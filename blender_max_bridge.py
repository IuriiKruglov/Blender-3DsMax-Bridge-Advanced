# ============================================================
#  Blender <-> 3Ds Max Bridge Advanced  (Blender add-on)
#  Version 3.0
#
#  Created by Claude (Anthropic)
#  under the leadership of Kruglov Iurii
#  License: GNU General Public License v3.0
# ============================================================
#
#  One add-on for both directions, together with BlenderMaxBridge.ms
#  3.0 in 3ds Max. Both apps use one bridge folder (set it in the
#  add-on preferences and in the 3ds Max dialog).
#
#  Blender -> 3ds Max ("Send to 3ds Max"; was Blender -> 3ds Max
#  Bridge 2.5): the scene state is saved, the JSON (hierarchy,
#  rotation orders, transforms, per-axis keys, collections, armatures
#  as dummies or exact bones with Skin, bones linked to objects with
#  Child Of) and the FBX (geometry) are written, the scene is restored
#  exactly, and a job file in the bridge folder makes the 3ds Max
#  listener import both. 3ds Max writes the result back; the panel
#  shows it.
#
#  3ds Max -> Blender ("Import latest from 3ds Max"; was 3ds Max ->
#  Blender Bridge 0.9): imports what "Send to Blender" in 3ds Max wrote
#  into <bridge folder>/FromMax (<scene>.json + .bin, latest.json):
#  hierarchy, groups, pivots, layers, meshes with 3ds Max's own
#  normals, splines, materials, Skin as an armature (bones that follow
#  other objects through Child Of), animation, units, and checks the
#  result against the values 3ds Max wrote.
#
#  Reset (panel "Bridge"): puts the bridge back to idle when something
#  went wrong, froze or hangs: stops waiting for 3ds Max, withdraws a
#  job 3ds Max has not picked up, clears the status, and ends a
#  progress bar or busy cursor left behind. Scene data is not touched.
#  BlenderMaxBridge.ms has its own Reset for the 3ds Max side.
#
#  Compatible with Blender 3.6 - 5.2.
#
#  INSTALL: Edit > Preferences > Add-ons > Install (from Disk), pick
#  this file (keep its name: it is the module name) and enable
#  "Blender <-> 3Ds Max Bridge Advanced". It replaces both older
#  add-ons: "Blender -> 3ds Max Bridge" has the same file name and is
#  updated in place; "3ds Max -> Blender Bridge" is switched off when
#  this add-on starts (remove it in Preferences > Add-ons).
#  UI: View3D > Sidebar (N) > Max Bridge,
#      File > Export > Send to 3ds Max (FBX + JSON) / Blender JSON,
#      File > Import > 3ds Max -> Blender (.json)
# ============================================================

bl_info = {
    "name":        "Blender <-> 3Ds Max Bridge Advanced",
    "author":      "Claude (Anthropic) under the leadership of Kruglov Iurii",
    "version":     (3, 0, 0),
    "blender":     (3, 6, 0),
    "location":    "View3D > Sidebar > Max Bridge  |  File > Export / File > Import",
    "description": "Two-way bridge with 3ds Max: sends objects, hierarchy, rotation orders, animation, "
                   "collections and armatures (dummies or exact bones + Skin) to 3ds Max, and imports 3ds Max "
                   "scenes (hierarchy, pivots, layers, meshes, materials, Skin, animation), checked on both sides",
    "category":    "Import-Export",
}

import bmesh
import collections
import json
import math
import os
import re
import tempfile
import time
import uuid

import bpy
import numpy as np
from bpy.props import (BoolProperty, EnumProperty, FloatProperty, IntProperty,
                       PointerProperty, StringProperty)
from bpy_extras.io_utils import ExportHelper, ImportHelper
from mathutils import Euler, Matrix, Quaternion, Vector
from mathutils.kdtree import KDTree

ADDON_VERSION = "3.0"
FROM_MAX_DIR = "FromMax"          # subfolder of the bridge folder: the scenes 3ds Max sends
# add-ons this one replaces (module -> name); they are switched off when this one starts
OLD_ADDONS = {"max_to_blender_bridge": "3ds Max -> Blender Bridge"}


# ─────────────────────────────────────────────────────────────────────────────
#  Bridge folder (both directions)
# ─────────────────────────────────────────────────────────────────────────────

def default_bridge_dir():
    base = os.environ.get("LOCALAPPDATA") or tempfile.gettempdir()
    return os.path.join(base, "BlenderMaxBridge")


def _prefs():
    try:
        addon = bpy.context.preferences.addons.get(__name__)
        return addon.preferences if addon else None
    except Exception:
        return None


def bridge_dir():
    p = _prefs()
    path = bpy.path.abspath(p.bridge_dir) if (p and p.bridge_dir.strip()) else default_bridge_dir()
    return os.path.normpath(path)


def exchange_dir():
    """Folder of the scenes 3ds Max sends (Send to Blender): <bridge folder>/FromMax."""
    return os.path.join(bridge_dir(), FROM_MAX_DIR)


# ═════════════════════════════════════════════════════════════════════════════
#  PART 1   Blender -> 3ds Max  (Send to 3ds Max)
# ═════════════════════════════════════════════════════════════════════════════

JSON_FORMAT = "BlenderMaxBridge"
JSON_VERSION = 5                  # 4: "Exact bones" armatures ("mode": "exact"), Skin "dq"; 5: bones linked to
                                  # objects (Child Of), "bone_axes", "bind_zero", Skin "armatures", "units"
EXACT_MIN_LISTENER = (2, 4)       # 3ds Max script that builds exact bones
JOB_FORMAT = "BlenderMaxBridgeJob"

JOB_FILE = "job.json"
RESULT_FILE = "result.json"
HEARTBEAT_FILE = "listener.json"
HEARTBEAT_MAX_AGE = 10.0          # seconds; Max rewrites it every ~2 s

PICKUP_TIMEOUT_OFFLINE = 30.0     # listener not running: give up after this
PICKUP_TIMEOUT_ONLINE = 180.0     # listener alive but busy: wait this long
RESULT_TIMEOUT = 1800.0           # import itself may take a while on big scenes

# Object types the FBX exporter writes with object_types = all six groups.
FBX_TYPES = {'EMPTY', 'CAMERA', 'LIGHT', 'ARMATURE', 'MESH',
             'CURVE', 'SURFACE', 'FONT', 'META'}
AXES = ("X", "Y", "Z")


def _resolve_output(settings):
    """Folder and base file name for the FBX/JSON pair."""
    folder = settings.output_dir.strip()
    if folder:
        folder = bpy.path.abspath(folder)
    elif bpy.data.filepath:
        folder = os.path.dirname(bpy.data.filepath)
    else:
        folder = os.path.join(bridge_dir(), "exports")
    base = settings.base_name.strip()
    if not base:
        base = bpy.path.display_name_from_filepath(bpy.data.filepath) if bpy.data.filepath else "untitled"
    base = bpy.path.clean_name(base)
    return os.path.normpath(folder), base


def listener_status():
    """(alive, seconds since last heartbeat or None)."""
    path = os.path.join(bridge_dir(), HEARTBEAT_FILE)
    try:
        age = time.time() - os.path.getmtime(path)
    except OSError:
        return False, None
    return age <= HEARTBEAT_MAX_AGE, age


def listener_units():
    """Units of the 3ds Max scene the listener runs in (from its heartbeat, 2.5 on), or ""."""
    hb = _read_json(os.path.join(bridge_dir(), HEARTBEAT_FILE))
    return str(hb.get("units", "")) if isinstance(hb, dict) else ""


def listener_version():
    """Version of the running 3ds Max script as a tuple (from its heartbeat), or None."""
    hb = _read_json(os.path.join(bridge_dir(), HEARTBEAT_FILE))
    try:
        parts = [int(x) for x in str(hb.get("bridge", "")).split(".")[:2]]
    except (AttributeError, ValueError):
        return None
    return tuple(parts + [0] * (2 - len(parts)))


# ─────────────────────────────────────────────────────────────────────────────
#  Compact JSON writer
#  Plain decimals only (no exponent notation), one object per line.
# ─────────────────────────────────────────────────────────────────────────────

def _num(v):
    v = float(v)
    if not math.isfinite(v) or abs(v) < 1e-12:
        return "0"
    s = ("%.10f" % v).rstrip("0").rstrip(".")
    return "0" if s in ("", "-0") else s


def _str(s):
    return json.dumps(str(s), ensure_ascii=False)


def _dump(v):
    if isinstance(v, dict):
        return "{" + ",".join(_str(k) + ":" + _dump(x) for k, x in v.items()) + "}"
    if isinstance(v, (list, tuple)):
        return "[" + ",".join(_dump(x) for x in v) + "]"
    if isinstance(v, bool):
        return "true" if v else "false"
    if v is None:
        return "null"
    if isinstance(v, (int, float)):
        return _num(v)
    return _str(v)


def write_bridge_json(path, data):
    sections = ("objects", "collections", "armatures", "skins")
    header = {k: v for k, v in data.items() if k not in sections}
    parts = ["{"]
    parts.append(",".join(_str(k) + ":" + _dump(v) for k, v in header.items()) + ",")
    parts.append('"objects":{')
    parts.append(",\n".join(_str(name) + ":" + _dump(rec) for name, rec in data["objects"].items()))
    parts.append("},")
    parts.append('"collections":' + _dump(data["collections"]))
    for sec in ("armatures", "skins"):          # JSON v3; older importers ignore them
        if data.get(sec):
            parts.append(',"%s":{' % sec)
            parts.append(",\n".join(_str(name) + ":" + _dump(rec) for name, rec in data[sec].items()))
            parts.append("}")
    parts.append("}")
    text = "\n".join(parts) + "\n"
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)
    os.replace(tmp, path)
    return len(text)


def _write_json_atomic(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(obj, fh, ensure_ascii=False, indent=1)
    for attempt in range(20):            # Max may hold the file for a moment
        try:
            os.replace(tmp, path)
            return
        except PermissionError:
            time.sleep(0.05)
    os.replace(tmp, path)


def _read_json(path):
    try:
        with open(path, "r", encoding="utf-8-sig") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


# ─────────────────────────────────────────────────────────────────────────────
#  Animation access, Blender 3.6 - 5.2
# ─────────────────────────────────────────────────────────────────────────────

def assigned_fcurves(id_data):
    """F-Curves of the action that actually animates id_data."""
    ad = getattr(id_data, "animation_data", None)
    if ad is None or ad.action is None:
        return ()
    act = ad.action
    if hasattr(act, "layers"):                        # Blender 4.4+ slotted actions
        slot = getattr(ad, "action_slot", None)
        if slot is None:
            return ()
        try:
            from bpy_extras.anim_utils import action_get_channelbag_for_slot
        except ImportError:
            action_get_channelbag_for_slot = None
        if action_get_channelbag_for_slot is not None:
            bag = action_get_channelbag_for_slot(act, slot)
            return tuple(bag.fcurves) if bag is not None else ()
        for layer in act.layers:
            for strip in layer.strips:
                bag = strip.channelbag(slot) if hasattr(strip, "channelbag") else None
                if bag is not None:
                    return tuple(bag.fcurves)
        return ()
    return tuple(act.fcurves)                         # Blender 3.6 - 4.3


def _keys(fc):
    return [{"frame": kp.co[0], "value": kp.co[1]} for kp in fc.keyframe_points]


def _quat_from_mode(mode, values):
    if mode == 'QUATERNION':
        return Quaternion(values).normalized()
    # AXIS_ANGLE: (angle, x, y, z)
    axis = Vector(values[1:4])
    if axis.length < 1e-12:
        return Quaternion()
    return Quaternion(axis.normalized(), values[0])


# ─────────────────────────────────────────────────────────────────────────────
#  Scene data -> JSON  (same fields and meaning as add-on v1.0)
# ─────────────────────────────────────────────────────────────────────────────

def object_record(obj, parent):
    """parent: name of the 3ds Max parent node ("" = none), see resolve_max_parent()."""
    mode = obj.rotation_mode
    if mode in ('QUATERNION', 'AXIS_ANGLE'):
        static = (tuple(obj.rotation_quaternion) if mode == 'QUATERNION'
                  else tuple(obj.rotation_axis_angle))
        rot = _quat_from_mode(mode, static).to_euler('XYZ')
        out_mode = 'XYZ'
    else:
        rot = obj.rotation_euler
        out_mode = mode

    anim = {ch: {"X": [], "Y": [], "Z": []} for ch in ("location", "rotation_euler", "scale")}

    fcurves = assigned_fcurves(obj)
    for fc in fcurves:
        dp, idx = fc.data_path, fc.array_index
        if idx > 2:
            continue
        if dp in ("location", "scale"):
            anim[dp][AXES[idx]] = _keys(fc)
        elif dp == "rotation_euler" and out_mode == mode:
            anim[dp][AXES[idx]] = _keys(fc)

    if out_mode != mode:
        # Quaternion / axis-angle animation -> XYZ euler keys with continuity.
        path = "rotation_quaternion" if mode == 'QUATERNION' else "rotation_axis_angle"
        comps = {fc.array_index: fc for fc in fcurves if fc.data_path == path}
        if comps:
            frames = sorted({kp.co[0] for fc in comps.values() for kp in fc.keyframe_points})
            prev = None
            for f in frames:
                vals = [comps[i].evaluate(f) if i in comps else static[i] for i in range(4)]
                q = _quat_from_mode(mode, vals)
                e = q.to_euler('XYZ', prev) if prev is not None else q.to_euler('XYZ')
                prev = e
                for i, ax in enumerate(AXES):
                    anim["rotation_euler"][ax].append({"frame": f, "value": e[i]})

    return {
        "parent":         parent,
        "rotation_mode":  out_mode,
        "location":       list(obj.location),
        "rotation_euler": [rot[0], rot[1], rot[2]],
        "scale":          list(obj.scale),
        "animation":      anim,
    }


def collections_record(objects):
    """Same structure as add-on v1.0: {"layers": {col: parent}, "objects": {obj: col}}."""
    relevant = set()
    obj_to_col = {}
    for obj in objects:
        for col in obj.users_collection:
            obj_to_col[obj.name] = col.name
            relevant.add(col.name)
    col_parent = {}
    for col in bpy.data.collections:
        for child in col.children:
            col_parent[child.name] = col.name
    for name in list(relevant):
        cur = name
        while cur in col_parent and col_parent[cur] not in relevant:
            cur = col_parent[cur]
            relevant.add(cur)
    layers = {name: col_parent.get(name, "") for name in sorted(relevant)}
    return {"layers": layers, "objects": obj_to_col}


def fbx_unit_factor(scene):
    """Blender units -> FBX centimetres, exactly as io_scene_fbx computes it
    (apply_unit_scale=True, global_scale=1.0)."""
    us = scene.unit_settings
    return 100.0 if us.system == 'NONE' else 100.0 * us.scale_length


def collect_scene_data(context, objects, pose_frame, fbx_name="", plans=None):
    """plans: {armature name: RigPlan} for armatures converted to dummies (may be empty).
    Converted armatures without their own animation are not 3ds Max nodes, so they are
    left out of "objects" and their children are re-parented (see resolve_max_parent)."""
    scene = context.scene
    plans = plans or {}
    scope_set = set(objects)
    nodes = [o for o in objects if not (o.name in plans and not plans[o.name].node)]
    return {
        "format":      JSON_FORMAT,
        "version":     JSON_VERSION,
        "generator":   "Blender %s / blender_max_bridge %s" % (bpy.app.version_string, ADDON_VERSION),
        "source":      os.path.basename(bpy.data.filepath) if bpy.data.filepath else "",
        "fbx":         fbx_name,
        "pose_frame":  pose_frame,
        "fps":         scene.render.fps / (scene.render.fps_base or 1.0),
        "frame_start": scene.frame_start,
        "frame_end":   scene.frame_end,
        "unit_to_cm":  fbx_unit_factor(scene),
        "units":       {"system": scene.unit_settings.system, "scale_length": scene.unit_settings.scale_length},
        "objects":     {o.name: _object_with_space(o, plans, scope_set) for o in nodes},
        "collections": collections_record(objects),
    }


def _object_with_space(obj, plans, scope_set):
    name, ref = resolve_max_parent(obj, plans, scope_set)
    rec = object_record(obj, name)
    space = parent_space(obj, ref, plans)
    if space is not None:
        rec["parent_space"] = space
    return rec


def parent_space(obj, ref, plans=None):
    """Space of obj's own channel values relative to its 3ds Max parent.

    Blender: world = parent matrix @ matrix_parent_inverse @ basis. The 3ds Max script
    assumes that the channel values are the world values in the pose the scene is linked
    in, which holds after Ctrl+P as long as the parent has kept the pose it had then. When
    the parent was parented in another pose (or has moved since), this returns the 3x4
    rows of M, constant over time, with
        world(obj) = world(3ds Max parent) @ M @ basis(obj)
    otherwise None. The linking pose is the pose frame; for children of bone dummies it
    is the bind (rest) pose, like the FBX and the dummies. ref: from resolve_max_parent.
    plans: bones of "Exact bones" rigs keep the bone's own axes (no dummy axes)."""
    par = obj.parent
    if par is None:
        return None
    kind, target = ref if ref is not None else (None, None)
    pinv = obj.matrix_parent_inverse
    if obj.parent_type == 'BONE':
        bone = par.data.bones.get(obj.parent_bone) if par.type == 'ARMATURE' else None
        if bone is None or bone.use_relative_parent:
            return None
        tail = Matrix.Translation((0.0, bone.length, 0.0))
        if kind == 'bone':
            plan = (plans or {}).get(target[0])
            axes = (Matrix.Identity(4) if plan is not None and plan.exact else
                    plan.axes.get(target[1], DUMMY_AXES) if plan is not None else DUMMY_AXES)
            q = par.matrix_world @ bone.matrix_local @ tail @ pinv
            w_max = par.matrix_world @ bone.matrix_local @ axes
        else:
            q = par.matrix_world @ par.pose.bones[obj.parent_bone].matrix @ tail @ pinv
            w_max = target.matrix_world if kind == 'object' else Matrix.Identity(4)
    else:
        if obj.parent_type in ('VERTEX', 'VERTEX_3'):
            q = obj.matrix_world @ obj.matrix_basis.inverted_safe()
        else:
            q = par.matrix_world @ pinv
        w_max = target.matrix_world if kind == 'object' else Matrix.Identity(4)
    if max(abs(q[r][c] - (1.0 if r == c else 0.0)) for r in range(3) for c in range(4)) < 1e-5:
        return None
    m = w_max.inverted_safe() @ q
    return [[m[r][c] for c in range(4)] for r in range(3)]


# ─────────────────────────────────────────────────────────────────────────────
#  Armatures -> 3ds Max dummies + Skin modifier
#
#  Every converted bone becomes a Dummy named like the bone. Its axes are the
#  bone axes turned +90 degrees about the bone X axis:
#      dummy X = bone X,  dummy Y = bone Z (up),  dummy Z = -bone Y
#  For bones pointing backwards (+Y) that is "Z forward, Y up", the same as
#  the hand-made 3ds Max reference scene. A constant per-bone rotation does
#  not change the deformation: the Skin modifier only uses each dummy's
#  motion relative to its bind pose.
#
#  All matrices are evaluated by Blender itself (pose_bone.matrix includes
#  parents, inheritance, constraints, drivers, NLA), converted to the local
#  transform of the dummy relative to its 3ds Max parent and written as
#  position / Euler XYZ / scale values, ready for the 3ds Max controllers.
# ─────────────────────────────────────────────────────────────────────────────

DUMMY_AXES = Matrix.Rotation(math.radians(90.0), 4, 'X')

_POSE_PATH = re.compile(r'^pose\.bones\["((?:[^"\\]|\\.)*)"\]\.'
                        r'(location|rotation_quaternion|rotation_euler|rotation_axis_angle|scale)$')
_OBJECT_TRANSFORM_PATHS = {"location", "rotation_euler", "rotation_quaternion", "rotation_axis_angle",
                           "scale", "delta_location", "delta_rotation_euler",
                           "delta_rotation_quaternion", "delta_scale"}
_ROT_PATH = {'QUATERNION': "rotation_quaternion", 'AXIS_ANGLE': "rotation_axis_angle"}


class RigPlan:
    """How one armature object is converted."""

    def __init__(self, arm):
        self.arm = arm
        self.name = arm.name
        self.node = False        # True: the armature object itself becomes a dummy (it is animated)
        self.bones = []          # converted bones (deform bones + their parents), parents first
        self.bone_set = set()
        self.bake = False        # constraints / drivers / NLA / partial inheritance: sample every frame
        self.parent = ""         # 3ds Max parent of the root bone dummies ("" = world)
        self.parent_ref = None   # ('object', obj) or ('bone', (armature name, bone name)) or None
        self.exact = False       # "Exact bones": every bone becomes a 3ds Max bone with the bone's own axes
        self.links = {}          # root bone -> (3ds Max parent name, ref, Child Of constraint): bones linked to objects
        self.axes = {}           # bone -> dummy axes in the bone's frame (dummies of linked rigs: Y up, Z front)
        self.warnings = []


def _bones_parents_first(bones):
    out, seen = [], set()

    def visit(b):
        if b.name in seen:
            return
        if b.parent is not None:
            visit(b.parent)
        seen.add(b.name)
        out.append(b)

    for b in bones:
        visit(b)
    return out


def _object_animated(obj):
    if any(fc.data_path in _OBJECT_TRANSFORM_PATHS for fc in assigned_fcurves(obj)):
        return True
    ad = obj.animation_data
    if ad is not None and any(fc.data_path in _OBJECT_TRANSFORM_PATHS and not fc.mute for fc in ad.drivers):
        return True
    return any(not c.mute for c in obj.constraints)


def _rig_needs_bake(arm, bones, links=None):
    """Constraints, drivers, NLA or partial inheritance: the pose is sampled on every frame. A Child Of
    that links a root bone to an object (links) is no reason: that bone hangs under the object in 3ds Max."""
    linked = {v[2].as_pointer() for v in (links or {}).values()}
    if any(not c.mute and c.as_pointer() not in linked for pb in arm.pose.bones for c in pb.constraints):
        return True
    ad = arm.animation_data
    if ad is not None:
        if any(fc.data_path.startswith("pose.bones[") and not fc.mute for fc in ad.drivers):
            return True
        if ad.use_nla and any(len(t.strips) for t in ad.nla_tracks if not t.mute):
            return True
    return any(not b.use_inherit_rotation or getattr(b, "inherit_scale", 'FULL') != 'FULL' for b in bones)


def resolve_max_parent(obj, plans, scope_set):
    """(name, ref) of the node obj gets parented to in 3ds Max. ("", None) = world.
    Converted armatures that are not nodes pass their children on to their own parent;
    children of a converted bone get that bone's dummy."""
    child, par = obj, obj.parent
    while par is not None:
        if par not in scope_set:
            return "", None
        plan = plans.get(par.name) if par.type == 'ARMATURE' else None
        if plan is None:
            return par.name, ('object', par)
        if child.parent_type == 'BONE' and child.parent_bone in plan.bone_set:
            return child.parent_bone, ('bone', (plan.name, child.parent_bone))
        if plan.node:
            return par.name, ('object', par)
        child, par = par, par.parent
    return "", None


def plan_rigs(scope, bake_all=False, exact=False):
    """exact: "Exact bones" - every bone of the armature becomes a 3ds Max bone (the whole rig);
    else the deform bones, the bones carrying child objects and their parents become dummies."""
    scope_set = set(scope)
    plans = {}
    for arm in scope:
        if arm.type != 'ARMATURE':
            continue
        p = RigPlan(arm)
        p.exact = exact
        bones = arm.data.bones
        if exact:
            keep = {b.name for b in bones}
        else:
            wanted = [b for b in bones if b.use_deform]
            # bones that carry child objects become dummies too
            wanted += [bones[o.parent_bone] for o in scope
                       if o.parent is arm and o.parent_type == 'BONE' and o.parent_bone in bones]
            keep = set()
            for b in wanted:
                x = b
                while x is not None and x.name not in keep:
                    keep.add(x.name)
                    x = x.parent
        p.bones = [b for b in _bones_parents_first(list(bones)) if b.name in keep]
        p.bone_set = keep
        p.node = _object_animated(arm)
        if not p.bones:
            p.warnings.append("Armature '%s' has no %sbones, nothing to convert." % (arm.name, "" if exact else "deform "))
        for b in p.bones:
            if b.use_deform and b.bbone_segments > 1:
                p.warnings.append("Bone '%s' has %d B-Bone segments; 3ds Max deforms it as a straight bone."
                                  % (b.name, b.bbone_segments))
        plans[arm.name] = p
    for p in plans.values():
        if p.node:
            p.parent, p.parent_ref = p.name, ('object', p.arm)
        else:
            p.parent, p.parent_ref = resolve_max_parent(p.arm, plans, scope_set)
    # root bones linked to objects with Child Of (an assembly: CSLM12_Bone_gun -> CSLM12_Hull): in 3ds Max
    # the bone hangs under that object, no constraint
    for p in plans.values():
        for b in p.bones:
            if b.parent is None:
                link = _child_of_link(p.arm, b, plans, scope_set)
                if link is not None:
                    p.links[b.name] = link
        p.bake = bake_all or _rig_needs_bake(p.arm, p.bones, p.links)
        if p.links and not p.exact:
            # dummies of an assembly rig: the bone axes turned in 90 degree steps, Y up, Z to the front
            for b in p.bones:
                p.axes[b.name] = upright_axes((p.arm.matrix_world @ b.matrix_local).to_3x3())
    return plans


def _child_of_link(arm, b, plans, scope_set):
    """(3ds Max parent name, ref, constraint) when root bone b follows an object (or a converted bone)
    with one plain Child Of: the only active constraint, full influence, every channel, owner space
    Pose, target space World, its inverse set. Then bone world = target world @ inverse @ pose matrix,
    the bone's local transform under the target is inverse @ rest @ basis, and the bone can hang
    under the target in 3ds Max. Else None (the rig is sampled on every frame, as before)."""
    pb = arm.pose.bones.get(b.name)
    if pb is None:
        return None
    active = [c for c in pb.constraints if not c.mute and c.influence > 0.0]
    if len(active) != 1 or active[0].type != 'CHILD_OF':
        return None
    c = active[0]
    flags = ("use_location_x", "use_location_y", "use_location_z", "use_rotation_x", "use_rotation_y",
             "use_rotation_z", "use_scale_x", "use_scale_y", "use_scale_z")
    if (c.influence < 1.0 - 1e-6 or not all(getattr(c, f, True) for f in flags) or c.owner_space != 'POSE'
            or c.target_space != 'WORLD' or getattr(c, "set_inverse_pending", False)):
        return None
    t = c.target
    if t is None or t is arm or t not in scope_set:
        return None
    if c.subtarget:
        tp = plans.get(t.name) if t.type == 'ARMATURE' else None
        if tp is None or c.subtarget not in tp.bone_set or getattr(c, "head_tail", 0.0) != 0.0:
            return None
        tw = t.matrix_world @ t.pose.bones[c.subtarget].matrix
        return (c.subtarget, ('bone', (tp.name, c.subtarget)), c) if _child_of_holds(arm, pb, tw, c) else None
    if t.type == 'ARMATURE' and t.name in plans and not plans[t.name].node:
        return None                     # an armature that is no 3ds Max node
    return (t.name, ('object', t), c) if _child_of_holds(arm, pb, t.matrix_world, c) else None


def _child_of_holds(arm, pb, tw, c):
    """The bone is where Child Of puts it: armature world @ pose matrix = target world @ inverse @ rest @
    basis (no drivers or other effects on top)."""
    want = tw @ Matrix(c.inverse_matrix) @ pb.bone.matrix_local @ pb.matrix_basis
    got = arm.matrix_world @ pb.matrix
    tol = 1e-5 * max(1.0, want.translation.length)
    return max(abs(want[i][j] - got[i][j]) for i in range(3) for j in range(4)) <= tol


_UP, _FRONT = Vector((0.0, 0.0, 1.0)), Vector((0.0, -1.0, 0.0))


def upright_axes(w3):
    """Dummy axes in the bone's frame (4x4, a turn by 90 degree steps): dummy Y = the bone axis nearest
    to the scene's up (+Z), dummy Z = the remaining axis nearest to the front (-Y), X completes them.
    w3: the bone's axes in the world (bind pose)."""
    cols = [Vector((w3[0][i], w3[1][i], w3[2][i])).normalized() for i in range(3)]
    cands = [(i, s) for i in range(3) for s in (1.0, -1.0)]
    iy, sy = max(cands, key=lambda c: c[1] * cols[c[0]].dot(_UP))
    iz, sz = max((c for c in cands if c[0] != iy), key=lambda c: c[1] * cols[c[0]].dot(_FRONT))
    ix = 3 - iy - iz
    m = Matrix(((0.0,) * 3,) * 3)
    m[iy][1], m[iz][2], m[ix][0] = sy, sz, 1.0
    if m.determinant() < 0.0:
        m[ix][0] = -1.0
    return m.to_4x4()


def bone_axes_code(axes):
    """User property text for the 3ds Max -> Blender importer: the bone's X, Y, Z as dummy axes
    ("x,-z,y" for the plain dummy axes)."""
    out = []
    for j in range(3):
        k = max(range(3), key=lambda k: abs(axes[j][k]))
        out.append(("-" if axes[j][k] < 0.0 else "") + "xyz"[k])
    return ",".join(out)


def _rig_fcurves(arm):
    """{bone name: {property: [fcurves]}} from the action that animates the armature."""
    out = {}
    for fc in assigned_fcurves(arm):
        m = _POSE_PATH.match(fc.data_path)
        if m:
            bone = re.sub(r'\\(.)', r'\1', m.group(1))
            out.setdefault(bone, {}).setdefault(m.group(2), []).append(fc)
    return out


def _side_hint(fc, i, side):
    """3ds Max tangent type that reproduces this side of Blender key i."""
    kps = fc.keyframe_points
    kp = kps[i]
    if side == "out":
        if i == len(kps) - 1:
            return None
        mode, h = kp.interpolation, kp.handle_right
    else:
        if i == 0:
            return None
        mode, h = kps[i - 1].interpolation, kp.handle_left
    if mode == 'CONSTANT':
        return "step"
    if mode == 'LINEAR':
        return "linear"
    if mode == 'BEZIER' and abs(h[1] - kp.co[1]) <= 1e-6 * max(1.0, abs(kp.co[1])):
        return "flat"
    return "auto"


def _combine_hints(hints):
    hs = {h for h in hints if h is not None}
    if not hs:
        return None
    return hs.pop() if len(hs) == 1 else "auto"


def _group_keys(fcurves):
    """{frame key: [frame, ti, to]} for the union of keys of a channel group."""
    keys = {}
    for fc in fcurves:
        for i, kp in enumerate(fc.keyframe_points):
            k = int(round(kp.co[0] * 1000.0))
            e = keys.setdefault(k, [kp.co[0], [], []])
            e[1].append(_side_hint(fc, i, "in"))
            e[2].append(_side_hint(fc, i, "out"))
    return {k: [e[0], _combine_hints(e[1]), _combine_hints(e[2])] for k, e in keys.items()}


def _decompose(m, prev=None):
    loc, q, sca = m.decompose()
    e = q.to_euler('XYZ', prev) if prev is not None else q.to_euler('XYZ')
    return loc, e, sca


def _prs(loc, e, sca):
    return {"location": [loc[0], loc[1], loc[2]], "rotation": [e[0], e[1], e[2]],
            "scale": [sca[0], sca[1], sca[2]]}


def _frame_set(scene, f):
    fi = math.floor(f)
    scene.frame_set(int(fi), subframe=float(f - fi))


def collect_rig_data(context, plans, pose_frame):
    """JSON records for the converted armatures. Leaves the scene at pose_frame."""
    scene = context.scene
    active = [p for p in plans.values() if p.bones]
    if not active:
        return {}

    def dummy_worlds(rest):
        dw = {}
        for p in active:
            arm = p.arm
            for b in p.bones:
                m = b.matrix_local if rest else arm.pose.bones[b.name].matrix
                dw[(p.name, b.name)] = arm.matrix_world @ m @ p.axes.get(b.name, DUMMY_AXES)
        return dw

    def parent_world(p, b, dw):
        if b.parent is not None:
            return dw[(p.name, b.parent.name)]
        link = p.links.get(b.name)
        kind, ref = link[1] if link is not None else (p.parent_ref or (None, None))
        if kind is None:
            return Matrix.Identity(4)
        if kind == 'object':
            return ref.matrix_world.copy()
        return dw.get(ref, Matrix.Identity(4))

    def locals_at(dw):
        return {(p.name, b.name): parent_world(p, b, dw).inverted_safe() @ dw[(p.name, b.name)]
                for p in active for b in p.bones}

    # rest (bind pose) and pose-frame values
    _frame_set(scene, pose_frame)
    dw_rest = dummy_worlds(True)
    rest = locals_at(dw_rest)
    pose = locals_at(dummy_worlds(False))

    # which frames are needed, per bone and channel group
    groups = {}            # (rig, bone) -> {"location": {fk: [f, ti, to]}, ...}
    frames = {}            # frame key -> frame
    for p in active:
        fcs = {} if p.bake else _rig_fcurves(p.arm)
        for b in p.bones:
            if p.bake:
                fr = {int(f * 1000): [float(f), None, None]
                      for f in range(scene.frame_start, scene.frame_end + 1)}
                g = {"location": fr, "rotation": fr, "scale": fr}
            else:
                bf = fcs.get(b.name, {})
                rot_path = _ROT_PATH.get(p.arm.pose.bones[b.name].rotation_mode, "rotation_euler")
                g = {"location": _group_keys(bf.get("location", [])),
                     "rotation": _group_keys(bf.get(rot_path, [])),
                     "scale": _group_keys(bf.get("scale", []))}
            groups[(p.name, b.name)] = g
            for keys in g.values():
                for fk, e in keys.items():
                    frames[fk] = e[0]

    # evaluate Blender at every needed frame
    sampled = {}           # (rig, bone) -> {fk: local matrix}
    for fk in sorted(frames):
        _frame_set(scene, frames[fk])
        loc = locals_at(dummy_worlds(False))
        for key, g in groups.items():
            if any(fk in keys for keys in g.values()):
                sampled.setdefault(key, {})[fk] = loc[key]
    _frame_set(scene, pose_frame)

    out = {}
    for p in active:
        arm = p.arm
        bones_out = []
        for b in p.bones:
            key = (p.name, b.name)
            r_loc, r_rot, r_sca = _decompose(rest[key])
            q_loc, q_rot, q_sca = _decompose(pose[key], r_rot)
            anim = {"location": {}, "rotation": {}, "scale": {}}
            smp = sampled.get(key, {})
            prev = q_rot
            values = {}
            for fk in sorted(smp):
                l, e, s = _decompose(smp[fk], prev)
                prev = e
                values[fk] = (l, e, s)
            static = (q_loc, q_rot, q_sca)
            for gi, gname in enumerate(("location", "rotation", "scale")):
                keys = groups[key][gname]
                if not keys:
                    continue
                ordered = sorted(keys)
                for ax in range(3):
                    vals = [values[fk][gi][ax] for fk in ordered]
                    if max(vals) - min(vals) <= 1e-6 and abs(vals[0] - static[gi][ax]) <= 1e-6:
                        continue                      # this axis does not move: no keys
                    lst = []
                    for fk, v in zip(ordered, vals):
                        f, ti, to = keys[fk]
                        k = {"frame": f, "value": v}
                        if ti is not None:
                            k["ti"] = ti
                        if to is not None:
                            k["to"] = to
                        lst.append(k)
                    anim[gname][AXES[ax]] = lst
            link = p.links.get(b.name)
            bones_out.append({
                "name":           b.name,
                "parent":         b.parent.name if b.parent is not None else link[0] if link else p.parent,
                "deform":         b.use_deform,
                "length":         b.length,
                "bone_axes":      bone_axes_code(p.axes.get(b.name, DUMMY_AXES)),
                "rest":           _prs(r_loc, r_rot, r_sca),
                "pose":           _prs(q_loc, q_rot, q_sca),
                "world_rotation": list(dw_rest[key].to_3x3().normalized().to_quaternion().to_euler('XYZ')),
                "animation":      anim,
            })
        w_loc, w_rot, w_sca = _decompose(arm.matrix_world)
        out[p.name] = {
            "node":   p.node,
            "parent": p.parent,
            "bake":   p.bake,
            "world":  _prs(w_loc, w_rot, w_sca),
            "bones":  bones_out,
        }
    return out


# ─────────────────────────────────────────────────────────────────────────────
#  Armatures -> exact 3ds Max bones + Skin modifier  ("Exact bones", new in 2.4)
#
#  Every bone becomes a 3ds Max bone with the bone's own axes (Y along the
#  bone), linked like the bones in Blender; root bones go under the armature's
#  own parent (no armature node, unless the armature object is animated).
#  Its controllers are Freeze Transform layers, as 3ds Max's Freeze Transform
#  builds them:
#      Frozen Position / Frozen Rotation = rest (bind) pose relative to the
#                                          3ds Max parent
#      Zero Pos XYZ    = Blender's location in the parent's axes
#      Zero Euler XYZ  = Blender's rotation (Euler bones: Blender's own values
#                        and rotation order; quaternion bones: Euler XYZ)
#      Scale           = Blender's scale
#  so in 3ds Max the rest pose reads as zero, like the rest pose in Blender,
#  and the keys carry Blender's pose bone values. Rotation lists apply the
#  zero layer in the frozen (local) frame and position lists add up in the
#  parent's frame, so a bone's local transform is
#      T(frozen + zero position) @ R(frozen) @ R(zero) @ S(scale)
#  which is Blender's rest_relative @ T(location) @ R(rotation) @ S(scale).
# ─────────────────────────────────────────────────────────────────────────────

_EULER_ORDERS = ('XYZ', 'XZY', 'YXZ', 'YZX', 'ZXY', 'ZYX')


def _axis_map(m3, tol=1e-6):
    """For a matrix that maps each axis onto one axis (a turn by multiples of 90 deg, maybe
    scaled): [(target axis, factor) for source axes x, y, z], else None."""
    out = []
    for j in range(3):
        col = [m3[i][j] for i in range(3)]
        i = max(range(3), key=lambda k: abs(col[k]))
        big = abs(col[i])
        if big < 1e-12 or any(abs(col[k]) > tol * big for k in range(3) if k != i):
            return None
        out.append((i, col[i]))
    return out if len({i for i, _ in out}) == 3 else None


def _keys_with_hints(keys, values_of, ax):
    """JSON key list for one 3ds Max axis: keys {fk: [frame, ti, to]}, values_of(fk) -> vector."""
    lst = []
    for fk in sorted(keys):
        f, ti, to = keys[fk]
        k = {"frame": f, "value": values_of(fk)[ax]}
        if ti is not None:
            k["ti"] = ti
        if to is not None:
            k["to"] = to
        lst.append(k)
    return lst


def _snap(x, targets, tol=1e-6):
    """x moved onto the nearest of targets when it is within tol (32-bit float noise of the
    bone matrices), else unchanged."""
    for t in targets:
        if abs(x - t) <= tol * max(1.0, abs(t)):
            return t
    return x


def _channel_rotation(pb, order):
    """Pose bone rotation channels as (Euler in order or None, quaternion)."""
    mode = pb.rotation_mode
    if order is not None:
        e = pb.rotation_euler.copy()
        return e, e.to_quaternion()
    if mode == 'AXIS_ANGLE':
        return None, _quat_from_mode(mode, tuple(pb.rotation_axis_angle))
    return None, Quaternion(tuple(pb.rotation_quaternion)).normalized()


def collect_exact_rig_data(context, plans, pose_frame, warnings):
    """JSON records for the armatures sent as exact 3ds Max bones (see above).
    Values come from Blender's own pose bone channels (exact keys); the evaluated bone
    matrices confirm them, and replace them where the channels are not the pose (baked
    rigs: constraints, drivers, NLA, partial inheritance). Leaves the scene at pose_frame."""
    scene = context.scene
    active = [p for p in plans.values() if p.bones]
    if not active:
        return {}

    def bone_worlds(rest):
        bw = {}
        for p in active:
            arm = p.arm
            for b in p.bones:
                m = b.matrix_local if rest else arm.pose.bones[b.name].matrix
                bw[(p.name, b.name)] = arm.matrix_world @ m
        return bw

    def parent_world(p, b, bw):
        if b.parent is not None:
            return bw[(p.name, b.parent.name)]
        link = p.links.get(b.name)
        kind, ref = link[1] if link is not None else (p.parent_ref or (None, None))
        if kind is None:
            return Matrix.Identity(4)
        if kind == 'object':
            return ref.matrix_world.copy()
        return bw.get(ref, Matrix.Identity(4))

    def locals_at(bw):
        return {(p.name, b.name): parent_world(p, b, bw).inverted_safe() @ bw[(p.name, b.name)]
                for p in active for b in p.bones}

    # rest (bind) pose relative to the 3ds Max parent: the frozen layers
    _frame_set(scene, pose_frame)
    bw_rest = bone_worlds(True)
    rest = locals_at(bw_rest)
    # a root bone linked to an object with Child Of: local = inverse @ rest @ basis under the target, so
    # the frozen layer is inverse @ rest (its Skin bind stays the armature's rest pose, see "bind_zero")
    bind = {}
    for p in active:
        for bname, link in p.links.items():
            key = (p.name, bname)
            bind[key] = rest[key]
            rest[key] = Matrix(link[2].inverse_matrix) @ p.arm.data.bones[bname].matrix_local
    info = {}
    worst_rest = (0.0, "")
    for p in active:
        fcs = {} if p.bake else _rig_fcurves(p.arm)
        for b in p.bones:
            key = (p.name, b.name)
            pb = p.arm.pose.bones[b.name]
            r_loc, r_q, r_sca = rest[key].decompose()
            back = Matrix.LocRotScale(r_loc, r_q, r_sca)
            lost = max(abs(back[i][j] - rest[key][i][j]) for i in range(3) for j in range(4))
            if lost > worst_rest[0]:
                worst_rest = (lost, b.name)
            # bones are rigid: a scale of 1 within float noise is 1 (an armature scale stays)
            r_sca = Vector([_snap(c, (1.0,)) for c in r_sca])
            m3 = r_q.to_matrix() @ Matrix.Diagonal(r_sca)
            lmap = _axis_map(m3)
            if lmap is not None:                     # a turn by multiples of 90 deg: exact factors
                m3 = Matrix(((0.0,) * 3,) * 3)
                for j, (i, f) in enumerate(lmap):
                    m3[i][j] = _snap(f, (1.0, -1.0) + tuple(c * sg for c in r_sca for sg in (1.0, -1.0)))
            order = pb.rotation_mode if pb.rotation_mode in _EULER_ORDERS else None
            info[key] = {
                "p": p, "b": b, "pb": pb, "r_loc": r_loc, "r_q": r_q, "r_sca": r_sca, "m3": m3,
                "r_qinv": r_q.inverted(), "order": order, "zero_order": order or 'XYZ',
                "fc": fcs.get(b.name, {}), "lmap": lmap,
            }
    if worst_rest[0] > 1e-5:
        warnings.append("Bone '%s': its rest pose is sheared against its 3ds Max parent (%.2g; a scaled "
                        "armature or parent turned against the bone); 3ds Max cannot hold that exactly."
                        % (worst_rest[1], worst_rest[0]))

    # keys per bone, channel and 3ds Max axis: {fk: [frame, ti, to]}
    every = {int(round(f * 1000.0)): [float(f), None, None]
             for f in range(scene.frame_start, scene.frame_end + 1)}
    frames = {}
    for key, d in info.items():
        p = d["p"]
        chans = {"location": [{}, {}, {}], "rotation": [{}, {}, {}], "scale": [{}, {}, {}]}
        if p.bake:
            for g in chans.values():
                for ax in range(3):
                    g[ax] = every
        else:
            bf = d["fc"]
            # location: a Blender axis lands on one 3ds Max axis when the rest frame only swaps or
            # flips the parent's axes; otherwise every 3ds Max axis takes the keys of all of them
            loc_fcs = {fc.array_index: fc for fc in bf.get("location", []) if fc.array_index < 3}
            if loc_fcs:
                if d["lmap"] is not None:
                    for j, fc in loc_fcs.items():
                        chans["location"][d["lmap"][j][0]] = _group_keys([fc])
                else:
                    union = _group_keys(list(loc_fcs.values()))
                    chans["location"] = [union, union, union]
            if d["order"] is not None:
                # Euler bones: Blender's own keys, axis by axis
                for fc in bf.get("rotation_euler", []):
                    if fc.array_index < 3:
                        chans["rotation"][fc.array_index] = _group_keys([fc])
            else:
                rot_path = _ROT_PATH.get(d["pb"].rotation_mode, "rotation_quaternion")
                rot_fcs = bf.get(rot_path, [])
                if rot_fcs:
                    union = _group_keys(rot_fcs)
                    chans["rotation"] = [union, union, union]
            scl_fcs = [fc for fc in bf.get("scale", []) if fc.array_index < 3]
            if scl_fcs:
                union = _group_keys(scl_fcs)               # 3ds Max keeps X/Y/Z in one scale key
                chans["scale"] = [union, union, union]
        d["chans"] = chans
        for g in chans.values():
            for keys in g:
                for fk, e in keys.items():
                    frames[fk] = e[0]

    stats = {"lost": (0.0, ""), "fallback": set()}

    def zero_values(d, L, prev):
        """(zero position, zero rotation as Euler in zero_order, scale) of one bone now."""
        loc, q, sca = L.decompose()
        back = Matrix.LocRotScale(loc, q, sca)
        lost = max(abs(back[i][j] - L[i][j]) for i in range(3) for j in range(4))
        if lost > stats["lost"][0]:
            stats["lost"] = (lost, d["b"].name)
        zp_m = loc - d["r_loc"]
        qz_m = d["r_qinv"] @ q
        if not d["p"].bake:
            pb = d["pb"]
            e, qz = _channel_rotation(pb, d["order"])
            zp = d["m3"] @ Vector(pb.location)
            sc = Vector([pb.scale[i] * d["r_sca"][i] for i in range(3)])
            tol = 1e-5 * max(1.0, zp_m.length, d["r_loc"].length)
            ra, rb = qz.to_matrix(), qz_m.to_matrix()        # (float32 quaternions: compare matrices)
            if ((zp - zp_m).length <= tol and max(abs(ra[i][j] - rb[i][j]) for i in range(3) for j in range(3)) <= 1e-5
                    and max(abs(sc[i] - sca[i]) for i in range(3)) <= 1e-5 * max(1.0, max(abs(x) for x in sc))):
                if e is None:
                    e = qz.to_euler('XYZ', prev) if prev is not None else qz.to_euler('XYZ')
                return zp, e, sc
            stats["fallback"].add(d["b"].name)
        e = qz_m.to_euler(d["zero_order"], prev) if prev is not None else qz_m.to_euler(d["zero_order"])
        return zp_m, e, sca

    pose_vals = {}
    loc_now = locals_at(bone_worlds(False))
    for key, d in info.items():
        pose_vals[key] = zero_values(d, loc_now[key], None)
    sampled = {key: {} for key in info}
    prev = {key: pose_vals[key][1] for key in info}
    for fk in sorted(frames):
        _frame_set(scene, frames[fk])
        loc_now = locals_at(bone_worlds(False))
        for key, d in info.items():
            if any(fk in keys for g in d["chans"].values() for keys in g):
                vals = zero_values(d, loc_now[key], prev[key])
                prev[key] = vals[1]
                sampled[key][fk] = vals
    _frame_set(scene, pose_frame)
    if stats["lost"][0] > 1e-4:
        warnings.append("Bone '%s': its motion has shear (%.2g) that 3ds Max position / rotation / scale keys "
                        "cannot hold (non-uniform scale under a turned child)." % (stats["lost"][1], stats["lost"][0]))
    if stats["fallback"]:
        names = sorted(stats["fallback"])
        warnings.append("%d bone(s) are not posed by their own channels (%s): their keys take the evaluated "
                        "pose instead of Blender's channel values." % (len(names), ", ".join(names[:5])))

    out = {}
    for p in active:
        arm = p.arm
        bones_out = []
        for b in p.bones:
            key = (p.name, b.name)
            d = info[key]
            q_loc, q_rot, q_sca = pose_vals[key]
            link = p.links.get(b.name)
            # Skin bind of a linked bone = the armature's rest pose; when its target has moved since the
            # Child Of inverse was set, that is not the frozen pose: zero values that pose it there
            bz = None
            if key in bind:
                b_loc, b_q, b_sca = bind[key].decompose()
                z_loc, z_q = b_loc - d["r_loc"], d["r_qinv"] @ b_q
                zm = z_q.to_matrix()
                if (z_loc.length > 1e-6 * max(1.0, b_loc.length) or
                        max(abs(zm[i][j] - (1.0 if i == j else 0.0)) for i in range(3) for j in range(3)) > 1e-6):
                    bz = _prs(z_loc, z_q.to_euler(d["zero_order"]), b_sca)
            smp = sampled[key]
            static = (q_loc, q_rot, q_sca)
            anim = {"location": {}, "rotation": {}, "scale": {}}
            for gi, gname in enumerate(("location", "rotation", "scale")):
                g = d["chans"][gname]
                for ax in range(3):
                    keys = g[ax]
                    if not keys:
                        continue
                    vals = [smp[fk][gi][ax] for fk in sorted(keys)]
                    own = (not p.bake and (gname != "location" or d["lmap"] is not None)
                           and (gname != "rotation" or d["order"] is not None))
                    # Blender's own key tracks are kept as they are; tracks made of several
                    # (or baked) only on the axes that move
                    if not own and max(vals) - min(vals) <= 1e-6 and abs(vals[0] - static[gi][ax]) <= 1e-6:
                        continue
                    anim[gname][AXES[ax]] = _keys_with_hints(keys, lambda fk, gi=gi: smp[fk][gi], ax)
            rec = {
                "name":           b.name,
                "parent":         b.parent.name if b.parent is not None else link[0] if link else p.parent,
                "deform":         b.use_deform,
                "length":         b.length,
                "hide":           bool(b.hide),
                "rest":           _prs(d["r_loc"], d["r_q"].to_euler('XYZ'), d["r_sca"]),
                "zero_order":     d["zero_order"],
                "zero_pose":      _prs(q_loc, q_rot, q_sca),
                "world_rotation": list(bw_rest[key].to_3x3().normalized().to_quaternion().to_euler('XYZ')),
                "zero_animation": anim,
            }
            if bz is not None:
                rec["bind_zero"] = bz
            bones_out.append(rec)
        w_loc, w_rot, w_sca = _decompose(arm.matrix_world)
        out[p.name] = {
            "mode":   "exact",
            "node":   p.node,
            "parent": p.parent,
            "bake":   p.bake,
            "world":  _prs(w_loc, w_rot, w_sca),
            "bones":  bones_out,
        }
    return out


def collect_skin_data(context, plans, scope, warnings):
    """Per-vertex weights of meshes deformed by converted armatures, read from the
    evaluated mesh exactly as the FBX exporter writes it (armatures in REST pose).
    Weights are normalized like Blender's Armature modifier does; vertices whose
    total weight is <= 0.0001 are not deformed by Blender (empty list)."""
    dg = context.evaluated_depsgraph_get()
    skins = {}
    for o in scope:
        if o.type != 'MESH':
            continue
        mods = [m for m in o.modifiers if m.type == 'ARMATURE' and m.object is not None
                and m.object.name in plans and plans[m.object.name].bones and m.show_viewport]
        if not mods:
            continue
        if not all(m.use_vertex_groups for m in mods):
            warnings.append("'%s': Armature modifier does not use vertex groups; no skin." % o.name)
            continue
        if any(m.use_bone_envelopes for m in mods):
            warnings.append("'%s': bone envelopes are not converted, only vertex group weights." % o.name)
        # several Armature modifiers (one armature per bone, each masked by its bone's group) become one
        # Skin with all their bones: the weights blend every bone, like one Armature modifier
        plans_used = list(collections.OrderedDict((m.object.name, plans[m.object.name]) for m in mods).values())
        if len(mods) > 1:
            warnings.append("'%s': %d Armature modifiers -> one Skin with the bones of %s%s." % (
                o.name, len(mods), ", ".join("'%s'" % q.name for q in plans_used),
                "; their vertex group masks are left out (the weights blend all bones)"
                if any(m.vertex_group for m in mods) else ""))
        elif mods[0].vertex_group:
            warnings.append("'%s': the Armature modifier vertex group mask is ignored." % o.name)
        pv = {bool(m.use_deform_preserve_volume) for m in mods}
        if len(pv) > 1:
            warnings.append("'%s': Preserve Volume is on for some of its Armature modifiers: the Skin uses dual "
                            "quaternion." % o.name)
        plan = plans_used[0]
        deform = [b.name for q in plans_used for b in q.bones if b.use_deform]
        index = {}
        for i, n in enumerate(deform):
            index.setdefault(n, i)
        gnames = [g.name for g in o.vertex_groups]
        eo = o.evaluated_get(dg)
        me = eo.to_mesh(preserve_all_data_layers=True, depsgraph=dg)
        try:
            weights, static = [], 0
            for v in me.vertices:
                acc = {}
                for g in v.groups:
                    bi = index.get(gnames[g.group]) if g.group < len(gnames) else None
                    if bi is not None and g.weight > 0.0:
                        acc[bi] = acc.get(bi, 0.0) + g.weight
                tot = sum(acc.values())
                if tot <= 0.0001:
                    weights.append([])
                    static += 1
                else:
                    row = []
                    for bi in sorted(acc):
                        row += [bi, acc[bi] / tot]
                    weights.append(row)
            nverts = len(me.vertices)
        finally:
            eo.to_mesh_clear()
        # Preserve Volume = dual quaternion skinning: the Skin's DQ toggle (2.4)
        skins[o.name] = {"armature": plan.name, "armatures": [q.name for q in plans_used], "bones": deform,
                         "vertices": nverts, "static_vertices": static, "dq": any(pv), "weights": weights}
    return skins


# ─────────────────────────────────────────────────────────────────────────────
#  Scene state: save -> strip for FBX -> restore
# ─────────────────────────────────────────────────────────────────────────────

def scope_objects(context, scope):
    if scope == 'SELECTED':
        objs = [o for o in context.selected_objects]
    else:
        objs = [o for o in context.view_layer.objects if o.visible_get()]
    return [o for o in objs if o.type in FBX_TYPES]


def _sorted_parents_first(objects):
    order, seen = [], set()
    pool = set(objects)

    def visit(o):
        if o in seen:
            return
        seen.add(o)
        if o.parent is not None and o.parent in pool:
            visit(o.parent)
        order.append(o)

    for o in objects:
        visit(o)
    return order


def _basis(o):
    return {
        "rotation_mode":       o.rotation_mode,
        "location":            tuple(o.location),
        "rotation_euler":      tuple(o.rotation_euler),
        "rotation_quaternion": tuple(o.rotation_quaternion),
        "rotation_axis_angle": tuple(o.rotation_axis_angle),
        "scale":               tuple(o.scale),
    }


def _set_basis(o, b):
    o.rotation_mode = b["rotation_mode"]
    o.location = b["location"]
    o.rotation_euler = b["rotation_euler"]
    o.rotation_quaternion = b["rotation_quaternion"]
    o.rotation_axis_angle = b["rotation_axis_angle"]
    o.scale = b["scale"]


def save_state(context, scope):
    scene, vl = context.scene, context.view_layer
    st = {
        "frame": scene.frame_current,
        "subframe": scene.frame_subframe,
        "active": vl.objects.active,
        "selected": [o for o in vl.objects if o.select_get()],
        "scope": list(scope),
        "parents": {},
        "basis": {},
        "anim": {},
        "constraints": [],
    }
    for o in scope:
        st["parents"][o] = (o.parent, o.parent_type, o.parent_bone,
                            tuple(o.parent_vertices), o.matrix_parent_inverse.copy())
    for o in scene.objects:
        ad = o.animation_data
        if o in st["parents"] or (ad is not None and ad.action is not None):
            st["basis"][o] = _basis(o)
        for c in o.constraints:
            st["constraints"].append((c, c.mute))
        if o.pose is not None:
            for pb in o.pose.bones:
                for c in pb.constraints:
                    st["constraints"].append((c, c.mute))
    for o in scope:
        ad = o.animation_data
        if ad is None:
            continue
        act = ad.action
        st["anim"][o] = {
            "action": act,
            "slot": getattr(ad, "action_slot", None) if act is not None else None,
            "fake_user": act.use_fake_user if act is not None else None,
            "use_nla": ad.use_nla,
            "drivers": [(fc, fc.mute) for fc in ad.drivers],
        }
    return st


def strip_for_fbx(context, state, plans=None):
    """Mute constraints, remove animation, clear parents keeping transforms.
    Armatures converted to dummies go to REST pose, so the meshes they deform are
    exported undeformed (the bind pose of the 3ds Max Skin modifier)."""
    state.setdefault("pose_position", [])
    for p in (plans or {}).values():
        data = p.arm.data
        if data.pose_position != 'REST' and all(d is not data for d, _pp in state["pose_position"]):
            state["pose_position"].append((data, data.pose_position))
            data.pose_position = 'REST'
    for c, _mute in state["constraints"]:
        c.mute = True
    for o, a in state["anim"].items():
        ad = o.animation_data
        for fc, _mute in a["drivers"]:
            fc.mute = True
        ad.use_nla = False
        if a["action"] is not None:
            a["action"].use_fake_user = True     # never orphaned while unassigned
            ad.action = None
    context.view_layer.update()

    scope = state["scope"]
    world = {o: o.matrix_world.copy() for o in scope}
    for o in scope:
        if o.parent is not None:
            o.parent = None
            o.matrix_world = world[o]
    context.view_layer.update()

    for o in context.view_layer.objects:
        if o.select_get():
            o.select_set(False)
    for o in scope:
        o.select_set(True)
    if scope:
        context.view_layer.objects.active = scope[0]


def restore_state(context, state):
    errors = []

    def guard(label, fn):
        try:
            fn()
        except Exception as exc:                  # keep restoring the rest
            errors.append("%s: %s" % (label, exc))

    scene = context.scene
    for o, (par, ptype, pbone, pverts, pinv) in state["parents"].items():
        def _p(o=o, par=par, ptype=ptype, pbone=pbone, pverts=pverts, pinv=pinv):
            if o.parent != par:
                o.parent = par
            if par is not None:
                if o.parent_type != ptype:
                    o.parent_type = ptype
                if o.parent_bone != pbone:
                    o.parent_bone = pbone
                if tuple(o.parent_vertices) != pverts:
                    o.parent_vertices = pverts
            o.matrix_parent_inverse = pinv
        guard("parent " + o.name, _p)

    for o, a in state["anim"].items():
        def _a(o=o, a=a):
            ad = o.animation_data
            if a["action"] is not None:
                if ad.action != a["action"]:
                    ad.action = a["action"]
                slot = a["slot"]
                if slot is not None and hasattr(ad, "action_slot") and ad.action_slot != slot:
                    ad.action_slot = slot
                a["action"].use_fake_user = a["fake_user"]
            ad.use_nla = a["use_nla"]
            for fc, mute in a["drivers"]:
                fc.mute = mute
        guard("animation " + o.name, _a)

    for c, mute in state["constraints"]:
        guard("constraint " + c.name, lambda c=c, mute=mute: setattr(c, "mute", mute))

    for data, pp in state.get("pose_position", []):
        guard("pose position " + data.name, lambda data=data, pp=pp: setattr(data, "pose_position", pp))

    guard("frame", lambda: scene.frame_set(state["frame"], subframe=state["subframe"]))

    # Raw property values last: keeps exact euler angles and unkeyed edits.
    for o, b in state["basis"].items():
        guard("transform " + o.name, lambda o=o, b=b: _set_basis(o, b))

    def _sel():
        vl = context.view_layer
        for o in vl.objects:
            if o.select_get():
                o.select_set(False)
        for o in state["selected"]:
            if o.name in vl.objects:
                o.select_set(True)
        vl.objects.active = state["active"]
    guard("selection", _sel)
    guard("update", context.view_layer.update)
    return errors


def _ensure_object_mode(context):
    obj = context.view_layer.objects.active
    if obj is not None and obj.mode != 'OBJECT' and bpy.ops.object.mode_set.poll():
        prev = obj.mode
        bpy.ops.object.mode_set(mode='OBJECT')
        return obj, prev
    return None, None


def _restore_mode(context, obj, prev):
    if obj is None or prev is None:
        return
    try:
        if context.view_layer.objects.active is obj and bpy.ops.object.mode_set.poll():
            bpy.ops.object.mode_set(mode=prev)
    except Exception:
        pass


# ─────────────────────────────────────────────────────────────────────────────
#  FBX export with the agreed settings
# ─────────────────────────────────────────────────────────────────────────────

FBX_SETTINGS = dict(
    use_selection=True,
    use_visible=False,
    use_active_collection=False,
    object_types={'EMPTY', 'CAMERA', 'LIGHT', 'ARMATURE', 'MESH', 'OTHER'},
    use_custom_props=False,
    global_scale=1.0,
    apply_scale_options='FBX_SCALE_NONE',     # "All Local"
    axis_forward='Y',
    axis_up='Z',
    apply_unit_scale=True,
    use_space_transform=True,
    bake_space_transform=True,                # "Apply Transform"
    bake_anim=False,
    path_mode='AUTO',
    batch_mode='OFF',
)


def _fbx_operator_props():
    try:
        return set(bpy.ops.export_scene.fbx.get_rna_type().properties.keys())
    except Exception:
        pass
    try:
        import addon_utils
        addon_utils.enable("io_scene_fbx", default_set=True, persistent=True)
        return set(bpy.ops.export_scene.fbx.get_rna_type().properties.keys())
    except Exception:
        return None


def export_fbx(filepath, armatures=True):
    """armatures=False: armature objects are converted to 3ds Max dummies by the
    JSON, so no Blender bones or skin clusters go into the FBX."""
    valid = _fbx_operator_props()
    if valid is None:
        raise RuntimeError("The FBX exporter (io_scene_fbx) is not available.")
    kwargs = {k: v for k, v in FBX_SETTINGS.items() if k in valid}
    if not armatures and "object_types" in kwargs:
        kwargs["object_types"] = set(kwargs["object_types"]) - {'ARMATURE'}
    kwargs["filepath"] = filepath
    if "check_existing" in valid:
        kwargs["check_existing"] = False
    result = bpy.ops.export_scene.fbx(**kwargs)
    if 'FINISHED' not in result:
        raise RuntimeError("FBX export did not finish: %s" % (result,))


# ─────────────────────────────────────────────────────────────────────────────
#  Export bundle (JSON + FBX) with guaranteed scene restore
# ─────────────────────────────────────────────────────────────────────────────

def export_bundle(context, scope, json_path, fbx_path, pose_frame, convert_bones=True, bake_bones=False,
                  exact_bones=False):
    """Write JSON (and FBX if fbx_path) and restore the scene. Returns stats.
    convert_bones: armatures become 3ds Max dummies + Skin (JSON "armatures"/"skins");
    with exact_bones every bone becomes a 3ds Max bone with the bone's own axes instead."""
    t0 = time.perf_counter()
    for o in scope:
        ad = o.animation_data
        if ad is not None and ad.use_tweak_mode:
            raise RuntimeError("'%s' is in NLA tweak mode. Exit tweak mode and try again." % o.name)

    mode_obj, mode_prev = _ensure_object_mode(context)
    before = {o: o.matrix_world.copy() for o in scope}
    state = save_state(context, scope)
    exact = bool(convert_bones and exact_bones)
    stats = {"objects": len(scope), "warnings": [], "dummies": 0, "bones": 0, "skins": 0, "exact": exact}
    restore_errors = []
    try:
        context.scene.frame_set(pose_frame)
        plans = plan_rigs(scope, bake_bones, exact) if convert_bones else {}
        for p in plans.values():
            stats["warnings"] += p.warnings
        data = collect_scene_data(context, scope, pose_frame,
                                  os.path.basename(fbx_path) if fbx_path else "", plans)
        if plans:
            if exact:
                data["armatures"] = collect_exact_rig_data(context, plans, pose_frame, stats["warnings"])
            else:
                data["armatures"] = collect_rig_data(context, plans, pose_frame)
            names = set(data["objects"])
            bone_names = [b["name"] for a in data["armatures"].values() for b in a["bones"]]
            clash = sorted(set(bone_names) & names)
            if clash:
                stats["warnings"].append("Bone and object share a name (3ds Max node names clash): "
                                         + ", ".join(clash[:5]))
            seen, twice = set(), set()
            for n in bone_names:
                (twice if n in seen else seen).add(n)
            if twice:
                stats["warnings"].append("Bones with the same name in different armatures (3ds Max links "
                                         "them by name): " + ", ".join(sorted(twice)[:5]))
        if fbx_path or plans:
            strip_for_fbx(context, state, plans)
        # mesh sizes as the FBX has them (armatures in rest): 3ds Max checks its meshes against them
        dg = context.evaluated_depsgraph_get()
        for o in scope:
            rec = data["objects"].get(o.name)
            if rec is not None and o.type == 'MESH':
                bb = [Vector(c) for c in o.evaluated_get(dg).bound_box]
                rec["size"] = (bb[6] - bb[0]).length
        if plans:
            data["skins"] = collect_skin_data(context, plans, scope, stats["warnings"])
        stats["json_bytes"] = write_bridge_json(json_path, data)
        stats["keys"] = sum(len(v) for rec in data["objects"].values()
                            for ch in rec["animation"].values() for v in ch.values())
        stats["animated"] = sum(1 for rec in data["objects"].values()
                                if any(v for ch in rec["animation"].values() for v in ch.values()))
        for a in data.get("armatures", {}).values():
            stats["bones" if exact else "dummies"] += len(a["bones"])
            for b in a["bones"]:
                anim = b["zero_animation"] if exact else b["animation"]
                n = sum(len(v) for ch in anim.values() for v in ch.values())
                stats["keys"] += n
                stats["animated"] += 1 if n else 0
        stats["skins"] = len(data.get("skins", {}))
        if fbx_path:
            export_fbx(fbx_path, armatures=not plans)
    finally:
        restore_errors = restore_state(context, state)
        _restore_mode(context, mode_obj, mode_prev)

    worst = 0.0
    for o, m in before.items():
        m2 = o.matrix_world
        worst = max(worst, max(abs(m[r][c] - m2[r][c]) for r in range(4) for c in range(4)))
    stats["restore_errors"] = restore_errors
    stats["restore_deviation"] = worst
    stats["seconds"] = time.perf_counter() - t0
    return stats


# ─────────────────────────────────────────────────────────────────────────────
#  Bridge: job file + polling for the 3ds Max result
# ─────────────────────────────────────────────────────────────────────────────

_transfer = {"id": None, "state": "idle", "lines": [], "t0": 0.0, "picked": False}


def _redraw_panels():
    try:
        for win in bpy.context.window_manager.windows:
            for area in win.screen.areas:
                if area.type == 'VIEW_3D':
                    area.tag_redraw()
    except Exception:
        pass


def _set_transfer(state, *lines):
    _transfer["state"] = state
    _transfer["lines"] = [l for l in lines if l]
    for l in _transfer["lines"]:
        print("[Max Bridge]", l)
    _redraw_panels()


def send_job(fbx_path, json_path, replace, objects):
    folder = bridge_dir()
    os.makedirs(folder, exist_ok=True)
    job_id = uuid.uuid4().hex
    job = {
        "format":   JOB_FORMAT,
        "version":  JSON_VERSION,
        "id":       job_id,
        "created":  time.time(),
        "fbx":      fbx_path,
        "json":     json_path,
        "replace":  bool(replace),
        "objects":  objects,
        "blender":  bpy.app.version_string,
        "source":   bpy.data.filepath,
    }
    _write_json_atomic(os.path.join(folder, JOB_FILE), job)
    _transfer.update(id=job_id, t0=time.time(), picked=False)
    if bpy.app.timers.is_registered(_poll_result):
        bpy.app.timers.unregister(_poll_result)
    bpy.app.timers.register(_poll_result, first_interval=0.5)
    return job_id


def _poll_result():
    if _transfer["state"] != "waiting":
        return None
    folder = bridge_dir()
    job_path = os.path.join(folder, JOB_FILE)
    now = time.time()
    waited = now - _transfer["t0"]

    res = _read_json(os.path.join(folder, RESULT_FILE))
    if res and res.get("id") == _transfer["id"]:
        ok = res.get("status") == "ok"
        lines = ["3ds Max: %s" % (res.get("message") or ("done" if ok else "failed"))]
        for w in (res.get("warnings") or [])[:6]:
            lines.append("  ! " + str(w))
        _set_transfer("done" if ok else "error", *lines)
        return None

    job = _read_json(job_path) if os.path.exists(job_path) else None
    still_queued = job is not None and job.get("id") == _transfer["id"]
    if not still_queued:
        if not _transfer["picked"]:
            _transfer["picked"] = True
            _set_transfer("waiting", "3ds Max picked up the job, importing...")
    else:
        alive, _age = listener_status()
        limit = PICKUP_TIMEOUT_ONLINE if alive else PICKUP_TIMEOUT_OFFLINE
        if waited > limit:
            try:
                os.remove(job_path)
            except OSError:
                pass
            _set_transfer("error",
                          "3ds Max did not pick up the job (%.0f s)." % waited,
                          "Run BlenderMaxBridge.ms in 3ds Max and press Start listening.",
                          "Files are kept, you can import them manually.")
            return None

    if waited > RESULT_TIMEOUT:
        _set_transfer("error", "No result from 3ds Max after %.0f s." % waited)
        return None
    return 0.5


# ─────────────────────────────────────────────────────────────────────────────
#  Settings
# ─────────────────────────────────────────────────────────────────────────────

class MaxBridgeSettings(bpy.types.PropertyGroup):
    scope: EnumProperty(
        name="Objects",
        items=(('ALL', "All visible", "All objects visible in the current view layer"),
               ('SELECTED', "Selected", "Only the selected objects")),
        default='ALL',
    )
    pose_frame: IntProperty(
        name="Pose frame",
        description="Frame at which the static pose (FBX transforms and JSON values) is taken. "
                    "3ds Max reads the import at frame 0, so keep 0 unless your rest pose is elsewhere",
        default=0,
    )
    output_dir: StringProperty(
        name="Output folder",
        description="Where the FBX and JSON are written. Empty = next to the .blend file "
                    "(or the bridge folder if the file is not saved)",
        subtype='DIR_PATH',
        default="",
    )
    base_name: StringProperty(
        name="File name",
        description="Base name for the FBX and JSON files. Empty = .blend file name",
        default="",
    )
    replace_in_max: BoolProperty(
        name="Replace same-named objects in 3ds Max",
        description="Before importing, delete 3ds Max objects whose names match the exported objects, "
                    "so re-sending updates the scene instead of duplicating it",
        default=True,
    )
    bones_to_dummies: BoolProperty(
        name="Bones -> Dummies + Skin",
        description="Convert armatures: every deform bone becomes a 3ds Max Dummy (Z forward, Y up) "
                    "with the bone animation, and meshes deformed by the armature get a Skin modifier "
                    "with the painted weights. Off: armatures go into the FBX as before",
        default=True,
    )
    exact_bones: BoolProperty(
        name="Exact bones",
        description="Every bone becomes a 3ds Max bone with the Blender bone's own axes (Y along the "
                    "bone), linked like in Blender, with no armature object (root bones go under the "
                    "armature's parent; an animated armature keeps a dummy). Freeze Transform layers: "
                    "the rest pose reads as zero and the keys are Blender's pose bone values. "
                    "Off: deform bones become dummies (Z forward, Y up)",
        default=False,
    )
    bake_bones: BoolProperty(
        name="Bake bone keys every frame",
        description="Key the dummies / bones on every frame of the scene range (only axes that move). "
                    "Off: keys only where Blender has bone keys; flat, linear and constant curves "
                    "match exactly, other curve shapes follow 3ds Max interpolation between keys. "
                    "Bones with constraints or drivers are always baked",
        default=False,
    )


# ─────────────────────────────────────────────────────────────────────────────
#  Operators
# ─────────────────────────────────────────────────────────────────────────────

def _run(op, context, send):
    s = context.scene.max_bridge
    scope = scope_objects(context, s.scope)
    if not scope:
        op.report({'WARNING'}, "No objects to export (check the 'Objects' setting).")
        return {'CANCELLED'}
    folder, base = _resolve_output(s)
    try:
        os.makedirs(folder, exist_ok=True)
    except OSError as exc:
        op.report({'ERROR'}, "Cannot create output folder: %s" % exc)
        return {'CANCELLED'}
    fbx_path = os.path.join(folder, base + ".fbx")
    json_path = os.path.join(folder, base + ".json")

    if send and s.bones_to_dummies and s.exact_bones:
        alive, _age = listener_status()
        ver = listener_version() if alive else None
        if ver is not None and ver < EXACT_MIN_LISTENER:
            msg = ("Exact bones need BlenderMaxBridge.ms %d.%d or newer in 3ds Max (the listener runs %d.%d)."
                   % (EXACT_MIN_LISTENER + ver))
            op.report({'ERROR'}, msg)
            _set_transfer("error", msg)
            return {'CANCELLED'}

    if send and _transfer["state"] == "waiting":
        _set_transfer("idle")                     # previous job is replaced

    try:
        stats = export_bundle(context, scope, json_path, fbx_path, s.pose_frame, s.bones_to_dummies, s.bake_bones,
                              s.exact_bones)
    except Exception as exc:
        op.report({'ERROR'}, "Export failed: %s" % exc)
        _set_transfer("error", "Export failed: %s" % exc)
        return {'CANCELLED'}

    summary = "%d objects (%d animated, %d keys), %.1f s" % (
        stats["objects"], stats["animated"], stats["keys"], stats["seconds"])
    if stats["dummies"]:
        summary += ", %d bones -> dummies, %d skinned" % (stats["dummies"], stats["skins"])
    if stats["bones"]:
        summary += ", %d exact bones, %d skinned" % (stats["bones"], stats["skins"])
    warn = list(stats["warnings"])
    if stats["restore_errors"]:
        warn.append("Scene restore problems: " + "; ".join(stats["restore_errors"][:3]))
    if stats["restore_deviation"] > 1e-4:
        warn.append("Scene restore check: objects moved by up to %.6f" % stats["restore_deviation"])
    for w in warn:
        op.report({'WARNING'}, w)

    if not send:
        _set_transfer("done", "Exported " + summary, fbx_path, json_path, *warn)
        op.report({'INFO'}, "Exported %s -> %s" % (summary, folder))
        return {'FINISHED'}

    try:
        send_job(fbx_path, json_path, s.replace_in_max, stats["objects"])
    except OSError as exc:
        op.report({'ERROR'}, "Cannot write job file: %s" % exc)
        _set_transfer("error", "Cannot write job file: %s" % exc)
        return {'CANCELLED'}
    alive, _age = listener_status()
    _set_transfer("waiting",
                  "Exported " + summary,
                  "Waiting for 3ds Max..." if alive else
                  "Waiting for 3ds Max (listener looks offline)...",
                  *warn)
    op.report({'INFO'}, "Sent to 3ds Max: " + summary)
    return {'FINISHED'}


class MAXBRIDGE_OT_send(bpy.types.Operator):
    """Export FBX + JSON, restore the scene and import everything in 3ds Max"""
    bl_idname = "max_bridge.send"
    bl_label = "Send to 3ds Max"
    bl_options = {'REGISTER', 'UNDO'}

    def execute(self, context):
        return _run(self, context, send=True)


class MAXBRIDGE_OT_export_files(bpy.types.Operator):
    """Export FBX + JSON with the bridge settings, without notifying 3ds Max"""
    bl_idname = "max_bridge.export_files"
    bl_label = "Export FBX + JSON only"
    bl_options = {'REGISTER', 'UNDO'}

    def execute(self, context):
        return _run(self, context, send=False)


class MAXBRIDGE_OT_open_folder(bpy.types.Operator):
    """Open the output folder"""
    bl_idname = "max_bridge.open_folder"
    bl_label = "Open output folder"

    def execute(self, context):
        folder, _base = _resolve_output(context.scene.max_bridge)
        os.makedirs(folder, exist_ok=True)
        bpy.ops.wm.path_open(filepath=folder)
        return {'FINISHED'}


class EXPORT_OT_blender_max_json(bpy.types.Operator, ExportHelper):
    """Write only the JSON (hierarchy, rotation orders, transforms, animation, collections)"""
    bl_idname = "export_scene.blender_max_json"
    bl_label = "Export Blender JSON"
    bl_options = {'REGISTER', 'UNDO'}

    filename_ext = ".json"
    filter_glob: StringProperty(default="*.json", options={'HIDDEN'})
    use_selection: BoolProperty(name="Selected Objects", default=True)

    def execute(self, context):
        scope = scope_objects(context, 'SELECTED' if self.use_selection else 'ALL')
        if not scope:
            self.report({'WARNING'}, "No objects to export.")
            return {'CANCELLED'}
        try:
            s = context.scene.max_bridge
            stats = export_bundle(context, scope, self.filepath, None, s.pose_frame, s.bones_to_dummies,
                                  s.bake_bones, s.exact_bones)
        except Exception as exc:
            self.report({'ERROR'}, "Export failed: %s" % exc)
            return {'CANCELLED'}
        self.report({'INFO'}, "Exported %d objects to %s" % (stats["objects"], self.filepath))
        return {'FINISHED'}




# ═════════════════════════════════════════════════════════════════════════════
#  PART 2   3ds Max -> Blender  (Import from 3ds Max)
# ═════════════════════════════════════════════════════════════════════════════

FORMAT_NAME = "max2blender"
FORMAT_VERSION = 3
BIN_MAGIC = b"M2BBIN1\x00"
LOG_TEXT = "Max to Blender Import"
EULER_ORDERS = {"XYZ", "XZY", "YXZ", "YZX", "ZXY", "ZYX"}

# tolerances of the checks (meters / matrix units)
POS_TOL = 1e-4          # 0.1 mm
AXIS_TOL = 1e-4         # matrix axis error (relative)
BBOX_TOL_REL = 1e-4
# 3ds Max and Blender both compute matrices in 32-bit floats: a node far down a chain of large
# translations (a camera image plane 1.3 km in front of a camera 1.3 km away) carries rounding of
# a few float32 steps of those distances. Position tolerance: POS_TOL + FLOAT_REL * chain length.
FLOAT_REL = 1e-6
# two 3ds Max normals closer than this (dot product) are one normal: no hard edge between them
NRM_SAME = 1.0 - 1e-6
SKIN_TOL_REL = 1e-4     # skin check: deviation relative to the mesh size
# 3ds Max nodes that become armature bones (their objects go) when a Skin uses them: helpers, and
# 3ds Max's own skeleton objects
SKELETON_KINDS = {"dummy", "point", "helper"}
SKELETON_CLASSES = {"BoneGeometry", "Biped_Object", "CATBone", "HubObject"}
# bone frame = node frame @ C. The Blender -> 3ds Max bridge makes a dummy from a bone with the bone
# axes turned +90 degrees about X (dummy X = bone X, Y = bone Z, Z = -bone Y); a bone made from a
# dummy turns them back, so a round trip gives the same dummies. 3ds Max bones point along their X
# axis, and so does their Blender bone (bone Y = node X, bone Z = node Z).
BONE_FROM_DUMMY = Matrix.Rotation(math.radians(-90.0), 4, 'X')
BONE_FROM_MAX_BONE = Matrix.Rotation(math.radians(-90.0), 4, 'Z')


def max_bone_frame(rec):
    """Bone frame of a 3ds Max bone (BoneGeometry, Biped, CAT) relative to its node: the Blender bone
    points where the bone geometry points. 3ds Max builds it along the object's X axis, so bone Y =
    node X; an object offset that turns the geometry turns the bone with it. Bones made by the
    Blender -> 3ds Max bridge's "Exact bones" carry the Blender bone's axes on the node, with the
    geometry turned onto Y: they come back with exactly those axes (bone frame = node frame)."""
    off = rec.get("offset")
    if not off:
        return BONE_FROM_MAX_BONE.copy()
    # 3ds Max rows (object axes in node space) -> Blender columns
    m = Matrix([[float(off[c][r]) for c in range(3)] for r in range(3)])
    if m.determinant() <= 1e-12:
        return BONE_FROM_MAX_BONE.copy()                  # mirrored or flat offset: the plain rule
    return m.normalized().to_quaternion().to_matrix().to_4x4() @ BONE_FROM_MAX_BONE


_AXIS_CODES = {"x": (0, 1.0), "-x": (0, -1.0), "y": (1, 1.0), "-y": (1, -1.0), "z": (2, 1.0), "-z": (2, -1.0)}


def dummy_bone_frame(rec):
    """Bone frame of a dummy / point relative to its node. The Blender -> 3ds Max bridge (2.5 on) writes
    the user property BlenderBoneAxes = <bone X>,<bone Y>,<bone Z> as dummy axes (x, -z, y for its
    plain dummies), so a bone comes back with the axes it had in Blender also when the dummy's axes
    were turned (Y up, Z to the front); without it, bone Y = dummy -Z."""
    m = re.search(r"(?im)^\s*BlenderBoneAxes\s*=\s*([^\r\n]+)", rec.get("props") or "")
    if m:
        codes = [c.strip().lower() for c in m.group(1).split(",")]
        if len(codes) == 3 and all(c in _AXIS_CODES for c in codes):
            cols = []
            for c in codes:
                v = [0.0, 0.0, 0.0]
                i, s = _AXIS_CODES[c]
                v[i] = s
                cols.append(v)
            C = Matrix([[cols[j][i] for j in range(3)] for i in range(3)])
            if abs(C.determinant() - 1.0) < 1e-6:
                return C.to_4x4()
    return BONE_FROM_DUMMY.copy()


def latest_export():
    """JSON path written by 3ds Max into <exchange folder>/latest.json, or None."""
    ptr = os.path.join(exchange_dir(), "latest.json")
    try:
        with open(ptr, "r", encoding="utf-8") as fh:
            path = json.load(fh).get("json", "")
        return path if path and os.path.isfile(path) else None
    except Exception:
        return None


# ─────────────────────────────────────────────────────────────────────────────
#  Report: log file + text block
# ─────────────────────────────────────────────────────────────────────────────

class Report:
    def __init__(self, path=None):
        self.t0 = time.time()
        self.lines = []
        self.warnings = 0
        self.errors = 0
        self.fh = None
        if path:
            try:
                self.fh = open(path, "w", encoding="utf-8")
            except Exception:
                self.fh = None

    def log(self, msg, console=False):
        line = "[%9.3f] %s" % (time.time() - self.t0, msg)
        self.lines.append(line)
        if self.fh:
            self.fh.write(line + "\n")
            self.fh.flush()
        if console:
            print("MaxToBlender", line)

    def warning(self, msg):
        self.warnings += 1
        self.log("WARNING " + msg, console=self.warnings <= 20)

    def error(self, msg):
        self.errors += 1
        self.log("ERROR " + msg, console=True)

    def close(self):
        if self.fh:
            self.fh.close()
            self.fh = None
        try:
            txt = bpy.data.texts.get(LOG_TEXT) or bpy.data.texts.new(LOG_TEXT)
            txt.clear()
            txt.write("\n".join(self.lines) + "\n")
        except Exception:
            pass


# ─────────────────────────────────────────────────────────────────────────────
#  Math: 3ds Max matrices (row vectors) -> Blender (column vectors)
# ─────────────────────────────────────────────────────────────────────────────

def max_tm(rows, u):
    """3ds Max matrix3 rows [X axis, Y axis, Z axis, translation] -> Blender 4x4;
    translation scaled by u (unit factor)."""
    r1, r2, r3, t = rows
    return Matrix(((r1[0], r2[0], r3[0], t[0] * u),
                   (r1[1], r2[1], r3[1], t[1] * u),
                   (r1[2], r2[2], r3[2], t[2] * u),
                   (0.0, 0.0, 0.0, 1.0)))


def decompose(m):
    """loc, 3x3 rotation, scale; a mirrored matrix gets all three scales negative
    (the way 3ds Max and Blender both decompose it)."""
    loc = m.to_translation()
    m3 = m.to_3x3()
    s = Vector((m3.col[0].length, m3.col[1].length, m3.col[2].length))
    if m3.determinant() < 0.0:
        s = -s
    r = m3.copy()
    for i in range(3):
        if abs(s[i]) > 1e-30:
            r.col[i] = m3.col[i] / s[i]
    return loc, r, s


def compose(loc, rot3, scale):
    m = rot3.to_4x4() @ Matrix.Diagonal((scale[0], scale[1], scale[2], 1.0))
    m.translation = loc
    return m


def tm_error(a, b):
    """(translation distance, largest axis difference relative to the axis length)."""
    dpos = (a.translation - b.translation).length
    dax = 0.0
    for i in range(3):
        ca = a.col[i].xyz
        cb = b.col[i].xyz
        dax = max(dax, (ca - cb).length / max(cb.length, 1e-9))
    return dpos, dax


# ─────────────────────────────────────────────────────────────────────────────
#  Export file
# ─────────────────────────────────────────────────────────────────────────────

# A number followed by L (64-bit) or P (pointer): how MAXScript prints some integers;
# the 0.2 script wrote mesh offsets that way ("at":8L).
_INT_SUFFIX = re.compile(r'(?<=[:\[,])(-?\d+)[LP](?=[,\]}])')


def generator_version(doc):
    """(major, minor) of the MaxToBlenderBridge script that wrote the file, or None."""
    m = re.match(r"\s*MaxToBlenderBridge\s+(\d+)\.(\d+)", str(doc.get("generator") or ""))
    return (int(m.group(1)), int(m.group(2))) if m else None


def load_export(json_path, report=None):
    with open(json_path, "r", encoding="utf-8") as fh:
        text = fh.read()
    try:
        doc = json.loads(text)
    except json.JSONDecodeError:
        fixed, n = _INT_SUFFIX.subn(r"\1", text)
        doc = json.loads(fixed)
        if report is not None:
            report.log("file from an older script: %d integers written as 8L / 8P read as plain numbers" % n)
    if doc.get("format") != FORMAT_NAME:
        raise ValueError("not a 3ds Max -> Blender bridge file (format %r)" % doc.get("format"))
    if int(doc.get("version", 0)) > FORMAT_VERSION:
        raise ValueError("file format %s is newer than this add-on (%d): update the add-on"
                         % (doc.get("version"), FORMAT_VERSION))
    bin_path = os.path.join(os.path.dirname(json_path), doc.get("bin", ""))
    blob = b""
    if doc.get("meshes"):
        with open(bin_path, "rb") as fh:
            blob = fh.read()
        if blob[:8] != BIN_MAGIC:
            raise ValueError("%s is not a bridge geometry file" % bin_path)
    return doc, blob


# ─────────────────────────────────────────────────────────────────────────────
#  Meshes
# ─────────────────────────────────────────────────────────────────────────────

def _read(blob, dtype, count, offset):
    arr = np.frombuffer(blob, dtype=dtype, count=count, offset=offset)
    return arr, offset + arr.nbytes


def _edge_lookup(mesh_edges_keys, wanted_keys):
    """Index of every wanted key in mesh_edges_keys (all wanted keys exist)."""
    order = np.argsort(mesh_edges_keys, kind="stable")
    pos = np.searchsorted(mesh_edges_keys, wanted_keys, sorter=order)
    pos = np.clip(pos, 0, len(order) - 1)
    idx = order[pos]
    ok = mesh_edges_keys[idx] == wanted_keys
    return idx, ok


def _set_edge_sharp(me, sharp):
    try:
        me.edges.foreach_set("use_edge_sharp", sharp)
    except Exception:
        attr = me.attributes.get("sharp_edge") or me.attributes.new("sharp_edge", 'BOOLEAN', 'EDGE')
        attr.data.foreach_set("value", sharp)


def _set_face_smooth(me, smooth):
    try:
        me.polygons.foreach_set("use_smooth", smooth)
    except Exception:
        attr = me.attributes.get("sharp_face") or me.attributes.new("sharp_face", 'BOOLEAN', 'FACE')
        attr.data.foreach_set("value", ~smooth)


def _srgb_to_linear(c):
    c = np.asarray(c, dtype=np.float32)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4).astype(np.float32)


def map_channel_names(props):
    """{channel: name} from 3ds Max user properties ("MapChannel:1 = UVMap", written by the FBX
    importer and the Channel Info names)."""
    out = {}
    for m in re.finditer(r"MapChannel\s*:\s*(\d+)\s*=\s*([^\r\n]+)", props or ""):
        nm = m.group(2).strip()
        if nm:
            out[int(m.group(1))] = nm[:63]
    return out


def build_mesh(name, rec, blob, u, opts, report, use_normals=True, channel_names=None):
    """Blender mesh from one blob of the .bin file. Returns (mesh, slot material IDs,
    dissolved edges, shading source: "normals" / "edges" / "groups" / "flat").
    Shading: with 3ds Max normals in the file (and use_normals), hard edges are where the
    normals of the two faces differ, every face is smooth, and with opts.shading 'NORMALS'
    the normals themselves become custom split normals; without them the smoothing groups
    decide (hard where two faces share no group, faces in group 0 flat)."""
    nv, nf = int(rec["nv"]), int(rec["nf"])
    off = int(rec["at"])
    verts, off = _read(blob, "<f4", nv * 3, off)
    faces, off = _read(blob, "<u4", nf * 5, off)
    verts = verts.reshape(nv, 3).astype(np.float64) * u
    faces = faces.reshape(nf, 5)
    tris = faces[:, :3].view(np.int32).astype(np.int64)
    sg = faces[:, 3].astype(np.uint32)
    matid = (faces[:, 4] & 0xFFFF).astype(np.int64) + 1
    vis = ((faces[:, 4] >> 16) & 7).astype(np.int64)
    maps = []
    for ch, nmv in rec.get("maps", []):
        mv, off = _read(blob, "<f4", int(nmv) * 3, off)
        mf, off = _read(blob, "<i4", nf * 3, off)
        maps.append((int(ch), mv.reshape(-1, 3), mf.reshape(nf, 3).astype(np.int64)))
    shading = getattr(opts, "shading", 'NORMALS')
    # 3ds Max normals: a table (pivot space) and one index per triangle corner
    ntab = ncorner = None
    nrm = rec.get("nrm")
    if nrm and use_normals and shading in ('NORMALS', 'EDGES'):
        nn = int(nrm[1])
        ntab, o2 = _read(blob, "<f4", nn * 3, int(nrm[0]))
        ncorner, _ = _read(blob, "<i4", nf * 3, o2)
        ntab = ntab.reshape(nn, 3).astype(np.float64)
        ln = np.linalg.norm(ntab, axis=1)
        ntab = ntab / np.where(ln > 1e-20, ln, 1.0)[:, None]
        ncorner = ncorner.reshape(nf, 3).astype(np.int64)

    # drop triangles that Blender can't hold (index out of range, repeated vertex)
    valid = np.all((tris >= 0) & (tris < nv), axis=1)
    valid &= (tris[:, 0] != tris[:, 1]) & (tris[:, 1] != tris[:, 2]) & (tris[:, 2] != tris[:, 0])
    dropped = int(nf - valid.sum())
    if dropped:
        report.log("mesh '%s': %d degenerate triangles skipped" % (name, dropped))
        tris, sg, matid, vis = tris[valid], sg[valid], matid[valid], vis[valid]
        maps = [(ch, mv, mf[valid]) for ch, mv, mf in maps]
        if ncorner is not None:
            ncorner = ncorner[valid]
    nt = len(tris)
    cn = None                                   # 3ds Max normal of every triangle corner
    if ncorner is not None:
        badc = (ncorner < 0) | (ncorner >= len(ntab))
        if badc.any():
            report.warning("mesh '%s': %d corners point outside the normal table; smoothing groups used"
                           % (name, int(badc.sum())))
        else:
            cn = ntab[ncorner.ravel()]

    me = bpy.data.meshes.new(name)
    me.vertices.add(nv)
    me.vertices.foreach_set("co", verts.astype(np.float32).ravel())
    me.loops.add(nt * 3)
    me.loops.foreach_set("vertex_index", tris.astype(np.int32).ravel())
    me.polygons.add(nt)
    me.polygons.foreach_set("loop_start", np.arange(0, nt * 3, 3, dtype=np.int32))
    try:
        me.polygons.foreach_set("loop_total", np.full(nt, 3, dtype=np.int32))   # Blender 3.6 - 3.x
    except (AttributeError, TypeError, RuntimeError):
        pass                                                                    # 4.0+: derived
    me.update(calc_edges=True)

    # the 3ds Max smoothing groups, kept on the faces (creases for live TurboSmooth)
    if nt:
        sga = me.attributes.new("max_sg", 'INT', 'FACE')
        sga.data.foreach_set("value", np.ascontiguousarray(sg, dtype=np.uint32).view(np.int32))

    # material IDs -> slots (one slot per ID used, ascending)
    ids = np.unique(matid) if nt else np.array([1], dtype=np.int64)
    if nt:
        me.polygons.foreach_set("material_index", np.searchsorted(ids, matid).astype(np.int32))
    for _ in ids:
        me.materials.append(None)

    # map channels: 1.. -> UV maps (named as in 3ds Max), 0 -> vertex colors "Col" (with the
    # vertex alpha of channel -2), -1 -> illumination "Illum"
    first_uv = None
    per_corner = {}
    for ch, mv, mf in maps:
        if len(mv) == 0:
            continue
        per_corner[ch] = mv[np.clip(mf, 0, len(mv) - 1).ravel()]
    alpha = per_corner.get(-2)
    for ch in sorted(per_corner):
        vals = per_corner[ch]
        if ch in (0, -1) or (ch == -2 and 0 not in per_corner):
            col = np.ones((nt * 3, 4), dtype=np.float32)
            if ch != -2:
                col[:, :3] = np.clip(vals, 0.0, 1.0)
            if ch != -1 and alpha is not None:
                col[:, 3] = np.clip(alpha[:, 0], 0.0, 1.0)
            cname = "Illum" if ch == -1 else "Col"
            try:
                attr = me.color_attributes.new(cname, 'BYTE_COLOR', 'CORNER')
                try:
                    attr.data.foreach_set("color_srgb", col.ravel())
                except (AttributeError, TypeError):
                    lin = col.copy()
                    lin[:, :3] = _srgb_to_linear(col[:, :3])
                    attr.data.foreach_set("color", lin.ravel())
            except Exception as ex:
                report.warning("mesh '%s': vertex colors (channel %d) not set (%s)" % (name, ch, ex))
        elif ch > 0:
            uvname = (channel_names or {}).get(ch) or "UVChannel_%d" % ch
            uv = np.ascontiguousarray(vals[:, :2], dtype=np.float32)
            if len(me.uv_layers) < 8:
                uvl = me.uv_layers.new(name=uvname)
                uvl.data.foreach_set("uv", uv.ravel())
                uvname = uvl.name
                if first_uv is None:
                    first_uv = uvl
            else:
                # Blender holds 8 UV maps (a 2D corner attribute would count as one more): further
                # channels stay as 3D corner attributes (U, V, W) for the Attribute node
                attr = me.attributes.new(uvname, 'FLOAT_VECTOR', 'CORNER')
                attr.data.foreach_set("vector", np.ascontiguousarray(vals[:, :3], dtype=np.float32).ravel())
                report.log("mesh '%s': map channel %d kept as the corner attribute '%s' (U, V, W; Blender holds "
                           "8 UV maps)" % (name, ch, attr.name))
                continue
            if np.abs(vals[:, 2]).max() > 1e-6:
                wattr = me.attributes.new(uvname + "_W", 'FLOAT', 'CORNER')
                wattr.data.foreach_set("value", np.ascontiguousarray(vals[:, 2], dtype=np.float32))
    if first_uv is not None:
        me.uv_layers.active = first_uv
        first_uv.active_render = True
    if nt:
        mattr = me.attributes.new("max_mat_id", 'INT', 'FACE')
        mattr.data.foreach_set("value", matid.astype(np.int32))

    # shading: smooth faces; hard edges where the 3ds Max normals of the two faces differ
    # (or, without normals, where they share no smoothing group)
    smoothing = shading != 'FLAT'
    if nt and smoothing:
        _set_face_smooth(me, np.ones(nt, bool) if cn is not None else sg != 0)
    a = tris
    b = np.roll(tris, -1, axis=1)          # edges v1-v2, v2-v3, v3-v1 = 3ds Max edges 1, 2, 3
    lo = np.minimum(a, b).ravel()
    hi = np.maximum(a, b).ravel()
    ekey = lo * nv + hi
    eface = np.repeat(np.arange(nt), 3)
    evis = ((vis[:, None] >> np.arange(3)) & 1).ravel()
    order = np.argsort(ekey, kind="stable")
    ks = ekey[order]
    if nt:
        starts = np.flatnonzero(np.r_[True, ks[1:] != ks[:-1]])
        counts = np.diff(np.r_[starts, len(ks)])
    else:
        starts = counts = np.zeros(0, dtype=np.int64)
    two = starts[counts == 2]
    ca, cb = order[two], order[two + 1]
    fa, fb = eface[ca], eface[cb]
    nsplit = None
    if cn is not None and len(two):
        # edge slot k of a triangle runs from its corner k to corner k+1; match the other
        # triangle's corners to the same two vertices and compare the normals there
        ka, kb = ca % 3, cb % 3
        tf = tris.ravel()
        a0, a1 = fa * 3 + ka, fa * 3 + (ka + 1) % 3
        b0, b1 = fb * 3 + kb, fb * 3 + (kb + 1) % 3
        same = tf[a0] == tf[b0]
        d0 = np.einsum("ij,ij->i", cn[a0], cn[np.where(same, b0, b1)])
        d1 = np.einsum("ij,ij->i", cn[a1], cn[np.where(same, b1, b0)])
        nsplit = (d0 < NRM_SAME) | (d1 < NRM_SAME)
    sharp_keys = []
    if smoothing and len(two):
        sharp2 = nsplit if nsplit is not None else (sg[fa] & sg[fb]) == 0
        sharp_keys.append(ekey[ca][sharp2])
    many = starts[counts > 2]
    if smoothing and len(many):
        sharp_keys.append(ekey[order[many]])
    me_ev = np.empty(len(me.edges) * 2, dtype=np.int64)
    me.edges.foreach_get("vertices", me_ev)
    me_ev = me_ev.reshape(-1, 2)
    me_keys = np.minimum(me_ev[:, 0], me_ev[:, 1]) * nv + np.maximum(me_ev[:, 0], me_ev[:, 1])
    if sharp_keys:
        want = np.concatenate(sharp_keys)
        if len(want):
            idx, ok = _edge_lookup(me_keys, want)
            sharp = np.zeros(len(me.edges), dtype=bool)
            sharp[idx[ok]] = True
            _set_edge_sharp(me, sharp)
    if hasattr(me, "use_auto_smooth"):                       # Blender 3.6 - 4.0
        me.use_auto_smooth = True
        me.auto_smooth_angle = math.pi
    custom = cn is not None and shading == 'NORMALS'
    if custom:
        # the corner normals ride along through the polygon rebuild as a corner attribute
        tmp = me.attributes.new("_m2b_normal", 'FLOAT_VECTOR', 'CORNER')
        tmp.data.foreach_set("vector", np.ascontiguousarray(cn, dtype=np.float32).ravel())

    # quads / n-gons: dissolve edges hidden on both triangles (same material and group,
    # the same 3ds Max normals at both ends)
    n_dissolve = 0
    if opts.rebuild_polygons and len(two):
        dis = (evis[ca] == 0) & (evis[cb] == 0) & (matid[fa] == matid[fb]) & (sg[fa] == sg[fb]) & (fa != fb)
        if nsplit is not None:
            dis &= ~nsplit
        if dis.any():
            idx, ok = _edge_lookup(me_keys, ekey[ca][dis])
            idx = np.unique(idx[ok])
            n_dissolve = len(idx)
            bm = bmesh.new()
            bm.from_mesh(me)
            bm.edges.ensure_lookup_table()
            edges = [bm.edges[int(i)] for i in idx]
            bmesh.ops.dissolve_edges(bm, edges=edges, use_verts=False, use_face_split=False)
            bm.to_mesh(me)
            bm.free()
    if custom:
        attr = me.attributes.get("_m2b_normal")
        lv = np.empty(len(me.loops) * 3, np.float32)
        attr.data.foreach_get("vector", lv)
        me.attributes.remove(attr)
        lv = lv.reshape(-1, 3).astype(np.float64)
        ln = np.linalg.norm(lv, axis=1)
        lv = lv / np.where(ln > 1e-20, ln, 1.0)[:, None]
        me.normals_split_custom_set(lv.tolist())
    me.update()
    source = "flat" if not smoothing else ("normals" if custom else ("edges" if cn is not None else "groups"))
    return me, [int(i) for i in ids], n_dissolve, source


# ─────────────────────────────────────────────────────────────────────────────
#  Live modifiers (Shell / TurboSmooth from the top of a 3ds Max stack)
# ─────────────────────────────────────────────────────────────────────────────

def _edge_faces(me):
    """Faces of every edge: (face 0, face 1, number of faces); faces are -1 unless
    the edge has exactly two."""
    ne, nl, npoly = len(me.edges), len(me.loops), len(me.polygons)
    le = np.empty(nl, np.int64)
    me.loops.foreach_get("edge_index", le)
    ls = np.empty(npoly, np.int64)
    me.polygons.foreach_get("loop_start", ls)
    lt = np.empty(npoly, np.int64)
    me.polygons.foreach_get("loop_total", lt)
    loop_ids = np.repeat(ls, lt) + (np.arange(nl) - np.repeat(np.cumsum(lt) - lt, lt))
    lf = np.empty(nl, np.int64)
    lf[loop_ids] = np.repeat(np.arange(npoly), lt)
    cnt = np.bincount(le, minlength=ne)
    order = np.argsort(le, kind="stable")
    first = np.r_[0, np.cumsum(cnt)[:-1]]
    f0 = np.full(ne, -1, np.int64)
    f1 = np.full(ne, -1, np.int64)
    two = cnt == 2
    f0[two] = lf[order[first[two]]]
    f1[two] = lf[order[first[two] + 1]]
    return f0, f1, cnt


def set_edge_creases(me, values):
    """Edge creases on every Blender version; returns where they went."""
    values = np.ascontiguousarray(values, dtype=np.float32)
    if bpy.app.version >= (4, 0, 0):
        attr = me.attributes.get("crease_edge") or me.attributes.new("crease_edge", 'FLOAT', 'EDGE')
        attr.data.foreach_set("value", values)
        return "crease_edge"
    try:                                                   # Blender 3.x
        me.edges.foreach_set("crease", values)
        back = np.empty(len(values), np.float32)
        me.edges.foreach_get("crease", back)
        if np.allclose(back, values):
            return "MeshEdge.crease"
    except (AttributeError, TypeError, RuntimeError):
        pass
    bm = bmesh.new()
    bm.from_mesh(me)
    layer = bm.edges.layers.crease.verify()
    bm.edges.ensure_lookup_table()
    for i in np.flatnonzero(values):
        bm.edges[int(i)][layer] = float(values[i])
    bm.to_mesh(me)
    bm.free()
    return "bmesh crease layer"


def prepare_live_mesh(me, live):
    """Creases and shading of a mesh under live modifiers, from the 3ds Max smoothing
    groups. Returns the number of creased edges."""
    ts = [m.get("params") or {} for m in live if m.get("class") == "TurboSmooth"]
    npoly, ne = len(me.polygons), len(me.edges)
    if npoly == 0:
        return 0
    sg = np.zeros(npoly, np.int64)
    sga = me.attributes.get("max_sg")
    if sga is not None:
        tmp = np.empty(npoly, np.int32)
        sga.data.foreach_get("value", tmp)
        sg = tmp.view(np.uint32).astype(np.int64)
    mat = np.empty(npoly, np.int32)
    me.polygons.foreach_get("material_index", mat)
    f0, f1, cnt = _edge_faces(me)
    two = cnt == 2
    sep_sg = np.zeros(ne, bool)
    sep_mat = np.zeros(ne, bool)
    sep_sg[two] = (sg[f0[two]] & sg[f1[two]]) == 0
    sep_mat[two] = mat[f0[two]] != mat[f1[two]]
    nonman = cnt > 2
    crease = np.zeros(ne, np.float32)
    _, base_sg, _, top_base = live_seams(live)
    if base_sg:
        crease[sep_sg | nonman] = 1.0
    if any(t.get("sepByMats") for t in ts):
        crease[sep_mat | nonman] = 1.0
    if crease.any():
        set_edge_creases(me, crease)
    if ts and ts[-1].get("smoothResult", True):
        # Smooth Result: every face smooth; hard edges stay only where TurboSmooth separates
        top = ts[-1]
        _set_face_smooth(me, np.ones(npoly, bool))
        sharp = np.zeros(ne, bool)
        if top_base:
            sharp |= sep_sg | nonman
        if top.get("sepByMats"):
            sharp |= sep_mat | nonman
        _set_edge_sharp(me, sharp)
    top = live[-1] if live else None
    if top and top.get("class") == "Shell" and (top.get("params") or {}).get("autosmooth", True) \
            and hasattr(me, "use_auto_smooth"):
        # Shell's Auto Smooth Edge (Blender 3.6 - 4.0): the rim is hard above the angle
        me.use_auto_smooth = True
        me.auto_smooth_angle = math.radians(float((top.get("params") or {}).get("autoSmoothAngle", 45.0)))
    return int(np.count_nonzero(crease))


def _smooth_by_angle_group():
    """Blender's own "Smooth by Angle" node group (4.1+), appended once."""
    ng = bpy.data.node_groups.get("Smooth by Angle")
    if ng is not None:
        return ng
    root = bpy.utils.system_resource('DATAFILES')
    for rel in (("assets", "geometry_nodes", "smooth_by_angle.blend"),
                ("assets", "nodes", "geometry_nodes_essentials.blend")):
        path = os.path.join(root, *rel)
        if not os.path.isfile(path):
            continue
        with bpy.data.libraries.load(path, link=False) as (src, dst):
            if "Smooth by Angle" not in src.node_groups:
                continue
            dst.node_groups = ["Smooth by Angle"]
        for ng in dst.node_groups:
            if ng is not None:
                return ng
    return None


def _set_group_input(mod, ng, name, value):
    try:
        for item in ng.interface.items_tree:
            if getattr(item, "in_out", None) == 'INPUT' and item.name == name:
                mod[item.identifier] = value
                return True
    except AttributeError:
        pass
    return False


def live_seams(live):
    """Where the TurboSmooths of a run (lowest first) separate faces, as 3ds Max does it.
    "Separate by Smoothing Groups" keeps the seams of the groups the TurboSmooth gets: the mesh's
    own groups until a TurboSmooth with Smooth Result gives every face one group (nothing left to
    separate above it), the rim of a Shell (its own groups) above a Shell. Material IDs survive.
    Returns (use creases per modifier, crease the mesh's own group seams, crease the rim of each
    Shell per modifier, the top TurboSmooth separates the mesh's own group seams)."""
    uses, rims = [], []
    base_sg = False
    top_base = False
    own, rim = True, False
    for k, m in enumerate(live):
        p = m.get("params") or {}
        uses.append(False)
        rims.append(False)
        if m.get("class") == "TurboSmooth":
            sep_sg = bool(p.get("sepBySmGroups"))
            uses[k] = bool((sep_sg and (own or rim)) or p.get("sepByMats"))
            if sep_sg and own:
                base_sg = True
            if sep_sg and rim:
                for j in range(k):
                    if live[j].get("class") == "Shell":
                        rims[j] = True
            top_base = sep_sg and own
            if p.get("smoothResult", True):
                own = rim = False
        elif m.get("class") == "Shell":
            rim = True
    return uses, base_sg, rims, top_base


def add_live_modifiers(obj, live, u, notes):
    """Blender modifiers for the 3ds Max run, lowest first."""
    seps, _, rims, _ = live_seams(live)
    for k, m in enumerate(live):
        cls = m.get("class")
        p = m.get("params") or {}
        name = m.get("name") or cls
        if cls == "TurboSmooth":
            md = obj.modifiers.new(name, 'SUBSURF')
            it = int(p.get("iterations", 1))
            rit = int(p.get("renderIterations", it)) if p.get("useRenderIterations") else it
            if it > 6 or rit > 6:
                notes.add("TurboSmooth iterations above 6 set to 6")
            md.levels = max(0, min(6, it))
            md.render_levels = max(0, min(6, rit))
            md.use_limit_surface = False               # 3ds Max keeps the subdivided cage
            # the seam creases are for the levels that separate there; Blender carries a crease up
            # through every level, so the others must not see it
            md.use_creases = seps[k]
            md.boundary_smooth = 'ALL'
            md.show_only_control_edges = bool(p.get("isolineDisplay", False))
        elif cls == "Shell":
            inner = float(p.get("innerAmount", 0.0))
            outer = float(p.get("outerAmount", 1.0))
            total = inner + outer
            md = obj.modifiers.new(name, 'SOLIDIFY')
            md.solidify_mode = 'NON_MANIFOLD'
            md.thickness = total * u
            off = (outer - inner) / total if abs(total) > 1e-12 else 0.0
            if abs(off) > 1.0:
                notes.add("Shell amount of opposite signs: Solidify offset limited to -1..1")
            md.offset = max(-1.0, min(1.0, off))
            md.use_rim = True
            md.nonmanifold_thickness_mode = 'CONSTRAINTS' if p.get("straightenCorners") else 'FIXED'
            md.nonmanifold_boundary_mode = 'NONE'
            if rims[k]:
                md.edge_crease_inner = 1.0                # a separating TurboSmooth keeps the rim borders
                md.edge_crease_outer = 1.0
            if int(p.get("segments", 1)) > 1:
                notes.add("Shell segments above 1 (rim divisions) are not in Solidify")
            if any(p.get(o) for o in ("overrideInnerMatID", "overrideOuterMatID", "overrideMatID")):
                notes.add("Shell material ID overrides are not transferred")
            if p.get("Bevel"):
                notes.add("Shell bevel edges are not transferred")
        else:
            notes.add("unknown live modifier %s skipped" % cls)
            continue
        md.show_viewport = bool(m.get("views", True))
        md.show_render = bool(m.get("renders", True))
    top = live[-1] if live else None
    if top and top.get("class") == "Shell" and (top.get("params") or {}).get("autosmooth", True) \
            and bpy.app.version >= (4, 1, 0):
        ng = _smooth_by_angle_group()
        if ng is None:
            notes.add("Smooth by Angle not found: Shell rims are shaded smooth")
        else:
            md = obj.modifiers.new("Auto Smooth Edge", 'NODES')
            md.node_group = ng
            _set_group_input(md, ng, "Angle", math.radians(float((top.get("params") or {}).get("autoSmoothAngle", 45.0))))


def live_signature(live):
    return " > ".join(m.get("class", "?") for m in live)


def _nearest_dists(points, tree_points):
    tree = KDTree(len(tree_points))
    for i, c in enumerate(tree_points):
        tree.insert(c, i)
    tree.balance()
    return np.array([tree.find(c)[2] for c in points], dtype=np.float64)


def deviation(a, b):
    """Largest and mean nearest-vertex distance between two point sets, both ways."""
    if len(a) == 0 or len(b) == 0:
        return float("inf"), float("inf")
    d1 = _nearest_dists(a, b)
    d2 = _nearest_dists(b, a)
    return float(max(d1.max(), d2.max())), float(0.5 * (d1.mean() + d2.mean()))


# ─────────────────────────────────────────────────────────────────────────────
#  Skin -> Armature
# ─────────────────────────────────────────────────────────────────────────────
#
#  3ds Max's Skin (rows: 3ds Max's row-vector matrices) moves a vertex v of the mesh below it to
#      world = v x MeshBind x inverse(BoneBind) x Bone(t)          (one bone)
#  and blends that over the bones by the weights; with "Back Transform Vertices" (default) the
#  mesh node's own transform does not move the skin. In Blender the armature is a child of the
#  mesh object (same matrix), each bone's rest pose is its bind frame in the mesh's space and a
#  Copy Transforms constraint makes the bone follow the 3ds Max bone object, so the deformation
#  is Bone(t) x inverse(BoneBind) x MeshBind again, whatever moves the model.
#  The exact meaning of the bind matrices (node or object matrix, object or pivot space) is not
#  documented: every reading is tried against the skinned mesh 3ds Max wrote at its check frames.

def _rows4(rows):
    """3ds Max matrix3 rows -> 4x4 numpy matrix, row-vector convention, 3ds Max units."""
    m = np.eye(4)
    r = np.asarray(rows, dtype=np.float64)
    m[:3, :3] = r[:3]
    m[3, :3] = r[3]
    return m


def _homog(v):
    return np.c_[v, np.ones(len(v))]


def _bl_matrix(r, u):
    """Row-vector 4x4 (3ds Max units) -> Blender Matrix (column vectors, translation x u)."""
    c = np.array(r, dtype=np.float64).T.copy()
    c[:3, 3] *= u
    return Matrix(c.tolist())


def read_skin_weights(blob, sk):
    """(vertex index, bone index, weight) arrays of a Skin record."""
    nv, total, off = int(sk["nv"]), int(sk["pairs"]), int(sk["at"])
    counts, off = _read(blob, "<i4", nv, off)
    ids, off = _read(blob, "<i4", total, off)
    wts, off = _read(blob, "<f4", total, off)
    vidx = np.repeat(np.arange(nv), counts.astype(np.int64))
    return vidx, ids.astype(np.int64), wts.astype(np.float64)


class SkinReading:
    """One reading of the Skin's matrices: bone matrix = node or object matrix of the bone; bind =
    BoneBind (used inverted) or already its inverse; vertices in object or pivot space; back
    transform on / off."""
    def __init__(self, bone_tm, bind_given_inverse, space, back_transform):
        self.bone_tm, self.bind_given_inverse = bone_tm, bind_given_inverse
        self.space, self.back_transform = space, back_transform

    def __str__(self):
        return "bone %s matrix, %s, mesh %s space, back transform %s" % (
            self.bone_tm, "bind matrix is the inverse" if self.bind_given_inverse else "inverse of the bind matrix",
            self.space, "on" if self.back_transform else "off")


def skin_readings(v_piv, offset_rows, sk, vidx, ids, wts, blob):
    """Errors (3ds Max units, worst vertex over the check frames) of every reading of the Skin's
    matrices, best first: [(error, SkinReading)], and the number of vertices used as evidence.
    Rigidly bound vertices (all weight on one bone) are the evidence when there are any: linear
    and dual quaternion blending move them the same way."""
    bones = sk.get("bones") or []
    nb, nv = len(bones), len(v_piv)
    if not sk.get("mesh_bind") or not sk.get("check") or nb == 0:
        return [], 0
    binds = [_rows4(b["bind"]) if b.get("bind") else None for b in bones]
    mb = _rows4(sk["mesh_bind"])
    off = _rows4(offset_rows) if offset_rows else np.eye(4)
    v_src = {"object": (_homog(v_piv) @ np.linalg.inv(off))[:, :3], "pivot": v_piv}
    W = np.zeros((nv, nb))
    ok = (ids >= 0) & (ids < nb) & (vidx < nv)
    np.add.at(W, (vidx[ok], ids[ok]), wts[ok])
    total = W.sum(axis=1)
    dom = W.argmax(axis=1)
    rigid = (W.max(axis=1) >= 0.999 * total) & (total > 0.5)
    for b in range(nb):                       # a bone without a bind matrix can't be evidence
        if binds[b] is None:
            rigid &= dom != b
    use = rigid if rigid.sum() >= 3 else (total > 0.5)
    checks = []
    for c in sk["check"]:
        vr = c.get("verts") or {}
        if int(vr.get("nv", -1)) != nv:
            continue
        ref = np.frombuffer(blob, dtype="<f4", count=nv * 3, offset=int(vr["at"])).reshape(nv, 3).astype(np.float64)
        bn = [_rows4(m) if m else None for m in c.get("bones", [])]
        bo = [_rows4(m) if m else None for m in c.get("bones_obj", [])]
        if len(bn) != nb or len(bo) != nb:
            continue
        checks.append((ref, bn, bo, _rows4(c["mesh"]), _rows4(c["mesh_obj"])))
    if not checks or not use.any():
        return [], 0
    out = []
    for bone_tm in ("node", "object"):
        for given_inv in (False, True):
            for space in ("object", "pivot"):
                for bt in (True, False):
                    rd = SkinReading(bone_tm, given_inv, space, bt)
                    hv = _homog(v_src[space])
                    err = 0.0
                    for ref, bn, bo, m_node, m_obj in checks:
                        cur = bn if bone_tm == "node" else bo
                        acc = np.zeros((nv, 3))
                        wsum = np.zeros(nv)
                        for b in range(nb):
                            if binds[b] is None or cur[b] is None:
                                continue
                            sel = use & (W[:, b] > 0)
                            if not sel.any():
                                continue
                            x = binds[b] if given_inv else np.linalg.inv(binds[b])
                            t = mb @ x @ cur[b]
                            acc[sel] += W[sel, b:b + 1] * (hv[sel] @ t)[:, :3]
                            wsum[sel] += W[sel, b]
                        sel = use & (wsum > 1e-9)
                        world = acc[sel] / wsum[sel, None]
                        if not bt:
                            world = (_homog(world) @ np.linalg.inv(mb) @ (m_obj if space == "object" else m_node))[:, :3]
                        if len(world):
                            err = max(err, float(np.abs(world - ref[sel]).max()))
                    out.append((err, rd))
    out.sort(key=lambda e: e[0])
    return out, int(use.sum())


def solve_skin_binds(v_piv, sk, vidx, ids, wts, blob):
    """Fallback when the bind matrices are missing or no reading of them fits: per bone the 4x4 row
    matrix K with world = v (pivot space) x K x Bone(t) (bone node matrix), solved by least squares
    from the skinned mesh 3ds Max wrote at the check frames (linear blending). Returns
    (list of K or None per bone, worst error in 3ds Max units, True when every K is determined)
    or None."""
    bones = sk.get("bones") or []
    nb, nv = len(bones), len(v_piv)
    if nb == 0 or nv == 0:
        return None
    W = np.zeros((nv, nb))
    ok = (ids >= 0) & (ids < nb) & (vidx < nv)
    np.add.at(W, (vidx[ok], ids[ok]), wts[ok])
    total = W.sum(axis=1)
    use = total > 1e-9
    Wn = W[use] / total[use, None]
    hv = _homog(v_piv[use])
    blocks, rhs, refs, mats = [], [], [], []
    for c in sk.get("check", []):
        vr = c.get("verts") or {}
        if int(vr.get("nv", -1)) != nv or len(c.get("bones", [])) != nb or any(m is None for m in c["bones"]):
            continue
        ref = np.frombuffer(blob, dtype="<f4", count=nv * 3, offset=int(vr["at"])).reshape(nv, 3).astype(np.float64)[use]
        bt = [_rows4(m) for m in c["bones"]]
        # world_j = sum_b w_b (hv @ K_b @ R_b)_j + sum_b w_b t_b,j ; unknowns K_b[0:4, 0:3]
        a = np.zeros((len(hv), 3, nb * 12))
        tsum = np.zeros((len(hv), 3))
        for b in range(nb):
            r3 = bt[b][:3, :3]
            for j in range(3):
                a[:, j, b * 12:(b + 1) * 12] = Wn[:, b:b + 1] * np.einsum("na,c->nac", hv, r3[:, j]).reshape(len(hv), 12)
            tsum += Wn[:, b:b + 1] * bt[b][3, :3]
        blocks.append(a.reshape(-1, nb * 12))
        rhs.append((ref - tsum).ravel())
        refs.append((ref, bt))
    if not blocks:
        return None
    A = np.vstack(blocks)
    y = np.concatenate(rhs)
    sol, _, rank, _ = np.linalg.lstsq(A, y, rcond=None)
    err = float(np.abs(A @ sol - y).max()) if len(y) else 0.0
    ks = []
    for b in range(nb):
        k = np.eye(4)
        k[:, :3] = sol[b * 12:(b + 1) * 12].reshape(4, 3)
        k[:3, 3] = 0.0
        k[3, 3] = 1.0
        ks.append(k if np.any(Wn[:, b] > 0) else None)
    return ks, err, int(rank) >= nb * 12


def _is_rigid(m3, tol=1e-5):
    """Columns orthonormal and right-handed."""
    a = np.array(m3, dtype=np.float64)
    return bool(np.abs(a.T @ a - np.eye(3)).max() <= tol and np.linalg.det(a) > 0)


def _rigid_part(m):
    """The closest rotation + the translation of a 4x4 Matrix (mirror: X axis turned back)."""
    a = np.array(m.to_3x3(), dtype=np.float64)
    if np.linalg.det(a) < 0:
        a[:, 0] = -a[:, 0]
    uu, _, vt = np.linalg.svd(a)
    r = uu @ vt
    out = Matrix.Identity(4)
    for i in range(3):
        for j in range(3):
            out[i][j] = float(r[i, j])
    out.translation = m.translation
    return out


def _orthonormal(m):
    """Matrix with exactly orthonormal axes (removes float drift of a rigid matrix)."""
    return _rigid_part(m)


def _edit_bones(context, arm_obj, build):
    """Runs build(edit_bones) with arm_obj in Edit Mode. The armature is linked to the scene's
    master collection for that moment (a hidden layer collection can't enter Edit Mode)."""
    vl = context.view_layer
    master = context.scene.collection
    linked = master.objects.get(arm_obj.name) is None
    if linked:
        master.objects.link(arm_obj)
    prev_active = vl.objects.active
    prev_sel = [o for o in context.selected_objects] if hasattr(context, "selected_objects") else []
    for o in prev_sel:
        o.select_set(False)
    vl.objects.active = arm_obj
    arm_obj.select_set(True)
    if context.mode != 'OBJECT':
        bpy.ops.object.mode_set(mode='OBJECT')
    bpy.ops.object.mode_set(mode='EDIT')
    try:
        build(arm_obj.data.edit_bones)
    finally:
        bpy.ops.object.mode_set(mode='OBJECT')
        arm_obj.select_set(False)
        for o in prev_sel:
            try:
                o.select_set(True)
            except Exception:
                pass
        vl.objects.active = prev_active
        if linked:
            master.objects.unlink(arm_obj)


def _signed_permutation(m3, tol=1e-6):
    """For a rotation that only swaps and flips axes: [(axis, sign) for x, y, z] (column j of m3 is
    sign * unit axis), else None."""
    out = []
    for j in range(3):
        col = [m3[i][j] for i in range(3)]
        i = max(range(3), key=lambda k: abs(col[k]))
        if abs(abs(col[i]) - 1.0) > tol or any(abs(col[k]) > tol for k in range(3) if k != i):
            return None
        out.append((i, 1.0 if col[i] > 0 else -1.0))
    return out if len({t for t, _ in out}) == 3 else None


def _bone_path(pb, prop):
    return 'pose.bones["%s"].%s' % (bpy.utils.escape_identifier(pb.name), prop)


def _bone_curve(arm, pb, prop, index, frame, value):
    """F-curve of a pose bone channel, made by keyframe_insert (which creates the action, slot and
    channel bag the way every Blender version expects) with one key at frame / value."""
    getattr(pb, prop)[index] = value
    pb.keyframe_insert(prop, index=index, frame=frame, group=pb.name)
    fc = find_fcurve(arm, _bone_path(pb, prop), index)
    if fc is None:
        raise RuntimeError("F-curve %s[%d] not found after keyframe_insert" % (_bone_path(pb, prop), index))
    return fc


def copy_fcurve_to_bone(src, arm, pb, prop, index, mul, add):
    """The keys of F-curve src on the pose bone channel prop[index], every value (keys and handles) as
    value * mul + add; times, interpolation, easing and handle types as they are."""
    kps_s = src.keyframe_points
    n = len(kps_s)
    co = np.empty(n * 2, dtype=np.float32)
    hl = np.empty(n * 2, dtype=np.float32)
    hr = np.empty(n * 2, dtype=np.float32)
    kps_s.foreach_get("co", co)
    kps_s.foreach_get("handle_left", hl)
    kps_s.foreach_get("handle_right", hr)
    for arr in (co, hl, hr):
        arr[1::2] = arr[1::2] * mul + add
    fc = _bone_curve(arm, pb, prop, index, float(co[0]), float(co[1]))
    kps = fc.keyframe_points
    while len(kps) > 1:
        kps.remove(kps[-1])
    if n > 1:
        kps.add(n - 1)
    kps.foreach_set("co", co)
    for k in range(n):
        a, b = kps_s[k], kps[k]
        b.interpolation = a.interpolation
        b.easing = a.easing
        b.handle_left_type = a.handle_left_type
        b.handle_right_type = a.handle_right_type
    kps.foreach_set("handle_left", hl)
    kps.foreach_set("handle_right", hr)
    fc.extrapolation = src.extrapolation
    fc.update()
    return fc


def bone_fcurve(arm, pb, prop, index, frames, values, interpolation):
    """Keys at frames / values on the pose bone channel prop[index]."""
    fc = _bone_curve(arm, pb, prop, index, float(frames[0]), float(values[0]))
    kps = fc.keyframe_points
    while len(kps) > 1:
        kps.remove(kps[-1])
    if len(frames) > 1:
        kps.add(len(frames) - 1)
    co = np.empty(len(frames) * 2, dtype=np.float32)
    co[0::2] = frames
    co[1::2] = values
    kps.foreach_set("co", co)
    for kp in kps:
        kp.interpolation = interpolation
    fc.update()
    return fc


# ─────────────────────────────────────────────────────────────────────────────
#  Splines
# ─────────────────────────────────────────────────────────────────────────────

def build_curve(name, shape, u):
    cu = bpy.data.curves.new(name, 'CURVE')
    cu.dimensions = '3D'
    steps = int(shape.get("steps", 6))
    cu.resolution_u = max(1, min(64, steps + 1))
    for sp in shape.get("splines", []):
        knots = sp.get("knots", [])
        n = len(knots)
        if n == 0:
            continue
        s = cu.splines.new('BEZIER')
        s.bezier_points.add(n - 1)
        for i, k in enumerate(knots):
            bp = s.bezier_points[i]
            bp.handle_left_type = 'FREE'
            bp.handle_right_type = 'FREE'
            bp.co = (k[0] * u, k[1] * u, k[2] * u)
            bp.handle_left = (k[3] * u, k[4] * u, k[5] * u)
            bp.handle_right = (k[6] * u, k[7] * u, k[8] * u)
        s.use_cyclic_u = bool(sp.get("closed"))
        for g in sp.get("lines", []):           # straight segments: handles on the line
            g = int(g)
            pa = s.bezier_points[g]
            pb = s.bezier_points[(g + 1) % n]
            d = pb.co - pa.co
            pa.handle_right = pa.co + d / 3.0
            pb.handle_left = pb.co - d / 3.0
    r = shape.get("render")
    if r and (r.get("renderable") or r.get("viewport")):
        th = float(r.get("thickness") or 0.0)
        if r.get("rectangular"):
            th = max(float(r.get("width") or 0.0), float(r.get("length") or 0.0))
        cu.bevel_depth = th * 0.5 * u
        sides = int(r.get("sides") or 12)
        cu.bevel_resolution = max(0, min(32, (sides - 4) // 2))
        try:
            cu.use_fill_caps = True
        except AttributeError:
            pass
    return cu


# ─────────────────────────────────────────────────────────────────────────────
#  Materials
# ─────────────────────────────────────────────────────────────────────────────

def _image_node(nt, path, label, report):
    if not path or not os.path.isfile(path):
        if path:
            report.log("bitmap not found: %s" % path)
        return None
    try:
        img = bpy.data.images.load(path, check_existing=True)
    except Exception as ex:
        report.warning("bitmap %s: %s" % (path, ex))
        return None
    node = nt.nodes.new("ShaderNodeTexImage")
    node.image = img
    node.label = label
    return node


def build_material(key, rec, report):
    mat = bpy.data.materials.new(rec.get("name") or key)
    mat["max_class"] = rec.get("class", "")
    mat["max_key"] = key
    color = rec.get("color")
    try:
        mat.use_nodes = True
    except Exception:
        pass
    bsdf = None
    if mat.node_tree:
        bsdf = next((nd for nd in mat.node_tree.nodes if nd.type == 'BSDF_PRINCIPLED'), None)
    if color:
        c = (float(color[0]), float(color[1]), float(color[2]), 1.0)
        mat.diffuse_color = c
        if bsdf:
            bsdf.inputs["Base Color"].default_value = c
    elif "Missing" in rec.get("class", ""):
        mat.diffuse_color = (0.8, 0.0, 0.8, 1.0)          # a plug-in material 3ds Max could not load
        if bsdf:
            bsdf.inputs["Base Color"].default_value = (0.8, 0.0, 0.8, 1.0)
    if bsdf is not None:
        if rec.get("metal") is not None:
            bsdf.inputs["Metallic"].default_value = max(0.0, min(1.0, float(rec["metal"])))
        if rec.get("rough") is not None:
            bsdf.inputs["Roughness"].default_value = max(0.0, min(1.0, float(rec["rough"])))
        if rec.get("opacity") is not None and float(rec["opacity"]) < 0.999:
            bsdf.inputs["Alpha"].default_value = max(0.0, float(rec["opacity"]))
            try:
                mat.blend_method = 'HASHED'
            except Exception:
                pass
        maps = rec.get("maps") or {}
        nt = mat.node_tree
        img = _image_node(nt, maps.get("color"), "Base Color", report)
        if img:
            nt.links.new(img.outputs["Color"], bsdf.inputs["Base Color"])
        img = _image_node(nt, maps.get("rough"), "Roughness", report)
        if img:
            img.image.colorspace_settings.name = 'Non-Color'
            nt.links.new(img.outputs["Color"], bsdf.inputs["Roughness"])
        img = _image_node(nt, maps.get("metal"), "Metallic", report)
        if img:
            img.image.colorspace_settings.name = 'Non-Color'
            nt.links.new(img.outputs["Color"], bsdf.inputs["Metallic"])
        img = _image_node(nt, maps.get("normal"), "Normal", report)
        if img:
            img.image.colorspace_settings.name = 'Non-Color'
            nm = nt.nodes.new("ShaderNodeNormalMap")
            nt.links.new(img.outputs["Color"], nm.inputs["Color"])
            nt.links.new(nm.outputs["Normal"], bsdf.inputs["Normal"])
    return mat


# ─────────────────────────────────────────────────────────────────────────────
#  Animation
# ─────────────────────────────────────────────────────────────────────────────

def find_fcurve(obj, data_path, index):
    ad = obj.animation_data
    if ad is None or ad.action is None:
        return None
    act = ad.action
    if hasattr(act, "layers"):                        # Blender 4.4+ slotted actions
        slot = getattr(ad, "action_slot", None)
        if slot is None:
            return None
        try:
            from bpy_extras.anim_utils import action_get_channelbag_for_slot
        except ImportError:
            action_get_channelbag_for_slot = None
        bag = None
        if action_get_channelbag_for_slot is not None:
            bag = action_get_channelbag_for_slot(act, slot)
        else:
            for layer in act.layers:
                for strip in layer.strips:
                    bag = strip.channelbag(slot) if hasattr(strip, "channelbag") else None
                    if bag is not None:
                        break
        return bag.fcurves.find(data_path, index=index) if bag is not None else None
    return act.fcurves.find(data_path, index=index)  # Blender 3.6 - 4.3


def _set_channel(obj, data_path, index, value):
    vec = getattr(obj, data_path)
    vec[index] = value


def new_fcurve(obj, data_path, index, frames, values):
    """F-curve with keys at frames/values (handles and interpolation set by the caller).
    The first key goes through keyframe_insert, which creates the action, slot and
    channel bag the way every Blender version expects."""
    _set_channel(obj, data_path, index, values[0])
    obj.keyframe_insert(data_path, index=index, frame=frames[0], group="Object Transforms")
    fc = find_fcurve(obj, data_path, index)
    if fc is None:
        raise RuntimeError("F-curve %s[%d] not found after keyframe_insert" % (data_path, index))
    kps = fc.keyframe_points
    while len(kps) > 1:
        kps.remove(kps[-1])
    if len(frames) > 1:
        kps.add(len(frames) - 1)
    co = np.empty(len(frames) * 2, dtype=np.float32)
    co[0::2] = frames
    co[1::2] = values
    kps.foreach_set("co", co)
    return fc


def _bezier_t(a, b, u):
    """Parameter s where the normalized time Bezier (0, a, 1-b, 1) reaches u."""
    lo, hi = 0.0, 1.0
    s = u
    for _ in range(60):
        s = 0.5 * (lo + hi)
        x = 3.0 * (1 - s) ** 2 * s * a + 3.0 * (1 - s) * s * s * (1.0 - b) + s ** 3
        if x < u:
            lo = s
        else:
            hi = s
    return s


def fit_segment(v0, v1, samples, a, b):
    """Value handles (y1, y2) of a Bezier segment with time handles at a and 1-b
    (fractions of the segment) through v0, v1 and the samples at 1/4, 1/2, 3/4 of
    the segment time. Returns (y1, y2, max residual)."""
    rows, rhs = [], []
    for u, y in zip((0.25, 0.5, 0.75), samples):
        s = _bezier_t(a, b, u)
        b0, b1, b2, b3 = (1 - s) ** 3, 3 * (1 - s) ** 2 * s, 3 * (1 - s) * s * s, s ** 3
        rows.append((b1, b2))
        rhs.append(y - b0 * v0 - b3 * v1)
    A = np.array(rows)
    r = np.array(rhs)
    sol, *_ = np.linalg.lstsq(A, r, rcond=None)
    res = float(np.max(np.abs(A @ sol - r)))
    return float(sol[0]), float(sol[1]), res


UNIT_LABELS = {"length": "Max units", "deg": "degrees", "percent": "percent", "fraction": "fraction"}


class AnimStats:
    def __init__(self):
        self.tracks = 0
        self.single_static = 0
        self.single_kept = 0
        self.segments = 0
        self.model_lengths = 0
        self.model_third = 0
        self.bad_fits = 0
        self.worst_fit = (0.0, "")
        self.unit_fixes = 0
        self.baked_nodes = 0
        self.baked_channels = 0
        self.evidence = {}       # (controller, unit, what) -> ratios, logged as conventions evidence

    def add_evidence(self, ctrl, unit, what, ratio):
        lst = self.evidence.setdefault((ctrl, unit, what), [])
        if len(lst) < 5000:
            lst.append(ratio)


def _length_text(meters):
    """'1 m', '1 cm', '2.54 cm'... for a length in meters."""
    for div, name in ((1000.0, "km"), (1.0, "m"), (0.01, "cm"), (0.001, "mm")):
        if meters >= div * 0.999999:
            return "%g %s" % (meters / div, name)
    return "%g m" % meters


def unit_factor(unit, u):
    if unit == "length":
        return u
    if unit == "deg":
        return math.pi / 180.0
    if unit == "percent":
        return 0.01
    return 1.0


def _prs_complete(prs):
    """PRS record with position, Euler angles (Blender order) and scale, all numbers."""
    if not prs or prs.get("order") not in EULER_ORDERS:
        return False
    for key in ("pos", "euler", "scale"):
        v = prs.get(key)
        if not isinstance(v, list) or len(v) != 3 or any(not isinstance(x, (int, float)) for x in v):
            return False
    return True


def static_channel_value(prs, ch, i, u):
    """Value of a channel at the export frame from the PRS record (Blender units), or None."""
    if not _prs_complete(prs):
        return None
    if ch == "location":
        return prs["pos"][i] * u
    if ch == "rotation_euler":
        return math.radians(prs["euler"][i])
    if ch == "scale":
        return prs["scale"][i]
    return None


def import_track(obj, tr, u, export_frame, prs, opts, stats, report):
    """One 3ds Max key track -> F-curve with fitted handles."""
    ch, i = tr["ch"], int(tr["i"])
    keys = tr.get("keys", [])
    kv = tr.get("kv", [])
    seg = tr.get("seg", [])
    if not keys or len(kv) != len(keys):
        report.warning("'%s': %s[%d] has no usable keys" % (obj.name, ch, i))
        return
    f = unit_factor(tr.get("unit"), u)
    frames = [float(k[0]) for k in keys]
    vals = [float(v) * f if v is not None else 0.0 for v in kv]
    ctrl = tr.get("ctrl", "")
    for k, v in zip(keys, kv):            # raw key value vs sampled controller value (unit evidence)
        if k[1] not in (None, 0) and v is not None and abs(v) > 1e-6:
            stats.add_evidence(ctrl, tr.get("unit"), "key value / sampled value", float(k[1]) / float(v))
    segs = [[float(x) * f if x is not None else 0.0 for x in s] for s in seg]

    # unit check against the PRS value at the export frame (catches a wrong unit label)
    ref = static_channel_value(prs, ch, i, u)
    if ref is not None:
        here = _value_at(frames, vals, export_frame)
        if here is not None and abs(here - ref) > 1e-4 * max(1.0, abs(ref)):
            for cand in (0.01, 100.0, math.pi / 180.0, 180.0 / math.pi):
                if abs(here * cand - ref) <= 1e-4 * max(1.0, abs(ref)):
                    vals = [v * cand for v in vals]
                    segs = [[x * cand for x in s] for s in segs]
                    f *= cand
                    stats.unit_fixes += 1
                    report.warning("'%s': %s[%d] unit corrected x%g (label %s)"
                                   % (obj.name, ch, i, cand, tr.get("unit")))
                    break

    if len(keys) == 1 and not opts.keep_single_keys:
        _set_channel(obj, ch, i, vals[0])
        stats.single_static += 1
        return
    if len(keys) == 1:
        stats.single_kept += 1

    stats.tracks += 1
    fc = new_fcurve(obj, ch, i, frames, vals)
    kps = fc.keyframe_points
    n = len(keys)
    linear_ctrl = tr.get("ctrl", "").lower().startswith("linear")
    hr = [None] * n        # right handle of key k
    hl = [None] * n        # left handle of key k
    interp = ['BEZIER'] * n
    for k in range(n - 1):
        t0, t1 = frames[k], frames[k + 1]
        v0, v1 = vals[k], vals[k + 1]
        dt = t1 - t0
        smp = segs[k] if k < len(segs) else [v0 + (v1 - v0) * x for x in (0.25, 0.5, 0.75)]
        out_type = str(keys[k][3]).lower()
        stats.segments += 1
        if linear_ctrl:                     # Linear Float / Position / Scale: no tangents
            interp[k] = 'LINEAR'
            continue
        if out_type == "step":
            interp[k] = 'CONSTANT'
            err = max(abs(x - v0) for x in smp)
            if err > 1e-5 * max(1.0, abs(v0)):
                report.warning("'%s': %s[%d] step segment at %g does not hold (%.3g)" % (obj.name, ch, i, t0, err))
            continue
        tol = 1e-5 * max(1.0, abs(v0), abs(v1), max(abs(x) for x in smp))
        cands = []
        a = keys[k][7]
        b = keys[k + 1][6]
        if a is not None and b is not None and 0.0 < a < 1.0 and 0.0 < b < 1.0 and a + b <= 1.0:
            y1, y2, res = fit_segment(v0, v1, smp, float(a), float(b))
            cands.append((res, "lengths", float(a), float(b), y1, y2))
        y1, y2, res = fit_segment(v0, v1, smp, 1.0 / 3.0, 1.0 / 3.0)
        cands.append((res, "third", 1.0 / 3.0, 1.0 / 3.0, y1, y2))
        cands.sort(key=lambda c: c[0])
        res, model, a, b, y1, y2 = cands[0]
        if model == "lengths":
            stats.model_lengths += 1
        else:
            stats.model_third += 1
        if res > tol:
            stats.bad_fits += 1
            if res / max(tol, 1e-12) > stats.worst_fit[0]:
                stats.worst_fit = (res / max(tol, 1e-12), "%s %s[%d] at frame %g" % (obj.name, ch, i, t0))
        hr[k] = (t0 + a * dt, y1)
        hl[k + 1] = (t1 - b * dt, y2)
        # tangent convention evidence: fitted slope / raw 3ds Max tangent (value units per frame)
        raw_out, raw_in = keys[k][5], keys[k + 1][4]
        if raw_out not in (None, 0) and a > 0 and res <= tol:
            stats.add_evidence(ctrl, tr.get("unit"), "fitted out slope / out tangent", ((y1 - v0) / (a * dt)) / (raw_out * f))
        if raw_in not in (None, 0) and b > 0 and res <= tol:
            stats.add_evidence(ctrl, tr.get("unit"), "fitted in slope / in tangent", ((v1 - y2) / (b * dt)) / (raw_in * f))
        if model == "lengths" and keys[k][7] is not None:
            stats.add_evidence(ctrl, tr.get("unit"), "out tangent length", float(keys[k][7]))

    # handles without a segment: mirror the other side (flat for a lone key)
    for k in range(n):
        co = (frames[k], vals[k])
        if hr[k] is None and hl[k] is not None:
            hr[k] = (2 * co[0] - hl[k][0], 2 * co[1] - hl[k][1])
        if hl[k] is None and hr[k] is not None:
            hl[k] = (2 * co[0] - hr[k][0], 2 * co[1] - hr[k][1])
        if hl[k] is None:
            hl[k] = (co[0] - 1.0, co[1])
            hr[k] = (co[0] + 1.0, co[1])
    for k, kp in enumerate(kps):
        kp.interpolation = interp[k]
        kp.handle_left_type = 'FREE'
        kp.handle_right_type = 'FREE'
        kp.handle_left = hl[k]
        kp.handle_right = hr[k]
    fc.update()


def remap_legacy_euler(tracks, order, prs, export_frame):
    """Scripts up to 0.4 labeled the Euler XYZ sub-controller tracks by their position, and 3ds Max
    lists them in the controller's axis order (ZXY: Z, X, Y), so track i holds the axis order[i].
    Returns (tracks, how, matched, checked): how is "remapped" or "kept" (the values at the export
    frame match the old labels, not the axis order); matched / checked count the tracks whose
    value at the export frame equals the PRS Euler angle of the axis they end up on."""
    out = []
    new_ok = old_ok = checked = 0
    euler = prs.get("euler") if _prs_complete(prs) else None
    for t in tracks:
        if t.get("ch") != "rotation_euler":
            out.append(t)
            continue
        i = int(t.get("i", 0))
        j = "XYZ".index(order[i]) if 0 <= i < 3 else i
        if euler is not None and t.get("keys") and len(t.get("kv", [])) == len(t["keys"]):
            here = _value_at([float(k[0]) for k in t["keys"]],
                             [float(v) if v is not None else 0.0 for v in t["kv"]], export_frame)
            if here is not None:
                checked += 1
                tol = 1e-3 * max(1.0, abs(here))
                new_ok += abs(here - float(euler[j])) <= tol
                old_ok += abs(here - float(euler[i])) <= tol
        t2 = dict(t)
        t2["i"] = j
        out.append(t2)
    if checked and old_ok == checked and new_ok < checked:
        return tracks, "kept", old_ok, checked
    return out, "remapped", new_ok, checked


def _value_at(frames, vals, f):
    """Key value at frame f when f is a key (else the first key's value when f precedes it)."""
    for fr, v in zip(frames, vals):
        if abs(fr - f) < 1e-6:
            return v
    if frames and f < frames[0]:
        return vals[0]
    return None


def import_bake(obj, bake, order, u, stats, report):
    """Local matrices per frame -> keys on the channels that move."""
    start = int(bake["start"])
    mats = [max_tm(r, u) for r in bake["local"]]
    if not mats:
        return
    frames = [float(start + k) for k in range(len(mats))]
    obj.rotation_mode = order
    locs, rots, scls = [], [], []
    prev = None
    for m in mats:
        loc, r3, s = decompose(m)
        e = r3.to_euler(order, prev) if prev is not None else r3.to_euler(order)
        prev = e
        locs.append(loc)
        rots.append(e)
        scls.append(s)
    channels = (("location", locs, 1e-6), ("rotation_euler", rots, 1e-6), ("scale", scls, 1e-7))
    obj.location = locs[0]
    obj.rotation_euler = rots[0]
    obj.scale = scls[0]
    for path, seq, tol in channels:
        for i in range(3):
            vals = [float(v[i]) for v in seq]
            if max(vals) - min(vals) <= tol * max(1.0, max(abs(x) for x in vals)):
                _set_channel(obj, path, i, vals[0])
                continue
            fc = new_fcurve(obj, path, i, frames, vals)
            for kp in fc.keyframe_points:
                kp.interpolation = 'LINEAR'
            fc.update()
            stats.baked_channels += 1
    stats.baked_nodes += 1


# ─────────────────────────────────────────────────────────────────────────────
#  Import
# ─────────────────────────────────────────────────────────────────────────────

class Options:
    def __init__(self, **kw):
        self.unit_mode = kw.get("unit_mode", 'METERS')
        self.custom_scale = kw.get("custom_scale", 1.0)
        self.animation = kw.get("animation", True)
        self.keep_single_keys = kw.get("keep_single_keys", False)
        self.materials = kw.get("materials", True)
        self.scene_settings = kw.get("scene_settings", True)
        self.verify = kw.get("verify", True)
        self.rebuild_polygons = kw.get("rebuild_polygons", True)
        # 'NORMALS': hard / soft edges + the exact 3ds Max normals (custom split normals)
        # 'EDGES': hard / soft edges as in 3ds Max, Blender's own normals; 'FLAT': flat faces
        # custom_normals=True / False (the sidebar checkbox) stands for 'NORMALS' / 'EDGES'
        shading = 'FLAT' if kw.get("smoothing") is False else 'NORMALS'
        if kw.get("custom_normals") is not None:
            shading = 'NORMALS' if kw["custom_normals"] else 'EDGES'
        self.shading = kw.get("shading", shading)
        self.check_live = kw.get("check_live", True)
        self.skin = kw.get("skin", True)              # Skin -> Armature (else the skinned mesh as it is)
        # Skin bones that are 3ds Max helpers / skeleton objects become the armature's bones (their objects
        # go, their motion and children move onto the bones); else they stay objects the bones follow
        self.dummy_bones = kw.get("dummy_bones", True)
        self.bake_bones = kw.get("bake_bones", False)  # key the bones that follow objects instead
        self.check_skin = kw.get("check_skin", True)


def _find_layer_collection(lc, col):
    if lc.collection == col:
        return lc
    for child in lc.children:
        hit = _find_layer_collection(child, col)
        if hit is not None:
            return hit
    return None


def _empty_style(obj, rec, u):
    kind = rec.get("kind")
    if rec.get("group_head"):
        box = rec.get("box") or [10.0, 10.0, 10.0]
        obj.empty_display_type = 'PLAIN_AXES'
        obj.empty_display_size = max(0.01, max(abs(x) for x in box) * u * 0.1)
    elif kind == "dummy":
        box = rec.get("box") or [10.0, 10.0, 10.0]
        obj.empty_display_type = 'CUBE'
        obj.empty_display_size = max(1e-4, max(abs(x) for x in box) * 0.5 * u)
    elif kind == "point":
        obj.empty_display_type = 'PLAIN_AXES'
        obj.empty_display_size = max(1e-4, float(rec.get("size") or 10.0) * 0.5 * u)
    else:
        obj.empty_display_type = 'PLAIN_AXES'
        obj.empty_display_size = max(1e-4, 10.0 * u)


class MaxImport:
    def __init__(self, context, json_path, opts):
        self.context = context
        self.json_path = json_path
        self.opts = opts
        base = os.path.splitext(json_path)[0]
        self.report = Report(base + ".import.log")
        self.objs = {}          # handle -> object
        self.residual = {}      # handle -> shear part of a sheared local matrix (in the data / children)
        self.meshes = {}        # mesh key -> (mesh, slot IDs)
        self.mats = {}          # material key -> bpy material
        self.mat_recs = {}
        self.layer_cols = []
        self.stats = AnimStats()
        self.live_notes = set()
        self.live_count = 0
        self.live_rows = []
        self.verify_rows = []
        self.bbox_bad = []
        self.skin_rows = []
        self.summary = ""
        self.legacy_euler = False
        self.euler_fix = collections.Counter()   # "remapped" / "kept" nodes, matched / checked tracks
        self.chain_len = {}     # handle -> sum of the translation lengths up the parent chain (Blender units)
        self.rec_by_h = {}
        self.skins = []         # per skinned mesh: object, record, armature, reading, notes...
        self.rigs = []          # per armature: object, bones (by node handle), order, parent node
        self.bone_nodes = {}    # handle -> (armature, bone name, C) of 3ds Max nodes that became bones
        self.baked_bones = set()  # handles of those keyed on every frame
        self.mm = 1000.0          # millimeters per Blender unit (set from the file's units)

    # ── helpers ──────────────────────────────────────────────────────────
    def scene_unit_scale(self):
        """Meters per Blender unit of this scene: its Unit Scale (Scene > Units) when it uses metric or imperial
        units, else 1."""
        us = self.context.scene.unit_settings
        sl = float(us.scale_length or 1.0)
        return sl if us.system in ('METRIC', 'IMPERIAL') and sl > 0.0 else 1.0

    def unit(self, doc):
        """Blender units per 3ds Max unit. Real size: 3ds Max units -> meters -> the scene's units."""
        cm = float(doc.get("units", {}).get("cm_per_unit", 1.0) or 1.0)
        if self.opts.unit_mode == 'METERS':
            return cm * 0.01 / self.scene_unit_scale()
        if self.opts.unit_mode == 'CUSTOM':
            return float(self.opts.custom_scale)
        return 1.0

    def resolve_material(self, mkey, mat_id):
        """bpy material for a 3ds Max material key and a face material ID."""
        if not mkey or mkey not in self.mat_recs:
            return None
        rec = self.mat_recs[mkey]
        multi = rec.get("multi")
        if multi is None:
            return self.mats.get(mkey)
        if not multi:
            return None
        hit = next((m for m in multi if int(m[0]) == mat_id), None)
        if hit is None:                              # IDs beyond the list wrap around in 3ds Max
            hit = multi[(mat_id - 1) % len(multi)]
        return self.mats.get(hit[1]) if hit[1] else None

    # ── main ─────────────────────────────────────────────────────────────
    def run(self):
        rep = self.report
        t0 = time.time()
        rep.log("Blender <-> 3Ds Max Bridge Advanced %s (3ds Max -> Blender), Blender %s"
                % (ADDON_VERSION, bpy.app.version_string), console=True)
        rep.log("file: %s" % self.json_path, console=True)
        doc, blob = load_export(self.json_path, rep)
        self.blob = blob
        u = self.unit(doc)
        self.u = u
        cm = float(doc.get("units", {}).get("cm_per_unit", 1.0) or 1.0)
        self.mm = 10.0 * cm / u                 # millimeters per Blender unit (sizes in the report)
        tinfo = doc.get("time", {})
        export_frame = float(tinfo.get("frame", 0.0))
        rep.log("from %s (3ds Max %s), %s; units %s (%s cm) -> x%g; %d nodes, %d meshes"
                % (doc.get("file"), doc.get("max_version"), doc.get("generator"),
                   doc.get("units", {}).get("system"), doc.get("units", {}).get("cm_per_unit"), u,
                   len(doc.get("nodes", [])), len(doc.get("meshes", {}))), console=True)
        us = self.context.scene.unit_settings
        if self.opts.unit_mode == 'METERS':
            sl = self.scene_unit_scale()
            rep.log("units: 3ds Max %s (1 unit = %g cm) -> real size in this scene (%s, Unit Scale %g: 1 Blender unit "
                    "= %s): x%g" % (doc.get("units", {}).get("system"), cm, us.system.lower(), sl,
                                    _length_text(sl), u), console=True)
        else:
            rep.log("units: 3ds Max %s (1 unit = %g cm) -> x%g (%s); 1 Blender unit = %s"
                    % (doc.get("units", {}).get("system"), cm, u, "1 3ds Max unit = 1 Blender unit"
                       if self.opts.unit_mode == 'MAX_UNITS' else "custom factor", _length_text(self.mm / 1000.0)),
                    console=True)
        gv = generator_version(doc)
        self.legacy_euler = gv is not None and gv < (0, 5)
        scene = self.context.scene
        for rec in doc.get("nodes", []):
            h = rec.get("h")
            self.rec_by_h[h] = rec
            t = (rec.get("local") or [[0, 0, 0]] * 4)[3]
            try:
                own = math.sqrt(sum(float(x) ** 2 for x in t)) * u
            except (TypeError, ValueError):
                own = 0.0
            self.chain_len[h] = own + self.chain_len.get(rec.get("parent"), 0.0)

        if self.opts.scene_settings and tinfo:
            fps = float(tinfo.get("fps", 30.0))
            scene.render.fps = max(1, int(round(fps)))
            scene.render.fps_base = scene.render.fps / fps if fps > 0 else 1.0
            scene.frame_start = int(tinfo.get("start", 0))
            scene.frame_end = int(tinfo.get("end", 100))

        # collections from layers
        stem = os.path.splitext(doc.get("file") or os.path.basename(self.json_path))[0] or "3ds Max"
        root = bpy.data.collections.new(stem)
        scene.collection.children.link(root)
        layers = doc.get("layers", [])
        for lay in layers:
            self.layer_cols.append(bpy.data.collections.new(lay.get("name", "layer")))
        for k, lay in enumerate(layers):
            p = int(lay.get("parent", -1))
            parent = self.layer_cols[p] if 0 <= p < len(self.layer_cols) and p != k else root
            parent.children.link(self.layer_cols[k])
        for k, lay in enumerate(layers):
            col = self.layer_cols[k]
            if lay.get("frozen"):
                col.hide_select = True
            if lay.get("renderable") is False:
                col.hide_render = True
            if lay.get("hidden"):
                # 3ds Max neither shows nor renders a hidden layer
                col.hide_render = True
                lc = _find_layer_collection(self.context.view_layer.layer_collection, col)
                if lc is not None:
                    lc.hide_viewport = True

        # materials
        if self.opts.materials:
            self.mat_recs = doc.get("materials", {}) or {}
            for key, rec in self.mat_recs.items():
                if rec.get("multi") is not None:
                    continue
                try:
                    self.mats[key] = build_material(key, rec, rep)
                except Exception as ex:
                    rep.error("material '%s': %s" % (rec.get("name"), ex))
            rep.log("materials: %d (+%d Multi/Sub)" % (len(self.mats),
                    sum(1 for r in self.mat_recs.values() if r.get("multi") is not None)))

        # meshes
        mrecs = doc.get("meshes", {}) or {}
        self.mesh_recs = mrecs
        first_user = {}
        live_keys = set()
        chan_names = {}
        for rec in doc.get("nodes", []):
            mk = rec.get("mesh")
            if mk and mk not in first_user:
                first_user[mk] = rec.get("name", mk)
                chan_names[mk] = map_channel_names(rec.get("props"))
            if mk and rec.get("live"):
                live_keys.add(mk)                # shaded from the smoothing groups (see prepare_live_mesh)
        tm0 = time.time()
        polys = dissolved = 0
        sources = collections.Counter()
        for key, mrec in mrecs.items():
            try:
                me, ids, nd, src = build_mesh(first_user.get(key, key), mrec, blob, u, self.opts, rep,
                                              use_normals=key not in live_keys, channel_names=chan_names.get(key))
                me["max_mat_ids"] = ids
                self.meshes[key] = (me, ids)
                polys += len(me.polygons)
                dissolved += nd
                sources[src] += 1
            except Exception as ex:
                rep.error("mesh %s ('%s'): %s" % (key, first_user.get(key), ex))
        rep.log("meshes: %d built, %d polygons, %d hidden edges dissolved, %.1f s"
                % (len(self.meshes), polys, dissolved, time.time() - tm0), console=True)
        n_nrm = sum(1 for k, r in mrecs.items() if r.get("nrm"))
        rep.log("shading (%s): %d meshes with hard edges and the exact 3ds Max normals (custom normals), %d with hard "
                "edges from the 3ds Max normals and Blender's normals, %d with hard edges from smoothing groups, %d flat; "
                "the file has 3ds Max normals for %d of %d meshes"
                % ({'NORMALS': "Custom Normals on", 'EDGES': "Custom Normals off", 'FLAT': "flat"}.get(
                    getattr(self.opts, "shading", 'NORMALS'), "?"), sources["normals"], sources["edges"],
                    sources["groups"], sources["flat"], n_nrm, len(mrecs)), console=True)
        n_plain = len(mrecs) - n_nrm - len(live_keys & set(mrecs))
        if n_plain > 0 and self.opts.shading != 'FLAT':
            rep.log("shading: %d meshes came without 3ds Max normals, so their hard edges follow the smoothing groups; "
                    "a mesh with explicit normals and smoothing group 0 (from Blender, FBX, OBJ, Weighted Normals) looks "
                    "faceted that way. Scripts from 0.6 on send the normals of every mesh they can read; the 3ds Max log "
                    "says why a mesh has none%s"
                    % (n_plain, " (this file is from %s)" % doc.get("generator") if doc.get("generator") else ""))

        # objects
        nodes = doc.get("nodes", [])
        for rec in nodes:
            try:
                self.make_object(rec, root, u)
            except Exception as ex:
                rep.error("node '%s': %s" % (rec.get("name"), ex))
        # parents and static transforms, parents first (the file is in hierarchy order)
        for rec in nodes:
            obj = self.objs.get(rec.get("h"))
            if obj is None:
                continue
            try:
                self.place(obj, rec, u)
            except Exception as ex:
                rep.error("transform of '%s': %s" % (rec.get("name"), ex))
        if self.opts.materials:
            self.assign_materials(nodes)
        for rec in nodes:
            obj = self.objs.get(rec.get("h"))
            if obj is None:
                continue
            if rec.get("hidden"):
                try:
                    obj.hide_set(True)
                except Exception:
                    obj.hide_viewport = True
                obj.hide_render = True
            if rec.get("frozen"):
                obj.hide_select = True
            if rec.get("renderable") is False:
                obj.hide_render = True

        # Skin -> Armature (its modifier comes first, before the live modifiers)
        if any(rec.get("skin") for rec in nodes):
            try:
                self.setup_skins(nodes, u, export_frame)
            except Exception as ex:
                rep.error("skin: %s" % ex)

        # live modifiers: Shell / TurboSmooth from the top of the 3ds Max stacks
        prepared = {}
        n_sub = n_sol = n_crease = 0
        for rec in nodes:
            live = rec.get("live")
            obj = self.objs.get(rec.get("h"))
            if not live or obj is None or obj.type != 'MESH':
                continue
            try:
                if obj.data.name not in prepared:
                    prepared[obj.data.name] = prepare_live_mesh(obj.data, live)
                    n_crease += prepared[obj.data.name]
                add_live_modifiers(obj, live, u, self.live_notes)
                self.live_count += 1
                n_sub += sum(1 for m in live if m.get("class") == "TurboSmooth")
                n_sol += sum(1 for m in live if m.get("class") == "Shell")
            except Exception as ex:
                rep.error("live modifiers of '%s': %s" % (rec.get("name"), ex))
        if self.live_count:
            rep.log("live modifiers: %d objects, %d Subdivision Surface (TurboSmooth), %d Solidify (Shell); "
                    "%d meshes prepared, %d creased edges" % (self.live_count, n_sub, n_sol, len(prepared), n_crease),
                    console=True)
            for note in sorted(self.live_notes):
                rep.log("   note: " + note)

        # animation
        if self.opts.animation:
            ta = time.time()
            for rec in nodes:
                anim = rec.get("anim")
                obj = self.objs.get(rec.get("h"))
                if not anim or obj is None:
                    continue
                try:
                    self.animate(obj, rec, anim, u, export_frame)
                except Exception as ex:
                    rep.error("animation of '%s': %s" % (rec.get("name"), ex))
            s = self.stats
            rep.log("animation: %d F-curves from keys (%d segments: %d fitted with the 3ds Max tangent lengths, "
                    "%d with 1/3), %d single-key tracks made static, %d kept; %d nodes baked (%d channels); "
                    "%d unit corrections; %.1f s"
                    % (s.tracks, s.segments, s.model_lengths, s.model_third, s.single_static, s.single_kept,
                       s.baked_nodes, s.baked_channels, s.unit_fixes, time.time() - ta), console=True)
            if s.bad_fits:
                rep.warning("%d segments do not fit a Bezier curve (worst %.1fx tolerance: %s)"
                            % (s.bad_fits, s.worst_fit[0], s.worst_fit[1]))
            ef = self.euler_fix
            if ef["remapped"] or ef["kept"]:
                rep.log("older export (%s): Euler tracks were labeled by sub-controller position, which follows "
                        "the axis order; %d nodes with orders other than XYZ remapped to their axes, %d kept; "
                        "evidence: %d of %d tracks equal the 3ds Max Euler angle of their axis at the export frame"
                        % (doc.get("generator"), ef["remapped"], ef["kept"], ef["matched"], ef["checked"]),
                        console=True)
            for (ctrl, unit, what), arr in sorted(s.evidence.items()):
                a = np.array(arr)
                rep.log("evidence %s / %s: %s: median %.6g, min %.6g, max %.6g, n=%d"
                        % (ctrl, unit, what, float(np.median(a)), float(a.min()), float(a.max()), len(a)))

        if self.rigs:
            try:
                self.bones_from_dummies(export_frame)
            except Exception as ex:
                rep.error("skin bones: %s" % ex)
        if self.skins and self.opts.bake_bones:
            try:
                self.bake_skin_bones()
            except Exception as ex:
                rep.error("bone keys: %s" % ex)
        scene.frame_set(int(math.floor(export_frame)), subframe=export_frame - math.floor(export_frame))
        self.context.view_layer.update()
        if self.opts.verify:
            self.verify(nodes, u, export_frame)
            scene.frame_set(int(math.floor(export_frame)), subframe=export_frame - math.floor(export_frame))
        if self.opts.check_live and self.live_count:
            try:
                self.check_live(nodes, u)
            except Exception as ex:
                rep.error("live modifier check: %s" % ex)
        if self.opts.check_skin and self.skins:
            try:
                self.check_skins(u, export_frame)
            except Exception as ex:
                rep.error("skin check: %s" % ex)
            scene.frame_set(int(math.floor(export_frame)), subframe=export_frame - math.floor(export_frame))
        secs = time.time() - t0
        self.summary = ("%d objects, %d meshes, %d warnings, %d errors, %.1f s"
                        % (len(self.objs), len(self.meshes), rep.warnings, rep.errors, secs))
        rep.log("finished: " + self.summary, console=True)
        rep.close()
        return self.summary

    # ── objects ──────────────────────────────────────────────────────────
    def make_object(self, rec, root, u):
        kind = rec.get("kind", "other")
        name = rec.get("name") or "node"
        data = None
        if kind == "mesh" and rec.get("mesh") in self.meshes:
            data = self.meshes[rec["mesh"]][0]
        elif kind == "shape" and rec.get("shape"):
            data = build_curve(name, rec["shape"], u)
        obj = bpy.data.objects.new(name, data)
        if data is None:
            _empty_style(obj, rec, u)
        li = int(rec.get("layer", -1))
        col = self.layer_cols[li] if 0 <= li < len(self.layer_cols) else root
        col.objects.link(obj)
        obj["max_handle"] = int(rec.get("h", 0))
        obj["max_name"] = name
        obj["max_class"] = rec.get("class", "")
        obj["max_base"] = rec.get("base", "")
        obj["max_kind"] = kind
        if rec.get("group_head"):
            obj["max_group_head"] = True
            obj["max_group_open"] = bool(rec.get("group_open"))
        if rec.get("group_member"):
            obj["max_group_member"] = True
        if rec.get("mods"):
            obj["max_mods"] = " | ".join("%s (%s)%s" % (m[0], m[1], "" if m[2] else " off") for m in rec["mods"])
        if rec.get("props"):
            obj["max_user_props"] = rec["props"]
        if rec.get("offset"):
            obj["max_pivot_offset"] = [x for row in rec["offset"] for x in row]
        if rec.get("error"):
            obj["max_export_error"] = rec["error"]
            self.report.warning("'%s' failed in 3ds Max: %s" % (name, rec["error"]))
        w = rec.get("wire")
        if w:
            obj.color = (float(w[0]), float(w[1]), float(w[2]), 1.0)
        if kind == "mesh" and data is None:
            self.report.warning("'%s': mesh missing, imported as an Empty" % name)
        self.objs[rec.get("h")] = obj

    def place(self, obj, rec, u):
        ph = rec.get("parent", -1)
        pk = None
        if ph is not None and ph != -1:
            parent = self.objs.get(ph)
            if parent is None:
                self.report.warning("'%s': parent %s not in the file, kept at the top" % (obj.name, ph))
            else:
                obj.parent = parent
                pk = self.residual.get(ph)
        # a sheared parent passes its shear part on through the parent inverse
        obj.matrix_parent_inverse = pk.copy() if pk is not None else Matrix.Identity(4)
        L = max_tm(rec["local"], u)
        if rec.get("shear"):
            # location / rotation / scale can't hold a shear: Blender keeps the closest
            # transform B, the rest K = B^-1 L goes into the object data and to the children
            obj.matrix_basis = L
            B = obj.matrix_basis.copy()
            K = B.inverted() @ L
            self.residual[rec.get("h")] = K
            if obj.data is not None:
                if getattr(obj.data, "users", 1) > 1:
                    obj.data = obj.data.copy()
                obj.data.transform(K)
            self.report.log("'%s': sheared local matrix: shear part moved into the %s"
                            % (obj.name, "object data and the children" if obj.data is not None else "children"))
            if obj.data is None:
                self.report.warning("'%s': an Empty can't show its shear (children are exact)" % obj.name)
            return
        prs = rec.get("prs")
        if _prs_complete(prs):
            order = prs["order"]
            loc = Vector(prs["pos"]) * u
            eul = Euler([math.radians(x) for x in prs["euler"]], order)
            scl = Vector(prs["scale"])
            cand = compose(loc, eul.to_matrix(), scl)
            dpos, dax = tm_error(cand, L)
            if dpos <= POS_TOL + FLOAT_REL * self.chain_len.get(rec.get("h"), 0.0) and dax <= AXIS_TOL:
                obj.rotation_mode = order
                obj.location = loc
                obj.rotation_euler = eul
                obj.scale = scl
                return
            self.report.log("'%s': PRS values do not rebuild the local matrix (%.3g m, %.3g: a scale axis or a "
                            "constraint); the matrix is used" % (obj.name, dpos, dax))
            obj.rotation_mode = order
        obj.matrix_basis = L

    def assign_materials(self, nodes):
        done_mesh = {}
        for rec in nodes:
            obj = self.objs.get(rec.get("h"))
            mk = rec.get("mesh")
            if obj is None or obj.type != 'MESH' or mk not in self.meshes:
                continue
            me, ids = self.meshes[mk]
            mats = [self.resolve_material(rec.get("mtl"), i) for i in ids]
            if mk not in done_mesh:
                for k, m in enumerate(mats):
                    me.materials[k] = m
                done_mesh[mk] = mats
            elif mats != done_mesh[mk]:
                for k, m in enumerate(mats):     # instance with another material: object-linked slots
                    slot = obj.material_slots[k]
                    slot.link = 'OBJECT'
                    slot.material = m

    def animate(self, obj, rec, anim, u, export_frame):
        mode = anim.get("mode")
        prs = rec.get("prs")
        order = anim.get("order") if anim.get("order") in EULER_ORDERS else (
            prs.get("order") if prs and prs.get("order") in EULER_ORDERS else 'XYZ')
        if mode == "keys":
            tracks = anim.get("tracks", [])
            if self.legacy_euler and order != "XYZ" and any(t.get("ch") == "rotation_euler" for t in tracks):
                tracks, how, ok, checked = remap_legacy_euler(tracks, order, prs, export_frame)
                self.euler_fix[how] += 1
                self.euler_fix["matched"] += ok
                self.euler_fix["checked"] += checked
                if how == "kept":
                    self.report.warning("'%s': Euler %s tracks kept as labeled (their values at the export frame "
                                        "match the labels, not the axis order)" % (obj.name, order))
            if obj.rotation_mode != order:
                if any(t.get("ch") == "rotation_euler" for t in tracks):
                    self.report.warning("'%s': rotation mode %s -> %s for the Euler keys" % (obj.name, obj.rotation_mode, order))
                    m = obj.matrix_basis.copy()
                    obj.rotation_mode = order
                    obj.matrix_basis = m
            for tr in tracks:
                import_track(obj, tr, u, export_frame, prs, self.opts, self.stats, self.report)
        elif mode == "bake" and anim.get("bake"):
            import_bake(obj, anim["bake"], order, u, self.stats, self.report)
            self.report.log("'%s': baked (%s)" % (obj.name, anim.get("reason", "")))

    # ── Skin -> Armature ─────────────────────────────────────────────────
    def skinned_shape(self, rec, obj, u, export_frame):
        """The mesh as 3ds Max shows it at the export frame (Skin applied), from the skin check data;
        used when the Skin is not converted. Returns True when the vertices were replaced."""
        sk = rec.get("skin") or {}
        if obj.type != 'MESH':
            return False
        me = obj.data
        for c in sk.get("check", []):
            vr = c.get("verts") or {}
            if abs(float(c.get("frame", -1e9)) - export_frame) > 1e-6 or int(vr.get("nv", -1)) != len(me.vertices):
                continue
            nv = len(me.vertices)
            ref = np.frombuffer(self.blob, dtype="<f4", count=nv * 3, offset=int(vr["at"])).reshape(nv, 3)
            piv = (_homog(ref.astype(np.float64)) @ np.linalg.inv(_rows4(rec["world"])))[:, :3] * u
            if me.users > 1:
                me = obj.data = me.copy()
            me.vertices.foreach_set("co", piv.astype(np.float32).ravel())
            me.update()
            return True
        return False

    def skin_bind_data(self, rec, obj, u):
        """The Skin of rec read for an armature: the weights, and per bone the matrix K from the mesh's
        pivot space to the bone's frame (deformed world position = bone node world(t) @ K @ v).
        Returns (data, None) or (None, why not)."""
        sk = rec["skin"]
        mrec = self.mesh_recs.get(rec.get("mesh"))
        nv = int(sk.get("nv", 0))
        if obj.type != 'MESH' or mrec is None:
            return None, "no mesh"
        if len(obj.data.vertices) != nv or int(mrec.get("nv", -1)) != nv:
            return None, "the mesh has %d vertices, the Skin %d" % (len(obj.data.vertices), nv)
        if self.residual.get(rec.get("h")) is not None:
            return None, "sheared node"
        bones = sk.get("bones") or []
        nb = len(bones)
        if nb == 0:
            return None, "no bones"
        vidx, ids, wts = read_skin_weights(self.blob, sk)
        v_piv = np.frombuffer(self.blob, dtype="<f4", count=nv * 3, offset=int(mrec["at"])).reshape(nv, 3)
        v_piv = v_piv.astype(np.float64)
        size = float(np.max(v_piv.max(axis=0) - v_piv.min(axis=0))) if nv else 1.0
        readings, n_ev = [], 0
        if sk.get("mesh_bind"):
            readings, n_ev = skin_readings(v_piv, rec.get("offset"), sk, vidx, ids, wts, self.blob)
        if readings:
            # readings that fit equally (a still mesh, bones without offsets) are told apart by the Skin's own
            # Back Transform flag, then the plain reading first
            best = readings[0][0]
            flag = bool(sk.get("back_transform", True))
            tied = [x for x in readings if x[0] <= max(2.0 * best, best + 1e-6 * size)]
            err, rd = min(tied, key=lambda x: (x[1].back_transform != flag, x[1].bone_tm != "node",
                                               x[1].bind_given_inverse, x[1].space != "object"))
            alt = next((e for e, r in readings[1:] if e > max(best * 10.0, 1e-4 * size)), None)
        else:
            err, rd, alt = None, SkinReading("node", False, "object", True), None
        # no bind matrices, or none of their readings fits: solve them from 3ds Max's skinned mesh
        solved = None
        if err is None or err > SKIN_TOL_REL * size + 1e-6 or any(not b.get("bind") for b in bones):
            res = solve_skin_binds(v_piv, sk, vidx, ids, wts, self.blob)
            if res is not None and (err is None or res[1] < err):
                solved = res
                err, alt, rd = res[1], None, SkinReading("node", False, "pivot", True)
                n_ev = nv
        if solved is None and not sk.get("mesh_bind"):
            return None, "no bind matrices and no check data to solve them from"
        mb = _rows4(sk["mesh_bind"]) if sk.get("mesh_bind") else np.eye(4)
        off = _rows4(rec["offset"]) if rec.get("offset") else np.eye(4)
        s_rows = np.linalg.inv(off) if rd.space == "object" else np.eye(4)
        c0 = (sk.get("check") or [{}])[0]
        infos = []
        notes = []
        mesh_size = max(size * u, 1e-6)
        for b, bone in enumerate(bones):
            name = (bone.get("name") or "Bone %d" % (b + 1))[:63]
            bh = bone.get("h")
            if solved is not None:
                if solved[0][b] is None:
                    notes.append("bone '%s' carries no weight: left out" % name)
                    infos.append(None)
                    continue
                k = _bl_matrix(solved[0][b], u)
            else:
                if not bone.get("bind"):
                    notes.append("bone '%s' has no bind matrix: left out" % name)
                    infos.append(None)
                    continue
                bind = _rows4(bone["bind"])
                x = bind if rd.bind_given_inverse else np.linalg.inv(bind)
                offb = np.eye(4)
                if rd.bone_tm == "object":
                    bn = (c0.get("bones") or [None] * nb)[b]
                    bo = (c0.get("bones_obj") or [None] * nb)[b]
                    if bn and bo:
                        offb = _rows4(bo) @ np.linalg.inv(_rows4(bn))
                k = _bl_matrix(s_rows @ mb @ x @ offb, u)
            try:
                k.inverted()
            except ValueError:
                notes.append("bone '%s': bind matrix can't be inverted: left out" % name)
                infos.append(None)
                continue
            ln = float(bone.get("len") or 0.0) * u
            ln = min(max(ln if ln > 0 else 0.1 * mesh_size, 0.02 * mesh_size), 0.5 * mesh_size)
            if bh is not None and bh not in self.rec_by_h:
                notes.append("bone '%s' is not in the file: it stays at its bind pose" % name)
                bh = None
            infos.append({"name": name, "h": bh, "k": k, "len": ln, "max_name": bone.get("name")})
        if not any(infos):
            return None, "no usable bones"
        return {"obj": obj, "rec": rec, "vidx": vidx, "ids": ids, "wts": wts, "bones": infos, "reading": rd,
                "err": err, "alt": alt, "n_ev": n_ev, "size": size, "notes": notes, "solved": solved,
                "pairs": len(wts)}, None

    # ── 3ds Max nodes and their links ──
    def _node_world(self, h):
        """World matrix of node h as 3ds Max has it (the object's world with its shear part), now."""
        obj = self.objs.get(h)
        if obj is None:
            return None
        k = self.residual.get(h)
        return obj.matrix_world @ k if k is not None else obj.matrix_world.copy()

    def _max_parent(self, h):
        p = (self.rec_by_h.get(h) or {}).get("parent")
        return None if p is None or p == -1 or p not in self.rec_by_h else p

    def _animated(self, h):
        if not self.opts.animation:
            return False
        a = (self.rec_by_h.get(h) or {}).get("anim") or {}
        return a.get("mode") in ("keys", "bake")

    def _rigid_link(self, a, b):
        """True when nodes a and b (None: the world) keep their relative transform over the animation:
        no animated node between either of them and their nearest common ancestor."""
        def chain(h):
            out = []
            while h is not None:
                out.append(h)
                h = self._max_parent(h)
            return out
        ca, cb = chain(a), chain(b)
        common = set(ca) & set(cb)
        for c in (ca, cb):
            for x in c:
                if x in common:
                    break
                if self._animated(x):
                    return False
        return True

    def _object_above(self, h):
        """The nearest 3ds Max ancestor of node h that is an object here (None: the world)."""
        p = self._max_parent(h)
        while p is not None and p not in self.objs:
            p = self._max_parent(p)
        return p

    def _common_ancestor(self, hs):
        """The nearest node that is (or is above) every node in hs and is an object here; None: the world."""
        chains = []
        for h in hs:
            if h is None:
                return None
            c = []
            while h is not None:
                c.append(h)
                h = self._max_parent(h)
            chains.append(c)
        if not chains:
            return None
        common = set(chains[0]).intersection(*chains[1:])
        for x in chains[0]:
            if x in common and x in self.objs:
                return x
        return None

    def _skeleton_node(self, h):
        """Node h becomes an armature bone (its object goes): a helper or a 3ds Max skeleton object
        that is not sheared and carries no Skin or live modifiers of its own."""
        if not self.opts.dummy_bones or h is None or h not in self.objs or self.residual.get(h) is not None:
            return False
        r = self.rec_by_h.get(h) or {}
        if r.get("skin") or r.get("live"):
            return False
        return r.get("kind") in SKELETON_KINDS or r.get("class") in SKELETON_CLASSES

    def setup_skins(self, nodes, u, export_frame):
        rep = self.report
        self.context.view_layer.update()          # world matrices of the placed objects
        datas = []
        n_flat = 0
        for rec in nodes:
            if not rec.get("skin"):
                continue
            obj = self.objs.get(rec.get("h"))
            if obj is None:
                continue
            why = "Skin -> Armature is off" if not self.opts.skin else None
            data = None
            if why is None:
                try:
                    data, why = self.skin_bind_data(rec, obj, u)
                except Exception as ex:
                    data, why = None, "error: %s" % ex
            if data is not None:
                datas.append(data)
                continue
            # not converted: the mesh as 3ds Max shows it at the export frame
            shaped = self.skinned_shape(rec, obj, u, export_frame)
            n_flat += 1
            if self.opts.skin:
                rep.warning("'%s': Skin not converted (%s); %s" % (obj.name, why, "the mesh is the skinned shape at "
                            "the export frame" if shaped else "the mesh is the one below the Skin"))
        # skins that share bones get one armature
        root = list(range(len(datas)))

        def find(i):
            while root[i] != i:
                root[i] = root[root[i]]
                i = root[i]
            return i
        owner = {}
        for i, d in enumerate(datas):
            for b in d["bones"]:
                if b is None or b["h"] is None:
                    continue
                if b["h"] in owner:
                    root[find(i)] = find(owner[b["h"]])
                else:
                    owner[b["h"]] = i
        groups = collections.OrderedDict()
        for i, d in enumerate(datas):
            groups.setdefault(find(i), []).append(d)
        n_ok = 0
        for group in groups.values():
            try:
                self.build_rig(group, u)
                n_ok += len(group)
            except Exception as ex:
                rep.error("armature for %s: %s" % (", ".join("'%s'" % d["obj"].name for d in group), ex))
                for d in group:
                    if self.skinned_shape(d["rec"], d["obj"], u, export_frame):
                        n_flat += 1
        if n_ok or n_flat:
            rep.log("skin: %d Skin modifiers -> Armature modifiers on %d armatures, %d kept as the skinned shape"
                    % (n_ok, len(self.rigs), n_flat), console=True)
        for s in self.skins:
            rd, err = s["reading"], s["err"]
            if err is None:
                rep.warning("'%s': no check data to confirm the bind matrices; read as: %s" % (s["obj"].name, rd))
            else:
                rep.log("   %-34s %d bones, %d weights, %s%s; bind matrices %s; evidence: %d vertices "
                        "within %.3g mm of 3ds Max%s"
                        % (s["obj"].name, s["bones"], s["pairs"], "dual quaternion" if s["rec"]["skin"].get("dq")
                           else "linear", ", %d bind helpers" % s["helpers"] if s["helpers"] else "",
                           "solved from the check frames" if s.get("solved") else "read as: %s" % rd,
                           s["n_ev"], err * u * self.mm,
                           "" if s["alt"] is None else " (next reading off by %.3g mm)" % (s["alt"] * u * self.mm)))
                if err > SKIN_TOL_REL * s["size"] + 1e-6:
                    rep.warning("'%s': no reading of the Skin matrices matches 3ds Max (best off by %.3g mm)"
                                % (s["obj"].name, err * u * self.mm))
            if not rd.back_transform:
                rep.log("      note: Back Transform Vertices off in 3ds Max; in Blender the skin follows the bones only")
            for note in s["notes"]:
                rep.log("      note: " + note)

    def build_rig(self, datas, u):
        """One armature for skins that share bones. Every Skin bone is a bone; 3ds Max helpers and
        skeleton objects become the bones themselves (bone frame = node frame @ C, rest = bind; their
        motion goes onto the pose bones in bones_from_dummies), other objects are followed with Copy
        Transforms. Helpers between two bones join as bones that do not deform.
        The armature hangs under the nearest common 3ds Max ancestor of the skinned meshes and of the
        objects the root bones hang under (their anchors), when every skinned mesh keeps still against
        it (else under the first mesh). When a root bone's anchor is not that parent (bones linked to
        different objects of an assembly), every root bone follows its anchor with a Child Of
        constraint: one armature, one Armature modifier per mesh, the blend of one 3ds Max Skin."""
        rep = self.report
        mesh_size = max(max(d["size"] for d in datas) * u, 1e-6)
        bones = collections.OrderedDict()           # node handle (or ("missing", skin, bone)) -> bone
        for di, d in enumerate(datas):
            for b, info in enumerate(d["bones"]):
                if info is None:
                    continue
                key = info["h"] if info["h"] is not None else ("missing", di, b)
                e = bones.get(key)
                if e is None:
                    e = bones[key] = {"h": info["h"], "name": info["name"], "len": info["len"], "skins": [],
                                      "deform": True}
                e["skins"].append((di, b))
        # helpers between two bones (and nothing else in between) become bones that do not deform
        for key in list(bones):
            h = bones[key]["h"]
            if h is None:
                continue
            path, p = [], self._max_parent(h)
            while p is not None and p not in bones:
                path.append(p)
                p = self._max_parent(p)
            if p is None or not path or not all(self._skeleton_node(x) for x in path):
                continue
            for x in path:
                r = self.rec_by_h[x]
                box, sz = r.get("box"), r.get("size")
                ln = (max(abs(float(v)) for v in box) * u if box else float(sz) * u if sz else 0.1 * mesh_size)
                bones[x] = {"h": x, "name": (r.get("name") or "node")[:63], "skins": [], "deform": False,
                            "len": min(max(ln, 0.02 * mesh_size), 0.5 * mesh_size)}
        # bone parents: the nearest 3ds Max ancestor that is a bone; parents first
        for key, e in bones.items():
            e["parent"] = None
            p = self._max_parent(e["h"]) if e["h"] is not None else None
            while p is not None:
                if p in bones:
                    e["parent"] = p
                    break
                p = self._max_parent(p)

        def depth(key):
            n, p = 0, bones[key]["parent"]
            while p is not None:
                n, p = n + 1, bones[p]["parent"]
            return n
        order = sorted(bones, key=depth)
        for key in order:
            bones[key]["convert"] = self._skeleton_node(bones[key]["h"])
        # the armature's parent: the nearest common ancestor of the skinned meshes and of the root
        # bones' anchors (the objects they hang under in 3ds Max), when the meshes keep still against it
        mesh_hs = [d["rec"].get("h") for d in datas]
        roots = [bones[k] for k in order if bones[k]["parent"] is None and bones[k]["h"] is not None]
        for e in roots:
            e["anchor"] = self._object_above(e["h"])
        anchors = list(collections.OrderedDict((e["anchor"], 1) for e in roots))
        P = self._common_ancestor(anchors + mesh_hs)
        if not all(self._rigid_link(m, P) for m in mesh_hs):
            P = mesh_hs[0]
        # root bones linked to other objects than the armature's parent: every root bone that becomes a
        # bone follows its anchor with a Child Of constraint (the bones keep their 3ds Max links)
        chained = [e for e in roots if e["convert"] and e["anchor"] is not None]
        use_childof = any(e["anchor"] != P for e in chained)
        for e in roots:
            e["childof"] = use_childof and e in chained
        notes = []
        loose = [d["obj"].name for d in datas if not self._rigid_link(d["rec"].get("h"), P)]
        if loose:
            rep.warning("armature of %s: %s moves against it; that skin follows its object's motion in Blender, "
                        "not in 3ds Max" % (datas[0]["obj"].name, ", ".join("'%s'" % n for n in loose)))
        first = datas[0]["obj"]
        arm_data = bpy.data.armatures.new(first.name + "_Armature")
        arm = bpy.data.objects.new(first.name + "_Armature", arm_data)
        ref = self.objs.get(roots[0]["h"]) if roots else None
        for col in (ref.users_collection if ref is not None else first.users_collection):
            col.objects.link(arm)
        if P is not None:
            kp = self.residual.get(P)
            arm.parent = self.objs[P]
            arm.matrix_parent_inverse = kp.copy() if kp is not None else Matrix.Identity(4)
        arm.matrix_basis = Matrix.Identity(4)
        A = self._node_world(P) if P is not None else Matrix.Identity(4)
        Ainv = A.inverted()
        # rest frames: a Skin bone's bind (same deformation in every skin of the group), a helper's
        # frame at the export frame. pose = A^-1 @ node world @ C (C: e["C"])
        n_conv = 0
        for key in order:
            e = bones[key]
            h = e["h"]
            r = self.rec_by_h.get(h) or {}
            n_conv += e["convert"]
            if e["convert"]:
                C = max_bone_frame(r) if r.get("class") in SKELETON_CLASSES else dummy_bone_frame(r)
            else:
                C = Matrix.Identity(4)
            Kp = N = None
            if e["skins"]:
                di, b = e["skins"][0]
                d = datas[di]
                Kp = d["bones"][b]["k"] @ d["obj"].matrix_world.inverted() @ A     # armature space -> bone frame
                rest0 = Kp.inverted() @ C
                for di2, b2 in e["skins"][1:]:
                    d2 = datas[di2]
                    K2 = d2["bones"][b2]["k"] @ d2["obj"].matrix_world.inverted() @ A
                    dpos, dax = tm_error(K2.inverted() @ C, rest0)
                    if dpos > POS_TOL + SKIN_TOL_REL * mesh_size or dax > AXIS_TOL:
                        notes.append("bone '%s' is bound elsewhere in '%s' than in '%s' (%.3g m, %.3g): '%s' deforms "
                                     "differently" % (e["name"], d2["obj"].name, d["obj"].name, dpos, dax,
                                                      d2["obj"].name))
            else:
                N = self._node_world(h)
                rest0 = Ainv @ N @ C
            rigid = _is_rigid(rest0.to_3x3())
            rest = _orthonormal(rest0) if rigid else _rigid_part(rest0)
            if rigid:
                Cfix = C
            elif Kp is not None:
                Cfix = Kp @ rest
            else:
                Cfix = N.inverted() @ A @ rest
            e.update(rest=rest, C=Cfix, rigid=rigid, connect=False)
        # a bone with one child bone straight ahead on its Y axis reaches to it, and the child connects
        # when it is a 3ds Max node at its bind place whose position is not animated. Connecting moves
        # the child's head onto the parent's axis: allowed up to 1e-5 rad of turn of the child
        kids = collections.defaultdict(list)
        for key in order:
            if bones[key]["parent"] is not None:
                kids[bones[key]["parent"]].append(key)
        for key in order:
            e = bones[key]
            inv = e["rest"].inverted()
            ahead = []
            for ck in kids.get(key, []):
                v = inv @ bones[ck]["rest"].translation
                if v.y > 1e-3 * mesh_size and math.hypot(v.x, v.z) <= 1e-5 * bones[ck]["len"]:
                    ahead.append((ck, v.y))
            if len(ahead) != 1:
                continue
            ck, dist = ahead[0]
            e["len"] = dist
            c = bones[ck]
            a = (self.rec_by_h.get(c["h"]) or {}).get("anim") or {}
            moves = self.opts.animation and (a.get("mode") == "bake" or
                                             any(t.get("ch") == "location" for t in a.get("tracks", [])))
            if c["convert"] and not moves:
                here = (Ainv @ self._node_world(c["h"]) @ c["C"]).translation
                c["connect"] = (here - c["rest"].translation).length <= max(1e-6, 1e-6 * mesh_size)

        def build(ebs):
            for key in order:
                e = bones[key]
                eb = ebs.new(e["name"])
                eb.head = (0.0, 0.0, 0.0)
                eb.tail = (0.0, e["len"], 0.0)
                eb.matrix = e["rest"]
                eb.use_deform = e["deform"]
                e["name"] = eb.name
            for key in order:
                e = bones[key]
                if e["parent"] is not None:
                    eb = ebs[e["name"]]
                    eb.parent = ebs[bones[e["parent"]]["name"]]
                    eb.use_connect = e["connect"]

        _edit_bones(self.context, arm, build)
        arm.show_in_front = True
        arm["max_skin_of"] = ", ".join(d["obj"].name for d in datas)
        arm["max_bone_axes"] = ("dummy / point: bone = node @ Rx(-90) (dummy Z = -bone Y), or the axes in its user "
                                "property BlenderBoneAxes; 3ds Max bone: bone Y along its geometry (node X, or as the "
                                "object offset turns it)")
        for key in order:
            e = bones[key]
            bone = arm.data.bones[e["name"]]
            e["rest"] = bone.matrix_local.copy()             # as Blender keeps it
            if e["h"] is None:
                continue
            r = self.rec_by_h[e["h"]]
            bone["max_handle"] = int(e["h"])
            bone["max_name"] = r.get("name", "")
            bone["max_class"] = r.get("class", "")
            bone["max_kind"] = r.get("kind", "")
            if r.get("box"):
                bone["max_box"] = [float(x) for x in r["box"]]
            if r.get("size") is not None:
                bone["max_size"] = float(r["size"])
            if e["convert"] and r.get("hidden"):
                bone.hide = True
        # root bones that follow their own 3ds Max parent object: Child Of, the inverse set to the
        # armature's place (bone world = anchor world @ inverse @ pose matrix; the constraint's owner
        # space is the pose space)
        linked = []
        for e in roots:
            if not e["childof"]:
                continue
            tgt = self.objs[e["anchor"]]
            con = arm.pose.bones[e["name"]].constraints.new('CHILD_OF')
            con.name = "Child Of"
            con.target = tgt
            con.owner_space = 'POSE'
            con.target_space = 'WORLD'
            e["Q"] = tgt.matrix_world.inverted() @ A
            con.inverse_matrix = e["Q"]
            linked.append("%s -> %s" % (e["name"], tgt.name))
        # bones that follow 3ds Max objects (geometry used as Skin bones, or every bone with
        # "Dummies -> Bones" off)
        helpers = 0
        for key in order:
            e = bones[key]
            if e["convert"] or e["h"] is None or self.objs.get(e["h"]) is None:
                continue
            target = self.objs[e["h"]]
            if not e["rigid"]:
                # scaled / mirrored bind: an Empty under the object carries the part a bone's rest pose
                # can't hold (bone world = node world @ C)
                hobj = bpy.data.objects.new(target.name + " skin bind", None)
                for col in target.users_collection:
                    col.objects.link(hobj)
                hobj.parent = target
                kres = self.residual.get(e["h"])
                hobj.matrix_parent_inverse = (kres @ e["C"]) if kres is not None else e["C"].copy()
                hobj.matrix_basis = Matrix.Identity(4)
                hobj.empty_display_type = 'PLAIN_AXES'
                hobj.empty_display_size = e["len"] * 0.25
                hobj.hide_render = True
                try:
                    hobj.hide_set(True)
                except Exception:
                    pass
                target = hobj
                helpers += 1
            con = arm.pose.bones[e["name"]].constraints.new('COPY_TRANSFORMS')
            con.name = "3ds Max bone"
            con.target = target
        # weights and Armature modifiers
        for di, d in enumerate(datas):
            obj = d["obj"]
            groups = {}
            for key in order:
                e = bones[key]
                for dj, b in e["skins"]:
                    if dj == di:
                        groups[b] = obj.vertex_groups.get(e["name"]) or obj.vertex_groups.new(name=e["name"])
            lost = 0
            for v, b, w in zip(d["vidx"].tolist(), d["ids"].tolist(), d["wts"].tolist()):
                vg = groups.get(b)
                if vg is None:
                    lost += 1
                    continue
                vg.add([v], w, 'REPLACE')
            dnotes = list(d["notes"])
            if lost:
                dnotes.append("%d weights on bones left out" % lost)
            md = obj.modifiers.new("Armature", 'ARMATURE')
            md.object = arm
            md.use_vertex_groups = True
            md.use_bone_envelopes = False
            md.use_deform_preserve_volume = bool(d["rec"]["skin"].get("dq"))
            if d["solved"] is not None:
                nchk = sum(1 for c in d["rec"]["skin"].get("check", [])
                           if int((c.get("verts") or {}).get("nv", -1)) == len(obj.data.vertices))
                dnotes.insert(0, "bind matrices solved from 3ds Max's skinned mesh at %d check frames%s" % (
                    nchk, "" if d["solved"][2] else "; the bones never move apart there, so poses far from those "
                                                     "may deform differently"))
            obj["max_skin"] = "solved from the check frames" if d["solved"] is not None else str(d["reading"])
            self.skins.append({"obj": obj, "rec": d["rec"], "arm": arm, "reading": d["reading"], "err": d["err"],
                               "alt": d["alt"], "n_ev": d["n_ev"], "size": d["size"], "helpers": helpers,
                               "bones": sum(1 for b in d["bones"] if b is not None), "notes": dnotes + notes,
                               "pairs": d["pairs"], "solved": d["solved"] is not None})
        self.rigs.append({"arm": arm, "bones": bones, "order": order, "P": P})
        rep.log("armature '%s': %d bones (%d of them 3ds Max %s, %d follow 3ds Max objects, %d connected), under %s"
                % (arm.name, len(bones), n_conv, "dummies / points / bones" if n_conv else "nodes",
                   sum(1 for e in bones.values() if not e["convert"] and e["h"] is not None and e["h"] in self.objs),
                   sum(1 for e in bones.values() if e["connect"]),
                   "'%s'" % self.objs[P].name if P is not None else "the world"), console=bool(linked))
        if linked:
            rep.log("   root bones linked to different objects in 3ds Max: one armature, each root bone follows its "
                    "3ds Max parent with Child Of: %s" % ", ".join(linked), console=True)

    def bones_from_dummies(self, export_frame):
        """The 3ds Max nodes that became bones: their motion goes onto the pose bones (their own keys,
        mapped to the bone's axes, where the bone's rest frame allows it; else a key per frame), their
        other children are parented to the bones and their objects are deleted."""
        rep = self.report
        scene = self.context.scene
        jobs = [(rig, rig["bones"][k]) for rig in self.rigs for k in rig["order"]
                if rig["bones"][k]["convert"] and self.objs.get(rig["bones"][k]["h"]) is not None]
        if not jobs:
            return
        t0 = time.time()
        scene.frame_set(int(math.floor(export_frame)), subframe=export_frame - math.floor(export_frame))
        self.context.view_layer.update()
        converted = {e["h"] for _, e in jobs}
        exact, bake = [], []
        for rig, e in jobs:
            arm = rig["arm"]
            E = self.objs[e["h"]]
            rest = arm.data.bones[e["name"]].matrix_local.copy()
            pe = rig["bones"][e["parent"]] if e["parent"] is not None else None
            # bone basis(t) = G^-1 @ E's basis(t) @ C when E's parent moves with the bone's parent frame
            epw = (E.parent.matrix_world @ E.matrix_parent_inverse) if E.parent is not None else Matrix.Identity(4)
            G = None
            if pe is None and e.get("childof"):
                # Child Of: bone world = anchor world @ Q @ pose matrix, so E's own keys fit when E hangs
                # under the anchor (its world = anchor world @ parent inverse @ basis)
                ref = e["anchor"]
                if E.parent is not None and E.parent == self.objs.get(ref):
                    G = E.matrix_parent_inverse.inverted() @ e["Q"] @ rest
            elif pe is None:
                ref = rig["P"]
                G = (arm.matrix_world.inverted() @ epw).inverted() @ rest
            elif pe["h"] is not None and self._node_world(pe["h"]) is not None:
                ref = pe["h"]
                rest_rel = arm.data.bones[pe["name"]].matrix_local.inverted() @ rest
                G = (self._node_world(pe["h"]).inverted() @ epw).inverted() @ pe["C"] @ rest_rel
            order = E.rotation_mode if E.rotation_mode in EULER_ORDERS else 'XYZ'
            perm = None
            if G is not None and e["rigid"] and self._rigid_link(self._max_parent(e["h"]), ref):
                c3 = e["C"].to_3x3()
                g3 = G.to_3x3()
                perm = _signed_permutation(c3.inverted())
                # rest frames as Blender keeps them (float32, connected heads) may turn by up to 1e-5 rad
                if perm is not None and (not _is_rigid(g3, 1e-5) or
                                         max(abs(g3[i][j] - c3[i][j]) for i in range(3) for j in range(3)) > 1e-5):
                    perm = None
            pb = arm.pose.bones[e["name"]]
            if perm is not None:
                turned = any(len(fc.keyframe_points) for fc in (find_fcurve(E, "rotation_euler", j) for j in range(3))
                             if fc is not None) if E.animation_data is not None else False
                exact.append((rig, e, E, pb, perm, G.translation.copy(), order, turned))
            else:
                pb.rotation_mode = 'QUATERNION'
                bake.append((rig, e, E, pb, pe, rest))
        # their own keys, mapped to the bone's axes: E's axis j is the bone's axis perm[j][0], times
        # perm[j][1]; locations shifted by the bone's rest offset
        n_curves = 0
        n_keyed = n_baked = 0
        for rig, e, E, pb, perm, g, order, turned in exact:
            arm = rig["arm"]
            had = n_curves
            # Euler keys keep their own axes (the 3ds Max order with the axes mapped); a bone whose rotation
            # does not move uses quaternions, as Blender's bones do
            border = "".join("XYZ"[perm["XYZ".index(c)][0]] for c in order)
            pb.rotation_mode = border
            for path in ("location", "rotation_euler", "scale"):
                for j in range(3):
                    i, s = perm[j]
                    if path == "location":
                        mul, add = s, -s * g[j]
                    elif path == "rotation_euler":
                        mul, add = s, 0.0
                    else:
                        mul, add = 1.0, 0.0
                    vec = getattr(pb, path)
                    vec[i] = getattr(E, path)[j] * mul + add
                    fc = find_fcurve(E, path, j) if E.animation_data is not None else None
                    if fc is not None and len(fc.keyframe_points):
                        copy_fcurve_to_bone(fc, arm, pb, path, i, mul, add)
                        n_curves += 1
            if not turned:
                q = Euler(tuple(pb.rotation_euler), border).to_quaternion()
                pb.rotation_mode = 'QUATERNION'
                pb.rotation_quaternion = q
            n_keyed += n_curves > had
        # a key per frame where the bone's rest frame is turned against its parent (or E's parent
        # moves against the bone's parent)
        lost_worst = (0.0, "")
        if bake:
            if self.opts.animation and any(self._animated(x) for x in self.rec_by_h):
                frames = list(range(int(scene.frame_start), int(scene.frame_end) + 1))
            else:
                frames = [int(round(export_frame))]
            samples = [[] for _ in bake]
            reach = [1.0] * len(bake)       # largest world distance in the samples: their float32 noise
            for f in frames:
                scene.frame_set(f)
                for n, (rig, e, E, pb, pe, rest) in enumerate(bake):
                    arm = rig["arm"]
                    ainv = arm.matrix_world.inverted()
                    nw_e = self._node_world(e["h"])
                    reach[n] = max(reach[n], arm.matrix_world.translation.length, nw_e.translation.length)
                    pose = ainv @ nw_e @ e["C"]
                    if pe is None and e.get("childof"):
                        # bone world = anchor world @ Q @ rest @ basis
                        space = self.objs[e["anchor"]].matrix_world @ e["Q"]
                        basis = rest.inverted() @ space.inverted() @ nw_e @ e["C"]
                    elif pe is None:
                        basis = rest.inverted() @ pose
                    else:
                        rest_p = arm.data.bones[pe["name"]].matrix_local
                        nw = self._node_world(pe["h"]) if pe["h"] is not None else None
                        pose_p = ainv @ nw @ pe["C"] if nw is not None else rest_p
                        basis = (rest_p.inverted() @ rest).inverted() @ pose_p.inverted() @ pose
                    samples[n].append(basis)
            for n, (rig, e, E, pb, pe, rest) in enumerate(bake):
                arm = rig["arm"]
                locs, rots, scls = [], [], []
                prev = None
                for m in samples[n]:
                    loc, q, sc = m.decompose()
                    lost = max(abs(Matrix.LocRotScale(loc, q, sc)[i][j] - m[i][j]) for i in range(3) for j in range(4))
                    if lost > lost_worst[0]:
                        lost_worst = (lost, "%s / %s" % (arm.name, pb.name))
                    if prev is not None and prev.dot(q) < 0.0:
                        q.negate()
                    prev = q
                    locs.append(loc)
                    rots.append(q)
                    scls.append(sc)
                # a channel that only shows the float32 noise of the world matrices stays a value
                had = n_curves
                for path, seq, tol in (("location", locs, max(1e-6, 3e-7 * reach[n])),
                                       ("rotation_quaternion", rots, 2e-6), ("scale", scls, 2e-6)):
                    for i in range(4 if path == "rotation_quaternion" else 3):
                        vals = [float(v[i]) for v in seq]
                        vec = getattr(pb, path)
                        if max(vals) - min(vals) <= tol * max(1.0, max(abs(x) for x in vals)):
                            vec[i] = sum(vals) / len(vals) if path != "rotation_quaternion" else vals[0]
                            continue
                        bone_fcurve(arm, pb, path, i, frames, vals, 'LINEAR')
                        n_curves += 1
                if n_curves > had:
                    n_baked += 1
                    self.baked_bones.add(e["h"])
        # the nodes' other children hang on the bones now (bone parent frame = bone pose at its tail)
        moved = 0
        for rig, e, E, pb, *more in exact + bake:
            arm = rig["arm"]
            bone = arm.data.bones[e["name"]]
            fix = (e["C"] @ Matrix.Translation((0.0, bone.length, 0.0))).inverted()
            for ch in list(E.children):
                if ch.get("max_handle") in converted and ch.type != 'ARMATURE':
                    continue
                mpi = ch.matrix_parent_inverse.copy()
                ch.parent = arm
                ch.parent_type = 'BONE'
                ch.parent_bone = bone.name
                ch.matrix_parent_inverse = fix @ mpi
                moved += 1
        # a Child Of whose object became a bone of another armature follows that bone (same motion:
        # the bone's world is the object's world @ C)
        retarget = [(rig, rig["bones"][k]) for rig in self.rigs for k in rig["order"]
                    if rig["bones"][k].get("childof") and rig["bones"][k]["anchor"] in converted]
        if retarget:
            scene.frame_set(int(math.floor(export_frame)), subframe=export_frame - math.floor(export_frame))
            self.context.view_layer.update()
            for rig, e in retarget:
                own = next(((r2["arm"], r2["bones"][e["anchor"]]["name"]) for r2 in self.rigs
                            if e["anchor"] in r2["bones"] and r2["bones"][e["anchor"]]["convert"]), None)
                con = next((c for c in rig["arm"].pose.bones[e["name"]].constraints if c.type == 'CHILD_OF'), None)
                if own is None or con is None:
                    continue
                arm2, bname = own
                t_old = self.objs[e["anchor"]].matrix_world.copy()
                t_new = arm2.matrix_world @ arm2.pose.bones[bname].matrix
                con.target = arm2
                con.subtarget = bname
                e["Q"] = t_new.inverted() @ t_old @ e["Q"]
                con.inverse_matrix = e["Q"]
        removed = 0
        for rig, e in jobs:
            E = self.objs.pop(e["h"])
            bone = rig["arm"].data.bones[e["name"]]
            for k in list(E.keys()):            # the node's 3ds Max properties (user properties...) stay on its bone
                if k.startswith("_") or k in bone:
                    continue
                v = E[k]
                try:
                    bone[k] = v.to_dict() if hasattr(v, "to_dict") else v.to_list() if hasattr(v, "to_list") else v
                except Exception:
                    pass
            act = E.animation_data.action if E.animation_data is not None else None
            bpy.data.objects.remove(E, do_unlink=True)
            if act is not None and act.users == 0:
                bpy.data.actions.remove(act)
            self.bone_nodes[e["h"]] = (rig["arm"], e["name"], e["C"].copy())
            removed += 1
        scene.frame_set(int(math.floor(export_frame)), subframe=export_frame - math.floor(export_frame))
        self.context.view_layer.update()
        rep.log("skin bones: %d 3ds Max nodes became bones: %d with their own keys on the bone axes, %d keyed on every "
                "frame (bind turned against the parent, or a parent that moves between them), %d without keys; %d "
                "F-curves on the bones in all; %d other objects now hang on bones; %d objects removed; %.1f s"
                % (len(jobs), n_keyed, n_baked, len(jobs) - n_keyed - n_baked, n_curves, moved, removed,
                   time.time() - t0), console=True)
        if lost_worst[0] > 1e-5:
            rep.warning("skin bones: a shear in the bone motion can't be keyed (largest %.3g, %s): the deformation "
                        "differs there" % lost_worst)


    def bake_skin_bones(self):
        """Bone keys on every frame of the range from the Copy Transforms result; those constraints
        removed (Child Of on root bones stays: it is the link to the 3ds Max parent)."""
        scene = self.context.scene
        frames = list(range(int(scene.frame_start), int(scene.frame_end) + 1))
        if not frames or not self.skins:
            return
        arms = list(collections.OrderedDict((s["arm"].name, s["arm"]) for s in self.skins).values())
        data = {}
        for arm in arms:                        # skins that share bones share one armature
            data[arm.name] = {pb.name: [] for pb in arm.pose.bones
                              if any(c.type == 'COPY_TRANSFORMS' for c in pb.constraints)}
        if not any(data.values()):
            return
        for f in frames:
            scene.frame_set(f)
            for arm in arms:
                for name, seq in data[arm.name].items():
                    pb = arm.pose.bones[name]
                    m = arm.convert_space(pose_bone=pb, matrix=pb.matrix, from_space='POSE', to_space='LOCAL')
                    d = m.decompose()
                    # location / rotation / scale keys can't hold a shear: measure what is lost
                    back = Matrix.LocRotScale(d[0], d[1], d[2])
                    lost = max(abs(back[i][j] - m[i][j]) for i in range(3) for j in range(4))
                    seq.append((d, lost))
        worst = (0.0, "")
        for arm in arms:
            for name, seq in data[arm.name].items():
                pb = arm.pose.bones[name]
                for con in list(pb.constraints):
                    if con.type == 'COPY_TRANSFORMS':
                        pb.constraints.remove(con)
                pb.rotation_mode = 'QUATERNION'
                lost = max(x[1] for x in seq)
                if lost > worst[0]:
                    worst = (lost, "%s / %s" % (arm.name, name))
                seq = [x[0] for x in seq]
                locs = [d[0] for d in seq]
                quats = []
                prev = None
                for d in seq:
                    q = d[1].copy()
                    if prev is not None and prev.dot(q) < 0.0:
                        q.negate()
                    quats.append(q)
                    prev = q
                scls = [d[2] for d in seq]
                pb.location, pb.rotation_quaternion, pb.scale = locs[0], quats[0], scls[0]
                # a channel that only shows float32 noise stays a value
                for path, seq2, n, tol in (("location", locs, 3, 1e-6), ("rotation_quaternion", quats, 4, 2e-6),
                                           ("scale", scls, 3, 2e-6)):
                    for i in range(n):
                        vals = [float(v[i]) for v in seq2]
                        if max(vals) - min(vals) <= tol * max(1.0, max(abs(x) for x in vals)):
                            getattr(pb, path)[i] = vals[0]
                            continue
                        bone_fcurve(arm, pb, path, i, frames, vals, 'LINEAR')
        self.report.log("skin: bone keys on %d frames for the %d bones that followed 3ds Max objects (constraints "
                        "removed)" % (len(frames), sum(len(v) for v in data.values())), console=True)
        if worst[0] > 1e-5:
            self.report.warning("skin: a shear in the bone motion can't be keyed (largest %.3g, %s): the deformation "
                                "differs there; with 'Bone keys' off the bones follow the 3ds Max objects exactly"
                                % worst)

    def check_skins(self, u, export_frame):
        """The deformed meshes against the skinned meshes 3ds Max wrote at the check frames (with Animation
        off, only at the export frame: nothing moves in Blender)."""
        rep = self.report
        scene = self.context.scene
        rows = []
        for s in self.skins:
            obj, sk = s["obj"], s["rec"]["skin"]
            nv = int(sk["nv"])
            others = [m for m in obj.modifiers if m.type != 'ARMATURE' and m.show_viewport]
            for m in others:
                m.show_viewport = False
            worst = (0.0, None)
            try:
                for c in sk.get("check", []):
                    vr = c.get("verts") or {}
                    if int(vr.get("nv", -1)) != nv:
                        continue
                    fr = float(c["frame"])
                    if not self.opts.animation and abs(fr - export_frame) > 1e-9:
                        continue
                    scene.frame_set(int(math.floor(fr)), subframe=fr - math.floor(fr))
                    dg = self.context.evaluated_depsgraph_get()
                    co, _ = self._eval_mesh(obj, dg)
                    if len(co) != nv:
                        continue
                    mw = np.array(obj.evaluated_get(dg).matrix_world)
                    world = co @ mw[:3, :3].T + mw[:3, 3]
                    ref = np.frombuffer(self.blob, dtype="<f4", count=nv * 3, offset=int(vr["at"]))
                    ref = ref.reshape(nv, 3).astype(np.float64) * u
                    d = float(np.linalg.norm(world - ref, axis=1).max())
                    if worst[1] is None or d > worst[0]:
                        worst = (d, fr)
            finally:
                for m in others:
                    m.show_viewport = True
            tol = max(1e-5, SKIN_TOL_REL * s["size"] * u)
            rows.append((worst[0], worst[1], tol, obj.name, len(sk.get("check", []))))
        self.skin_rows = rows
        if rows:
            good = sum(1 for r in rows if r[1] is not None and r[0] <= r[2])
            rep.log("skin check: %d skinned meshes against 3ds Max's at their check frames%s: %d within "
                    "tolerance (1e-4 of the mesh size)" % (len(rows), "" if self.opts.animation else
                                                           " (Animation off: the export frame only)", good),
                    console=True)
            for d, fr, tol, name, n in rows:
                if fr is None:
                    rep.log("   %-34s no check frame could be compared" % name)
                else:
                    rep.log("   %-34s worst vertex %.3g mm at frame %g (%d check frames)%s"
                            % (name, d * self.mm, fr, n, "" if d <= tol else "  <-- off"), console=d > tol)
            if good < len(rows):
                rep.warning("%d skinned meshes differ from 3ds Max (details above)" % (len(rows) - good))

    # ── verification ─────────────────────────────────────────────────────
    def verify(self, nodes, u, export_frame):
        rep = self.report
        scene = self.context.scene
        checks = {}                       # frame -> [(obj, Matrix, shear part or None)]
        # a baked node (and everything under it) has keys on whole frames of the range only:
        # in between and outside, 3ds Max's procedural motion can't be compared
        baked = set()
        for rec in nodes:
            a = rec.get("anim") or {}
            if (a.get("mode") == "bake" and self.opts.animation) or rec.get("parent") in baked:
                baked.add(rec.get("h"))
        f0 = float(scene.frame_start)
        f1 = float(scene.frame_end)
        skipped = 0
        baked |= self.baked_bones
        for rec in nodes:
            if rec.get("parent") in baked:
                baked.add(rec.get("h"))
        for rec in nodes:
            obj = self.objs.get(rec.get("h"))
            if "world" not in rec:
                continue
            if obj is not None:
                label, get = obj.name, (lambda o=obj: o.matrix_world)
            elif rec.get("h") in self.bone_nodes:
                arm, bname, c = self.bone_nodes[rec["h"]]
                label = "%s (bone of '%s')" % (bname, arm.name)
                get = (lambda a=arm, pb=arm.pose.bones[bname], ci=c.inverted(): a.matrix_world @ pb.matrix @ ci)
            else:
                continue
            k = self.residual.get(rec.get("h"))
            ptol = POS_TOL + FLOAT_REL * self.chain_len.get(rec.get("h"), 0.0)
            checks.setdefault(export_frame, []).append((label, get, max_tm(rec["world"], u), k, ptol))
            anim = rec.get("anim") or {}
            vf = (anim.get("verify") or {}) if self.opts.animation else {}     # Animation off: nothing moves
            in_baked = rec.get("h") in baked
            for fr, w in zip(vf.get("frames", []), vf.get("world", [])):
                fr = float(fr)
                if abs(fr - export_frame) <= 1e-9:
                    continue
                if in_baked and (fr != math.floor(fr) or fr < f0 or fr > f1):
                    skipped += 1
                    continue
                checks.setdefault(fr, []).append((label, get, max_tm(w, u), k, ptol))
        worst = {}                        # obj name -> (dpos, dax, frame, position tolerance)
        n_checks = 0
        n_far = 0
        for fr in sorted(checks):
            scene.frame_set(int(math.floor(fr)), subframe=fr - math.floor(fr))
            for label, get, mw, k, ptol in checks[fr]:
                # a sheared node: its shear part sits in the data / the children's parent inverse
                cur_m = get()
                eff = cur_m @ k if k is not None else cur_m
                dpos, dax = tm_error(eff, mw)
                n_checks += 1
                cur = worst.get(label)
                if cur is None or dpos / ptol + dax / AXIS_TOL > cur[0] / cur[3] + cur[1] / AXIS_TOL:
                    worst[label] = (dpos, dax, fr, ptol)
        bad = [(k, v) for k, v in worst.items() if v[0] > v[3] or v[1] > AXIS_TOL]
        n_far = sum(1 for v in worst.values() if POS_TOL < v[0] <= v[3] and v[1] <= AXIS_TOL)
        bad.sort(key=lambda kv: -(kv[1][0] / kv[1][3] + kv[1][1] / AXIS_TOL))
        mpu = self.mm / 1000.0                     # meters per Blender unit
        rep.log("check: %d world matrices at %d frames; %d objects off by more than %.2g m (plus 32-bit float "
                "rounding of long parent chains) / %.2g" % (n_checks, len(checks), len(bad), POS_TOL * mpu, AXIS_TOL),
                console=True)
        if n_far:
            rep.log("check: %d objects far down long chains (e.g. image planes 1 km from their camera) are off by "
                    "more than %.2g m but within float rounding of their chain" % (n_far, POS_TOL * mpu))
        if skipped:
            rep.log("check: %d sub-frame or out-of-range checks skipped under baked nodes" % skipped)
        for name, (dpos, dax, fr, ptol) in bad[:15]:
            rep.log("   %-40s position %.4g m, axes %.4g at frame %g" % (name, dpos * mpu, dax, fr), console=True)
        # world bounding boxes of meshes at the export frame
        scene.frame_set(int(math.floor(export_frame)), subframe=export_frame - math.floor(export_frame))
        cache = {}
        bbad = []
        nb = 0
        # 3ds Max reports node.min / max as the object-space box carried into world space
        # (its 8 corners through offset x node matrix), not the tight box of the vertices
        for rec in nodes:
            obj = self.objs.get(rec.get("h"))
            wb = rec.get("wbox")
            if obj is None or obj.type != 'MESH' or not wb:
                continue
            me = obj.data
            deformed = bool(rec.get("live")) or any(m.type == 'ARMATURE' for m in obj.modifiers)
            ckey = me.name + ("#eval" if deformed else "")
            if ckey not in cache:
                if deformed:                        # 3ds Max's box is the one of the final mesh
                    cache[ckey] = self._eval_mesh(obj, self.context.evaluated_depsgraph_get())[0]
                else:
                    co = np.empty(len(me.vertices) * 3, dtype=np.float64)
                    me.vertices.foreach_get("co", co)
                    cache[ckey] = co.reshape(-1, 3)
            co = cache[ckey]
            if len(co) == 0:
                continue
            m = np.array(obj.matrix_world)
            k = self.residual.get(rec.get("h"))
            if k is not None:                       # sheared node: its shear part sits in the data
                m = m @ np.array(k)
                ki = np.linalg.inv(np.array(k))
                co = co @ ki[:3, :3].T + ki[:3, 3]
            if rec.get("offset"):
                off = np.array(max_tm(rec["offset"], u))
                oi = np.linalg.inv(off)
                co = co @ oi[:3, :3].T + oi[:3, 3]  # pivot space -> object space
                m = m @ off
            omin, omax = co.min(axis=0), co.max(axis=0)
            corners = np.array([[x, y, z] for x in (omin[0], omax[0]) for y in (omin[1], omax[1])
                                for z in (omin[2], omax[2])])
            wco = corners @ m[:3, :3].T + m[:3, 3]
            bmin, bmax = wco.min(axis=0), wco.max(axis=0)
            mmin = np.array(wb[0]) * u
            mmax = np.array(wb[1]) * u
            size = max(float(np.max(mmax - mmin)), 1e-9)
            err = float(max(np.max(np.abs(bmin - mmin)), np.max(np.abs(bmax - mmax))))
            nb += 1
            if err > max(POS_TOL, BBOX_TOL_REL * size):
                bbad.append((err, obj.name, size))
        bbad.sort(reverse=True)
        rep.log("check: %d mesh bounding boxes; %d differ from 3ds Max" % (nb, len(bbad)), console=True)
        for err, name, size in bbad[:15]:
            rep.log("   %-40s bounding box off by %.4g m (size %.4g m)" % (name, err * self.mm / 1000.0,
                                                                         size * self.mm / 1000.0), console=True)
        self.verify_rows = bad
        self.bbox_bad = bbad
        if bad or bbad:
            rep.warning("%d transforms and %d bounding boxes differ from 3ds Max (details above)" % (len(bad), len(bbad)))

    def _eval_mesh(self, obj, dg):
        """Vertices (object space) and triangle count of the evaluated mesh."""
        ev = obj.evaluated_get(dg)
        me = ev.to_mesh()
        try:
            co = np.empty(len(me.vertices) * 3, dtype=np.float64)
            me.vertices.foreach_get("co", co)
            lt = np.empty(len(me.polygons), np.int64)
            me.polygons.foreach_get("loop_total", lt)
            ntri = int((lt - 2).sum()) if len(lt) else 0
        finally:
            ev.to_mesh_clear()
        return co.reshape(-1, 3), ntri

    def check_live(self, nodes, u):
        """Live Subdivision / Solidify against the final vertices 3ds Max wrote. Where the
        result is off, the other boundary / thickness rules are tried and the closest kept."""
        rep = self.report
        t0 = time.time()
        users = collections.OrderedDict()            # mesh name -> [(object, record)]
        for rec in nodes:
            obj = self.objs.get(rec.get("h"))
            if rec.get("final") and rec.get("live") and obj is not None and obj.type == 'MESH':
                users.setdefault(obj.data.name, []).append((obj, rec))
        tuned = collections.Counter()
        rows = []
        for mname, lst in users.items():
            obj, rec = lst[0]
            fin = rec["final"]
            nv = int(fin["nv"])
            ref = np.frombuffer(self.blob, dtype="<f4", count=nv * 3, offset=int(fin["at"]))
            ref = ref.reshape(-1, 3).astype(np.float64) * u
            size = float(np.max(ref.max(axis=0) - ref.min(axis=0))) if nv else 0.0
            tol = max(1e-5, 1e-4 * size)
            dg = self.context.evaluated_depsgraph_get()
            co, ntri = self._eval_mesh(obj, dg)
            dmax, dmean = deviation(co, ref)
            best_nv, best_tri = len(co), ntri
            choice = []
            if dmax > tol:
                subs = [md for md in obj.modifiers if md.type == 'SUBSURF']
                sols = [md for md in obj.modifiers if md.type == 'SOLIDIFY']
                trials = []
                if subs:
                    trials.append(("boundary_smooth", 'SUBSURF', 'PRESERVE_CORNERS'))
                if sols:
                    trials.append(("nonmanifold_thickness_mode", 'SOLIDIFY', 'EVEN'))
                    trials.append(("nonmanifold_thickness_mode", 'SOLIDIFY', 'CONSTRAINTS'))
                for attr, mtype, val in trials:
                    mods = [md for md in obj.modifiers if md.type == mtype]
                    old = [getattr(md, attr) for md in mods]
                    if all(o == val for o in old):
                        continue
                    for md in mods:
                        setattr(md, attr, val)
                    dg = self.context.evaluated_depsgraph_get()
                    dg.update()
                    co2, ntri2 = self._eval_mesh(obj, dg)
                    d2max, d2mean = deviation(co2, ref)
                    if d2max < dmax * 0.999:
                        dmax, dmean, best_nv, best_tri = d2max, d2mean, len(co2), ntri2
                        choice = [c for c in choice if c[0] != attr] + [(attr, val)]
                    else:
                        for md, o in zip(mods, old):
                            setattr(md, attr, o)
                for attr, val in choice:            # the same rule for every instance of this mesh
                    tuned[(attr, val)] += 1
                    for other, _ in lst[1:]:
                        mtype = 'SUBSURF' if attr == "boundary_smooth" else 'SOLIDIFY'
                        for md in other.modifiers:
                            if md.type == mtype:
                                setattr(md, attr, val)
            rows.append((dmax, dmean, tol, live_signature(rec["live"]), obj.name, nv, best_nv,
                         int(fin.get("nf", 0)), best_tri, size, len(lst)))
        self.live_rows = rows
        if not rows:
            return
        within = sum(1 for r in rows if r[0] <= r[2])
        same_v = sum(1 for r in rows if r[5] == r[6])
        rep.log("live check: %d meshes (%d objects) against 3ds Max's final vertices: %d within tolerance "
                "(1e-4 of their size), vertex counts equal on %d; %.1f s"
                % (len(rows), sum(r[10] for r in rows), within, same_v, time.time() - t0), console=True)
        by_sig = collections.defaultdict(list)
        for r in rows:
            by_sig[r[3]].append(r)
        for sig, rs in sorted(by_sig.items(), key=lambda kv: -len(kv[1])):
            d = np.array([r[0] for r in rs])
            w = max(rs, key=lambda r: r[0])
            rep.log("   %-34s %4d meshes, %4d within tolerance, deviation median %.3g mm, worst %.3g mm (%s)"
                    % (sig, len(rs), sum(1 for r in rs if r[0] <= r[2]), float(np.median(d)) * self.mm,
                       float(d.max()) * self.mm, w[4]), console=True)
        for (attr, val), n in sorted(tuned.items()):
            rep.log("   %s = %s matched 3ds Max better on %d meshes" % (attr, val, n), console=True)
        bad = sorted((r for r in rows if r[0] > r[2]), key=lambda r: -r[0] / max(r[9], 1e-9))
        for r in bad[:15]:
            rep.log("   %-36s %-28s off by %.3g mm (size %.3g m), vertices 3ds Max %d / Blender %d, triangles %d / %d"
                    % (r[4], r[3], r[0] * self.mm, r[9] * self.mm / 1000.0, r[5], r[6], r[7], r[8]))


def run_import(context, json_path, opts):
    imp = MaxImport(context, json_path, opts)
    try:
        return imp.run(), imp
    except Exception:
        imp.report.close()
        raise


# ─────────────────────────────────────────────────────────────────────────────
#  Settings and operators
# ─────────────────────────────────────────────────────────────────────────────

class MaxBridgeImportSettings(bpy.types.PropertyGroup):
    unit_mode: EnumProperty(
        name="Units",
        items=(('METERS', "Real size", "3ds Max sizes kept: 3ds Max system units converted to meters, in this "
                                       "scene's units (Scene > Units > Unit Scale; 1 Blender unit = 1 m by default)"),
               ('MAX_UNITS', "3ds Max units", "1 3ds Max unit = 1 Blender unit"),
               ('CUSTOM', "Custom", "Multiply 3ds Max units by a custom factor")),
        default='METERS')
    custom_scale: FloatProperty(name="Factor", default=1.0, min=1e-6, soft_max=100.0, precision=6)
    animation: BoolProperty(name="Animation", default=True)
    keep_single_keys: BoolProperty(
        name="Keep single keys", default=False,
        description="A track with one key animates nothing; off: it becomes the static value")
    materials: BoolProperty(name="Materials", default=True)
    scene_settings: BoolProperty(name="Frame rate and range", default=True,
                                 description="Take the frame rate and animation range from 3ds Max")
    verify: BoolProperty(name="Check against 3ds Max", default=True,
                         description="Compare world matrices and bounding boxes with the values 3ds Max wrote")
    rebuild_polygons: BoolProperty(name="Rebuild quads / n-gons", default=True,
                                   description="Dissolve the hidden edges of the 3ds Max triangles")
    check_live: BoolProperty(name="Check live modifiers", default=True,
                             description="Compare live Subdivision / Solidify with the final vertices 3ds Max wrote")
    custom_normals: BoolProperty(
        name="Custom Normals", default=True,
        description="On: the 3ds Max normals are baked in as custom normals, exactly the shading 3ds Max shows "
                    "(Edit Normals, Weighted Normals, normals from FBX included), like an FBX import with Custom "
                    "Normals. Off: Blender computes the normals; the hard edges stay where 3ds Max has them")
    skin: BoolProperty(name="Skin -> Armature", default=True,
                       description="A 3ds Max Skin becomes an Armature modifier with the same bones and weights; "
                                   "off: the skinned mesh as it is at the export frame")
    dummy_bones: BoolProperty(
        name="Dummies -> Bones", default=True,
        description="Dummies, points and 3ds Max bones a Skin uses become the armature's bones: their animation "
                    "goes onto the bones, their children hang on the bones, and their objects are not created. "
                    "Off: they stay objects and the bones follow them with constraints")
    bake_bones: BoolProperty(
        name="Bone keys", default=False,
        description="Bones that follow 3ds Max objects (meshes used as Skin bones, or every bone with "
                    "'Dummies -> Bones' off) get a key on every frame instead of a Copy Transforms constraint")
    check_skin: BoolProperty(name="Check skin", default=True,
                             description="Compare the deformed mesh with the skinned mesh 3ds Max wrote at its check frames")
    last_summary: StringProperty(default="")


def _opts_from(s):
    return Options(unit_mode=s.unit_mode, custom_scale=s.custom_scale, animation=s.animation,
                   keep_single_keys=s.keep_single_keys, materials=s.materials, scene_settings=s.scene_settings,
                   verify=s.verify, rebuild_polygons=s.rebuild_polygons, custom_normals=s.custom_normals,
                   check_live=s.check_live, skin=s.skin, dummy_bones=s.dummy_bones, bake_bones=s.bake_bones,
                   check_skin=s.check_skin)


def _draw_settings(layout, s):
    col = layout.column(align=True)
    col.prop(s, "unit_mode")
    if s.unit_mode == 'CUSTOM':
        col.prop(s, "custom_scale")
    col = layout.column(align=True)
    col.prop(s, "custom_normals")
    col = layout.column(align=True)
    col.prop(s, "animation")
    sub = col.row()
    sub.enabled = s.animation
    sub.prop(s, "keep_single_keys")
    col.prop(s, "materials")
    col.prop(s, "rebuild_polygons")
    col.prop(s, "skin")
    sub = col.row()
    sub.enabled = s.skin
    sub.prop(s, "dummy_bones")
    sub = col.row()
    sub.enabled = s.skin
    sub.prop(s, "bake_bones")
    col.prop(s, "scene_settings")
    col.prop(s, "verify")
    col.prop(s, "check_live")
    sub = col.row()
    sub.enabled = s.skin
    sub.prop(s, "check_skin")


def _do_import(op, context, path):
    s = context.scene.max_bridge_import
    try:
        summary, imp = run_import(context, path, _opts_from(s))
    except Exception as ex:
        op.report({'ERROR'}, "3ds Max import failed: %s" % ex)
        return {'CANCELLED'}
    s.last_summary = summary
    level = {'WARNING'} if (imp.report.errors or imp.verify_rows or getattr(imp, "bbox_bad", None)) else {'INFO'}
    op.report(level, "3ds Max import: %s (report: text '%s')" % (summary, LOG_TEXT))
    return {'FINISHED'}


class MAXBRIDGE_OT_import_file(bpy.types.Operator, ImportHelper):
    """Import a scene that 3ds Max wrote with Send to Blender (BlenderMaxBridge.ms)"""
    bl_idname = "max_bridge.import_file"
    bl_label = "Import from 3ds Max (.json)"
    bl_options = {'REGISTER', 'UNDO'}
    filename_ext = ".json"
    filter_glob: StringProperty(default="*.json", options={'HIDDEN'})

    def draw(self, context):
        _draw_settings(self.layout, context.scene.max_bridge_import)

    def execute(self, context):
        return _do_import(self, context, self.filepath)


class MAXBRIDGE_OT_import_latest(bpy.types.Operator):
    """Import the last scene sent from 3ds Max (bridge folder, FromMax/latest.json)"""
    bl_idname = "max_bridge.import_latest"
    bl_label = "Import latest from 3ds Max"
    bl_options = {'REGISTER', 'UNDO'}

    def execute(self, context):
        path = latest_export()
        if not path:
            self.report({'ERROR'}, "Nothing sent from 3ds Max yet (%s)" % exchange_dir())
            return {'CANCELLED'}
        return _do_import(self, context, path)


class MAXBRIDGE_OT_show_report(bpy.types.Operator):
    """Show the last import report in a Text Editor area, if one is open"""
    bl_idname = "max_bridge.show_report"
    bl_label = "Show report"

    def execute(self, context):
        txt = bpy.data.texts.get(LOG_TEXT)
        if txt is None:
            self.report({'WARNING'}, "No report yet")
            return {'CANCELLED'}
        for area in context.screen.areas:
            if area.type == 'TEXT_EDITOR':
                area.spaces.active.text = txt
                return {'FINISHED'}
        self.report({'INFO'}, "Open a Text Editor and pick '%s'" % LOG_TEXT)
        return {'FINISHED'}




# ═════════════════════════════════════════════════════════════════════════════
#  BRIDGE   Reset, preferences, UI, registration
# ═════════════════════════════════════════════════════════════════════════════

# ─────────────────────────────────────────────────────────────────────────────
#  Reset (both directions)
# ─────────────────────────────────────────────────────────────────────────────

_retired = []                     # names of the old add-ons this one switched off


def reset_bridge(context):
    """Back to idle when something went wrong, froze or hangs: stop waiting for 3ds Max, withdraw a job
    3ds Max has not picked up, clear the status, end a progress bar or busy cursor left behind. Scene
    data is not touched. Returns what was done, as lines."""
    done = []
    was_waiting = _transfer["state"] == "waiting"
    if bpy.app.timers.is_registered(_poll_result):
        bpy.app.timers.unregister(_poll_result)
    if was_waiting:
        done.append("stopped waiting for 3ds Max")
    folder = bridge_dir()
    job_path = os.path.join(folder, JOB_FILE)
    withdrawn = False
    if os.path.exists(job_path):
        job = _read_json(job_path) or {}
        try:
            os.remove(job_path)
            withdrawn = True
            when = time.strftime("%H:%M:%S", time.localtime(float(job.get("created") or 0.0)))
            done.append("withdrew the job 3ds Max had not picked up (sent %s)" % when)
        except (OSError, TypeError, ValueError) as ex:
            done.append("could not remove %s: %s" % (job_path, ex))
    tmp = job_path + ".tmp"
    if os.path.exists(tmp):
        try:
            os.remove(tmp)
            done.append("removed a half-written job file")
        except OSError:
            pass
    if was_waiting and not withdrawn:
        done.append("3ds Max had picked the job up: if 3ds Max hangs, press Reset there too")
    wm = context.window_manager
    try:
        wm.progress_end()
    except Exception:
        pass
    for win in wm.windows:
        try:
            win.cursor_modal_restore()
        except Exception:
            pass
    _transfer.update(id=None, t0=0.0, picked=False)
    _set_transfer("idle")
    return done


class MAXBRIDGE_OT_reset(bpy.types.Operator):
    """Put the bridge back to idle when something went wrong, froze or hangs: stop waiting for 3ds Max,
    withdraw a job 3ds Max has not picked up, clear the status and end a progress bar or busy cursor
    left behind. Scene data is not touched"""
    bl_idname = "max_bridge.reset"
    bl_label = "Reset bridge"

    def execute(self, context):
        done = reset_bridge(context)
        msg = "Bridge reset" + (": " + "; ".join(done) if done else " (it was idle)")
        print("[Max Bridge]", msg)
        self.report({'INFO'}, msg)
        return {'FINISHED'}


# ─────────────────────────────────────────────────────────────────────────────
#  Old add-ons
# ─────────────────────────────────────────────────────────────────────────────

def _retire_old_addons():
    """Switch off the add-ons this one replaces: they would add a second importer to the sidebar."""
    try:
        import addon_utils
    except ImportError:
        return None
    for module, label in OLD_ADDONS.items():
        try:
            _loaded, enabled = addon_utils.check(module)
        except Exception:
            continue
        if not enabled:
            continue
        try:
            addon_utils.disable(module, default_set=True)
            _retired.append(label)
            print("[Max Bridge] '%s' is replaced by %s %s and was switched off; remove it in "
                  "Preferences > Add-ons" % (label, bl_info["name"], ADDON_VERSION))
        except Exception as ex:
            print("[Max Bridge] could not switch off '%s': %s" % (label, ex))
    return None


# ─────────────────────────────────────────────────────────────────────────────
#  Preferences
# ─────────────────────────────────────────────────────────────────────────────

class MaxBridgePreferences(bpy.types.AddonPreferences):
    bl_idname = __name__

    bridge_dir: StringProperty(
        name="Bridge folder",
        description="Folder shared with BlenderMaxBridge.ms in 3ds Max, for both directions: the job, result "
                    "and heartbeat files of Send to 3ds Max, and in its subfolder FromMax the scenes 3ds Max "
                    "sends. Must be the same folder as in the 3ds Max dialog",
        subtype='DIR_PATH',
        default=default_bridge_dir(),
    )

    def draw(self, context):
        layout = self.layout
        layout.prop(self, "bridge_dir")
        col = layout.column(align=True)
        col.label(text="Default: " + default_bridge_dir(), icon='INFO')
        col.label(text="Scenes from 3ds Max: " + exchange_dir())
        for label in _retired:
            layout.label(text="'%s' is replaced by this add-on and was switched off: remove it." % label,
                         icon='ERROR')


# ─────────────────────────────────────────────────────────────────────────────
#  UI: sidebar tab Max Bridge
# ─────────────────────────────────────────────────────────────────────────────

class VIEW3D_PT_max_bridge(bpy.types.Panel):
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "Max Bridge"
    bl_label = "Blender -> 3ds Max"

    def draw(self, context):
        layout = self.layout
        s = context.scene.max_bridge

        alive, age = listener_status()
        row = layout.row()
        if alive:
            mu = listener_units()
            row.label(text="3ds Max listener: online" + ("" if mu in ("", "centimeters") else " (scene in %s)" % mu),
                      icon='CHECKMARK')
        else:
            row.label(text="3ds Max listener: offline", icon='ERROR')

        col = layout.column()
        col.scale_y = 1.6
        col.enabled = _transfer["state"] != "waiting"
        col.operator(MAXBRIDGE_OT_send.bl_idname, icon='EXPORT')

        if _transfer["state"] != "idle":
            box = layout.box()
            icon = {'waiting': 'TIME', 'done': 'CHECKMARK', 'error': 'ERROR'}.get(_transfer["state"], 'INFO')
            for i, line in enumerate(_transfer["lines"]):
                box.label(text=line, icon=icon if i == 0 else 'NONE')
            if _transfer["state"] == "waiting":
                box.operator(MAXBRIDGE_OT_reset.bl_idname, text="Stop waiting (Reset)", icon='CANCEL')

        box = layout.box()
        box.label(text="Settings")
        box.row().prop(s, "scope", expand=True)
        box.prop(s, "pose_frame")
        box.prop(s, "output_dir")
        box.prop(s, "base_name")
        box.prop(s, "replace_in_max")
        box.prop(s, "bones_to_dummies",
                 text="Armatures -> Bones + Skin" if s.exact_bones else "Bones -> Dummies + Skin")
        sub = box.column()
        sub.enabled = s.bones_to_dummies
        sub.prop(s, "exact_bones")
        sub.prop(s, "bake_bones")
        folder, base = _resolve_output(s)
        sub = box.column(align=True)
        sub.scale_y = 0.8
        sub.label(text=os.path.join(folder, base + ".fbx / .json"))

        row = layout.row(align=True)
        row.operator(MAXBRIDGE_OT_export_files.bl_idname, icon='FILE_TICK')
        row.operator(MAXBRIDGE_OT_open_folder.bl_idname, text="", icon='FILE_FOLDER')


def menu_func_export(self, context):
    self.layout.operator(MAXBRIDGE_OT_send.bl_idname, text="Send to 3ds Max (FBX + JSON)")
    self.layout.operator(EXPORT_OT_blender_max_json.bl_idname, text="Blender JSON (.json)")




def latest_info():
    """(JSON path, time) of the last scene 3ds Max sent (FromMax/latest.json), or (None, "")."""
    try:
        with open(os.path.join(exchange_dir(), "latest.json"), "r", encoding="utf-8-sig") as fh:
            d = json.load(fh)
        return (d.get("json") or None), str(d.get("exported") or "")
    except Exception:
        return None, ""


class MAXBRIDGE_PT_import(bpy.types.Panel):
    bl_label = "3ds Max -> Blender"
    bl_idname = "MAXBRIDGE_PT_import"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "Max Bridge"

    def draw(self, context):
        s = context.scene.max_bridge_import
        lay = self.layout
        path, when = latest_info()
        if path and os.path.isfile(path):
            lay.label(text="From 3ds Max: %s%s" % (os.path.basename(path), ("  (%s)" % when) if when else ""),
                      icon='CHECKMARK')
        else:
            lay.label(text="Nothing sent from 3ds Max yet", icon='INFO')
        col = lay.column()
        col.scale_y = 1.6
        col.operator(MAXBRIDGE_OT_import_latest.bl_idname, icon='IMPORT')
        lay.operator(MAXBRIDGE_OT_import_file.bl_idname, icon='FILEBROWSER', text="Import file...")
        box = lay.box()
        _draw_settings(box, s)
        if s.last_summary:
            lay.label(text=s.last_summary)
            lay.operator(MAXBRIDGE_OT_show_report.bl_idname, icon='TEXT')


class MAXBRIDGE_PT_bridge(bpy.types.Panel):
    bl_label = "Bridge"
    bl_idname = "MAXBRIDGE_PT_bridge"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "Max Bridge"

    def draw(self, context):
        lay = self.layout
        col = lay.column(align=True)
        col.label(text="%s %s" % (bl_info["name"], ADDON_VERSION))
        col.label(text="Folder: " + bridge_dir())
        for label in _retired:
            lay.label(text="'%s' was switched off: remove it in Preferences" % label, icon='ERROR')
        row = lay.row(align=True)
        row.operator(MAXBRIDGE_OT_reset.bl_idname, icon='FILE_REFRESH')
        op = row.operator("preferences.addon_show", text="", icon='PREFERENCES')
        op.module = __name__


def menu_func_import(self, context):
    self.layout.operator(MAXBRIDGE_OT_import_file.bl_idname, text="3ds Max -> Blender (.json)")


# ─────────────────────────────────────────────────────────────────────────────
#  Registration
# ─────────────────────────────────────────────────────────────────────────────

classes = (
    MaxBridgePreferences,
    MaxBridgeSettings,
    MaxBridgeImportSettings,
    MAXBRIDGE_OT_send,
    MAXBRIDGE_OT_export_files,
    MAXBRIDGE_OT_open_folder,
    EXPORT_OT_blender_max_json,
    MAXBRIDGE_OT_import_file,
    MAXBRIDGE_OT_import_latest,
    MAXBRIDGE_OT_show_report,
    MAXBRIDGE_OT_reset,
    VIEW3D_PT_max_bridge,
    MAXBRIDGE_PT_import,
    MAXBRIDGE_PT_bridge,
)


def register():
    for cls in classes:
        bpy.utils.register_class(cls)
    bpy.types.Scene.max_bridge = PointerProperty(type=MaxBridgeSettings)
    bpy.types.Scene.max_bridge_import = PointerProperty(type=MaxBridgeImportSettings)
    bpy.types.TOPBAR_MT_file_export.append(menu_func_export)
    bpy.types.TOPBAR_MT_file_import.append(menu_func_import)
    # after start-up: switching another add-on off while Blender enables its add-ons is not safe
    bpy.app.timers.register(_retire_old_addons, first_interval=0.5)


def unregister():
    for fn in (_poll_result, _retire_old_addons):
        if bpy.app.timers.is_registered(fn):
            bpy.app.timers.unregister(fn)
    bpy.types.TOPBAR_MT_file_import.remove(menu_func_import)
    bpy.types.TOPBAR_MT_file_export.remove(menu_func_export)
    del bpy.types.Scene.max_bridge_import
    del bpy.types.Scene.max_bridge
    for cls in reversed(classes):
        bpy.utils.unregister_class(cls)


if __name__ == "__main__":
    register()
