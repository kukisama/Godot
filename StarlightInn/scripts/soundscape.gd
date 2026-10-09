extends Node
## Original, offline sound assets. Only our own bus is muted, never system audio.

signal mute_changed(muted: bool)
signal cue_played(cue: String)

const CUES: Array[String] = ["footstep_0", "footstep_1", "footstep_2", "dialogue_open", "dialogue_close", "select", "reply", "lute"]
const FIRE_POSITION := Vector2(201, 430)
const BARD_POSITION := Vector2(417, 785)

var muted: bool = false
var suspended: bool = false
var master_bus: StringName
var ambience_bus: StringName
var music_bus: StringName
var voices: Array[AudioStreamPlayer] = []
var fireplace: AudioStreamPlayer
var lute: AudioStreamPlayer
var streams: Dictionary = {}
var played_counts: Dictionary = {}
var last_cue: String = ""
var fire_pan := AudioEffectPanner.new()
var lute_pan := AudioEffectPanner.new()
var fire_target_db: float = -27.0
var lute_target_db: float = -24.0
var _voice_index: int = 0
var _step_index: int = 0
var _since_step: float = 0.0
var _since_lute: float = 0.0
var _bard_distance: float = 1000.0
var _conversation_open: bool = false


func _ready() -> void:
	master_bus = StringName("Starlight_%d" % get_instance_id())
	ambience_bus = StringName("%s_Fire" % master_bus)
	music_bus = StringName("%s_Lute" % master_bus)
	_create_bus(master_bus, &"Master", -2.0)
	_create_bus(ambience_bus, master_bus, 0.0)
	_create_bus(music_bus, master_bus, 0.0)
	AudioServer.add_bus_effect(AudioServer.get_bus_index(ambience_bus), fire_pan)
	AudioServer.add_bus_effect(AudioServer.get_bus_index(music_bus), lute_pan)
	for cue: String in CUES:
		streams[cue] = load("res://assets/audio/%s.wav" % cue)
	for _index in range(6):
		var voice := AudioStreamPlayer.new()
		voice.bus = master_bus
		voice.max_polyphony = 1
		add_child(voice)
		voices.append(voice)
	fireplace = AudioStreamPlayer.new()
	var fire: AudioStreamWAV = load("res://assets/audio/fireplace.wav").duplicate()
	fire.loop_mode = AudioStreamWAV.LOOP_FORWARD
	fire.loop_begin = 0
	fire.loop_end = int(round(fire.get_length() * fire.mix_rate))
	fireplace.stream = fire
	fireplace.bus = ambience_bus
	fireplace.volume_db = -40.0
	add_child(fireplace)
	fireplace.play()
	lute = AudioStreamPlayer.new()
	lute.stream = streams["lute"]
	lute.bus = music_bus
	lute.volume_db = -24.0
	add_child(lute)
	play_cue("dialogue_open", -17.0)


func _create_bus(bus: StringName, send: StringName, volume: float) -> void:
	AudioServer.add_bus()
	var index: int = AudioServer.bus_count - 1
	AudioServer.set_bus_name(index, bus)
	AudioServer.set_bus_send(index, send)
	AudioServer.set_bus_volume_db(index, volume)


func update_listener(point: Vector2, conversation_open: bool) -> void:
	_conversation_open = conversation_open
	var distance: float = point.distance_to(FIRE_POSITION)
	fire_target_db = lerpf(-12.0, -23.0, clampf(distance / 1050.0, 0.0, 1.0))
	if conversation_open:
		fire_target_db -= 3.0
	fire_pan.pan = clampf((FIRE_POSITION.x - point.x) / 1100.0, -0.55, 0.55)
	lute_pan.pan = clampf((BARD_POSITION.x - point.x) / 1100.0, -0.45, 0.45)
	_bard_distance = point.distance_to(BARD_POSITION)
	lute_target_db = lerpf(-15.0, -28.0, clampf(_bard_distance / 800.0, 0.0, 1.0))
	if conversation_open:
		lute_target_db -= 4.0


func play_cue(cue: String, volume_db: float = -12.0) -> bool:
	if muted or suspended or not streams.has(cue) or voices.is_empty():
		return false
	if cue == "lute":
		lute.volume_db = lute_target_db
		lute.play()
		_since_lute = 0.0
	else:
		var voice: AudioStreamPlayer = voices[_voice_index]
		_voice_index = (_voice_index + 1) % voices.size()
		voice.stop()
		voice.stream = streams[cue]
		voice.volume_db = volume_db
		voice.pitch_scale = 1.0
		voice.play()
	last_cue = cue
	played_counts[cue] = int(played_counts.get(cue, 0)) + 1
	cue_played.emit(cue)
	return true


func footstep() -> void:
	# Distance drives cadence; a wall/paused conversation cannot trigger a step.
	# Cap pathological frame spikes so a hitch cannot produce a burst of clicks.
	if _since_step < 0.105:
		return
	_since_step = 0.0
	play_cue("footstep_%d" % (_step_index % 3), -14.0)
	_step_index += 1


func toggle_mute() -> void:
	set_muted(not muted)


func set_muted(value: bool) -> void:
	muted = value
	if AudioServer.get_bus_index(master_bus) >= 0:
		AudioServer.set_bus_mute(AudioServer.get_bus_index(master_bus), muted)
	if muted:
		for voice: AudioStreamPlayer in voices:
			voice.stop()
		if lute != null:
			lute.stop()
	_apply_pause()
	mute_changed.emit(muted)


func set_suspended(value: bool) -> void:
	suspended = value
	_apply_pause()


func _apply_pause() -> void:
	if fireplace != null:
		fireplace.stream_paused = muted or suspended
	if lute != null:
		lute.stream_paused = muted or suspended
	for voice: AudioStreamPlayer in voices:
		voice.stream_paused = muted or suspended


func _process(delta: float) -> void:
	_since_step += delta
	if fireplace == null or suspended:
		return
	fireplace.volume_db = lerpf(fireplace.volume_db, fire_target_db, minf(1.0, delta * 2.0))
	lute.volume_db = lerpf(lute.volume_db, lute_target_db, minf(1.0, delta * 2.0))
	if not muted:
		_since_lute += delta
		if _since_lute >= 18.0 and _bard_distance < 650.0 and not _conversation_open:
			play_cue("lute")


func _exit_tree() -> void:
	for voice: AudioStreamPlayer in voices:
		voice.stop()
	if fireplace != null:
		fireplace.stop()
	if lute != null:
		lute.stop()
	for bus: StringName in [music_bus, ambience_bus, master_bus]:
		var index: int = AudioServer.get_bus_index(bus)
		if index > 0:
			AudioServer.remove_bus(index)