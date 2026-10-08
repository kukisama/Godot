extends SceneTree
## Real-renderer visual integration capture, excluded from exports.
const Game = preload("res://scripts/game.gd")
var game: Node3D
var output := "res://qa/screens/"

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(output)
	game = Game.new()
	game.test_mode = true
	root.add_child(game)
	await _frames(50)
	await _capture("01-title")
	var enter := InputEventKey.new()
	enter.keycode = KEY_ENTER
	enter.physical_keycode = KEY_ENTER
	enter.pressed = true
	Input.parse_input_event(enter)
	await _frames(2)
	enter.pressed = false
	Input.parse_input_event(enter)
	await _frames(20)
	if game.state != "playing":
		push_error("Title keyboard start did not enter gameplay")
		quit(1)
		return
	for enemy in game.enemies:
		enemy.ai_enabled = false
	await _place(12.0)
	Input.action_press("move_right")
	await _frames(18)
	await _capture("02-forest-run")
	Input.action_release("move_right")
	await _place(47.0)
	await _capture("03-broken-bridge")
	await _place(98.0)
	await _capture("04-abbey")
	await _place(139.0)
	game.hero.begin_attack(2)
	await _frames(17)
	await _capture("05-finisher")
	await _place(169.5)
	game.boss.start_attack("sweep")
	await _frames(30)
	await _capture("06-boss-windup")
	game.pause_game()
	await _frames(10)
	await _capture("07-pause")
	game.resume_game()
	game._clear_projectiles()
	for enemy in game.enemies:
		enemy.set_physics_process(false)
	game.boss.take_damage(1000.0, game.hero.global_position.x)
	await _place(191.3)
	await _frames(20)
	await _capture("08-victory")
	print("RENDER_CAPTURE_COMPLETE state=%s" % game.state)
	game.queue_free()
	await process_frame
	quit(0)

func _place(x: float) -> void:
	game.hero.global_position = Vector3(x, 0.06, 0)
	game.hero.velocity = Vector3.ZERO
	game.hero._finish_action()
	game._camera_x = x + 2.0
	await _frames(45)

func _frames(count: int) -> void:
	for i in range(count):
		await process_frame

func _capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var result := image.save_png(output + name + ".png")
	if result != OK:
		push_error("Screenshot save failed: " + name)
		quit(1)
	print("RENDERED %s %s" % [name, image.get_size()])