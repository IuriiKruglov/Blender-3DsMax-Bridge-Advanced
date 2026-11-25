-- ============================================================
--  Blender <-> 3Ds Max Bridge Advanced  (3ds Max script)
--  Version 3.0
--
--  Created by Claude (Anthropic)
--  under the leadership of Kruglov Iurii
--  License: GNU General Public License v3.0
-- ============================================================
--
--  One script for both directions, together with the Blender add-on
--  blender_max_bridge.py 3.0. Both apps use one bridge folder (default
--  %LOCALAPPDATA%\BlenderMaxBridge; set the same folder in the Blender
--  add-on preferences).
--
--  Blender -> 3ds Max (receive; was BlenderMaxBridge.ms 2.5.1):
--    "Start listening" polls the bridge folder. "Send to 3ds Max" in
--    Blender drops a job there; the listener imports the FBX, applies
--    the JSON (hierarchy, rotation orders, transforms, keys, layers,
--    dummies or exact bones with Skin, bones linked to objects, scene
--    units) and writes the result back to Blender. Optional autostart
--    with 3ds Max.
--
--  3ds Max -> Blender (send; was MaxToBlenderBridge.ms 0.7.1):
--    "Send to Blender" writes the scene or the selection to
--    <bridge folder>\FromMax (<scene>.json + .bin + .log, latest.json)
--    or to a file: hierarchy, groups, pivots, layers, meshes with
--    3ds Max's own normals, splines, materials, Skin, live Shell /
--    TurboSmooth, animation, and values Blender checks itself against.
--    In Blender: "Import latest from 3ds Max".
--
--  Reset: after an error, a freeze or a hang, puts both directions
--  back to idle: stops the listener (and starts it again if it was on),
--  clears its busy state, answers a job Blender is waiting for so
--  Blender stops waiting, turns scene redraw back on, ends a progress
--  bar, gives objects an interrupted Replace renamed their names back,
--  closes files an interrupted export left open, and reads the settings
--  again. Scene data is not changed otherwise. The Blender add-on has
--  its own Reset.
--
--  INSTALL: Scripting > Run Script > BlenderMaxBridge.ms. It replaces
--  BlenderMaxBridge.ms 2.x (same file name; an enabled autostart is
--  pointed at this file) and MaxToBlenderBridge_v0.x.ms (do not run it
--  any more). Settings: plugcfg\BlenderMaxBridge.ini.
--
--  Compatible with 3ds Max 2022 - 2026 (Send to Blender: 2024 - 2026).
--  Full documentation and version history: README.md.
-- ============================================================

global BlenderMaxBridge
global BlenderMaxBridgeStruct
global BlenderMaxBridgeRollout
global BlenderMaxBridgeTopRollout
global BlenderMaxBridgeFloater
global BlenderMaxBridge_Timer
global BlenderMaxBridge_onTick
global BlenderMaxBridge_Reset
global BlenderMaxBridge_RefreshUI
global BlenderMaxBridge_OpenUI
global BlenderMaxBridge_AutoStart
global BlenderMaxBridge_Resume = (BlenderMaxBridge_Timer != undefined)
global MaxToBlender
global MaxToBlenderRollout
-- the compiled normals reader, kept for the 3ds Max session: #(its C# source, reader)
global MaxToBlenderNormalsReader

-- Stop the timer of a previous run of this script.
if BlenderMaxBridge_Timer != undefined do (
	try (BlenderMaxBridge_Timer.Stop()) catch ()
	try (dotNet.removeAllEventHandlers BlenderMaxBridge_Timer) catch ()
	try (BlenderMaxBridge_Timer.Dispose()) catch ()
	BlenderMaxBridge_Timer = undefined
)
-- Close the windows of a previous run (this script, or the older one-way scripts).
if BlenderMaxBridgeFloater != undefined do (try (closeRolloutFloater BlenderMaxBridgeFloater) catch ())
BlenderMaxBridgeFloater = undefined
try (destroyDialog BlenderMaxBridgeRollout) catch ()
try (destroyDialog MaxToBlenderRollout) catch ()


-- ============================================================
--  PART 1   Blender -> 3ds Max  (receive: the listener)
-- ============================================================

struct BlenderMaxBridgeStruct (
	bridgeVersion = "3.0",
	bridgeDir = "",
	unitsMode = "ask",          -- scene not in centimeters: "ask", "cm" (switch to cm) or "keep" (keep its units)
	unitsAnswer = undefined,    -- the answer given this session (#switch / #keep), for unitsAnswerKey
	unitsAnswerKey = "",
	scriptFile = "",
	listening = false,
	busy = false,
	lastBeat = 0,
	lastLine1 = "-",
	lastLine2 = "",
	lastJobId = "",
	jobInProgress = "",         -- id of the job being imported (Reset and a crash answer it)
	warnings = #(),

	-- ── Logging ─────────────────────────────────────────────────────────
	fn logLine msg = (
		format "[Blender->Max Bridge] %\n" msg
	),
	fn warn msg = (
		if warnings.count < 100 do append warnings msg
		logLine ("WARNING: " + msg)
	),

	-- ── Files (.NET, available in every 3ds Max version) ───────────────
	fn readText fp = (
		(dotNetClass "System.IO.File").ReadAllText fp
	),
	fn writeText fp txt = (
		(dotNetClass "System.IO.File").WriteAllText fp txt
	),
	fn fileExists fp = (
		(dotNetClass "System.IO.File").Exists fp
	),
	fn deleteFileSafe fp = (
		try ((dotNetClass "System.IO.File").Delete fp) catch ()
	),
	-- Blender may be reading the file for a moment: retry for up to 1 s.
	fn deleteFileRetry fp = (
		local n = 0
		while (fileExists fp) and n < 20 do (
			deleteFileSafe fp
			if fileExists fp do sleep 0.05
			n += 1
		)
		not (fileExists fp)
	),
	fn writeTextAtomic fp txt = (
		local tmp = fp + ".tmp"
		writeText tmp txt
		local done = false
		local n = 0
		while not done and n < 40 do (
			try (
				if fileExists fp do (dotNetClass "System.IO.File").Delete fp
				(dotNetClass "System.IO.File").Move tmp fp
				done = true
			) catch (
				sleep 0.05
				n += 1
			)
		)
		if not done do (
			writeText fp txt
			deleteFileSafe tmp
		)
	),
	fn ensureDir dir = (
		if not ((dotNetClass "System.IO.Directory").Exists dir) do (
			try ((dotNetClass "System.IO.Directory").CreateDirectory dir) catch ()
		)
		(dotNetClass "System.IO.Directory").Exists dir
	),
	-- Seconds since the file was written (double precision, from .NET).
	fn fileAgeSeconds fp = (
		local wt = (dotNetClass "System.IO.File").GetLastWriteTimeUtc fp
		((dotNetClass "System.DateTime").UtcNow.Subtract wt).TotalSeconds
	),

	-- ── Settings ────────────────────────────────────────────────────────
	fn iniFile = (
		pathConfig.appendPath (getDir #plugcfg) "BlenderMaxBridge.ini"
	),
	fn defaultBridgeDir = (
		local base = systemTools.getEnvVariable "LOCALAPPDATA"
		if base == undefined or base == "" do base = (dotNetClass "System.IO.Path").GetTempPath()
		pathConfig.appendPath base "BlenderMaxBridge"
	),
	fn loadSettings = (
		local d = getINISetting (iniFile()) "Bridge" "Folder"
		bridgeDir = if d != "" then d else (defaultBridgeDir())
		local um = getINISetting (iniFile()) "Bridge" "Units"
		unitsMode = if um == "cm" or um == "keep" then um else "ask"
	),
	fn saveSettings = (
		setINISetting (iniFile()) "Bridge" "Folder" bridgeDir
		setINISetting (iniFile()) "Bridge" "Units" unitsMode
	),

	-- ── JSON ────────────────────────────────────────────────────────────
	fn jsonEsc s = (
		local r = substituteString (s as string) "\\" "\\\\"
		r = substituteString r "\"" "\\\""
		r = substituteString r "\n" "\\n"
		r = substituteString r "\r" "\\r"
		r = substituteString r "\t" "\\t"
		r
	),
	fn jsonUnescape s = (
		local outStr = ""
		local i = 1
		local n = s.count
		while i <= n do (
			local c = s[i]
			if c == "\\" and i < n then (
				local e2 = s[i + 1]
				i += 2
				case e2 of (
					"n": outStr += "\n"
					"t": outStr += "\t"
					"r": outStr += "\r"
					"b": outStr += (bit.intAsChar 8)
					"f": outStr += (bit.intAsChar 12)
					"u": (
						outStr += (bit.intAsChar (bit.hexAsInt (substring s i 4)))
						i += 4
					)
					default: outStr += e2
				)
			) else (
				outStr += c
				i += 1
			)
		)
		outStr
	),
	fn parseNum s = (
		local ePos = findString s "e"
		if ePos == undefined do ePos = findString s "E"
		if ePos == undefined then (s as float) else (
			local mant = (substring s 1 (ePos - 1)) as float
			local ex = substring s (ePos + 1) -1
			if ex.count > 0 and ex[1] == "+" do ex = substring ex 2 -1
			mant * (10.0 ^ (ex as integer))
		)
	),
	-- Iterative parser: objects -> Dictionary #string, arrays -> Array,
	-- numbers -> Float, true/false, null -> undefined.
	fn parseJSON src = (
		local n = src.count
		local i = 1
		local root = undefined
		local stack = #()
		local isObj = #()
		local depth = 0
		local curKey = ""
		local expectKey = false
		local numChars = "0123456789+-.eE"
		while i <= n do (
			local c = src[i]
			if c == "{" or c == "[" then (
				local cont = if c == "{" then (Dictionary #string) else #()
				if depth == 0 then root = cont
				else if isObj[depth] then stack[depth][curKey] = cont
				else append stack[depth] cont
				depth += 1
				stack[depth] = cont
				isObj[depth] = (c == "{")
				expectKey = (c == "{")
				i += 1
			) else if c == "}" or c == "]" then (
				depth -= 1
				expectKey = false
				i += 1
			) else if c == "\"" then (
				local j = i + 1
				local esc = false
				while j <= n and src[j] != "\"" do (
					if src[j] == "\\" then (
						esc = true
						j += 2
					) else j += 1
				)
				local s = substring src (i + 1) (j - i - 1)
				if esc do s = jsonUnescape s
				i = j + 1
				if depth > 0 and isObj[depth] and expectKey then (
					curKey = s
					expectKey = false
				) else (
					if depth == 0 then root = s
					else if isObj[depth] then stack[depth][curKey] = s
					else append stack[depth] s
				)
			) else if c == "," then (
				if depth > 0 and isObj[depth] do expectKey = true
				i += 1
			) else if c == ":" or c == " " or c == "\n" or c == "\r" or c == "\t" then (
				i += 1
			) else (
				local v = undefined
				if c == "t" then (
					v = true
					i += 4
				) else if c == "f" then (
					v = false
					i += 5
				) else if c == "n" then (
					i += 4
				) else (
					local j = i + 1
					while j <= n and (findString numChars src[j]) != undefined do j += 1
					v = parseNum (substring src i (j - i))
					i = j
				)
				if depth == 0 then root = v
				else if isObj[depth] then stack[depth][curKey] = v
				else append stack[depth] v
			)
		)
		root
	),

	-- ── Math ────────────────────────────────────────────────────────────
	fn r2d v = v * (180.0 / pi),

	fn dget d k fb = (
		local v = d[k]
		if v == undefined then fb else v
	),

	fn blenderOrderToMax s = (
		case s of (
			"XYZ": 1
			"XZY": 2
			"YZX": 3
			"YXZ": 4
			"ZXY": 5
			"ZYX": 6
			default: 1
		)
	),

	fn buildWorldRot xDeg yDeg zDeg modeStr = (
		local mX = rotateXMatrix xDeg
		local mY = rotateYMatrix yDeg
		local mZ = rotateZMatrix zDeg
		case modeStr of (
			"XYZ": mX * mY * mZ
			"YZX": mY * mZ * mX
			"ZXY": mZ * mX * mY
			"XZY": mX * mZ * mY
			"YXZ": mY * mX * mZ
			"ZYX": mZ * mY * mX
			default: mX * mY * mZ
		)
	),

	fn safeAsin v = (
		local c = v
		if c >  1.0 do c =  1.0
		if c < -1.0 do c = -1.0
		asin c
	),

	-- Rotation about one axis ("X", "Y" or "Z") in degrees, row convention.
	fn axisRot ax deg = (
		case ax of (
			"X": rotateXMatrix deg
			"Y": rotateYMatrix deg
			default: rotateZMatrix deg
		)
	),

	-- Angle of a pure rotation about one axis (inverse of axisRot).
	fn axisAngleOf ax M = (
		case ax of (
			"X": atan2 M[2][3] M[2][2]
			"Y": atan2 M[3][1] M[3][3]
			default: atan2 M[1][2] M[1][1]
		)
	),

	-- Gimbal lock (middle angle +-90 deg): the first and the third axis
	-- coincide. The third angle is set to 0 and the first one takes the
	-- whole turn: R1(a1) = L * inverse(R2(middle)). Valid for +90 and -90.
	fn gimbalFirst L modeStr midDeg = (
		axisAngleOf modeStr[1] (L * (inverse (axisRot modeStr[2] midDeg)))
	),

	-- Euler angles (degrees, #(x, y, z)) of a rotation matrix for a rotation
	-- order. Middle angle in [-90, 90]. Below eps the matrix is treated as
	-- gimbal-locked (eps 1e-4: |middle| within 0.006 deg of 90; the
	-- gimbal branch is then accurate to about 0.02 deg, while the regular
	-- branch would divide 32-bit matrix noise by cos(middle)).
	fn decomposeEuler L modeStr = (
		local x=0.0; local y=0.0; local z=0.0
		local eps = 1e-4
		if modeStr == "XYZ" do (
			local sy = safeAsin (-(L[1][3]))
			local cy = cos sy
			if (abs cy) > eps then (
				x = atan2 ( L[2][3]/cy) (L[3][3]/cy)
				z = atan2 ( L[1][2]/cy) (L[1][1]/cy)
			) else ( x = gimbalFirst L modeStr sy; z = 0.0 )
			y = sy
		)
		if modeStr == "YZX" do (
			local sz = safeAsin (-(L[2][1]))
			local cz = cos sz
			if (abs cz) > eps then (
				y = atan2 ( L[3][1]/cz) (L[1][1]/cz)
				x = atan2 ( L[2][3]/cz) (L[2][2]/cz)
			) else ( y = gimbalFirst L modeStr sz; x = 0.0 )
			z = sz
		)
		if modeStr == "ZXY" do (
			local sx = safeAsin (-(L[3][2]))
			local cx = cos sx
			if (abs cx) > eps then (
				z = atan2 ( L[1][2]/cx) (L[2][2]/cx)
				y = atan2 ( L[3][1]/cx) (L[3][3]/cx)
			) else ( z = gimbalFirst L modeStr sx; y = 0.0 )
			x = sx
		)
		if modeStr == "XZY" do (
			local sz = safeAsin L[1][2]
			local cz = cos sz
			if (abs cz) > eps then (
				x = atan2 (-(L[3][2]/cz)) (L[2][2]/cz)
				y = atan2 (-(L[1][3]/cz)) (L[1][1]/cz)
			) else ( x = gimbalFirst L modeStr sz; y = 0.0 )
			z = sz
		)
		if modeStr == "YXZ" do (
			local sx = safeAsin L[2][3]
			local cx = cos sx
			if (abs cx) > eps then (
				y = atan2 (-(L[1][3]/cx)) (L[3][3]/cx)
				z = atan2 (-(L[2][1]/cx)) (L[2][2]/cx)
			) else ( y = gimbalFirst L modeStr sx; z = 0.0 )
			x = sx
		)
		if modeStr == "ZYX" do (
			local sy = safeAsin L[3][1]
			local cy = cos sy
			if (abs cy) > eps then (
				z = atan2 (-(L[2][1]/cy)) (L[1][1]/cy)
				x = atan2 (-(L[3][2]/cy)) (L[3][3]/cy)
			) else ( z = gimbalFirst L modeStr sy; x = 0.0 )
			y = sy
		)
		#(x, y, z)
	),

	fn axisIndex ax = (
		case ax of (
			"X": 1
			"Y": 2
			default: 3
		)
	),

	-- The other Euler triple of the same rotation, in rotation-order terms:
	-- (a1 + 180, 180 - a2, a3 + 180). eul: #(x, y, z) or Point3.
	fn dualEuler eul modeStr = (
		local v = #(eul[1], eul[2], eul[3])
		local i1 = axisIndex modeStr[1]
		local i2 = axisIndex modeStr[2]
		local i3 = axisIndex modeStr[3]
		v[i1] = v[i1] + 180.0
		v[i2] = 180.0 - v[i2]
		v[i3] = v[i3] + 180.0
		[v[1], v[2], v[3]]
	),

	-- v plus the whole turns that bring it nearest to nearTo.
	fn wrapNear v nearTo = v + 360.0 * (floor ((nearTo - v) / 360.0 + 0.5)),

	-- Same rotation: every element within tol (1e-4 ~ 0.006 deg).
	fn sameRotation A B tol = (
		local d = 0.0
		for r = 1 to 3 do (
			local dv = A[r] - B[r]
			d = amax #(d, abs dv.x, abs dv.y, abs dv.z)
		)
		d < tol
	),

	-- The Euler triple of L (Point3, degrees) nearest to prev: the primary
	-- or the dual triple, or under gimbal lock the one that keeps prev's
	-- third angle; whole turns added.
	fn nearestEuler L modeStr prev = (
		local p = decomposeEuler L modeStr
		local i1 = axisIndex modeStr[1]
		local i2 = axisIndex modeStr[2]
		local i3 = axisIndex modeStr[3]
		local cands = #([p[1], p[2], p[3]], (dualEuler p modeStr))
		if (abs (cos (p[i2]))) <= 1e-4 do (
			local gThird = prev[i3]
			local gFirst = axisAngleOf modeStr[1] (L * (inverse (axisRot modeStr[3] gThird)) * (inverse (axisRot modeStr[2] (p[i2]))))
			local g = #(p[1], p[2], p[3])
			g[i1] = gFirst
			g[i3] = gThird
			append cands [g[1], g[2], g[3]]
		)
		local best = undefined
		local bestD = 1e30
		for c in cands do (
			local w = [(wrapNear c.x prev.x), (wrapNear c.y prev.y), (wrapNear c.z prev.z)]
			local dd = (abs (w.x - prev.x)) + (abs (w.y - prev.y)) + (abs (w.z - prev.z))
			if dd < bestD do (
				best = w
				bestD = dd
			)
		)
		best
	),

	-- Euler values (Point3, degrees) for the next rotation key, from Blender's
	-- channel values rawPrev -> raw (Point3, degrees) and the previous key prev.
	-- 1. prev + Blender's change, when that is the same rotation all along the
	--    step (checked at the key and at two points inside the step). Keeps
	--    whole turns, angles past 90 deg and Blender's split between the axes,
	--    and 3ds Max interpolates the step like Blender.
	-- 2. Otherwise Blender's motion is followed in steps of at most 30 deg,
	--    each taking the equivalent triple nearest to the last one, so whole
	--    turns and the direction survive even when a Blender axis maps to
	--    another 3ds Max axis.
	fn continuousEuler rawPrev raw modeStr iPW prev = (
		local delta = raw - rawPrev
		local direct = true
		for sf in #(1.0, 0.381966, 0.723607) do (
			if direct do (
				local t = prev + delta * sf
				local r = rawPrev + delta * sf
				if not (sameRotation (buildWorldRot t.x t.y t.z modeStr) ((buildWorldRot r.x r.y r.z modeStr) * iPW) 1e-4) do direct = false
			)
		)
		if direct then (prev + delta) else (
			local n = (ceil ((amax #((abs delta.x), (abs delta.y), (abs delta.z))) / 30.0)) as integer
			if n < 1 do n = 1
			local cur = prev
			for j = 1 to n do (
				local r = rawPrev + delta * ((j as float) / n)
				cur = nearestEuler ((buildWorldRot r.x r.y r.z modeStr) * iPW) modeStr cur
			)
			cur
		)
	),

	-- "parent_space" (3 rows of Blender's 4x4 M, column vectors) as a 3ds Max
	-- matrix3 (row vectors): the transpose, translation in system units.
	fn parentSpaceMatrix ps U = (
		matrix3 [ps[1][1], ps[2][1], ps[3][1]] [ps[1][2], ps[2][2], ps[3][2]] \
			[ps[1][3], ps[2][3], ps[3][3]] [(ps[1][4] * U), (ps[2][4] * U), (ps[3][4] * U)]
	),

	-- Rotation of a matrix3: rows made orthonormal, no scale, no translation.
	fn rotationPart m = (
		local r1 = normalize m.row1
		local r2 = normalize (m.row2 - (dot m.row2 r1) * r1)
		matrix3 r1 r2 (cross r1 r2) [0, 0, 0]
	),

	fn getParentW wm rec = (
		local pn = dget rec "parent" ""
		local pw = if pn != "" then wm[pn] else undefined
		if pw == undefined then (matrix3 1) else pw
	),

	-- ── Keyframe tables (O(1) lookups) ──────────────────────────────────
	fn frameKey f = ((floor (f * 1000.0 + 0.5)) as integer),

	fn frameTime f = (
		if f == (floor f) then ((f as integer) as time) else (f as time)
	),

	fn keyMap arr = (
		local m = Dictionary #integer
		for kf in arr do m[frameKey kf["frame"]] = kf["value"]
		m
	),

	fn frameSetOf arr = (
		local m = Dictionary #integer
		for kf in arr do m[frameKey kf["frame"]] = true
		m
	),

	fn addFrames arr frameSet frameList = (
		for kf in arr do (
			local f = kf["frame"]
			local k = frameKey f
			if not (hasDictValue frameSet k) do (
				frameSet[k] = true
				append frameList f
			)
		)
	),

	fn mapGet m k fb = (
		local v = m[k]
		if v == undefined then fb else v
	),

	-- ── Scene helpers ───────────────────────────────────────────────────
	-- Parents before children (iterative, no recursion).
	fn topoSort objs = (
		local sorted = #()
		local state = Dictionary #string
		for start in objs.keys do (
			if not (hasDictValue state start) do (
				local stack = #(start)
				while stack.count > 0 do (
					local nm = stack[stack.count]
					if hasDictValue state nm then (
						deleteItem stack stack.count
						if state[nm] == 1 do (
							state[nm] = 2
							append sorted nm
						)
					) else (
						state[nm] = 1
						local pn = dget objs[nm] "parent" ""
						if pn != "" and (hasDictValue objs pn) and not (hasDictValue state pn) do append stack pn
					)
				)
			)
		)
		sorted
	),

	fn buildLookup nodeArr = (
		local m = Dictionary #string
		for o in nodeArr do (
			if not (hasDictValue m o.name) do m[o.name] = o
		)
		m
	),

	fn getOrCreateLayer layerName = (
		local lyr = LayerManager.getLayerFromName layerName
		if lyr == undefined do lyr = LayerManager.newLayerFromName layerName
		lyr
	),

	-- 3ds Max system units per centimetre.
	fn cmToSystem = (
		local cmPerType = case units.SystemType of (
			#inches: 2.54
			#feet: 30.48
			#miles: 160934.4
			#millimeters: 0.1
			#centimeters: 1.0
			#meters: 100.0
			#kilometers: 100000.0
			default: 1.0
		)
		1.0 / (cmPerType * units.SystemScale)
	),

	-- Scale the FBX importer really used (imported position / Blender
	-- location). Returns undefined unless at least 3 objects agree within
	-- 0.5 % (objects whose location is relative to a moved parent are outliers).
	fn measureUnitFactor objs nodes = (
		local ratios = #()
		for nm in nodes.keys do (
			local loc = dget objs[nm] "location" undefined
			-- with "parent_space" the location is not a world position
			if (dget objs[nm] "parent_space" undefined) != undefined do loc = undefined
			if loc != undefined do (
				local bl = length [loc[1], loc[2], loc[3]]
				if bl > 0.001 do append ratios ((length nodes[nm].pos) / bl)
			)
		)
		local result = undefined
		if ratios.count >= 3 do (
			sort ratios
			local med = ratios[(ratios.count + 1) / 2]
			if med > 1e-9 do (
				local inliers = 0
				for r in ratios where (abs (r / med - 1.0)) < 0.005 do inliers += 1
				if inliers * 10 >= ratios.count * 6 do result = med
			)
		)
		result
	),

	-- Node for a name: the one just imported from the FBX, else any scene node.
	fn findNode nm lookup = (
		local nd = lookup[nm]
		if nd != undefined and not (isValidNode nd) do nd = undefined
		if nd == undefined do nd = getNodeByName nm exact:true
		nd
	),

	-- Returns #(nodes Dictionary, missing names)
	fn findObjectNodes objs names lookup = (
		local nodes = Dictionary #string
		local missing = #()
		for nm in names do (
			local nd = findNode nm lookup
			if nd == undefined then append missing nm else nodes[nm] = nd
		)
		#(nodes, missing)
	),

	-- Blender units -> 3ds Max system units. Right after an FBX import the
	-- factor is checked on the imported objects, so location keys and bone
	-- dummies always match the scale the FBX importer used.
	fn resolveUnitFactor root lookup measure = (
		local U = (dget root "unit_to_cm" 100.0) * (cmToSystem())
		if measure do (
			local objs = root["objects"]
			local found = findObjectNodes objs objs.keys lookup
			local mU = measureUnitFactor objs found[1]
			if mU != undefined and (abs (mU / U - 1.0)) > 0.01 do (
				warn ("FBX was imported at " + (mU as string) + " units per Blender unit (expected " + \
					(U as string) + "); location keys follow the FBX. Check the FBX importer Units setting.")
				U = mU
			)
		)
		U
	),

	-- ── Scene units (2.5) ───────────────────────────────────────────────
	-- Blender sends sizes in centimeters (FBX) and Blender units (JSON). In a scene
	-- that is not in centimeters the FBX is imported with the units switched to
	-- centimeters for a moment (so the FBX importer converts nothing), then the
	-- new objects are rescaled to the scene units; everything from the JSON is
	-- multiplied by U = Blender units -> scene units.
	fn isCentimeters = (
		units.SystemType == #centimeters and (abs (units.SystemScale - 1.0)) < 1e-6
	),
	fn cmPerSystemUnit = (1.0 / (cmToSystem())),
	fn unitsLabel = (
		local t = units.SystemType as string
		if (abs (units.SystemScale - 1.0)) > 1e-6 then ((units.SystemScale as string) + " " + t) else t
	),

	-- What to do in a scene that is not in centimeters: #switch, #keep or #cancel.
	fn unitsDecision = (
		if isCentimeters() then #keep else (
			local key = unitsLabel()
			if unitsMode == "cm" then #switch
			else if unitsMode == "keep" then #keep
			else if unitsAnswer != undefined and unitsAnswerKey == key then unitsAnswer
			else (
				local cm = cmPerSystemUnit()
				local txt = "This 3ds Max scene uses " + key + " (1 unit = " + (cm as string) + " cm).\n" + \
					"Scenes from Blender come in best in centimeters.\n\n" + \
					"Yes:  switch the scene to centimeters (objects already in the scene are\n" + \
					"        rescaled and keep their size)\n" + \
					"No:  keep " + key + " (the Blender scene is rebuilt in " + key + ")\n" + \
					"Cancel:  do not import\n\n" + \
					"The answer is kept until 3ds Max closes; the listener window can make it permanent."
				local r = yesNoCancelBox txt title:"Blender <-> 3Ds Max Bridge: scene units"
				local ans = if r == #yes then #switch else if r == #no then #keep else #cancel
				if ans != #cancel do (
					unitsAnswer = ans
					unitsAnswerKey = key
				)
				ans
			)
		)
	),

	-- Scene -> centimeters; objects already in it keep their size (Rescale World Units).
	fn switchToCentimeters = (
		local key = unitsLabel()
		local f = cmPerSystemUnit()
		local n = objects.count
		if n > 0 and (abs (f - 1.0)) > 1e-9 do rescaleWorldUnits f
		units.SystemType = #centimeters
		units.SystemScale = 1.0
		logLine ("Scene units: " + key + " -> centimeters" + (if n > 0 then (", " + (n as string) + " objects rescaled x" + (f as string) + " (same size)") else ""))
	),

	-- Size (box diagonal) of a node's object in its own space: node.min / node.max (the
	-- object box carried into the world) with the node at the identity for that moment.
	-- For new, unlinked FBX nodes only.
	fn localSize nd = (
		local d = 0.0
		local t = nd.transform
		try (
			nd.transform = matrix3 1
			d = length (nd.max - nd.min)
		) catch (d = 0.0)
		nd.transform = t
		d
	),

	-- Geometry of an editable mesh / poly scaled by k in its own space (fallback).
	fn scaleGeometry nd k = (
		local bo = nd.baseObject
		local done = false
		-- base object, no node: positions in the object's own space
		if classOf bo == Editable_Poly then (
			for i = 1 to (polyop.getNumVerts bo) do polyop.setVert bo i ((polyop.getVert bo i) * k)
			done = true
		) else if classOf bo == Editable_Mesh then (
			for i = 1 to bo.mesh.numverts do meshop.setVert bo i ((meshop.getVert bo i) * k)
			done = true
		)
		if done do (
			nd.objectOffsetPos = nd.objectOffsetPos * k
			update nd
		)
		done
	),

	-- New objects from the FBX (centimeter numbers) -> scene units: positions and
	-- geometry x k (Rescale World Units), checked object by object.
	fn rescaleImported newNodes k = (
		local nds = for o in newNodes where (isValidNode o) collect o
		if nds.count > 0 and (abs (k - 1.0)) > 1e-9 do (
			local pos0 = for o in nds collect o.pos
			local scale0 = for o in nds collect o.scale
			local size0 = for o in nds collect (if superClassOf o == GeometryClass then (localSize o) else 0.0)
			clearSelection()
			select nds
			try (rescaleWorldUnits k #selOnly) catch (warn ("Rescale World Units failed: " + (getCurrentException())))
			clearSelection()
			local fixedPos = 0
			local fixedGeo = 0
			local badGeo = #()
			for i = 1 to nds.count do (
				local o = nds[i]
				-- the node scale stays Blender's; the position and the geometry scale by k
				if (length (o.scale - scale0[i])) > 1e-5 * (length scale0[i]) do o.scale = scale0[i]
				local want = pos0[i] * k
				if (length (o.pos - want)) > 1e-4 * (amax 1.0 (length want)) do (
					o.pos = want
					fixedPos += 1
				)
				if size0[i] > 1e-6 do (
					local r = (localSize o) / size0[i]
					if (abs (r - k)) > 1e-3 * k do (
						if (abs (r - 1.0)) < 1e-3 and (scaleGeometry o k) then fixedGeo += 1 else append badGeo o.name
					)
				)
			)
			logLine ("Scene units " + (unitsLabel()) + ": " + (nds.count as string) + " imported objects rescaled x" + (k as string) + \
				(if fixedPos > 0 then (", " + (fixedPos as string) + " positions set") else "") + \
				(if fixedGeo > 0 then (", " + (fixedGeo as string) + " meshes scaled directly") else ""))
			if badGeo.count > 0 do warn ((badGeo.count as string) + " object(s) could not be rescaled to " + (unitsLabel()) + \
				" (e.g. " + badGeo[1] + "); switch the scene to centimeters and send again.")
		)
	),

	-- Mesh sizes against Blender's ("size": local box diagonal in Blender units). Meshes
	-- that came with modifiers (a Skin from FBX bones: posed in Blender) are left out.
	fn checkMeshSizes root lookup U = (
		local objs = root["objects"]
		local n = 0
		local bad = #()
		for nm in objs.keys do (
			local bs = dget objs[nm] "size" undefined
			local nd = if bs != undefined then (findNode nm lookup) else undefined
			if nd != undefined and bs > 1e-9 and nd.modifiers.count == 0 do (
				local ms = localSize nd
				n += 1
				if (abs (ms / (bs * U) - 1.0)) > 1e-3 do append bad (nm + " " + (ms as string) + " vs " + ((bs * U) as string))
			)
		)
		if n > 0 do logLine ("Size check: " + (n as string) + " meshes against Blender in " + (unitsLabel()) + ", " + (bad.count as string) + " differ")
		if bad.count > 0 do warn ((bad.count as string) + " mesh(es) differ in size from Blender (e.g. " + bad[1] + " " + (unitsLabel()) + ")")
		bad.count
	),

	-- ── Armatures -> dummies + Skin (JSON v3) ───────────────────────────
	-- Blender computes every value (bind pose, pose, keys) as the local
	-- transform of the dummy relative to its 3ds Max parent:
	-- position (Blender units), Euler XYZ (radians), scale.
	fn tangentType s = (
		case s of (
			"flat": #flat
			"linear": #linear
			"step": #step
			default: #auto
		)
	),

	fn setKeyTangents k kf = (
		if kf != undefined do (
			local tin = kf["ti"]
			local tout = kf["to"]
			if tin != undefined do k.inTangentType = tangentType tin
			if tout != undefined do k.outTangentType = tangentType tout
		)
	),

	fn makeDummy nm size = (
		local d = Dummy name:nm
		d.boxsize = [size, size, size]
		if classOf d.pos.controller != Position_XYZ do d.pos.controller = Position_XYZ()
		if classOf d.rotation.controller != Euler_XYZ do d.rotation.controller = Euler_XYZ()
		if classOf d.scale.controller != Bezier_Scale do d.scale.controller = Bezier_Scale()
		d.rotation.controller.axisOrder = 1
		d
	),

	-- Local position / rotation / scale (relative to the parent node).
	fn setLocalPRS nd prs U = (
		local p = prs["location"]
		local r = prs["rotation"]
		local s = prs["scale"]
		local pc = nd.pos.controller
		pc.X_Position.controller.value = p[1] * U
		pc.Y_Position.controller.value = p[2] * U
		pc.Z_Position.controller.value = p[3] * U
		local rc = nd.rotation.controller
		rc.X_Rotation.controller.value = r2d r[1]
		rc.Y_Rotation.controller.value = r2d r[2]
		rc.Z_Rotation.controller.value = r2d r[3]
		nd.scale.controller.value = [s[1], s[2], s[3]]
	),

	-- ── Exact bones (2.4) ───────────────────────────────────────────────
	-- A 3ds Max bone with the Blender bone's own axes (Y along the bone). 3ds Max
	-- builds bone geometry along X, so the object offset turns it onto Y. The bone
	-- behaviour (auto-align, stretch) is off, so the node moves exactly as its
	-- controllers say. Not renderable, like any rig bone.
	fn makeExactBone nm len = (
		local b = BoneSys.createBone [0, 0, 0] [len, 0, 0] [0, 0, 1]
		b.name = nm
		local w = amax (len * 0.1) 0.01
		try (b.width = w) catch ()
		try (b.height = w) catch ()
		try (b.taper = 90) catch ()
		try (b.sidefins = false) catch ()
		try (b.frontfin = false) catch ()
		try (b.backfin = false) catch ()
		try (b.setBoneEnable false 0f) catch ()
		local q = (matrix3 [0, 1, 0] [-1, 0, 0] [0, 0, 1] [0, 0, 0]) as quat
		b.objectOffsetRot = q
		-- the geometry's X axis must lie on the node's +Y
		local ot = b.objectTransform * (inverse b.transform)
		if (dot ot.row1 y_axis) < 0.5 do b.objectOffsetRot = inverse q
		b.renderable = false
		b.pos.controller = Position_XYZ()
		b.rotation.controller = Euler_XYZ()
		b.scale.controller = Bezier_Scale()
		b.rotation.controller.axisOrder = 1
		b
	),

	-- Freeze Transform layers, as 3ds Max's own Freeze Transform builds them: the
	-- plain controllers, which hold the rest pose, become "Frozen Position" and
	-- "Frozen Rotation"; the active "Zero Pos XYZ" and "Zero Euler XYZ" (Blender's
	-- rotation order) take the pose and the keys. Rotation lists apply the zero
	-- layer in the frozen (local) frame, position lists add up in the parent's frame.
	fn freezeExactBone nd order = (
		nd.rotation.controller = Rotation_List()
		local rl = nd.rotation.controller
		rl.available.controller = Euler_XYZ()
		rl.setName 1 "Frozen Rotation"
		rl.setName 2 "Zero Euler XYZ"
		rl.setActive 2
		(rl[2].object).axisOrder = blenderOrderToMax order
		nd.pos.controller = Position_List()
		local pl = nd.pos.controller
		pl.available.controller = Position_XYZ()
		pl.setName 1 "Frozen Position"
		pl.setName 2 "Zero Pos XYZ"
		pl.setActive 2
	),

	fn zeroPos nd = ((nd.pos.controller[2]).object),
	fn zeroRot nd = ((nd.rotation.controller[2]).object),

	-- Zero layers at the pose frame: Blender's pose bone channels. Scale is not
	-- frozen: it is Blender's scale (times an armature scale for root bones).
	fn setZeroPRS nd prs U = (
		local p = prs["location"]
		local r = prs["rotation"]
		local s = prs["scale"]
		local pc = zeroPos nd
		pc.X_Position.controller.value = p[1] * U
		pc.Y_Position.controller.value = p[2] * U
		pc.Z_Position.controller.value = p[3] * U
		local rc = zeroRot nd
		rc.X_Rotation.controller.value = r2d r[1]
		rc.Y_Rotation.controller.value = r2d r[2]
		rc.Z_Rotation.controller.value = r2d r[3]
		nd.scale.controller.value = [s[1], s[2], s[3]]
	),

	-- Dummies (or exact bones) in the bind pose. Returns #(dummies Dictionary, world rotation Dictionary).
	fn createBoneDummies root lookup U = (
		local dummies = Dictionary #string
		local boneW = Dictionary #string
		local arms = root["armatures"]
		if arms != undefined do (
			-- every node first: a parent may belong to another armature
			for an in arms.keys do (
				local a = arms[an]
				if (dget a "node" false) == true do (
					local maxLen = 0.0
					for b in a["bones"] do maxLen = amax maxLen (dget b "length" 0.0)
					local ad = makeDummy an (amax (maxLen * U * 0.2) 1.0)
					setLocalPRS ad a["world"] U
					dummies[an] = ad
				)
				local exact = (dget a "mode" "") == "exact"
				for b in a["bones"] do (
					local bn = b["name"]
					dummies[bn] = if exact then (makeExactBone bn (amax ((dget b "length" 0.0) * U) 0.01)) \
						else (makeDummy bn (amax ((dget b "length" 0.0) * U * 0.1) 0.5))
				)
			)
			-- hierarchy and bind pose (exact bones: the rest pose becomes the frozen layer)
			for an in arms.keys do (
				local exact = (dget arms[an] "mode" "") == "exact"
				for b in arms[an]["bones"] do (
					local d = dummies[b["name"]]
					local pn = dget b "parent" ""
					local pNode = if pn != "" then dummies[pn] else undefined
					if pNode == undefined and pn != "" do pNode = findNode pn lookup
					if pNode != undefined do d.parent = pNode
					setLocalPRS d b["rest"] U
					if exact then (
						freezeExactBone d (dget b "zero_order" "XYZ")
						if (dget b "hide" false) == true do d.isHidden = true
						-- a bone linked to an object (Child Of in Blender) whose object has moved
						-- since: posed at its Skin bind for now (animateDummies sets the pose)
						local bz = dget b "bind_zero" undefined
						if bz != undefined do setZeroPRS d bz U
					) else (
						-- the Blender bone's axes in the dummy's axes, for the 3ds Max -> Blender bridge
						local ba = dget b "bone_axes" ""
						if ba != "" do setUserProp d "BlenderBoneAxes" ba
					)
					local wr = b["world_rotation"]
					boneW[b["name"]] = buildWorldRot (r2d wr[1]) (r2d wr[2]) (r2d wr[3]) "XYZ"
				)
			)
		)
		#(dummies, boneW)
	),

	-- Skin modifiers bound to the dummies in their bind pose.
	-- skinOps needs the Skin modifier shown in the Modify panel.
	fn applySkins root dummies lookup U = (
		local skins = root["skins"]
		local made = 0
		if skins != undefined and skins.count > 0 do (
			try (cui.commandPanelOpen = true) catch ()
			max modify mode
			for mn in skins.keys do (
				local srec = skins[mn]
				local nd = findNode mn lookup
				local bnodes = #()
				local missingB = 0
				for bn in srec["bones"] do (
					local d = dummies[bn]
					if d == undefined then missingB += 1 else append bnodes d
				)
				if nd == undefined then warn ("Skin: mesh '" + mn + "' not found.")
				else if missingB > 0 then warn ("Skin: dummies missing for '" + mn + "', skin skipped.")
				else (
					local weights = srec["weights"]
					local needStatic = false
					for w in weights where w.count == 0 do needStatic = true
					local staticId = 0
					if needStatic do (
						-- Blender leaves unweighted vertices in place: they follow the mesh.
						local sd = makeDummy (mn + "__SkinStatic") (amax (U * 0.05) 0.5)
						sd.parent = nd
						sd.transform = nd.transform
						try (nd.layer.addNode sd) catch ()
						append bnodes sd
						staticId = bnodes.count
						dummies[sd.name] = sd
					)
					local sk = Skin()
					addModifier nd sk
					select nd
					modPanel.setCurrentObject sk
					for i = 1 to bnodes.count do skinOps.addBone sk bnodes[i] (if i == bnodes.count then 1 else 0)
					classOf nd
					local nv = skinOps.GetNumberVertices sk
					if nv == 0 do (
						modPanel.setCurrentObject sk
						classOf nd
						nv = skinOps.GetNumberVertices sk
					)
					if nv != weights.count do
						warn (mn + ": Skin has " + (nv as string) + " vertices, Blender " + (weights.count as string) + ".")
					-- Skin bone ids, matched by name (normally the order of addBone)
					local ids = #()
					local nb = skinOps.GetNumberBones sk
					for i = 1 to bnodes.count do (
						local found = 0
						for j = 1 to nb while found == 0 do (
							if (skinOps.GetBoneName sk j 0) == bnodes[i].name do found = j
						)
						ids[i] = if found > 0 then found else i
					)
					local n = amin nv weights.count
					for vi = 1 to n do (
						local w = weights[vi]
						if w.count == 0 then skinOps.ReplaceVertexWeights sk vi ids[staticId] 1.0
						else (
							local bIds = #()
							local bWs = #()
							local k = 1
							while k < w.count do (
								append bIds ids[(w[k] as integer) + 1]
								append bWs w[k + 1]
								k += 2
							)
							skinOps.ReplaceVertexWeights sk vi bIds bWs
						)
					)
					-- Blender's Preserve Volume is dual quaternion skinning (2.4: set either way)
					try (sk.enableDQ = ((dget srec "dq" false) == true)) catch ()
					made += 1
				)
			)
			max create mode
		)
		made
	),

	fn keyFloatTrack ctrl keys mult = (
		for kf in keys do (
			local k = addNewKey ctrl (frameTime kf["frame"])
			k.value = kf["value"] * mult
			setKeyTangents k kf
		)
	),

	-- Keys on a Position_XYZ (pc), an Euler_XYZ (rc) and a Bezier_Scale (sc):
	-- a dummy's own controllers, or an exact bone's zero layers and its scale.
	-- Returns true if any key was made.
	fn keyTracks pc rc sc anim U = (
		local made = false
		local la = dget anim "location" undefined
		if la != undefined do (
			local kX = dget la "X" #()
			local kY = dget la "Y" #()
			local kZ = dget la "Z" #()
			if kX.count > 0 do keyFloatTrack pc.X_Position.controller kX U
			if kY.count > 0 do keyFloatTrack pc.Y_Position.controller kY U
			if kZ.count > 0 do keyFloatTrack pc.Z_Position.controller kZ U
			if (kX.count + kY.count + kZ.count) > 0 do made = true
		)
		local ra = dget anim "rotation" undefined
		if ra != undefined do (
			local mult = 180.0 / pi
			local kX = dget ra "X" #()
			local kY = dget ra "Y" #()
			local kZ = dget ra "Z" #()
			if kX.count > 0 do keyFloatTrack rc.X_Rotation.controller kX mult
			if kY.count > 0 do keyFloatTrack rc.Y_Rotation.controller kY mult
			if kZ.count > 0 do keyFloatTrack rc.Z_Rotation.controller kZ mult
			if (kX.count + kY.count + kZ.count) > 0 do made = true
		)
		-- Bezier_Scale keeps X/Y/Z in one key: all keys are created first,
		-- then filled at their own time (no extra frame-0 key).
		local sa = dget anim "scale" undefined
		if sa != undefined do (
			local kX = dget sa "X" #()
			local kY = dget sa "Y" #()
			local kZ = dget sa "Z" #()
			if (kX.count + kY.count + kZ.count) > 0 do (
				local allSet = Dictionary #integer
				local allFrames = #()
				addFrames kX allSet allFrames
				addFrames kY allSet allFrames
				addFrames kZ allSet allFrames
				local hints = Dictionary #integer
				for arr in #(kX, kY, kZ) do (
					for kf in arr do (
						local hk = frameKey kf["frame"]
						if not (hasDictValue hints hk) do hints[hk] = kf
					)
				)
				local xM = keyMap kX
				local yM = keyMap kY
				local zM = keyMap kZ
				local cur = sc.value
				for f in allFrames do addNewKey sc (frameTime f)
				with animate on (
					for f in allFrames do (
						local k = frameKey f
						local sv = [mapGet xM k cur.x, mapGet yM k cur.y, mapGet zM k cur.z]
						at time (frameTime f) (sc.value = sv)
					)
				)
				for f in allFrames do (
					local idx = getKeyIndex sc (frameTime f)
					if idx > 0 do setKeyTangents (getKey sc idx) hints[frameKey f]
				)
				made = true
			)
		)
		made
	),

	fn keyDummy d anim U = keyTracks d.pos.controller d.rotation.controller d.scale.controller anim U,

	-- After the Skin bind: pose values (unkeyed channels), then keys. Exact bones
	-- take them on their zero layers. Returns the number of animated dummies / bones.
	fn animateDummies root dummies U = (
		local arms = root["armatures"]
		local animated = 0
		if arms != undefined do (
			for an in arms.keys do (
				local exact = (dget arms[an] "mode" "") == "exact"
				for b in arms[an]["bones"] do (
					local d = dummies[b["name"]]
					if d != undefined do (
						if exact then (
							setZeroPRS d b["zero_pose"] U
							local zanim = dget b "zero_animation" undefined
							if zanim != undefined and (keyTracks (zeroPos d) (zeroRot d) d.scale.controller zanim U) do animated += 1
						) else (
							setLocalPRS d b["pose"] U
							local anim = dget b "animation" undefined
							if anim != undefined and (keyDummy d anim U) do animated += 1
						)
					)
				)
			)
		)
		animated
	),

	-- Bone dummies go to the layer of their armature's collection.
	fn layerDummies root dummies = (
		local cols = root["collections"]
		local objCols = if cols != undefined then cols["objects"] else undefined
		local arms = root["armatures"]
		if objCols != undefined and arms != undefined do (
			for an in arms.keys do (
				local ln = objCols[an]
				if ln != undefined do (
					local lyr = getOrCreateLayer ln
					if dummies[an] != undefined do lyr.addNode dummies[an]
					for b in arms[an]["bones"] do (
						local d = dummies[b["name"]]
						if d != undefined do lyr.addNode d
					)
				)
			)
		)
	),

	-- ── Apply JSON (passes and math as v1.1.1) ──────────────────────────
	-- U: Blender units -> system units (resolveUnitFactor).
	-- boneW: world rotations of the bone dummies (parents of objects).
	-- Returns #(appliedCount, animatedCount, timingText)
	fn applyData root lookup U boneW = (
		local objs = root["objects"]
		local sorted = topoSort objs

		local found = findObjectNodes objs sorted lookup
		local nodes = found[1]
		local missing = found[2]
		if missing.count > 0 do (
			local shown = ""
			for i = 1 to (amin missing.count 5) do shown += (if i > 1 then ", " else "") + missing[i]
			warn ((missing.count as string) + " object(s) not found in the scene: " + shown)
		)

		local bfps = dget root "fps" undefined
		if bfps != undefined and (abs (bfps - frameRate)) > 0.01 do
			warn ("Blender fps " + (bfps as string) + " differs from 3ds Max fps " + (frameRate as string) + "; keys keep their frame numbers.")

		-- Extend (never shrink) the time line to Blender's frame range.
		local fs = dget root "frame_start" undefined
		local fe = dget root "frame_end" undefined
		if fs != undefined and fe != undefined and fe > fs do (
			local r0 = amin (animationRange.start.frame as float) fs
			local r1 = amax (animationRange.end.frame as float) fe
			if r0 < animationRange.start.frame or r1 > animationRange.end.frame do
				animationRange = interval (frameTime r0) (frameTime r1)
		)

		-- World rotation of every node in the pose the scene is linked in (bone
		-- dummies: bind pose). Without "parent_space" Blender's channel values are
		-- the world rotation; with it W = R(channels) * rot(M) * W(parent).
		local worldMats = Dictionary #string
		for bn in boneW.keys do worldMats[bn] = boneW[bn]
		local spaces = Dictionary #string
		for nm in sorted do (
			local rec = objs[nm]
			local re = dget rec "rotation_euler" #(0.0, 0.0, 0.0)
			local wRot = buildWorldRot (r2d re[1]) (r2d re[2]) (r2d re[3]) (dget rec "rotation_mode" "XYZ")
			local spaceRec = dget rec "parent_space" undefined
			if spaceRec != undefined do (
				local kSpace = parentSpaceMatrix spaceRec U
				spaces[nm] = kSpace
				wRot = wRot * (rotationPart kSpace) * (getParentW worldMats rec)
			)
			worldMats[nm] = wRot
		)
		if spaces.count > 0 do logLine ((spaces.count as string) + " object(s) with a parent space (parented in another pose of the parent).")

		local animated = 0
		local tA = timeStamp()

		-- Pass 1a: rotation ORDER
		for nm in sorted do (
			local nd = nodes[nm]
			if nd != undefined do (
				local rc = nd.rotation.controller
				if classOf rc != Euler_XYZ do (
					nd.rotation.controller = Euler_XYZ()
					rc = nd.rotation.controller
				)
				rc.axisOrder = blenderOrderToMax (dget objs[nm] "rotation_mode" "XYZ")
			)
		)

		-- Pass 1b: rotation VALUES. The node is not linked yet (local == world)
		-- and its Euler controller has Blender's rotation order, so Blender's
		-- own channel values are exactly its world rotation W. (2.1 decomposed
		-- W instead; at +-90 deg on the middle axis that turned the node the
		-- wrong way, and Pass 1d then linked its children to the wrong pose.)
		-- With "parent_space" the world rotation is W from above, written as the
		-- Euler triple nearest to Blender's values.
		for nm in sorted do (
			local nd = nodes[nm]
			if nd != undefined do (
				local re = dget objs[nm] "rotation_euler" #(0.0, 0.0, 0.0)
				local rc = nd.rotation.controller
				local ev = [(r2d re[1]), (r2d re[2]), (r2d re[3])]
				if hasDictValue spaces nm do ev = nearestEuler worldMats[nm] (dget objs[nm] "rotation_mode" "XYZ") ev
				rc.X_Rotation.controller.value = ev.x
				rc.Y_Rotation.controller.value = ev.y
				rc.Z_Rotation.controller.value = ev.z
			)
		)

		-- Pass 1c: scale
		for nm in sorted do (
			local nd = nodes[nm]
			local js = if nd != undefined then objs[nm]["scale"] else undefined
			if js != undefined do nd.scale = [js[1], js[2], js[3]]
		)

		-- Pass 1d: parent objects (3ds Max keeps world transforms)
		for nm in sorted do (
			local nd = nodes[nm]
			local pn = if nd != undefined then (dget objs[nm] "parent" "") else ""
			if pn != "" do (
				local pNode = nodes[pn]
				if pNode == undefined do pNode = getNodeByName pn exact:true
				if pNode != undefined do nd.parent = pNode
			)
		)
		local tB = timeStamp()

		-- Pass 2: rotation & scale animation keys
		for nm in sorted do (
			local nd = nodes[nm]
			local rec = objs[nm]
			local anim = if nd != undefined then rec["animation"] else undefined
			if anim != undefined do (
				local modeStr = dget rec "rotation_mode" "XYZ"
				-- local rotation = R(channels) * iPW
				local iPW = if hasDictValue spaces nm then (rotationPart spaces[nm]) else (inverse (getParentW worldMats rec))
				local hasKeys = false

				-- Rotation keys: L from all three axes, a key only where Blender had one.
				-- Keys go in frame order and follow Blender's own channel motion (see
				-- continuousEuler), starting from the static values 3ds Max holds after
				-- linking; axes Blender did not key keep those static values.
				local ra = anim["rotation_euler"]
				if ra != undefined do (
					local kX = dget ra "X" #()
					local kY = dget ra "Y" #()
					local kZ = dget ra "Z" #()
					if (kX.count + kY.count + kZ.count) > 0 do (
						hasKeys = true
						local fsX = frameSetOf kX
						local fsY = frameSetOf kY
						local fsZ = frameSetOf kZ
						local allSet = Dictionary #integer
						local allFrames = #()
						addFrames kX allSet allFrames
						addFrames kY allSet allFrames
						addFrames kZ allSet allFrames
						sort allFrames
						local xM = keyMap kX
						local yM = keyMap kY
						local zM = keyMap kZ
						local jre = dget rec "rotation_euler" #(0.0, 0.0, 0.0)
						local rc = nd.rotation.controller
						local rawPrev = [(r2d jre[1]), (r2d jre[2]), (r2d jre[3])]
						local L0 = (buildWorldRot rawPrev.x rawPrev.y rawPrev.z modeStr) * iPW
						local statRot = [rc.X_Rotation.controller.value, rc.Y_Rotation.controller.value, rc.Z_Rotation.controller.value]
						if not (sameRotation (buildWorldRot statRot.x statRot.y statRot.z modeStr) L0 1e-4) do (
							local d0 = decomposeEuler L0 modeStr
							statRot = [d0[1], d0[2], d0[3]]
						)
						local prev = copy statRot
						local someUnkeyed = kX.count == 0 or kY.count == 0 or kZ.count == 0
						local inexact = false
						for f in allFrames do (
							local k = frameKey f
							local raw = [(r2d (mapGet xM k jre[1])), (r2d (mapGet yM k jre[2])), (r2d (mapGet zM k jre[3]))]
							local L = (buildWorldRot raw.x raw.y raw.z modeStr) * iPW
							local le = continuousEuler rawPrev raw modeStr iPW prev
							prev = le
							rawPrev = raw
							local tt = frameTime f
							if hasDictValue fsX k do (
								local kiX = addNewKey rc.X_Rotation.controller tt
								kiX.value = le.x
							)
							if hasDictValue fsY k do (
								local kiY = addNewKey rc.Y_Rotation.controller tt
								kiY.value = le.y
							)
							if hasDictValue fsZ k do (
								local kiZ = addNewKey rc.Z_Rotation.controller tt
								kiZ.value = le.z
							)
							-- An axis without any Blender key keeps its static value.
							if someUnkeyed do (
								local gx = if kX.count == 0 then statRot.x else le.x
								local gy = if kY.count == 0 then statRot.y else le.y
								local gz = if kZ.count == 0 then statRot.z else le.z
								if not (sameRotation (buildWorldRot gx gy gz modeStr) L 1e-3) do inexact = true
							)
						)
						if inexact do warn (nm + ": rotation is keyed on only some axes in Blender, but under its 3ds Max parent the other axes have to turn as well, so some poses cannot match. Key X, Y and Z rotation in Blender for an exact match.")
					)
				)

				-- Scale keys: Bezier_Scale keeps X/Y/Z in one key. All keys are
				-- created first, then their values are set at their own time, so no
				-- extra frame-0 key can appear. Same rule as location keys: Blender
				-- values are relative to the parent's pose at frame 0.
				local sa = anim["scale"]
				if sa != undefined do (
					local kX = dget sa "X" #()
					local kY = dget sa "Y" #()
					local kZ = dget sa "Z" #()
					if (kX.count + kY.count + kZ.count) > 0 do (
						hasKeys = true
						local allSet = Dictionary #integer
						local allFrames = #()
						addFrames kX allSet allFrames
						addFrames kY allSet allFrames
						addFrames kZ allSet allFrames
						local xM = keyMap kX
						local yM = keyMap kY
						local zM = keyMap kZ
						local js = dget rec "scale" #(1.0, 1.0, 1.0)
						local pS = if nd.parent != undefined then nd.parent.transform.scale else [1.0, 1.0, 1.0]
						if (abs pS.x) < 1e-6 do pS.x = 1.0
						if (abs pS.y) < 1e-6 do pS.y = 1.0
						if (abs pS.z) < 1e-6 do pS.z = 1.0
						if classOf nd.scale.controller != Bezier_Scale do nd.scale.controller = Bezier_Scale()
						local sc = nd.scale.controller
						for f in allFrames do addNewKey sc (frameTime f)
						with animate on (
							for f in allFrames do (
								local k = frameKey f
								local sv = [(mapGet xM k js[1]) / pS.x, (mapGet yM k js[2]) / pS.y, (mapGet zM k js[3]) / pS.z]
								at time (frameTime f) (sc.value = sv)
							)
						)
					)
				)
				if hasKeys do animated += 1
			)
		)
		local tC = timeStamp()

		-- Pass 3: location animation keys (after all rotations are keyed)
		for nm in sorted do (
			local nd = nodes[nm]
			local rec = objs[nm]
			local anim = if nd != undefined then rec["animation"] else undefined
			local la = if anim != undefined then anim["location"] else undefined
			if la != undefined do (
				local kX = dget la "X" #()
				local kY = dget la "Y" #()
				local kZ = dget la "Z" #()
				if (kX.count + kY.count + kZ.count) > 0 do (
					if (dget anim "rotation_euler" undefined) == undefined do animated += 1
					local fsX = frameSetOf kX
					local fsY = frameSetOf kY
					local fsZ = frameSetOf kZ
					local allSet = Dictionary #integer
					local allFrames = #()
					addFrames kX allSet allFrames
					addFrames kY allSet allFrames
					addFrames kZ allSet allFrames
					local xM = keyMap kX
					local yM = keyMap kY
					local zM = keyMap kZ
					local jl = dget rec "location" #(0.0, 0.0, 0.0)

					-- Position_XYZ: each axis has its own Bezier sub-controller.
					local savedWorldPos = copy nd.pos
					nd.pos.controller = Position_XYZ()
					nd.transform.pos = savedWorldPos

					local pc = nd.pos.controller
					local parentTMInv = if nd.parent != undefined then (inverse nd.parent.transform) else undefined
					-- with "parent_space": local position = (location * U) * M
					local kSpace = if hasDictValue spaces nm then spaces[nm] else undefined

					for f in allFrames do (
						local k = frameKey f
						local wPos = [(mapGet xM k jl[1]) * U, (mapGet yM k jl[2]) * U, (mapGet zM k jl[3]) * U]
						local lPos = if kSpace != undefined then (wPos * kSpace) else (if parentTMInv != undefined then (wPos * parentTMInv) else wPos)
						local tt = frameTime f
						if hasDictValue fsX k do (
							local kiX = addNewKey pc.X_Position.controller tt
							kiX.value = lPos.x
						)
						if hasDictValue fsY k do (
							local kiY = addNewKey pc.Y_Position.controller tt
							kiY.value = lPos.y
						)
						if hasDictValue fsZ k do (
							local kiZ = addNewKey pc.Z_Position.controller tt
							kiZ.value = lPos.z
						)
					)
				)
			)
		)
		local tD = timeStamp()

		-- Pass 4: layers from Blender collections
		local cols = root["collections"]
		if cols != undefined do (
			local layerDict = Dictionary #string
			local lyrs = cols["layers"]
			if lyrs != undefined do (
				for ln in lyrs.keys do layerDict[ln] = getOrCreateLayer ln
				for ln in lyrs.keys do (
					local pln = lyrs[ln]
					if pln != undefined and pln != "" do (
						local childLyr = layerDict[ln]
						local parentLyr = layerDict[pln]
						if childLyr != undefined and parentLyr != undefined do childLyr.setParent parentLyr
					)
				)
			)
			local objCols = cols["objects"]
			if objCols != undefined do (
				for onm in objCols.keys do (
					local nd = nodes[onm]
					if nd != undefined do (
						local ln = objCols[onm]
						local lyr = layerDict[ln]
						if lyr == undefined do lyr = getOrCreateLayer ln
						lyr.addNode nd
					)
				)
			)
		)
		local tE = timeStamp()

		local timing = "transforms " + (((tB - tA) / 1000.0) as string) + " s, rotation/scale keys " + \
			(((tC - tB) / 1000.0) as string) + " s, location keys " + (((tD - tC) / 1000.0) as string) + \
			" s, layers " + (((tE - tD) / 1000.0) as string) + " s"
		#(nodes.count, animated, timing)
	),

	-- ── FBX import ──────────────────────────────────────────────────────
	-- Returns #(success, newNodes)
	fn importFBX fbxPath = (
		try (pluginManager.loadClass FbxImporter) catch ()
		local beforeSet = Dictionary #integer
		for o in objects do beforeSet[o.inode.handle] = true
		local pushed = true
		try (FBXImporterSetParam "PushSettings") catch (pushed = false)
		try (FBXImporterSetParam "Mode" #create) catch ()
		try (FBXImporterSetParam "Animation" false) catch ()
		try (FBXImporterSetParam "UpAxis" "Z") catch ()
		local imp = try (FBXIMP) catch (undefined)
		local success = false
		try (
			success = if imp != undefined then (importFile fbxPath #noPrompt using:imp) else (importFile fbxPath #noPrompt)
		) catch (
			warn ("FBX import error: " + (getCurrentException()))
			success = false
		)
		if pushed do (try (FBXImporterSetParam "PopSettings") catch ())
		local newNodes = for o in objects where not (hasDictValue beforeSet o.inode.handle) collect o
		#((success == true), newNodes)
	),

	-- FBX import with the scene in centimeters for that moment: the FBX importer
	-- then converts nothing (its unit conversion would go into the node scales).
	fn importFBXInCentimeters fbxPath = (
		if isCentimeters() then (importFBX fbxPath) else (
			local sType = units.SystemType
			local sScale = units.SystemScale
			local r = #(false, #())
			try (
				units.SystemType = #centimeters
				units.SystemScale = 1.0
				r = importFBX fbxPath
			) catch (
				warn ("FBX import error: " + (getCurrentException()))
			)
			units.SystemType = sType
			units.SystemScale = sScale
			r
		)
	),

	-- Objects an interrupted import left renamed "<name>__BlenderBridgeOld" get their
	-- names back (when the name is free), so Replace finds them again.
	fn restoreLeftoverNames = (
		local suffix = "__BlenderBridgeOld"
		local left = for o in objects where (matchPattern o.name pattern:("*" + suffix)) collect o
		local n = 0
		local taken = 0
		for o in left do (
			local base = substring o.name 1 (o.name.count - suffix.count)
			if base != "" and (getNodeByName base exact:true) == undefined then (
				o.name = base
				n += 1
			) else taken += 1
		)
		if n > 0 do logLine ("Restored the names of " + (n as string) + " objects that an interrupted import had renamed")
		if taken > 0 do warn ((taken as string) + " object(s) are still named ..." + suffix + " (their names are taken); delete or rename them")
	),

	-- ── One import: JSON (+ FBX) ────────────────────────────────────────
	-- fbxPath: full path, "" = apply to objects already in the scene,
	-- "<auto>" = the FBX named in the JSON, next to it.
	-- Returns #(ok, message, objectCount)
	fn runImport jsonPath fbxPath doReplace = (
		local t0 = timeStamp()
		local root = undefined
		local msg = ""
		try (root = parseJSON (readText jsonPath)) catch (msg = "Cannot read JSON: " + (getCurrentException()))
		local objs = if root != undefined and (classOf root) == Dictionary then root["objects"] else undefined
		if objs == undefined or (classOf objs) != Dictionary then (
			if msg == "" do msg = "Not a Blender bridge JSON (no 'objects'): " + jsonPath
			#(false, msg, 0)
		) else (
			local t1 = timeStamp()
			local jv = dget root "version" 3
			if (classOf jv) != String and jv > 5 do
				warn ("The JSON is format version " + (jv as string) + " from a newer Blender add-on; update BlenderMaxBridge.ms.")
			if fbxPath == "<auto>" do (
				local nm = dget root "fbx" ""
				local cand = if nm != "" then (pathConfig.appendPath (getFilenamePath jsonPath) nm) else ""
				fbxPath = if cand != "" and (fileExists cand) then cand else ""
				if fbxPath == "" do (
					if nm == "" then warn "The JSON names no FBX; applying to objects already in the scene."
					else warn ("FBX not found next to the JSON (" + nm + "); applying to objects already in the scene.")
				)
			)
			sliderTime = 0f
			-- scene units (2.5): centimeters, or what the user chose for this scene
			local cancelMsg = ""
			local uDec = if fbxPath != "" then (unitsDecision()) else #keep
			if uDec == #cancel do cancelMsg = "Not imported: the scene units question was cancelled."
			if uDec == #switch do switchToCentimeters()
			local deleted = 0
			local lookup = undefined
			local newNodes = #()
			local fbxOk = true
			-- Bone dummies (and their Skin helpers) of a previous send are replaced too.
			local arms = dget root "armatures" undefined
			local rigNames = Dictionary #string
			if arms != undefined do (
				for an in arms.keys do (
					rigNames[an] = true
					for b in arms[an]["bones"] do rigNames[b["name"]] = true
				)
			)
			local skinRecs = dget root "skins" undefined
			if skinRecs != undefined do (
				for mn in skinRecs.keys do rigNames[mn + "__SkinStatic"] = true
			)
			if fbxPath != "" and cancelMsg == "" then (
				-- Replace: same-named objects are renamed out of the way, then
				-- deleted only if the FBX import succeeded (names restored if not).
				local oldNodes = #()
				local oldNames = #()
				restoreLeftoverNames()
				if doReplace do (
					oldNodes = for o in objects where (hasDictValue objs o.name) or (hasDictValue rigNames o.name) collect o
					for o in oldNodes do (
						append oldNames o.name
						o.name = o.name + "__BlenderBridgeOld"
					)
				)
				-- any error here still gives the renamed objects their names back
				local r = #(false, #())
				try (r = importFBXInCentimeters fbxPath) catch (warn ("FBX import error: " + (getCurrentException())))
				fbxOk = r[1]
				newNodes = r[2]
				if fbxOk then (
					-- not in centimeters: the new objects (centimeter numbers) to the scene units
					try (rescaleImported newNodes (cmToSystem())) catch (warn ("Rescaling to the scene units failed: " + (getCurrentException())))
					local doomed = for o in oldNodes where (isValidNode o) collect o
					deleted = doomed.count
					if doomed.count > 0 do delete doomed
				) else (
					for i = 1 to oldNodes.count where (isValidNode oldNodes[i]) do oldNodes[i].name = oldNames[i]
				)
				lookup = buildLookup newNodes
			) else (
				lookup = buildLookup (objects as array)
			)
			local t2 = timeStamp()
			if cancelMsg != "" then (
				#(false, cancelMsg, 0)
			) else if not fbxOk then (
				#(false, "FBX import failed: " + fbxPath, 0)
			) else (
				local res = undefined
				local applyErr = ""
				local doRigs = fbxPath != "" and arms != undefined
				if arms != undefined and not doRigs do
					warn "Bones -> dummies + Skin are built only together with the FBX import; skipped."
				local dummies = Dictionary #string
				local boneW = Dictionary #string
				local nSkins = 0
				local nRigAnim = 0
				sliderTime = 0f
				-- Nothing selected and Create panel: no command panel refresh per change.
				clearSelection()
				try (setCommandPanelTaskMode #create) catch ()
				local U = resolveUnitFactor root lookup (fbxPath != "")
				if fbxPath != "" do checkMeshSizes root lookup U
				disableSceneRedraw()
				try (
					with undo off (
						with animate off (
							if doRigs do (
								local rig = createBoneDummies root lookup U
								dummies = rig[1]
								boneW = rig[2]
							)
							res = applyData root lookup U boneW
						)
					)
				) catch (
					applyErr = getCurrentException()
				)
				enableSceneRedraw()
				local t3 = timeStamp()
				-- Skin (bind pose = dummies as created), then the dummy animation.
				if applyErr == "" and doRigs do (
					try (
						with undo off (
							with animate off (
								nSkins = applySkins root dummies lookup U
							)
						)
						clearSelection()
						disableSceneRedraw()
						with undo off (
							with animate off (
								nRigAnim = animateDummies root dummies U
								layerDummies root dummies
							)
						)
						enableSceneRedraw()
					) catch (
						enableSceneRedraw()
						applyErr = "bones/skin: " + (getCurrentException())
					)
				)
				try (setCommandPanelTaskMode #create) catch ()
				clearSelection()
				local sel = for o in newNodes where (isValidNode o) collect o
				for k in dummies.keys where (isValidNode dummies[k]) do append sel dummies[k]
				if sel.count > 0 do select sel
				redrawViews()
				local t4 = timeStamp()
				if applyErr != "" then (
					logLine ("Apply error: " + applyErr)
					#(false, "Error while applying the JSON: " + applyErr, 0)
				) else (
					local secs = (t4 - t0) / 1000.0
					msg = (res[1] as string) + " objects (" + ((res[2] + nRigAnim) as string) + " animated) in " + (secs as string) + " s"
					if dummies.count > 0 do (
						-- exact bones vs dummies (armature nodes and Skin helpers are dummies)
						local nExact = 0
						if arms != undefined do (
							for an in arms.keys where (dget arms[an] "mode" "") == "exact" do nExact += arms[an]["bones"].count
						)
						if nExact > 0 do msg += ", " + (nExact as string) + " bones"
						if dummies.count > nExact do msg += ", " + ((dummies.count - nExact) as string) + " dummies"
						msg += ", " + (nSkins as string) + " skinned"
					)
					if deleted > 0 do msg += ", replaced " + (deleted as string)
					logLine ("Done: " + msg)
					logLine ("  read+parse JSON " + (((t1 - t0) / 1000.0) as string) + " s, FBX " + \
						(((t2 - t1) / 1000.0) as string) + " s, apply " + (((t3 - t2) / 1000.0) as string) + \
						" s, bones/skin " + (((t4 - t3) / 1000.0) as string) + " s")
					logLine ("  apply: " + res[3])
					#(true, msg, res[1])
				)
			)
		)
	),

	-- ── Bridge jobs ─────────────────────────────────────────────────────
	fn writeResult jobId jobStatus msg secs objCount = (
		local w = ""
		for i = 1 to warnings.count do (
			if i > 1 do w += ","
			w += "\"" + (jsonEsc warnings[i]) + "\""
		)
		local txt = "{\"id\":\"" + (jsonEsc jobId) + "\",\"status\":\"" + jobStatus + "\",\"message\":\"" + \
			(jsonEsc msg) + "\",\"seconds\":" + (secs as string) + ",\"objects\":" + (objCount as string) + \
			",\"warnings\":[" + w + "]}"
		try (writeTextAtomic (pathConfig.appendPath bridgeDir "result.json") txt) catch (logLine "Cannot write result.json")
	),

	fn processJob jobPath = (
		local t0 = timeStamp()
		local age = try (fileAgeSeconds jobPath) catch (0.0)
		local job = undefined
		try (job = parseJSON (readText jobPath)) catch ()
		deleteFileRetry jobPath
		local isJob = job != undefined and (classOf job) == Dictionary
		local jobId = if isJob then (dget job "id" "") else ""
		if jobId != "" and jobId == lastJobId then (
			logLine "Job already processed, ignored."
		) else (
			lastJobId = jobId
			jobInProgress = jobId
			warnings = #()
			local jobStatus = "error"
			local msg = ""
			local objCount = 0
			if not isJob then (
				msg = "Unreadable job file."
			) else (
				local jsonPath = dget job "json" ""
				local fbxPath = dget job "fbx" ""
				if age > 900.0 then (
					msg = "Job expired (" + ((age as integer) as string) + " s old), ignored."
				) else if not (fileExists jsonPath) then (
					msg = "JSON not found: " + jsonPath
				) else if fbxPath != "" and not (fileExists fbxPath) then (
					msg = "FBX not found: " + fbxPath
				) else (
					logLine ("Job from Blender: " + jsonPath)
					local r = try (runImport jsonPath fbxPath (dget job "replace" true)) catch (#(false, "3ds Max error: " + (getCurrentException()), 0))
					jobStatus = if r[1] then "ok" else "error"
					msg = r[2]
					objCount = r[3]
				)
			)
			if jobStatus != "ok" do logLine ("Job failed: " + msg)
			lastLine1 = (if jobStatus == "ok" then "OK: " else "ERROR: ") + msg
			lastLine2 = if warnings.count > 0 then ((warnings.count as string) + " warning(s), see Listener") else ""
			writeResult jobId jobStatus msg ((timeStamp() - t0) / 1000.0) objCount
			jobInProgress = ""
		)
	),

	fn writeHeartbeat = (
		try (
			if ensureDir bridgeDir do (
				local txt = "{\"app\":\"3ds Max\",\"max_version\":" + ((maxVersion())[1] as string) + \
					",\"bridge\":\"" + bridgeVersion + "\",\"listening\":true,\"units\":\"" + (jsonEsc (unitsLabel())) + \
					"\",\"cm_per_unit\":" + ((cmPerSystemUnit()) as string) + "}"
				writeText (pathConfig.appendPath bridgeDir "listener.json") txt
			)
		) catch ()
	),

	fn updateUI = (
		if BlenderMaxBridgeRollout != undefined and BlenderMaxBridgeRollout.open do (
			try (BlenderMaxBridgeRollout.refreshState()) catch ()
		)
	),

	fn stopListening = (
		if BlenderMaxBridge_Timer != undefined do (
			try (BlenderMaxBridge_Timer.Stop()) catch ()
			try (dotNet.removeAllEventHandlers BlenderMaxBridge_Timer) catch ()
			try (BlenderMaxBridge_Timer.Dispose()) catch ()
			BlenderMaxBridge_Timer = undefined
		)
		if listening do (
			deleteFileSafe (pathConfig.appendPath bridgeDir "listener.json")
			logLine "Listener stopped."
		)
		listening = false
	),

	fn startListening = (
		stopListening()
		if not (ensureDir bridgeDir) then (
			logLine ("Cannot create the bridge folder: " + bridgeDir)
			false
		) else (
			BlenderMaxBridge_Timer = dotNetObject "System.Windows.Forms.Timer"
			BlenderMaxBridge_Timer.Interval = 500
			dotNet.addEventHandler BlenderMaxBridge_Timer "Tick" BlenderMaxBridge_onTick
			dotNet.setLifetimeControl BlenderMaxBridge_Timer #dotnet
			listening = true
			busy = false
			lastBeat = 0
			writeHeartbeat()
			BlenderMaxBridge_Timer.Start()
			logLine ("Listening for Blender in " + bridgeDir)
			true
		)
	),

	fn tick = (
		if listening and not busy do (
			local now = timeStamp()
			if (now - lastBeat) > 2000 or now < lastBeat do (
				lastBeat = now
				writeHeartbeat()
			)
			local jobPath = pathConfig.appendPath bridgeDir "job.json"
			if fileExists jobPath do (
				busy = true
				try (BlenderMaxBridge_Timer.Stop()) catch ()
				try (processJob jobPath) catch (
					local ex = getCurrentException()
					logLine ("Job crashed: " + ex)
					if jobInProgress != "" do (
						try (writeResult jobInProgress "error" ("3ds Max error: " + ex) 0.0 0) catch ()
						jobInProgress = ""
					)
				)
				busy = false
				lastBeat = 0
				if listening and BlenderMaxBridge_Timer != undefined do (try (BlenderMaxBridge_Timer.Start()) catch ())
				updateUI()
			)
		)
	),

	-- ── Start with 3ds Max ──────────────────────────────────────────────
	fn autoStartFile = (
		pathConfig.appendPath (getDir #userStartupScripts) "BlenderMaxBridge_AutoStart.ms"
	),
	fn autoStartEnabled = (
		fileExists (autoStartFile())
	),
	fn setAutoStart doEnable = (
		local f = autoStartFile()
		if doEnable then (
			if scriptFile == "" or not (fileExists scriptFile) then (
				messageBox "Run this script from a saved .ms file first (Scripting > Run Script)." title:"Blender <-> 3Ds Max Bridge"
				false
			) else (
				local txt = "-- Auto-generated by Blender <-> 3Ds Max Bridge Advanced " + bridgeVersion + "\n" + \
					"global BlenderMaxBridge_AutoStart = true\n" + \
					"try (fileIn @\"" + scriptFile + "\") catch (format \"Blender <-> 3Ds Max Bridge autostart failed: %\\n\" (getCurrentException()))\n"
				try (
					writeText f txt
					logLine ("Autostart enabled: " + f)
					true
				) catch (
					logLine ("Cannot write " + f)
					false
				)
			)
		) else (
			deleteFileSafe f
			logLine "Autostart disabled."
			true
		)
	),

	-- ── Entry points ────────────────────────────────────────────────────
	fn setup srcFile = (
		scriptFile = if srcFile != undefined then srcFile else ""
		loadSettings()
		-- After an update (new script file), point the autostart at this script.
		if scriptFile != "" and (autoStartEnabled()) do (
			local stub = try (readText (autoStartFile())) catch ("")
			if (findString stub scriptFile) == undefined do setAutoStart true
		)
	),

	fn setBridgeDir d = (
		local wasOn = listening
		if wasOn do stopListening()
		bridgeDir = d
		saveSettings()
		if wasOn do startListening()
	),

	fn manualImport jsonPath withFbx doReplace = (
		warnings = #()
		local r = runImport jsonPath (if withFbx then "<auto>" else "") (doReplace and withFbx)
		lastLine1 = (if r[1] then "OK: " else "ERROR: ") + r[2]
		lastLine2 = if warnings.count > 0 then ((warnings.count as string) + " warning(s), see Listener") else ""
		local txt = r[2]
		for w in warnings do txt += "\n- " + w
		messageBox txt title:"Blender <-> 3Ds Max Bridge"
		r[1]
	)
)

-- Timer callback. An unexpected error stops the listener instead of
-- repeating every 0.5 s.
fn BlenderMaxBridge_onTick sender evt = (
	try (
		if BlenderMaxBridge != undefined do BlenderMaxBridge.tick()
	) catch (
		format "[Blender->Max Bridge] Listener error, listener stopped: %\n" (getCurrentException())
		try (BlenderMaxBridge.busy = false) catch ()
		try (BlenderMaxBridge.stopListening()) catch ()
		try (BlenderMaxBridge.updateUI()) catch ()
	)
)



-- ============================================================
--  PART 2   3ds Max -> Blender  (send)
-- ============================================================

struct MaxToBlenderStruct (
	toolVersion = "3.0",
	formatVersion = 3,

	-- options (the dialog sets them)
	optSelectedOnly = false,
	optAnimation = true,
	optMaterials = true,
	optLiveMods = true,
	optCheckLive = true,
	optNormals = true,
	optSkin = true,
	optVerifyStep = 5,
	optMaxBakeFrames = 2000,
	optVerboseLog = false,
	uiFn = undefined,

	-- state of one export
	cancelled = false,
	binStream = undefined,
	binPath = "",
	meshItems = undefined,
	meshCount = 0,
	instSets = undefined,
	snapshotFlips = false,
	curIndex = 0,
	nodeTotal = 0,
	lastUiTick = 0,
	lastLogTick = 0,
	meshMs = 0,
	matQueue = undefined,
	matQueued = undefined,
	matItems = undefined,
	layerIdx = undefined,
	exportFrame = 0,
	nodeErrors = 0,
	warnCount = 0,
	statMeshes = 0,
	statShared = 0,
	statFaces = 0,
	statShapes = 0,
	statEmpties = 0,
	statKeyed = 0,
	statBaked = 0,
	statTracks = 0,
	statScaleAxis = 0,
	statLive = 0,
	statLiveMods = 0,
	statNormals = 0,
	statNormalsFail = 0,
	statNormalsExplicit = 0,
	normalsMs = 0,
	nrmReader = undefined,
	nrmReaderMsg = "",
	nrmInfoShown = 0,
	statSkins = 0,
	statSkinFail = 0,
	skinMs = 0,
	statEulerNamed = 0,
	statEulerByOrder = 0,
	panelUsed = false,
	prsQuatDirect = 0,
	prsQuatInverse = 0,
	lastResult = "",

	-- logging
	logWriter = undefined,
	logPath = "",
	logT0 = 0,
	curStage = "",

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

	-- 7 significant digits (settings) / 9 (float32 exact: matrices, keys)
	fn jNum v = (
		local fv = undefined
		if v != undefined do fv = try (v as float) catch undefined
		-- "," -> "." keeps the number valid JSON under a decimal-comma locale
		if fv == undefined or fv != fv or (abs fv) > 1e30 then "null" else (substituteString (formattedPrint fv format:".7g") "," ".")
	),

	fn jNumP v = (
		local fv = undefined
		if v != undefined do fv = try (v as float) catch undefined
		if fv == undefined or fv != fv or (abs fv) > 1e30 then "null" else (substituteString (formattedPrint fv format:".9g") "," ".")
	),

	fn jBool b = (if b == true then "true" else "false"),

	-- An integer as JSON. 3ds Max 2024 prints 64-bit integers as "8L" and
	-- pointer-sized ones as "8P"; JSON wants plain digits.
	fn jInt v = (
		local t = v as string
		local last = if t.count > 0 then t[t.count] else ""
		if last == "L" or last == "P" then substring t 1 (t.count - 1) else t
	),

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
	fn jKey s = (
		local t = jStr s
		if t == "null" then "?" else (substring t 2 (t.count - 2))
	),

	fn jP3 p = ("[" + (jNum p.x) + "," + (jNum p.y) + "," + (jNum p.z) + "]"),
	fn jP3p p = ("[" + (jNumP p.x) + "," + (jNumP p.y) + "," + (jNumP p.z) + "]"),
	fn jQuatP q = ("[" + (jNumP q.x) + "," + (jNumP q.y) + "," + (jNumP q.z) + "," + (jNumP q.w) + "]"),
	-- 4 rows of a matrix3 (row-vector convention: X, Y, Z axis, translation)
	fn jM3p m = ("[" + (jP3p m.row1) + "," + (jP3p m.row2) + "," + (jP3p m.row3) + "," + (jP3p m.row4) + "]"),
	fn jColor c = ("[" + (jNum c.r) + "," + (jNum c.g) + "," + (jNum c.b) + "]"),
	fn jColor01 c = ("[" + (jNum (c.r / 255.0)) + "," + (jNum (c.g / 255.0)) + "," + (jNum (c.b / 255.0)) + "]"),

	-- ── logging ──────────────────────────────────────────────────
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
			format "MaxToBlender: cannot write the log file %\n" logFile
		)
	),

	fn logLine msg toListener:false = (
		local secs = (timeStamp() - logT0) / 1000.0
		local txtLine = "[" + (substituteString (formattedPrint secs format:"9.3f") "," ".") + "] " + (msg as string)
		if logWriter != undefined do try (logWriter.WriteLine txtLine) catch ()
		if toListener do format "MaxToBlender %\n" txtLine
	),

	fn logError title ex st toListener:true = (
		logLine ("ERROR " + title + ": " + (substituteString (ex as string) "\n" " ")) toListener:toListener
		if (classOf st) == String and st != "" do logLine ("stack trace:\n" + st)
	),

	fn logWarn msg = (
		warnCount += 1
		logLine ("WARNING " + msg) toListener:(warnCount <= 20)
	),

	-- Keeps the dialog alive inside long loops: Esc, status text (4 times a
	-- second at most), a "working" line in the log every 30 s.
	fn tick msg = (
		if keyboard.escPressed do (
			cancelled = true
			throw "cancelled (Esc)"
		)
		local now = timeStamp()
		local dt = now - lastUiTick
		if dt > 250 or dt < 0 do (
			lastUiTick = now
			if uiFn != undefined do uiFn (100.0 * curIndex / (amax #(nodeTotal, 1))) msg
		)
		local dl = now - lastLogTick
		if dl > 30000 or dl < 0 do (
			lastLogTick = now
			logLine ("working: " + msg)
		)
	),

	-- ── small helpers ────────────────────────────────────────────
	fn localTM n = (
		if n.parent == undefined then n.transform else (n.transform * (inverse n.parent.transform))
	),

	fn isMirrored m = ((dot (cross m.row1 m.row2) m.row3) < 0),

	fn isIdentityTM m = (
		local d = (distance m.row1 [1,0,0]) + (distance m.row2 [0,1,0]) + (distance m.row3 [0,0,1])
		d < 1e-6 and (length m.row4) < 1e-5
	),

	-- largest |cos| between the axes of a matrix (0 = no shear)
	fn shearOf m = (
		local sx = length m.row1
		local sy = length m.row2
		local sz = length m.row3
		if sx < 1e-12 or sy < 1e-12 or sz < 1e-12 then 1.0 else (
			local n1 = m.row1 / sx
			local n2 = m.row2 / sy
			local n3 = m.row3 / sz
			amax #((abs (dot n1 n2)), (abs (dot n1 n3)), (abs (dot n2 n3)))
		)
	),

	fn axisOrderName i = (
		local names = #("XYZ", "XZY", "YZX", "YXZ", "ZXY", "ZYX", "XYX", "YZY", "ZXZ")
		if (classOf i) == Integer and i >= 1 and i <= names.count then names[i] else (i as string)
	),

	-- component 1..3 of a Point3 (0 = the value itself)
	fn comp3 v ci = (
		if v == undefined or ci == 0 then v else (
			try (
				if ci == 1 then v.x else if ci == 2 then v.y else v.z
			) catch undefined
		)
	),

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

	-- system unit in centimeters
	fn cmPerUnit = (
		local scl = units.SystemScale
		local st = units.SystemType
		if st == #inches then scl * 2.54
		else if st == #feet then scl * 30.48
		else if st == #miles then scl * 160934.4
		else if st == #millimeters then scl * 0.1
		else if st == #centimeters then scl * 1.0
		else if st == #meters then scl * 100.0
		else if st == #kilometers then scl * 100000.0
		else scl
	),

	-- ── where Send to Blender writes: <bridge folder>\FromMax ────
	-- (the bridge folder is the one of the listener, shared with the Blender add-on)
	fn exchangeDir = (
		local root = if BlenderMaxBridge != undefined and BlenderMaxBridge.bridgeDir != "" then BlenderMaxBridge.bridgeDir else (
			local base = systemTools.getEnvVariable "LOCALAPPDATA"
			if base == undefined or base == "" do base = (dotNetClass "System.IO.Path").GetTempPath()
			pathConfig.appendPath base "BlenderMaxBridge"
		)
		pathConfig.appendPath root "FromMax"
	),

	fn defaultOutput = (
		local base = if maxFileName != "" then (getFilenameFile maxFileName) else "untitled"
		pathConfig.appendPath (exchangeDir()) (base + ".json")
	),

	fn writeText filePath txt = (
		(dotNetClass "System.IO.File").WriteAllText filePath txt (dotNetObject "System.Text.UTF8Encoding" false)
	),

	-- ── layers ───────────────────────────────────────────────────
	fn layersJson = (
		layerIdx = Dictionary #string
		local items = #()
		local cnt = LayerManager.count
		for i = 0 to cnt - 1 do (
			local lay = LayerManager.getLayer i
			layerIdx[lay.name] = i
		)
		for i = 0 to cnt - 1 do (
			local lay = LayerManager.getLayer i
			local par = try (lay.getParent()) catch undefined
			local pIdx = -1
			if par != undefined do (
				if hasDictValue layerIdx par.name do pIdx = layerIdx[par.name]
			)
			local hid = try (lay.isHidden) catch (try (not lay.on) catch false)
			local frz = try (lay.isFrozen) catch false
			local rnd = try (lay.renderable) catch true
			append items (jObj #((kv "name" (jStr lay.name)), (kv "parent" (jInt pIdx)), \
				(kv "hidden" (jBool hid)), (kv "frozen" (jBool frz)), (kv "renderable" (jBool rnd))))
		)
		jArr items
	),

	-- ── nodes in hierarchy order (parents before children) ───────
	fn collectNodes selectedOnly = (
		local wanted = undefined
		if selectedOnly do (
			wanted = Dictionary #integer
			for s in selection do (
				local a = s
				while a != undefined do (
					wanted[a.handle] = true
					a = a.parent
				)
			)
		)
		local res = #()
		local stack = #()
		local roots = rootNode.children
		for i = roots.count to 1 by -1 do append stack roots[i]
		while stack.count > 0 do (
			local n = stack[stack.count]
			deleteItem stack stack.count
			if wanted == undefined or (hasDictValue wanted n.handle) do (
				append res n
				local ch = n.children
				for i = ch.count to 1 by -1 do append stack ch[i]
			)
		)
		res
	),

	fn nodeKind n = (
		local sup = superClassOf n
		local cls = classOf n
		if sup == GeometryClass then (
			if cls == TargetObject then "helper" else "mesh"
		)
		else if sup == shape then "shape"
		else if sup == helper then (
			if cls == Dummy then "dummy" else if cls == Point then "point" else "helper"
		)
		else if sup == camera then "camera"
		else if sup == light then "light"
		else "other"
	),

	-- ── geometry ─────────────────────────────────────────────────
	-- Does snapshotAsMesh reverse the faces of a mirrored node? Probed once per
	-- export on a temporary one-triangle mesh, deleted right away.
	fn probeSnapshot = (
		local res = false
		local pn = undefined
		try (
			pn = mesh vertices:#([0,0,0], [10,0,0], [0,10,0]) faces:#([1,2,3])
			pn.transform = scaleMatrix [-1,1,1]
			local sm = snapshotAsMesh pn
			local fc = getFace sm 1
			local i1 = fc.x as integer
			local i2 = fc.y as integer
			local i3 = fc.z as integer
			local kept = (i1 == 1 and i2 == 2 and i3 == 3) or (i1 == 2 and i2 == 3 and i3 == 1) or (i1 == 3 and i2 == 1 and i3 == 2)
			logLine ("probe: snapshotAsMesh of a mirrored triangle gives face [" + (i1 as string) + "," + (i2 as string) + "," + \
				(i3 as string) + "], vertex 2 at " + ((getVert sm 2) as string) + \
				(if kept then ": faces kept as they are" else ": faces reversed, turned back for mirrored nodes"))
			res = not kept
			delete sm
		) catch (
			logWarn ("probe failed (" + ((getCurrentException()) as string) + "); faces of mirrored nodes taken as they come")
			res = false
		)
		if pn != undefined and (isValidNode pn) do delete pn
		res
	),

	fn sameStack a b = (
		local ma = a.modifiers
		local mb = b.modifiers
		local same = ma.count == mb.count
		for i = 1 to ma.count do (
			if same and ma[i] != mb[i] do same = false
		)
		same
	),

	fn sameOffset a b = (
		local oa = a.objectTransform * (inverse a.transform)
		local ob = b.objectTransform * (inverse b.transform)
		local dr = (distance oa.row1 ob.row1) + (distance oa.row2 ob.row2) + (distance oa.row3 ob.row3)
		dr < 1e-5 and (distance oa.row4 ob.row4) < 1e-3
	),

	-- Mesh key of an earlier instance with the same base object, the same
	-- modifiers (instanced) and the same pivot offset: same mesh in pivot space.
	-- returns the entry #(node, mesh key, live JSON, final JSON) or undefined
	fn sharedMeshKey n = (
		local res = undefined
		local bk = (getHandleByAnim n.baseObject) as string
		if hasDictValue instSets bk do (
			for ent in instSets[bk] do (
				if res == undefined and (isValidNode ent[1]) and (sameStack n ent[1]) and (sameOffset n ent[1]) do res = ent
			)
		)
		res
	),

	fn rememberShared n meshKey liveTxt finalTxt = (
		local bk = (getHandleByAnim n.baseObject) as string
		if not (hasDictValue instSets bk) do instSets[bk] = #()
		append instSets[bk] #(n, meshKey, liveTxt, finalTxt)
	),

	-- One mesh blob in the .bin file (layout in the format notes). flip: write
	-- every face reversed (a mirrored node whose snapshot reversed them).
	-- nrm: #(normals as x y z floats, corner indices, corner order, explicit count) from
	-- readNormals, or undefined.
	-- Returns the number of map channels written.
	fn writeMeshBlob meshKey tri pivTM flip what nrm = (
		local bs = binStream
		local nv = tri.numverts
		local nf = tri.numfaces
		local blobAt = ftell bs
		local cnt = 4096
		for i = 1 to nv do (
			cnt -= 1
			if cnt <= 0 do (
				cnt = 4096
				tick (what + ": vertices " + (i as string) + " / " + (nv as string))
			)
			local p = (getVert tri i) * pivTM
			WriteFloat bs p.x
			WriteFloat bs p.y
			WriteFloat bs p.z
		)
		for f = 1 to nf do (
			cnt -= 1
			if cnt <= 0 do (
				cnt = 4096
				tick (what + ": faces " + (f as string) + " / " + (nf as string))
			)
			local fc = getFace tri f
			local e1 = getEdgeVis tri f 1
			local e2 = getEdgeVis tri f 2
			local e3 = getEdgeVis tri f 3
			local vis = 0
			if flip then (
				-- face (a, c, b): its edges are a-c (old edge 3), c-b (old 2), b-a (old 1)
				WriteLong bs ((fc.x as integer) - 1) #signed
				WriteLong bs ((fc.z as integer) - 1) #signed
				WriteLong bs ((fc.y as integer) - 1) #signed
				if e3 do vis += 1
				if e2 do vis += 2
				if e1 do vis += 4
			) else (
				WriteLong bs ((fc.x as integer) - 1) #signed
				WriteLong bs ((fc.y as integer) - 1) #signed
				WriteLong bs ((fc.z as integer) - 1) #signed
				if e1 do vis += 1
				if e2 do vis += 2
				if e3 do vis += 4
			)
			local sg = getFaceSmoothGroup tri f
			if sg < 0 then WriteLong bs sg #signed else WriteLong bs sg #unsigned
			local matIdx = (getFaceMatID tri f) - 1
			if matIdx < 0 do matIdx = 0
			if matIdx > 65535 do matIdx = 65535
			WriteLong bs (matIdx + vis * 65536) #unsigned
		)
		local maps = #()
		local nm = try (meshop.getNumMaps tri) catch 0
		-- -2 vertex alpha, -1 illumination, 0 vertex color, 1.. UV channels
		local chans = #(-2, -1)
		for ch = 0 to nm - 1 do append chans ch
		for ch in chans do (
			if (try (meshop.getMapSupport tri ch) catch false) do (
				local nmv = meshop.getNumMapVerts tri ch
				for i = 1 to nmv do (
					cnt -= 1
					if cnt <= 0 do (
						cnt = 4096
						tick (what + ": map " + (ch as string) + " vertices " + (i as string) + " / " + (nmv as string))
					)
					local mv = meshop.getMapVert tri ch i
					WriteFloat bs mv.x
					WriteFloat bs mv.y
					WriteFloat bs mv.z
				)
				for f = 1 to nf do (
					cnt -= 1
					if cnt <= 0 do (
						cnt = 4096
						tick (what + ": map " + (ch as string) + " faces " + (f as string) + " / " + (nf as string))
					)
					local mf = meshop.getMapFace tri ch f
					WriteLong bs ((mf.x as integer) - 1) #signed
					if flip then (
						WriteLong bs ((mf.z as integer) - 1) #signed
						WriteLong bs ((mf.y as integer) - 1) #signed
					) else (
						WriteLong bs ((mf.y as integer) - 1) #signed
						WriteLong bs ((mf.z as integer) - 1) #signed
					)
				)
				append maps ("[" + (jInt ch) + "," + (jInt nmv) + "]")
			)
		)
		local rec = #((kv "at" (jInt blobAt)), (kv "nv" (jInt nv)), (kv "nf" (jInt nf)), (kv "maps" (jArr maps)))
		-- 3ds Max normals: the table (pivot space), then one index per triangle corner,
		-- in the corner order of the faces as written
		if nrm != undefined do (
			local nrmAt = ftell bs
			local tb = nrm[1]
			for i = 1 to tb.count do (
				cnt -= 1
				if cnt <= 0 do (
					cnt = 4096
					tick (what + ": normals " + ((i / 3) as string) + " / " + ((tb.count / 3) as string))
				)
				WriteFloat bs tb[i]
			)
			-- the reader's corner for corners 1, 2, 3 of each face as written (a reversed face
			-- is written a, c, b)
			local cs = nrm[2]
			local p = nrm[3]
			local q1 = p[1]
			local q2 = if flip then p[3] else p[2]
			local q3 = if flip then p[2] else p[3]
			for f = 1 to nf do (
				cnt -= 1
				if cnt <= 0 do (
					cnt = 4096
					tick (what + ": normals, face " + (f as string) + " / " + (nf as string))
				)
				local b3 = (f - 1) * 3
				WriteLong bs cs[b3 + q1] #signed
				WriteLong bs cs[b3 + q2] #signed
				WriteLong bs cs[b3 + q3] #signed
			)
			append rec (kv "nrm" ("[" + (jInt nrmAt) + "," + (jInt (tb.count / 3)) + "]"))
		)
		append meshItems (kv meshKey (jObj rec))
		statFaces += nf
		maps.count
	),

	-- ── live modifiers ───────────────────────────────────────────
	-- The Shell / TurboSmooth modifiers at the top of the stack, top first: the
	-- part Blender keeps live. Disabled modifiers are skipped; any other enabled
	-- modifier ends the run (it and everything below it are baked).
	fn liveRun n = (
		local run = #()
		local stop = false
		local mods = n.modifiers
		for k = 1 to mods.count do (
			if not stop do (
				local md = mods[k]
				local isOn = try (md.enabled) catch true
				if isOn == true do (
					local cls = classOf md
					if cls == TurboSmooth or cls == Shell then append run md else stop = true
				)
			)
		)
		run
	),

	-- numeric and on/off parameters of a modifier as a JSON object
	fn modParamsJson md = (
		local items = #()
		local pn = try (getPropNames md) catch #()
		for p in pn do (
			local v = try (getProperty md p) catch undefined
			local cv = classOf v
			if cv == Float or cv == Double then append items (kv (jKey (p as string)) (jNum v))
			else if cv == Integer or cv == Integer64 or cv == IntegerPtr then append items (kv (jKey (p as string)) (jInt v))
			else if cv == BooleanClass then append items (kv (jKey (p as string)) (jBool v))
		)
		jObj items
	),

	-- the run in Blender's order: the lowest modifier first
	fn liveJson run = (
		local items = #()
		for k = run.count to 1 by -1 do (
			local md = run[k]
			local inViews = try (md.enabledInViews) catch true
			local inRenders = try (md.enabledInRenders) catch true
			append items (jObj #((kv "class" (jStr ((classOf md) as string))), (kv "name" (jStr md.name)), \
				(kv "views" (jBool (inViews != false))), (kv "renders" (jBool (inRenders != false))), \
				(kv "params" (modParamsJson md))))
		)
		jArr items
	),

	-- Vertices of the final mesh (whole stack) in pivot space: what Blender's live
	-- modifiers have to produce. Returns the JSON record of the blob.
	fn writeFinalVerts tri pivTM what = (
		local bs = binStream
		local nv = tri.numverts
		local blobAt = ftell bs
		local cnt = 4096
		for i = 1 to nv do (
			cnt -= 1
			if cnt <= 0 do (
				cnt = 4096
				tick (what + ": final vertices " + (i as string) + " / " + (nv as string))
			)
			local p = (getVert tri i) * pivTM
			WriteFloat bs p.x
			WriteFloat bs p.y
			WriteFloat bs p.z
		)
		jObj #((kv "at" (jInt blobAt)), (kv "nv" (jInt nv)), (kv "nf" (jInt tri.numfaces)))
	),

	-- ── Modify panel (skinOps reads the modifier shown there) ───────
	-- Shows modifier md of node n in the Modify panel: the node is selected (a hidden or
	-- frozen node / layer is shown for that moment). Returns what restoreShown puts back.
	fn showInModPanel n md = (
		local lay = n.layer
		local heads = #()
		local st = #(n.isHidden, n.isFrozen, (try (lay.isHidden) catch false), (try (lay.isFrozen) catch false), heads)
		if st[3] do (try (lay.isHidden = false) catch ())
		if st[4] do (try (lay.isFrozen = false) catch ())
		if st[1] do n.isHidden = false
		if st[2] do n.isFrozen = false
		-- a member of a closed group shows its modifiers only while the group is open
		local p = n.parent
		while p != undefined do (
			if (isGroupHead p) and not (isOpenGroupHead p) do (
				try (
					setGroupOpen p true
					append heads p
				) catch ()
			)
			p = p.parent
		)
		if not panelUsed do (
			try (cui.commandPanelOpen = true) catch ()
			panelUsed = true
		)
		if (getCommandPanelTaskMode()) != #modify do setCommandPanelTaskMode #modify
		select n
		modPanel.setCurrentObject md
		classOf n
		st
	),

	fn restoreShown n st = (
		if st != undefined do (
			for p in st[5] do (try (setGroupOpen p false) catch ())
			if st[2] do n.isFrozen = true
			if st[1] do n.isHidden = true
			local lay = n.layer
			if st[4] do (try (lay.isFrozen = true) catch ())
			if st[3] do (try (lay.isHidden = true) catch ())
		)
	),

	-- ── 3ds Max normals ──────────────────────────────────────────
	-- object space -> pivot space for normals: the inverse transpose of the pivot offset
	fn normalMatrix n = (
		local offTM = n.objectTransform * (inverse n.transform)
		local mi = inverse offTM
		matrix3 [mi.row1.x, mi.row2.x, mi.row3.x] [mi.row1.y, mi.row2.y, mi.row3.y] \
			[mi.row1.z, mi.row2.z, mi.row3.z] [0, 0, 0]
	),

	-- C# source of the normals reader (normalsReader compiles it)
	fn normalsReaderSource = (
"// 3ds Max -> Blender Bridge: normals reader, compiled by MaxToBlenderBridge.ms at run time.
// Created by Claude (Anthropic) under the leadership of Kruglov Iurii. GNU GPL v3.
// C# 5 (the compiler of .NET Framework 4.8 in 3ds Max), against Autodesk.Max.dll;
// MAX2024 defined for 3ds Max 2024 and later.
using System;
using Autodesk.Max;

public class MaxToBlenderNormals
{
    float[] table = new float[0];
    int[] corners = new int[0];
    int[] faceVerts = new int[0];
    int explicitCount = 0;

    // normals in pivot space, x y z per normal
    public float[] Table() { return table; }
    // index into Table (0..) for every triangle corner, 3 per triangle
    public int[] Corners() { return corners; }
    // Every step-th triangle and the last one, 4 numbers each: the triangle (0..) and
    // the mesh vertex (0..) at its corners 1, 2, 3. The caller matches them to its own
    // copy of the mesh (snapshotAsMesh may turn the triangles of a mirrored node around).
    public int[] SampleFaceVerts(int step)
    {
        int nf = faceVerts.Length / 3;
        if (nf <= 0) return new int[0];
        if (step < 1) step = 1;
        System.Collections.Generic.List<int> res = new System.Collections.Generic.List<int>();
        for (int f = 0; f < nf; f += step)
        {
            res.Add(f);
            res.Add(faceVerts[3 * f]);
            res.Add(faceVerts[3 * f + 1]);
            res.Add(faceVerts[3 * f + 2]);
        }
        if ((nf - 1) % step != 0)
        {
            int f = nf - 1;
            res.Add(f);
            res.Add(faceVerts[3 * f]);
            res.Add(faceVerts[3 * f + 1]);
            res.Add(faceVerts[3 * f + 2]);
        }
        return res.ToArray();
    }
    // how many of the normals are explicit (set by Edit Normals, Weighted Normals, an import...)
    public int ExplicitCount() { return explicitCount; }
    // lets go of the arrays of the last Read
    public void Clear()
    {
        table = new float[0];
        corners = new int[0];
        faceVerts = new int[0];
        explicitCount = 0;
    }

    // how the last Read found the mesh, for the log
    public string Info() { return info; }
    string info = \"\";

    // the .NET wrapper type of o (it tells what Autodesk.Max made of the object)
    static string ClassOf(IObject o)
    {
        return o.GetType().Name;
    }

    // \"triangles/vertices\" of m, for the messages
    static string Counts(IMesh m)
    {
        if (m == null) return \"none\";
        try { return m.NumFaces + \"/\" + m.NumVerts; } catch (Exception) { return \"?\"; }
    }

    // The mesh of tri with exactly nf triangles and nv vertices (those of the caller's
    // snapshot of the same node): tri.Mesh (the field), else tri.Mesh_ (GetMesh()).
    // null if neither; tried: what each had.
    static IMesh PickMesh(ITriObject tri, int nf, int nv, string label, ref string tried)
    {
        IMesh m = null;
        try { m = tri.Mesh; } catch (Exception) { }
        tried += (tried == \"\" ? \"\" : \", \") + label + \"Mesh \" + Counts(m);
        if (m != null && m.NumFaces == nf && m.NumVerts == nv) return m;
        IMesh m2 = null;
        try { m2 = tri.Mesh_; } catch (Exception) { }
        tried += \", \" + label + \"Mesh_ \" + Counts(m2);
        if (m2 != null && m2.NumFaces == nf && m2.NumVerts == nv) return m2;
        return null;
    }

    // The normals 3ds Max shades the node's evaluated mesh with at time `ticks`, per
    // triangle corner, as the FBX exporter writes them: the specified normals where
    // the mesh has them (Edit Normals, Weighted Normals, normals imported from FBX /
    // OBJ), smoothing-group normals everywhere else. Everything is read from a copy of
    // the mesh: the scene is not changed. nf, nv: triangles and vertices of the caller's
    // snapshot of the node (the mesh read must have the same). r1, r2, r3: the rows of
    // the 3x3 matrix that takes normals from object space to pivot space
    // (n' = x * r1 + y * r2 + z * r3). Returns \"\" when done, or the reason it could not.
    public string Read(int handle, int ticks, int nf, int nv,
                       float r1x, float r1y, float r1z,
                       float r2x, float r2y, float r2z,
                       float r3x, float r3y, float r3z)
    {
        Clear();
        info = \"\";
        if (nf <= 0) return \"the mesh has no triangles\";
        IGlobal g = GlobalInterface.Instance;
        IINode node = g.COREInterface.GetINodeByHandle((uint)handle);
        if (node == null) return \"no node with handle \" + handle;
        IObjectState os = node.EvalWorldState(ticks, true);
        IObject obj = os == null ? null : os.Obj;
        if (obj == null) return \"the node has no object\";
        IClass_ID triId = g.TriObjectClassID;
        bool isTri = obj.IsSubClassOf(triId);
        string cls = ClassOf(obj);
        IObject made = null;      // the TriObject ConvertToType made for us, deleted at the end
        IMesh mesh = null;        // our copy of the mesh, freed at the end
        try
        {
            // The TriObject the way Autodesk's own .NET samples get it: the object itself
            // when it is one, else what ConvertToType gives, cast to ITriObject.
            ITriObject tri = isTri ? obj as ITriObject : null;
            IObject conv = null;
            if (tri == null)
            {
                if (obj.CanConvertToType(triId) == 0) return \"the object is not a mesh (\" + cls + \")\";
                conv = obj.ConvertToType(ticks, triId);
                if (conv == null) return \"the conversion to a mesh failed (\" + cls + \")\";
                // a new object, unless ConvertToType gave the object itself
                if (!isTri && conv.NativePointer != obj.NativePointer) made = conv;
                tri = conv as ITriObject;
            }
            string how = isTri ? cls : cls + \" converted\";
            string tried = \"\";
            IMesh src = tri == null ? null : PickMesh(tri, nf, nv, \"\", ref tried);
            if (src == null)
            {
                // the same object wrapped from its pointer
                ITriObject t2 = null;
                try { t2 = g.TriObject.Marshal((conv != null ? conv : obj).NativePointer); } catch (Exception) { }
                if (t2 != null) src = PickMesh(t2, nf, nv, \"marshalled \", ref tried);
                if (src != null) how += \", marshalled\";
            }
            if (src == null)
                return \"no mesh with the snapshot's \" + nf + \" triangles / \" + nv + \" vertices (\" + how +
                       (tri == null ? \", not an ITriObject\" : \"\") + \"; \" + tried + \")\";
            // our own mesh: vertices and triangles (with their smoothing groups)
            mesh = g.Mesh.Create();
            mesh.DeepCopy(src, 3u);                 // TOPO_CHANNEL | GEOM_CHANNEL
            if (mesh.NumFaces != nf || mesh.NumVerts != nv)
            {
                IMesh m1 = mesh;
                mesh = null;
                try { m1.FreeAll(); } catch (Exception) { }
                mesh = g.Mesh.Create(src);          // the copy constructor
                how += \", copied whole\";
                if (mesh == null || mesh.NumFaces != nf || mesh.NumVerts != nv)
                    return \"copying the mesh failed (\" + how + \", copy \" + Counts(mesh) + \")\";
            }
            IMeshNormalSpec srcSpec = src.SpecifiedNormals;
            bool srcHas = srcSpec != null && srcSpec.NumFaces == nf && srcSpec.NumNormals > 0;
            IMeshNormalSpec spec = mesh.SpecifiedNormals;
            bool copyHas = spec != null && spec.NumFaces == nf && spec.NumNormals > 0;
            if (!copyHas)
            {
                mesh.ClearSpecifiedNormals();
                mesh.SpecifyNormals();
                spec = mesh.SpecifiedNormals;
                if (spec != null && srcHas) spec.Assign(srcSpec);   // the specified normals as they are
            }
            if (spec == null) return \"3ds Max gives the mesh no normals interface (\" + how + \")\";
            spec.SetParent(mesh);
            if (spec.NumFaces != nf) spec.SetNumFaces(nf);
            // face normals of the copy, for the normals computed from them below
            mesh.BuildNormals();
            // builds the normals that are not specified from the smoothing groups, and
            // computes the directions of the ones that are not explicit
            spec.CheckNormals();
            int nn = spec.NumNormals;
            if (nn <= 0) return \"3ds Max built no normals (\" + how + \")\";
            if (spec.NumFaces != nf) return \"3ds Max built normals for \" + spec.NumFaces + \" of \" + nf + \" triangles (\" + how + \")\";
            float[] tb = new float[nn * 3];
            int ne = 0;
            for (int i = 0; i < nn; i++)
            {
                IPoint3 p = spec.Normal(i);
                double x = p.X * r1x + p.Y * r2x + p.Z * r3x;
                double y = p.X * r1y + p.Y * r2y + p.Z * r3y;
                double z = p.X * r1z + p.Y * r2z + p.Z * r3z;
                double len = Math.Sqrt(x * x + y * y + z * z);
                if (len > 1e-20)
                {
                    x /= len;
                    y /= len;
                    z /= len;
                }
                else
                {
                    x = 0.0;
                    y = 0.0;
                    z = 1.0;
                }
                tb[3 * i] = (float)x;
                tb[3 * i + 1] = (float)y;
                tb[3 * i + 2] = (float)z;
                if (spec.GetNormalExplicit(i)) ne++;
            }
            int[] cs = new int[nf * 3];
            int[] fv = new int[nf * 3];
#if MAX2024
            for (int f = 0; f < nf; f++)
            {
                IFace face = mesh.GetFace(f);           // 3ds Max 2024 and later
#else
            System.Collections.Generic.IList<IFace> faces = mesh.Faces;   // 3ds Max 2022 - 2023
            for (int f = 0; f < nf; f++)
            {
                IFace face = faces[f];
#endif
                for (int c = 0; c < 3; c++)
                {
                    int k = spec.GetNormalIndex(f, c);
                    if (k < 0 || k >= nn) return \"triangle \" + (f + 1) + \" has no normal at corner \" + (c + 1) + \" (\" + how + \")\";
                    cs[3 * f + c] = k;
                    fv[3 * f + c] = (int)face.GetVert(c);
                }
            }
            table = tb;
            corners = cs;
            faceVerts = fv;
            explicitCount = ne;
            info = how + \"; \" + (srcHas ? \"specified normals\" : \"normals from the smoothing groups\") +
                   \", \" + nn + \" normals (\" + ne + \" explicit)\";
            return \"\";
        }
        catch (Exception ex)
        {
            return \"error: \" + ex.Message;
        }
        finally
        {
            if (mesh != null)
            {
                try { mesh.FreeAll(); } catch (Exception) { }
            }
            if (made != null)
            {
                try { made.DeleteMe(); } catch (Exception) { }
            }
        }
    }
}
"
	),

	-- Autodesk.Max.dll, 3ds Max's .NET interface to its SDK: in the 3ds Max folder, else
	-- wherever the loaded one comes from. "" if there is none.
	fn maxDotNetDll = (
		local dll = pathConfig.appendPath (getDir #maxRoot) "Autodesk.Max.dll"
		if not (doesFileExist dll) do (
			dll = ""
			try (
				for a in ((dotNetClass "System.AppDomain").CurrentDomain.GetAssemblies()) do (
					if dll == "" and (a.GetName()).Name == "Autodesk.Max" do dll = a.Location
				)
			) catch ()
		)
		dll
	),

	-- The C# compiler Autodesk added in 3ds Max 2026 (.NET 8 / 10, where the CodeDom
	-- compiler of .NET Framework is gone): CSharpUtilities.CSharpCompilationHelper, or
	-- undefined in older versions.
	fn csharpHelper = (
		local h = try (dotNetClass "CSharpUtilities.CSharpCompilationHelper") catch undefined
		if h == undefined and (maxVersion())[1] >= 28000 do (
			local p = pathConfig.appendPath (getDir #maxRoot) "CSharpUtilities.dll"
			if doesFileExist p do (
				h = try (
					dotNet.loadAssembly p
					dotNetClass "CSharpUtilities.CSharpCompilationHelper"
				) catch undefined
			)
		)
		h
	),

	-- Compiles the normals reader in memory against dll. max2024: the source starts with
	-- "#define MAX2024" (triangles read with GetFace, 3ds Max 2024 and later; else through
	-- Faces, 2022 - 2023). helper: see csharpHelper; undefined: the CodeDom compiler of
	-- .NET Framework (3ds Max 2025 and older). Returns the reader, or a String saying why not.
	fn compileNormalsReader dll max2024 helper = (
		local res = undefined
		local src = (if max2024 then "#define MAX2024\n" else "") + (normalsReaderSource())
		local asm = undefined
		local msgs = #()
		if helper != undefined then (
			-- with the assemblies 3ds Max has loaded, else with Autodesk.Max.dll named as well
			for refs in #(#(), #(dll)) while asm == undefined do (
				asm = try (helper.Compile src refs) catch (
					append msgs (substring ((getCurrentException()) as string) 1 400)
					undefined
				)
			)
			if asm == undefined and msgs.count == 0 do append msgs "the compiler returned nothing"
		) else (
			try (
				local provider = dotNetObject "Microsoft.CSharp.CSharpCodeProvider"
				local compilerParams = dotNetObject "System.CodeDom.Compiler.CompilerParameters"
				compilerParams.GenerateInMemory = true
				compilerParams.GenerateExecutable = false
				compilerParams.ReferencedAssemblies.Add "System.dll"
				compilerParams.ReferencedAssemblies.Add "System.Drawing.dll"
				compilerParams.ReferencedAssemblies.Add dll
				local cr = provider.CompileAssemblyFromSource compilerParams #(src)
				if cr.Errors.HasErrors then (
					for i = 0 to cr.Errors.Count - 1 do (
						local ce = cr.Errors.Item[i]
						if not ce.IsWarning and msgs.count < 3 do append msgs ("line " + (ce.Line as string) + ": " + ce.ErrorText)
					)
					if msgs.count == 0 do append msgs "errors without text"
				) else asm = cr.CompiledAssembly
			) catch (
				append msgs (substring ((getCurrentException()) as string) 1 400)
			)
		)
		if asm == undefined then (
			local msg = ""
			for m in msgs do msg += (if msg == "" then "" else "; ") + m
			res = "compiling it failed: " + msg
		) else (
			local rd = try (asm.CreateInstance "MaxToBlenderNormals") catch undefined
			res = if rd == undefined then "the compiled reader could not be created" else rd
		)
		res
	),

	-- The normals reader: a small C# class (normalsReaderSource) that reads the normals of
	-- a node's evaluated mesh the way the FBX exporter does, from a copy of the mesh: no
	-- modifier is added, nothing is selected, the scene is not changed. Compiled once per
	-- 3ds Max session and kept in a global with its source, so a reader compiled from a
	-- different source (another version of this script) is never used. Returns the reader,
	-- or a String saying why there is none.
	fn normalsReader = (
		local res = undefined
		local src = normalsReaderSource()
		if (classOf MaxToBlenderNormalsReader) == Array and MaxToBlenderNormalsReader.count == 2 and \
			MaxToBlenderNormalsReader[1] == src and MaxToBlenderNormalsReader[2] != undefined then (
			res = MaxToBlenderNormalsReader[2]
			logLine "3ds Max normals: reader compiled earlier in this 3ds Max session"
		) else (
			local t0 = timeStamp()
			local dll = maxDotNetDll()
			if dll == "" then res = "Autodesk.Max.dll not found in " + (getDir #maxRoot)
			else (
				-- the compiled reader binds to the Autodesk.Max that 3ds Max has loaded
				try (dotNet.loadAssembly dll) catch ()
				local helper = csharpHelper()
				local newApi = (maxVersion())[1] >= 26000
				res = compileNormalsReader dll newApi helper
				-- a 3ds Max whose interface differs from what its version suggests: the other way
				if (classOf res) == String do (
					local res2 = compileNormalsReader dll (not newApi) helper
					if (classOf res2) != String do res = res2
				)
				if (classOf res) != String do (
					MaxToBlenderNormalsReader = #(src, res)
					logLine ("3ds Max normals: reader compiled in " + \
						(substituteString (formattedPrint ((timeStamp() - t0) / 1000.0) format:".1f") "," ".") + " s (" + \
						(if helper != undefined then "CSharpCompilationHelper, .NET 8+" else "CodeDom, .NET Framework") + ")")
				)
			)
		)
		res
	),

	-- A .NET array from the reader as a MAXScript array (MAXScript converts the arrays .NET
	-- methods return; this is for a 3ds Max that hands over the .NET array itself).
	fn asArray v = (
		if (classOf v) == Array then v else (
			local a = #()
			local n = try (v.Length) catch 0
			for i = 0 to n - 1 do append a (v.GetValue i)
			a
		)
	),

	-- The reader's corner for each corner of tri's triangles: #(p1, p2, p3), the same for
	-- every triangle (snapshotAsMesh may turn the triangles of a mirrored node around).
	-- sv: every 61st triangle of the reader and its last one, 4 numbers each (triangle 0..,
	-- its vertices 0.. at corners 1, 2, 3). The first of them with three different
	-- vertices gives the order, all of them check it. undefined: not the same triangles.
	fn cornerPerm tri sv = (
		local nf = tri.numfaces
		local ns = sv.count / 4
		local p = undefined
		for k = 1 to ns while p == undefined do (
			local b = (k - 1) * 4
			local f = sv[b + 1] + 1
			if f >= 1 and f <= nf and sv[b + 2] != sv[b + 3] and sv[b + 3] != sv[b + 4] and sv[b + 2] != sv[b + 4] do (
				local fc = getFace tri f
				local s = #((fc.x as integer) - 1, (fc.y as integer) - 1, (fc.z as integer) - 1)
				p = #(0, 0, 0)
				for j = 1 to 3 do (
					for c = 1 to 3 do (if p[j] == 0 and sv[b + 1 + c] == s[j] do p[j] = c)
				)
			)
		)
		local same = p != undefined and p[1] > 0 and p[2] > 0 and p[3] > 0 and p[1] != p[2] and p[2] != p[3] and p[1] != p[3]
		for k = 1 to ns while same do (
			local b = (k - 1) * 4
			local f = sv[b + 1] + 1
			if f < 1 or f > nf then same = false
			else (
				local g = getFace tri f
				if sv[b + 1 + p[1]] != (g.x as integer) - 1 or sv[b + 1 + p[2]] != (g.y as integer) - 1 or \
					sv[b + 1 + p[3]] != (g.z as integer) - 1 do same = false
			)
		)
		if same then p else undefined
	),

	-- 3ds Max's normals of n as it is now (switched-off modifiers stay off) for the
	-- triangles of tri (the snapshot of the same stack at the same time), as the FBX
	-- exporter writes them: the specified normals where the mesh has them, smoothing-group
	-- normals everywhere else. Returns #(normals in pivot space as x y z floats, normal
	-- index 0.. for every corner of the reader's triangles, the reader's corner for each
	-- corner of tri #(p1, p2, p3), number of explicit normals), or a String saying why not.
	fn readNormals n tri what = (
		local t0 = timeStamp()
		local res = undefined
		local wsm = false
		for md in n.modifiers do (
			if (superClassOf md) == SpacewarpModifier do wsm = true
		)
		if wsm then res = "bound to a space warp"
		else if nrmReader == undefined then res = "no normals reader (see the start of the log)"
		else (
			local rd = nrmReader
			local nm = normalMatrix n
			local msg = try (rd.Read n.handle (currentTime as integer) tri.numfaces tri.numverts \
				nm.row1.x nm.row1.y nm.row1.z nm.row2.x nm.row2.y nm.row2.z nm.row3.x nm.row3.y nm.row3.z) \
				catch ("error: " + ((getCurrentException()) as string))
			if (classOf msg) != String then res = "the reader gave no answer"
			else if msg != "" then res = msg
			else (
				local tb = asArray (rd.Table())
				local cs = asArray (rd.Corners())
				local sv = asArray (rd.SampleFaceVerts 61)
				local ne = rd.ExplicitCount()
				local nf = tri.numfaces
				if cs.count != nf * 3 or tb.count < 3 then
					res = ("the reader has " + ((cs.count / 3) as string) + " triangles, the mesh " + (nf as string))
				else (
					local p = cornerPerm tri sv
					if p == undefined then res = "the reader's triangles are not the mesh's triangles"
					else (
						res = #(tb, cs, p, (if (classOf ne) == Integer then ne else 0))
						-- how the first meshes were read, for the log
						if nrmInfoShown < 3 or optVerboseLog do (
							nrmInfoShown += 1
							logLine ("3ds Max normals: " + what + " read (" + (try (rd.Info()) catch "?") + ")")
						)
					)
				)
			)
			try (rd.Clear()) catch ()
		)
		local ms = timeStamp() - t0
		if ms > 0 do normalsMs += ms
		if (classOf res) == String then statNormalsFail += 1 else (
			statNormals += 1
			if res[4] > 0 do statNormalsExplicit += 1
		)
		res
	),

	-- The normals reader tried on a temporary box (12 triangles, each side in its own
	-- smoothing group, so every corner must get the normal of its side). Logs the result;
	-- the box is deleted again and the counters are left as they were.
	fn probeNormals = (
		local pn = undefined
		local saved = #(statNormals, statNormalsFail, statNormalsExplicit, normalsMs, nrmInfoShown)
		nrmInfoShown = 3
		try (
			pn = box length:10 width:10 height:10
			local tri = snapshotAsMesh pn
			local r = readNormals pn tri "box"
			if (classOf r) == String then logWarn ("3ds Max normals: test on a box failed: " + r)
			else (
				local tb = r[1]
				local cs = r[2]
				local p = r[3]
				local bad = 0
				for f = 1 to tri.numfaces do (
					-- the side's normal from the triangle's corners (the box is not mirrored)
					local fc = getFace tri f
					local v1 = getVert tri (fc.x as integer)
					local fnrm = normalize (cross ((getVert tri (fc.y as integer)) - v1) ((getVert tri (fc.z as integer)) - v1))
					for c = 1 to 3 do (
						local k = cs[(f - 1) * 3 + p[c]]
						if (dot [tb[k * 3 + 1], tb[k * 3 + 2], tb[k * 3 + 3]] fnrm) < 0.999 do bad += 1
					)
				)
				if bad == 0 then logLine ("3ds Max normals: test on a box OK (" + (tri.numfaces as string) + " triangles, " + \
					((tb.count / 3) as string) + " normals, every corner has the normal of its side; " + \
					(try (nrmReader.Info()) catch "?") + ")")
				else logWarn ("3ds Max normals: test on a box: " + (bad as string) + " of " + ((tri.numfaces * 3) as string) + \
					" corners have a wrong normal")
			)
			delete tri
		) catch (
			logWarn ("3ds Max normals: test on a box failed (" + ((getCurrentException()) as string) + ")")
		)
		if pn != undefined and (isValidNode pn) do delete pn
		statNormals = saved[1]
		statNormalsFail = saved[2]
		statNormalsExplicit = saved[3]
		normalsMs = saved[4]
		nrmInfoShown = saved[5]
		true
	),

	-- ── Skin ─────────────────────────────────────────────────────
	-- The Skin modifier Blender keeps as an armature: enabled and the first enabled
	-- modifier under the live run (on top of the stack without one); else undefined.
	fn skinUnder n run = (
		local res = undefined
		local stop = false
		for md in n.modifiers do (
			if not stop do (
				local isOn = try (md.enabled) catch true
				if isOn == true and (findItem run md) == 0 do (
					stop = true
					if (classOf md) == Skin do res = md
				)
			)
		)
		res
	),

	-- The node a Skin bone name stands for; with several nodes of that name, the one the
	-- Skin modifier depends on.
	fn skinBoneNode sk bname = (
		local res = undefined
		if bname != undefined and bname != "" do (
			local cands = try (getNodeByName bname all:true) catch undefined
			if (classOf cands) != Array do (
				local one = try (getNodeByName bname) catch undefined
				cands = if one != undefined then #(one) else #()
			)
			if cands.count == 1 then res = cands[1]
			else (
				for c in cands do (
					if res == undefined and (findItem (refs.dependents c) sk) > 0 do res = c
				)
				if res == undefined and cands.count > 0 do res = cands[1]
			)
		)
		res
	),

	-- a length for the Blender bone: bone length, dummy box, or the object's size
	fn boneLength b = (
		local res = undefined
		if b != undefined do (
			local cls = classOf b
			if cls == BoneGeometry then res = try (b.length) catch undefined
			else if cls == Dummy then (
				local bx = try (b.boxsize) catch undefined
				if bx != undefined do res = amax #(bx.x, bx.y, bx.z)
			)
			if res == undefined do (
				local d = try (b.max - b.min) catch [0, 0, 0]
				res = amax #(d.x, d.y, d.z)
			)
		)
		res
	),

	-- Bones, bind matrices and weights of Skin sk on n (skinOps reads the Skin shown in
	-- the Modify panel). Returns #(bone names, bone nodes, mesh bind matrix, bone bind
	-- matrices, vertex count, weights per vertex, bone indices 0.., weights) or a String.
	fn readSkin n sk = (
		local st = showInModPanel n sk
		local res = undefined
		local err = undefined
		try (
			local nb = skinOps.GetNumberBones sk
			local nvs = skinOps.GetNumberVertices sk
			if nvs == 0 do (
				-- a Skin that was never shown fills on a second evaluation
				modPanel.setCurrentObject sk
				classOf n
				nvs = skinOps.GetNumberVertices sk
			)
			if nb == 0 then res = "no bones"
			else if nvs == 0 then res = "no vertices"
			else (
				local bnames = #()
				local bnodes = #()
				local binds = #()
				for b = 1 to nb do (
					local bname = try (skinOps.GetBoneName sk b 0) catch ""
					if bname == undefined do bname = ""
					local bn = skinBoneNode sk bname
					append bnames bname
					append bnodes bn
					append binds (if bn != undefined then (try (skinUtils.GetBoneBindTM n bn) catch undefined) else undefined)
				)
				local mbind = try (skinUtils.GetMeshBindTM n) catch undefined
				local counts = #()
				local ids = #()
				local wts = #()
				local outside = 0
				local cnt = 2048
				for v = 1 to nvs do (
					cnt -= 1
					if cnt <= 0 do (
						cnt = 2048
						tick ("'" + n.name + "': skin weights " + (v as string) + " / " + (nvs as string))
					)
					local wc = skinOps.GetVertexWeightCount sk v
					local kept = 0
					for j = 1 to wc do (
						local bid = skinOps.GetVertexWeightBoneID sk v j
						local w = skinOps.GetVertexWeight sk v j
						if bid < 1 or bid > nb then outside += 1
						else if w > 0.0 do (
							append ids (bid - 1)
							append wts w
							kept += 1
						)
					)
					append counts kept
				)
				if outside > 0 do logWarn ("'" + n.name + "': " + (outside as string) + \
					" skin weights name a bone outside 1.." + (nb as string) + " (left out)")
				local missing = 0
				for bn in bnodes do (if bn == undefined do missing += 1)
				if missing > 0 do logWarn ("'" + n.name + "': " + (missing as string) + " Skin bones not found by name")
				res = #(bnames, bnodes, mbind, binds, nvs, counts, ids, wts)
			)
		) catch (
			err = getCurrentException()
		)
		restoreShown n st
		if err != undefined do (
			if cancelled do throw "cancelled (Esc)"
			res = "error: " + (err as string)
		)
		res
	),

	-- Frames for the skin check: the export frame and up to 3 frames (every Nth of the
	-- range) where the bones are furthest from their pose at the export frame.
	fn skinCheckFrames bnodes = (
		local res = #(exportFrame as float)
		local fEnd = (animationRange.end.frame) as integer
		local cands = #()
		local f = (animationRange.start.frame) as integer
		while f <= fEnd do (
			append cands (f as float)
			f += optVerifyStep
		)
		appendIfUnique cands (fEnd as float)
		local scores = #()
		for c in cands do (
			local s = 0.0
			for b in bnodes where b != undefined do (
				local m0 = at time exportFrame b.transform
				local m1 = at time c b.transform
				local sz = 1.0 + (length m0.row4)
				s += (distance m0.row1 m1.row1) + (distance m0.row2 m1.row2) + (distance m0.row3 m1.row3) + \
					(distance m0.row4 m1.row4) / sz
			)
			append scores s
		)
		for k = 1 to 3 do (
			local best = 0
			local bs = 1e-5
			for i = 1 to cands.count do (
				if scores[i] > bs and (findItem res cands[i]) == 0 do (
					best = i
					bs = scores[i]
				)
			)
			if best > 0 do (
				append res cands[best]
				scores[best] = -1.0
			)
		)
		res
	),

	-- The skinned mesh (world space, the live run off) at the check frames, with the
	-- matrices of the mesh node and of the bones there: blobs + JSON items.
	fn skinChecks n sd what = (
		local items = #()
		local bnodes = sd[2]
		for f in (skinCheckFrames bnodes) do (
			local ft = try (at time f (snapshotAsMesh n)) catch undefined
			if (classOf ft) == TriMesh do (
				if ft.numverts == sd[5] then (
					local vrec = writeFinalVerts ft (matrix3 1) (what + " skin check")
					local bw = #()
					local bo = #()
					for b in bnodes do (
						if b == undefined then (
							append bw "null"
							append bo "null"
						) else (
							append bw (jM3p (at time f b.transform))
							append bo (jM3p (at time f b.objectTransform))
						)
					)
					append items (jObj #((kv "frame" (jNumP f)), (kv "verts" vrec), \
						(kv "mesh" (jM3p (at time f n.transform))), (kv "mesh_obj" (jM3p (at time f n.objectTransform))), \
						(kv "bones" (jArr bw)), (kv "bones_obj" (jArr bo))))
				) else logWarn (what + ": skin check at frame " + (f as string) + " skipped (" + \
					(ft.numverts as string) + " vertices, the Skin " + (sd[5] as string) + ")")
				delete ft
			)
		)
		items
	),

	-- The Skin record (JSON); the weights go to the .bin: the count of every vertex, then
	-- the bone indices (0..), then the weights.
	fn skinJson sk sd checkItems = (
		local bs = binStream
		local wAt = ftell bs
		for c in sd[6] do WriteLong bs c #signed
		for c in sd[7] do WriteLong bs c #signed
		for w in sd[8] do WriteFloat bs w
		local bnames = sd[1]
		local bnodes = sd[2]
		local binds = sd[4]
		local bItems = #()
		for b = 1 to bnames.count do (
			local bn = bnodes[b]
			local fields = #((kv "name" (jStr bnames[b])))
			if bn != undefined do (
				append fields (kv "h" (jInt bn.handle))
				append fields (kv "class" (jStr ((classOf bn) as string)))
				local ln = boneLength bn
				if ln != undefined do append fields (kv "len" (jNum ln))
			)
			if binds[b] != undefined do append fields (kv "bind" (jM3p binds[b]))
			append bItems (jObj fields)
		)
		local props = #((kv "name" (jStr sk.name)), \
			(kv "nv" (jInt sd[5])), (kv "pairs" (jInt sd[7].count)), (kv "at" (jInt wAt)), \
			(kv "dq" (jBool (try (sk.enableDQ) catch false))), \
			(kv "back_transform" (jBool (try (sk.backTransform) catch true))), \
			(kv "always_deform" (jBool (try (sk.always_deform) catch true))), \
			(kv "rigid" (jBool (try (sk.rigid_vertices) catch false))), \
			(kv "limit" (jInt (try (sk.bone_Limit) catch 20))), \
			(kv "bones" (jArr bItems)), \
			(kv "check" (jArr checkItems)))
		if sd[3] != undefined do append props (kv "mesh_bind" (jM3p sd[3]))
		jObj props
	),

	-- Mesh of a geometry node in pivot space (the 3ds Max pivot becomes the
	-- Blender origin); returns #(mesh key, live JSON, final JSON, skin JSON) (each
	-- of the last three may be undefined), or undefined. snapshotAsMesh is a
	-- standalone copy of the evaluated mesh (whole stack, space warps too) in
	-- world space; the inverse node matrix takes it to pivot space.
	-- Live run (Shell / TurboSmooth on top): the mesh below it, its parameters and the
	-- final vertices. Skin under the run (or on top): the mesh below the Skin, bones,
	-- weights and the check frames. Otherwise the whole stack, with 3ds Max's normals.
	fn exportMesh n = (
		local run = if optLiveMods then (liveRun n) else #()
		local sk = if optSkin then (skinUnder n run) else undefined
		local shared = if sk == undefined then (sharedMeshKey n) else undefined
		if shared != undefined then (
			statShared += 1
			if shared[3] != undefined do statLive += 1
			#(shared[2], shared[3], shared[4], undefined)
		) else (
			local t0 = timeStamp()
			local what = "'" + n.name + "'"
			local pivTM = inverse n.transform
			local flip = snapshotFlips == true and (isMirrored n.objectTransform)
			local liveTxt = undefined
			local finalTxt = undefined
			local skinTxt = undefined
			local tri = undefined
			local nrm = undefined
			local res = undefined
			-- Skin: bones, bind matrices and weights (Modify panel)
			local sd = undefined
			if optSkin and sk == undefined do (
				local skAny = false
				for md in n.modifiers do (
					if (classOf md) == Skin and (try (md.enabled) catch true) == true do skAny = true
				)
				if skAny do logLine (what + ": its Skin is under other modifiers and is baked (a Skin becomes an " + \
					"armature on top of the stack or right under Shell / TurboSmooth)")
			)
			if sk != undefined do (
				local ts = timeStamp()
				sd = readSkin n sk
				if (classOf sd) == String do (
					logWarn (what + ": Skin not converted (" + sd + "); the skinned mesh is baked as it is at the export frame")
					statSkinFail += 1
					sd = undefined
				)
				skinMs += timeStamp() - ts
			)
			-- the final mesh (whole stack), for the live modifier check in Blender
			if run.count > 0 and optCheckLive do (
				local ft = try (snapshotAsMesh n) catch undefined
				if (classOf ft) == TriMesh do (
					finalTxt = writeFinalVerts ft pivTM what
					delete ft
				)
			)
			-- the run (and the Skin) are switched off only while the mesh below them is read
			local runStates = #()
			for md in run do append runStates md.enabled
			local skinState = if sd != undefined then sk.enabled else undefined
			local checkItems = #()
			local err = undefined
			try (
				for md in run do md.enabled = false
				if sd != undefined do (
					local ts = timeStamp()
					checkItems = skinChecks n sd what
					skinMs += timeStamp() - ts
					sk.enabled = false
				)
				tri = snapshotAsMesh n
				if sd != undefined and (classOf tri) == TriMesh and tri.numverts != sd[5] do (
					logWarn (what + ": the mesh below the Skin has " + (tri.numverts as string) + " vertices, the Skin " + \
						(sd[5] as string) + "; the skinned mesh is baked as it is at the export frame")
					statSkinFail += 1
					sd = undefined
					sk.enabled = skinState
					skinState = undefined
					delete tri
					tri = snapshotAsMesh n
				)
				if optNormals and run.count == 0 and (classOf tri) == TriMesh do nrm = readNormals n tri what
			) catch (
				err = getCurrentException()
			)
			for k = 1 to run.count do (try (run[k].enabled = runStates[k]) catch ())
			if skinState != undefined do (try (sk.enabled = skinState) catch ())
			if err != undefined do (
				if cancelled do throw "cancelled (Esc)"
				throw (err as string)
			)
			if run.count > 0 do (
				liveTxt = liveJson run
				statLive += 1
				statLiveMods += run.count
			)
			if (classOf nrm) == String do (
				if optVerboseLog or statNormalsFail <= 10 do logLine (what + ": no 3ds Max normals (" + nrm + \
					"); Blender shades it from the smoothing groups")
				nrm = undefined
			)
			if (classOf tri) == TriMesh do (
				meshCount += 1
				local meshKey = "m" + (meshCount as string)
				local nmaps = writeMeshBlob meshKey tri pivTM flip what nrm
				local nv = tri.numverts
				local nf = tri.numfaces
				delete tri
				if sd != undefined do (
					skinTxt = skinJson sk sd checkItems
					statSkins += 1
				)
				if sk == undefined do rememberShared n meshKey liveTxt finalTxt
				local ms = timeStamp() - t0
				if ms > 0 do meshMs += ms
				if ms > 1000 or ms < 0 or optVerboseLog or sd != undefined do logLine ("mesh " + what + ": " + (nv as string) + \
					" vertices, " + (nf as string) + " triangles, " + (nmaps as string) + " map channels" + \
					(if nrm != undefined then (", " + ((nrm[1].count / 3) as string) + " normals" + \
						(if nrm[4] > 0 then (" (" + (nrm[4] as string) + " explicit)") else "")) else "") + \
					(if run.count > 0 then (", " + (run.count as string) + " live modifier(s) on top") else "") + \
					(if sd != undefined then (", Skin: " + (sd[1].count as string) + " bones, " + (sd[7].count as string) + \
						" weights, " + (checkItems.count as string) + " check frames") else "") + ", " + \
					(substituteString (formattedPrint (ms / 1000.0) format:".1f") "," ".") + " s")
				res = #(meshKey, liveTxt, finalTxt, skinTxt)
			)
			res
		)
	),

	-- ── splines ──────────────────────────────────────────────────
	fn knotJson src s k inv = (
		local p = (in coordsys world (getKnotPoint src s k)) * inv
		local vIn = (in coordsys world (getInVec src s k)) * inv
		local vOut = (in coordsys world (getOutVec src s k)) * inv
		local kt = try ((getKnotType src s k) as string) catch "corner"
		"[" + (jNumP p.x) + "," + (jNumP p.y) + "," + (jNumP p.z) + "," + \
			(jNumP vIn.x) + "," + (jNumP vIn.y) + "," + (jNumP vIn.z) + "," + \
			(jNumP vOut.x) + "," + (jNumP vOut.y) + "," + (jNumP vOut.z) + "," + (jStr kt) + "]"
	),

	-- Splines in pivot space. Shapes that are not plain editable splines
	-- (primitives, modifiers) are read from a temporary converted copy.
	fn shapeJson n = (
		local src = n
		local tmp = undefined
		local cls = classOf n
		local direct = (cls == SplineShape or cls == line) and n.modifiers.count == 0
		if not direct do (
			tmp = copy n
			convertToSplineShape tmp
			src = tmp
		)
		local inv = inverse n.transform
		local splinesOut = #()
		local res = undefined
		local errMsg = undefined
		try (
			for s = 1 to (numSplines src) do (
				local ks = #()
				for k = 1 to (numKnots src s) do append ks (knotJson src s k inv)
				local lineSegs = #()
				for g = 1 to (numSegments src s) do (
					if (getSegmentType src s g) == #line do append lineSegs (jInt (g - 1))
				)
				append splinesOut (jObj #((kv "closed" (jBool (isClosed src s))), (kv "knots" (jArr ks)), (kv "lines" (jArr lineSegs))))
			)
		) catch (
			errMsg = getCurrentException()
		)
		if tmp != undefined do (try (delete tmp) catch ())
		if errMsg != undefined then (
			logWarn ("'" + n.name + "': splines not read: " + (errMsg as string))
			undefined
		) else (
			local b = n.baseObject
			local f = #((kv "splines" (jArr splinesOut)))
			local stp = try (b.steps) catch undefined
			if stp != undefined do append f (kv "steps" (jInt stp))
			local rnd = try (b.render_renderable) catch false
			local vpt = try (b.render_displayRenderMesh) catch false
			if rnd == true or vpt == true do (
				local r = #((kv "renderable" (jBool rnd)), (kv "viewport" (jBool vpt)))
				local th = try (b.render_thickness) catch undefined
				if th != undefined do append r (kv "thickness" (jNum th))
				local sd = try (b.render_sides) catch undefined
				if sd != undefined do append r (kv "sides" (jInt sd))
				local ang = try (b.render_angle) catch undefined
				if ang != undefined do append r (kv "angle" (jNum ang))
				local rect = try (b.render_rectangular) catch false
				append r (kv "rectangular" (jBool rect))
				if rect == true do (
					append r (kv "width" (jNum (try (b.render_width) catch 0.0)))
					append r (kv "length" (jNum (try (b.render_length) catch 0.0)))
				)
				append f (kv "render" (jObj r))
			)
			statShapes += 1
			jObj f
		)
	),

	-- ── materials ────────────────────────────────────────────────
	fn matKey mt = ("a" + (jInt (getHandleByAnim mt))),

	fn queueMat mt = (
		if mt != undefined do (
			local mk = matKey mt
			if not (hasDictValue matQueued mk) do (
				matQueued[mk] = true
				append matQueue mt
			)
		)
	),

	fn firstProp obj propNames = (
		local res = undefined
		for pn in propNames do (
			if res == undefined and (isProperty obj pn) do res = try (getProperty obj pn) catch undefined
		)
		res
	),

	fn bitmapFile tm = (
		local res = undefined
		if tm != undefined do (
			if (classOf tm) == Bitmaptexture then res = try (tm.filename) catch undefined
			else (
				-- the first bitmap inside a map tree (one level), e.g. a color correction
				local ns = try (tm.numSubs) catch 0
				for i = 1 to ns do (
					if res == undefined do (
						local sa = try (getSubAnim tm i) catch undefined
						local sv = if sa != undefined then (try (sa.value) catch undefined) else undefined
						if (classOf sv) == Bitmaptexture do res = try (sv.filename) catch undefined
					)
				)
			)
		)
		res
	),

	fn matJson mt = (
		local f = #((kv "name" (jStr mt.name)), (kv "class" (jStr ((classOf mt) as string))))
		if (classOf mt) == Multimaterial then (
			local ids = try (mt.materialIDList) catch #()
			local subs = try (mt.materialList) catch #()
			local slotNames = try (mt.names) catch #()
			local items = #()
			for i = 1 to subs.count do (
				local sm = subs[i]
				local sid = if i <= ids.count then ids[i] else i
				local snm = if i <= slotNames.count then slotNames[i] else ""
				local slotOn = try (mt.mapEnabled[i]) catch true
				if sm != undefined and slotOn != false then (
					queueMat sm
					append items ("[" + (jInt sid) + "," + (jStr (matKey sm)) + "," + (jStr snm) + "]")
				) else append items ("[" + (jInt sid) + ",null," + (jStr snm) + "]")
			)
			append f (kv "multi" (jArr items))
		) else (
			local col = firstProp mt #(#base_color, #baseColor, #diffuse, #diffuseColor, #Diffuse_Color, #color, #albedo, #base_color_color)
			if (classOf col) == Color do append f (kv "color" (jColor01 col))
			if (classOf col) == Point4 do append f (kv "color" ("[" + (jNum col.x) + "," + (jNum col.y) + "," + (jNum col.z) + "]"))
			local metal = firstProp mt #(#metalness, #metallic, #metalness_value)
			if (classOf metal) == Float or (classOf metal) == Integer do append f (kv "metal" (jNum metal))
			local rough = firstProp mt #(#roughness, #roughness_value)
			if (classOf rough) == Float or (classOf rough) == Integer do (
				local inv = try (mt.roughness_inv) catch false
				append f (kv "rough" (jNum (if inv == true then (1.0 - rough) else rough)))
			)
			if (classOf mt) == Standardmaterial do (
				local gl = try (mt.glossiness) catch undefined
				if gl != undefined do append f (kv "rough" (jNum (1.0 - gl / 100.0)))
				local op = try (mt.opacity) catch undefined
				if op != undefined do append f (kv "opacity" (jNum (op / 100.0)))
			)
			local tr = firstProp mt #(#transparency)
			if (classOf tr) == Float do append f (kv "opacity" (jNum (1.0 - tr)))
			local cmap = firstProp mt #(#base_color_map, #baseColor_map, #diffuseMap, #diffuse_map, #texmap_diffuse, #base_color_texmap)
			local cfile = bitmapFile cmap
			local maps = #()
			if cfile != undefined do append maps (kv "color" (jStr cfile))
			local nfile = bitmapFile (firstProp mt #(#bump_map, #norm_map, #bumpMap, #normal_map))
			if nfile != undefined do append maps (kv "normal" (jStr nfile))
			local rfile = bitmapFile (firstProp mt #(#roughness_map, #glossinessMap, #roughness_texmap))
			if rfile != undefined do append maps (kv "rough" (jStr rfile))
			local mfile = bitmapFile (firstProp mt #(#metalness_map, #metallic_map))
			if mfile != undefined do append maps (kv "metal" (jStr mfile))
			if maps.count > 0 do append f (kv "maps" (jObj maps))
		)
		jObj f
	),

	fn materialsJson = (
		matItems = #()
		local i = 1
		while i <= matQueue.count do (
			local mt = matQueue[i]
			local mk = matKey mt
			try (
				append matItems (kv mk (matJson mt))
			) catch (
				local ex = getCurrentException()
				logWarn ("material '" + (try (mt.name) catch "?") + "': " + (ex as string))
				append matItems (kv mk (jObj #((kv "name" (jStr (try (mt.name) catch "?"))), (kv "class" (jStr ((classOf mt) as string))))))
			)
			i += 1
		)
		jObj matItems
	),

	-- ── animation ────────────────────────────────────────────────
	-- true when c or a sub-controller (6 levels) has keys or is procedural
	fn ctrlAnimated c depth = (
		local res = false
		if c != undefined do (
			local nk = try (numKeys c) catch -1
			if (classOf nk) == Integer and nk > 0 do res = true
			if not res and (isProcName ((classOf c) as string)) do res = true
			if not res and depth < 6 do (
				local ns = try (c.numSubs) catch 0
				for i = 1 to ns do (
					if not res do (
						local sa = try (getSubAnim c i) catch undefined
						local sc = if sa != undefined then (try (sa.controller) catch undefined) else undefined
						if sc != undefined and (MaxToBlender.ctrlAnimated sc (depth + 1)) do res = true
					)
				)
			)
		)
		res
	),

	fn isNativeFloat c = (
		local cc = classOf c
		cc == bezier_float or cc == linear_float
	),

	-- Axis (0 = X, 1 = Y, 2 = Z) of sub-controller i of a Position XYZ / Euler XYZ /
	-- Scale XYZ controller, read from its name (X_Position, Y_Rotation, Z_Scale ...);
	-- -1 when the name says nothing.
	fn subAxis c i = (
		local nm = try ((getSubAnimName c i) as string) catch ""
		local ax = -1
		if nm.count >= 2 and nm[2] == "_" do (
			local ch = toUpper nm[1]
			if ch == "X" then ax = 0
			else if ch == "Y" then ax = 1
			else if ch == "Z" then ax = 2
		)
		ax
	),

	-- Axes of sub-controllers 1..3. An Euler XYZ controller lists them in its axis
	-- order (ZXY: Z, X, Y), so their position is not their axis: the names decide.
	-- Without usable names: Euler XYZ by its axis order, the others X, Y, Z.
	fn subAxes c ord = (
		local res = #()
		for i = 1 to 3 do append res (subAxis c i)
		local named = (findItem res 0) > 0 and (findItem res 1) > 0 and (findItem res 2) > 0
		if named then (
			if ord != undefined do statEulerNamed += 1
		) else (
			res = #(0, 1, 2)
			if ord != undefined do (
				local letters = axisOrderName ord
				if letters.count == 3 do (
					for i = 1 to 3 do res[i] = (findString "XYZ" letters[i]) - 1
				)
				statEulerByOrder += 1
			)
			logWarn ("sub-controllers of a " + ((classOf c) as string) + " without X/Y/Z names (" + \
				(try ((getSubAnimName c 1) as string) catch "?") + ", ...): axes taken from " + \
				(if ord != undefined then "the axis order" else "their position"))
		)
		res
	),

	-- Do the PRS controller values rebuild the local matrix? Not with a scale
	-- axis (scaled or mirrored in world / parent coordinates): Blender's
	-- location / Euler / scale keys can't hold that, so such a node is baked.
	fn prsMatches n = (
		local res = true
		try (
			local sv = at time exportFrame (n.scale.controller.value)
			local qv = at time exportFrame (n.rotation.controller.value)
			local pv = at time exportFrame (n.pos.controller.value)
			local lt = at time exportFrame (localTM n)
			local sz = 1.0 + (length lt.row1) + (length lt.row2) + (length lt.row3)
			local tTol = 1e-3 * (1.0 + (length lt.row4))
			res = false
			-- the quaternion as 3ds Max turns it into a matrix, and its inverse: whichever
			-- convention MAXScript uses, a node without a scale axis matches one of them
			local qs = #(qv, (inverse qv))
			for k = 1 to 2 do (
				if not res do (
					local cand = (scaleMatrix sv) * (qs[k] as matrix3) * (transMatrix pv)
					local dr = (distance cand.row1 lt.row1) + (distance cand.row2 lt.row2) + (distance cand.row3 lt.row3)
					if dr <= 1e-4 * sz and (distance cand.row4 lt.row4) <= tTol do (
						res = true
						if k == 1 then prsQuatDirect += 1 else prsQuatInverse += 1
					)
				)
			)
		) catch (res = true)
		res
	),

	-- #(mode, reason, specs); mode #static, #keys or #bake;
	-- spec = #(controller, channel, index, unit, component 0..3)
	fn animPlan n = (
		local specs = #()
		local mode = #static
		local reason = ""
		local tc = n.controller
		if (ctrlAnimated tc 0) do (
			if (classOf tc) != prs then (
				mode = #bake
				reason = "transform controller " + ((classOf tc) as string)
			) else (
				mode = #keys
				local inh = try (getInheritanceFlags n) catch #{1..9}
				if inh.numberSet < 9 do (
					mode = #bake
					reason = "partial link inheritance"
				)
				local parts = #(#(n.position.controller, "location", "length"), \
					#(n.rotation.controller, "rotation_euler", "deg"), \
					#(n.scale.controller, "scale", "percent"))
				if mode == #keys and not (prsMatches n) do (
					mode = #bake
					reason = "scale axis: PRS values do not rebuild the local matrix"
					statScaleAxis += 1
				)
				for p in parts do (
					local c = p[1]
					if mode == #keys and (ctrlAnimated c 0) do (
						local cc = classOf c
						if cc == Position_XYZ or cc == Euler_XYZ or cc == ScaleXYZ then (
							local ordOk = true
							local ord = undefined
							if cc == Euler_XYZ do (
								ord = try (c.axisOrder) catch 0
								if ord < 1 or ord > 6 do (
									ordOk = false
									mode = #bake
									reason = "Euler order " + (axisOrderName ord)
								)
							)
							if ordOk do (
								-- the axis of each sub-controller from its name, not its position
								local axes = subAxes c ord
								for i = 1 to 3 do (
									local sub = try ((getSubAnim c i).controller) catch undefined
									if mode == #keys and sub != undefined and (ctrlAnimated sub 0) do (
										if (isNativeFloat sub) then append specs #(sub, p[2], axes[i], p[3], 0)
										else (
											mode = #bake
											reason = p[2] + " " + ("XYZ")[axes[i] + 1] + ": " + ((classOf sub) as string)
										)
									)
								)
							)
						)
						else if cc == bezier_position or cc == linear_position then (
							for i = 1 to 3 do append specs #(c, "location", i - 1, "length", i)
						)
						else if cc == bezier_scale or cc == linear_scale then (
							for i = 1 to 3 do append specs #(c, "scale", i - 1, "fraction", i)
						)
						else (
							mode = #bake
							reason = p[2] + ": " + (cc as string)
						)
					)
				)
			)
		)
		#(mode, reason, specs)
	),

	fn sampleAt c ci tf = (
		local v = at time tf (c.value)
		comp3 v ci
	),

	-- One F-curve worth of data: raw keys plus sampled values.
	fn trackJson spec keyTimes = (
		local c = spec[1]
		local ci = spec[5]
		local ks = c.keys
		local nk = ks.count
		local keyItems = #()
		local kvItems = #()
		local segItems = #()
		local times = #()
		for i = 1 to nk do (
			local k = ks[i]
			local tf = k.time.frame
			append times tf
			appendIfUnique keyTimes tf
			local rawV = comp3 (try (k.value) catch undefined) ci
			local inT = try ((k.inTangentType) as string) catch "linear"
			local outT = try ((k.outTangentType) as string) catch "linear"
			local inTan = comp3 (try (k.inTangent) catch undefined) ci
			local outTan = comp3 (try (k.outTangent) catch undefined) ci
			local inLen = comp3 (try (k.inTangentLength) catch undefined) ci
			local outLen = comp3 (try (k.outTangentLength) catch undefined) ci
			append keyItems ("[" + (jNumP tf) + "," + (jNumP rawV) + "," + (jStr inT) + "," + (jStr outT) + "," + \
				(jNumP inTan) + "," + (jNumP outTan) + "," + (jNumP inLen) + "," + (jNumP outLen) + "]")
			append kvItems (jNumP (sampleAt c ci tf))
		)
		for i = 1 to nk - 1 do (
			local t0 = times[i]
			local dt = times[i + 1] - t0
			append segItems ("[" + (jNumP (sampleAt c ci (t0 + dt * 0.25))) + "," + \
				(jNumP (sampleAt c ci (t0 + dt * 0.5))) + "," + (jNumP (sampleAt c ci (t0 + dt * 0.75))) + "]")
		)
		statTracks += 1
		jObj #((kv "ch" (jStr spec[2])), (kv "i" (jInt spec[3])), (kv "unit" (jStr spec[4])), \
			(kv "ctrl" (jStr ((classOf c) as string))), (kv "keys" (jArr keyItems)), \
			(kv "kv" (jArr kvItems)), (kv "seg" (jArr segItems)))
	),

	fn rangeFrames = (
		local f0 = (animationRange.start.frame) as integer
		local f1 = (animationRange.end.frame) as integer
		#(f0, f1)
	),

	-- local matrix at every frame of the animation range
	fn bakeJson n = (
		local fr = rangeFrames()
		local f0 = fr[1]
		local f1 = fr[2]
		if f1 - f0 + 1 > optMaxBakeFrames do (
			logWarn ("'" + n.name + "': bake limited to " + (optMaxBakeFrames as string) + " frames")
			f1 = f0 + optMaxBakeFrames - 1
		)
		local items = #()
		for f = f0 to f1 do append items (jM3p (at time f (localTM n)))
		statBaked += 1
		jObj #((kv "start" (jInt f0)), (kv "count" (jInt (f1 - f0 + 1))), (kv "local" (jArr items)))
	),

	-- world matrices for the Blender-side check: every Nth frame of the
	-- range, its ends and every key frame
	fn verifyJson n keyTimes = (
		local fr = rangeFrames()
		local frames = #()
		local f = fr[1]
		while f <= fr[2] do (
			append frames (f as float)
			f += optVerifyStep
		)
		appendIfUnique frames (fr[2] as float)
		for t in keyTimes do appendIfUnique frames t
		sort frames
		local fItems = #()
		local wItems = #()
		local cnt = amin #(frames.count, 400)
		for i = 1 to cnt do (
			append fItems (jNumP frames[i])
			append wItems (jM3p (at time frames[i] n.transform))
		)
		jObj #((kv "frames" (jArr fItems)), (kv "world" (jArr wItems)))
	),

	fn prsJson n = (
		local res = undefined
		if (classOf n.controller) == prs do (
			-- the controller values (parent space), as the scene scan reads them
			local p = try (at time exportFrame (n.pos.controller.value)) catch undefined
			local s = try (at time exportFrame (n.scale.controller.value)) catch undefined
			local q = try (at time exportFrame (n.rotation.controller.value)) catch undefined
			local parts = #()
			if (classOf p) == Point3 do append parts (kv "pos" (jP3p p))
			if (classOf s) == Point3 do append parts (kv "scale" (jP3p s))
			if (classOf q) == Quat do append parts (kv "quat" (jQuatP q))
			local rc = n.rotation.controller
			if (classOf rc) == Euler_XYZ do (
				local ord = try (rc.axisOrder) catch 0
				local ex = try (at time exportFrame rc.X_Rotation) catch undefined
				local ey = try (at time exportFrame rc.Y_Rotation) catch undefined
				local ez = try (at time exportFrame rc.Z_Rotation) catch undefined
				local okE = (classOf ex) == Float and (classOf ey) == Float and (classOf ez) == Float
				if ord >= 1 and ord <= 6 and okE do (
					append parts (kv "order" (jStr (axisOrderName ord)))
					append parts (kv "euler" ("[" + (jNumP ex) + "," + (jNumP ey) + "," + (jNumP ez) + "]"))
				)
			)
			res = jObj parts
		)
		res
	),

	-- ── one node ─────────────────────────────────────────────────
	fn nodeJson n = (
		local f = #()
		curStage = "head"
		tick ("Object " + (curIndex as string) + " of " + (nodeTotal as string) + ": " + n.name + "   (Esc cancels)")
		append f (kv "h" (jInt n.handle))
		append f (kv "name" (jStr n.name))
		local par = n.parent
		append f (kv "parent" (if par != undefined then (jInt par.handle) else "-1"))
		local layName = try (n.layer.name) catch ""
		append f (kv "layer" (if (hasDictValue layerIdx layName) then (jInt layerIdx[layName]) else "-1"))
		local kind = nodeKind n
		append f (kv "kind" (jStr kind))
		append f (kv "class" (jStr ((classOf n) as string)))
		append f (kv "base" (jStr ((classOf n.baseObject) as string)))
		if (isGroupHead n) do append f (kv "group_head" "true")
		if (isOpenGroupHead n) do append f (kv "group_open" "true")
		if (isGroupMember n) do append f (kv "group_member" "true")
		if n.isHidden do append f (kv "hidden" "true")
		if n.isFrozen do append f (kv "frozen" "true")
		if not n.renderable do append f (kv "renderable" "false")
		append f (kv "wire" (jColor01 n.wirecolor))
		local ub = try (getUserPropBuffer n) catch ""
		if ub != undefined and ub != "" do append f (kv "props" (jStr ub))

		curStage = "transform"
		local lt = at time exportFrame (localTM n)
		append f (kv "local" (jM3p lt))
		append f (kv "world" (jM3p (at time exportFrame n.transform)))
		if (shearOf lt) > 1e-4 do append f (kv "shear" "true")
		local prsTxt = prsJson n
		if prsTxt != undefined do append f (kv "prs" prsTxt)
		local inh = try (getInheritanceFlags n) catch #{1..9}
		if inh.numberSet < 9 do (
			local bits = #()
			for i = 1 to 9 do append bits (jBool inh[i])
			append f (kv "inherit" (jArr bits))
		)
		local offTM = n.objectTransform * (inverse n.transform)
		if not (isIdentityTM offTM) do append f (kv "offset" (jM3p offTM))

		curStage = "object (" + kind + ")"
		if kind == "mesh" then (
			local mr = exportMesh n
			if mr != undefined then (
				append f (kv "mesh" (jStr mr[1]))
				if mr[2] != undefined do append f (kv "live" mr[2])
				if mr[3] != undefined do append f (kv "final" mr[3])
				if mr[4] != undefined do append f (kv "skin" mr[4])
				statMeshes += 1
			) else logWarn ("'" + n.name + "': no mesh")
			append f (kv "wbox" ("[" + (jP3p n.min) + "," + (jP3p n.max) + "]"))
		)
		else if kind == "shape" then (
			local sj = shapeJson n
			if sj != undefined do append f (kv "shape" sj)
			append f (kv "wbox" ("[" + (jP3p n.min) + "," + (jP3p n.max) + "]"))
		)
		else if kind == "dummy" then (
			local bx = try (n.boxsize) catch undefined
			if bx != undefined do append f (kv "box" (jP3p bx))
			statEmpties += 1
		)
		else if kind == "point" then (
			local sz = try (n.size) catch undefined
			if sz != undefined do append f (kv "size" (jNum sz))
			statEmpties += 1
		)
		else statEmpties += 1

		curStage = "material"
		local mt = n.material
		if mt != undefined and optMaterials do (
			append f (kv "mtl" (jStr (matKey mt)))
			queueMat mt
		)

		curStage = "modifiers"
		local mods = n.modifiers
		if mods.count > 0 do (
			local ml = #()
			for k = 1 to mods.count do (
				local md = mods[k]
				local modOn = try (md.enabled) catch true
				append ml ("[" + (jStr md.name) + "," + (jStr ((classOf md) as string)) + "," + (jBool modOn) + "]")
			)
			append f (kv "mods" (jArr ml))
		)

		if optAnimation do (
			curStage = "animation plan"
			local plan = animPlan n
			if plan[1] != #static do (
				local keyTimes = #()
				local a = #((kv "mode" (jStr (plan[1] as string))))
				if plan[2] != "" do append a (kv "reason" (jStr plan[2]))
				if plan[1] == #keys then (
					curStage = "animation keys"
					local tr = #()
					for spec in plan[3] do append tr (trackJson spec keyTimes)
					append a (kv "tracks" (jArr tr))
					local ord = try (n.rotation.controller.axisOrder) catch 1
					append a (kv "order" (jStr (axisOrderName ord)))
					statKeyed += 1
				) else (
					curStage = "animation bake"
					append a (kv "bake" (bakeJson n))
					logLine ("'" + n.name + "': baked (" + plan[2] + ")")
				)
				curStage = "animation verify"
				append a (kv "verify" (verifyJson n keyTimes))
				append f (kv "anim" (jObj a))
			)
		)
		jObj f
	),

	-- ── whole export ─────────────────────────────────────────────
	fn exportBody jsonPath = (
		local t0 = timeStamp()
		cancelled = false
		meshItems = #()
		meshCount = 0
		meshMs = 0
		instSets = Dictionary #string
		lastUiTick = 0
		lastLogTick = timeStamp()
		matQueue = #()
		matQueued = Dictionary #string
		nodeErrors = 0
		warnCount = 0
		statMeshes = 0
		statShared = 0
		statFaces = 0
		statShapes = 0
		statEmpties = 0
		statKeyed = 0
		statBaked = 0
		statTracks = 0
		statScaleAxis = 0
		statLive = 0
		statLiveMods = 0
		statNormals = 0
		statNormalsFail = 0
		statNormalsExplicit = 0
		normalsMs = 0
		nrmReader = undefined
		nrmReaderMsg = ""
		nrmInfoShown = 0
		statSkins = 0
		statSkinFail = 0
		skinMs = 0
		statEulerNamed = 0
		statEulerByOrder = 0
		prsQuatDirect = 0
		prsQuatInverse = 0
		curStage = "start"

		logLine ("3ds Max -> Blender Bridge " + toolVersion + ", 3ds Max " + ((maxVersion())[1] as string) + ", " + localTime)
		logLine ("scene: " + maxFilePath + maxFileName)
		logLine ("output: " + jsonPath)
		logLine ("options: selected_only=" + (optSelectedOnly as string) + " animation=" + (optAnimation as string) + \
			" materials=" + (optMaterials as string) + " verify_step=" + (optVerifyStep as string) + \
			" live_modifiers=" + (optLiveMods as string) + " check_live=" + (optCheckLive as string) + \
			" normals=" + (optNormals as string) + " skin=" + (optSkin as string))
		local cmu = cmPerUnit()
		logLine ("units: " + (units.SystemType as string) + " x " + (units.SystemScale as string) + " = " + (cmu as string) + \
			" cm, fps " + (frameRate as string) + ", range " + (animationRange.start.frame as string) + " - " + (animationRange.end.frame as string))

		makeDir (getFilenamePath jsonPath) all:true
		binPath = (getFilenamePath jsonPath) + (getFilenameFile jsonPath) + ".bin"
		binStream = fopen binPath "wb"
		if binStream == undefined do throw ("cannot write " + binPath)
		WriteString binStream "M2BBIN1"
		snapshotFlips = probeSnapshot()
		if optNormals do (
			curStage = "normals reader"
			local rd = try (normalsReader()) catch ("error: " + ((getCurrentException()) as string))
			if (classOf rd) == String then (
				nrmReaderMsg = rd
				logWarn ("3ds Max normals: no reader (" + rd + "); Blender shades the meshes from their smoothing groups")
			) else (
				nrmReader = rd
				probeNormals()
			)
		)

		curStage = "layers"
		local layersTxt = layersJson()
		local nodes = collectNodes optSelectedOnly
		logLine ("nodes to export: " + (nodes.count as string))
		exportFrame = animationRange.start.frame
		nodeTotal = nodes.count
		local items = #()
		for i = 1 to nodes.count do (
			if not cancelled do (
				local n = nodes[i]
				curIndex = i
				if optVerboseLog do logLine ("node " + (i as string) + "/" + (nodes.count as string) + " '" + n.name + "'")
				try (
					append items (nodeJson n)
				) catch (
					local ex = getCurrentException()
					if cancelled or (matchPattern (ex as string) pattern:"*interrupt*") then (
						cancelled = true
					) else (
						local st = try (getCurrentExceptionStackTrace()) catch ""
						nodeErrors += 1
						local nm = try (n.name) catch "?"
						logError ("node '" + nm + "' at " + curStage) ex (if nodeErrors <= 20 then st else "") toListener:(nodeErrors <= 20)
						-- a minimal record keeps the hierarchy intact
						local lt = try (localTM n) catch (matrix3 1)
						append items (jObj #((kv "h" (jInt n.handle)), (kv "name" (jStr nm)), \
							(kv "parent" (if n.parent != undefined then (jInt n.parent.handle) else "-1")), \
							(kv "kind" (jStr "other")), (kv "local" (jM3p lt)), (kv "error" (jStr (ex as string)))))
					)
				)
				if (mod i 50) == 0 do gc light:true
			)
		)
		fclose binStream
		binStream = undefined
		if cancelled then (
			logLine ("cancelled (Esc) at object " + (curIndex as string) + " of " + (nodes.count as string) + ", step " + curStage) toListener:true
			try (deleteFile binPath) catch ()
			"cancelled"
		) else (
			logLine ("nodes done: " + (nodes.count as string) + ", errors: " + (nodeErrors as string) + ", meshes written: " + \
				(meshCount as string) + " (" + (statShared as string) + " instances share them), triangles: " + (statFaces as string) + \
				", mesh time " + (substituteString (formattedPrint (meshMs / 1000.0) format:".1f") "," ".") + " s")
			logLine ("live modifiers: " + (statLive as string) + " objects keep " + (statLiveMods as string) + \
				" Shell / TurboSmooth modifiers live (top of the stack)")
			logLine ("3ds Max normals: " + (statNormals as string) + " meshes read (" + (statNormalsExplicit as string) + \
				" of them with explicit normals), " + (statNormalsFail as string) + " without (smoothing groups), " + \
				(substituteString (formattedPrint (normalsMs / 1000.0) format:".1f") "," ".") + " s")
			logLine ("skin: " + (statSkins as string) + " Skin modifiers sent as armatures, " + (statSkinFail as string) + \
				" baked, " + (substituteString (formattedPrint (skinMs / 1000.0) format:".1f") "," ".") + " s")
			logLine ("Euler keys: " + (statEulerNamed as string) + " animated Euler XYZ controllers with X/Y/Z sub-controllers " + \
				"found by name, " + (statEulerByOrder as string) + " by the axis order")
			logLine ("PRS check of keyed nodes: " + (prsQuatDirect as string) + " rebuilt with the rotation quaternion as a matrix, " + \
				(prsQuatInverse as string) + " with its inverse, " + (statScaleAxis as string) + " baked (scale axis)")
			curStage = "materials"
			local matsTxt = "{}"
			if optMaterials do matsTxt = materialsJson()
			curStage = "document"
			local fr = rangeFrames()
			local doc = jObj #( \
				(kv "format" (jStr "max2blender")), \
				(kv "version" (jInt formatVersion)), \
				(kv "generator" (jStr ("MaxToBlenderBridge " + toolVersion))), \
				(kv "max_version" (jInt ((maxVersion())[1]))), \
				(kv "file" (jStr maxFileName)), \
				(kv "exported" (jStr localTime)), \
				(kv "bin" (jStr (filenameFromPath binPath))), \
				(kv "units" (jObj #((kv "system" (jStr (units.SystemType as string))), (kv "cm_per_unit" (jNumP cmu))))), \
				(kv "time" (jObj #((kv "fps" (jNum frameRate)), (kv "ticks_per_frame" (jInt ticksPerFrame)), \
					(kv "start" (jInt fr[1])), (kv "end" (jInt fr[2])), (kv "frame" (jNumP exportFrame))))), \
				(kv "options" (jObj #((kv "selected_only" (jBool optSelectedOnly)), (kv "animation" (jBool optAnimation)), \
					(kv "live_modifiers" (jBool optLiveMods)), (kv "check_live" (jBool optCheckLive)), \
					(kv "normals" (jBool optNormals)), (kv "skin" (jBool optSkin)), \
					(kv "materials" (jBool optMaterials)), (kv "verify_step" (jInt optVerifyStep))))), \
				(kv "stats" (jObj #((kv "nodes" (jInt nodes.count)), (kv "errors" (jInt nodeErrors)), \
					(kv "warnings" (jInt warnCount)), (kv "meshes" (jInt meshCount)), (kv "shared" (jInt statShared)), \
					(kv "triangles" (jInt statFaces)), (kv "shapes" (jInt statShapes)), (kv "empties" (jInt statEmpties)), \
					(kv "keyed_nodes" (jInt statKeyed)), (kv "baked_nodes" (jInt statBaked)), (kv "tracks" (jInt statTracks)), (kv "scale_axis_baked" (jInt statScaleAxis)), \
					(kv "snapshot_reverses_mirrored" (jBool snapshotFlips)), (kv "live_objects" (jInt statLive)), \
					(kv "live_modifiers" (jInt statLiveMods)), (kv "normals" (jInt statNormals)), \
					(kv "normals_missing" (jInt statNormalsFail)), (kv "normals_explicit" (jInt statNormalsExplicit)), \
					(kv "skins" (jInt statSkins)), \
					(kv "skins_baked" (jInt statSkinFail))))), \
				(kv "layers" layersTxt), \
				(kv "materials" matsTxt), \
				(kv "meshes" (jObj meshItems)), \
				(kv "nodes" (jArr items)))
			-- control characters other than tab / newline would make the JSON invalid
			doc = (dotNetClass "System.Text.RegularExpressions.Regex").Replace doc "[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F]" ""
			writeText jsonPath doc
			local secs = (timeStamp() - t0) / 1000.0
			logLine ("written: " + jsonPath + " (" + (doc.count as string) + " characters) and " + binPath)
			-- pointer for "Import latest from 3ds Max" in Blender
			try (
				local latest = pathConfig.appendPath (exchangeDir()) "latest.json"
				makeDir (getFilenamePath latest) all:true
				writeText latest (jObj #((kv "json" (jStr jsonPath)), (kv "exported" (jStr localTime)), \
					(kv "generator" (jStr ("MaxToBlenderBridge " + toolVersion)))))
			) catch (logWarn ("latest.json not written: " + ((getCurrentException()) as string)))
			logLine ("finished: " + (nodes.count as string) + " nodes, " + (nodeErrors as string) + " errors, " + \
				(warnCount as string) + " warnings, " + (formattedPrint secs format:".1f") + " s") toListener:true
			lastResult = (nodes.count as string) + " nodes, " + (meshCount as string) + " meshes, " + (statFaces as string) + \
				" triangles, " + (statLive as string) + " with live modifiers, " + (statSkins as string) + " skins, " + \
				(statKeyed as string) + " keyed + " + (statBaked as string) + " baked, " + (nodeErrors as string) + \
				" errors, " + (substituteString (formattedPrint secs format:".1f") "," ".") + " s"
			"ok"
		)
	),

	fn export jsonPath = (
		if jsonPath == undefined or jsonPath == "" do jsonPath = defaultOutput()
		makeDir (getFilenamePath jsonPath) all:true
		logOpen ((getFilenamePath jsonPath) + (getFilenameFile jsonPath) + ".log")
		local res = undefined
		local oldTime = sliderTime
		-- switching modifiers off and on for a moment must not leave "save changes?"
		local wasDirty = try (getSaveRequired()) catch true
		-- the Skin is read through the Modify panel: selection and panel are put back after
		local oldSel = selection as array
		local oldPanel = try (getCommandPanelTaskMode()) catch #create
		panelUsed = false
		disableSceneRedraw()
		try (
			with undo off (
				sliderTime = animationRange.start
				res = exportBody jsonPath
			)
		) catch (
			local ex = getCurrentException()
			local st = try (getCurrentExceptionStackTrace()) catch ""
			logError ("FATAL at " + curStage) ex st
			if binStream != undefined do (try (fclose binStream) catch ())
			binStream = undefined
			res = "error: " + (ex as string)
			lastResult = res
		)
		sliderTime = oldTime
		if panelUsed do (
			try (
				with undo off (
					local keep = #()
					for s in oldSel do (if isValidNode s do append keep s)
					if keep.count > 0 then select keep else clearSelection()
				)
			) catch ()
			try (setCommandPanelTaskMode oldPanel) catch ()
		)
		enableSceneRedraw()
		if wasDirty == false do (try (setSaveRequired false) catch ())
		logClose()
		res
	)
)

MaxToBlender = MaxToBlenderStruct()


-- ============================================================
--  BRIDGE   Reset and the dialog
-- ============================================================

-- Reset: after an error, a freeze or a hang, both directions back to idle. Scene data is not
-- changed, except that objects an interrupted Replace left renamed get their names back.
-- Returns a short text of what was done.
fn BlenderMaxBridge_Reset = (
	local done = #()
	local b = BlenderMaxBridge
	local wasListening = BlenderMaxBridge_Timer != undefined or (b != undefined and b.listening)
	local scriptFile = if b != undefined then b.scriptFile else ""
	-- the listener: timer off, busy state cleared
	if BlenderMaxBridge_Timer != undefined do (
		try (BlenderMaxBridge_Timer.Stop()) catch ()
		try (dotNet.removeAllEventHandlers BlenderMaxBridge_Timer) catch ()
		try (BlenderMaxBridge_Timer.Dispose()) catch ()
		BlenderMaxBridge_Timer = undefined
	)
	if b != undefined do (
		b.listening = false
		b.busy = false
		b.warnings = #()
		-- a job Blender is waiting for: answered, so Blender stops waiting
		local jobPath = pathConfig.appendPath b.bridgeDir "job.json"
		if b.fileExists jobPath do (
			local job = try (b.parseJSON (b.readText jobPath)) catch undefined
			local jid = if (classOf job) == Dictionary then (b.dget job "id" "") else ""
			b.deleteFileRetry jobPath
			if jid != "" do (
				try (b.writeResult jid "error" "Reset in 3ds Max: the job was withdrawn, nothing was imported." 0.0 0) catch ()
			)
			append done "withdrew the job Blender sent"
		)
		if b.jobInProgress != "" do (
			try (b.writeResult b.jobInProgress "error" "Reset in 3ds Max: the import did not finish." 0.0 0) catch ()
			b.jobInProgress = ""
			append done "told Blender the import did not finish"
		)
		b.deleteFileSafe (pathConfig.appendPath b.bridgeDir "result.json.tmp")
		b.deleteFileSafe (pathConfig.appendPath b.bridgeDir "listener.json")
		local renamed = for o in objects where (matchPattern o.name pattern:"*__BlenderBridgeOld") collect o
		if renamed.count > 0 do (
			try (b.restoreLeftoverNames()) catch ()
			append done ("restored the names of objects an interrupted Replace renamed (" + (renamed.count as string) + ")")
		)
	)
	-- the exporter: files an interrupted export left open
	local m = MaxToBlender
	if m != undefined do (
		if m.binStream != undefined do (
			try (fclose m.binStream) catch ()
			m.binStream = undefined
			append done "closed the .bin file of an interrupted export"
		)
		try (m.logClose()) catch ()
		m.uiFn = undefined
	)
	-- 3ds Max: scene redraw (counted: every disable needs an enable), progress bar, Esc
	local nRedraw = 0
	while nRedraw < 100 and (try (isSceneRedrawDisabled()) catch false) do (
		enableSceneRedraw()
		nRedraw += 1
	)
	if nRedraw > 0 do append done "turned scene redraw back on"
	try (progressEnd()) catch ()
	escapeEnable = true
	-- fresh state, the settings read again, the listener started again if it was on
	BlenderMaxBridge = BlenderMaxBridgeStruct()
	BlenderMaxBridge.setup scriptFile
	MaxToBlender = MaxToBlenderStruct()
	if wasListening do (
		if BlenderMaxBridge.startListening() then append done "listener started again"
		else append done "the listener could not start again (bridge folder?)"
	)
	redrawViews()
	local msg = "Reset done"
	if done.count == 0 then msg += " (all was idle)." else (
		msg += ": "
		for i = 1 to done.count do msg += (if i > 1 then "; " else "") + done[i]
		msg += "."
	)
	format "[Blender <-> 3Ds Max Bridge] %\n" msg
	msg
)

fn BlenderMaxBridge_RefreshUI = (
	if BlenderMaxBridgeTopRollout != undefined and BlenderMaxBridgeTopRollout.open do (
		try (BlenderMaxBridgeTopRollout.refreshState()) catch ()
	)
	if BlenderMaxBridgeRollout != undefined and BlenderMaxBridgeRollout.open do (
		try (BlenderMaxBridgeRollout.refreshState()) catch ()
	)
	if MaxToBlenderRollout != undefined and MaxToBlenderRollout.open do (
		try (MaxToBlenderRollout.showPath()) catch ()
	)
)

rollout BlenderMaxBridgeTopRollout "Bridge folder and Reset" (
	edittext etDir "" width:322 align:#left across:2
	button btnDir "..." width:28 height:18 align:#right tooltip:"Choose the bridge folder"
	label lblDir "The same folder as in the Blender add-on preferences" align:#left width:350
	button btnReset "Reset" width:90 height:26 align:#left across:2 \
		tooltip:"After an error, a freeze or a hang: stops the listener (and starts it again if it was on), answers a job Blender waits for, turns scene redraw back on, ends a progress bar, restores names an interrupted Replace changed and closes files an interrupted export left open. Scene data is not changed."
	label lblReset "Both directions back to idle" align:#left width:250 offset:[-85,6]

	fn refreshState = (
		etDir.text = BlenderMaxBridge.bridgeDir
	)

	on BlenderMaxBridgeTopRollout open do refreshState()

	on btnDir pressed do (
		local d = getSavePath caption:"Bridge folder (the same folder as in the Blender add-on preferences)" initialDir:BlenderMaxBridge.bridgeDir
		if d != undefined do (
			BlenderMaxBridge.setBridgeDir d
			BlenderMaxBridge_RefreshUI()
		)
	)

	on etDir entered txt do (
		if txt != "" do BlenderMaxBridge.setBridgeDir txt
		BlenderMaxBridge_RefreshUI()
	)

	on btnReset pressed do (
		local msg = BlenderMaxBridge_Reset()
		lblReset.text = if (findString msg "all was idle") != undefined then "Reset done (all was idle)" else "Reset done, see the MAXScript Listener"
		BlenderMaxBridge_RefreshUI()
		messageBox msg title:"Blender <-> 3Ds Max Bridge"
	)
)

rollout BlenderMaxBridgeRollout "Blender -> 3ds Max  (receive)" (
	checkbutton cbListen "Start listening" width:356 height:34 align:#center
	label lblState "Listener: stopped" align:#left width:356
	checkbox chkAuto "Start the listener automatically when 3ds Max starts" align:#left
	group "Scene units (Blender sends centimeters)" (
		dropdownlist ddUnits "" items:#("Ask when the scene is not in centimeters", "Switch the scene to centimeters", "Keep the scene units (rebuild in them)") width:350 align:#left
		label lblUnits "" align:#left width:350
	)
	group "Last import" (
		label lblLast1 "-" align:#left width:350
		label lblLast2 "" align:#left width:350
	)
	group "Manual import (without Blender)" (
		button btnImport "Import JSON..." width:120 align:#left across:2
		checkbox chkFbx "Import the FBX named in the JSON" checked:true align:#left offset:[-50,4]
		checkbox chkReplace "Replace same-named objects (with FBX only)" checked:true align:#left
	)

	fn refreshState = (
		local b = BlenderMaxBridge
		cbListen.checked = b.listening
		cbListen.text = if b.listening then "Listening...  (click to stop)" else "Start listening"
		lblState.text = if b.listening then "Listener: waiting for Blender" else "Listener: stopped"
		lblLast1.text = b.lastLine1
		lblLast2.text = b.lastLine2
		chkAuto.checked = b.autoStartEnabled()
		ddUnits.selection = if b.unitsMode == "cm" then 2 else if b.unitsMode == "keep" then 3 else 1
		lblUnits.text = "This scene: " + (b.unitsLabel()) + (if b.isCentimeters() then "" else (" (1 unit = " + ((b.cmPerSystemUnit()) as string) + " cm)"))
	)

	on BlenderMaxBridgeRollout open do refreshState()

	on cbListen changed state do (
		if state then BlenderMaxBridge.startListening() else BlenderMaxBridge.stopListening()
		refreshState()
	)

	on chkAuto changed state do (
		BlenderMaxBridge.setAutoStart state
		refreshState()
	)

	on ddUnits selected i do (
		BlenderMaxBridge.unitsMode = if i == 2 then "cm" else if i == 3 then "keep" else "ask"
		BlenderMaxBridge.unitsAnswer = undefined
		BlenderMaxBridge.saveSettings()
		refreshState()
	)

	on btnImport pressed do (
		local f = getOpenFileName caption:"Select the Blender JSON" types:"JSON (*.json)|*.json|All files (*.*)|*.*|"
		if f != undefined do (
			BlenderMaxBridge.manualImport f chkFbx.checked chkReplace.checked
			refreshState()
		)
	)
)


rollout MaxToBlenderRollout "3ds Max -> Blender  (send)" (
	local fileChoice = ""

	group "Scope" (
		radioButtons rbScope labels:#("Whole scene", "Selection (with its parents)") default:1 columns:1 align:#left
	)
	group "Include" (
		checkbox cbAnim "Animation (keys; baked where they can't be kept)" checked:true
		checkbox cbMats "Materials" checked:true
		checkbox cbSkin "Skin -> Blender armature (bones, weights)" checked:true
		checkbox cbLive "Keep Shell / TurboSmooth live (top of the stack)" checked:true
		checkbox cbCheckLive "Check them against 3ds Max (final vertices)" checked:true offset:[16,0]
		spinner spVerify "Check every N frames: " range:[1,1000,5] type:#integer fieldWidth:40 align:#left
		checkbox cbVerbose "Log every object" checked:false
	)
	group "Output" (
		radioButtons rbOut labels:#("Bridge folder \\FromMax (Blender: Import latest from 3ds Max)", "File") default:1 columns:1 align:#left
		edittext etPath "" width:280 across:2 align:#left
		button btnBrowse "Browse..." width:70 align:#right
	)
	button btnSend "Send to Blender" width:350 height:32
	progressBar pbProgress width:350 height:10 color:(color 90 160 230)
	label lblStatus "" width:350 height:32 align:#left
	button btnLog "Open log" width:110 across:2
	button btnFolder "Show folder" width:110

	fn outputPath = (
		if rbOut.state == 2 and fileChoice != "" then fileChoice else (MaxToBlender.defaultOutput())
	)

	fn showPath = (
		etPath.text = if rbOut.state == 1 then (MaxToBlender.exchangeDir()) else (outputPath())
		btnBrowse.enabled = rbOut.state == 2
	)

	fn onUi pct msg = (
		if pct != undefined do pbProgress.value = pct
		lblStatus.text = msg
		windows.processPostedMessages()
	)

	on MaxToBlenderRollout open do showPath()

	on rbOut changed state do showPath()

	on cbLive changed state do cbCheckLive.enabled = state

	-- a file typed into the field (Enter) in file mode; the folder mode follows the bridge folder (above)
	on etPath entered txt do (
		if txt != "" and rbOut.state == 2 do (
			fileChoice = txt
			if (getFilenameType fileChoice) == "" do fileChoice += ".json"
		)
		showPath()
	)

	on btnBrowse pressed do (
		local f = getSaveFileName caption:"Export for Blender" filename:(outputPath()) types:"Max to Blender JSON (*.json)|*.json|"
		if f != undefined do (
			if (getFilenameType f) == "" do f += ".json"
			fileChoice = f
			showPath()
		)
	)

	on btnSend pressed do (
		local outFile = outputPath()
		MaxToBlender.optSelectedOnly = rbScope.state == 2
		MaxToBlender.optAnimation = cbAnim.checked
		MaxToBlender.optMaterials = cbMats.checked
		MaxToBlender.optNormals = true
		MaxToBlender.optSkin = cbSkin.checked
		MaxToBlender.optLiveMods = cbLive.checked
		MaxToBlender.optCheckLive = cbLive.checked and cbCheckLive.checked
		MaxToBlender.optVerifyStep = spVerify.value
		MaxToBlender.optVerboseLog = cbVerbose.checked
		if MaxToBlender.optSelectedOnly and selection.count == 0 then (
			lblStatus.text = "Nothing selected."
		) else (
			lblStatus.text = "Exporting... (Esc cancels)"
			pbProgress.value = 0
			btnSend.enabled = false
			MaxToBlender.uiFn = onUi
			local res = try (MaxToBlender.export outFile) catch ("failed at " + MaxToBlender.curStage + ": " + ((getCurrentException()) as string))
			MaxToBlender.uiFn = undefined
			btnSend.enabled = true
			pbProgress.value = if res == "ok" then 100 else 0
			lblStatus.text = if res == "ok" then ("Done: " + MaxToBlender.lastResult) else ((res as string) + "  (Open log)")
		)
	)

	on btnLog pressed do (
		if MaxToBlender.logPath != "" and (doesFileExist MaxToBlender.logPath) then shellLaunch "notepad.exe" MaxToBlender.logPath
		else lblStatus.text = "No log yet."
	)

	on btnFolder pressed do (
		local folder = getFilenamePath (outputPath())
		if doesFileExist folder then shellLaunch "explorer.exe" folder else lblStatus.text = "Folder does not exist yet."
	)
)


fn BlenderMaxBridge_OpenUI = (
	if BlenderMaxBridgeFloater != undefined do (try (closeRolloutFloater BlenderMaxBridgeFloater) catch ())
	BlenderMaxBridgeFloater = newRolloutFloater ("Blender <-> 3Ds Max Bridge Advanced " + BlenderMaxBridge.bridgeVersion) 410 900
	addRollout BlenderMaxBridgeTopRollout BlenderMaxBridgeFloater
	addRollout BlenderMaxBridgeRollout BlenderMaxBridgeFloater
	addRollout MaxToBlenderRollout BlenderMaxBridgeFloater
)

BlenderMaxBridge = BlenderMaxBridgeStruct()
BlenderMaxBridge.setup (getSourceFileName())

if BlenderMaxBridge_AutoStart == true then (
	BlenderMaxBridge_AutoStart = false
	BlenderMaxBridge.startListening()
) else (
	if BlenderMaxBridge_Resume do BlenderMaxBridge.startListening()
	BlenderMaxBridge_OpenUI()
)
