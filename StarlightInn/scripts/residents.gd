extends RefCounted
## Local life only. This controller has no Dialogue/provider/Azure reference.

signal chatter(id: String, text: String)
signal chatter_cleared

const Catalog = preload("res://scripts/npc_catalog.gd")
const Navigation = preload("res://scripts/navigation.gd")
const Scenes = preload("res://scripts/npc_scenes.gd")
const TALK_DISTANCE := 190.0
const BREAK_DISTANCE := 230.0
const SCENE_COOLDOWN := 55.0

var actors: Dictionary = {}
var states: Dictionary = {}
var random := RandomNumberGenerator.new()
var enabled: bool = true
var chatter_count: int = 0
var moved_distance: Dictionary = {}
var _room_chatter_cooldown: float = 0.0
var scene_count: int = 0
var _scene: Dictionary = {}
var _scene_index: int = -1
var _line_time: float = 0.0
var _scan_time: float = 0.0
var _scene_cooldowns: Dictionary = {}
var _last_scene_id: String = ""


func setup(residents: Dictionary) -> void:
	actors = residents
	random.randomize()
	states.clear()
	moved_distance.clear()
	_scene = {}
	_scene_index = -1
	_line_time = 0.0
	_scan_time = 0.0
	_scene_cooldowns.clear()
	_last_scene_id = ""
	_room_chatter_cooldown = 0.0
	chatter_count = 0
	scene_count = 0
	for id: String in Catalog.IDS:
		states[id] = {"route": PackedVector2Array(), "wait": random.randf_range(1.2, 4.0),
			"speech_timer": random.randf_range(4.0, 11.0), "greeting_cooldown": 0.0,
			"was_near": false, "stuck": 0.0, "last_line": -1}
		moved_distance[id] = 0.0


func update(delta: float, player_position: Vector2, navigation: Navigation, held_id: String = "", quiet: bool = false, paused: bool = false) -> void:
	if not enabled:
		if not _scene.is_empty():
			cancel_conversation()
		return
	if delta <= 0.0:
		return
	_room_chatter_cooldown = maxf(0.0, _room_chatter_cooldown - delta)
	_scan_time = maxf(0.0, _scan_time - delta)
	for scene_id: String in _scene_cooldowns:
		_scene_cooldowns[scene_id] = maxf(0.0, float(_scene_cooldowns[scene_id]) - delta)
	if quiet or paused:
		if not _scene.is_empty():
			cancel_conversation()
		_room_chatter_cooldown = maxf(_room_chatter_cooldown, 2.5)
	else:
		_advance_scene(delta, navigation, held_id)
		if _scene.is_empty() and _room_chatter_cooldown <= 0.0 and _scan_time <= 0.0:
			_try_conversation(navigation, held_id)
	for id: String in Catalog.IDS:
		var actor = actors[id]
		var state: Dictionary = states[id]
		var record: Dictionary = Catalog.get_npc(id)
		state.greeting_cooldown = maxf(0.0, float(state.greeting_cooldown) - delta)
		if not quiet and not paused:
			state.speech_timer = float(state.speech_timer) - delta
		var near: bool = actor.ground_position.distance_to(player_position) < 180.0
		if id == held_id or paused or _is_participant(id):
			actor.set_motion(Vector2.ZERO)
			state.was_near = near
			continue
		if not quiet and _scene.is_empty() and near and not state.was_near and state.greeting_cooldown <= 0.0 and _room_chatter_cooldown <= 0.0:
			_speak(id, record.hellos[random.randi_range(0, record.hellos.size() - 1)], "wave")
			state.greeting_cooldown = 24.0
		state.was_near = near
		var before: Vector2 = actor.ground_position
		var path: PackedVector2Array = state.route
		if actor.gesture_time > 0.0:
			actor.set_motion(Vector2.ZERO)
			continue
		if not path.is_empty():
			var budget: float = float(record.walk_speed) * delta
			while budget > 0.01 and not path.is_empty():
				var gap: Vector2 = path[0] - actor.ground_position
				if gap.length() < 3.0:
					path.remove_at(0)
					continue
				var wanted: Vector2 = gap.normalized() * minf(budget, gap.length())
				var result: Vector2 = _move(id, actor.ground_position, wanted, player_position, navigation)
				if result.distance_to(actor.ground_position) < 0.01:
					break
				actor.set_ground_position(result)
				budget -= wanted.length()
			state.route = path
			var motion: Vector2 = actor.ground_position - before
			actor.set_motion(motion, delta)
			moved_distance[id] = float(moved_distance[id]) + motion.length()
			state.stuck = float(state.stuck) + delta if motion.length_squared() < 0.001 else 0.0
			if path.is_empty() or state.stuck > 0.85:
				state.route = PackedVector2Array()
				state.wait = random.randf_range(1.5, 4.5)
				state.stuck = 0.0
		else:
			actor.set_motion(Vector2.ZERO)
			state.wait = float(state.wait) - delta
			if not quiet and _scene.is_empty() and state.speech_timer <= 0.0 and _room_chatter_cooldown <= 0.0:
				var line_index: int = random.randi_range(0, record.small_talk.size() - 1)
				if line_index == state.last_line:
					line_index = (line_index + 1) % record.small_talk.size()
				state.last_line = line_index
				_speak(id, record.small_talk[line_index], "celebrate" if random.randf() < 0.55 else "wave")
			elif state.wait <= 0.0:
				_plan_walk(id, player_position, navigation)


func _is_participant(id: String) -> bool:
	return not _scene.is_empty() and id in _scene.participants


func _near_each_other(participants: Array, navigation: Navigation, distance: float) -> bool:
	for index in range(participants.size()):
		for other in range(index + 1, participants.size()):
			var a: Vector2 = actors[participants[index]].ground_position
			var b: Vector2 = actors[participants[other]].ground_position
			if a.distance_to(b) > distance or not navigation.has_clear_sight(a, b):
				return false
	return true


func _try_conversation(navigation: Navigation, held_id: String) -> void:
	_scan_time = 0.3
	var candidates: Array[Dictionary] = []
	var largest: int = 0
	for scene: Dictionary in Scenes.SCENES:
		if held_id in scene.participants or float(_scene_cooldowns.get(scene.id, 0.0)) > 0.0:
			continue
		if not _near_each_other(scene.participants, navigation, TALK_DISTANCE):
			continue
		var count: int = scene.participants.size()
		if count > largest:
			candidates.clear()
			largest = count
		if count == largest:
			candidates.append(scene)
	if candidates.is_empty():
		return
	if candidates.size() > 1:
		for index in range(candidates.size() - 1, -1, -1):
			if candidates[index].id == _last_scene_id:
				candidates.remove_at(index)
	_scene = candidates[random.randi_range(0, candidates.size() - 1)]
	_last_scene_id = _scene.id
	_scene_index = 0
	scene_count += 1
	for id: String in _scene.participants:
		states[id].route = PackedVector2Array()
		states[id].stuck = 0.0
	_emit_scene_line()


func _advance_scene(delta: float, navigation: Navigation, held_id: String) -> void:
	if _scene.is_empty():
		return
	if held_id in _scene.participants or not _near_each_other(_scene.participants, navigation, BREAK_DISTANCE):
		cancel_conversation()
		return
	_line_time -= delta
	if _line_time > 0.0001:
		return
	_scene_index += 1
	if _scene_index >= _scene.lines.size():
		cancel_conversation()
	else:
		_emit_scene_line()


func _emit_scene_line() -> void:
	var line: Array = _scene.lines[_scene_index]
	var speaker: String = line[0]
	var listener: String = _scene.lines[(_scene_index + 1) % _scene.lines.size()][0]
	if listener == speaker:
		for id: String in _scene.participants:
			if id != speaker:
				listener = id
				break
	for id: String in _scene.participants:
		var target: String = listener if id == speaker else speaker
		actors[id].set_conversation(true, actors[target].ground_position)
	_line_time = Scenes.LINE_SECONDS
	chatter_count += 1
	chatter.emit(speaker, line[1])


func cancel_conversation() -> void:
	if not _scene.is_empty():
		_scene_cooldowns[_scene.id] = SCENE_COOLDOWN
		for id: String in _scene.participants:
			actors[id].set_conversation(false)
			states[id].wait = random.randf_range(2.5, 4.5)
			states[id].speech_timer = random.randf_range(13.0, 25.0)
		_room_chatter_cooldown = maxf(_room_chatter_cooldown, 9.0)
	_scene = {}
	_scene_index = -1
	_line_time = 0.0
	chatter_cleared.emit()


func conversation_snapshot() -> Dictionary:
	return {"id": _scene.get("id", ""), "participants": _scene.get("participants", []).duplicate(),
		"line": _scene_index, "remaining": _line_time, "count": scene_count}


func _plan_walk(id: String, player_position: Vector2, navigation: Navigation) -> void:
	var actor = actors[id]
	var record: Dictionary = Catalog.get_npc(id)
	var state: Dictionary = states[id]
	for _attempt in range(8):
		var point: Vector2 = record.roam_points[random.randi_range(0, record.roam_points.size() - 1)]
		point += Vector2(random.randf_range(-32, 32), random.randf_range(-24, 24))
		if point.distance_to(record.position) > float(record.roam_radius) or point.distance_to(actor.ground_position) < 48.0:
			continue
		if not _free_position(id, point, player_position, navigation):
			continue
		var path: PackedVector2Array = navigation.find_path(actor.ground_position, point, true, Navigation.NPC_RADIUS)
		if not path.is_empty():
			state.route = path
			return
	state.wait = random.randf_range(1.0, 2.5)


func _move(id: String, from: Vector2, motion: Vector2, player_position: Vector2, navigation: Navigation) -> Vector2:
	var result: Vector2 = from
	var steps: int = maxi(1, ceili(motion.length() / 5.0))
	var step: Vector2 = motion / float(steps)
	for _index in range(steps):
		if _free_position(id, result + step, player_position, navigation):
			result += step
		else:
			if _free_position(id, result + Vector2(step.x, 0), player_position, navigation):
				result += Vector2(step.x, 0)
			if _free_position(id, result + Vector2(0, step.y), player_position, navigation):
				result += Vector2(0, step.y)
	return result


func _free_position(id: String, point: Vector2, player_position: Vector2, navigation: Navigation) -> bool:
	if not navigation.is_floor_walkable(point, Navigation.NPC_RADIUS):
		return false
	if point.distance_to(player_position) < Navigation.NPC_RADIUS + Navigation.PLAYER_RADIUS + 4.0:
		return false
	for other_id: String in actors:
		if other_id != id and point.distance_to(actors[other_id].ground_position) < Navigation.NPC_RADIUS * 2.0 + 4.0:
			return false
	return true


func _speak(id: String, text: String, gesture: String) -> void:
	var state: Dictionary = states[id]
	state.route = PackedVector2Array()
	state.wait = random.randf_range(2.5, 4.5)
	state.speech_timer = random.randf_range(13.0, 25.0)
	actors[id].set_motion(Vector2.ZERO)
	actors[id].play_gesture(gesture, 1.7)
	_room_chatter_cooldown = 5.2
	chatter_count += 1
	chatter.emit(id, text)


func snapshot() -> Dictionary:
	var result: Dictionary = {}
	for id: String in actors:
		var actor = actors[id]
		result[id] = {"x": actor.ground_position.x, "y": actor.ground_position.y,
			"moving": actor.moving, "conversing": actor.conversing, "facing": actor.facing, "animation": actor.current_direction,
			"frame": actor.current_frame, "walked": moved_distance.get(id, 0.0)}
	return result