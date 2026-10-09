extends SceneTree
## Real Audio.gd + real imported streams + AudioServer mixer; NOT a listening test.
## --headless --audio-driver Dummy --script res://tests/test_audio_runtime.gd
## Never use --fixed-fps: the Dummy mixer advances on a separate wall clock.
## Only public audio calls, player seeks and test-only bus routing are fixtures.
## No source/import edits, synthesized substitute PCM, manual mix_audio or main scene.

const RuntimeAudio = preload("res://scripts/audio.gd")
const REPORT_PATH: String = "res://qa/audio-runtime.json"
const ENVIRONMENT_PATH: String = "res://qa/audio-runtime-environment.json"
const WAV_PATH: String = "res://qa/audio-runtime-testmix.wav"
const MUSIC_SECONDS: Dictionary = {"explore": 96.0, "boss": 80.0, "victory": 10.0}
const OWN_BUSES: Array[String] = ["AudioRuntimeMusic", "AudioRuntimeSFX"]
const SETTLE_SECONDS: float = 0.25
const SILENCE_LIMIT: float = 0.00001
const WATCHDOG_MS: int = 45000

class FrameFence extends Node:
	signal settled

	func _init() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		process_priority = 1000000

	func _process(_delta: float) -> void:
		settled.emit()

class CaptureTap extends RefCounted:
	var effect: AudioEffectCapture = AudioEffectCapture.new()
	var samples: PackedVector2Array = PackedVector2Array()
	var discarded: int = 0
	var pushed: int = 0

	func _init() -> void:
		effect.buffer_length = 2.0

	func drain() -> void:
		var available: int = effect.get_frames_available()
		if available > 0:
			samples.append_array(effect.get_buffer(available))
		discarded = effect.get_discarded_frames()
		pushed = effect.get_pushed_frames()

var audio
var fence: FrameFence
var taps: Dictionary = {}
var original_buses: Array[Dictionary] = []
var created_buses: Array[String] = []
var original_max_fps: int = 0
var source_hashes: Dictionary = {}
var analysis: Dictionary = {}
var imports: Dictionary = {}
var results: Array[Dictionary] = []
var failures: Array[Dictionary] = []
var phases: Dictionary = {}
var summaries: Dictionary = {}
var gain_measurements: Dictionary = {}
var production_findings: Array[Dictionary] = []
var cleanup: Dictionary = {}
var wav_result: Dictionary = {"written": false}
var environment: Dictionary = {}
var section: String = "boot"
var started_ms: int = 0
var playback_started_ms: int = 0
var playback_wall_ms: int = 0
var requested_wait_seconds: float = 0.0
var observed_frames: int = 0
var max_music: int = 0
var max_sfx: int = 0
var topology_faults: int = 0
var weight_faults: int = 0
var paused_non_ui_faults: int = 0
var global_bus_faults: int = 0
var finished_counts: Array[int] = [0, 0]
var music_ids: Array[int] = []
var sfx_ids: Array[int] = []
var sfx_playback_positions: Dictionary = {}
var running: bool = false
var aborting: bool = false
var cleaned_up: bool = false


func _initialize() -> void:
	started_ms = Time.get_ticks_msec()
	original_max_fps = Engine.max_fps
	_run.call_deferred()


func _process(_delta: float) -> bool:
	# Also catches an aborted coroutine after an unexpected GDScript runtime error.
	if running and not aborting and Time.get_ticks_msec() - started_ms > WATCHDOG_MS:
		aborting = true
		_abort.call_deferred("45-second wall-clock watchdog expired")
	return false


func _run() -> void:
	running = true
	Engine.max_fps = 60  # Real-time cap, not simulated --fixed-fps acceleration.
	_check(AudioServer.get_driver_name() == "Dummy", "explicit Dummy audio driver",
		AudioServer.get_driver_name(), "Dummy")
	_check(not OS.get_cmdline_args().has("--fixed-fps") and Engine.time_scale == 1.0
		and AudioServer.playback_speed_scale == 1.0, "unaccelerated scene and mixer clocks",
		{"args": OS.get_cmdline_args(), "time_scale": Engine.time_scale,
		"audio_speed": AudioServer.playback_speed_scale}, "no --fixed-fps; both scales 1")
	if FileAccess.file_exists(ENVIRONMENT_PATH):
		var context: Variant = JSON.parse_string(FileAccess.get_file_as_string(ENVIRONMENT_PATH))
		if context is Dictionary:
			environment = context
	_snapshot_sources()
	_save(false)
	if not _validate_imports():
		_abort("required imported resources unavailable or stale")
		return
	original_buses = _bus_snapshot()
	_check(AudioServer.get_bus_name(0) == "Master" and not AudioServer.is_bus_mute(0)
		and not AudioServer.is_bus_bypassing_effects(0)
		and is_zero_approx(AudioServer.get_bus_volume_db(0)), "unaltered Master is a unity, unmuted capture path",
		original_buses, "Master 0 dB; unmuted; effects enabled")
	for bus_name: String in OWN_BUSES:
		if AudioServer.get_bus_index(bus_name) >= 0:
			_abort("test bus already exists: " + bus_name)
			return
		AudioServer.add_bus()
		var index: int = AudioServer.bus_count - 1
		AudioServer.set_bus_name(index, bus_name)
		AudioServer.set_bus_send(index, &"Master")
		created_buses.append(bus_name)
	for key: String in ["mix", "music", "sfx"]:
		var tap: CaptureTap = CaptureTap.new()
		taps[key] = tap
		var bus_name: String = "Master" if key == "mix" else OWN_BUSES[0 if key == "music" else 1]
		AudioServer.add_bus_effect(AudioServer.get_bus_index(bus_name), tap.effect)
	fence = FrameFence.new()
	root.add_child(fence)
	fence.settled.connect(_observe_frame)
	audio = RuntimeAudio.new()
	_check(is_equal_approx(audio._master, 0.65), "production default volume", audio._master, 0.65)
	audio.set_volume(1.0)  # Exercise the worst permitted volume, not a reduced test gain.
	audio.set_music("explore")
	root.add_child(audio)
	for index in range(audio._music_players.size()):
		var player: AudioStreamPlayer = audio._music_players[index]
		player.bus = StringName(OWN_BUSES[0])
		player.finished.connect(_music_finished.bind(index))
		music_ids.append(player.get_instance_id())
	for player: AudioStreamPlayer in audio._sfx_players:
		player.bus = StringName(OWN_BUSES[1])
		sfx_ids.append(player.get_instance_id())
	_check(music_ids.size() == 2 and sfx_ids.size() == 16 and audio.get_child_count() == 18,
		"real production pool; configuration before ready applied",
		{"music": music_ids.size(), "sfx": sfx_ids.size(), "applied": audio._applied_music,
		"master": audio._master}, "2 music + 16 SFX; explore; volume 1")
	_check(audio._applied_music == "explore" and audio._master == 1.0,
		"pre-ready public requests survive ready", [audio._applied_music, audio._master], ["explore", 1])
	playback_started_ms = Time.get_ticks_msec()
	await _test_explore_and_all_sfx()
	await _test_loop("explore")
	await _test_pool_and_boss()
	await _test_loop("boss")
	await _test_pause_mute_resume()
	await _test_rapid_retargets()
	await _test_victory()
	await _test_finished_track_retarget()
	await _test_destroy_during_crossfade()
	_end_phase()
	playback_wall_ms = Time.get_ticks_msec() - playback_started_ms
	running = false
	_cleanup()
	_analyze_captures()
	_check(observed_frames > 0 and topology_faults == 0 and weight_faults == 0
		and paused_non_ui_faults == 0 and global_bus_faults == 0, "per-frame production invariants",
		{"frames": observed_frames, "topology_faults": topology_faults, "weight_faults": weight_faults,
		"paused_non_ui_faults": paused_non_ui_faults, "global_bus_faults": global_bus_faults}, "all fault counts zero")
	_check(max_music == 2 and max_sfx == 16, "observed bounded concurrency reaches both limits",
		{"music": max_music, "sfx": max_sfx}, {"music": 2, "sfx": 16})
	_check(audio == null or not is_instance_valid(audio), "audio owner freed", is_instance_valid(audio), false)
	_verify_sources()
	_save_wav()
	_save(true)
	print("AUDIO_RUNTIME_SUMMARY " + JSON.stringify({"checks": results.size(), "failed": failures.size(),
		"playback_wall_ms": playback_wall_ms, "mix": summaries.get("mix", {}),
		"mute": phases.get("muted", {}).get("metrics", {}).get("mix", {}),
		"duck": gain_measurements, "max_music": max_music, "max_sfx": max_sfx,
		"production_findings": production_findings.size(), "hardware_validated": false, "listened": false}))
	quit(0 if failures.is_empty() else 1)


func _validate_imports() -> bool:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://qa/audio-analysis.json"))
	if not parsed is Dictionary:
		_check(false, "offline analysis is readable context", typeof(parsed), TYPE_DICTIONARY)
		return false
	analysis = parsed
	_check(bool(analysis.get("passed", false)), "existing offline analysis passed (separate scope)",
		analysis.get("passed"), true)
	_check(RuntimeAudio.MUSIC_FILES.size() == 3 and RuntimeAudio.SFX_FILES.size() == 17,
		"production asset counts", [RuntimeAudio.MUSIC_FILES.size(), RuntimeAudio.SFX_FILES.size()], [3, 17])
	var valid: bool = true
	for track: String in MUSIC_SECONDS:
		var path: String = str(RuntimeAudio.MUSIC_FILES.get(track, ""))
		var stream: AudioStreamOggVorbis = load(path) as AudioStreamOggVorbis
		var row: Dictionary = {"path": path, "loaded": stream != null,
			"source_sha256": FileAccess.get_sha256(path)}
		if stream != null:
			row.merge({"imported_length_seconds": stream.get_length(), "imported_loop_before_use": stream.loop,
				"imported_loop_offset": stream.loop_offset, "class": stream.get_class()})
		var expected: Dictionary = analysis.get("assets", {}).get("music/" + track, {})
		var ok: bool = stream != null and absf(stream.get_length() - float(MUSIC_SECONDS[track])) < 0.002 \
			and row.source_sha256 == expected.get("sha256", "missing")
		imports["music/" + track] = row
		_check(ok, "real imported OGG length and source identity: " + track, row,
			{"seconds": MUSIC_SECONDS[track], "tolerance_seconds": 0.002, "hash": expected.get("sha256")})
		valid = valid and ok
	for sound: String in RuntimeAudio.SFX_FILES:
		var path: String = str(RuntimeAudio.SFX_FILES[sound])
		var stream: AudioStreamWAV = load(path) as AudioStreamWAV
		var expected: Dictionary = analysis.get("assets", {}).get("sfx/" + sound, {})
		var row: Dictionary = {"path": path, "loaded": stream != null,
			"source_sha256": FileAccess.get_sha256(path)}
		if stream != null:
			row.merge({"imported_length_seconds": stream.get_length(), "stereo": stream.stereo,
				"sample_rate": stream.mix_rate, "imported_loop_mode": stream.loop_mode})
		var ok: bool = stream != null and stream.stereo and stream.mix_rate == 44100 \
			and absf(stream.get_length() - float(expected.get("duration_seconds", -1))) < 0.002 \
			and row.source_sha256 == expected.get("sha256", "missing")
		imports["sfx/" + sound] = row
		_check(ok, "real imported WAV identity/stereo/rate/length: " + sound, row, expected.get("duration_seconds"))
		valid = valid and ok
	return valid


func _test_explore_and_all_sfx() -> void:
	_begin_phase("explore_sfx")
	_assert_runtime_track("explore")
	await _wait(0.25)
	for sound: String in RuntimeAudio.SFX_FILES:
		audio.play_sfx(sound)
		var slot: int = audio._sfx_order.find(audio._serial)
		await _wait(0.045)
		var player: AudioStreamPlayer = audio._sfx_players[slot]
		var stream: AudioStreamWAV = player.stream as AudioStreamWAV
		var position: float = player.get_playback_position()
		sfx_playback_positions[sound] = position
		_check(stream != null and stream == audio._sfx_cache.get(sound)
			and stream.loop_mode == AudioStreamWAV.LOOP_DISABLED and position > 0.0,
			"engine playback advances; runtime loop disabled: " + sound,
			{"position_seconds": position, "playing": player.playing, "slot": slot,
			"runtime_loop_mode": stream.loop_mode if stream != null else -1}, "real cached WAV; position > 0; no loop")
	await _wait(0.25)
	_assert_settled("explore")
	_check(audio._sfx_cache.size() == 17, "all 17 production SFX exercised", audio._sfx_cache.size(), 17)


func _test_loop(track: String) -> void:
	_begin_phase(track + "_loop")
	var player: AudioStreamPlayer = _music_player(track)
	if player == null:
		_check(false, "loop fixture has active " + track, _playing_music(), track)
		return
	_assert_runtime_track(track)
	var slot: int = audio._music_players.find(player)
	var finished_before: int = finished_counts[slot]
	var seek_position: float = player.stream.get_length() - 0.15
	player.seek(seek_position)
	await _wait(0.40)
	var position: float = player.get_playback_position()
	var loops: int = player.get_stream_playback().get_loop_count() if player.has_stream_playback() else -1
	_check(player.playing and position > 0.0 and position < 1.0 and loops >= 1
		and finished_counts[slot] == finished_before, "real decoder crosses loop boundary: " + track,
		{"seek_seconds": seek_position, "position_after": position, "loop_count": loops,
		"finished_delta": finished_counts[slot] - finished_before, "playing": player.playing},
		"still playing near start; >=1 loop; no finished signal")


func _test_pool_and_boss() -> void:
	_begin_phase("pool_stress")
	for request in range(64):
		audio.play_sfx("bell", 0.5)
		_observe_players()
	var orders: Array = audio._sfx_order.duplicate()
	orders.sort()
	_check(_sfx_count() == 16 and orders == range(audio._serial - 15, audio._serial + 1),
		"64 overlapping requests steal oldest voices, never grow the pool",
		{"active": _sfx_count(), "serial": audio._serial, "remaining_orders": orders}, "latest 16 serials")
	await _wait(0.20)
	_begin_phase("boss_crossfade")
	audio.set_music("boss")
	_assert_runtime_track("boss")
	_check(_playing_music().size() == 2, "explore and boss genuinely overlap", _playing_music(), "two tracks")
	await _wait(1.25)
	_assert_settled("boss")
	var player: AudioStreamPlayer = _music_player("boss")
	var before: float = player.get_playback_position()
	var playback_id: int = player.get_stream_playback().get_instance_id()
	audio.set_music("boss")
	await _wait(0.10)
	_check(player.get_playback_position() > before and player.get_stream_playback().get_instance_id() == playback_id,
		"repeated current-track request does not restart decoder", [before, player.get_playback_position()], "position increases; same playback")


func _test_pause_mute_resume() -> void:
	var player: AudioStreamPlayer = _music_player("boss")
	_begin_phase("reference_seek_settle")
	player.seek(2.0)
	await _wait(SETTLE_SECONDS)
	_begin_phase("duck_reference")
	await _wait(0.32)
	var level_before: float = db_to_linear(player.volume_db)
	_begin_phase("pause_settle")
	audio.set_paused(true)
	paused = true
	_check(_sfx_count() == 0, "pause immediately stops existing combat transients", _sfx_count(), 0)
	await _wait(SETTLE_SECONDS)
	_check(player.playing and not player.stream_paused and is_equal_approx(audio._pause_gain, 0.24)
		and absf(db_to_linear(player.volume_db) / level_before - 0.24) < 0.00001,
		"actual tree pause keeps music running at authored duck gain",
		{"tree_paused": paused, "stream_paused": player.stream_paused, "pause_gain": audio._pause_gain,
		"linear_gain_ratio": db_to_linear(player.volume_db) / level_before}, 0.24)
	_begin_phase("paused_blocked")
	var serial_before: int = audio._serial
	for sound: String in RuntimeAudio.SFX_FILES:
		if sound != "ui":
			audio.play_sfx(sound)
	await _wait(0.18)
	_check(audio._serial == serial_before and _sfx_count() == 0, "all 16 non-UI names rejected while paused",
		{"serial_delta": audio._serial - serial_before, "active": _sfx_count()}, "0 / 0")
	_begin_phase("paused_seek_settle")
	player.seek(2.0)
	await _wait(SETTLE_SECONDS)
	_begin_phase("duck_paused")
	await _wait(0.32)
	_begin_phase("paused_ui")
	audio.play_sfx("ui")
	_check(audio._serial == serial_before + 1 and _sfx_count() == 1,
		"UI sound alone is accepted during tree pause", [audio._serial - serial_before, _sfx_count()], [1, 1])
	await _wait(0.22)
	_begin_phase("mute_settle")
	audio.play_sfx("ui")
	await _wait(0.04)
	audio.set_volume(0.0)
	var muted_voices: int = 0
	for voice: AudioStreamPlayer in audio._music_players + audio._sfx_players:
		if voice.volume_db == -INF:
			muted_voices += 1
	_check(muted_voices == 18, "public mute silences every player", muted_voices, 18)
	audio.set_paused(false)
	paused = false
	await _wait(SETTLE_SECONDS)
	_begin_phase("muted")
	serial_before = audio._serial
	var position_before: float = player.get_playback_position()
	for sound: String in RuntimeAudio.SFX_FILES:
		audio.play_sfx(sound)
	await _wait(0.30)
	_check(audio._serial == serial_before and player.get_playback_position() > position_before,
		"mute rejects every SFX including UI but does not stop music clock",
		{"serial_delta": audio._serial - serial_before, "position_before": position_before,
		"position_after": player.get_playback_position()}, "no new voices; advancing music")
	_begin_phase("resume_settle")
	audio.set_volume(1.0)
	await _wait(SETTLE_SECONDS)
	_check(is_equal_approx(audio._pause_gain, 1.0) and _sfx_count() == 0,
		"resume restores gain without resurrecting stale SFX", [audio._pause_gain, _sfx_count()], [1, 0])
	player.seek(2.0)
	await _wait(SETTLE_SECONDS)
	_begin_phase("duck_resumed")
	await _wait(0.32)
	_check(absf(db_to_linear(player.volume_db) / level_before - 1.0) < 0.00001,
		"resumed music player gain restored", db_to_linear(player.volume_db) / level_before, 1.0)


func _test_rapid_retargets() -> void:
	_begin_phase("rapid_retargets")
	var sequence: Array[String] = ["explore", "boss", "victory", "none", "explore", "victory", "boss", "explore"]
	for index in range(16):
		audio.set_music(sequence[index % sequence.size()])
		_observe_players()
		await _wait(0.035)
	_begin_phase("retarget_settle")
	audio.set_music("boss")
	await _wait(1.25)
	_assert_settled("boss")
	_check(_current_ids(audio._music_players) == music_ids, "rapid changes reuse the same two player objects",
		_current_ids(audio._music_players), music_ids)
	_begin_phase("cancel_crossfade")
	audio.set_music("explore")
	await _wait(0.10)
	audio.set_music("none")
	await _wait(1.25)
	_check(_playing_music().is_empty() and audio._music_names == ["", ""]
		and is_zero_approx(audio._weights[0]) and is_zero_approx(audio._weights[1]),
		"none kills an in-flight crossfade; no stale track survives",
		{"playing": _playing_music(), "names": audio._music_names, "weights": audio._weights}, "no tracks; zero weights")
	await _wait(SETTLE_SECONDS)
	_begin_phase("cancelled_silence")
	await _wait(0.25)


func _test_victory() -> void:
	_begin_phase("victory_intro")
	audio.set_music("victory")
	_assert_runtime_track("victory")
	await _wait(1.25)
	_assert_settled("victory")
	var player: AudioStreamPlayer = _music_player("victory")
	var slot: int = audio._music_players.find(player)
	var finished_before: int = finished_counts[slot]
	_begin_phase("victory_end")
	player.seek(player.stream.get_length() - 0.30)
	await _wait(0.65)
	_check(not player.playing and finished_counts[slot] == finished_before + 1,
		"victory reaches its real 10-second endpoint exactly once",
		{"playing": player.playing, "finished_delta": finished_counts[slot] - finished_before,
		"imported_seconds": player.stream.get_length()}, "stopped; exactly one finished signal; 10 seconds")
	_begin_phase("victory_stays_finished")
	audio.set_music("victory")
	await _wait(0.25)
	_check(not player.playing and finished_counts[slot] == finished_before + 1 and _playing_music().is_empty(),
		"finished one-shot does not auto-loop or restart on repeated request",
		{"playing": _playing_music(), "finished_delta": finished_counts[slot] - finished_before}, "none / 1")


func _test_finished_track_retarget() -> void:
	# Preserve this as a RED regression if a finished one-shot's stale weight
	# causes slot selection to evict the only LIVE outgoing track. Do not fix
	# production here or reclassify that failure as a successful crossfade.
	_begin_phase("finished_track_retarget")
	var finished_state: Array[Dictionary] = _music_snapshot()
	audio.set_music("explore")
	await _wait(0.20)
	var before: Array[Dictionary] = _music_snapshot()
	var outgoing: AudioStreamPlayer = _music_player("explore")
	_check(outgoing != null, "post-victory retarget fixture has live explore", before, "explore playing")
	audio.set_music("boss")
	var after: Array[Dictionary] = _music_snapshot()
	var kept_live_track: bool = outgoing != null and outgoing.playing and _playing_music().size() == 2
	var evidence: Dictionary = {"after_victory_finished": finished_state,
		"before_boss_request": before, "immediately_after_boss_request": after}
	_check(kept_live_track, "retarget after finished victory retains the live outgoing track",
		evidence, "reuse inactive victory slot, retain explore while boss fades in")
	if not kept_live_track:
		production_findings.append({"id": "finished-victory-stale-weight", "source": "scripts/audio.gd::_select_music",
			"reproduction": ["Let victory finish (test seeks to 9.7s)", "set_music(explore)",
				"After 0.2s, before the 1.15s fade completes, set_music(boss)"],
			"observed": evidence, "impact": "The sole live outgoing explore player is stopped; new boss starts at zero gain instead of crossfading over it.",
			"cause": "Slot choice compares weights without discounting the non-playing finished victory slot.",
			"production_modified": false, "assertion_id": results.size()})
	await _wait(1.25)
	_assert_settled("boss")


func _test_destroy_during_crossfade() -> void:
	_begin_phase("destroy_active")
	# Start from the settled live boss, independently of the regression above.
	audio.set_music("explore")
	audio.play_sfx("bell")
	await _wait(0.20)
	_check(_playing_music().size() == 2 and _sfx_count() == 1 and audio._fade_elapsed < 1.15,
		"destruction fixture has live music crossfade and SFX", _playing_music(), "2 music + 1 SFX; unfinished fade")
	var references: Array[WeakRef] = [weakref(audio)]
	for voice: AudioStreamPlayer in audio._music_players + audio._sfx_players:
		references.append(weakref(voice))
	audio.queue_free()
	await _wait(SETTLE_SECONDS)
	var survivors: int = 0
	for reference: WeakRef in references:
		if reference.get_ref() != null:
			survivors += 1
	_check(survivors == 0, "freeing owner destroys all 18 players safely", survivors, 0)
	audio = null
	_begin_phase("destroyed_silence")
	await _wait(0.25)


func _wait(seconds: float) -> void:
	requested_wait_seconds += seconds
	var mix: CaptureTap = taps["mix"]
	var first_sample: int = mix.effect.get_pushed_frames()
	var required_samples: int = ceili(seconds * AudioServer.get_mix_rate())
	await create_timer(seconds, true, false, true).timeout
	# Dummy mixes on its own thread, in observed 4096-frame batches. A scene
	# timer alone can expire before that thread has mixed even one batch under
	# load. Require real PCM progress as well; retain all duration, amplitude,
	# gain and correlation assertions unchanged. The suite watchdog is bounded.
	while mix.effect.get_pushed_frames() - first_sample < required_samples:
		await process_frame
	# Both SceneTree signals precede node callbacks; fence follows Audio._process.
	await physics_frame
	await process_frame
	await fence.settled


func _observe_frame() -> void:
	observed_frames += 1
	_drain()
	_observe_players()


func _drain() -> void:
	for tap: CaptureTap in taps.values():
		tap.drain()


func _observe_players() -> void:
	if not is_instance_valid(audio):
		return
	var music_count: int = _playing_music().size()
	var sfx_count: int = _sfx_count()
	max_music = maxi(max_music, music_count)
	max_sfx = maxi(max_sfx, sfx_count)
	if audio._music_players.size() != 2 or audio._sfx_players.size() != 16 \
		or audio.get_child_count() != 18 or music_count > 2 or sfx_count > 16 \
		or _current_ids(audio._music_players) != music_ids or _current_ids(audio._sfx_players) != sfx_ids:
		topology_faults += 1
	for voice: AudioStreamPlayer in audio._music_players + audio._sfx_players:
		if voice.max_polyphony != 1:
			topology_faults += 1
	for weight: float in audio._weights:
		if not is_finite(weight) or weight < 0.0 or weight > 1.000001:
			weight_faults += 1
	if audio._paused:
		for voice: AudioStreamPlayer in audio._sfx_players:
			if voice.playing and voice.stream != audio._sfx_cache.get("ui"):
				paused_non_ui_faults += 1
	if AudioServer.get_bus_volume_db(0) != float(original_buses[0].volume_db) \
		or AudioServer.is_bus_mute(0) != bool(original_buses[0].mute):
		global_bus_faults += 1


func _music_finished(slot: int) -> void:
	finished_counts[slot] += 1


func _current_ids(players: Array) -> Array[int]:
	var ids: Array[int] = []
	for player: AudioStreamPlayer in players:
		ids.append(player.get_instance_id())
	return ids


func _music_snapshot() -> Array[Dictionary]:
	var state: Array[Dictionary] = []
	if not is_instance_valid(audio):
		return state
	for index in range(audio._music_players.size()):
		var player: AudioStreamPlayer = audio._music_players[index]
		state.append({"slot": index, "name": audio._music_names[index], "playing": player.playing,
			"weight": audio._weights[index], "linear_gain": db_to_linear(player.volume_db),
			"position_seconds": player.get_playback_position()})
	return state


func _playing_music() -> Array[String]:
	var names: Array[String] = []
	for index in range(audio._music_players.size()):
		if audio._music_players[index].playing:
			names.append(audio._music_names[index])
	return names


func _sfx_count() -> int:
	var count: int = 0
	for player: AudioStreamPlayer in audio._sfx_players:
		if player.playing:
			count += 1
	return count


func _music_player(track: String) -> AudioStreamPlayer:
	for index in range(audio._music_players.size()):
		if audio._music_names[index] == track and audio._music_players[index].playing:
			return audio._music_players[index]
	return null


func _assert_runtime_track(track: String) -> void:
	var stream: AudioStreamOggVorbis = audio._music_cache.get(track) as AudioStreamOggVorbis
	var player: AudioStreamPlayer = _music_player(track)
	var row: Dictionary = {"cached": stream != null, "active_player": player != null}
	if stream != null:
		row.merge({"loop": stream.loop, "loop_offset": stream.loop_offset, "length_seconds": stream.get_length()})
		imports["music/" + track]["runtime"] = row.duplicate()
	_check(stream != null and player != null and player.stream == stream
		and stream.loop == (track != "victory") and is_zero_approx(stream.loop_offset)
		and absf(stream.get_length() - float(MUSIC_SECONDS[track])) < 0.002,
		"actual runtime stream loop/length: " + track, row, {"loop": track != "victory", "seconds": MUSIC_SECONDS[track]})


func _assert_settled(track: String) -> void:
	var player: AudioStreamPlayer = _music_player(track)
	var target_weight: float = -1.0
	if player != null:
		target_weight = audio._weights[audio._music_players.find(player)]
	_check(_playing_music() == [track] and is_equal_approx(target_weight, 1.0)
		and audio._fade_elapsed >= 1.15, "crossfade settles to only " + track,
		{"playing": _playing_music(), "weights": audio._weights, "elapsed": audio._fade_elapsed}, "one track; weight 1; completed fade")


func _begin_phase(label: String) -> void:
	_end_phase()
	section = label
	var starts: Dictionary = {}
	for key: String in taps:
		starts[key] = (taps[key] as CaptureTap).samples.size()
	phases[label] = {"start_ms": Time.get_ticks_msec() - playback_started_ms,
		"start_frames": starts, "music_state_start": _music_snapshot()}
	print("PHASE " + label)


func _end_phase() -> void:
	_drain()
	if not phases.has(section):
		return
	var ends: Dictionary = {}
	for key: String in taps:
		ends[key] = (taps[key] as CaptureTap).samples.size()
	phases[section]["end_frames"] = ends
	phases[section]["end_ms"] = Time.get_ticks_msec() - playback_started_ms


func _stats(samples: PackedVector2Array, begin: int = 0, end: int = -1) -> Dictionary:
	if end < 0:
		end = samples.size()
	var energy_left: float = 0.0
	var energy_right: float = 0.0
	var energy_side: float = 0.0
	var peak: float = 0.0
	var nonfinite: int = 0
	var nonzero: int = 0
	var clipped: int = 0
	for index in range(begin, end):
		var sample: Vector2 = samples[index]
		if not is_finite(sample.x) or not is_finite(sample.y):
			nonfinite += int(not is_finite(sample.x)) + int(not is_finite(sample.y))
			continue
		var amplitude: float = maxf(absf(sample.x), absf(sample.y))
		peak = maxf(peak, amplitude)
		nonzero += int(amplitude > 0.000001)
		clipped += int(absf(sample.x) >= 1.0) + int(absf(sample.y) >= 1.0)
		energy_left += float(sample.x) * sample.x
		energy_right += float(sample.y) * sample.y
		energy_side += pow((float(sample.x) - sample.y) * 0.5, 2.0)
	var count: int = end - begin
	var denominator: float = maxf(1.0, count)
	return {"frames": count, "seconds": count / AudioServer.get_mix_rate(), "peak": peak,
		"rms": sqrt((energy_left + energy_right) / (denominator * 2.0)),
		"left_rms": sqrt(energy_left / denominator), "right_rms": sqrt(energy_right / denominator),
		"side_rms": sqrt(energy_side / denominator), "nonzero_frames": nonzero,
		"nonfinite_samples": nonfinite, "clipped_samples": clipped}


func _phase_samples(label: String, key: String) -> PackedVector2Array:
	var tap: CaptureTap = taps[key]
	return tap.samples.slice(int(phases[label].start_frames[key]), int(phases[label].end_frames[key]))


func _aligned_gain(reference: PackedVector2Array, target: PackedVector2Array) -> Dictionary:
	# Replay the SAME excerpt through the real player at different gains. Align
	# captured waveforms, rather than comparing RMS from unrelated musical bars.
	# Dummy was observed delivering 4096-frame (~93ms) batches: an 80ms search
	# can miss the exact alignment. Keep the gain/correlation thresholds strict;
	# search every feasible offset within 200ms instead, after capture stops.
	var radius: int = int(AudioServer.get_mix_rate() * 0.20)
	var count: int = 4096
	if mini(reference.size(), target.size()) < count * 2:
		return {"valid": false, "reference_frames": reference.size(), "target_frames": target.size()}
	var anchor: int = int((reference.size() - count) / 2.0)
	var first_lag: int = maxi(-radius, -anchor)
	var last_lag: int = mini(radius, target.size() - anchor - count)
	var best_correlation: float = -1.0
	var best_lag: int = 0
	for lag in range(first_lag, last_lag + 1):
		var xx: float = 0.0
		var yy: float = 0.0
		var xy: float = 0.0
		for index in range(0, 2048, 32):
			var a: Vector2 = reference[anchor + index]
			var b: Vector2 = target[anchor + lag + index]
			xx += a.dot(a)
			yy += b.dot(b)
			xy += a.dot(b)
		var correlation: float = xy / sqrt(maxf(xx * yy, 1.0e-30))
		if correlation > best_correlation:
			best_correlation = correlation
			best_lag = lag
	var xx: float = 0.0
	var yy: float = 0.0
	var xy: float = 0.0
	for index in range(count):
		var a: Vector2 = reference[anchor + index]
		var b: Vector2 = target[anchor + best_lag + index]
		xx += a.dot(a)
		yy += b.dot(b)
		xy += a.dot(b)
	var gain: float = xy / maxf(xx, 1.0e-30)
	return {"valid": xx > 1.0e-10 and yy > 1.0e-10, "gain": gain,
		"correlation": xy / sqrt(maxf(xx * yy, 1.0e-30)), "lag_frames": best_lag,
		"search_lag_bounds": [first_lag, last_lag], "reference_anchor": anchor,
		"aligned_frames": count, "residual_rms": sqrt(maxf(0.0, yy - 2 * gain * xy + gain * gain * xx) / (count * 2.0))}


func _analyze_captures() -> void:
	section = "captured_metrics"
	for key: String in taps:
		var tap: CaptureTap = taps[key]
		var metrics: Dictionary = _stats(tap.samples)
		metrics.merge({"discarded_frames": tap.discarded, "pushed_frames": tap.pushed})
		summaries[key] = metrics
		_check(int(metrics.frames) > 0 and int(metrics.nonfinite_samples) == 0
			and float(metrics.peak) > 0.00001 and float(metrics.peak) < 1.0
			and float(metrics.left_rms) > 0.000001 and float(metrics.right_rms) > 0.000001
			and float(metrics.side_rms) > 0.000001 and tap.discarded == 0,
			"real finite nonzero stereo capture with headroom: " + key, metrics,
			"peak in (1e-5, 1); both channels and side nonzero; no dropped/nonfinite/clipped samples")
	for label: String in phases:
		var metrics: Dictionary = {}
		for key: String in taps:
			metrics[key] = _stats(_phase_samples(label, key))
		phases[label]["metrics"] = metrics
		print("CAPTURE " + label + " " + JSON.stringify(metrics.mix))
	for label: String in ["explore_sfx", "explore_loop", "boss_crossfade", "boss_loop", "duck_reference",
			"duck_paused", "duck_resumed", "rapid_retargets", "retarget_settle", "victory_intro", "destroy_active"]:
		_assert_signal(label, "music", false)
	_assert_signal("explore_sfx", "sfx", false)
	_assert_signal("pool_stress", "sfx", false)
	_assert_signal("paused_ui", "sfx", false)
	_assert_signal("paused_blocked", "sfx", true)
	for label: String in ["muted", "cancelled_silence", "victory_stays_finished", "destroyed_silence"]:
		_assert_signal(label, "mix", true)
	_assert_signal("muted", "music", true)
	_assert_signal("muted", "sfx", true)
	for label: String in ["duck_paused", "duck_resumed"]:
		var measurement: Dictionary = _aligned_gain(_phase_samples("duck_reference", "music"), _phase_samples(label, "music"))
		gain_measurements[label] = measurement
		var expected: float = 0.24 if label == "duck_paused" else 1.0
		_check(bool(measurement.get("valid", false)) and float(measurement.get("correlation", 0)) > 0.995
			and absf(float(measurement.get("gain", -1)) - expected) < 0.005,
			"sample-aligned actual mixer gain: " + label, measurement,
			{"gain": expected, "absolute_tolerance": 0.005, "min_correlation": 0.995})
	var mix_seconds: float = float(summaries.mix.seconds)
	_check(mix_seconds >= 4.0 and mix_seconds > playback_wall_ms * 0.0005
		and mix_seconds < playback_wall_ms * 0.0015 + 0.25,
		"Dummy really advances audio, not only SceneTree state",
		{"captured_seconds": mix_seconds, "playback_wall_seconds": playback_wall_ms / 1000.0},
		">=4s PCM; capture duration within 0.5..1.5x real wall time")


func _assert_signal(label: String, key: String, silent: bool) -> void:
	var metrics: Dictionary = phases[label].metrics[key]
	var enough: bool = int(metrics.frames) >= int(AudioServer.get_mix_rate() * 0.12)
	var valid: bool = int(metrics.nonfinite_samples) == 0 and float(metrics.peak) < 1.0
	var amplitude_ok: bool = float(metrics.peak) < SILENCE_LIMIT if silent else float(metrics.rms) > SILENCE_LIMIT
	_check(enough and valid and amplitude_ok, "captured " + ("silence" if silent else "signal") + ": " + label + "/" + key,
		metrics, ">=120ms real frames; finite; " + ("peak < 1e-5" if silent else "rms > 1e-5; peak < 1"))


func _bus_snapshot() -> Array[Dictionary]:
	var state: Array[Dictionary] = []
	for index in range(AudioServer.bus_count):
		var effects: Array[Dictionary] = []
		for effect_index in range(AudioServer.get_bus_effect_count(index)):
			effects.append({"id": AudioServer.get_bus_effect(index, effect_index).get_instance_id(),
				"enabled": AudioServer.is_bus_effect_enabled(index, effect_index)})
		state.append({"name": AudioServer.get_bus_name(index), "volume_db": AudioServer.get_bus_volume_db(index),
			"mute": AudioServer.is_bus_mute(index), "solo": AudioServer.is_bus_solo(index),
			"bypass": AudioServer.is_bus_bypassing_effects(index), "send": str(AudioServer.get_bus_send(index)), "effects": effects})
	return state


func _cleanup() -> void:
	if cleaned_up:
		return
	cleaned_up = true
	paused = false
	if is_instance_valid(fence):
		fence.set_process(false)
		fence.queue_free()
	if is_instance_valid(audio):
		for player: AudioStreamPlayer in audio._music_players + audio._sfx_players:
			player.stop()
		audio.queue_free()
	var removed_effects: int = 0
	for bus_index in range(AudioServer.bus_count - 1, -1, -1):
		for effect_index in range(AudioServer.get_bus_effect_count(bus_index) - 1, -1, -1):
			for tap: CaptureTap in taps.values():
				if AudioServer.get_bus_effect(bus_index, effect_index) == tap.effect:
					AudioServer.remove_bus_effect(bus_index, effect_index)
					removed_effects += 1
					break
	for bus_name: String in created_buses:
		var index: int = AudioServer.get_bus_index(bus_name)
		if index > 0:
			AudioServer.remove_bus(index)
	var remaining_capture_frames: int = 0
	for tap: CaptureTap in taps.values():
		tap.effect.clear_buffer()
		remaining_capture_frames += tap.effect.get_frames_available()
	Engine.max_fps = original_max_fps
	cleanup = {"removed_capture_effects": removed_effects, "remaining_ring_frames": remaining_capture_frames,
		"bus_layout_before": original_buses, "bus_layout_after": _bus_snapshot(), "max_fps_restored": Engine.max_fps == original_max_fps}
	if not original_buses.is_empty():
		_check(cleanup.bus_layout_before == cleanup.bus_layout_after and remaining_capture_frames == 0
			and removed_effects == taps.size(), "all temporary buses/effects removed and capture rings emptied", cleanup, "exact original layout; empty rings")


func _snapshot_sources() -> void:
	var paths: Array[String] = ["res://scripts/audio.gd", "res://scripts/game.gd", "res://tools/compose_audio.py",
		"res://qa/audio-analysis.json", "res://project.godot", "res://main.tscn"]
	for asset: Variant in RuntimeAudio.MUSIC_FILES.values() + RuntimeAudio.SFX_FILES.values():
		paths.append(str(asset))
		if FileAccess.file_exists(str(asset) + ".import"):
			paths.append(str(asset) + ".import")
	for path: String in paths:
		source_hashes[path] = FileAccess.get_sha256(path)


func _verify_sources() -> void:
	var changed: Array[String] = []
	for path: String in source_hashes:
		if FileAccess.get_sha256(path) != str(source_hashes[path]):
			changed.append(path)
	_check(changed.is_empty(), "production, generator, imports and original analysis unchanged", changed, [])


func _save_wav() -> void:
	var tap: CaptureTap = taps["mix"]
	var frames: int = int(AudioServer.get_mix_rate()) * 4
	if tap.samples.size() < frames or int(summaries.mix.nonfinite_samples) != 0 or float(summaries.mix.peak) >= 1.0:
		_check(false, "safe unnormalized four-second test WAV available", summaries.mix, ">=4s finite, unclipped capture")
		return
	var pcm: PackedByteArray = PackedByteArray()
	pcm.resize(frames * 4)
	for index in range(frames):
		pcm.encode_s16(index * 4, roundi(tap.samples[index].x * 32767.0))
		pcm.encode_s16(index * 4 + 2, roundi(tap.samples[index].y * 32767.0))
	var wav: AudioStreamWAV = AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = int(AudioServer.get_mix_rate())
	wav.stereo = true
	wav.data = pcm
	var error: Error = wav.save_to_wav(ProjectSettings.globalize_path(WAV_PATH))
	wav_result = {"written": error == OK, "path": WAV_PATH, "error": error, "seconds": 4.0,
		"frames": frames, "sample_rate": wav.mix_rate, "channels": 2, "bits_per_sample": 16,
		"normalized": false, "source": "first four seconds of actual Master AudioEffectCapture",
		"not_game_asset": true, "not_a_listening_review": true,
		"sha256": FileAccess.get_sha256(WAV_PATH) if error == OK else ""}
	_check(error == OK, "four-second raw test mix WAV saved without gain normalization", wav_result, OK)


func _check(ok: bool, label: String, actual: Variant, expected: Variant) -> void:
	var row: Dictionary = {"id": results.size() + 1, "section": section,
		"label": label, "passed": ok, "actual": actual, "expected": expected}
	results.append(row)
	if not ok:
		failures.append(row)
		printerr("FAIL " + JSON.stringify(row))
	else:
		print("PASS %d %s" % [row.id, label])


func _save(completed: bool) -> void:
	var report: Dictionary = {"schema": "hollow-bell-audio-runtime/v1", "completed": completed,
		"passed": completed and failures.is_empty(), "checks": results.size(), "failed": failures.size(),
		"results": results, "failures": failures, "engine": Engine.get_version_info(),
		"audio_driver": AudioServer.get_driver_name(), "mix_rate": AudioServer.get_mix_rate(),
		"executable": OS.get_executable_path(), "command_line_arguments": OS.get_cmdline_args(),
		"run_utc": Time.get_datetime_string_from_system(true) + "Z",
		"wall_ms": Time.get_ticks_msec() - started_ms, "playback_wall_ms": playback_wall_ms,
		"requested_timer_seconds": requested_wait_seconds, "observed_frames": observed_frames,
		"music_player_count": music_ids.size(), "sfx_player_count": sfx_ids.size(),
		"max_active_music": max_music, "max_active_sfx": max_sfx,
		"actual_sfx_playback_positions": sfx_playback_positions, "imports": imports,
		"summary": summaries, "phases": phases, "aligned_gain_measurements": gain_measurements,
		"production_findings": production_findings,
		"cleanup": cleanup, "test_mix_wav": wav_result, "protected_source_sha256": source_hashes,
		"environment_context": environment, "hardware_playback_validated": false, "listened_to_audio": false,
		"scope": ["Real production Audio.gd in a standalone SceneTree; no main-scene gameplay/UI test",
			"Actual engine AudioStreamPlayer playback and AudioEffectCapture; no synthesized/mock mix",
			"Music lengths and loop flags tested on actual imported resources; boundary seeks avoid waiting 186 seconds",
			"Test-only unity music/SFX buses feed unchanged Master; effects and buses removed on exit",
			"Existing PCM/R128 analysis read only; this report is not a new R128 or listening assessment",
			"Dummy validates engine mixing only; hardware/WASAPI output cannot be certified here"]}
	var output: FileAccess = FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if output == null:
		printerr("Cannot write runtime report; error=" + str(FileAccess.get_open_error()))
		quit(2)
		return
	output.store_string(JSON.stringify(report, "\t") + "\n")
	output.close()


func _abort(reason: String) -> void:
	running = false
	_check(false, "suite completed within runtime preconditions", reason, "completed")
	_end_phase()
	_cleanup()
	_verify_sources()
	_save(false)
	quit(2)