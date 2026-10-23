extends Node2D
## Plays the game's sounds: the wind and the deep ice as ambience, a crackle for every burning
## fire, a heartbeat when someone is close to freezing, and one-off sounds for whatever the
## simulation reports in world.events. The sounds themselves are made by tools/make_sounds.py.
## Positions are local to this node, as in WorldView, so (0, 0) is the top-left corner of the world.

const WorldSim := preload("res://scripts/world.gd")

const CELL := 16
const POOL_SIZE := 24
const MAX_FIRE_LOOPS := 8
const HEARING := 1300.0 # screen pixels at which a sound has faded out completely
const HEARTBEAT_WARMTH := 25.0 # below this, you hear the coldest survivor's heart

const SOUNDS := {
	"wind": [preload("res://sounds/wind.ogg")],
	"deep": [preload("res://sounds/deep.ogg")],
	"groan": [preload("res://sounds/groan_1.ogg"), preload("res://sounds/groan_2.ogg")],
	"heartbeat": [preload("res://sounds/heartbeat.ogg")],
	"fire": [preload("res://sounds/fire.ogg")],
	"stove": [preload("res://sounds/stove.ogg")],
	"ignite": [preload("res://sounds/ignite.ogg")],
	"hiss": [preload("res://sounds/hiss.ogg")],
	"fizzle": [preload("res://sounds/fizzle.ogg")],
	"drip": [preload("res://sounds/drip_1.ogg"), preload("res://sounds/drip_2.ogg"), preload("res://sounds/drip_3.ogg")],
	"tap": [preload("res://sounds/tap_1.ogg"), preload("res://sounds/tap_2.ogg")],
	"melt": [preload("res://sounds/melt.ogg")],
	"freeze": [preload("res://sounds/freeze.ogg")],
	"chip_ice": [preload("res://sounds/chip_ice_1.ogg"), preload("res://sounds/chip_ice_2.ogg"), preload("res://sounds/chip_ice_3.ogg")],
	"chip_snow": [preload("res://sounds/chip_snow_1.ogg"), preload("res://sounds/chip_snow_2.ogg")],
	"step": [preload("res://sounds/step_1.ogg"), preload("res://sounds/step_2.ogg"), preload("res://sounds/step_3.ogg")],
	"crack": [preload("res://sounds/crack_1.ogg"), preload("res://sounds/crack_2.ogg")],
	"fall": [preload("res://sounds/fall.ogg")],
	"crate": [preload("res://sounds/crate.ogg")],
	"place": [preload("res://sounds/place.ogg")],
	"knock": [preload("res://sounds/knock.ogg")],
	"click": [preload("res://sounds/click.ogg")],
	"camp": [preload("res://sounds/camp.ogg")],
	"journal": [preload("res://sounds/journal.ogg")],
	"blueprint": [preload("res://sounds/blueprint.ogg")],
	"death": [preload("res://sounds/death.ogg")],
	"won": [preload("res://sounds/won.ogg")],
	"lost": [preload("res://sounds/lost.ogg")],
}

# How each one-off sound plays: volume in dB, the shortest gap between two plays in seconds
# (so a big thaw is one slosh, not fifty), and how much the pitch may vary.
const ONE_SHOTS := {
	"chip_ice": [-5.0, 0.04, 0.08],
	"chip_snow": [-7.0, 0.04, 0.10],
	"step": [-15.0, 0.05, 0.12],
	"crack": [-3.0, 0.25, 0.10],
	"melt": [-11.0, 0.45, 0.15],
	"freeze": [-12.0, 0.60, 0.10],
	"fall": [0.0, 0.15, 0.08],
	"hiss": [-5.0, 0.30, 0.10],
	"fizzle": [-7.0, 0.20, 0.10],
	"crate": [-3.0, 0.20, 0.05],
	"drip": [-13.0, 0.07, 0.15],
	"tap": [-18.0, 0.05, 0.15],
	"ignite": [-4.0, 0.10, 0.05],
	"place": [-7.0, 0.05, 0.10],
	"knock": [-6.0, 0.05, 0.08],
	"click": [-12.0, 0.03, 0.03],
}

# Story moments play one at a time; a more important one is never cut off by a lesser one.
const STING_PRIORITY := {"journal": 1, "blueprint": 2, "camp": 3, "death": 4, "lost": 5, "won": 5}
const STING_VOLUME := {"journal": -9.0, "blueprint": -8.0, "camp": -5.0, "death": -5.0, "lost": -3.0, "won": -3.0}

var world: WorldSim
var depth := 0.0 ## 0 when the view is at the surface, 1 at bedrock; set by the camera owner

var _pool: Array[AudioStreamPlayer2D] = []
var _next := 0
var _ui: AudioStreamPlayer
var _sting: AudioStreamPlayer
var _sting_priority := 0
var _wind: AudioStreamPlayer
var _deep: AudioStreamPlayer
var _heart: AudioStreamPlayer
var _fires := {} # cell index * 8 + build kind -> AudioStreamPlayer2D
var _last_played := {}
var _time := 0.0
var _groan_in := 20.0


func _ready() -> void:
	_make_bus("Ambience", 4.0)
	var effects := _make_bus("Effects", 8.0)
	if AudioServer.get_bus_effect_count(effects) == 0:
		# The glacier is one big hollow: give every effect a little cave behind it.
		var cave := AudioEffectReverb.new()
		cave.room_size = 0.7
		cave.damping = 0.55
		cave.spread = 0.8
		cave.hipass = 0.15
		cave.dry = 1.0
		cave.wet = 0.2
		AudioServer.add_bus_effect(effects, cave)
	_make_bus("Stings", 6.0)
	if AudioServer.get_bus_effect_count(0) == 0:
		var limiter := AudioEffectHardLimiter.new() # a collapse, a sting and three fires at once must not clip
		limiter.ceiling_db = -0.5
		AudioServer.add_bus_effect(0, limiter)
	for k in POOL_SIZE:
		var player := AudioStreamPlayer2D.new()
		player.bus = "Effects"
		player.max_distance = HEARING
		player.attenuation = 1.2
		player.panning_strength = 0.7
		add_child(player)
		_pool.append(player)
	for sound in ["fire", "stove"]:
		(SOUNDS[sound][0] as AudioStreamOggVorbis).loop = true
	_ui = _player("Effects")
	_sting = _player("Stings")
	_wind = _loop_player("wind", "Ambience")
	_deep = _loop_player("deep", "Ambience")
	_heart = _loop_player("heartbeat", "Ambience")
	_heart.volume_db = -60.0


func set_world(new_world: WorldSim) -> void:
	world = new_world
	world.events.clear()
	for key: int in _fires.keys():
		_fires[key].queue_free()
	_fires.clear()
	_sting.stop()
	_sting_priority = 0


func _process(delta: float) -> void:
	if world == null:
		return
	_time += delta
	_play_events()
	_update_fires()
	_update_ambience(delta)


## Silences everything, so the audio server lets go of every stream before the game quits.
func stop_all() -> void:
	for player in get_children():
		player.stop()


## Plays a one-off sound at a world cell, such as a building being placed.
func play_at_cell(sound: String, cell: Vector2i, pitch := 1.0) -> void:
	play_at(sound, Vector2((cell.x + 0.5) * CELL, (cell.y + 0.5) * CELL), pitch)


func play_at(sound: String, at: Vector2, pitch := 1.0) -> void:
	if not _ready_to_play(sound):
		return
	var player := _pool[_next]
	_next = (_next + 1) % _pool.size()
	for k in _pool.size(): # prefer a player that is free
		if not _pool[(_next + k) % _pool.size()].playing:
			player = _pool[(_next + k) % _pool.size()]
			break
	player.position = at
	_configure(player, sound, pitch)
	player.play()


## Plays a sound that has no place in the world, like a tool being picked.
func play_ui(sound: String) -> void:
	if _ready_to_play(sound):
		_configure(_ui, sound, 1.0)
		_ui.play()


func on_drip_landed(at: Vector2, into_water: bool) -> void:
	play_at("drip" if into_water else "tap", at)


func _ready_to_play(sound: String) -> bool:
	var gap: float = ONE_SHOTS[sound][1]
	if _time - _last_played.get(sound, -100.0) < gap:
		return false
	_last_played[sound] = _time
	return true


func _configure(player: Node, sound: String, pitch: float) -> void:
	var settings: Array = ONE_SHOTS[sound]
	var variants: Array = SOUNDS[sound]
	player.stream = variants[randi() % variants.size()]
	player.volume_db = settings[0]
	player.pitch_scale = pitch * (1.0 + randf_range(-settings[2], settings[2]))


# --- Simulation events ---------------------------------------------------------

func _play_events() -> void:
	var sting := ""
	for event: Dictionary in world.events:
		var kind: String = event.kind
		var at := Vector2((event.x + 0.5) * CELL, (event.y + 0.5) * CELL)
		if STING_PRIORITY.has(kind):
			if sting == "" or STING_PRIORITY[kind] > STING_PRIORITY[sting]:
				sting = kind
			continue
		match kind:
			"chip":
				match event.tile:
					WorldSim.Tile.ICE: play_at("chip_ice", at)
					WorldSim.Tile.CRATE: play_at("knock", at, 0.8)
					_: play_at("chip_snow", at, 0.85 if event.tile == WorldSim.Tile.FELT else 1.0)
			"step":
				if world.water[world.idx(event.x, event.y)] > 0.3:
					play_at("tap", at, 0.55) # splashing through meltwater
				else:
					play_at("step", at)
			"crack":
				play_at("crack", at)
				_groan_in *= 0.7 # stressed ice sets the whole glacier talking
			"melt", "freeze", "fall", "hiss", "crate":
				play_at(kind, at)
	world.events.clear()
	if sting != "":
		_play_sting(sting)


func _play_sting(sting: String) -> void:
	if _sting.playing and STING_PRIORITY[sting] < _sting_priority:
		return
	_sting.stream = SOUNDS[sting][0]
	_sting.volume_db = STING_VOLUME[sting]
	_sting.play()
	_sting_priority = STING_PRIORITY[sting]


# --- Fires ---------------------------------------------------------------------

func _update_fires() -> void:
	var burning := {}
	for i in world.build.size():
		if world.fire_is_burning(i):
			burning[i * 8 + world.build[i]] = true
	for key: int in _fires.keys():
		if not burning.has(key):
			var i := key / 8
			_fade_out(_fires[key])
			_fires.erase(key)
			if world.fuel > 0.0:
				play_at_cell("fizzle", Vector2i(i % WorldSim.W, i / WorldSim.W)) # drowned or smothered
	for key: int in burning.keys():
		if _fires.has(key) or _fires.size() >= MAX_FIRE_LOOPS:
			continue
		var i := key / 8
		var player := AudioStreamPlayer2D.new()
		player.stream = SOUNDS["stove" if key % 8 == WorldSim.Build.STOVE else "fire"][0]
		player.bus = "Effects"
		player.max_distance = HEARING
		player.attenuation = 1.6
		player.panning_strength = 0.7
		player.volume_db = -9.0
		player.pitch_scale = randf_range(0.94, 1.06)
		player.position = Vector2((i % WorldSim.W + 0.5) * CELL, (i / WorldSim.W + 0.5) * CELL)
		add_child(player)
		player.play(randf() * player.stream.get_length()) # so two fires never crackle in step
		_fires[key] = player


func _fade_out(player: AudioStreamPlayer2D) -> void:
	var tween := create_tween()
	tween.tween_property(player, "volume_db", -50.0, 0.8)
	tween.tween_callback(player.queue_free)


# --- Ambience ------------------------------------------------------------------

func _update_ambience(delta: float) -> void:
	# The storm is loud near the surface; deeper down you hear the glacier itself.
	var ease_rate := clampf(delta * 2.0, 0.0, 1.0)
	_wind.volume_db = lerpf(_wind.volume_db, lerpf(-7.0, -24.0, depth), ease_rate)
	_deep.volume_db = lerpf(_deep.volume_db, lerpf(-26.0, -9.0, depth), ease_rate)

	_groan_in -= delta
	if _groan_in <= 0.0 and not world.is_over():
		_groan_in = randf_range(25.0, 55.0)
		var groan := _player("Ambience")
		groan.stream = SOUNDS["groan"][randi() % SOUNDS["groan"].size()]
		groan.volume_db = randf_range(-14.0, -8.0)
		groan.pitch_scale = randf_range(0.8, 1.1)
		groan.finished.connect(groan.queue_free)
		groan.play()

	var coldest := 100.0
	for c in world.colonists:
		if c.alive:
			coldest = minf(coldest, c.warmth)
	var target := -60.0
	if coldest < HEARTBEAT_WARMTH and not world.is_over():
		target = lerpf(-6.0, -22.0, coldest / HEARTBEAT_WARMTH)
		_heart.pitch_scale = lerpf(0.78, 1.0, coldest / HEARTBEAT_WARMTH) # the cold slows the heart
	_heart.volume_db = lerpf(_heart.volume_db, target, ease_rate)


# --- Setup ---------------------------------------------------------------------

func _make_bus(bus_name: String, volume_db: float) -> int:
	var index := AudioServer.get_bus_index(bus_name)
	if index == -1:
		index = AudioServer.bus_count
		AudioServer.add_bus(index)
		AudioServer.set_bus_name(index, bus_name)
		AudioServer.set_bus_send(index, "Master")
	AudioServer.set_bus_volume_db(index, volume_db)
	return index


func _player(bus_name: String) -> AudioStreamPlayer:
	var player := AudioStreamPlayer.new()
	player.bus = bus_name
	add_child(player)
	return player


func _loop_player(sound: String, bus_name: String) -> AudioStreamPlayer:
	var stream: AudioStreamOggVorbis = SOUNDS[sound][0]
	stream.loop = true
	var player := _player(bus_name)
	player.stream = stream
	player.volume_db = -30.0 # eases up to its level in the first second
	player.play(randf() * stream.get_length())
	return player
