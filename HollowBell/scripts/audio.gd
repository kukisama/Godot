extends Node
## Original offline-synthesized Hollow Bell audio. No global bus changes.
## Explore/boss loop; victory is a one-shot. Safe to configure before _ready().

const MUSIC_FILES: Dictionary = {
	"explore": "res://assets/audio/music/explore.ogg",
	"boss": "res://assets/audio/music/boss.ogg",
	"victory": "res://assets/audio/music/victory.ogg",
}
const SFX_FILES: Dictionary = {
	"step": "res://assets/audio/sfx/step.wav",
	"jump": "res://assets/audio/sfx/jump.wav",
	"land": "res://assets/audio/sfx/land.wav",
	"sword": "res://assets/audio/sfx/sword.wav",
	"heavy": "res://assets/audio/sfx/heavy.wav",
	"hit": "res://assets/audio/sfx/hit.wav",
	"parry": "res://assets/audio/sfx/parry.wav",
	"roll": "res://assets/audio/sfx/roll.wav",
	"heal": "res://assets/audio/sfx/heal.wav",
	"bow": "res://assets/audio/sfx/bow.wav",
	"magic": "res://assets/audio/sfx/magic.wav",
	"wing": "res://assets/audio/sfx/wing.wav",
	"slam": "res://assets/audio/sfx/slam.wav",
	"bell": "res://assets/audio/sfx/bell.wav",
	"checkpoint": "res://assets/audio/sfx/checkpoint.wav",
	"death": "res://assets/audio/sfx/death.wav",
	"ui": "res://assets/audio/sfx/ui.wav",
}
const SFX_GAINS: Dictionary = {
	"step": 0.34, "jump": 0.52, "land": 0.66, "sword": 0.70,
	"heavy": 0.90, "hit": 0.78, "parry": 0.85, "roll": 0.46,
	"heal": 0.68, "bow": 0.66, "magic": 0.76, "wing": 0.60,
	"slam": 0.95, "bell": 0.75, "checkpoint": 0.76, "death": 0.78,
	"ui": 0.45,
}
const SFX_POOL_SIZE: int = 16
const CROSSFADE_SECONDS: float = 1.15
const PAUSED_MUSIC_GAIN: float = 0.24
const MUSIC_GAIN: float = 0.55
# Allocate a bounded SFX budget across active voices, not a tiny fixed /16 gain.
# Music <= -1 dBTP and SFX PCM <= 0.76: even coherent sums stay below 0.91.
const SFX_GAIN: float = 0.55

var _master: float = 0.65
var _paused: bool = false
var _pause_gain: float = 1.0
var _requested_music: String = "none"
var _applied_music: String = ""
var _music_players: Array[AudioStreamPlayer] = []
var _sfx_players: Array[AudioStreamPlayer] = []
var _music_names: Array[String] = ["", ""]
var _music_cache: Dictionary = {}
var _sfx_cache: Dictionary = {}
var _warned_names: Dictionary = {}
var _weights: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
var _fade_from: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
var _fade_to: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
var _fade_elapsed: float = CROSSFADE_SECONDS
var _sfx_order: Array[int] = []
var _sfx_gains: Array[float] = []
var _serial: int = 0


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	for index in range(2):
		var player: AudioStreamPlayer = AudioStreamPlayer.new()
		player.name = "Music%d" % index
		player.process_mode = Node.PROCESS_MODE_ALWAYS
		player.volume_db = -INF
		add_child(player)
		_music_players.append(player)
	for index in range(SFX_POOL_SIZE):
		var player: AudioStreamPlayer = AudioStreamPlayer.new()
		player.name = "SFX%02d" % index
		player.process_mode = Node.PROCESS_MODE_ALWAYS
		player.max_polyphony = 1
		player.volume_db = -INF
		add_child(player)
		_sfx_players.append(player)
		_sfx_order.append(0)
		_sfx_gains.append(0.0)
	_select_music(_requested_music)
	_update_levels()


func set_music(track_name: String) -> void:
	if track_name != "none" and not MUSIC_FILES.has(track_name):
		_warn_once("music:" + track_name)
		return
	_requested_music = track_name
	if is_node_ready():
		_select_music(track_name)


func play_sfx(sound_name: String, pitch: float = 1.0) -> void:
	if not SFX_FILES.has(sound_name):
		_warn_once("sfx:" + sound_name)
		return
	if not is_node_ready() or (_paused and sound_name != "ui") or _master <= 0.0:
		return
	var stream: AudioStreamWAV = _sfx_cache.get(sound_name) as AudioStreamWAV
	if stream == null:
		var path: String = str(SFX_FILES[sound_name])
		stream = load(path) as AudioStreamWAV
		if stream == null:
			_warn_once("missing:" + path)
			return
		stream.loop_mode = AudioStreamWAV.LOOP_DISABLED
		_sfx_cache[sound_name] = stream
	var slot: int = 0
	for index in range(SFX_POOL_SIZE):
		if not _sfx_players[index].playing:
			slot = index
			break
		if _sfx_order[index] < _sfx_order[slot]:
			slot = index
	var player: AudioStreamPlayer = _sfx_players[slot]
	player.stop()
	player.stream = stream
	player.pitch_scale = clampf(pitch, 0.5, 2.0) if is_finite(pitch) else 1.0
	_sfx_gains[slot] = float(SFX_GAINS.get(sound_name, 0.7))
	_serial += 1
	_sfx_order[slot] = _serial
	player.volume_db = -INF
	player.play()
	_update_levels()


func set_volume(value: float) -> void:
	if not is_finite(value):
		return
	_master = clampf(value, 0.0, 1.0)
	_update_levels()


func set_paused(value: bool) -> void:
	_paused = value
	if value:
		# Never resume stale combat transients when returning from the menu.
		for player in _sfx_players:
			player.stop()


func _select_music(track_name: String) -> void:
	_discard_finished_music()
	if track_name == _applied_music:
		return
	var targets: PackedFloat32Array = PackedFloat32Array([0.0, 0.0])
	if track_name != "none":
		var stream: AudioStreamOggVorbis = _music_cache.get(track_name) as AudioStreamOggVorbis
		if stream == null:
			var path: String = str(MUSIC_FILES[track_name])
			stream = load(path) as AudioStreamOggVorbis
			if stream == null:
				_warn_once("missing:" + path)
				return
			stream.loop = track_name != "victory"
			stream.loop_offset = 0.0
			_music_cache[track_name] = stream
		var slot: int = -1
		for index in range(2):
			if _music_names[index] == track_name and _music_players[index].playing:
				slot = index
				break
		if slot < 0:
			# On rapid requests, retain the louder outgoing track; never add a third.
			slot = 0 if _weights[0] <= _weights[1] else 1
			var player: AudioStreamPlayer = _music_players[slot]
			player.stop()
			player.stream = stream
			player.volume_db = -INF
			_weights[slot] = 0.0
			_music_names[slot] = track_name
			player.play()
		targets[slot] = 1.0
	_applied_music = track_name
	_fade_from = _weights.duplicate()
	_fade_to = targets
	_fade_elapsed = 0.0


func _process(delta: float) -> void:
	_discard_finished_music()
	var pause_target: float = PAUSED_MUSIC_GAIN if _paused else 1.0
	_pause_gain = move_toward(_pause_gain, pause_target, delta * 5.0)
	if _fade_elapsed < CROSSFADE_SECONDS:
		_fade_elapsed = minf(_fade_elapsed + delta, CROSSFADE_SECONDS)
		var fraction: float = _fade_elapsed / CROSSFADE_SECONDS
		var blend: float = fraction * fraction * (3.0 - 2.0 * fraction)
		for index in range(2):
			# Equal-power interpolation also preserves partially completed fades.
			_weights[index] = sqrt(lerpf(
				_fade_from[index] * _fade_from[index],
				_fade_to[index] * _fade_to[index], blend
			))
			if _fade_elapsed >= CROSSFADE_SECONDS and _fade_to[index] == 0.0:
				_music_players[index].stop()
				_music_names[index] = ""
	_update_levels()


func _discard_finished_music() -> void:
	# A finished one-shot occupies no audible slot. Its previous fade weight
	# must not make a newly playing track look quieter and get stolen on a
	# rapid request (victory ends -> explore -> boss).
	for index in range(_music_players.size()):
		if not _music_players[index].playing:
			_weights[index] = 0.0
			_fade_from[index] = 0.0
			_fade_to[index] = 0.0
			_music_names[index] = ""


func _update_levels() -> void:
	# Reserve headroom during correlated crossfades, without touching Master bus.
	var weight_sum: float = maxf(1.0, _weights[0] + _weights[1])
	for index in range(_music_players.size()):
		_music_players[index].volume_db = linear_to_db(
			_master * MUSIC_GAIN * _pause_gain * _weights[index] / weight_sum
		)
	var sfx_weight_sum: float = 0.0
	for index in range(_sfx_players.size()):
		if _sfx_players[index].playing:
			sfx_weight_sum += _sfx_gains[index]
	sfx_weight_sum = maxf(1.0, sfx_weight_sum)
	for index in range(_sfx_players.size()):
		_sfx_players[index].volume_db = linear_to_db(
			_master * _sfx_gains[index] * SFX_GAIN / sfx_weight_sum
		)


func _warn_once(key: String) -> void:
	if not _warned_names.has(key):
		_warned_names[key] = true
		push_warning("Hollow Bell audio: unknown or unavailable " + key)


func shutdown() -> void:
	set_process(false)
	for player: AudioStreamPlayer in _music_players + _sfx_players:
		if is_instance_valid(player):
			player.stop()
			player.stream = null
	_music_cache.clear()
	_sfx_cache.clear()
	_music_names = ["", ""]
	_weights.fill(0.0)
	_fade_from.fill(0.0)
	_fade_to.fill(0.0)


func _exit_tree() -> void:
	shutdown()