extends SceneTree
## Headless checks for the simulation rules. Run with:
##   godot --headless --path . --script res://tests/sim_test.gd

const WorldSim := preload("res://scripts/world.gd")

var _failures := 0


func _init() -> void:
	if not (WorldSim as Script).can_instantiate():
		print("FAIL world.gd did not compile")
		quit(1)
		return
	_test_generation()
	_test_cold_without_fire()
	_test_fire_melts_ceiling()
	_test_digging()
	_test_meltwater_refreezes()
	_test_felt_insulates()
	_test_food()
	_test_journal()
	_test_camp_discovery()
	_test_lichen_grows_food()
	_test_stove_saves_fuel()
	_test_full_run()
	if _failures == 0:
		print("All simulation checks passed.")
	quit(1 if _failures > 0 else 0)


func _check(ok: bool, what: String) -> void:
	if ok:
		print("  ok   ", what)
	else:
		_failures += 1
		print("  FAIL ", what)


func _run(world: WorldSim, n: int) -> void:
	for k in n:
		world.tick()


func _count(world: WorldSim, tile: int) -> int:
	var n := 0
	for t in world.tiles:
		if t == tile:
			n += 1
	return n


func _test_generation() -> void:
	print("generation")
	var world := WorldSim.new(3)
	_check(world.colonists.size() == 3, "three colonists")
	for c in world.colonists:
		_check(world.is_standable(c.pos.x, c.pos.y), "%s starts on solid ground" % c.name)
	_check(_count(world, WorldSim.Tile.CRATE) == 16, "sixteen salvage crates")


func _test_cold_without_fire() -> void:
	print("cold without fire")
	var world := WorldSim.new(3)
	_run(world, WorldSim.TICKS_PER_DAY)
	var c: WorldSim.Colonist = world.colonists[0]
	print("    warmth after one day with no fire: %.1f" % c.warmth)
	_check(c.warmth < 100.0, "colonists lose warmth in the cold")
	_run(world, WorldSim.TICKS_PER_DAY * 2)
	print("    alive after three days with no fire: %d" % world.alive_count())
	_check(world.alive_count() == 0, "nobody survives three days without heat")


func _test_fire_melts_ceiling() -> void:
	print("fire melts the ceiling")
	var world := WorldSim.new(3)
	var ice_before := _count(world, WorldSim.Tile.ICE)
	_check(world.place_fire(32, 17), "fire placed in the cave")
	_run(world, WorldSim.TICKS_PER_DAY)
	var total_water := 0.0
	for w in world.water:
		total_water += w
	var ice_after := _count(world, WorldSim.Tile.ICE)
	print("    ice tiles %d -> %d, water %.2f, cave air %.1f°C, fuel %.1f" % [ice_before, ice_after, total_water, world.temp[world.idx(32, 15)], world.fuel])
	_check(ice_after < ice_before or total_water > 0.0, "heat melts nearby ice")
	_check(world.fuel < WorldSim.START_FUEL, "fire burns fuel")
	var warm := 0
	for c in world.colonists:
		if c.alive and c.warmth > 80.0:
			warm += 1
	_check(warm == 3, "colonists stay warm near the fire")


func _test_digging() -> void:
	print("digging")
	var world := WorldSim.new(3)
	world.set_dig_mark(38, 17, true)
	world.set_dig_mark(39, 17, true)
	_run(world, 200)
	_check(world.tile_at(38, 17) == WorldSim.Tile.AIR, "first marked tile dug out")
	_check(world.tile_at(39, 17) == WorldSim.Tile.AIR, "second marked tile dug out")
	_check(world.snow >= 2, "digging ice yields snow")


func _test_meltwater_refreezes() -> void:
	print("meltwater refreezes")
	var world := WorldSim.new(3)
	var i := world.idx(27, 17)
	world.water[i] = 1.0
	world.temp[i] = -10.0
	_run(world, 5)
	_check(world.tiles[i] == WorldSim.Tile.ICE, "water in the cold freezes into ice")
	_check(world.integrity[i] < 0.6, "refrozen ice is weaker than glacier ice")


func _test_felt_insulates() -> void:
	print("felt insulates")
	var plain := WorldSim.new(3)
	var lined := WorldSim.new(3)
	for w: WorldSim in [plain, lined]:
		w.fuel = 1000.0
		w.place_fire(32, 17)
	# Line the cave ceiling with felt in one world.
	lined.felt = 100
	for x in range(26, 38):
		lined.place_block(x, 14, WorldSim.Tile.FELT)
	_run(plain, WorldSim.TICKS_PER_DAY * 2)
	_run(lined, WorldSim.TICKS_PER_DAY * 2)
	var plain_strength := _total_strength(plain)
	var lined_strength := _total_strength(lined)
	print("    ceiling strength lost in two days: bare %.2f, felt-lined %.2f" % [plain_strength.x - plain_strength.y, lined_strength.x - lined_strength.y])
	_check(lined_strength.x - lined_strength.y < plain_strength.x - plain_strength.y, "a felt-lined ceiling melts less")


## Returns (strength of a fresh world, strength of this world) summed over the ice above the cave.
func _total_strength(world: WorldSim) -> Vector2:
	var fresh := WorldSim.new(3)
	var a := 0.0
	var b := 0.0
	for y in range(6, 14):
		for x in range(20, 44):
			var i := world.idx(x, y)
			if fresh.tiles[i] == WorldSim.Tile.ICE:
				a += fresh.integrity[i]
			if world.tiles[i] == WorldSim.Tile.ICE:
				b += world.integrity[i]
	return Vector2(a, b)


func _test_food() -> void:
	print("food")
	var world := WorldSim.new(3)
	world.place_fire(32, 17)
	_run(world, WorldSim.TICKS_PER_DAY)
	print("    rations after one day: %.2f" % world.food)
	_check(absf(world.food - (WorldSim.START_FOOD - 3.0)) < 0.05, "three colonists eat three rations a day")
	_run(world, WorldSim.TICKS_PER_DAY * 2)
	_check(world.food == 0.0, "rations run out after three days")


func _test_journal() -> void:
	print("journal")
	var world := WorldSim.new(3)
	_check(world.journal_step == 0, "the journal starts at its first entry")
	world.place_fire(32, 17)
	world.tick()
	_check(world.journal_step == 1, "lighting a fire completes the first entry")
	world.crates_opened = 1
	world.tick()
	_check(world.journal_step == 2, "opening a crate completes the second entry")
	_check(not world.is_won(), "the run is not won early")


func _test_camp_discovery() -> void:
	print("frozen camps")
	var world := WorldSim.new(3)
	_check(world.camps.size() == 3, "three frozen camps")
	var hut: Rect2i = world.camps[0].rect
	# Put Ada in a pocket just east of the survey hut and have her dig through its wall.
	var stand := Vector2i(hut.end.x + 1, hut.end.y - 1)
	var wall := Vector2i(hut.end.x, hut.end.y - 1)
	world.tiles[world.idx(stand.x, stand.y)] = WorldSim.Tile.AIR
	world.colonists[0].pos = stand
	world.set_dig_mark(wall.x, wall.y, true)
	var food_before := world.food
	_run(world, 80)
	_check(world.camps[0].found, "digging into the survey hut discovers it")
	_check(world.lichen_unlocked, "the survey hut unlocks the lichen bed")
	_check(world.food > food_before, "the survey hut holds food")
	_check(not world.camps[1].found, "other camps stay sealed")


func _test_lichen_grows_food() -> void:
	print("lichen")
	var plain := WorldSim.new(3)
	var farm := WorldSim.new(3)
	for w: WorldSim in [plain, farm]:
		w.place_fire(32, 17)
	_check(not farm.place_lichen(30, 17), "lichen needs its blueprint")
	farm.lichen_unlocked = true
	farm.snow = 4
	_check(farm.place_lichen(31, 17) and farm.place_lichen(33, 17), "two lichen beds placed beside the fire")
	_run(plain, WorldSim.TICKS_PER_DAY)
	_run(farm, WorldSim.TICKS_PER_DAY)
	print("    rations after a day: bare %.2f, with lichen %.2f" % [plain.food, farm.food])
	_check(farm.food >= plain.food + 1.5, "warm lichen beds grow food")


func _test_stove_saves_fuel() -> void:
	print("peat stove")
	var fire := WorldSim.new(3)
	var stove := WorldSim.new(3)
	fire.place_fire(32, 17)
	_check(not stove.place_stove(32, 17), "the stove needs its blueprint")
	stove.stove_unlocked = true
	_check(stove.place_stove(32, 17), "stove placed")
	_run(fire, WorldSim.TICKS_PER_DAY)
	_run(stove, WorldSim.TICKS_PER_DAY)
	print("    fuel used in a day: fire %.1f, stove %.1f; cave air fire %.1f°C, stove %.1f°C" % [
		WorldSim.START_FUEL - fire.fuel, WorldSim.START_FUEL - stove.fuel, fire.temp[fire.idx(30, 16)], stove.temp[stove.idx(30, 16)]])
	_check(WorldSim.START_FUEL - stove.fuel < 0.5 * (WorldSim.START_FUEL - fire.fuel), "the stove burns under half the fuel")
	var warm := 0
	for c in stove.colonists:
		if c.warmth > 80.0:
			warm += 1
	_check(warm == 3, "a stove keeps everyone warm")


func _test_full_run() -> void:
	print("ten days with one fire and no other help")
	var world := WorldSim.new(3)
	world.place_fire(32, 17)
	var start := Time.get_ticks_msec()
	var n := WorldSim.TICKS_PER_DAY * 10
	_run(world, n)
	var ms := Time.get_ticks_msec() - start
	print("    alive %d, fuel %.1f, food %.1f, ice %d, %.2f ms per tick" % [world.alive_count(), world.fuel, world.food, _count(world, WorldSim.Tile.ICE), float(ms) / n])
	for m in world.messages:
		print("    log: ", m)
	_check(world.is_lost(), "sitting still is not enough to survive")
