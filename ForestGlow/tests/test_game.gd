extends SceneTree
## Inject mouse events through the real viewport, not direct collect callbacks.

var game
var failures := 0
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func check(condition: bool, description: String) -> void:
	checks += 1
	if condition:
		print("PASS ", description)
	else:
		failures += 1
		push_error("FAIL " + description)

func click_at(pos: Vector2, button: int = MOUSE_BUTTON_LEFT) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = pos
	motion.global_position = pos
	root.push_input(motion, true)
	var down := InputEventMouseButton.new()
	down.position = pos
	down.global_position = pos
	down.button_index = button
	down.pressed = true
	root.push_input(down, true)
	var up := InputEventMouseButton.new()
	up.position = pos
	up.global_position = pos
	up.button_index = button
	up.pressed = false
	root.push_input(up, true)
	await process_frame

func target(kind: String) -> void:
	game.targets.clear()
	game._spawn_target(0, kind)
	await click_at(game.target_position(game.targets[0]))

func _run() -> void:
	game = load("res://scripts/game.gd").new()
	root.add_child(game)
	await process_frame
	game.test_mode = true
	game.set_process(false)
	check(game.state == "menu", "initial menu")
	check(game.textures.size() == 6 and game.background != null, "generated assets loaded")
	for kind in game.textures:
		var image: Image = game.textures[kind].get_image()
		check(image.get_size() == Vector2i(256, 256) and image.get_pixel(0, 0).a == 0.0, "transparent sliced sprite " + kind)
	await click_at(Vector2(640, 548))
	check(game.state == "playing" and game.score == 0, "start via mouse button")
	await click_at(game.target_position(game.targets[0]), MOUSE_BUTTON_RIGHT)
	check(game.score == 0, "right click ignored")
	await target("amber")
	check(game.score == 1 and game.combo == 1, "amber mouse hit +1")
	await target("blue")
	check(game.score == 3 and game.combo == 2, "blue mouse hit +2")
	await target("star")
	check(game.score == 8 and game.combo == 3, "star mouse hit +5")
	await target("amber")
	await target("amber")
	check(game.score == 12 and game.combo == 5, "five-hit combo bonus +2")
	var before: int = game.score
	await click_at(Vector2(1200, 660))
	check(game.score == before, "empty ground cannot score")
	await click_at(Vector2(1130, 68))
	check(game.muted, "mute via mouse")
	await click_at(Vector2(1035, 68))
	check(game.state == "paused", "pause via mouse")
	var time_before: float = game.remaining
	game._process(5.0)
	check(is_equal_approx(game.remaining, time_before), "pause freezes countdown")
	await click_at(Vector2(492, 337))
	check(game.score == before, "modal blocks gameplay")
	await click_at(Vector2(640, 548))
	check(game.state == "playing", "resume via mouse")
	await target("spore")
	check(is_equal_approx(game.remaining, time_before - 4.0) and game.combo == 0, "spore loses four seconds and combo")
	game.targets.clear()
	game._spawn_target(0, "amber")
	game.combo = 4
	game._update_targets(4.0)
	check(game.targets.is_empty() and game.combo == 0, "expired fruit breaks combo")
	game._spawn_target(0, "spore")
	game.combo = 4
	game._update_targets(4.0)
	check(game.combo == 4, "ignored spore does not break combo")
	game.score = 34
	game.combo = 0
	await target("blue")
	check(game.state == "won" and game.score == 36, "goal opens win screen")
	await click_at(Vector2(640, 548))
	check(game.state == "playing" and game.score == 0 and game.combo == 0 and game.remaining == 45.0, "restart resets all round state")
	game.remaining = 0.1
	game._process(0.2)
	check(game.state == "lost" and game.remaining == 0.0, "timeout opens result screen")
	await click_at(Vector2(640, 617))
	check(game.state == "menu", "return to menu via mouse")
	await click_at(Vector2(640, 548))
	game.remaining = 3.0
	await target("spore")
	check(game.state == "lost" and game.remaining == 0.0, "spore time clamps to zero and ends round")
	await click_at(Vector2(640, 548))
	game.test_mode = false
	game._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	game.test_mode = true
	check(game.state == "paused", "focus loss automatically pauses")
	game.start_round()
	game.targets.clear()
	for slot in range(6):
		game._spawn_target(slot, "amber")
	game._spawn_target()
	check(game.targets.size() == 6, "spawn points never overlap")
	# Drive a full deterministic round using the normal spawn/timer code.
	game.start_round()
	game.rng.seed = 20261008
	var ticks := 0
	while game.state == "playing" and ticks < 500:
		game._process(0.1)
		for item in game.targets.duplicate():
			if game.state == "playing" and item.kind != "spore":
				await click_at(game.target_position(item))
		if game.state == "playing":
			game._update_effects(0.1)
		ticks += 1
	check(game.state == "won", "complete round through normal spawns and mouse input")
	print("GAME_TESTS: ", checks, " checks, ", failures, " failures")
	game.queue_free()
	await process_frame
	quit(1 if failures > 0 else 0)