extends SceneTree
## Real-scene audio integration, not synthesis/quality or audible-output QA.
## All interactions use in-viewport InputEvents; no OS keyboard/mouse or GUI.

const GameScript = preload("res://scripts/game.gd")
const SoundScript = preload("res://scripts/soundscape.gd")
const VIEW_SIZE := Vector2i(1600, 1000)
const DT: float = 1.0 / 60.0
const ACTIONS: Array[String] = ["inn_left", "inn_right", "inn_up", "inn_down", "inn_sprint"]
const WAV_NAMES: Array[String] = [
	"dialogue_close", "dialogue_open", "fireplace", "footstep_0", "footstep_1",
	"footstep_2", "lute", "reply", "select",
]
const SECTIONS: Array[String] = [
	"samples", "scene_and_buses", "walking", "dialogue", "text_and_busy",
	"modals", "spatial", "mute", "focus", "capture_and_pool",
]

var game: GameScript
var sound: SoundScript
var passed: int = 0
var failed: int = 0
var skipped: int = 0
var section: String = "startup"
var section_passed: int = 0
var section_failed: int = 0
var completed: Array[String] = []
var finishing: bool = false
var manual_steps: int = 0
var held_keys: Array[int] = []
var mouse_position := Vector2.ZERO
var cues: Array[String] = []
var cue_bindings: Array[Dictionary] = []
var mute_events: Array[bool] = []
var requests: Array[Dictionary] = []
var responses: Array[Dictionary] = []
var chosen: Array[String] = []
var samples: Dictionary = {}
var original_fire: AudioStreamWAV
var original_fire_settings: Array = []
var original_buses: Array[Dictionary] = []
var own_buses: Array[StringName] = []
var original_root_children: int = 0
var capture_effect: AudioEffectCapture
var playback_refs: Array[WeakRef] = []
var owned_resource_refs: Array[WeakRef] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	create_timer(60.0).timeout.connect(_deadline)
	original_buses = _bus_layout()
	original_root_children = root.get_child_count()
	root.size = VIEW_SIZE
	if not _test_samples():
		await _finish()
		return
	var scene: PackedScene = load("res://main.tscn") as PackedScene
	if not _check(scene != null, "main.tscn loads", "PackedScene", scene):
		await _finish()
		return
	game = scene.instantiate() as GameScript
	if not _check(game != null, "real game instantiates", "GameScript", game):
		await _finish()
		return
	sound = game.sound
	# Observe the startup cue too, rather than silently subtracting/clearing it.
	sound.cue_played.connect(_on_cue)
	sound.mute_changed.connect(_on_mute)
	root.add_child(game)
	# Disable BEFORE yielding: real port timers/Controls run, sound time never doubles.
	game.set_physics_process(false)
	sound.set_process(false)
	game.player.set_process(false)
	for npc: Node in game.npcs.values():
		npc.set_process(false)
	own_buses.assign([sound.master_bus, sound.ambience_bus, sound.music_bus])
	game.dialogue.port.request_dispatched.connect(_on_request)
	game.dialogue.port.response_ready.connect(_on_response)
	game.ui.choice_selected.connect(_on_choice)
	var clock: float = sound._since_step
	await _settle()
	_equal(sound._since_step, clock, "settling frames do not advance sound time")
	_test_scene_and_buses()
	await _test_walking()
	await _test_dialogue()
	await _test_text_and_busy()
	await _test_modals()
	await _test_spatial()
	await _test_mute()
	await _test_focus()
	await _test_capture_and_pool()
	_equal(completed, SECTIONS, "all integration sections completed")
	_check(passed + failed >= 30, "minimum assertion coverage", ">= 30", passed + failed)
	await _finish()


func _test_samples() -> bool:
	_begin("samples")
	var manifest: Array[String] = []
	for filename: String in DirAccess.get_files_at("res://assets/audio"):
		if filename.ends_with(".wav"):
			manifest.append(filename.get_basename())
	manifest.sort()
	_equal(manifest, WAV_NAMES, "exactly the nine production WAVs")
	var valid: bool = true
	for cue: String in WAV_NAMES:
		var wav: AudioStreamWAV = load("res://assets/audio/%s.wav" % cue) as AudioStreamWAV
		if not _check(wav != null, cue + " loads through ResourceLoader", "AudioStreamWAV", wav):
			valid = false
			continue
		samples[cue] = wav
		_check(wav.get_length() > 0.0, cue + " decoded duration", "> 0 seconds", wav.get_length())
	original_fire = samples.get("fireplace") as AudioStreamWAV
	if original_fire != null:
		original_fire_settings = _fire_settings(original_fire)
	_end()
	return valid


func _test_scene_and_buses() -> void:
	_begin("scene_and_buses")
	_equal(DisplayServer.get_name(), "headless", "no desktop window")
	_equal(root.size, VIEW_SIZE, "1600x1000 root")
	_equal(game.is_physics_processing(), false, "game physics is manually advanced")
	_equal(sound.is_processing(), false, "sound process is manually advanced")
	_equal(sound.get_parent(), game, "production sound node belongs to main scene")
	_equal(game.ui.model, game.dialogue, "real UI/model binding")
	_equal(sound.muted, false, "audio defaults to unmuted")
	_equal(sound.suspended, false, "audio initially unsuspended")
	_equal(game.ui.audio_button.text, "M  声音：开", "actual HUD defaults to sound on")
	_equal(cues, ["dialogue_open"], "exactly one separately observed startup cue")
	_equal(AudioServer.bus_count, original_buses.size() + 3, "only three owned buses added")
	var added: Array[String] = []
	var originals: Array[String] = []
	for bus: Dictionary in original_buses:
		originals.append(bus["name"])
	for index: int in range(AudioServer.bus_count):
		var name: String = str(AudioServer.get_bus_name(index))
		if not originals.has(name):
			added.append(name)
	_equal(added, [str(sound.master_bus), str(sound.ambience_bus), str(sound.music_bus)], "exact owned bus identities")
	for bus: StringName in own_buses:
		var index: int = AudioServer.get_bus_index(bus)
		if _check(index > 0, "owned bus exists outside Master: " + str(bus), "> 0", index):
			_equal(AudioServer.is_bus_mute(index), false, "owned bus initially unmuted: " + str(bus))
	_equal(AudioServer.get_bus_send(AudioServer.get_bus_index(sound.master_bus)), &"Master", "owned mix sends to Master")
	_near(AudioServer.get_bus_volume_db(AudioServer.get_bus_index(sound.master_bus)), -2.0, 0.001, "owned mix gain")
	for row: Array in [[sound.ambience_bus, sound.fire_pan], [sound.music_bus, sound.lute_pan]]:
		var index: int = AudioServer.get_bus_index(row[0])
		_equal(AudioServer.get_bus_send(index), sound.master_bus, "spatial bus routes into owned mix")
		_equal(AudioServer.get_bus_effect_count(index), 1, "one spatial effect, not an unrelated bus effect")
		_equal(AudioServer.get_bus_effect(index, 0), row[1], "actual AudioEffectPanner attached")
	_original_buses_unchanged("startup preserves Master and every pre-existing bus")
	_equal(sound.voices.size(), 6, "six real cue-pool AudioStreamPlayers")
	_equal(sound.fireplace.bus, sound.ambience_bus, "fireplace uses spatial fire bus")
	_equal(sound.lute.bus, sound.music_bus, "lute uses spatial music bus")
	_equal(sound.lute.stream, samples["lute"], "lute binds the loaded production WAV")
	_equal(sound.fireplace.playing, true, "fireplace playback started")
	playback_refs.append(weakref(sound.fireplace.get_stream_playback()))
	owned_resource_refs.append(weakref(sound.fire_pan))
	owned_resource_refs.append(weakref(sound.lute_pan))
	var fire: AudioStreamWAV = sound.fireplace.stream as AudioStreamWAV
	if _check(fire != null, "fireplace stream type", "AudioStreamWAV", fire):
		owned_resource_refs.append(weakref(fire))
		_check(fire != original_fire, "loop settings belong to a duplicate Resource", "distinct resources", [fire, original_fire])
		_equal(fire.loop_mode, AudioStreamWAV.LOOP_FORWARD, "fireplace loops forward")
		_equal(fire.mix_rate, 44100, "fireplace sample rate")
		_equal(fire.loop_begin, 0, "fireplace loop starts at first frame")
		_equal(fire.loop_end, 705600, "loop contains the complete 16 seconds, not byte count")
		_near(fire.get_length(), 16.0, 1.0 / 44100.0, "fireplace duration")
		_near(float(fire.loop_end) / float(fire.mix_rate), fire.get_length(), 1.0 / 44100.0, "loop end matches full sample length")
		_equal(fire.data.size(), original_fire.data.size(), "duplicate keeps the complete sample data")
	_equal(_fire_settings(original_fire), original_fire_settings, "cached original Resource settings are unchanged")
	_end()


func _test_walking() -> void:
	_begin("walking")
	_fixture(Vector2(800, 750))
	var origin: Vector2 = game.player.ground_position
	var start: int = cues.size()
	var steps_before: int = game.footsteps
	_physical_key(KEY_D, true)
	_equal(Input.is_action_pressed("inn_right"), true, "real D event activates movement action")
	_advance_frames(60)
	_physical_key(KEY_D, false)
	_near(game.player.ground_position.distance_to(origin), 224.0, 0.03, "one second of real displacement")
	_equal(game.footsteps - steps_before, 6, "distance, not frame count, triggers six steps")
	_expect_cues(start, ["footstep_0", "footstep_1", "footstep_2", "footstep_0", "footstep_1", "footstep_2"], "footstep WAVs rotate in order")
	start = cues.size()
	origin = game.player.ground_position
	_advance_frames(60)
	_equal(game.player.ground_position, origin, "released movement remains stationary")
	_expect_cues(start, [], "standing still produces no footsteps")
	_fixture(Vector2(950, 430))
	origin = game.player.ground_position
	_physical_key(KEY_W, true)
	_advance_frames(90)
	var stopped: Vector2 = game.player.ground_position
	_check(stopped.distance_to(origin) > 5.0 and stopped.distance_to(origin) < 100.0,
		"real north-bar collision stops an initially moving actor", "5 < travel < 100 px", stopped.distance_to(origin))
	_check(game.navigation.is_walkable(stopped), "collision fixture stays on valid floor", true, stopped)
	start = cues.size()
	steps_before = game.footsteps
	_advance_frames(60)
	_equal(game.player.ground_position, stopped, "holding W at collision cannot move")
	_equal(game.footsteps, steps_before, "collision does not count phantom steps")
	_expect_cues(start, [], "held collision key does not emit footsteps")
	_physical_key(KEY_W, false)
	_fixture(Vector2(800, 750))
	await _settle()
	start = cues.size()
	_click_at(Vector2(1000, 750))
	_check(not game.route.is_empty(), "real ground click creates route", "nonempty route", game.route)
	for _index: int in range(120):
		if game.route.is_empty():
			break
		_step(DT)
	_near(game.player.ground_position.distance_to(Vector2(1000, 750)), 0.0, 2.0, "mouse route really reaches destination")
	_check(_footsteps_since(start).size() >= 5, "mouse-driven displacement also produces steps", ">= 5", _footsteps_since(start))
	start = cues.size()
	_advance_frames(30)
	_expect_cues(start, [], "completed route produces no trailing footsteps")
	await _open_near("mira")
	origin = game.player.ground_position
	start = cues.size()
	_physical_key(KEY_D, true)
	_advance_frames(60)
	_physical_key(KEY_D, false)
	_equal(game.player.ground_position, origin, "dialogue blocks actual movement")
	_expect_cues(start, [], "dialogue blocks footsteps despite held movement input")
	_tap(KEY_ESCAPE)
	_end()


func _test_dialogue() -> void:
	_begin("dialogue")
	_fixture(GameScript.SPAWN)
	var start: int = cues.size()
	_tap(KEY_E)
	_equal(game.dialogue.is_open, false, "E without a nearby NPC is rejected")
	_expect_cues(start, [], "rejected far interaction has no opening cue")
	await _open_near("mira")
	start = cues.size()
	_tap(KEY_E)
	_tap(KEY_ENTER)
	_expect_cues(start, [], "revealing an open dialogue does not reopen/replay sound")
	_tap(KEY_1)
	_equal(game.dialogue.page, "guide", "valid numeric choice reaches real local branch")
	_expect_cues(start, ["select"], "valid local choice has exactly one select, no reply")
	start = cues.size()
	_tap(KEY_4)
	_tap(KEY_0)
	_equal(game.dialogue.page, "guide", "invalid choice slots cannot navigate")
	_expect_cues(start, [], "invalid choices while not busy do not leak select")
	await _click_choice("back")
	start = cues.size()
	_tap(KEY_4)
	_equal(game.dialogue.is_open, false, "valid goodbye closes dialogue")
	_expect_cues(start, ["dialogue_close"], "goodbye has close only, not select")
	await _open_near("oren")
	start = cues.size()
	var request_count: int = requests.size()
	await _click_choice("list_running")
	_equal(requests.size(), request_count + 1, "actual option Button dispatches one request")
	_equal(game.dialogue.busy, true, "production asynchronous busy state reached")
	_expect_cues(start, ["select"], "accepted request selects before reply, once")
	_assert_busy_silent("Oren request")
	await _await_reply("Oren request")
	var reply_count: int = int(sound.played_counts.get("reply", 0))
	start = cues.size()
	await _click_choice("back")
	_tap(KEY_4)
	await _settle()
	_equal(game.dialogue.page, "chat", "another real changed notification refreshes local page")
	_equal(int(sound.played_counts.get("reply", 0)), reply_count, "same response ID does not replay on subsequent refreshes")
	_expect_cues(start, ["select", "select"], "back/local refresh has no duplicate reply")
	start = cues.size()
	_tap(KEY_ESCAPE)
	_tap(KEY_ESCAPE)
	_expect_cues(start, ["dialogue_close"], "Escape closes exactly once, closed Escape is silent")
	await _open_near("eve")
	start = cues.size()
	await _click_control(_find_button(game.ui.dialog_panel, "×"), "dialogue close Button")
	_equal(game.dialogue.is_open, false, "real close Button closes model")
	_expect_cues(start, ["dialogue_close"], "close Button routes to one closing cue")
	_end()


func _test_text_and_busy() -> void:
	_begin("text_and_busy")
	await _open_near("finn")
	_equal(sound.lute.stream, samples["lute"], "Finn's lute retains actual WAV binding")
	_equal(sound.lute.playing, true, "Finn starts the real music player")
	var start: int = cues.size()
	_tap(KEY_3)
	await _settle()
	_equal(game.dialogue.page, "input", "free-chat choice opens actual input page")
	_expect_cues(start, ["select"], "entering free chat is one valid selection")
	_click_at(game.ui.input_line.get_global_rect().get_center())
	_equal(game.ui.input_line.has_focus(), true, "real click focuses LineEdit")
	start = cues.size()
	var toggles: int = mute_events.size()
	var position_before: Vector2 = game.player.ground_position
	_physical_key(KEY_M, true, 109)
	_step(DT)
	_physical_key(KEY_M, false)
	await _settle()
	_equal(game.ui.input_line.text, "m", "letter m really enters LineEdit")
	_equal(game.ui.input_counter.text, "1 / 280", "text_changed updates the real counter")
	_equal(sound.muted, false, "focused m does not toggle sound")
	_equal(AudioServer.is_bus_mute(AudioServer.get_bus_index(sound.master_bus)), false, "focused m leaves real audio bus unmuted")
	_equal(game.ui.audio_button.text, "M  声音：开", "focused m leaves HUD sound on")
	_equal(mute_events.size(), toggles, "focused m emits no mute_changed")
	_equal(game.player.ground_position, position_before, "focused typing leaves player still")
	_expect_cues(start, [], "typing m creates no audio cue")
	var request_count: int = requests.size()
	_tap(KEY_ENTER)
	_equal(requests.size(), request_count + 1, "real Return submits typed message once")
	_equal(game.dialogue.last_request.get("arguments"), {"message": "m"}, "request contains the typed m")
	_expect_cues(start, ["select"], "accepted text submission has one select")
	_equal(game.ui.input_line.text, "", "accepted input is cleared")
	_equal(game.ui.input_line.editable, false, "busy LineEdit is read-only")
	_equal(game.ui.send_button.disabled, true, "busy send Button is disabled")
	_assert_busy_silent("Finn text request, including repeated Return")
	await _await_reply("Finn text request")
	start = cues.size()
	request_count = requests.size()
	_click_at(game.ui.input_line.get_global_rect().get_center())
	_tap(KEY_ENTER)
	await _settle()
	_equal(requests.size(), request_count, "empty text does not dispatch")
	_equal(game.dialogue.busy, false, "rejected empty text remains not busy")
	_check("空白" in game.ui.body.text, "real blank-input rejection reaches UI", "contains 空白", game.ui.body.text)
	_expect_cues(start, [], "empty submission/refresh emits neither select nor stale reply")
	_click_at(game.ui.input_line.get_global_rect().get_center())
	await _type_text("again")
	start = cues.size()
	await _click_control(game.ui.send_button, "send Button")
	_equal(requests.size(), request_count + 1, "send Button dispatches one accepted request")
	_expect_cues(start, ["select"], "send Button is bound to one selection cue")
	await _await_reply("second distinct text response")
	_click_at(game.ui.input_line.get_global_rect().get_center())
	await _type_text("cancel")
	_tap(KEY_ENTER)
	_check(not game.dialogue.pending_request_id.is_empty(), "cancellation has a real pending request", "nonempty request ID", game.dialogue.pending_request_id)
	await _settle()
	var response_count: int = responses.size()
	start = cues.size()
	_tap(KEY_ESCAPE)
	_expect_cues(start, ["dialogue_close"], "closing a busy conversation emits one close")
	start = cues.size()
	await _drain_latency()
	_equal(responses.size(), response_count, "canceled request does not return to a closed session")
	_expect_cues(start, [], "canceled reply cannot sound later")
	_end()


func _test_modals() -> void:
	_begin("modals")
	for kind: String in ["guide", "journal"]:
		_fixture(GameScript.SPAWN)
		var key: int = KEY_F1 if kind == "guide" else KEY_J
		var start: int = cues.size()
		_tap(key)
		await _settle()
		_equal(game.ui.modal_kind, kind, kind + " shortcut opens real modal")
		_expect_cues(start, ["select"], kind + " opening emits select")
		start = cues.size()
		var point: Vector2 = game.player.ground_position
		_physical_key(KEY_D, true)
		_advance_frames(20)
		_physical_key(KEY_D, false)
		_tap(KEY_1)
		_tap(KEY_E)
		_tap(KEY_ENTER)
		_click_at(game.ui.audio_button.get_global_rect().get_center())
		_equal(game.player.ground_position, point, kind + " blocks movement")
		_equal(sound.muted, false, kind + " blocks underlying audio Button")
		_expect_cues(start, [], kind + " blocked controls/steps do not leak sound")
		_tap(key)
		_equal(game.ui.modal.visible, false, kind + " same shortcut closes")
		_expect_cues(start, ["dialogue_close"], kind + " shortcut closes exactly once")
		start = cues.size()
		var text: String = "F1  旅店指南" if kind == "guide" else "J  旅人手记"
		await _click_control(_find_button(game.ui, text), kind + " HUD Button")
		_equal(game.ui.modal_kind, kind, kind + " real HUD Button opens")
		await _click_control(_find_button(game.ui.modal, "×"), kind + " modal close Button")
		_expect_cues(start, ["select", "dialogue_close"], kind + " mouse open/close sound bindings")
	await _open_near("oren")
	_tap(KEY_F1)
	var start: int = cues.size()
	_tap(KEY_1)
	_tap(KEY_ENTER)
	_equal(game.dialogue.page, "root", "modal blocks underlying dialogue choice")
	_expect_cues(start, [], "modal-blocked valid underlying choice has no select")
	_tap(KEY_ESCAPE)
	_equal(game.dialogue.is_open, true, "first Escape closes only the modal")
	_expect_cues(start, ["dialogue_close"], "top modal has one closing cue")
	start = cues.size()
	_tap(KEY_ESCAPE)
	_tap(KEY_ESCAPE)
	_expect_cues(start, ["dialogue_close"], "underlying dialogue closes once, not twice")
	_end()


func _test_spatial() -> void:
	_begin("spatial")
	# Acoustic-only placements straddle the off-floor hearth. These are NOT
	# navigation-reachability claims; the real game still updates the listener.
	var probes: Array[Dictionary] = [
		{"point": Vector2(201, 430), "db": -12.0, "pan": 0.0},
		{"point": Vector2(-99, 430), "db": -15.142857, "pan": 300.0 / 1100.0},
		{"point": Vector2(501, 430), "db": -15.142857, "pan": -300.0 / 1100.0},
		{"point": Vector2(-1799, 430), "db": -23.0, "pan": 0.55},
		{"point": Vector2(2201, 430), "db": -23.0, "pan": -0.55},
	]
	for probe: Dictionary in probes:
		_fixture(probe["point"], false)
		_step(0.5)
		var label: String = "listener " + str(probe["point"])
		_near(sound.fire_target_db, probe["db"], 0.0001, label + " fireplace attenuation")
		_near(sound.fire_pan.pan, probe["pan"], 0.0001, label + " fireplace left/right pan")
		_near(sound.fireplace.volume_db, probe["db"], 0.001, label + " actual player gain follows target")
		if probe["point"].x < -1000.0 or probe["point"].x > 2000.0:
			_near(sound.lute_pan.pan, 0.45 if probe["point"].x < 0.0 else -0.45, 0.0001, label + " music pan clamp")
			_near(sound.lute_target_db, -28.0, 0.0001, label + " distant music attenuation")
	_fixture(Vector2(350, 610))
	var nearby_fire: float = sound.fire_target_db
	_check(sound.lute_pan.pan > 0.0, "reachable position left of bard pans him right", "> 0", sound.lute_pan.pan)
	_fixture(Vector2(1160, 600))
	_check(sound.fire_target_db < nearby_fire, "real distant floor position attenuates hearth", "< " + str(nearby_fire), sound.fire_target_db)
	_check(sound.lute_pan.pan < 0.0, "reachable position right of bard pans him left", "< 0", sound.lute_pan.pan)
	_fixture(game.npcs["oren"].ground_position + Vector2(0, 95))
	var fire_before: float = sound.fire_target_db
	var lute_before: float = sound.lute_target_db
	var pan_before: float = sound.fire_pan.pan
	_tap(KEY_E)
	await _settle()
	_equal(game.dialogue.is_open, true, "real conversation activates spatial ducking")
	_near(sound.fire_target_db, fire_before - 3.0, 0.0001, "dialogue ducks fireplace by 3 dB")
	_near(sound.lute_target_db, lute_before - 4.0, 0.0001, "dialogue ducks music by 4 dB")
	_near(sound.fire_pan.pan, pan_before, 0.0001, "dialogue does not change spatial pan")
	_tap(KEY_ESCAPE)
	_step(0.0)
	_near(sound.fire_target_db, fire_before, 0.0001, "closing dialogue removes fireplace duck")
	_end()


func _test_mute() -> void:
	_begin("mute")
	_fixture(GameScript.SPAWN)
	var start: int = cues.size()
	var toggles: int = mute_events.size()
	_tap(KEY_M)
	_assert_mute(true, "M mutes")
	_expect_cues(start, [], "muting is silent")
	_equal(mute_events.size(), toggles + 1, "M emits one mute_changed")
	_equal(sound.fireplace.stream_paused, true, "muting pauses fireplace")
	_assert_stopped_voices("muting stops old one-shots rather than queuing them")
	_equal(sound.lute.playing, false, "muting stops old lute phrase")
	var lute_clock: float = sound._since_lute
	start = cues.size()
	var steps_before: int = game.footsteps
	_physical_key(KEY_D, true)
	_advance_frames(20)
	_physical_key(KEY_D, false)
	_check(game.footsteps > steps_before, "muted real movement still crosses step threshold", "> " + str(steps_before), game.footsteps)
	await _open_near("finn", true)
	await _click_choice("story")
	_equal(game.dialogue.busy, true, "muted choice still dispatches real request")
	await _await_reply("muted response", false)
	_tap(KEY_ESCAPE)
	_tap(KEY_F1)
	_tap(KEY_ESCAPE)
	_step(25.0)
	_expect_cues(start, [], "muted steps/open/lute/select/reply/close/modal never create cues")
	_equal(sound._since_lute, lute_clock, "muted time does not accumulate overdue lute phrases")
	_assert_stopped_voices("suppressed cues do not restart stopped players")
	_fixture(Vector2(1160, 600))
	start = cues.size()
	await _click_control(game.ui.audio_button, "restore audio Button")
	_assert_mute(false, "audio Button restores")
	_expect_cues(start, ["select"], "restore emits only its new confirmation")
	_equal(sound.fireplace.stream_paused, false, "restoring resumes fireplace")
	start = cues.size()
	_advance_frames(30)
	await _settle()
	_expect_cues(start, [], "restore cannot replay suppressed or previously stopped cues")
	await _click_control(game.ui.audio_button, "mute audio Button")
	_assert_mute(true, "audio Button also mutes")
	root.push_input(_key_event(KEY_M, true, 0, true), true)
	root.push_input(_key_event(KEY_M, false), true)
	_assert_mute(true, "M key-repeat cannot toggle mute")
	start = cues.size()
	_tap(KEY_M)
	_assert_mute(false, "M also restores")
	_expect_cues(start, ["select"], "M restore emits one fresh confirmation")
	_equal(mute_events.slice(toggles), [true, false, true, false], "keyboard/Button binding emits exact mute transitions")
	start = cues.size()
	_tap(KEY_F1)
	_tap(KEY_ESCAPE)
	_expect_cues(start, ["select", "dialogue_close"], "new post-restore UI inputs still sound normally")
	_end()


func _test_focus() -> void:
	_begin("focus")
	_fixture(GameScript.SPAWN)
	await _settle()
	_click_at(game.camera.unproject_position(game.npcs["mira"].global_position) + Vector2(0, -70))
	_check(not game.route.is_empty() and game.pending_npc == "mira", "focus fixture starts with real NPC-click route", "route to mira", [game.route, game.pending_npc])
	_physical_key(KEY_D, true)
	var start: int = cues.size()
	var clock: float = sound._since_lute
	var playback_before: Array[bool] = _playback_flags()
	# Deliver the actual engine notification locally; never steal OS window focus.
	game.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_equal(sound.suspended, true, "focus-out suspends sound")
	_equal(game.route.size(), 0, "focus-out clears route")
	_equal(game.pending_npc, "", "focus-out cancels pending interaction")
	_equal(Input.is_action_pressed("inn_right"), false, "focus-out releases held movement")
	_assert_paused(true, "focus-out", playback_before)
	_physical_key(KEY_D, false)
	_step(20.0)
	_equal(sound._since_lute, clock, "suspension does not accumulate music time")
	await _open_near("finn", true)
	_expect_cues(start, [], "suspended movement and open/lute attempts are silent")
	game.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
	_equal(sound.suspended, false, "focus-in resumes sound")
	_assert_paused(false, "focus-in", playback_before)
	_step(0.0)
	await _settle()
	_expect_cues(start, [], "focus-in does not invent/replay suppressed cues")
	start = cues.size()
	_tap(KEY_ESCAPE)
	_expect_cues(start, ["dialogue_close"], "fresh input after focus-in sounds normally")
	await _open_near("finn")
	playback_before = _playback_flags()
	_equal(playback_before[1], true, "active-focus fixture has a really playing lute")
	_check(playback_before.slice(2).has(true), "active-focus fixture has playing cue-pool voices", "at least one playing voice", playback_before)
	var lute_stream: AudioStream = sound.lute.stream
	start = cues.size()
	game.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_assert_paused(true, "active Finn focus-out", playback_before)
	await create_timer(0.12).timeout
	game.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
	_assert_paused(false, "active Finn focus-in", playback_before)
	_equal(sound.lute.playing, true, "focus-in resumes the existing lute playback")
	_equal(sound.lute.stream, lute_stream, "focus-in preserves the existing lute stream")
	_expect_cues(start, [], "resuming active players does not issue a new cue")
	_tap(KEY_ESCAPE)
	_tap(KEY_M)
	start = cues.size()
	playback_before = _playback_flags()
	game.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_OUT)
	game.notification(MainLoop.NOTIFICATION_APPLICATION_FOCUS_IN)
	_assert_mute(true, "focus cycle preserves user mute")
	_assert_paused(true, "muted focus-in", playback_before)
	_expect_cues(start, [], "focus cycle does not unmute or emit cues")
	_tap(KEY_M)
	_assert_mute(false, "explicit M restores after muted focus cycle")
	_equal(sound.fireplace.stream_paused, false, "fireplace resumes only after explicit unmute")
	_original_buses_unchanged("focus cycles preserve pre-existing bus state")
	_end()


func _test_capture_and_pool() -> void:
	_begin("capture_and_pool")
	_fixture(GameScript.SPAWN)
	var bus_index: int = AudioServer.get_bus_index(sound.master_bus)
	var effects_before: int = AudioServer.get_bus_effect_count(bus_index)
	capture_effect = AudioEffectCapture.new()
	capture_effect.buffer_length = 0.5
	owned_resource_refs.append(weakref(capture_effect))
	AudioServer.add_bus_effect(bus_index, capture_effect)
	await _open_near("finn")
	await create_timer(0.2).timeout
	var available: int = capture_effect.get_frames_available()
	var peak: float = 0.0
	if available > 0:
		var frames: PackedVector2Array = capture_effect.get_buffer(available)
		_equal(frames.size(), available, "capture returns its reported frame count")
		for frame: Vector2 in frames:
			peak = maxf(peak, maxf(absf(frame.x), absf(frame.y)))
	if peak > 0.0:
		_check(true, "real AudioEffectCapture contains nonzero mixed samples", "> 0", peak)
		print("SOUND_MIX: captured_frames=%d peak=%f; software mix only, NOT an audibility/listening claim" % [available, peak])
	else:
		skipped += 1
		print("SOUND_MIX: SKIPPED -- headless capture has frames=%d peak=%f; nonzero mixing/audible output not verified" % [available, peak])
	_remove_capture()
	_equal(AudioServer.get_bus_effect_count(bus_index), effects_before, "temporary capture removed from owned bus")
	var seen: Array[String] = []
	var counts: Dictionary = {}
	var slots: Dictionary = {}
	var invalid: Array[Dictionary] = []
	for index: int in range(cues.size()):
		var cue: String = cues[index]
		counts[cue] = int(counts.get(cue, 0)) + 1
		if not seen.has(cue):
			seen.append(cue)
		var binding: Dictionary = cue_bindings[index]
		if not binding["valid"]:
			invalid.append(binding)
		if binding["slot"] >= 0:
			slots[binding["slot"]] = true
	seen.sort()
	var expected: Array[String] = SoundScript.CUES.duplicate()
	expected.sort()
	_equal(seen, expected, "all eight cues exercised through real game inputs")
	_equal(sound.played_counts, counts, "production counts exactly match independently observed signals")
	_equal(invalid, [], "every cue signal had an actual playing WAV on its correct bus")
	_equal(slots.size(), 6, "real inputs exercised every round-robin voice slot")
	_equal(playback_refs.size(), cues.size() + 1, "every cue playback plus fireplace is tracked weakly for teardown")
	for index: int in range(sound.voices.size()):
		var voice: AudioStreamPlayer = sound.voices[index]
		_equal(voice.get_parent(), sound, "pool voice %d belongs to production sound node" % index)
		_equal(voice.bus, sound.master_bus, "pool voice %d routes to owned bus" % index)
		_equal(voice.max_polyphony, 1, "pool voice %d is bounded" % index)
		_check(voice.stream != null and samples.values().has(voice.stream), "pool voice %d holds a real loaded production stream" % index, "one of nine cached WAVs", voice.stream)
	_equal(_fire_settings(original_fire), original_fire_settings, "all playback leaves source fireplace settings untouched")
	_equal(sound.is_processing(), false, "sound never re-enabled automatic process during composite test")
	_original_buses_unchanged("capture/playback preserved all original buses")
	_end()


func _assert_busy_silent(label: String) -> void:
	_equal(game.dialogue.busy, true, label + " precondition is actual busy state")
	var start: int = cues.size()
	var count: int = requests.size()
	var pending: String = game.dialogue.pending_request_id
	for child: Node in game.ui.choice_box.get_children():
		var button: Button = child as Button
		_equal(button.disabled, true, label + " busy option disabled")
		_click_at(button.get_global_rect().get_center())
	if game.ui.send_button.is_visible_in_tree():
		_click_at(game.ui.send_button.get_global_rect().get_center())
	_tap(KEY_1)
	_tap(KEY_4)
	_tap(KEY_ENTER)
	_tap(KEY_ENTER)
	_equal(requests.size(), count, label + " rejected inputs cannot dispatch again")
	_equal(game.dialogue.pending_request_id, pending, label + " keeps current request ID")
	_expect_cues(start, [], label + " busy/invalid/disabled inputs cannot leak select")


func _await_reply(label: String, audible_cue: bool = true) -> void:
	var request_id: String = game.dialogue.pending_request_id
	var before: int = responses.size()
	var start: int = cues.size()
	_check(not request_id.is_empty(), label + " real pending request", "nonempty request ID", request_id)
	var clock: float = sound._since_step
	await _drain_latency()
	_equal(sound._since_step, clock, label + " real-time timer does not double-advance sound clock")
	_equal(game.dialogue.busy, false, label + " completes within production latency")
	_equal(responses.size(), before + 1, label + " one actual response_ready")
	_equal(game.dialogue.last_response.get("request_id"), request_id, label + " matching response adopted")
	_equal(game.ui.body.text, game.dialogue.last_response.get("message"), label + " actual UI shows reply")
	_expect_cues(start, ["reply"] if audible_cue else [], label + " reply cue count")
	start = cues.size()
	await _settle()
	_expect_cues(start, [], label + " settling does not repeat reply")


func _drain_latency() -> void:
	# Allow the real deferred dispatcher to create its timer, then wait once.
	await process_frame
	await create_timer(game.dialogue.port.latency_seconds + 0.12).timeout
	await _settle()


func _open_near(id: String, silent: bool = false) -> void:
	_fixture(game.npcs[id].ground_position + Vector2(0, 95))
	await _settle()
	var start: int = cues.size()
	_tap(KEY_E)
	await _settle()
	_equal(game.dialogue.is_open, true, id + " E opens real nearby dialogue")
	_equal(game.dialogue.npc_id, id, id + " E selects correct NPC")
	_expect_cues(start, [] if silent else (["dialogue_open", "lute"] if id == "finn" else ["dialogue_open"]), id + " opening sound binding")


func _fixture(point: Vector2, require_walkable: bool = true) -> void:
	# Same position-only fixture as test_game.gd; never set audio/model state.
	_release_keys()
	if game.ui.modal.visible:
		_tap(KEY_ESCAPE)
	if game.dialogue.is_open:
		_tap(KEY_ESCAPE)
	_tap(KEY_ESCAPE)
	game.player.set_ground_position(point)
	game.player.set_motion(Vector2.ZERO)
	game._physics_process(0.0)
	if require_walkable:
		_check(game.navigation.is_walkable(point), "valid placement fixture", "walkable floor", point)


func _step(delta: float) -> void:
	game._physics_process(delta)
	sound._process(delta)
	manual_steps += 1


func _advance_frames(count: int) -> void:
	for _index: int in range(count):
		_step(DT)


func _settle() -> void:
	await process_frame
	await process_frame
	if is_instance_valid(game):
		game._physics_process(0.0)


func _key_event(code: int, pressed: bool, unicode_value: int = 0, echo: bool = false) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.unicode = unicode_value if pressed else 0
	event.pressed = pressed
	event.echo = echo
	return event


func _tap(code: int, unicode_value: int = 0) -> void:
	root.push_input(_key_event(code, true, unicode_value), true)
	root.push_input(_key_event(code, false), true)


func _physical_key(code: int, pressed: bool, unicode_value: int = 0) -> void:
	Input.parse_input_event(_key_event(code, pressed, unicode_value))
	Input.flush_buffered_events()
	if pressed and not held_keys.has(code):
		held_keys.append(code)
	elif not pressed:
		held_keys.erase(code)


func _release_keys() -> void:
	for code: int in held_keys.duplicate():
		Input.parse_input_event(_key_event(code, false))
	held_keys.clear()
	Input.flush_buffered_events()
	for action: String in ACTIONS:
		if InputMap.has_action(action):
			Input.action_release(action)


func _type_text(value: String) -> void:
	for index: int in range(value.length()):
		var unicode_value: int = value.unicode_at(index)
		var code: int = unicode_value - 32 if unicode_value >= 97 and unicode_value <= 122 else unicode_value
		_tap(code, unicode_value)
	await _settle()


func _click_at(point: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = point
	motion.global_position = point
	motion.relative = point - mouse_position
	root.push_input(motion, true)
	mouse_position = point
	for pressed: bool in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.global_position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
		event.pressed = pressed
		root.push_input(event, true)


func _click_control(control: Control, label: String) -> void:
	if not _check(is_instance_valid(control), label + " exists", "actual Control", control):
		return
	var rect: Rect2 = control.get_global_rect()
	if not _check(control.is_visible_in_tree() and rect.has_area(), label + " has visible hit rectangle", "visible nonempty rect", rect):
		return
	_click_at(rect.get_center())
	await _settle()


func _click_choice(id: String) -> void:
	var index: int = -1
	for candidate: int in range(game.dialogue.choices.size()):
		if game.dialogue.choices[candidate]["id"] == id:
			index = candidate
	if not _check(index >= 0 and index < game.ui.choice_box.get_child_count(), "actual choice exists: " + id, id, game.dialogue.choices):
		return
	var before: int = chosen.size()
	await _click_control(game.ui.choice_box.get_child(index) as Control, "choice " + id)
	_equal(chosen.slice(before), [id], "actual Button emits exactly the chosen ID: " + id)


func _find_button(node: Node, text: String) -> Button:
	if node is Button and node.text == text:
		return node as Button
	for child: Node in node.get_children():
		var found: Button = _find_button(child, text)
		if found != null:
			return found
	return null


func _assert_mute(value: bool, label: String) -> void:
	_equal(sound.muted, value, label + " sound state")
	_equal(AudioServer.is_bus_mute(AudioServer.get_bus_index(sound.master_bus)), value, label + " actual owned bus mute")
	_equal(game.ui.audio_button.text, "M  声音：关" if value else "M  声音：开", label + " actual HUD label")
	_original_buses_unchanged(label + " leaves Master mute/volume and unrelated buses intact")


func _playback_flags() -> Array[bool]:
	var players: Array[AudioStreamPlayer] = [sound.fireplace, sound.lute]
	players.append_array(sound.voices)
	var result: Array[bool] = []
	for player: AudioStreamPlayer in players:
		result.append(player.playing or player.stream_paused)
	return result


func _assert_paused(value: bool, label: String, playback_before: Array[bool]) -> void:
	# Native stopped players have no playback to pause: stream_paused reads false.
	# Expectations come from BEFORE the notification, never the observed result.
	var players: Array[AudioStreamPlayer] = [sound.fireplace, sound.lute]
	players.append_array(sound.voices)
	var states: Array[bool] = []
	var expected: Array[bool] = []
	for index: int in range(players.size()):
		states.append(players[index].stream_paused)
		expected.append(value and playback_before[index])
		if not playback_before[index]:
			_equal(players[index].playing, false, label + " stopped player %d remains stopped" % index)
	_equal(states, expected, label + " pauses retained playbacks, not nonexistent stopped playbacks")
	print("SOUND_PAUSE: %s before_playback=%s paused=%s" % [label, playback_before, states])


func _assert_stopped_voices(label: String) -> void:
	var playing: Array[int] = []
	for index: int in range(sound.voices.size()):
		if sound.voices[index].playing:
			playing.append(index)
	_equal(playing, [], label)


func _fire_settings(wav: AudioStreamWAV) -> Array:
	return [wav.loop_mode, wav.loop_begin, wav.loop_end, wav.mix_rate]


func _bus_state(index: int) -> Dictionary:
	var effects: Array[int] = []
	for effect: int in range(AudioServer.get_bus_effect_count(index)):
		effects.append(AudioServer.get_bus_effect(index, effect).get_instance_id())
	return {"name": str(AudioServer.get_bus_name(index)), "send": str(AudioServer.get_bus_send(index)),
		"mute": AudioServer.is_bus_mute(index), "volume_db": AudioServer.get_bus_volume_db(index),
		"solo": AudioServer.is_bus_solo(index), "effects": effects}


func _bus_layout() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for index: int in range(AudioServer.bus_count):
		result.append(_bus_state(index))
	return result


func _original_buses_unchanged(label: String) -> void:
	var actual: Array[Dictionary] = []
	for bus: Dictionary in original_buses:
		var index: int = AudioServer.get_bus_index(bus["name"])
		actual.append(_bus_state(index) if index >= 0 else {"missing": bus["name"]})
	_equal(actual, original_buses, label)


func _on_cue(cue: String) -> void:
	cues.append(cue)
	var slot: int = -1
	var player: AudioStreamPlayer = sound.lute
	var bus: StringName = sound.music_bus
	if cue != "lute":
		slot = posmod(sound._voice_index - 1, sound.voices.size())
		player = sound.voices[slot]
		bus = sound.master_bus
	var stream: AudioStream = player.stream
	var valid: bool = stream != null and stream == samples.get(cue) and stream.get_length() > 0.0 and player.bus == bus and player.playing
	cue_bindings.append({"cue": cue, "slot": slot, "bus": player.bus,
		"stream": stream.resource_path if stream != null else "null", "playing": player.playing, "valid": valid})
	if player.has_stream_playback():
		playback_refs.append(weakref(player.get_stream_playback()))


func _on_mute(value: bool) -> void:
	mute_events.append(value)


func _on_request(request: Dictionary) -> void:
	requests.append(request.duplicate(true))


func _on_response(response: Dictionary) -> void:
	responses.append(response.duplicate(true))


func _on_choice(id: String) -> void:
	chosen.append(id)


func _footsteps_since(start: int) -> Array[String]:
	var result: Array[String] = []
	for cue: String in cues.slice(start):
		if cue.begins_with("footstep_"):
			result.append(cue)
	return result


func _expect_cues(start: int, expected: Array, label: String) -> void:
	_equal(cues.slice(start), expected, label)


func _remove_capture() -> void:
	if capture_effect == null or not is_instance_valid(sound):
		return
	var index: int = AudioServer.get_bus_index(sound.master_bus)
	if index >= 0:
		for effect: int in range(AudioServer.get_bus_effect_count(index) - 1, -1, -1):
			if AudioServer.get_bus_effect(index, effect) == capture_effect:
				AudioServer.remove_bus_effect(index, effect)
	capture_effect = null


func _begin(name: String) -> void:
	section = name
	section_passed = passed
	section_failed = failed
	print("SOUND_SECTION_BEGIN: " + name)


func _end() -> void:
	completed.append(section)
	print("SOUND_SECTION: %s %d passed, %d failed" % [section, passed - section_passed, failed - section_failed])


func _check(condition: bool, label: String, expected: Variant, actual: Variant) -> bool:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL [%s] %s | expected=%s | actual=%s" % [section, label, str(expected), str(actual)])
	return condition


func _equal(actual: Variant, expected: Variant, label: String) -> bool:
	return _check(actual == expected, label, expected, actual)


func _near(actual: float, expected: float, tolerance: float, label: String) -> bool:
	return _check(absf(actual - expected) <= tolerance, label, "%f +/- %f" % [expected, tolerance], actual)


func _deadline() -> void:
	if finishing:
		return
	_check(false, "60-second watchdog: aborted coroutine or incomplete test", SECTIONS, completed)
	await _finish()


func _finish() -> void:
	if finishing:
		return
	finishing = true
	section = "cleanup"
	_release_keys()
	var pressed: Array[String] = []
	for action: String in ACTIONS:
		if InputMap.has_action(action) and Input.is_action_pressed(action):
			pressed.append(action)
	_equal(pressed, [], "test releases its input actions")
	_remove_capture()
	var refs: Array[WeakRef] = []
	if is_instance_valid(game):
		refs.append(weakref(game))
		refs.append(weakref(game.dialogue))
		refs.append(weakref(game.dialogue.port))
	if is_instance_valid(sound):
		refs.append(weakref(sound))
		for child: Node in sound.get_children():
			refs.append(weakref(child))
	if is_instance_valid(game):
		game.queue_free()
	game = null
	sound = null
	await process_frame
	await process_frame
	var alive: Array[String] = []
	for instance: WeakRef in refs:
		if instance.get_ref() != null:
			alive.append(str(instance.get_ref()))
	_equal(alive, [], "scene, port, sound and every player are freed")
	for bus: StringName in own_buses:
		_equal(AudioServer.get_bus_index(bus), -1, "production exit removes owned bus " + str(bus))
	_equal(_bus_layout(), original_buses, "exit restores exact original bus layout including Master mute/volume")
	_equal(root.get_child_count(), original_root_children, "no scene nodes leaked into root")
	if original_fire != null:
		_equal(_fire_settings(original_fire), original_fire_settings, "source fireplace settings survive teardown unchanged")
	# If production cleanup failed, retain those failures but remove ONLY our own
	# uniquely named buses. Never repair/mute/reconfigure the Master or other buses.
	for bus: StringName in own_buses:
		var index: int = AudioServer.get_bus_index(bus)
		if index > 0:
			AudioServer.remove_bus(index)
			printerr("SOUND_CLEANUP: removed leaked owned bus after recording failure: " + str(bus))
	# Native stop/remove operations are consumed by the audio thread, not by
	# manual sound._process(). Two fast headless frames can precede its next mix.
	# Wait once with a bound, then FAIL for retained playbacks/resources; no polling
	# or force-free workaround can conceal a production lifecycle regression.
	await create_timer(0.25).timeout
	await process_frame
	var retained_playbacks: Array[String] = _retained(playback_refs)
	var retained_resources: Array[String] = _retained(owned_resource_refs)
	_equal(retained_playbacks, [], "audio thread releases every observed playback after bounded drain")
	_equal(retained_resources, [], "owned loop Resource, panners and capture effect are released")
	print("SOUND_CLEANUP: tracked_playbacks=%d retained_playbacks=%s retained_owned_resources=%s" % [playback_refs.size(), retained_playbacks, retained_resources])
	print("SOUND_COVERAGE: sections=%d/%d; WAVs=%d; manual_steps=%d; cue_events=%d; requests=%d; responses=%d; skipped=%d; no audibility claim" % [
		completed.size(), SECTIONS.size(), samples.size(), manual_steps, cues.size(), requests.size(), responses.size(), skipped])
	print("SOUND_TESTS: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _retained(instances: Array[WeakRef]) -> Array[String]:
	var result: Array[String] = []
	for instance: WeakRef in instances:
		var object: Object = instance.get_ref()
		if object != null:
			result.append("%s:%d" % [object.get_class(), object.get_instance_id()])
	return result