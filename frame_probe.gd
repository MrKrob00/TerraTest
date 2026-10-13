extends Node
## WHAT A FRAME COSTS ON THE DEVICE, LAYER BY LAYER (the profiler panel's PROBE button). The phone's
## GPU is the one that counts and it gives no timestamps (GLES3), and llvmpipe here ranks pixels far
## above what a phone does - render scale bought 15% there and nothing on the phone. So the device
## measures itself: each layer of the picture is switched OFF for `WINDOW` seconds between two
## windows with it ON, and the cost is the mean frame time off against the two ons round it. The
## table goes into the panel and the clipboard. A switch writes the field the game owns and puts
## the saved value back, and every node is asked `is_instance_valid` after each wait.

signal finished(text: String)

const SETTLE := 0.6
const WINDOW := 2.5
## Each layer is switched off this many times and the costs averaged: one window read +-8 ms of
## noise on llvmpipe.
const ROUNDS := 2

var _lines: Array[String] = []
var status: String = ""

func run() -> void:
	var main: Node = get_node_or_null("/root/Main")
	if main == null:
		return
	_lines.clear()
	_lines.append("PROBE  %s  view %d m" % [Time.get_datetime_string_from_system(), int(main.get("view_distance")) if main.get("view_distance") != null else 0])
	var base0: float = await _measure("base")
	_lines.append("base %.1f ms (%d fps)" % [base0, int(1000.0 / maxf(base0, 0.1))])
	for c in _cases(main):
		var nm: String = c[0]
		var flip: Callable = c[1]
		var cost := 0.0
		var offs := 0.0
		for r in ROUNDS:
			status = "probe: %s off (%d/%d)" % [nm, r + 1, ROUNDS]
			var saved = flip.call(true, null)
			var off: float = await _measure(nm)
			flip.call(false, saved)
			status = "probe: %s on (%d/%d)" % [nm, r + 1, ROUNDS]
			var on: float = await _measure(nm)
			cost += (base0 + on) * 0.5 - off
			offs += off
			base0 = on
		_lines.append("%-15s %+6.1f ms  (off %.1f, on %.1f)" % [nm, cost / ROUNDS, offs / ROUNDS, base0])
	_lines.append("+ = what the layer costs; noise is about +-2 ms")
	var text := "\n".join(_lines)
	print(text)
	DisplayServer.clipboard_set(text)
	status = ""
	finished.emit(text)

func _measure(_tag: String) -> float:
	await _wait(SETTLE)
	var frames := 0
	var t0 := Time.get_ticks_usec()
	var end := t0 + int(WINDOW * 1000000.0)
	while Time.get_ticks_usec() < end:
		await get_tree().process_frame
		frames += 1
	return float(Time.get_ticks_usec() - t0) / 1000.0 / maxf(float(frames), 1.0)

func _wait(sec: float) -> void:
	var end := Time.get_ticks_msec() + int(sec * 1000.0)
	while Time.get_ticks_msec() < end:
		await get_tree().process_frame

## Each case: [name, Callable(off: bool, saved) -> saved]. Called with true it switches the
## layer off and returns what it needs to put it back; with false and that value it restores.
func _cases(main: Node) -> Array:
	var out: Array = []
	var light := main.get_node_or_null("DirectionalLight3D2") as DirectionalLight3D
	if light != null and light.shadow_enabled:
		out.append(["shadows", func(off: bool, _s):
			if is_instance_valid(light):
				light.shadow_enabled = not off
			return true])
	var map := main.get_node_or_null("map") as Node3D
	if map != null:
		out.append(["ground+veins", _vis(map)])
		var mat = map.get("_mat")
		if mat is ShaderMaterial:
			out.append(["grass+snow lift", func(off: bool, s):
				if off:
					var keep := [mat.get_shader_parameter("grass_height"), mat.get_shader_parameter("snow_height")]
					mat.set_shader_parameter("grass_height", 0.0)
					mat.set_shader_parameter("snow_height", 0.0)
					return keep
				mat.set_shader_parameter("grass_height", s[0])
				mat.set_shader_parameter("snow_height", s[1])
				return null])
		var rn := map.get_node_or_null("Resource_Nodes") as Node3D
		if rn != null:
			out.append(["veins+trees", _vis(rn)])
			for ch in rn.get_children():
				if ch.get_script() != null and String(ch.get_script().resource_path).ends_with("far_trees.gd") and ch is Node3D:
					out.append(["far tree cards", _vis(ch)])
		for ch in map.get_children():
			if ch.get_script() != null and String(ch.get_script().resource_path).ends_with("grass.gd"):
				var vp = ch.get("_vp")
				if vp is SubViewport:
					out.append(["grass viewport", func(off: bool, s):
						if not is_instance_valid(vp):
							return 0
						if off:
							var keep: int = vp.render_target_update_mode
							vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
							return keep
						vp.render_target_update_mode = s
						return null])
	var veh := main.get_node_or_null("Vehicles") as Node3D
	if veh != null:
		out.append(["machines", _vis(veh)])
	var obj := main.get_node_or_null("objects") as Node3D
	if obj != null:
		out.append(["loose items", _vis(obj)])
	var we := main.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we != null and we.environment != null:
		var env := we.environment
		out.append(["sky", func(off: bool, s):
			if off:
				var keep := [env.background_mode, env.background_color]
				env.background_color = Color(0.55, 0.6, 0.65)
				env.background_mode = Environment.BG_COLOR
				return keep
			env.background_mode = s[0]
			env.background_color = s[1]
			return null])
	out.append(["HUD", func(off: bool, s):
		if off:
			var hidden: Array = []
			for c in get_tree().root.find_children("*", "CanvasLayer", true, false):
				if (c as CanvasLayer).visible:
					(c as CanvasLayer).visible = false
					hidden.append(c)
			return hidden
		for c in s:
			if is_instance_valid(c):
				(c as CanvasLayer).visible = true
		return null])
	return out

func _vis(n: Node3D) -> Callable:
	return func(off: bool, _s):
		if is_instance_valid(n):
			n.visible = not off
		return true
