extends RefCounted
## Simulation for the Meltwater prototype: tiles, heat, melting, meltwater and colonists.
## Pure data and rules with no rendering, so it can run headless in tests.

enum Tile { AIR, ICE, ROCK, FELT, SNOW, CRATE }
enum Build { NONE, FIRE, LADDER }

const W := 64
const H := 40
const TICKS_PER_SECOND := 10
const TICKS_PER_DAY := 600
const TARGET_DAYS := 10

const SURFACE_ROWS := 3
const FIRN_ROWS := 3
const BEDROCK_ROWS := 3
const SURFACE_TEMP := -40.0
const BEDROCK_TEMP := 2.0
const MELT_POINT := 0.0
const FREEZE_POINT := -2.0

# Share of the temperature difference two neighbouring tiles exchange per tick, indexed by Tile.
const CONDUCT := [0.12, 0.06, 0.04, 0.004, 0.012, 0.05]
const WATER_CONDUCT := 0.09
const CONVECTION := 0.08
const ICE_RELAX := 0.002 # how strongly ice drifts back to the glacier's own temperature
const MELT_RATE := 0.015
const COLLAPSE_INTEGRITY := 0.45
const REFROZEN_INTEGRITY := 0.55
const FIRE_HEAT := 3.0
const FIRE_MAX_TEMP := 35.0
const FIRE_FUEL_PER_TICK := 0.025
const FIRE_DROWN_WATER := 0.8
const FIRE_BOIL_RATE := 0.05
const BODY_HEAT := 0.25
const CRATE_FUEL := 20.0
const START_FUEL := 60.0
const START_FELT := 10
const MAX_MESSAGES := 5


class Colonist:
	var name: String
	var pos: Vector2i
	var warmth := 100.0
	var alive := true
	var wet := false
	var path: Array[Vector2i] = []
	var job := -1 # index of the cell being dug, or -1
	var dig_progress := 0.0
	var move_cooldown := 0
	var idle_ticks := 0

	func _init(colonist_name: String, start: Vector2i) -> void:
		name = colonist_name
		pos = start


var tiles := PackedInt32Array()
var temp := PackedFloat32Array()
var integrity := PackedFloat32Array()
var water := PackedFloat32Array()
var build := PackedInt32Array()
var dig_mark := PackedByteArray()
var reserved := {} # cell index -> Colonist digging it

var colonists: Array[Colonist] = []
var fuel := START_FUEL
var felt := START_FELT
var snow := 0
var ticks := 0
var messages: Array[String] = []
var rng := RandomNumberGenerator.new()

var _last_melt_message := -10000
var _last_collapse_message := -10000
var _fuel_warned := false


func _init(seed_value: int = 1) -> void:
	rng.seed = seed_value
	_generate()


# --- Queries -----------------------------------------------------------------

func idx(x: int, y: int) -> int:
	return y * W + x


func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < W and y >= 0 and y < H


func tile_at(x: int, y: int) -> int:
	return tiles[idx(x, y)] if in_bounds(x, y) else Tile.ROCK


func is_solid(x: int, y: int) -> bool:
	return tile_at(x, y) != Tile.AIR


func is_passable(x: int, y: int) -> bool:
	return in_bounds(x, y) and tiles[idx(x, y)] == Tile.AIR


func has_ladder(x: int, y: int) -> bool:
	return in_bounds(x, y) and build[idx(x, y)] == Build.LADDER


func is_standable(x: int, y: int) -> bool:
	if not is_passable(x, y):
		return false
	return is_solid(x, y + 1) or has_ladder(x, y) or has_ladder(x, y + 1)


func is_diggable(i: int) -> bool:
	var t := tiles[i]
	return t == Tile.ICE or t == Tile.SNOW or t == Tile.CRATE or t == Tile.FELT


func fire_is_burning(i: int) -> bool:
	return build[i] == Build.FIRE and fuel > 0.0 and water[i] <= FIRE_DROWN_WATER


## How deep and therefore how old the ice is, from 0 at the surface to 1 at bedrock.
func ice_age(y: int) -> float:
	return clampf(float(y - SURFACE_ROWS) / float(H - BEDROCK_ROWS - SURFACE_ROWS), 0.0, 1.0)


## The glacier's own temperature: very cold near the surface, close to melting near bedrock.
func base_temp(y: int) -> float:
	return lerpf(-14.0, -3.0, ice_age(y))


func day() -> int:
	return ticks / TICKS_PER_DAY


func alive_count() -> int:
	var n := 0
	for c in colonists:
		if c.alive:
			n += 1
	return n


func is_won() -> bool:
	return ticks >= TARGET_DAYS * TICKS_PER_DAY and alive_count() > 0


func is_lost() -> bool:
	return alive_count() == 0


func is_over() -> bool:
	return is_won() or is_lost()


func colonist_at(x: int, y: int) -> Colonist:
	for c in colonists:
		if c.alive and c.pos.x == x and c.pos.y == y:
			return c
	return null


func describe(x: int, y: int) -> String:
	if not in_bounds(x, y):
		return ""
	var i := idx(x, y)
	var names := ["Air", "Ice", "Stone", "Felt wall", "Snow", "Salvage crate"]
	var text: String = names[tiles[i]]
	if y < SURFACE_ROWS:
		text = "Surface storm"
	text += ", %.1f°C" % temp[i]
	if tiles[i] == Tile.ICE or tiles[i] == Tile.SNOW:
		text += ", strength %d%%" % roundi(integrity[i] * 100.0)
	if water[i] > 0.02:
		text += ", water %d%%" % roundi(water[i] * 100.0)
	if build[i] == Build.FIRE:
		text += ", fire" + ("" if fire_is_burning(i) else " (out)")
	elif build[i] == Build.LADDER:
		text += ", ladder"
	return text


func log_message(text: String) -> void:
	messages.append(text)
	while messages.size() > MAX_MESSAGES:
		messages.remove_at(0)


# --- Player actions ----------------------------------------------------------

func set_dig_mark(x: int, y: int, on: bool) -> void:
	if not in_bounds(x, y):
		return
	var i := idx(x, y)
	if on and is_diggable(i):
		dig_mark[i] = 1
	elif not on:
		dig_mark[i] = 0


func place_fire(x: int, y: int) -> bool:
	if not is_standable(x, y):
		return false
	var i := idx(x, y)
	if build[i] != Build.NONE or water[i] > FIRE_DROWN_WATER or y < SURFACE_ROWS:
		return false
	build[i] = Build.FIRE
	# Fires sit on a stone hearth, or they would melt straight through the floor.
	var below := idx(x, y + 1)
	if tiles[below] != Tile.ROCK:
		tiles[below] = Tile.ROCK
		integrity[below] = 1.0
		dig_mark[below] = 0
	return true


func place_ladder(x: int, y: int) -> bool:
	if not is_passable(x, y) or y < SURFACE_ROWS:
		return false
	var i := idx(x, y)
	if build[i] != Build.NONE:
		return false
	build[i] = Build.LADDER
	return true


func place_block(x: int, y: int, kind: int) -> bool:
	if not is_passable(x, y) or y < SURFACE_ROWS or colonist_at(x, y) != null:
		return false
	var i := idx(x, y)
	if build[i] != Build.NONE:
		return false
	if kind == Tile.FELT:
		if felt <= 0:
			return false
		felt -= 1
		integrity[i] = 1.0
	elif kind == Tile.SNOW:
		if snow <= 0:
			return false
		snow -= 1
		integrity[i] = 0.6
	else:
		return false
	tiles[i] = kind
	water[i] = 0.0
	return true


func clear_at(x: int, y: int) -> void:
	if not in_bounds(x, y):
		return
	var i := idx(x, y)
	dig_mark[i] = 0
	build[i] = Build.NONE


# --- Simulation --------------------------------------------------------------

func tick() -> void:
	if is_over():
		return
	ticks += 1
	_tick_fires()
	_tick_conduction()
	_tick_phase_changes()
	_tick_water()
	_tick_collapse()
	for c in colonists:
		_tick_colonist(c)
	if ticks % TICKS_PER_DAY == 0 and not is_over():
		log_message("Day %d begins." % (day() + 1))
	if is_won():
		log_message("Day %d reached with %d alive. The colony holds, for now." % [TARGET_DAYS, alive_count()])
	elif is_lost():
		log_message("Nobody is left. The ice keeps them.")


func _tick_fires() -> void:
	for i in build.size():
		if build[i] != Build.FIRE:
			continue
		if not is_solid(i % W, i / W + 1):
			build[i] = Build.NONE
			log_message("A fire fell through the melting floor and went out.")
			continue
		if not fire_is_burning(i):
			continue
		fuel = maxf(fuel - FIRE_FUEL_PER_TICK, 0.0)
		temp[i] = minf(maxf(temp[i], 0.0) + FIRE_HEAT, FIRE_MAX_TEMP)
		water[i] = maxf(water[i] - FIRE_BOIL_RATE, 0.0) # drips hiss away, a flood puts it out
	if fuel <= 0.0 and not _fuel_warned:
		_fuel_warned = true
		log_message("Out of fuel. The fires are dying.")
	elif fuel > 0.0:
		_fuel_warned = false


func _conductivity(i: int) -> float:
	if tiles[i] == Tile.AIR and water[i] > 0.3:
		return WATER_CONDUCT
	return CONDUCT[tiles[i]]


func _tick_conduction() -> void:
	var next := temp.duplicate()
	for y in H:
		for x in W:
			var i := idx(x, y)
			var ki := _conductivity(i)
			if x + 1 < W:
				var j := i + 1
				var flow := (temp[i] - temp[j]) * minf(ki, _conductivity(j)) * 0.5
				next[i] -= flow
				next[j] += flow
			if y + 1 < H:
				var j := i + W
				var flow := (temp[i] - temp[j]) * minf(ki, _conductivity(j)) * 0.5
				# Warm air rises: extra heat moves up out of an air tile that is warmer than the one above.
				if tiles[j] == Tile.AIR and water[j] <= 0.3 and temp[j] > temp[i]:
					flow += (temp[i] - temp[j]) * CONVECTION
				next[i] -= flow
				next[j] += flow
	temp = next
	# Fixed boundaries: the storm above and the faint warmth of bedrock below.
	for y in H:
		for x in W:
			var i := idx(x, y)
			if y < SURFACE_ROWS:
				temp[i] = SURFACE_TEMP
			elif y == H - 1:
				temp[i] = BEDROCK_TEMP
			elif tiles[i] == Tile.ICE or tiles[i] == Tile.SNOW:
				# The glacier is huge; local heat only bends its temperature for a while.
				temp[i] += (base_temp(y) - temp[i]) * ICE_RELAX


func _tick_phase_changes() -> void:
	for i in tiles.size():
		var t := tiles[i]
		if t == Tile.ICE or t == Tile.SNOW:
			if temp[i] > MELT_POINT:
				var excess := temp[i] - MELT_POINT
				integrity[i] -= excess * MELT_RATE * (2.0 if t == Tile.SNOW else 1.0)
				temp[i] = MELT_POINT + excess * 0.5 # melting soaks up heat
				if integrity[i] <= 0.0:
					_melt(i, 0.3 if t == Tile.SNOW else 0.6)
		elif t == Tile.AIR and water[i] > 0.0 and temp[i] < FREEZE_POINT:
			var x := i % W
			var y := i / W
			if water[i] >= 0.5 and colonist_at(x, y) == null:
				tiles[i] = Tile.ICE
				integrity[i] = REFROZEN_INTEGRITY * water[i]
				water[i] = 0.0
				build[i] = Build.NONE
				temp[i] += 1.0 # freezing gives heat back
			else:
				water[i] = maxf(water[i] - 0.004, 0.0)


func _melt(i: int, amount: float) -> void:
	tiles[i] = Tile.AIR
	integrity[i] = 0.0
	water[i] = minf(water[i] + amount, 1.0)
	dig_mark[i] = 0
	reserved.erase(i)
	if ticks - _last_melt_message > 300:
		_last_melt_message = ticks
		log_message("The ice is melting. Water is running.")


func _tick_water() -> void:
	for y in range(H - 2, -1, -1):
		var left_to_right := (ticks + y) % 2 == 0
		for k in W:
			var x := k if left_to_right else W - 1 - k
			var i := idx(x, y)
			if tiles[i] != Tile.AIR or water[i] <= 0.0:
				continue
			var below := i + W
			if tiles[below] == Tile.AIR and water[below] < 1.0:
				var move := minf(water[i], 1.0 - water[below])
				water[i] -= move
				water[below] += move
			for dx: int in [-1, 1]:
				var nx := x + dx
				if nx < 0 or nx >= W:
					continue
				var j := i + dx
				if tiles[j] == Tile.AIR and water[j] < water[i]:
					var share := (water[i] - water[j]) * 0.25
					water[i] -= share
					water[j] += share
			if water[i] < 0.02:
				water[i] = 0.0


func _tick_collapse() -> void:
	for y in range(H - 2, -1, -1):
		for x in W:
			var i := idx(x, y)
			var t := tiles[i]
			if (t != Tile.ICE and t != Tile.SNOW) or integrity[i] >= COLLAPSE_INTEGRITY:
				continue
			var below := i + W
			if tiles[below] != Tile.AIR:
				continue
			if is_solid(x - 1, y) and is_solid(x + 1, y):
				continue # still wedged between its neighbours, like a keystone
			var victim := colonist_at(x, y + 1)
			if victim != null:
				# The block shatters on whoever is underneath.
				tiles[i] = Tile.AIR
				integrity[i] = 0.0
				dig_mark[i] = 0
				reserved.erase(i)
				victim.warmth -= 30.0
				log_message("%s was hit by falling ice." % victim.name)
				continue
			_drop_block(i, below)


func _drop_block(from: int, to: int) -> void:
	tiles[to] = tiles[from]
	integrity[to] = integrity[from]
	var t := temp[to]
	temp[to] = temp[from]
	temp[from] = t
	water[from] = water[to]
	water[to] = 0.0
	if build[to] == Build.FIRE:
		log_message("Falling ice smothered a fire.")
	build[to] = Build.NONE
	dig_mark[to] = dig_mark[from]
	dig_mark[from] = 0
	reserved.erase(from)
	tiles[from] = Tile.AIR
	integrity[from] = 0.0
	if ticks - _last_collapse_message > 300:
		_last_collapse_message = ticks
		log_message("Weakened ice is falling.")


# --- Colonists ---------------------------------------------------------------

func _tick_colonist(c: Colonist) -> void:
	if not c.alive:
		return
	var i := idx(c.pos.x, c.pos.y)
	temp[i] += BODY_HEAT # people are heat sources too

	var t := temp[i]
	c.wet = water[i] > 0.3
	if c.wet:
		# Wet clothes steal heat fast, and twice as fast below freezing.
		c.warmth -= 0.08 + maxf(-t, 0.0) * 0.04
	elif t < 0.0:
		c.warmth -= -t * 0.02
	elif t > 6.0:
		c.warmth += 0.25
	else:
		c.warmth += 0.05
	c.warmth = clampf(c.warmth, 0.0, 100.0)
	if c.warmth <= 0.0:
		c.alive = false
		_release_job(c)
		log_message("%s froze." % c.name)
		return

	# Gravity comes before any choice.
	if not is_standable(c.pos.x, c.pos.y) and is_passable(c.pos.x, c.pos.y + 1):
		c.pos.y += 1
		if not c.path.is_empty() and c.path[0] == c.pos:
			c.path.remove_at(0)
		return

	if c.move_cooldown > 0:
		c.move_cooldown -= 1
		return

	if c.job != -1 and (dig_mark[c.job] == 0 or not is_diggable(c.job)):
		_release_job(c)
	if c.job == -1 and c.path.is_empty():
		_find_job(c)
		if c.job == -1:
			c.idle_ticks += 1
			if c.idle_ticks % 15 == 1:
				_seek_warmth(c)

	if not c.path.is_empty():
		_step(c)
		return

	if c.job != -1:
		var jx := c.job % W
		var jy := c.job / W
		if absi(jx - c.pos.x) > 1 or absi(jy - c.pos.y) > 1:
			_release_job(c)
			return
		c.dig_progress += 1.0
		if c.dig_progress >= _dig_ticks(c.job):
			_complete_dig(c)


func _step(c: Colonist) -> void:
	var nxt: Vector2i = c.path[0]
	if absi(nxt.y - c.pos.y) > 1:
		# A drop: walk off the edge and let gravity finish the move.
		var edge := Vector2i(nxt.x, c.pos.y)
		if not is_passable(edge.x, edge.y):
			_release_job(c)
			return
		c.pos = edge
	else:
		if not is_passable(nxt.x, nxt.y):
			_release_job(c)
			return
		c.pos = nxt
		c.path.remove_at(0)
	c.move_cooldown = 3 if c.wet else 2


func _dig_ticks(i: int) -> float:
	match tiles[i]:
		Tile.ICE:
			return 10.0 + 20.0 * integrity[i]
		Tile.SNOW:
			return 6.0
		Tile.CRATE:
			return 15.0
		Tile.FELT:
			return 5.0
	return 10.0


func _complete_dig(c: Colonist) -> void:
	var i := c.job
	match tiles[i]:
		Tile.ICE, Tile.SNOW:
			snow += 1 # chipped ice packs into snow blocks
		Tile.CRATE:
			fuel += CRATE_FUEL
			log_message("%s opened an old expedition crate: +%d fuel." % [c.name, int(CRATE_FUEL)])
		Tile.FELT:
			felt += 1
	tiles[i] = Tile.AIR
	integrity[i] = 0.0
	dig_mark[i] = 0
	_release_job(c)


func _release_job(c: Colonist) -> void:
	if c.job != -1:
		reserved.erase(c.job)
	c.job = -1
	c.dig_progress = 0.0
	c.path.clear()


func _find_job(c: Colonist) -> void:
	if not is_standable(c.pos.x, c.pos.y):
		return
	var result := _bfs(c.pos, 2500)
	for p: Vector2i in result.order:
		var target := _dig_target_near(p)
		if target != -1:
			c.job = target
			c.idle_ticks = 0
			c.dig_progress = 0.0
			reserved[target] = c
			c.path = _path_to(result.came, c.pos, p)
			return


func _dig_target_near(p: Vector2i) -> int:
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var x := p.x + dx
			var y := p.y + dy
			if not in_bounds(x, y):
				continue
			var j := idx(x, y)
			if dig_mark[j] == 1 and not reserved.has(j) and is_diggable(j):
				return j
	return -1


func _seek_warmth(c: Colonist) -> void:
	if not is_standable(c.pos.x, c.pos.y) or c.warmth >= 95.0:
		return
	var result := _bfs(c.pos, 800)
	var here: float = temp[idx(c.pos.x, c.pos.y)]
	var best := c.pos
	var best_score := here
	for k in result.order.size():
		var p: Vector2i = result.order[k]
		# Prefer warm spots, but not ones far across the base.
		var score: float = temp[idx(p.x, p.y)] - 0.02 * k
		var other := colonist_at(p.x, p.y)
		if other != null and other != c:
			score -= 3.0 # leave room for the others around the fire
		if score > best_score + 1.0:
			best_score = score
			best = p
	if best != c.pos:
		c.path = _path_to(result.came, c.pos, best)


func _neighbors(p: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for dx: int in [-1, 1]:
		var x := p.x + dx
		if is_standable(x, p.y):
			out.append(Vector2i(x, p.y))
		elif is_standable(x, p.y - 1) and is_passable(p.x, p.y - 1):
			out.append(Vector2i(x, p.y - 1)) # step up
		elif is_passable(x, p.y):
			# Step or drop down to wherever we land.
			var land := p.y + 1
			while land < H and not is_standable(x, land) and is_passable(x, land) and land - p.y <= 8:
				land += 1
			if is_standable(x, land):
				out.append(Vector2i(x, land))
	if (has_ladder(p.x, p.y) or has_ladder(p.x, p.y - 1)) and is_passable(p.x, p.y - 1):
		out.append(Vector2i(p.x, p.y - 1))
	if has_ladder(p.x, p.y + 1) and is_passable(p.x, p.y + 1):
		out.append(Vector2i(p.x, p.y + 1))
	return out


func _bfs(start: Vector2i, limit: int) -> Dictionary:
	var came := {start: start}
	var order: Array[Vector2i] = [start]
	var head := 0
	while head < order.size() and order.size() < limit:
		var p: Vector2i = order[head]
		head += 1
		for n in _neighbors(p):
			if not came.has(n):
				came[n] = p
				order.append(n)
	return {"came": came, "order": order}


func _path_to(came: Dictionary, start: Vector2i, goal: Vector2i) -> Array[Vector2i]:
	var path: Array[Vector2i] = []
	var p := goal
	while p != start:
		path.push_front(p)
		p = came[p]
	return path


# --- World generation --------------------------------------------------------

func _generate() -> void:
	var n := W * H
	tiles.resize(n)
	temp.resize(n)
	integrity.resize(n)
	water.resize(n)
	build.resize(n)
	dig_mark.resize(n)
	for y in H:
		for x in W:
			var i := idx(x, y)
			water[i] = 0.0
			build[i] = Build.NONE
			dig_mark[i] = 0
			if y < SURFACE_ROWS:
				tiles[i] = Tile.AIR
				temp[i] = SURFACE_TEMP
				integrity[i] = 0.0
			elif y < SURFACE_ROWS + FIRN_ROWS:
				tiles[i] = Tile.SNOW # packed firn on top of the glacier
				temp[i] = base_temp(y)
				integrity[i] = 0.5
			elif y >= H - BEDROCK_ROWS:
				tiles[i] = Tile.ROCK
				temp[i] = BEDROCK_TEMP
				integrity[i] = 1.0
			else:
				tiles[i] = Tile.ICE
				temp[i] = base_temp(y)
				integrity[i] = 0.6 + 0.4 * ice_age(y)

	# The small pocket the survivors cut on the way in.
	for y in range(14, 18):
		for x in range(26, 38):
			var i := idx(x, y)
			tiles[i] = Tile.AIR
			temp[i] = -7.0
			integrity[i] = 0.0

	# Crates left behind by earlier expeditions.
	var placed := 0
	while placed < 16:
		var x := rng.randi_range(2, W - 3)
		var y := rng.randi_range(SURFACE_ROWS + FIRN_ROWS + 2, H - BEDROCK_ROWS - 1)
		var i := idx(x, y)
		var near_camp := x >= 22 and x <= 41 and y >= 12 and y <= 19
		if tiles[i] == Tile.ICE and not near_camp:
			tiles[i] = Tile.CRATE
			integrity[i] = 1.0
			placed += 1

	var names := ["Ada", "Tomas", "Ines"]
	for k in names.size():
		colonists.append(Colonist.new(names[k], Vector2i(29 + k * 3, 17)))
	log_message("Three survivors reach the ice. Keep them warm.")
