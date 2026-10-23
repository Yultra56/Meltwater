extends Node2D
## Prototype front end: draws the world with plain shapes, handles mouse tools and the HUD.
## All rules live in world.gd; nothing here changes the simulation except through its actions.

const WorldSim := preload("res://scripts/world.gd")

const CELL := 16
const TOP := 64 # HUD band above the world, in pixels
const MAX_SPEED := 3

enum Tool { DIG, FIRE, FELT, SNOW, LADDER, CLEAR }
const TOOL_NAMES := ["Dig", "Fire", "Felt wall", "Snow block", "Ladder", "Clear"]

const COLOR_BACKGROUND := Color(0.04, 0.05, 0.08)
const COLOR_STORM := Color(0.56, 0.60, 0.68)
const COLOR_CAVE := Color(0.08, 0.09, 0.13)
const COLOR_CAVE_WARM := Color(0.32, 0.18, 0.09)
const COLOR_YOUNG_ICE := Color(0.86, 0.91, 0.96)
const COLOR_OLD_ICE := Color(0.26, 0.50, 0.82)
const COLOR_SNOW := Color(0.94, 0.95, 0.97)
const COLOR_STONE := Color(0.27, 0.25, 0.24)
const COLOR_FELT := Color(0.52, 0.36, 0.24)
const COLOR_CRATE := Color(0.62, 0.45, 0.16)
const COLOR_CRACK := Color(0.15, 0.20, 0.30, 0.8)
const COLOR_WATER := Color(0.18, 0.42, 0.85, 0.85)
const COLOR_DIG_MARK := Color(1.0, 0.84, 0.25)
const COLOR_FIRE := Color(1.0, 0.55, 0.15)
const COLOR_FIRE_CORE := Color(1.0, 0.85, 0.4)
const COLOR_LADDER := Color(0.55, 0.40, 0.25)
const COLOR_COLD := Color(0.35, 0.55, 1.0)
const COLOR_WARM := Color(1.0, 0.72, 0.40)

var world: WorldSim
var tool := Tool.DIG
var speed := 1
var _paused := false
var _accumulator := 0.0
var _heat_view := false
var _hover := Vector2i(-1, -1)
var _painting := 0 # 0 = not painting, 1 = left button (apply tool), 2 = right button (clear)

var _hud: Label
var _log: Label
var _banner: Label


func _ready() -> void:
	_build_ui()
	_new_world()


func _new_world() -> void:
	world = WorldSim.new(randi())
	_accumulator = 0.0
	_paused = false


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(12, 6)
	_hud.add_theme_font_size_override("font_size", 14)
	layer.add_child(_hud)
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
	_update_ui()
	queue_redraw()


# --- Input -------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1: tool = Tool.DIG
			KEY_2: tool = Tool.FIRE
			KEY_3: tool = Tool.FELT
			KEY_4: tool = Tool.SNOW
			KEY_5: tool = Tool.LADDER
			KEY_6: tool = Tool.CLEAR
			KEY_SPACE: _paused = not _paused
			KEY_EQUAL, KEY_KP_ADD: speed = mini(speed + 1, MAX_SPEED)
			KEY_MINUS, KEY_KP_SUBTRACT: speed = maxi(speed - 1, 1)
			KEY_H: _heat_view = not _heat_view
			KEY_R: _new_world()
	elif event is InputEventMouseButton:
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
	var local := get_global_transform_with_canvas().affine_inverse() * screen
	return Vector2i(floori(local.x / CELL), floori((local.y - TOP) / CELL))


func _apply_at(cell: Vector2i) -> void:
	if not world.in_bounds(cell.x, cell.y) or world.is_over():
		return
	if _painting == 2:
		world.clear_at(cell.x, cell.y)
		return
	match tool:
		Tool.DIG: world.set_dig_mark(cell.x, cell.y, true)
		Tool.FIRE: world.place_fire(cell.x, cell.y)
		Tool.FELT: world.place_block(cell.x, cell.y, WorldSim.Tile.FELT)
		Tool.SNOW: world.place_block(cell.x, cell.y, WorldSim.Tile.SNOW)
		Tool.LADDER: world.place_ladder(cell.x, cell.y)
		Tool.CLEAR: world.clear_at(cell.x, cell.y)


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
		tools.append(("[%d %s]" if k == tool else "%d %s") % [k + 1, name_text])
	var hover := world.describe(_hover.x, _hover.y)
	_hud.text = "Day %d of %d   %s   Fuel %d   Felt %d   Snow %d   Warmth: %s\n%s   %s" % [
		mini(world.day() + 1, WorldSim.TARGET_DAYS), WorldSim.TARGET_DAYS,
		"PAUSED" if _paused else "Speed %dx" % speed,
		ceili(world.fuel), world.felt, world.snow, ", ".join(people),
		"  ".join(tools), hover,
	]
	_log.text = "\n".join(world.messages) + "\nLeft drag: use tool   Right drag: clear   1-6: tools   Space: pause   +/-: speed   H: heat view   R: restart"
	if world.is_won():
		_banner.text = "The colony holds. %d of 3 survived ten days." % world.alive_count()
	elif world.is_lost():
		_banner.text = "Everyone froze. Press R to try again."
	else:
		_banner.text = ""


# --- Drawing -----------------------------------------------------------------

func _draw() -> void:
	draw_rect(Rect2(0, 0, WorldSim.W * CELL, TOP + WorldSim.H * CELL + 160), COLOR_BACKGROUND)
	var now := Time.get_ticks_msec() / 1000.0
	for y in WorldSim.H:
		for x in WorldSim.W:
			var i := world.idx(x, y)
			var r := Rect2(x * CELL, TOP + y * CELL, CELL, CELL)
			if _heat_view:
				draw_rect(r, _heat_color(world.temp[i]))
			else:
				_draw_tile(i, x, y, r)
			if world.water[i] > 0.02 and world.tiles[i] == WorldSim.Tile.AIR:
				var h := CELL * minf(world.water[i], 1.0)
				draw_rect(Rect2(r.position.x, r.end.y - h, CELL, h), COLOR_WATER)
			match world.build[i]:
				WorldSim.Build.FIRE: _draw_fire(r, world.fire_is_burning(i), now + x)
				WorldSim.Build.LADDER: _draw_ladder(r)
			if world.dig_mark[i] == 1:
				draw_rect(r.grow(-1.5), COLOR_DIG_MARK, false, 1.5)
	for k in world.colonists.size():
		_draw_colonist(world.colonists[k], k)
	if world.in_bounds(_hover.x, _hover.y):
		draw_rect(Rect2(_hover.x * CELL, TOP + _hover.y * CELL, CELL, CELL), Color(1, 1, 1, 0.8), false, 1.0)


func _draw_tile(i: int, x: int, y: int, r: Rect2) -> void:
	var t := world.tiles[i]
	var temp := world.temp[i]
	match t:
		WorldSim.Tile.AIR:
			if y < WorldSim.SURFACE_ROWS:
				draw_rect(r, COLOR_STORM)
			else:
				draw_rect(r, COLOR_CAVE.lerp(COLOR_CAVE_WARM, clampf(temp / 25.0, 0.0, 1.0)))
		WorldSim.Tile.ICE:
			# Old deep ice is clear blue; young ice is white. Weak ice turns grey.
			var c := COLOR_YOUNG_ICE.lerp(COLOR_OLD_ICE, world.ice_age(y))
			c = c.lerp(Color(0.45, 0.50, 0.56), clampf(1.0 - world.integrity[i] / 0.8, 0.0, 0.6))
			if temp > -1.0:
				c = c.lightened(0.15) # wet, glistening surface
			draw_rect(r, c)
		WorldSim.Tile.SNOW:
			draw_rect(r, COLOR_SNOW)
		WorldSim.Tile.ROCK:
			draw_rect(r, COLOR_STONE)
		WorldSim.Tile.FELT:
			draw_rect(r, COLOR_FELT)
			draw_line(r.position + Vector2(2, 5), r.position + Vector2(CELL - 2, 5), COLOR_FELT.darkened(0.3))
			draw_line(r.position + Vector2(2, 11), r.position + Vector2(CELL - 2, 11), COLOR_FELT.darkened(0.3))
		WorldSim.Tile.CRATE:
			draw_rect(r, COLOR_OLD_ICE.lerp(COLOR_YOUNG_ICE, 0.3))
			draw_rect(r.grow(-3), COLOR_CRATE)
			draw_line(r.position + Vector2(3, 3), r.end - Vector2(3, 3), COLOR_CRATE.darkened(0.4))
	if (t == WorldSim.Tile.ICE or t == WorldSim.Tile.SNOW) and world.integrity[i] < 0.5:
		draw_line(r.position + Vector2(3, 2), r.position + Vector2(9, 9), COLOR_CRACK, 1.0)
		draw_line(r.position + Vector2(9, 9), r.position + Vector2(6, 14), COLOR_CRACK, 1.0)
		draw_line(r.position + Vector2(9, 9), r.position + Vector2(14, 7), COLOR_CRACK, 1.0)


func _draw_fire(r: Rect2, burning: bool, t: float) -> void:
	var base := r.position + Vector2(CELL / 2.0, CELL)
	if not burning:
		draw_rect(Rect2(base.x - 5, base.y - 3, 10, 3), Color(0.3, 0.3, 0.3))
		return
	var flicker := 1.0 + 0.15 * sin(t * 11.0)
	var tall := 12.0 * flicker
	draw_colored_polygon(PackedVector2Array([base + Vector2(-6, 0), base + Vector2(6, 0), base + Vector2(0, -tall)]), COLOR_FIRE)
	draw_colored_polygon(PackedVector2Array([base + Vector2(-3, 0), base + Vector2(3, 0), base + Vector2(0, -tall * 0.55)]), COLOR_FIRE_CORE)


func _draw_ladder(r: Rect2) -> void:
	draw_line(r.position + Vector2(4, 0), r.position + Vector2(4, CELL), COLOR_LADDER, 2.0)
	draw_line(r.position + Vector2(12, 0), r.position + Vector2(12, CELL), COLOR_LADDER, 2.0)
	for k in 3:
		var yy := r.position.y + 3 + k * 5
		draw_line(Vector2(r.position.x + 4, yy), Vector2(r.position.x + 12, yy), COLOR_LADDER, 1.5)


func _draw_colonist(c: WorldSim.Colonist, k: int) -> void:
	# Colonists sharing a tile stand side by side instead of on top of each other.
	var shift := 0
	for j in k:
		var other: WorldSim.Colonist = world.colonists[j]
		if other.pos == c.pos:
			shift += 1
	var offset: int = [0, 11, -11][shift % 3]
	var r := Rect2(c.pos.x * CELL + 3 + offset, TOP + c.pos.y * CELL + 2, CELL - 6, CELL - 2)
	if not c.alive:
		draw_rect(Rect2(r.position.x - 2, r.end.y - 5, r.size.x + 4, 5), Color(0.55, 0.6, 0.65))
		return
	var body := COLOR_COLD.lerp(COLOR_WARM, c.warmth / 100.0)
	draw_rect(r.grow(1), Color(0.05, 0.05, 0.08))
	draw_rect(r, body)
	draw_rect(Rect2(r.position.x + 2, r.position.y + 2, r.size.x - 4, 3), body.darkened(0.4)) # hood
	# Warmth bar above the head.
	draw_rect(Rect2(r.position.x, r.position.y - 4, r.size.x, 2), Color(0.1, 0.1, 0.1))
	draw_rect(Rect2(r.position.x, r.position.y - 4, r.size.x * c.warmth / 100.0, 2), body)


func _heat_color(t: float) -> Color:
	if t < 0.0:
		return Color(0.95, 0.97, 1.0).lerp(Color(0.10, 0.20, 0.70), clampf(-t / 40.0, 0.0, 1.0))
	return Color(0.95, 0.97, 1.0).lerp(Color(0.85, 0.20, 0.10), clampf(t / 30.0, 0.0, 1.0))
