extends Node2D
## Draws the glacier: the terrain shader underneath, then buildings, camps, particles and the survivors.
## Positions are local to this node, so (0, 0) is the top-left corner of the world.

const WorldSim := preload("res://scripts/world.gd")
const TerrainShader := preload("res://shaders/terrain.gdshader")

const CELL := 16
const LIGHT_RADIUS := 8 # tiles
const MAX_PARTICLES := 500
const WALK_SPEED := 70.0 # pixels per second the drawn survivor follows its tile at

enum Particle { DRIP, STEAM, SPARK, BREATH }

## A drop of meltwater hit the floor or a pool, at a position local to this node.
signal drip_landed(at: Vector2, into_water: bool)

const COLOR_DIG_MARK := Color(1.0, 0.84, 0.25)
const COLOR_FLAME := Color(1.0, 0.50, 0.12)
const COLOR_FLAME_CORE := Color(1.0, 0.86, 0.45)
const COLOR_EMBER := Color(0.95, 0.30, 0.08)
const COLOR_LOG := Color(0.30, 0.19, 0.10)
const COLOR_LADDER := Color(0.50, 0.36, 0.22)
const COLOR_LICHEN := Color(0.45, 0.72, 0.42)
const COLOR_IRON := Color(0.22, 0.21, 0.21)
const COLOR_CRATE := Color(0.55, 0.38, 0.16)
const COLOR_CAMP_PROP := Color(0.62, 0.58, 0.50)
const COLOR_FROZEN := Color(0.62, 0.70, 0.78)
const COLOR_JOURNAL := Color(1.0, 0.86, 0.55)
const COLOR_FUR := Color(0.86, 0.80, 0.68)
const COLOR_TROUSERS := Color(0.16, 0.17, 0.21)
const COLOR_BOOTS := Color(0.10, 0.08, 0.07)
const COLOR_FACE := Color(0.42, 0.29, 0.22)
const COLOR_DRIP := Color(0.70, 0.86, 1.0, 0.9)
const PARKAS := [Color(0.70, 0.20, 0.16), Color(0.82, 0.60, 0.18), Color(0.16, 0.50, 0.54)]

var world: WorldSim
var heat_view := false
var hover := Vector2i(-1, -1)

var _terrain: ColorRect
var _cells_image: Image
var _heat_image: Image
var _cells_texture: ImageTexture
var _heat_texture: ImageTexture
var _cell_bytes := PackedByteArray()
var _heat_bytes := PackedByteArray()
var _light := PackedFloat32Array()

var _particles: Array[Dictionary] = []
var _shown: Array[Vector2] = [] # where each survivor is drawn, easing toward their tile
var _facing: Array[float] = []
var _stride: Array[float] = []
var _time := 0.0


func _ready() -> void:
	_terrain = ColorRect.new()
	_terrain.size = Vector2(WorldSim.W * CELL, WorldSim.H * CELL)
	_terrain.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_terrain.show_behind_parent = true
	var material := ShaderMaterial.new()
	material.shader = TerrainShader
	material.set_shader_parameter("grid", Vector2(WorldSim.W, WorldSim.H))
	material.set_shader_parameter("surface_rows", float(WorldSim.SURFACE_ROWS))
	material.set_shader_parameter("bedrock_rows", float(WorldSim.BEDROCK_ROWS))
	_terrain.material = material
	add_child(_terrain)
	_cell_bytes.resize(WorldSim.W * WorldSim.H * 4)
	_heat_bytes.resize(WorldSim.W * WorldSim.H * 4)
	_light.resize(WorldSim.W * WorldSim.H)
	_upload_textures()
	material.set_shader_parameter("cells", _cells_texture)
	material.set_shader_parameter("heat", _heat_texture)


func set_world(new_world: WorldSim) -> void:
	world = new_world
	_particles.clear()
	_shown.clear()
	_facing.clear()
	_stride.clear()
	for k in world.colonists.size():
		_shown.append(_colonist_target(k))
		_facing.append(1.0)
		_stride.append(0.0)


func _process(delta: float) -> void:
	if world == null:
		return
	_time += delta
	_compute_light()
	_upload_textures()
	(_terrain.material as ShaderMaterial).set_shader_parameter("heat_view", heat_view)
	_move_survivors(delta)
	_spawn_particles(delta)
	_update_particles(delta)
	queue_redraw()


# --- Terrain data ------------------------------------------------------------

## Firelight per tile: falls off with distance and is dimmed by each solid tile it passes through.
func _compute_light() -> void:
	_light.fill(0.0)
	for i in world.build.size():
		if not world.fire_is_burning(i):
			continue
		var sx := i % WorldSim.W
		var sy := i / WorldSim.W
		var strength := 1.0 if world.build[i] == WorldSim.Build.FIRE else 0.75
		strength *= 0.9 + 0.1 * sin(_time * 9.0 + sx * 1.7) * sin(_time * 5.3 + sy)
		for y in range(maxi(sy - LIGHT_RADIUS, 0), mini(sy + LIGHT_RADIUS + 1, WorldSim.H)):
			for x in range(maxi(sx - LIGHT_RADIUS, 0), mini(sx + LIGHT_RADIUS + 1, WorldSim.W)):
				var d := Vector2(x - sx, y - sy).length()
				if d > LIGHT_RADIUS:
					continue
				var l := strength * pow(1.0 - d / LIGHT_RADIUS, 2.0) * _transmission(sx, sy, x, y, d)
				var j := world.idx(x, y)
				_light[j] = minf(_light[j] + l, 1.0)


## Share of light that reaches (x, y) from (sx, sy): ice lets some through, rock and felt very little.
func _transmission(sx: int, sy: int, x: int, y: int, d: float) -> float:
	var through := 1.0
	var steps := int(d)
	for s in range(1, steps):
		var f := float(s) / d
		var px := roundi(lerpf(sx, x, f))
		var py := roundi(lerpf(sy, y, f))
		match world.tile_at(px, py):
			WorldSim.Tile.AIR:
				pass
			WorldSim.Tile.ICE, WorldSim.Tile.SNOW, WorldSim.Tile.CRATE:
				through *= 0.55
			_:
				through *= 0.15
		if through < 0.02:
			return 0.0
	return through


func _upload_textures() -> void:
	if world != null:
		var n := WorldSim.W * WorldSim.H
		for i in n:
			var o := i * 4
			var sealed := 0
			if world.tiles[i] == WorldSim.Tile.AIR:
				var camp := world.camp_at(i % WorldSim.W, i / WorldSim.W)
				if camp != -1 and not world.camps[camp].found:
					sealed = 255
			_cell_bytes[o] = world.tiles[i] * 32
			_cell_bytes[o + 1] = clampi(roundi(world.integrity[i] * 255.0), 0, 255)
			_cell_bytes[o + 2] = clampi(roundi(world.water[i] * 255.0), 0, 255)
			_cell_bytes[o + 3] = sealed
			_heat_bytes[o] = clampi(roundi((world.temp[i] + 40.0) / 80.0 * 255.0), 0, 255)
			_heat_bytes[o + 1] = clampi(roundi(_light[i] * 255.0), 0, 255)
			# Strength again, filtered smoothly in the shader; open tiles count as strong so they don't grey their walls.
			_heat_bytes[o + 2] = 255 if world.tiles[i] == WorldSim.Tile.AIR else clampi(roundi(world.integrity[i] * 255.0), 0, 255)
			_heat_bytes[o + 3] = 255
	_cells_image = Image.create_from_data(WorldSim.W, WorldSim.H, false, Image.FORMAT_RGBA8, _cell_bytes)
	_heat_image = Image.create_from_data(WorldSim.W, WorldSim.H, false, Image.FORMAT_RGBA8, _heat_bytes)
	if _cells_texture == null:
		_cells_texture = ImageTexture.create_from_image(_cells_image)
		_heat_texture = ImageTexture.create_from_image(_heat_image)
	else:
		_cells_texture.update(_cells_image)
		_heat_texture.update(_heat_image)


# --- Survivors' drawn positions ----------------------------------------------

func _colonist_target(k: int) -> Vector2:
	var c: WorldSim.Colonist = world.colonists[k]
	# Survivors sharing a tile stand side by side instead of on top of each other.
	var shift := 0
	for j in k:
		var other: WorldSim.Colonist = world.colonists[j]
		if other.alive == c.alive and other.pos == c.pos:
			shift += 1
	var offset: float = [0.0, 8.0, -8.0][shift % 3]
	return Vector2(c.pos.x * CELL + CELL / 2.0 + offset, (c.pos.y + 1) * CELL)


func _move_survivors(delta: float) -> void:
	for k in world.colonists.size():
		var target := _colonist_target(k)
		var gap := target - _shown[k]
		if gap.length() > CELL * 3.0:
			_shown[k] = target # a long drop or a restart: don't slide across the map
		else:
			_shown[k] = _shown[k].move_toward(target, WALK_SPEED * delta * (3.0 if gap.y > 2.0 else 1.0))
		if absf(gap.x) > 0.5:
			_facing[k] = signf(gap.x)
		if gap.length() > 0.5:
			_stride[k] += delta * 14.0
		else:
			_stride[k] = 0.0


# --- Particles ---------------------------------------------------------------

func _spawn(kind: int, p: Vector2, v: Vector2, life: float) -> void:
	if _particles.size() < MAX_PARTICLES:
		_particles.append({"kind": kind, "p": p, "v": v, "life": life, "max": life})


func _spawn_particles(delta: float) -> void:
	# Meltwater drips from warm ice ceilings.
	for k in 40:
		var x := randi() % WorldSim.W
		var y := randi() % (WorldSim.H - 1)
		var i := world.idx(x, y)
		var t := world.tiles[i]
		if (t == WorldSim.Tile.ICE or t == WorldSim.Tile.SNOW) and world.temp[i] > -0.6 and world.is_passable(x, y + 1):
			if randf() < 8.0 * delta:
				_spawn(Particle.DRIP, Vector2(x * CELL + randf_range(3, 13), (y + 1) * CELL), Vector2.ZERO, 3.0)
	# Steam and sparks from fires and stoves.
	for i in world.build.size():
		if not world.fire_is_burning(i):
			continue
		var base := Vector2((i % WorldSim.W) * CELL + CELL / 2.0, (i / WorldSim.W) * CELL + 4)
		if randf() < 5.0 * delta:
			_spawn(Particle.STEAM, base + Vector2(randf_range(-3, 3), 0), Vector2(randf_range(-3, 3), -14), 1.8)
		if world.build[i] == WorldSim.Build.FIRE and randf() < 9.0 * delta:
			_spawn(Particle.SPARK, base + Vector2(randf_range(-3, 3), 4), Vector2(randf_range(-8, 8), randf_range(-38, -18)), 0.7)
	# Breath clouds in the cold.
	for k in world.colonists.size():
		var c: WorldSim.Colonist = world.colonists[k]
		if c.alive and world.temp[world.idx(c.pos.x, c.pos.y)] < -1.0 and randf() < 0.8 * delta:
			_spawn(Particle.BREATH, _shown[k] + Vector2(_facing[k] * 4.0, -13), Vector2(_facing[k] * 6.0, -3), 1.1)


func _update_particles(delta: float) -> void:
	var k := _particles.size() - 1
	while k >= 0:
		var p := _particles[k]
		p.life -= delta
		match p.kind:
			Particle.DRIP:
				p.v.y += 320.0 * delta
			Particle.SPARK:
				p.v.y += 20.0 * delta
			_:
				p.v *= 1.0 - 0.8 * delta
		p.p += p.v * delta
		var cell := Vector2i(floori(p.p.x / CELL), floori(p.p.y / CELL))
		var dead: bool = p.life <= 0.0
		if p.kind == Particle.DRIP and not dead:
			var into_water := world.in_bounds(cell.x, cell.y) and world.water[world.idx(cell.x, cell.y)] > 0.3
			if into_water or world.is_solid(cell.x, cell.y):
				dead = true
				drip_landed.emit(p.p, into_water)
		if dead:
			_particles.remove_at(k)
		k -= 1


# --- Drawing -----------------------------------------------------------------

func _draw() -> void:
	if world == null:
		return
	for i in world.build.size():
		var r := Rect2((i % WorldSim.W) * CELL, (i / WorldSim.W) * CELL, CELL, CELL)
		match world.build[i]:
			WorldSim.Build.FIRE: _draw_fire(r, world.fire_is_burning(i), _time + i)
			WorldSim.Build.LADDER: _draw_ladder(r)
			WorldSim.Build.LICHEN: _draw_lichen(r, world.temp[i] > WorldSim.LICHEN_WARM_TEMP, _time + i)
			WorldSim.Build.STOVE: _draw_stove(r, world.fire_is_burning(i), _time + i)
		if world.dig_mark[i] == 1:
			_draw_dig_mark(r)
	for camp in world.camps:
		_draw_camp(camp)
	for k in world.colonists.size():
		_draw_survivor(k)
	_draw_particles()
	if world.in_bounds(hover.x, hover.y):
		draw_rect(Rect2(hover.x * CELL, hover.y * CELL, CELL, CELL), Color(1, 1, 1, 0.7), false, 1.0)


func _draw_dig_mark(r: Rect2) -> void:
	# Corner brackets, so the ice under the mark stays visible.
	var a := r.grow(-1.5)
	var l := 4.0
	for corner in [a.position, Vector2(a.end.x, a.position.y), a.end, Vector2(a.position.x, a.end.y)]:
		var sx := 1.0 if corner.x == a.position.x else -1.0
		var sy := 1.0 if corner.y == a.position.y else -1.0
		draw_line(corner, corner + Vector2(l * sx, 0), COLOR_DIG_MARK, 1.5)
		draw_line(corner, corner + Vector2(0, l * sy), COLOR_DIG_MARK, 1.5)


func _draw_fire(r: Rect2, burning: bool, t: float) -> void:
	var base := Vector2(r.position.x + CELL / 2.0, r.end.y)
	draw_line(base + Vector2(-6, -1), base + Vector2(5, -3), COLOR_LOG, 2.5)
	draw_line(base + Vector2(-5, -3), base + Vector2(6, -1), COLOR_LOG.darkened(0.2), 2.5)
	if not burning:
		draw_circle(base + Vector2(0, -2), 2.0, Color(0.25, 0.24, 0.24))
		return
	draw_circle(base + Vector2(0, -6), 9.0, Color(1.0, 0.6, 0.25, 0.10)) # soft glow
	# Three tongues of flame, each flickering on its own rhythm.
	for k in 3:
		var sway := sin(t * (7.0 + k * 2.3) + k) * 1.5
		var tall := (11.0 - absf(k - 1) * 3.0) * (0.85 + 0.15 * sin(t * (11.0 + k * 3.1)))
		var x0 := (k - 1) * 3.0
		var tip := base + Vector2(x0 + sway, -tall - 2)
		draw_colored_polygon(PackedVector2Array([base + Vector2(x0 - 3.2, -2), base + Vector2(x0 + 3.2, -2), tip]), COLOR_FLAME)
		draw_colored_polygon(PackedVector2Array([base + Vector2(x0 - 1.6, -2), base + Vector2(x0 + 1.6, -2), base.lerp(tip, 0.55) + Vector2(0, -2)]), COLOR_FLAME_CORE)
	draw_line(base + Vector2(-4, -2), base + Vector2(4, -2), COLOR_EMBER, 1.5)


func _draw_stove(r: Rect2, burning: bool, t: float) -> void:
	var body := Rect2(r.position.x + 2, r.position.y + 5, CELL - 4, CELL - 7)
	draw_rect(Rect2(body.position.x + 1, r.end.y - 2, 2, 2), COLOR_IRON) # legs
	draw_rect(Rect2(body.end.x - 3, r.end.y - 2, 2, 2), COLOR_IRON)
	draw_rect(body, COLOR_IRON)
	draw_rect(Rect2(body.position.x, body.position.y, body.size.x, 1.5), COLOR_IRON.lightened(0.25))
	draw_rect(Rect2(r.position.x + 9, r.position.y - 3, 3, 8), COLOR_IRON.darkened(0.2)) # chimney pipe
	var door := Rect2(body.position.x + 3, body.position.y + 3, body.size.x - 6, 4)
	if burning:
		draw_circle(door.get_center(), 7.0, Color(1.0, 0.6, 0.25, 0.12))
		draw_rect(door, COLOR_FLAME.lerp(COLOR_FLAME_CORE, 0.5 + 0.5 * sin(t * 6.0)))
	else:
		draw_rect(door, Color(0.12, 0.11, 0.11))


func _draw_ladder(r: Rect2) -> void:
	draw_line(r.position + Vector2(4, 0), r.position + Vector2(4, CELL), COLOR_LADDER, 1.8)
	draw_line(r.position + Vector2(12, 0), r.position + Vector2(12, CELL), COLOR_LADDER, 1.8)
	for k in 3:
		var yy := r.position.y + 3 + k * 5
		draw_line(Vector2(r.position.x + 4, yy), Vector2(r.position.x + 12, yy), COLOR_LADDER.lightened(0.1), 1.4)
		draw_circle(Vector2(r.position.x + 4, yy), 0.9, COLOR_FUR.darkened(0.3)) # rope lashing


func _draw_lichen(r: Rect2, growing: bool, t: float) -> void:
	var base := r.end.y
	draw_line(Vector2(r.position.x + 1, base - 1), Vector2(r.end.x - 1, base - 1), Color(0.30, 0.24, 0.18), 2.0) # peat tray
	var colour := COLOR_LICHEN if growing else COLOR_LICHEN.darkened(0.45)
	for k in 5:
		var cx := r.position.x + 2.5 + k * 2.8
		var size := 1.6 + 0.9 * float((k * 7) % 3) / 2.0
		if growing:
			size *= 1.0 + 0.06 * sin(t * 2.0 + k)
		draw_circle(Vector2(cx, base - 2.5 - (k % 2)), size, colour)
	if growing:
		draw_circle(Vector2(r.get_center().x, base - 3), 6.0, Color(COLOR_LICHEN, 0.10)) # faint glow


## Camps sealed in the ice are drawn faintly, as if seen through it, so the player always has somewhere to dig toward.
func _draw_camp(camp: Dictionary) -> void:
	var rect: Rect2i = camp.rect
	var found: bool = camp.found
	var alpha := 1.0 if found else 0.42
	var origin := Vector2(rect.position.x * CELL, rect.position.y * CELL)
	var size := Vector2(rect.size.x * CELL, rect.size.y * CELL)
	var floor_y := origin.y + size.y
	var canvas := Color(COLOR_CAMP_PROP, alpha)
	# A collapsed tent, its ridge pole snapped.
	var peak := Vector2(origin.x + 1.2 * CELL, floor_y - 1.5 * CELL)
	draw_colored_polygon(PackedVector2Array([Vector2(origin.x + 3, floor_y), Vector2(origin.x + 2.7 * CELL, floor_y), peak]), canvas)
	draw_colored_polygon(PackedVector2Array([Vector2(origin.x + 3, floor_y), peak, Vector2(origin.x + 0.9 * CELL, floor_y)]), canvas.darkened(0.25))
	draw_line(peak, peak + Vector2(3, -4), Color(COLOR_LOG, alpha), 1.2)
	# Their supplies, and one of them, lying where the cold found them.
	var box := Rect2(origin.x + 3.3 * CELL, floor_y - 10, 13, 10)
	draw_rect(box, Color(COLOR_CRATE, alpha))
	draw_rect(box, Color(COLOR_CRATE.darkened(0.45), alpha), false, 1.0)
	var body := Vector2(origin.x + 5.2 * CELL, floor_y - 3)
	draw_line(body, body + Vector2(18, 0), Color(COLOR_FROZEN, alpha), 5.0)
	draw_circle(body + Vector2(21, -0.5), 3.4, Color(COLOR_FROZEN, alpha))
	draw_line(body + Vector2(2, -3), body + Vector2(12, -3.5), Color(1, 1, 1, 0.35 * alpha), 1.0) # rime
	if camp.name == "the last shelter":
		for k in 9:
			var tx := origin.x + size.x - 34 + k * 3.5
			draw_line(Vector2(tx, origin.y + 6), Vector2(tx + (2.0 if k % 5 == 4 else 0.0), origin.y + 16), canvas, 1.0)
	var font := ThemeDB.fallback_font
	var label: String = String(camp.name).capitalize() if found else "?"
	draw_string(font, Vector2(origin.x + 2, origin.y - 3), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(COLOR_JOURNAL, alpha))
	if not found:
		draw_rect(Rect2(origin, size), Color(COLOR_JOURNAL, 0.30), false, 1.0)


func _draw_survivor(k: int) -> void:
	var c: WorldSim.Colonist = world.colonists[k]
	var feet := _shown[k]
	var parka: Color = PARKAS[k % PARKAS.size()]
	if not c.alive:
		# Frozen where they fell.
		draw_line(feet + Vector2(-6, -2.5), feet + Vector2(5, -2.5), parka.lerp(COLOR_FROZEN, 0.6), 5.0)
		draw_circle(feet + Vector2(7.5, -3), 3.2, COLOR_FUR.lerp(COLOR_FROZEN, 0.5))
		draw_line(feet + Vector2(-5, -4.5), feet + Vector2(4, -4.5), Color(1, 1, 1, 0.5), 1.0)
		return
	var f := _facing[k]
	var cold := clampf(1.0 - c.warmth / 100.0, 0.0, 1.0)
	var shiver := sin(_time * 48.0 + k) * 0.7 * smoothstep(0.45, 0.85, cold)
	var p := feet + Vector2(shiver, 0)
	var walking := _stride[k] > 0.0
	var digging := c.job != -1 and c.path.is_empty() and not walking
	var bob := absf(sin(_stride[k])) * -0.8 if walking else 0.0
	parka = parka.lerp(COLOR_FROZEN, cold * 0.35)

	# Legs and boots.
	for side: float in [-1.0, 1.0]:
		var swing := sin(_stride[k]) * 2.2 * side if walking else 0.0
		var hip := p + Vector2(side * 1.6, -5 + bob)
		var foot := p + Vector2(side * 1.6 + swing, -0.8)
		draw_line(hip, foot, COLOR_TROUSERS, 2.4)
		draw_line(foot + Vector2(-1.0, 0), foot + Vector2(1.6 * f, 0), COLOR_BOOTS, 1.8)

	# Parka, darker on the side away from the viewer's light, with a fur hem.
	var torso := PackedVector2Array([
		p + Vector2(-4.4, -4.4 + bob), p + Vector2(4.4, -4.4 + bob),
		p + Vector2(3.7, -11.2 + bob), p + Vector2(-3.7, -11.2 + bob)])
	draw_colored_polygon(torso, parka)
	draw_colored_polygon(PackedVector2Array([
		p + Vector2(-4.4 * f, -4.4 + bob), p + Vector2(-1.5 * f, -4.4 + bob),
		p + Vector2(-1.2 * f, -11.2 + bob), p + Vector2(-3.7 * f, -11.2 + bob)]), parka.darkened(0.25))
	draw_line(p + Vector2(-4.6, -4.6 + bob), p + Vector2(4.6, -4.6 + bob), COLOR_FUR, 1.6)

	# The working arm: swinging an ice pick when digging, otherwise swaying with the stride.
	var shoulder := p + Vector2(f * 2.2, -9.6 + bob)
	var angle := 0.0
	if digging:
		angle = -1.2 + 1.5 * (0.5 + 0.5 * sin(_time * 9.0 + k))
	elif walking:
		angle = sin(_stride[k] + PI) * 0.5
	var hand := shoulder + Vector2(f * 4.6, 0).rotated(angle * f + PI * 0.4 * f)
	draw_line(shoulder, hand, parka.darkened(0.12), 2.2)
	if digging:
		var shaft := (hand - shoulder).normalized()
		var head := hand + shaft * 4.0
		draw_line(hand, head, COLOR_LOG.lightened(0.2), 1.2)
		draw_line(head + shaft.orthogonal() * 2.5, head - shaft.orthogonal() * 2.5, Color(0.65, 0.67, 0.70), 1.4)

	# Hood with a fur ruff around a shadowed face.
	var head_center := p + Vector2(f * 0.5, -13.4 + bob)
	draw_circle(head_center, 3.7, parka)
	draw_circle(head_center + Vector2(f * 0.9, 0.2), 2.8, COLOR_FUR)
	draw_circle(head_center + Vector2(f * 1.2, 0.3), 1.9, COLOR_FACE)
	draw_circle(head_center + Vector2(f * 1.9, -0.1), 0.45, Color(0.08, 0.06, 0.05))
	if cold > 0.5:
		draw_circle(head_center + Vector2(f * 0.9, 0.2), 2.8, Color(1, 1, 1, (cold - 0.5) * 0.6)) # frost in the fur

	# A thin warmth bar, only when it matters.
	if c.warmth < 70.0:
		var bar := Rect2(feet.x - 5, feet.y - 20, 10, 1.6)
		draw_rect(bar, Color(0.05, 0.05, 0.08, 0.8))
		draw_rect(Rect2(bar.position, Vector2(bar.size.x * c.warmth / 100.0, bar.size.y)), Color(0.45, 0.65, 1.0).lerp(Color(1.0, 0.7, 0.4), c.warmth / 100.0))


func _draw_particles() -> void:
	for p in _particles:
		var age: float = 1.0 - p.life / p.max
		match p.kind:
			Particle.DRIP:
				draw_line(p.p, p.p + Vector2(0, clampf(p.v.y * 0.02, 1.0, 3.0)), COLOR_DRIP, 1.0)
			Particle.STEAM:
				draw_circle(p.p, 1.5 + age * 4.0, Color(0.85, 0.85, 0.85, 0.22 * (1.0 - age)))
			Particle.SPARK:
				draw_circle(p.p, 0.7, Color(1.0, 0.75, 0.3, 1.0 - age))
			Particle.BREATH:
				draw_circle(p.p, 1.0 + age * 2.5, Color(0.92, 0.95, 1.0, 0.35 * (1.0 - age)))
