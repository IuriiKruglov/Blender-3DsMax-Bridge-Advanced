-- ============================================================
--  Max Scene Scan  -  3ds Max scene setup to JSON
--  Version 1.2
--
--  Created by Claude (Anthropic)
--  under the leadership of Kruglov Iurii
-- ============================================================
--
--  A read-only scan of everything a 3ds Max -> Blender transfer
--  has to deal with. It writes one JSON file and changes nothing
--  in the scene:
--    - file, 3ds Max version, renderer, system and display units,
--      frame rate, animation range, animation layers
--    - layers (nested), selection sets, xref scenes and objects
--    - every node: hierarchy, groups (head, member, open,
--      nesting depth), layer and display flags, link inheritance
--    - transforms: world and local matrices, controller values,
--      object offset (pivot moved away from the geometry),
--      scale / mirror / shear analysis, local bounding box
--    - transform controller tree: key counts, key frames, tangent
--      types, out-of-range types, constraint targets, expressions,
--      scripts and wires
--    - other keyed or procedural tracks (visibility, object,
--      modifier and material parameters)
--    - base object class and parameters, instances, evaluated
--      face and vertex counts, map channels of editable meshes
--    - modifier stacks (top first): on/off, sharing, context and
--      gizmo transforms, parameters, Skin bones, Morpher channels
--    - materials and maps with bitmap files (missing ones marked)
--    - a summary: class counts, and lists of the nodes with
--      non-uniform scale, mirroring, shear, pivot offsets,
--      animation, procedural controllers, XForm modifiers, ...
--  The file holds names, settings and file paths, no geometry.
--
--  Use: Scripting > Run Script..., pick this file. A dialog
--  opens; press Scan. Esc cancels a running scan.
--  From code:  MaxSceneScan.scan @"C:\temp\scene_scan.json"
--
--  Log: <name>.log next to the JSON, flushed line by line: options,
--  every object before it is scanned (option), each step, timings,
--  and every error with the object, the step and the MAXScript
--  stack trace. A failing object or section is logged and skipped;
--  the JSON is still written.
--
--  CHANGES IN 1.2
--    - "tracks" (other keyed or procedural tracks) no longer repeats
--      the transform tracks: getSubAnimName returns #transform in
--      lower case and a string compare with "Transform" is case-
--      sensitive in MAXScript. The test now compares names.
--    - Modifiers: every sub-anim whose value is a matrix is written
--      under "sub_tms" (Symmetry mirror plane, gizmos, centers),
--      plus the keyed parameter tracks of the modifier.
--
--  CHANGES IN 1.1
--    - Log file and "Open log" button.
--    - Fixed "Bad free thunk local member index when accessing
--      local: d": a function parameter read inside a for-collect
--      loop fails in 3ds Max. All for-collect loops are now
--      for-do loops (the form the Blender bridge script uses).
--
--  License: GNU General Public License v3.0
-- ============================================================

global MaxSceneScan
global MaxSceneScanRollout

struct MaxSceneScanStruct (
	toolVersion = "1.2",

	-- options (the dialog sets them)
	optMesh = true,
	optParams = true,
	optTracks = true,
	optMaterials = true,
	optKeyTimes = 30,
	progressFn = undefined,

	-- modifiers whose parameter lists are huge or need the Modify panel
	heavyMods = #("Edit_Poly", "Edit_Mesh", "Edit_Patch", "Edit_Spline", "Unwrap_UVW", "Edit_Normals", \
		"Skin_Wrap", "Skin_Wrap_Patch", "Cloth", "HairMod", "Morpher", "Physique", "Retopology", "DataChannelModifier"),

	-- state of one scan
	cancelled = false,
	superHist = undefined,
	baseHist = undefined,
	classHist = undefined,
	modHist = undefined,
	ctrlHist = undefined,
	matHist = undefined,
	mapHist = undefined,
	issues = undefined,
	matQueue = undefined,
	matQueued = undefined,
	curKeys = false,
	curProc = undefined,
	curSubframe = false,
	maxDepth = 0,
	maxGroupNesting = 0,
	maxStack = 0,
	totalFaces = 0,
	groupHeads = 0,
	missingMaps = 0,
	scanErrors = 0,
	sceneMin = undefined,
	sceneMax = undefined,

	-- logging
	optVerboseLog = true,
	logWriter = undefined,
	logPath = "",
	logT0 = 0,
	curStage = "",
	stageErrors = undefined,
	sectionErrors = 0,

	-- ── JSON helpers ─────────────────────────────────────────────
	fn jStr s = (
		if s == undefined then "null" else (
			local t = s as string
			t = substituteString t "\\" "\\\\"
			t = substituteString t "\"" "\\\""
			t = substituteString t "\n" "\\n"
			t = substituteString t "\r" "\\r"
			t = substituteString t "\t" "\\t"
			"\"" + t + "\""
		)
	),

	fn clip s cnt = (
		if s == undefined then undefined else (
			local t = s as string
			if t.count > cnt then ((substring t 1 cnt) + "...") else t
		)
	),

	fn jNum v = (
		local fv = undefined
		if v != undefined do fv = try (v as float) catch undefined
		-- "," -> "." keeps the number valid JSON under a decimal-comma locale
		if fv == undefined or fv != fv or (abs fv) > 1e30 then "null" else (substituteString (formattedPrint fv format:".7g") "," ".")
	),

	fn jBool b = (if b == true then "true" else "false"),

	fn joinList arr = (
		local ss = stringStream ""
		for i = 1 to arr.count do (
			if i > 1 do format "," to:ss
			format "%" arr[i] to:ss
		)
		ss as string
	),

	fn jArr items = ("[" + (joinList items) + "]"),
	fn jObj pairs = ("{" + (joinList pairs) + "}"),
	fn kv k v = ("\"" + k + "\":" + v),
	-- an arbitrary name as an object key for kv (escaped, without the quotes)
	fn jKey s = (
		local t = jStr s
		if t == "null" then "?" else (substring t 2 (t.count - 2))
	),

	fn jP3 p = ("[" + (jNum p.x) + "," + (jNum p.y) + "," + (jNum p.z) + "]"),
	fn jQuat q = ("[" + (jNum q.x) + "," + (jNum q.y) + "," + (jNum q.z) + "," + (jNum q.w) + "]"),
	fn jM3 m = ("[" + (jP3 m.row1) + "," + (jP3 m.row2) + "," + (jP3 m.row3) + "," + (jP3 m.row4) + "]"),
	fn jColor c = ("[" + (jNum c.r) + "," + (jNum c.g) + "," + (jNum c.b) + "]"),

	-- A simple value as JSON, or undefined when it is not one.
	fn jScalar v = (
		if v == undefined then undefined else (
			local c = classOf v
			if c == Float or c == Double then (jNum v)
			else if c == Integer or c == Integer64 or c == IntegerPtr then (v as string)
			else if c == BooleanClass then (jBool v)
			else if c == String then (jStr (clip v 300))
			else if c == Name then (jStr (v as string))
			else if c == Point3 then (jP3 v)
			else if c == Point2 then ("[" + (jNum v.x) + "," + (jNum v.y) + "]")
			else if c == Point4 then ("[" + (jNum v.x) + "," + (jNum v.y) + "," + (jNum v.z) + "," + (jNum v.w) + "]")
			else if c == Color then (jColor v)
			else if c == Quat then (jQuat v)
			else if c == Matrix3 then (jM3 v)
			else if c == Time then (jNum v.frame)
			else if c == EulerAngles then ("[" + (jNum v.x) + "," + (jNum v.y) + "," + (jNum v.z) + "]")
			else if (isValidNode v) then ("{\"node\":" + (v.handle as string) + "}")
			else undefined
		)
	),

	fn jScalarOrNull v = (
		local s = jScalar v
		if s == undefined then "null" else s
	),

	-- A parameter value: simple values, short arrays of them, material and map references.
	fn jProp v = (
		local s = jScalar v
		if s != undefined then s
		else if v == undefined then undefined
		else if (classOf v) == Array then (
			if v.count > 16 then ("{\"array\":" + (v.count as string) + "}")
			else (
				local items = #()
				for x in v do append items (jScalarOrNull x)
				jArr items
			)
		)
		else (
			local sc = try (superClassOf v) catch undefined
			if sc == material then ("{\"material\":" + (jStr (try (v.name) catch "")) + "}")
			else if sc == textureMap then ("{\"map\":" + (jStr ((classOf v) as string)) + "}")
			else undefined
		)
	),

	-- Simple parameters of an object, modifier or controller (at most cnt).
	fn simpleProps obj cnt = (
		local out = #()
		local names = try (getPropNames obj) catch #()
		local i = 1
		while i <= names.count and out.count < cnt do (
			local pn = names[i]
			local v = try (getProperty obj pn) catch undefined
			local s = jProp v
			if s != undefined do append out (kv (pn as string) s)
			i += 1
		)
		jObj out
	),

	-- ── counters ─────────────────────────────────────────────────
	fn bump d k = (
		if hasDictValue d k then d[k] = d[k] + 1 else d[k] = 1
	),

	fn histJson d = (
		local ks = #()
		for k in d.keys do append ks k
		sort ks
		local items = #()
		for k in ks do append items ((jStr k) + ":" + (d[k] as string))
		jObj items
	),

	fn addIssue key nodeName = (
		if not (hasDictValue issues key) do issues[key] = #(0, #())
		local v = issues[key]
		v[1] = v[1] + 1
		if v[2].count < 40 do append v[2] nodeName
	),

	-- ── logging ──────────────────────────────────────────────────
	-- The log is written line by line and flushed at once, so it is
	-- complete up to the last step even if 3ds Max stops responding.
	fn logClose = (
		if logWriter != undefined do (
			try (logWriter.Close()) catch ()
			logWriter = undefined
		)
	),

	fn logOpen logFile = (
		logClose()
		logPath = logFile
		logT0 = timeStamp()
		try (
			logWriter = dotNetObject "System.IO.StreamWriter" logFile false (dotNetObject "System.Text.UTF8Encoding" false)
			logWriter.AutoFlush = true
		) catch (
			logWriter = undefined
			format "MaxSceneScan: cannot write the log file %\n" logFile
		)
	),

	-- One line in the log (seconds since the scan started), optionally also in the Listener.
	fn logLine msg toListener:false = (
		local secs = (timeStamp() - logT0) / 1000.0
		local txtLine = "[" + (substituteString (formattedPrint secs format:"9.3f") "," ".") + "] " + (msg as string)
		if logWriter != undefined do try (logWriter.WriteLine txtLine) catch ()
		if toListener do format "MaxSceneScan %\n" txtLine
	),

	-- ex / st: getCurrentException() and the stack trace, taken in the catch block.
	fn logError title ex st toListener:true = (
		logLine ("ERROR " + title + ": " + (substituteString (ex as string) "\n" " ")) toListener:toListener
		if (classOf st) == String and st != "" do logLine ("stack trace:\n" + st)
	),

	-- Record for a node that failed; the scan goes on with the next node.
	fn nodeFailed n idx ex st = (
		scanErrors += 1
		bump stageErrors curStage
		local nm = try (n.name) catch "?"
		local stack = if scanErrors <= 20 then st else ""
		logError ("node " + (idx as string) + " '" + nm + "' at " + curStage) ex stack toListener:(scanErrors <= 20)
		jObj #((kv "id" (try (n.handle as string) catch "null")), (kv "name" (jStr nm)), \
			(kv "scan_error" (jStr ex)), (kv "stage" (jStr curStage)))
	),

	fn sectionFailed nm ex st = (
		sectionErrors += 1
		logError ("section " + nm) ex st
		"null"
	),

	-- ── transforms ───────────────────────────────────────────────
	-- #(sx, sy, sz, mirrored, shear, nonUniform) of a matrix3:
	-- axis lengths, negative determinant, max |cos| between axes,
	-- longest / shortest axis - 1.
	fn tmInfo m = (
		local r1 = m.row1
		local r2 = m.row2
		local r3 = m.row3
		local sx = length r1
		local sy = length r2
		local sz = length r3
		local mirrored = (dot (cross r1 r2) r3) < 0.0
		local shear = 0.0
		local nonUni = 1e9
		if sx > 1e-12 and sy > 1e-12 and sz > 1e-12 do (
			local n1 = r1 / sx
			local n2 = r2 / sy
			local n3 = r3 / sz
			shear = amax #((abs (dot n1 n2)), (abs (dot n1 n3)), (abs (dot n2 n3)))
			nonUni = (amax #(sx, sy, sz)) / (amin #(sx, sy, sz)) - 1.0
		)
		#(sx, sy, sz, mirrored, shear, nonUni)
	),

	fn tmInfoJson ti = (
		jObj #((kv "scale" ("[" + (jNum ti[1]) + "," + (jNum ti[2]) + "," + (jNum ti[3]) + "]")), \
			(kv "mirrored" (jBool ti[4])), (kv "shear" (jNum ti[5])), (kv "non_uniform" (jNum ti[6])))
	),

	-- ── controllers ──────────────────────────────────────────────
	fn isProcName cn = (
		local pats = #("*Expression*", "*Script*", "*Wire*", "*Noise*", "*Constraint*", "*Reactor*", "*Spring*", \
			"*Audio*", "*Motion_Capture*", "*Waveform*", "*Attachment*", "*IK*", "Bip*", "*Footstep*", \
			"*Vertical_Horizontal*", "CAT*", "*Layer*", "*Limit*", "*Surface*", "*Block*")
		local hit = false
		for p in pats do (
			if not hit and (matchPattern cn pattern:p) do hit = true
		)
		hit
	),

	fn axisOrderName i = (
		local names = #("XYZ", "XZY", "YZX", "YXZ", "ZXY", "ZYX", "XYX", "YZY", "ZXZ")
		if (classOf i) == Integer and i >= 1 and i <= names.count then names[i] else (i as string)
	),

	-- Counts of "in>out" tangent types over the first 200 keys (Bezier keys only).
	fn tangentHist c nk = (
		local res = undefined
		local ks = try (c.keys) catch undefined
		if ks != undefined and nk > 0 do (
			local probe = try (ks[1].inTangentType) catch undefined
			if probe != undefined do (
				local names = #()
				local counts = #()
				try (
					for i = 1 to (amin #(nk, 200)) do (
						local k = ks[i]
						local tk = ((k.inTangentType) as string) + ">" + ((k.outTangentType) as string)
						local idx = findItem names tk
						if idx == 0 then (
							append names tk
							append counts 1
						) else counts[idx] = counts[idx] + 1
					)
				) catch ()
				local items = #()
				for i = 1 to names.count do append items ((jStr names[i]) + ":" + (counts[i] as string))
				res = jObj items
			)
		)
		res
	),

	-- Controller tree as JSON. Sub-controllers through the global
	-- instance (recursion), up to 6 levels.
	fn ctrlJson c depth = (
		local f = #()
		local cn = (classOf c) as string
		curStage = "controller " + cn + " (level " + (depth as string) + ")"
		bump ctrlHist cn
		append f (kv "class" (jStr cn))
		local proc = isProcName cn
		if proc do appendIfUnique curProc cn
		local nk = try (numKeys c) catch -1
		if (classOf nk) != Integer do nk = -1
		if nk > 0 do (
			curKeys = true
			append f (kv "keys" (nk as string))
			try (
				local ta = (getKeyTime c 1).frame
				local tb = (getKeyTime c nk).frame
				append f (kv "range" ("[" + (jNum ta) + "," + (jNum tb) + "]"))
				local ts = #()
				for i = 1 to (amin #(nk, (amax #(optKeyTimes, 100)))) do (
					local fr = (getKeyTime c i).frame
					if (abs (fr - (floor (fr + 0.5)))) > 0.001 do curSubframe = true
					if i <= optKeyTimes do append ts (jNum fr)
				)
				if ts.count > 0 do append f (kv "times" (jArr ts))
			) catch ()
			local tg = tangentHist c nk
			if tg != undefined do append f (kv "tangents" tg)
			local bo = try ((getBeforeORT c) as string) catch "constant"
			local ao = try ((getAfterORT c) as string) catch "constant"
			if bo != "constant" or ao != "constant" do append f (kv "ort" ("[" + (jStr bo) + "," + (jStr ao) + "]"))
		)
		local v = try (c.value) catch undefined
		if v != undefined and (classOf v) != Matrix3 do (
			local vs = jScalar v
			if vs != undefined do append f (kv "value" vs)
		)
		if matchPattern cn pattern:"*Euler*" do (
			local ord = try (c.axisOrder) catch undefined
			if ord != undefined do append f (kv "order" (jStr (axisOrderName ord)))
		)
		if matchPattern cn pattern:"*_List" do try (
			local lc = c.count
			append f (kv "active" (c.active as string))
			local nmItems = #()
			local wItems = #()
			for i = 1 to lc do (
				append nmItems (jStr (c.getName i))
				append wItems (jNum c.weight[i])
			)
			append f (kv "names" (jArr nmItems))
			append f (kv "weights" (jArr wItems))
		) catch ()
		if matchPattern cn pattern:"*Constraint*" do try (
			local nt = c.getNumTargets()
			local tl = #()
			for i = 1 to nt do (
				local tn = try (c.getNode i) catch undefined
				local g = #()
				if isValidNode tn then (
					append g (kv "node" (tn.handle as string))
					append g (kv "name" (jStr tn.name))
				) else append g (kv "node" "null")
				local tw = try (c.getWeight i) catch undefined
				if tw != undefined do append g (kv "weight" (jNum tw))
				if cn == "Link_Constraint" do (
					local lf = try (c.getFrameNo i) catch undefined
					if lf != undefined do append g (kv "frame" (jNum lf))
				)
				append tl (jObj g)
			)
			append f (kv "targets" (jArr tl))
		) catch ()
		if matchPattern cn pattern:"*Expression*" do try (append f (kv "expression" (jStr (clip (c.getExpression()) 2000)))) catch ()
		if matchPattern cn pattern:"*Script*" do try (append f (kv "script" (jStr (clip c.script 2000)))) catch ()
		if matchPattern cn pattern:"*Wire*" do try (
			local nw = c.numWires
			local wl = #()
			for i = 1 to nw do append wl (jStr (clip (c.getExprText i) 500))
			if wl.count > 0 do append f (kv "wires" (jArr wl))
		) catch ()
		if proc and optParams do (
			local pj = simpleProps c 30
			if pj != "{}" do append f (kv "params" pj)
		)
		if depth < 6 do (
			local subs = #()
			local ns = try (c.numSubs) catch 0
			for i = 1 to ns do (
				local sa = try (getSubAnim c i) catch undefined
				local sc = undefined
				if sa != undefined do sc = try (sa.controller) catch undefined
				if sc != undefined do (
					local snm = try ((getSubAnimName c i) as string) catch (i as string)
					append subs ("{" + (kv "name" (jStr snm)) + "," + (kv "ctrl" (MaxSceneScan.ctrlJson sc (depth + 1))) + "}")
				)
			)
			if subs.count > 0 do append f (kv "subs" (jArr subs))
		)
		jObj f
	),

	-- Keyed or procedural controllers under a node, except its
	-- Transform (reported in "controller"). Iterative, limited.
	fn tracksOf n = (
		local out = #()
		local stack = #()
		local ns = try (n.numSubs) catch 0
		for i = ns to 1 by -1 do (
			local sname = try (getSubAnimName n i) catch undefined
			local snm = if sname != undefined then (sname as string) else (i as string)
			-- names compare case-insensitively, strings do not ("transform" != "Transform")
			if sname != #transform do (
				local sa = try (getSubAnim n i) catch undefined
				if sa != undefined do append stack #(sa, snm, 1)
			)
		)
		local visited = 0
		while stack.count > 0 and visited < 3000 and out.count < 60 do (
			local it = stack[stack.count]
			deleteItem stack stack.count
			visited += 1
			local sa = it[1]
			local trackPath = it[2]
			local c = try (sa.controller) catch undefined
			if c != undefined do (
				local nk = try (numKeys c) catch -1
				if (classOf nk) != Integer do nk = -1
				local cn = (classOf c) as string
				if nk > 0 or (isProcName cn) do (
					local g = #((kv "path" (jStr trackPath)), (kv "class" (jStr cn)))
					if nk > 0 do (
						append g (kv "keys" (nk as string))
						try (append g (kv "range" ("[" + (jNum (getKeyTime c 1).frame) + "," + (jNum (getKeyTime c nk).frame) + "]"))) catch ()
					)
					if matchPattern cn pattern:"*Expression*" do try (append g (kv "expression" (jStr (clip (c.getExpression()) 500)))) catch ()
					if matchPattern cn pattern:"*Script*" do try (append g (kv "script" (jStr (clip c.script 500)))) catch ()
					append out (jObj g)
				)
			)
			if it[3] < 6 do (
				local ns2 = try (sa.numSubs) catch 0
				for j = ns2 to 1 by -1 do (
					local sb = try (getSubAnim sa j) catch undefined
					if sb != undefined do (
						local sn = try ((getSubAnimName sa j) as string) catch (j as string)
						append stack #(sb, trackPath + "/" + sn, it[3] + 1)
					)
				)
			)
		)
		out
	),

	-- ── base object and modifiers ────────────────────────────────
	-- Sub-anim names of an object as name values (compare case-insensitively).
	fn subNames obj = (
		local out = #()
		local ns = try (obj.numSubs) catch 0
		for i = 1 to ns do (
			local snm = try ((getSubAnimName obj i) as string) catch ""
			append out (snm as name)
		)
		out
	),

	fn baseJson n base bcls bsup = (
		local g = #((kv "class" (jStr bcls)), (kv "super" (jStr bsup)))
		if bcls == "Editable_Poly" then (
			try (
				append g (kv "faces" ((polyop.getNumFaces base) as string))
				append g (kv "verts" ((polyop.getNumVerts base) as string))
				local nmp = polyop.getNumMaps base
				local chs = #()
				for i = 0 to nmp - 1 do (
					if (polyop.getMapSupport base i) do append chs (i as string)
				)
				append g (kv "map_channels" (jArr chs))
			) catch ()
		)
		else if bcls == "Editable_mesh" then (
			try (
				append g (kv "faces" (base.numfaces as string))
				append g (kv "verts" (base.numverts as string))
				local nmp = meshop.getNumMaps base
				local chs = #()
				for i = 0 to nmp - 1 do (
					if (meshop.getMapSupport base i) do append chs (i as string)
				)
				append g (kv "map_channels" (jArr chs))
			) catch ()
		)
		else if optParams do (
			local pj = simpleProps base 40
			if pj != "{}" do append g (kv "params" pj)
		)
		if bsup == "shape" do (
			local nsp = try (numSplines n) catch undefined
			if (classOf nsp) == Integer do append g (kv "splines" (nsp as string))
		)
		jObj g
	),

	fn modJson n m = (
		local g = #()
		local mc = (classOf m) as string
		bump modHist mc
		append g (kv "name" (jStr m.name))
		append g (kv "class" (jStr mc))
		local ms = (superClassOf m) as string
		if ms != "modifier" do append g (kv "super" (jStr ms))
		if not (try (m.enabled) catch true) do append g (kv "enabled" "false")
		if not (try (m.enabledInViews) catch true) do append g (kv "in_views" "false")
		if not (try (m.enabledInRenders) catch true) do append g (kv "in_renders" "false")
		local deps = try (refs.dependentNodes m) catch #()
		if deps.count > 1 do append g (kv "shared_by" (deps.count as string))
		local ctm = try (getModContextTM n m) catch undefined
		if (classOf ctm) == Matrix3 and not (isIdentity ctm) do append g (kv "context_tm" (jM3 ctm))
		local sn = subNames m
		if (findItem sn #gizmo) > 0 do (
			local gtm = try (m.gizmo.value) catch (try (m.gizmo.transform) catch undefined)
			if (classOf gtm) == Matrix3 do append g (kv "gizmo_tm" (jM3 gtm))
		)
		if (findItem sn #center) > 0 do (
			local cen = try (m.center) catch undefined
			if (classOf cen) == Point3 do append g (kv "center" (jP3 cen))
		)
		-- every matrix sub-anim (Symmetry mirror plane, gizmos) and keyed parameters
		local subTms = #()
		local keyedSubs = #()
		local nsm = try (m.numSubs) catch 0
		for i = 1 to nsm do (
			local sa = try (getSubAnim m i) catch undefined
			if sa != undefined do (
				local saName = try ((getSubAnimName m i) as string) catch (i as string)
				local sv = try (sa.value) catch undefined
				if (classOf sv) == Matrix3 do append subTms (kv (jKey saName) (jM3 sv))
				local sc = try (sa.controller) catch undefined
				if sc != undefined do (
					local snk = try (numKeys sc) catch 0
					if (classOf snk) == Integer and snk > 0 do append keyedSubs (jObj #((kv "track" (jStr saName)), (kv "class" (jStr ((classOf sc) as string))), (kv "keys" (snk as string))))
				)
			)
		)
		if subTms.count > 0 do append g (kv "sub_tms" (jObj subTms))
		if keyedSubs.count > 0 do append g (kv "keyed_params" (jArr keyedSubs))
		if matchPattern mc pattern:"*XForm*" do addIssue "xform_modifier" n.name
		if mc == "Skin" do try (
			local bIds = #()
			local bNames = #()
			for r in (refs.dependsOn m) do (
				if isValidNode r do (
					append bIds (r.handle as string)
					append bNames (jStr r.name)
				)
			)
			append g (kv "bones" (jArr bIds))
			append g (kv "bone_names" (jArr bNames))
			addIssue "skinned" n.name
		) catch ()
		if mc == "Morpher" do try (
			local nch = WM3_NumberOfChannels m
			local chs = #()
			for i = 1 to nch do (
				if (WM3_MC_HasData m i) do append chs (jObj #((kv "index" (i as string)), (kv "name" (jStr (WM3_MC_GetName m i))), (kv "value" (jNum (WM3_MC_GetValue m i)))))
			)
			append g (kv "channels" (jArr chs))
			addIssue "morpher" n.name
		) catch ()
		if mc == "Unwrap_UVW" do (
			local ch = try (m.unwrap.getMapChannel()) catch (try (m.getMapChannel()) catch undefined)
			if ch != undefined do append g (kv "map_channel" (ch as string))
		)
		if optParams and (findItem heavyMods mc) == 0 do (
			local pj = simpleProps m 60
			if pj != "{}" do append g (kv "params" pj)
		)
		jObj g
	),

	-- ── node parts ───────────────────────────────────────────────
	fn nodeHead n f = (
		local nm = n.name
		append f (kv "id" (n.handle as string))
		append f (kv "name" (jStr nm))
		local par = n.parent
		append f (kv "parent" (if par != undefined then (par.handle as string) else "null"))
		if n.children.count > 0 do append f (kv "children" (n.children.count as string))
		local d = 0
		local a = par
		while a != undefined do (
			d += 1
			a = a.parent
		)
		if d > 0 do append f (kv "depth" (d as string))
		if d > maxDepth do maxDepth = d
		append f (kv "layer" (jStr (try (n.layer.name) catch undefined)))
		local flg = #()
		if (try (n.isHidden) catch false) do (
			append flg (jStr "hidden")
			addIssue "hidden" nm
		)
		if (try (n.isFrozen) catch false) do (
			append flg (jStr "frozen")
			addIssue "frozen" nm
		)
		if not (try (n.renderable) catch true) do append flg (jStr "not_renderable")
		if (try (n.boxMode) catch false) do append flg (jStr "box_mode")
		if (try (n.xray) catch false) do append flg (jStr "see_through")
		if flg.count > 0 do append f (kv "flags" (jArr flg))
		local vis = try (n.visibility) catch true
		if vis != true do (
			local vs = jScalar vis
			if vs != undefined do append f (kv "visibility" vs)
		)
		append f (kv "wirecolor" (jColor n.wirecolor))
		local gh = try (isGroupHead n) catch false
		local gm = try (isGroupMember n) catch false
		if gh or gm do (
			local g = #()
			if gh do (
				append g (kv "head" "true")
				groupHeads += 1
				local gd = 0
				local a2 = par
				while a2 != undefined do (
					if (isGroupHead a2) do gd += 1
					a2 = a2.parent
				)
				append g (kv "nesting" (gd as string))
				if gd > maxGroupNesting do maxGroupNesting = gd
				if (try (isOpenGroupHead n) catch false) do (
					append g (kv "open" "true")
					addIssue "open_groups" nm
				)
			)
			if gm do append g (kv "member" "true")
			append f (kv "group" (jObj g))
		)
		if isProperty n #target do (
			local tg = try (n.target) catch undefined
			if isValidNode tg do append f (kv "target" (tg.handle as string))
		)
	),

	fn nodeTransform n f = (
		local nm = n.name
		local wTM = n.transform
		append f (kv "world" (jM3 wTM))
		local wi = tmInfo wTM
		append f (kv "world_info" (tmInfoJson wi))
		if wi[6] > 1e-4 do addIssue "non_uniform_scale_world" nm
		if wi[4] do addIssue "mirrored_world" nm
		if wi[5] > 1e-4 do addIssue "shear_world" nm
		local tp = wTM.row4
		if sceneMin == undefined then (
			sceneMin = copy tp
			sceneMax = copy tp
		) else (
			sceneMin = [(amin #(sceneMin.x, tp.x)), (amin #(sceneMin.y, tp.y)), (amin #(sceneMin.z, tp.z))]
			sceneMax = [(amax #(sceneMax.x, tp.x)), (amax #(sceneMax.y, tp.y)), (amax #(sceneMax.z, tp.z))]
		)
		local par = n.parent
		if par != undefined do (
			local lTM = try (wTM * (inverse par.transform)) catch undefined
			if lTM != undefined do (
				append f (kv "local" (jM3 lTM))
				local li = tmInfo lTM
				append f (kv "local_info" (tmInfoJson li))
				if li[6] > 1e-4 do addIssue "non_uniform_scale_local" nm
				if li[4] do addIssue "mirrored_local" nm
				if li[5] > 1e-4 do addIssue "shear_local" nm
			)
		)
		local inh = try (getInheritanceFlags n) catch undefined
		if inh != undefined do (
			local allOn = true
			for i = 1 to 9 do (
				if not inh[i] do allOn = false
			)
			if not allOn do (
				local ib = #()
				for i = 1 to 9 do append ib (jBool inh[i])
				append f (kv "inherit" (jArr ib))
				addIssue "partial_link_inheritance" nm
			)
		)
		local lk = try (getTransformLockFlags n) catch undefined
		if lk != undefined and lk.numberSet > 0 do (
			local lb = #()
			for i = 1 to 9 do append lb (jBool lk[i])
			append f (kv "locks" (jArr lb))
		)
		local prs = #()
		local pv = try (n.pos.controller.value) catch undefined
		if (classOf pv) == Point3 do append prs (kv "pos" (jP3 pv))
		local rv = try (n.rotation.controller.value) catch undefined
		if (classOf rv) == Quat do append prs (kv "rot_quat" (jQuat rv))
		local sv = try (n.scale.controller.value) catch undefined
		if (classOf sv) == Point3 do append prs (kv "scale" (jP3 sv))
		if prs.count > 0 do append f (kv "prs" (jObj prs))
		local offPos = n.objectOffsetPos
		local offRot = n.objectOffsetRot
		local offScl = n.objectOffsetScale
		if (length offPos) > 1e-5 or (abs offRot.w) < 0.9999999 or (length (offScl - [1, 1, 1])) > 1e-6 do (
			append f (kv "offset" (jObj #((kv "pos" (jP3 offPos)), (kv "rot_quat" (jQuat offRot)), (kv "scale" (jP3 offScl)))))
			append f (kv "object_tm" (jM3 n.objectTransform))
			addIssue "pivot_offset" nm
		)
		local bb = try (nodeLocalBoundingBox n) catch undefined
		if (classOf bb) == Array and bb.count == 2 do append f (kv "bbox_local" ("[" + (jP3 bb[1]) + "," + (jP3 bb[2]) + "]"))
	),

	fn nodeAnimation n f = (
		local nm = n.name
		curKeys = false
		curProc = #()
		curSubframe = false
		curStage = "transform controller"
		local tc = try (n.controller) catch undefined
		if tc != undefined do (
			local tj = ctrlJson tc 0
			if curKeys or curProc.count > 0 then append f (kv "controller" tj)
			else (
				local cc = #((kv "class" (jStr ((classOf tc) as string))), (kv "static" "true"))
				local pc = try ((classOf n.pos.controller) as string) catch undefined
				if pc != undefined do append cc (kv "pos" (jStr pc))
				local rc = try (n.rotation.controller) catch undefined
				if rc != undefined do (
					append cc (kv "rot" (jStr ((classOf rc) as string)))
					local ord = try (rc.axisOrder) catch undefined
					if ord != undefined do append cc (kv "order" (jStr (axisOrderName ord)))
				)
				local sc = try ((classOf n.scale.controller) as string) catch undefined
				if sc != undefined do append cc (kv "scale" (jStr sc))
				append f (kv "controller" (jObj cc))
			)
		)
		if curKeys do addIssue "animated_transform" nm
		if curProc.count > 0 do (
			local pl = #()
			for x in curProc do append pl (jStr x)
			append f (kv "procedural" (jArr pl))
			addIssue "procedural_transform" nm
		)
		if curSubframe do addIssue "subframe_keys" nm
		if optTracks do (
			curStage = "other tracks"
			local tr = tracksOf n
			if tr.count > 0 do (
				append f (kv "tracks" (jArr tr))
				addIssue "animated_or_procedural_other_tracks" nm
			)
		)
	),

	fn nodeObject n f = (
		local nm = n.name
		local cls = try ((classOf n) as string) catch "?"
		local sup = try ((superClassOf n) as string) catch "?"
		local base = n.baseObject
		local bcls = try ((classOf base) as string) catch "?"
		local bsup = try ((superClassOf base) as string) catch "?"
		append f (kv "class" (jStr cls))
		append f (kv "super" (jStr sup))
		bump superHist sup
		bump baseHist bcls
		bump classHist cls
		if ((findString cls "Missing") != undefined) or ((findString bcls "Missing") != undefined) do addIssue "missing_plugin_classes" nm
		if bcls == "XRefObject" do addIssue "xref_objects" nm
		if bcls == "Container" do addIssue "containers" nm
		if bcls == "BoneGeometry" do addIssue "max_bones" nm
		if bcls == "Biped_Object" do addIssue "biped" nm
		if matchPattern bcls pattern:"CAT*" do addIssue "cat_rig" nm
		if (matchPattern bcls pattern:"*Proxy*") or (matchPattern bcls pattern:"*RailClone*") or (matchPattern bcls pattern:"*Forest*") do addIssue "proxies_scatter" nm
		if (matchPattern bcls pattern:"PF_*") or (matchPattern bcls pattern:"*Particle*") or (matchPattern bcls pattern:"*tyFlow*") do addIssue "particles" nm
		curStage = "base object (" + bcls + ")"
		append f (kv "base" (baseJson n base bcls bsup))
		curStage = "instances"
		local inst = #()
		local ni = try (InstanceMgr.GetInstances n &inst) catch 1
		if (classOf ni) != Integer do ni = 1
		if ni > 1 do (
			local keyH = n.handle
			for x in inst do (
				if (isValidNode x) and x.handle < keyH do keyH = x.handle
			)
			append f (kv "instances" (jObj #((kv "count" (ni as string)), (kv "key" (keyH as string)))))
			addIssue "instanced" nm
		)
		local deps = try (refs.dependentNodes base) catch #()
		if deps.count > 1 and deps.count > ni do append f (kv "base_shared_by" (deps.count as string))
		curStage = "mesh counts"
		if optMesh and sup == "GeometryClass" do (
			local pc = try (getPolygonCount n) catch undefined
			if (classOf pc) == Array and pc.count >= 2 do (
				append f (kv "mesh" (jObj #((kv "faces" (pc[1] as string)), (kv "verts" (pc[2] as string)))))
				totalFaces += pc[1]
			)
		)
		if sup == "shape" and (isProperty base #render_renderable) do (
			if (try (base.render_renderable) catch false) == true do addIssue "renderable_splines" nm
		)
		local mods = n.modifiers
		if mods.count > 0 do (
			local ml = #()
			for k = 1 to mods.count do (
				curStage = "modifier " + (k as string) + " (" + ((classOf mods[k]) as string) + ")"
				append ml (modJson n mods[k])
			)
			append f (kv "modifiers" (jArr ml))
			if mods.count > maxStack do maxStack = mods.count
			addIssue "has_modifiers" nm
		)
		curStage = "material reference"
		local mt = n.material
		if mt != undefined do (
			local mk = "a" + ((getHandleByAnim mt) as string)
			append f (kv "material" (jStr mk))
			if optMaterials and not (hasDictValue matQueued mk) do (
				matQueued[mk] = true
				append matQueue mt
			)
		)
		curStage = "user properties"
		local up = try (getUserPropBuffer n) catch ""
		if (classOf up) == String and up != "" do append f (kv "user_props" (jStr (clip up 500)))
		local cas = #()
		for owner in #(n, base) do (
			local nca = try (custAttributes.count owner) catch 0
			for i = 1 to nca do (
				local cdef = try (custAttributes.getDef owner i) catch undefined
				if cdef != undefined do append cas (jStr (try (cdef.name as string) catch "?"))
			)
		)
		if cas.count > 0 do append f (kv "custom_attributes" (jArr cas))
	),

	fn nodeJson n = (
		local f = #()
		curStage = "head"
		nodeHead n f
		curStage = "object"
		nodeObject n f
		curStage = "transform"
		nodeTransform n f
		curStage = "animation"
		nodeAnimation n f
		jObj f
	),

	-- ── materials and maps (iterative, by anim handle) ────────────
	fn materialsJson = (
		local out = #()
		local seen = Dictionary #string
		local qi = 1
		while qi <= matQueue.count and out.count < 20000 do (
			local mt = matQueue[qi]
			qi += 1
			local h = (getHandleByAnim mt) as string
			if not (hasDictValue seen h) do try (
				seen[h] = true
				local g = #()
				local mc = (classOf mt) as string
				curStage = "material " + mc + " '" + (try (mt.name) catch "?") + "'"
				local isMat = (superClassOf mt) == material
				append g (kv "kind" (jStr (if isMat then "material" else "map")))
				append g (kv "name" (jStr (try (mt.name) catch "")))
				append g (kv "class" (jStr mc))
				if isMat then bump matHist mc else bump mapHist mc
				local nsm = try (getNumSubMtls mt) catch 0
				local subs = #()
				for i = 1 to nsm do (
					local sm = try (getSubMtl mt i) catch undefined
					if sm != undefined do (
						local slot = try ((getSubMtlSlotName mt i) as string) catch (i as string)
						append subs (jObj #((kv "slot" (jStr slot)), (kv "ref" (jStr ("a" + ((getHandleByAnim sm) as string))))))
						append matQueue sm
					)
				)
				if subs.count > 0 do append g (kv "submaterials" (jArr subs))
				if mc == "Multimaterial" do try (
					local idl = #()
					for x in mt.materialIDList do append idl (x as string)
					append g (kv "ids" (jArr idl))
				) catch ()
				local ntm = try (getNumSubTexmaps mt) catch 0
				local maps = #()
				for i = 1 to ntm do (
					local tx = try (getSubTexmap mt i) catch undefined
					if tx != undefined do (
						local slot = try ((getSubTexmapSlotName mt i) as string) catch (i as string)
						append maps (jObj #((kv "slot" (jStr slot)), (kv "ref" (jStr ("a" + ((getHandleByAnim tx) as string))))))
						append matQueue tx
					)
				)
				if maps.count > 0 do append g (kv "maps" (jArr maps))
				local fname = undefined
				for pn in #(#filename, #HDRIMapName) do (
					if fname == undefined and (isProperty mt pn) do (
						local fv = try (getProperty mt pn) catch undefined
						if (classOf fv) == String and fv != "" do fname = fv
					)
				)
				if fname != undefined do (
					append g (kv "file" (jStr fname))
					local found = doesFileExist fname
					if not found do (
						local fp = try (mapPaths.getFullFilePath fname) catch ""
						found = (classOf fp) == String and fp != ""
					)
					if not found do (
						append g (kv "missing" "true")
						missingMaps += 1
					)
				)
				append out ((jStr ("a" + h)) + ":" + (jObj g))
			) catch (
				local ex = getCurrentException()
				local st = try (getCurrentExceptionStackTrace()) catch ""
				scanErrors += 1
				bump stageErrors curStage
				logError curStage ex (if scanErrors <= 20 then st else "") toListener:(scanErrors <= 20)
			)
		)
		out
	),

	-- ── scene sections ───────────────────────────────────────────
	fn unitsJson = (
		local st = units.SystemType
		local cm = case st of (
			#inches: 2.54
			#feet: 30.48
			#miles: 160934.4
			#millimeters: 0.1
			#centimeters: 1.0
			#meters: 100.0
			#kilometers: 100000.0
			default: 1.0
		)
		cm = cm * units.SystemScale
		jObj #((kv "system" (jStr (st as string))), (kv "system_scale" (jNum units.SystemScale)), \
			(kv "cm_per_unit" (jNum cm)), (kv "display" (jStr (units.DisplayType as string))), \
			(kv "metric" (jStr (units.MetricType as string))), (kv "us" (jStr (units.USType as string))))
	),

	fn timeJson = (
		jObj #((kv "fps" (jNum frameRate)), (kv "ticks_per_frame" (TicksPerFrame as string)), \
			(kv "start" (jNum animationRange.start.frame)), (kv "end" (jNum animationRange.end.frame)), \
			(kv "current" (jNum sliderTime.frame)))
	),

	fn animLayersJson = (
		local out = #()
		try (
			local nl = AnimLayerManager.getLayerCount()
			for i = 1 to nl do append out (jStr (AnimLayerManager.getLayerName i))
		) catch ()
		out
	),

	fn layersJson = (
		local out = #()
		for i = 0 to LayerManager.count - 1 do (
			local lay = LayerManager.getLayer i
			if lay != undefined do (
				local g = #((kv "name" (jStr lay.name)))
				local lp = try (lay.getParent()) catch undefined
				if lp != undefined do append g (kv "parent" (jStr (try (lp.name) catch undefined)))
				if (try (lay.isHidden) catch false) do append g (kv "hidden" "true")
				if (try (lay.isFrozen) catch false) do append g (kv "frozen" "true")
				if not (try (lay.renderable) catch true) do append g (kv "renderable" "false")
				local arr = #()
				try (lay.nodes &arr) catch ()
				append g (kv "nodes" (arr.count as string))
				append out (jObj g)
			)
		)
		out
	),

	fn selSetsJson = (
		local out = #()
		try (
			for i = 1 to selectionSets.count do (
				local s = selectionSets[i]
				append out (jObj #((kv "name" (jStr s.name)), (kv "count" (s.count as string))))
			)
		) catch ()
		out
	),

	fn xrefsJson = (
		local sc = #()
		try (
			for i = 1 to (xrefs.getXRefFileCount()) do append sc (jStr (xrefs.getXRefFile i).filename)
		) catch ()
		local ob = #()
		try (
			for i = 1 to objXRefMgr.recordCount do append ob (jStr (objXRefMgr.GetRecord i).srcFileName)
		) catch ()
		jObj #((kv "scenes" (jArr sc)), (kv "object_records" (jArr ob)))
	),

	fn issuesJson = (
		local ks = #()
		for k in issues.keys do append ks k
		sort ks
		local items = #()
		for k in ks do (
			local ex = #()
			for x in issues[k][2] do append ex (jStr x)
			append items (kv k (jObj #((kv "count" (issues[k][1] as string)), (kv "examples" (jArr ex)))))
		)
		jObj items
	),

	fn legendJson = (
		jObj #( \
			(kv "matrices" (jStr "3ds Max matrix3 as 4 rows: X axis, Y axis, Z axis, translation. Row vectors: p_world = p_local * M. System units.")), \
			(kv "world" (jStr "node.transform: the pivot (node TM) in world space")), \
			(kv "local" (jStr "world * inverse(parent world): the node relative to its parent")), \
			(kv "world_info" (jStr "scale = axis lengths, mirrored = negative determinant, shear = largest |cos| between axes, non_uniform = longest / shortest axis - 1")), \
			(kv "prs" (jStr "transform controller values: local position, rotation quaternion [x,y,z,w] as 3ds Max reports it, scale")), \
			(kv "offset" (jStr "object offset: pivot moved without the geometry. Geometry is in object space; object_tm = offset * world = node.objectTransform")), \
			(kv "bbox_local" (jStr "bounding box min/max in node (pivot) space")), \
			(kv "inherit" (jStr "Link Info inheritance [move x,y,z, rotate x,y,z, scale x,y,z], listed only when some are off")), \
			(kv "controller" (jStr "transform controller tree (static: classes only). keys = key count, range = first/last key frame, times = key frames, tangents = in>out tangent type counts, ort = before/after out-of-range types, value = current value as 3ds Max reports it")), \
			(kv "tracks" (jStr "other keyed or procedural tracks under the node: visibility, object, modifier and material parameters")), \
			(kv "base" (jStr "base object (bottom of the stack); class = evaluated object at the top of the stack")), \
			(kv "mesh" (jStr "faces and vertices of the evaluated object (getPolygonCount)")), \
			(kv "modifiers" (jStr "top of the stack first. context_tm = modifier context TM, gizmo_tm = gizmo transform, shared_by = nodes using this modifier instance")), \
			(kv "instances" (jStr "instanced nodes: count and the lowest node id of the instance set")), \
			(kv "materials" (jStr "materials and maps by key; nodes refer to them with material:<key>")), \
			(kv "issues" (jStr "summary.issues lists node names (up to 40) per finding, see issue_keys")), \
			(kv "issue_keys" (jObj #( \
				(kv "non_uniform_scale_world" (jStr "world axes of different length (non-uniform scale on the node or a parent)")), \
				(kv "non_uniform_scale_local" (jStr "the node's own scale relative to its parent is non-uniform")), \
				(kv "mirrored_world" (jStr "negative determinant in world space (mirrored / negative scale)")), \
				(kv "mirrored_local" (jStr "mirrored relative to the parent")), \
				(kv "shear_world" (jStr "world axes not perpendicular: rotated child of a non-uniformly scaled parent")), \
				(kv "shear_local" (jStr "skewed relative to the parent: rotated scale axis or partial link inheritance")), \
				(kv "pivot_offset" (jStr "pivot moved without the geometry (object offset), not baked")), \
				(kv "partial_link_inheritance" (jStr "Link Info inheritance switched off on some axes")), \
				(kv "animated_transform" (jStr "keys in the transform controllers")), \
				(kv "procedural_transform" (jStr "constraints, expressions, scripts, wires, lists, IK, biped/CAT or animation layers in the transform")), \
				(kv "subframe_keys" (jStr "transform keys between whole frames")), \
				(kv "animated_or_procedural_other_tracks" (jStr "keys or procedural controllers on visibility, object, modifier or material parameters")), \
				(kv "has_modifiers" (jStr "nodes with a modifier stack")), \
				(kv "xform_modifier" (jStr "XForm or Reset XForm modifier in the stack")), \
				(kv "instanced" (jStr "instanced objects")), \
				(kv "open_groups" (jStr "group heads of open groups")), \
				(kv "missing_plugin_classes" (jStr "objects of plugins that are not installed")) \
			))) \
		)
	),

	-- Depth-first node list, parents before children.
	fn collectNodes selectedOnly = (
		local want = undefined
		if selectedOnly do (
			want = Dictionary #integer
			for s in selection do (
				local a = s
				while a != undefined do (
					want[a.handle] = true
					a = a.parent
				)
			)
		)
		local res = #()
		local stack = #()
		local rc = rootNode.children
		for i = rc.count to 1 by -1 do append stack rc[i]
		while stack.count > 0 do (
			local nd = stack[stack.count]
			deleteItem stack stack.count
			if want == undefined or (hasDictValue want nd.handle) do append res nd
			local ch = nd.children
			for i = ch.count to 1 by -1 do append stack ch[i]
		)
		res
	),

	fn defaultPath = (
		local dir = maxFilePath
		if dir == "" do dir = getDir #export
		if dir[dir.count] != "\\" do dir += "\\"
		local nm = if maxFileName != "" then (getFilenameFile maxFileName) else "untitled"
		dir + nm + "_scan.json"
	),

	-- ── sections of the document ─────────────────────────────────
	fn summaryJson secs done cnt = (
		local bounds = if sceneMin == undefined then "null" else ("[" + (jP3 sceneMin) + "," + (jP3 sceneMax) + "]")
		jObj #( \
			(kv "nodes_in_scene" (objects.count as string)), \
			(kv "nodes_scanned" (done as string)), \
			(kv "nodes_listed" (cnt as string)), \
			(kv "cancelled" (jBool cancelled)), \
			(kv "scan_errors" (scanErrors as string)), \
			(kv "seconds" (jNum secs)), \
			(kv "max_hierarchy_depth" (maxDepth as string)), \
			(kv "group_heads" (groupHeads as string)), \
			(kv "max_group_nesting" (maxGroupNesting as string)), \
			(kv "max_modifier_stack" (maxStack as string)), \
			(kv "total_faces" (totalFaces as string)), \
			(kv "missing_maps" (missingMaps as string)), \
			(kv "pivot_bounds" bounds) \
		)
	),

	fn buildSection nm = (
		case nm of (
			"units": unitsJson()
			"time": timeJson()
			"anim_layers": jArr (animLayersJson())
			"legend": legendJson()
			"selection_sets": jArr (selSetsJson())
			"xrefs": xrefsJson()
			"superclasses": histJson superHist
			"base_classes": histJson baseHist
			"evaluated_classes": histJson classHist
			"modifier_classes": histJson modHist
			"controller_classes": histJson ctrlHist
			"material_classes": histJson matHist
			"map_classes": histJson mapHist
			"issues": issuesJson()
			"renderer": jStr ((classOf renderers.current) as string)
			default: "null"
		)
	),

	-- A section of the document; a failure is logged and gives null.
	fn safeSection nm = (
		curStage = "section " + nm
		local t1 = timeStamp()
		local res = try (buildSection nm) catch (
			local ex = getCurrentException()
			local st = try (getCurrentExceptionStackTrace()) catch ""
			sectionFailed nm ex st
		)
		logLine ("section " + nm + " done (" + ((timeStamp() - t1) as string) + " ms)")
		res
	),

	-- ── main ─────────────────────────────────────────────────────
	fn scanBody outPath selectedOnly = (
		cancelled = false
		superHist = Dictionary #string
		baseHist = Dictionary #string
		classHist = Dictionary #string
		modHist = Dictionary #string
		ctrlHist = Dictionary #string
		matHist = Dictionary #string
		mapHist = Dictionary #string
		issues = Dictionary #string
		stageErrors = Dictionary #string
		matQueue = #()
		matQueued = Dictionary #string
		maxDepth = 0
		maxGroupNesting = 0
		maxStack = 0
		totalFaces = 0
		groupHeads = 0
		missingMaps = 0
		scanErrors = 0
		sectionErrors = 0
		sceneMin = undefined
		sceneMax = undefined
		local t0 = timeStamp()
		local mv = maxVersion()
		logLine ("Max Scene Scan " + toolVersion + ", 3ds Max " + (mv[1] as string) + ", " + localTime) toListener:true
		logLine ("scene: " + maxFilePath + maxFileName)
		logLine ("output: " + outPath)
		logLine ("options: selected_only=" + (selectedOnly as string) + " mesh=" + (optMesh as string) + " params=" + (optParams as string) + \
			" tracks=" + (optTracks as string) + " materials=" + (optMaterials as string) + " key_times=" + (optKeyTimes as string) + \
			" verbose=" + (optVerboseLog as string))
		logLine ("units: " + (units.SystemType as string) + " x " + (units.SystemScale as string) + ", fps " + (frameRate as string) + \
			", range " + (animationRange.start.frame as string) + " - " + (animationRange.end.frame as string))

		curStage = "collect nodes"
		local nodeList = collectNodes selectedOnly
		logLine ("nodes to scan: " + (nodeList.count as string) + " of " + (objects.count as string) + " in the scene") toListener:true

		local nodeSS = stringStream ""
		local done = 0
		with undo off (
			for i = 1 to nodeList.count do (
				if not cancelled do (
					local n = nodeList[i]
					curStage = "start"
					if optVerboseLog do logLine ("node " + (i as string) + "/" + (nodeList.count as string) + " id " + \
						(try (n.handle as string) catch "?") + " '" + (try (n.name) catch "?") + "' " + \
						(try ((classOf n.baseObject) as string) catch "?"))
					local js = try (nodeJson n) catch (
						local ex = getCurrentException()
						local st = try (getCurrentExceptionStackTrace()) catch ""
						nodeFailed n i ex st
					)
					if i > 1 do format ",\n" to:nodeSS
					format "%" js to:nodeSS
					done = i
					if keyboard.escPressed do (
						cancelled = true
						logLine ("cancelled by Esc after node " + (i as string)) toListener:true
					)
					if progressFn != undefined and ((mod i 20) == 0 or i == nodeList.count) do progressFn i nodeList.count
				)
			)
		)
		logLine ("nodes done: " + (done as string) + ", node errors: " + (scanErrors as string) + \
			", " + (((timeStamp() - t0) / 1000.0) as string) + " s") toListener:true

		local matItems = #()
		if optMaterials do (
			curStage = "materials"
			local t1 = timeStamp()
			matItems = try (materialsJson()) catch (
				local ex = getCurrentException()
				local st = try (getCurrentExceptionStackTrace()) catch ""
				sectionFailed "materials" ex st
				#()
			)
			logLine ("materials and maps: " + (matItems.count as string) + " (" + ((timeStamp() - t1) as string) + " ms)")
		)
		curStage = "layers"
		local lays = try (layersJson()) catch (
			local ex = getCurrentException()
			local st = try (getCurrentExceptionStackTrace()) catch ""
			sectionFailed "layers" ex st
			#()
		)
		logLine ("layers: " + (lays.count as string))
		local secs = (timeStamp() - t0) / 1000.0

		curStage = "document"
		local mvItems = #()
		for x in mv do append mvItems (jScalarOrNull x)
		local doc = stringStream ""
		format "{\n" to:doc
		format "\"format\":\"MaxSceneScan\",\"version\":1,\n" to:doc
		format "\"generator\":%,\n" (jStr ("Max Scene Scan " + toolVersion + " / 3ds Max " + (mv[1] as string))) to:doc
		format "\"scanned\":%,\n" (jStr localTime) to:doc
		format "\"max_version\":%,\n" (jArr mvItems) to:doc
		format "\"file\":%,\n" (jObj #((kv "path" (jStr maxFilePath)), (kv "name" (jStr maxFileName)))) to:doc
		format "\"renderer\":%,\n" (safeSection "renderer") to:doc
		format "\"options\":%,\n" (jObj #((kv "selected_only" (jBool selectedOnly)), (kv "mesh" (jBool optMesh)), \
			(kv "params" (jBool optParams)), (kv "tracks" (jBool optTracks)), (kv "materials" (jBool optMaterials)), \
			(kv "key_times" (optKeyTimes as string)))) to:doc
		format "\"units\":%,\n" (safeSection "units") to:doc
		format "\"time\":%,\n" (safeSection "time") to:doc
		format "\"anim_layers\":%,\n" (safeSection "anim_layers") to:doc
		format "\"legend\":%,\n" (safeSection "legend") to:doc
		local sm = #()
		append sm (kv "counts" (try (summaryJson secs done nodeList.count) catch "null"))
		for nmS in #("superclasses", "base_classes", "evaluated_classes", "modifier_classes", "controller_classes", \
			"material_classes", "map_classes", "issues") do append sm (kv nmS (safeSection nmS))
		local stItems = #()
		for k in stageErrors.keys do append stItems ((jStr k) + ":" + (stageErrors[k] as string))
		append sm (kv "errors_by_stage" (jObj stItems))
		append sm (kv "section_errors" (sectionErrors as string))
		format "\"summary\":%,\n" (jObj sm) to:doc
		format "\"layers\":[\n" to:doc
		for i = 1 to lays.count do format "%%\n" lays[i] (if i < lays.count then "," else "") to:doc
		format "],\n" to:doc
		format "\"selection_sets\":%,\n" (safeSection "selection_sets") to:doc
		format "\"xrefs\":%,\n" (safeSection "xrefs") to:doc
		format "\"materials\":{\n" to:doc
		for i = 1 to matItems.count do format "%%\n" matItems[i] (if i < matItems.count then "," else "") to:doc
		format "},\n" to:doc
		format "\"nodes\":[\n" to:doc
		format "%" (nodeSS as string) to:doc
		format "\n]\n}\n" to:doc

		curStage = "write file"
		local txt = doc as string
		txt = (dotNetClass "System.Text.RegularExpressions.Regex").Replace txt "[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F]" ""
		(dotNetClass "System.IO.File").WriteAllText outPath txt (dotNetObject "System.Text.UTF8Encoding" false)
		logLine ("written: " + outPath + " (" + ((getFileSize outPath) as string) + " bytes)") toListener:true
		for k in stageErrors.keys do logLine ("errors at " + k + ": " + (stageErrors[k] as string))
		logLine ("finished: " + (done as string) + " nodes, " + (scanErrors as string) + " node errors, " + \
			(sectionErrors as string) + " section errors, " + (((timeStamp() - t0) / 1000.0) as string) + " s") toListener:true
		#(done, nodeList.count, secs, cancelled, scanErrors + sectionErrors)
	),

	-- Scans and writes outPath; the log goes next to it (<name>.log).
	-- Returns #(nodes scanned, nodes listed, seconds, cancelled, errors).
	fn scan outPath selectedOnly:false = (
		logOpen ((getFilenamePath outPath) + (getFilenameFile outPath) + ".log")
		local res = undefined
		try (
			res = scanBody outPath selectedOnly
		) catch (
			local ex = getCurrentException()
			local st = try (getCurrentExceptionStackTrace()) catch ""
			logError ("FATAL at " + curStage) ex st
			logClose()
			throw
		)
		logClose()
		res
	)
)

MaxSceneScan = MaxSceneScanStruct()

try (destroyDialog MaxSceneScanRollout) catch ()

rollout MaxSceneScanRollout "Max Scene Scan  v1.1" width:380 (
	group "Scope" (
		radioButtons rbScope labels:#("Whole scene", "Selected objects (and their parents)") default:1 columns:1 align:#left
	)
	group "Include" (
		checkbox chkMesh "Face and vertex counts (evaluates modifier stacks)" checked:true
		checkbox chkParams "Object, modifier and controller parameters" checked:true
		checkbox chkTracks "Keyed tracks other than transforms" checked:true
		checkbox chkMats "Materials and maps" checked:true
		spinner spnTimes "Key frames listed per track " range:[0,100000,30] type:#integer fieldWidth:60 align:#left
	)
	group "Log" (
		checkbox chkVerbose "Log every object (finds an object that breaks the scan)" checked:true
	)
	group "Output file" (
		edittext etPath "" width:316 across:2 align:#left
		button btnBrowse "..." width:30 align:#right
	)
	button btnScan "Scan" width:350 height:32
	progressBar pbScan value:0 width:350 height:10
	label lblStatus "Esc cancels a running scan. The log is written next to the JSON." width:350 height:44 align:#left
	button btnShow "Show file in Explorer" width:172 enabled:false across:2
	button btnLog "Open log" width:172 enabled:false

	fn onProgress done total = (
		pbScan.value = 100.0 * done / total
		lblStatus.text = "Scanning object " + (done as string) + " of " + (total as string) + "   (Esc cancels)"
		windows.processPostedMessages()
	)

	on MaxSceneScanRollout open do (
		etPath.text = MaxSceneScan.defaultPath()
	)

	on btnBrowse pressed do (
		local fp = getSaveFileName caption:"Save the scene scan" filename:etPath.text types:"JSON (*.json)|*.json|All files (*.*)|*.*|"
		if fp != undefined do etPath.text = fp
	)

	on btnScan pressed do (
		if rbScope.state == 2 and selection.count == 0 then (
			messageBox "Select objects first, or scan the whole scene." title:"Max Scene Scan"
		) else (
			MaxSceneScan.optMesh = chkMesh.checked
			MaxSceneScan.optParams = chkParams.checked
			MaxSceneScan.optTracks = chkTracks.checked
			MaxSceneScan.optMaterials = chkMats.checked
			MaxSceneScan.optKeyTimes = spnTimes.value
			MaxSceneScan.optVerboseLog = chkVerbose.checked
			MaxSceneScan.progressFn = onProgress
			btnScan.enabled = false
			btnShow.enabled = false
			btnLog.enabled = false
			pbScan.value = 0
			local res = try (MaxSceneScan.scan etPath.text selectedOnly:(rbScope.state == 2)) catch (
				lblStatus.text = "Scan failed at " + MaxSceneScan.curStage + ":\n" + (getCurrentException()) + \
					"\nDetails: Open log."
				undefined
			)
			btnScan.enabled = true
			btnLog.enabled = doesFileExist MaxSceneScan.logPath
			if res != undefined do (
				pbScan.value = 100
				local head = if res[4] then "Cancelled after " else "Done: "
				local errs = if res[5] > 0 then (", " + (res[5] as string) + " errors (see log)") else ", no errors"
				lblStatus.text = head + (res[1] as string) + " of " + (res[2] as string) + " objects in " + \
					(formattedPrint res[3] format:".1f") + " s" + errs + ".\n" + (filenameFromPath etPath.text)
				btnShow.enabled = true
			)
		)
	)

	on btnShow pressed do (
		shellLaunch "explorer.exe" ("/select,\"" + etPath.text + "\"")
	)

	on btnLog pressed do (
		if doesFileExist MaxSceneScan.logPath do shellLaunch "notepad.exe" ("\"" + MaxSceneScan.logPath + "\"")
	)
)

createDialog MaxSceneScanRollout
