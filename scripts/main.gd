extends Node2D
## Prototype front end: mouse and keyboard tools, the camera and the HUD.
## All rules live in world.gd, all world drawing in world_view.gd and all sound in sound_board.gd.

const WorldSim := preload("res://scripts/world.gd")
const WorldView := preload("res://scripts/world_view.gd")
const SoundBoard := preload("res://scripts/sound_board.gd")

const CELL := 16
const TOP := 92 # HUD band above the world, in pixels
const MAX_SPEED := 3
const BOTTOM := 156 # message band below the world, in pixels
const MIN_ZOOM := 1.0
const MAX_ZOOM := 4.0
const ZOOM_STEP := 1.15
const PAN_SPEED := 700.0 # screen pixels per second

enum Tool { DIG, FIRE, FELT, SNOW, LADDER, CLEAR, LICHEN, STOVE }
const TOOL_NAMES := ["Dig", "Fire", "Felt wall", "Snow block", "Ladder", "Clear", "Lichen bed", "Peat stove"]

const COLOR_BACKGROUND := Color(0.04, 0.05, 0.08)
const COLOR_JOURNAL := Color(1.0, 0.86, 0.55)

var world: WorldSim
var tool := Tool.DIG
var speed := 1
var _paused := false
var _accumulator := 0.0
var _heat_view := false
var _hover := Vector2i(-1, -1)
var _painting := 0 # 0 = not painting, 1 = left button (apply tool), 2 = right button (clear)

var _hud: Label
var _journal: Label
var _log: Label
var _banner: Label
var _camera: Camera2D
var _view: WorldView
var _sound: SoundBoard


func _ready() -> void:
	get_tree().auto_accept_quit = false # see _notification
	_camera = Camera2D.new()
	add_child(_camera)
	_camera.make_current()
	_view = WorldView.new()
	_view.position = Vector2(0, TOP)
	add_child(_view)
	_sound = SoundBoard.new()
	_sound.position = Vector2(0, TOP)
	add_child(_sound)
	_view.drip_landed.connect(_sound.on_drip_landed)
	_build_ui()
	_new_world()
	_reset_camera()


func _new_world() -> void:
	world = WorldSim.new(randi())
	_view.set_world(world)
	_sound.set_world(world)
	_accumulator = 0.0
	_paused = false


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	# Solid bands above and below the world so a zoomed-in view never shows through the text.
	var view := Vector2(WorldSim.W * CELL, TOP + WorldSim.H * CELL + BOTTOM)
	for band in [Rect2(0, 0, view.x, TOP), Rect2(0, TOP + WorldSim.H * CELL, view.x, BOTTOM)]:
		var panel := ColorRect.new()
		panel.color = COLOR_BACKGROUND
		panel.position = band.position
		panel.size = band.size
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		layer.add_child(panel)
	_hud = Label.new()
	_hud.position = Vector2(12, 6)
	_hud.add_theme_font_size_override("font_size", 14)
	layer.add_child(_hud)
	_journal = Label.new()
	_journal.position = Vector2(12, 46)
	_journal.add_theme_font_size_override("font_size", 14)
	_journal.add_theme_color_override("font_color", COLOR_JOURNAL)
	layer.add_child(_journal)
	_log = Label.new()
	_log.position = Vector2(12, TOP + WorldSim.H * CELL + 6)
	_log.add_theme_font_size_override("font_size", 13)
	_log.add_theme_color_override("font_color", Color(0.80, 0.84, 0.90))
	layer.add_child(_log)
	_banner = Label.new()
	_banner.position = Vector2(0, TOP + WorldSim.H * CELL / 2 - 30)
	_banner.size = Vector2(WorldSim.W * CELL, 60)
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.add_theme_font_size_override("font_size", 26)
	_banner.add_theme_color_override("font_outline_color", Color.BLACK)
	_banner.add_theme_constant_override("outline_size", 8)
	layer.add_child(_banner)


func _process(delta: float) -> void:
	if not _paused and not world.is_over():
		_accumulator += delta * speed
		var step := 1.0 / WorldSim.TICKS_PER_SECOND
		var steps := 0
		while _accumulator >= step and steps < 10:
			world.tick()
			_accumulator -= step
			steps += 1
		if steps == 10:
			_accumulator = 0.0 # the machine can't keep up; drop the backlog rather than spiral
	_pan_camera(delta)
	_view.hover = _hover
	_view.heat_view = _heat_view
	_sound.depth = _view_depth()
	_update_ui()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		# Give the audio a moment to stop, or Godot warns about streams still playing at exit.
		_sound.stop_all()
		await get_tree().create_timer(0.1).timeout
		get_tree().quit()


# --- Input -------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode >= KEY_1 and event.keycode <= KEY_8:
			tool = (event.keycode - KEY_1) as Tool
			_sound.play_ui("click")
		match event.keycode:
			KEY_M: AudioServer.set_bus_mute(0, not AudioServer.is_bus_mute(0))
			KEY_SPACE: _paused = not _paused
			KEY_EQUAL, KEY_KP_ADD: speed = mini(speed + 1, MAX_SPEED)
			KEY_MINUS, KEY_KP_SUBTRACT: speed = maxi(speed - 1, 1)
			KEY_H: _heat_view = not _heat_view
			KEY_R:
				_new_world()
				_reset_camera()
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed:
				_zoom_at(event.position, ZOOM_STEP if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / ZOOM_STEP)
			return
		if event.pressed:
			_painting = 1 if event.button_index == MOUSE_BUTTON_LEFT else 2 if event.button_index == MOUSE_BUTTON_RIGHT else 0
			_apply_at(_cell_at(event.position))
		else:
			_painting = 0
	elif event is InputEventMouseMotion:
		_hover = _cell_at(event.position)
		if _painting != 0:
			_apply_at(_hover)


func _cell_at(screen: Vector2) -> Vector2i:
	if screen.y < TOP or screen.y >= TOP + WorldSim.H * CELL:
		return Vector2i(-1, -1) # over the text bands, not the world
	var local := _screen_to_world(screen)
	return Vector2i(floori(local.x / CELL), floori((local.y - TOP) / CELL))


# --- Camera ------------------------------------------------------------------
# The world is drawn at its natural size between the two text bands; at zoom 1 it fills that gap exactly.

func _screen_to_world(screen: Vector2) -> Vector2:
	return _camera.position + (screen - get_viewport_rect().size / 2.0) / _camera.zoom.x


## How deep the middle of the view is, from 0 at the surface to 1 at bedrock.
func _view_depth() -> float:
	var screen := get_viewport_rect().size
	var centre := _screen_to_world(Vector2(screen.x / 2.0, TOP + WorldSim.H * CELL / 2.0))
	return clampf((centre.y - TOP) / (WorldSim.H * CELL), 0.0, 1.0)


func _reset_camera() -> void:
	_camera.zoom = Vector2.ONE
	_camera.position = get_viewport_rect().size / 2.0
	_clamp_camera()


func _zoom_at(screen: Vector2, factor: float) -> void:
	var before := _screen_to_world(screen)
	var zoom := clampf(_camera.zoom.x * factor, MIN_ZOOM, MAX_ZOOM)
	_camera.zoom = Vector2(zoom, zoom)
	# Keep the point under the cursor in place while zooming.
	_camera.position = before - (screen - get_viewport_rect().size / 2.0) / zoom
	_clamp_camera()


func _pan_camera(delta: float) -> void:
	var dir := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
		dir.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
		dir.x += 1.0
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP):
		dir.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN):
		dir.y += 1.0
	if dir != Vector2.ZERO:
		_camera.position += dir.normalized() * PAN_SPEED * delta / _camera.zoom.x
		_clamp_camera()


## Keeps the visible part of the world inside its edges, measured in the gap between the text bands.
func _clamp_camera() -> void:
	var zoom := _camera.zoom.x
	var screen := get_viewport_rect().size
	var gap_center := Vector2(screen.x / 2.0, TOP + WorldSim.H * CELL / 2.0)
	var offset := (gap_center - screen / 2.0) / zoom # from camera centre to the gap's centre, in world units
	var half := Vector2(WorldSim.W * CELL, WorldSim.H * CELL) / zoom / 2.0
	var world_min := Vector2(0, TOP)
	var world_max := Vector2(WorldSim.W * CELL, TOP + WorldSim.H * CELL)
	var focus := _camera.position + offset
	focus.x = clampf(focus.x, world_min.x + half.x, world_max.x - half.x)
	focus.y = clampf(focus.y, world_min.y + half.y, world_max.y - half.y)
	_camera.position = focus - offset


func _apply_at(cell: Vector2i) -> void:
	if not world.in_bounds(cell.x, cell.y) or world.is_over():
		return
	if _painting == 2:
		world.clear_at(cell.x, cell.y)
		return
	var i := world.idx(cell.x, cell.y)
	match tool:
		Tool.DIG:
			var was_marked := world.dig_mark[i] == 1
			world.set_dig_mark(cell.x, cell.y, true)
			if not was_marked and world.dig_mark[i] == 1:
				_sound.play_at_cell("click", cell)
		Tool.FIRE:
			if world.place_fire(cell.x, cell.y):
				_sound.play_at_cell("ignite", cell)
		Tool.FELT, Tool.SNOW:
			if world.place_block(cell.x, cell.y, WorldSim.Tile.FELT if tool == Tool.FELT else WorldSim.Tile.SNOW):
				_sound.play_at_cell("place", cell)
		Tool.LADDER:
			if world.place_ladder(cell.x, cell.y):
				_sound.play_at_cell("knock", cell)
		Tool.CLEAR: world.clear_at(cell.x, cell.y)
		Tool.LICHEN:
			if world.place_lichen(cell.x, cell.y):
				_sound.play_at_cell("place", cell, 1.3)
		Tool.STOVE:
			if world.place_stove(cell.x, cell.y):
				_sound.play_at_cell("ignite", cell, 0.8)


# --- HUD ---------------------------------------------------------------------

func _update_ui() -> void:
	var people := PackedStringArray()
	for c in world.colonists:
		if c.alive:
			people.append("%s %d%%%s" % [c.name, roundi(c.warmth), " (wet)" if c.wet else ""])
		else:
			people.append("%s (dead)" % c.name)
	var tools := PackedStringArray()
	for k in TOOL_NAMES.size():
		var name_text: String = TOOL_NAMES[k]
		if (k == Tool.LICHEN and not world.lichen_unlocked) or (k == Tool.STOVE and not world.stove_unlocked):
			name_text = "???" # blueprints are found in the frozen camps
		tools.append(("[%d %s]" if k == tool else "%d %s") % [k + 1, name_text])
	var hover := world.describe(_hover.x, _hover.y)
	_hud.text = "Day %d   %s   Fuel %d   Food %d   Felt %d   Snow %d   Warmth: %s\n%s\n\n%s" % [
		world.day() + 1, "PAUSED" if _paused else "Speed %dx" % speed,
		ceili(world.fuel), ceili(world.food), world.felt, world.snow, ", ".join(people),
		hover, "  ".join(tools),
	]
	_journal.text = "Journal %d/%d: %s" % [mini(world.journal_step + 1, world.journal.size()), world.journal.size(), world.journal_text()]
	_log.text = "\n".join(world.messages) + "\nLeft drag: use tool   Right drag: clear   1-8: tools   Scroll: zoom   WASD: move view   Space: pause   +/-: speed   H: heat   M: mute   R: restart"
	if world.is_won():
		_banner.text = "The journal is complete. %d of 3 made it, on day %d." % [world.alive_count(), world.day() + 1]
	elif world.is_lost():
		_banner.text = "Everyone is gone. Press R to try again."
	else:
		_banner.text = ""
