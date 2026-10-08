extends SceneTree
## Isolated contract suite: no main scene, real 3D floor/ledge collisions, mock game.
## Run with --headless --fixed-fps 60 --script res://tests/test_enemy_contract.gd.

const EnemyScript = preload("res://scripts/enemy.gd")
const Catalog = preload("res://scripts/catalog.gd")
const DT: float = 1.0 / 60.0


class TestHero extends Node3D:
	var health: float = 10000.0
	var dead: bool = false


class TestEffects extends Node:
	var bursts: Array[Dictionary] = []
	var slashes: Array[Dictionary] = []

	func burst(pos: Vector3, tint: Color, count: int) -> void:
		bursts.append({"pos": pos, "tint": tint, "count": count})

	func slash(pos: Vector3, facing: int, tint: Color, radius: float) -> void:
		slashes.append({"pos": pos, "facing": facing, "tint": tint, "radius": radius})


class TestAudio extends Node:
	var sounds: Array[String] = []

	func play_sfx(sound: String, _pitch: float = 1.0) -> void:
		sounds.append(sound)


class TestGame extends Node3D:
	var state: String = "playing"
	var boss_started: bool = false
	var hero: TestHero = TestHero.new()
	var effects: TestEffects = TestEffects.new()
	var audio: TestAudio = TestAudio.new()
	var enemies: Array[Node] = []
	var active_enemy: Node
	var floors: Array[StaticBody3D] = []
	var calls: Array[Dictionary] = []
	var samples: Array[Dictionary] = []
	var defeated: int = 0
	var death_snapshot: Dictionary = {}
	var reject_hits: bool = false
	var parry_contact: bool = false
	var kill_on_projectile: bool = false
	var kill_on_wave: bool = false
	var clock: float = 0.0

	func _ready() -> void:
		add_child(hero)
		add_child(effects)
		add_child(audio)

	func _physics_process(delta: float) -> void:
		if state == "playing":
			clock += delta

	func snapshot(owner: Node, event: String) -> Dictionary:
		var sprite: Sprite3D = owner.get("sprite") as Sprite3D
		var pos: Vector3 = owner.get("global_position")
		return {"event": event, "time": clock, "state": str(owner.get("state")),
			"attack": str(owner.get("attack_name")), "frame": sprite.frame,
			"pos": pos, "floor": (owner as CharacterBody3D).is_on_floor(),
			"tell": float(owner.get("telegraph_strength"))}

	func hurt_player(damage: float, from_x: float, knockback: float = 5.0) -> bool:
		var record: Dictionary = snapshot(active_enemy, "hit")
		record.merge({"damage": damage, "from_x": from_x, "knockback": knockback})
		calls.append(record)
		if parry_contact:
			active_enemy.call("take_damage", 4.0, hero.global_position.x, 4.0)
			return false
		if reject_hits:
			return false
		hero.health -= damage
		return true

	func spawn_projectile(origin: Vector3, direction: Vector3, projectile_kind: String,
			damage: float, speed: float, owner: Node, tint: Color) -> void:
		var record: Dictionary = snapshot(owner, "projectile")
		record.merge({"origin": origin, "direction": direction, "kind": projectile_kind,
			"damage": damage, "speed": speed, "tint": tint})
		calls.append(record)
		if kill_on_projectile:
			owner.call("take_damage", 10000.0, hero.global_position.x)

	func spawn_wave(x: float, direction: float, damage: float, owner: Node) -> void:
		var record: Dictionary = snapshot(owner, "wave")
		record.merge({"x": x, "direction": direction, "damage": damage})
		calls.append(record)
		if kill_on_wave:
			owner.call("take_damage", 10000.0, hero.global_position.x)

	func shake(_strength: float) -> void:
		pass

	func on_enemy_defeated(enemy: Node) -> void:
		defeated += 1
		death_snapshot = {"dead": bool(enemy.get("dead")), "state": str(enemy.get("state")),
			"layer": int(enemy.get("collision_layer")), "mask": int(enemy.get("collision_mask")),
			"burst_count": effects.bursts.size(), "queued": enemy.is_queued_for_deletion()}


var _world: TestGame
var _checks: int = 0
var _failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	await _test_catalog_and_frames()
	await _test_single_contact_and_interrupts()
	await _test_projectiles_and_target_locks()
	await _test_pause_and_dormancy()
	await _test_death()
	await _test_boss()
	await _test_ledges()
	await _test_coarse_tick()
	if is_instance_valid(_world):
		_world.queue_free()
		await process_frame
	print("ENEMY CONTRACT: %d checks, %d failures" % [_checks, _failures.size()])
	for failure: String in _failures:
		printerr("FAIL: " + failure)
	quit(0 if _failures.is_empty() else 1)


func _check(condition: bool, label: String, actual: Variant = "") -> void:
	_checks += 1
	if not condition:
		var text: String = "%s (actual: %s)" % [label, str(actual)]
		_failures.append(text)
		printerr("FAIL: " + text)


func _floor(left: float, right: float) -> void:
	var body: StaticBody3D = StaticBody3D.new()
	var collider: CollisionShape3D = CollisionShape3D.new()
	var shape: BoxShape3D = BoxShape3D.new()
	shape.size = Vector3(right - left, 1, 8)
	collider.shape = shape
	body.add_child(collider)
	body.position = Vector3((left + right) * 0.5, -0.5, 0)
	body.collision_layer = 1
	body.collision_mask = 0
	_world.add_child(body)
	_world.floors.append(body)


func _reset(kind: String, x: float = 10.0, hero_x: float = 11.2) -> Node3D:
	if is_instance_valid(_world):
		_world.queue_free()
		await process_frame
	_world = TestGame.new()
	root.add_child(_world)
	_world.boss_started = kind == "boss"
	_world.hero.global_position = Vector3(hero_x, 0.02, 0)
	_floor(-20, 39)
	_floor(42, 82)
	_floor(85, 121)
	_floor(125, 210)
	var enemy = EnemyScript.new()
	_world.add_child(enemy)
	_world.active_enemy = enemy
	_world.enemies.append(enemy)
	enemy.configure(_world, kind, Vector3(x, 0.06, 0))
	enemy.ai_enabled = false
	await _frames(4)
	return enemy


func _frames(count: int) -> void:
	for index in range(count):
		await physics_frame
		await process_frame
		if is_instance_valid(_world.active_enemy):
			_world.samples.append(_world.snapshot(_world.active_enemy, "sample"))


func _attack_done(enemy: Node, limit: int = 720) -> void:
	for index in range(limit):
		await _frames(1)
		if not is_instance_valid(enemy):
			_check(false, "attack owner unexpectedly freed")
			return
		if str(enemy.get("state")) == "idle" and str(enemy.get("attack_name")).is_empty():
			return
	_check(false, "attack completed within bounded physics ticks", enemy.get("state"))


func _calls(event: String) -> Array[Dictionary]:
	var selected: Array[Dictionary] = []
	for record: Dictionary in _world.calls:
		if str(record["event"]) == event:
			selected.append(record)
	return selected


func _validate_frames(label: String) -> void:
	var valid_events: bool = true
	for record: Dictionary in _world.calls:
		valid_events = valid_events and str(record["state"]) == "active" and int(record["frame"]) in [14, 15]
	_check(valid_events, label + ": all damage/releases occur in active poses", _world.calls)
	var valid_poses: bool = true
	for record: Dictionary in _world.samples:
		var frame: int = int(record["frame"])
		match str(record["state"]):
			"windup", "transition": valid_poses = valid_poses and frame in [12, 13]
			"active": valid_poses = valid_poses and frame in [14, 15]
			"recovery": valid_poses = valid_poses and frame in [16, 17]
			"casting": valid_poses = valid_poses and frame == 15
			"airborne": valid_poses = valid_poses and frame == 13
			"hurt": valid_poses = valid_poses and frame in [18, 19, 20]
			"dead": valid_poses = valid_poses and frame in [21, 22, 23]
	_check(valid_poses, label + ": atlas ranges are paced by combat stage")


func _validate_tells(enemy: Node, label: String) -> void:
	var valid: bool = true
	var stages: Array = enemy.get("_stages")
	for stage: Dictionary in stages:
		if str(stage["state"]) == "windup":
			valid = valid and float(stage["duration"]) >= 0.45
	_check(valid, label + ": every fresh tell is at least 450 ms", stages)


func _test_catalog_and_frames() -> void:
	var expected: Dictionary = {"briar": 1, "sentinel": 2, "lancer": 1, "arbalist": 1,
		"cantor": 3, "gargoyle": 1, "warden": 1, "boss": 1}
	_check(Catalog.ENEMIES.size() == 8, "exactly eight enemy kinds")
	for enemy_kind: String in Catalog.ENEMIES:
		var x: float = 174.0 if enemy_kind == "boss" else 10.0
		var enemy = await _reset(enemy_kind, x, x + 1.2)
		var stats: Dictionary = Catalog.ENEMIES[enemy_kind]
		_check(is_equal_approx(enemy.max_health, float(stats["hp"])), enemy_kind + ": catalog HP", enemy.max_health)
		_check(is_equal_approx(enemy.pixel_scale, float(stats["pixel_size"])), enemy_kind + ": catalog sprite scale")
		_check(is_equal_approx(enemy.body_height, float(stats["height"])), enemy_kind + ": catalog body height")
		var start_time: float = _world.clock
		enemy.start_attack()
		_validate_tells(enemy, enemy_kind)
		_check(enemy.state == "windup" and enemy.sprite.frame == 12, enemy_kind + ": anticipation begins at frame 12")
		await _frames(24)
		_check(enemy.attack_events_count == 0 and _world.calls.is_empty(), enemy_kind + ": no damage in first 400 ms")
		await _attack_done(enemy)
		_check(enemy.attack_events_count == int(expected[enemy_kind]), enemy_kind + ": exact event count", enemy.attack_events_count)
		_validate_frames(enemy_kind)
		if enemy_kind == "arbalist" or enemy_kind == "cantor":
			_check(_calls("hit").is_empty(), enemy_kind + ": no hidden melee on a spell/bolt")
		else:
			_check(_calls("hit").size() == int(expected[enemy_kind]), enemy_kind + ": one contact per swing", _calls("hit"))
		if enemy_kind == "warden":
			_check(_calls("wave").size() == 2, "warden: exactly two ground waves")
		print("KIND %s: events=%d duration=%.3f s" % [enemy_kind, enemy.attack_events_count, _world.clock - start_time])
		var before: int = _world.calls.size()
		await _frames(30)
		_check(_world.calls.size() == before, enemy_kind + ": idle/recovery does not leak damage")


func _test_single_contact_and_interrupts() -> void:
	var enemy = await _reset("sentinel")
	_world.reject_hits = true
	enemy.start_attack()
	await _attack_done(enemy)
	_check(_calls("hit").size() == 2 and _world.hero.health == 10000.0,
		"blocked swings are spent rather than retried", _calls("hit").size())
	for enemy_kind: String in Catalog.ENEMIES:
		if enemy_kind == "boss":
			continue
		enemy = await _reset(enemy_kind)
		enemy.start_attack()
		await _frames(12)
		_check(enemy.take_damage(1.0, 8.0), enemy_kind + ": accepts ordinary hit")
		_check(enemy.state == "hurt" and enemy.attack_name.is_empty(), enemy_kind + ": stagger cancels tell")
		await _frames(150)
		_check(enemy.attack_events_count == 0 and _world.calls.is_empty(), enemy_kind + ": interrupted attack cannot fire later")
		_validate_frames(enemy_kind + " stagger")
	for enemy_kind: String in ["sentinel", "warden"]:
		enemy = await _reset(enemy_kind)
		_world.parry_contact = true
		enemy.start_attack()
		await _frames(180)
		_check(enemy.attack_events_count == 1 and _calls("hit").size() == 1,
			enemy_kind + ": reentrant parry stops subsequent combo", enemy.attack_events_count)
		_check(_calls("wave").is_empty(), enemy_kind + ": parry cancels pending waves")
	enemy = await _reset("lancer", 10, 12)
	_world.hero.global_position.y = 2.0
	enemy.start_attack()
	await _attack_done(enemy)
	_check(_calls("hit").is_empty(), "lancer: jump clears the narrow thrust hitbox")
	enemy = await _reset("sentinel")
	enemy.start_attack()
	_world.hero.global_position.x = 7.5
	await _frames(45)
	_check(_calls("hit").is_empty(), "sentinel: locked swing cannot hit behind its facing")


func _test_projectiles_and_target_locks() -> void:
	var enemy = await _reset("arbalist", 10, 16)
	enemy.start_attack()
	var locked: Vector3 = enemy.get("_locked_target")
	_check(enemy.get("_aim_line").visible, "arbalist: visible aim line during tell")
	await _frames(30)
	_world.hero.global_position = Vector3(8, 3, 0)
	await _attack_done(enemy)
	var bolts: Array[Dictionary] = _calls("projectile")
	_check(bolts.size() == 1, "arbalist: one bolt")
	if bolts.size() == 1:
		var origin: Vector3 = bolts[0]["origin"]
		var direction: Vector3 = bolts[0]["direction"]
		_check(direction.is_equal_approx((locked - origin).normalized()), "arbalist: aim does not track after lock", direction)
		_check(float(bolts[0]["speed"]) >= 18.0, "arbalist: fast projectile", bolts[0]["speed"])
	_check(enemy.global_position.x < 10.0, "arbalist: actual recoil displacement", enemy.global_position)
	enemy = await _reset("cantor", 10, 16)
	enemy.start_attack()
	await _attack_done(enemy)
	var orbs: Array[Dictionary] = _calls("projectile")
	_check(orbs.size() == 3, "cantor: exactly three orbs")
	if orbs.size() == 3:
		var d0: Vector3 = orbs[0]["direction"]
		var d1: Vector3 = orbs[1]["direction"]
		var d2: Vector3 = orbs[2]["direction"]
		_check(d0.angle_to(d1) > 0.20 and d1.angle_to(d2) > 0.20, "cantor: spatial fan", [d0, d1, d2])
		_check(float(orbs[0]["speed"]) < float(orbs[1]["speed"]) and float(orbs[1]["speed"]) < float(orbs[2]["speed"]),
			"cantor: staggered speeds")
		_check(float(orbs[1]["time"]) - float(orbs[0]["time"]) >= 0.23 and float(orbs[2]["time"]) - float(orbs[1]["time"]) >= 0.23,
			"cantor: staggered release times", [orbs[0]["time"], orbs[1]["time"], orbs[2]["time"]])
	enemy = await _reset("gargoyle", 10, 14)
	var home: Vector3 = enemy.global_position
	enemy.start_attack()
	locked = enemy.get("_locked_target")
	_check(enemy.get("_target_marker").visible, "gargoyle: marked locked target")
	await _frames(30)
	_world.hero.global_position.x = 7.0
	await _attack_done(enemy)
	var nearest: float = INF
	for sample: Dictionary in _world.samples:
		if str(sample["state"]) == "active":
			var pos: Vector3 = sample["pos"]
			nearest = minf(nearest, pos.distance_to(locked))
	_check(nearest < 0.30, "gargoyle: dive reaches stored location, not moving hero", nearest)
	_check(_calls("hit").is_empty(), "gargoyle: moving away dodges locked dive")
	_check(enemy.global_position.distance_to(home) < 0.15, "gargoyle: returns to pre-dive hover", enemy.global_position)
	_check(enemy.animation_start == 6 and enemy.animation_count == 6, "gargoyle: animated wing poses, not idle sprite translation")


func _test_pause_and_dormancy() -> void:
	var enemy = await _reset("cantor", 10, 15)
	enemy.start_attack()
	await _frames(30)
	_world.state = "paused"
	var position_before: Vector3 = enemy.global_position
	var elapsed_before: float = enemy.get("_stage_elapsed")
	var animation_before: float = enemy.animation_clock
	await _frames(90)
	_check(enemy.global_position == position_before and float(enemy.get("_stage_elapsed")) == elapsed_before,
		"pause freezes physics position and attack clock")
	_check(enemy.animation_clock == animation_before and _world.calls.is_empty(), "pause freezes base animation and spell releases")
	_check(not enemy.take_damage(3.0, 9.0), "paused enemy refuses stray damage")
	_world.state = "playing"
	await _attack_done(enemy)
	_check(_calls("projectile").size() == 3, "resume continues exactly the pending three-orb cast")
	enemy = await _reset("cantor", 10, 15)
	enemy.start_attack()
	await _frames(20)
	_world.hero.global_position.x = 50
	await _frames(150)
	_check(enemy.state == "dormant" and _world.calls.is_empty(), "distance greater than 20 cancels attack and sleeps")
	_world.hero.global_position.x = 15
	await _frames(2)
	_check(enemy.state == "idle" and enemy.attack_name.is_empty(), "waking never resumes stale active damage")
	enemy.start_attack()
	await _frames(24)
	_check(enemy.attack_events_count == 0, "waking requires a new full tell")
	var old_hero: Node3D = _world.hero
	_world.hero = null
	old_hero.queue_free()
	await _frames(3)
	_check(enemy.state == "dormant", "missing/freed hero safely cancels attacks")
	enemy = await _reset("boss", 175, 159)
	_world.boss_started = false
	await _frames(2)
	enemy.start_attack("bell")
	_check(enemy.state == "dormant" and enemy.attack_events_count == 0, "boss remains inactive before arena trigger")
	_check(not enemy.take_damage(1.0, 159), "inactive boss cannot be damaged through the gate")
	_world.hero.global_position.x = 160.0
	await _frames(2)
	_check(enemy.state == "dormant", "boss threshold is strictly greater than x=160")
	_world.hero.global_position.x = 160.1
	await _frames(2)
	_check(enemy.state == "idle", "hero crossing x=160 activates boss")
	_world.hero.global_position.x = 159
	_world.boss_started = true
	await _frames(2)
	enemy.start_attack("sweep")
	_check(enemy.state == "windup", "boss_started independently enables boss")


func _test_death() -> void:
	for enemy_kind: String in Catalog.ENEMIES:
		var x: float = 174.0 if enemy_kind == "boss" else 10.0
		var enemy = await _reset(enemy_kind, x, x + 1.2)
		enemy.start_attack()
		await _frames(10)
		_check(enemy.take_damage(10000.0, x - 1.0), enemy_kind + ": lethal hit accepted")
		_check(_world.defeated == 1 and enemy.dead and enemy.state == "dead", enemy_kind + ": death reported immediately once")
		_check(enemy.collision_layer == 0 and enemy.collision_mask == 0, enemy_kind + ": death immediately disables collision")
		_check(_world.death_snapshot["burst_count"] > 0 and not _world.death_snapshot["queued"], enemy_kind + ": effects precede disposal")
		_check(not _world.effects.bursts.is_empty() and _world.effects.bursts.back()["tint"] == Color(1.0, 0.76, 0.35),
			enemy_kind + ": defeat dissolves into golden light, not species-colored particles")
		_check(enemy.sprite.frame == 21 and enemy.animation_name == "death", enemy_kind + ": death starts at dissolve pose")
		_check(not enemy.take_damage(1.0, x - 1.0), enemy_kind + ": second lethal hit has no effects")
		enemy.start_attack()
		await _frames(32)
		_check(is_instance_valid(enemy) and enemy.sprite.modulate.a < 1.0, enemy_kind + ": visible fade before removal")
		_check(enemy.attack_events_count == 0 and _world.calls.is_empty(), enemy_kind + ": death cancels queued damage")
		await _frames(26)
		_check(not is_instance_valid(enemy) and _world.defeated == 1, enemy_kind + ": frees after physics-driven fade")
	var enemy = await _reset("cantor", 10, 16)
	_world.kill_on_projectile = true
	enemy.start_attack()
	await _frames(160)
	_check(_calls("projectile").size() == 1 and _world.defeated == 1,
		"death during first release cancels remaining two orbs", _world.calls)
	enemy = await _reset("warden")
	_world.kill_on_wave = true
	enemy.start_attack()
	await _frames(150)
	_check(_calls("wave").size() == 1 and _world.defeated == 1,
		"reentrant death between wave emissions cancels second wave")
	enemy = await _reset("briar")
	enemy.take_damage(10000.0, 8)
	await _frames(20)
	_world.state = "paused"
	var fade_clock: float = enemy.get("_death_elapsed")
	await _frames(90)
	_check(is_instance_valid(enemy) and float(enemy.get("_death_elapsed")) == fade_clock, "pause also freezes death fade")
	_world.state = "playing"
	await _frames(40)
	_check(not is_instance_valid(enemy), "death fade completes after resume")


func _test_boss() -> void:
	var enemy = await _reset("boss", 174, 177)
	_check(enemy.max_health == 760.0, "boss has exactly catalog HP 760")
	for expected: String in ["sweep", "jump_slam", "bell"]:
		var count_before: int = enemy.attack_events_count
		enemy.start_attack()
		_check(enemy.attack_name == expected, "boss cycles sweep / jump / bell", enemy.attack_name)
		_validate_tells(enemy, "phase one " + expected)
		if expected == "jump_slam":
			for index in range(120):
				await _frames(1)
				if enemy.state == "airborne" and enemy.global_position.y > 0.5:
					break
			_world.state = "title"
			var pos: Vector3 = enemy.global_position
			var motion: Vector3 = enemy.velocity
			var events: int = enemy.attack_events_count
			await _frames(60)
			_check(enemy.global_position == pos and enemy.velocity == motion and enemy.attack_events_count == events,
				"title freezes airborne boss, including gravity and landing events")
			_world.state = "playing"
		await _attack_done(enemy)
		_check(enemy.attack_events_count - count_before == (3 if expected == "bell" else 1), "phase one " + expected + ": event count")
	var waves: Array[Dictionary] = _calls("wave")
	_check(waves.size() == 8, "phase one: landing wave pair plus three bell pairs", waves.size())
	var grounded: bool = true
	var jump_height: float = 0.0
	for wave: Dictionary in waves:
		grounded = grounded and bool(wave["floor"])
	for sample: Dictionary in _world.samples:
		var pos: Vector3 = sample["pos"]
		jump_height = maxf(jump_height, pos.y)
	_check(grounded, "boss ground waves only emit after real floor contact", waves)
	_check(jump_height > 1.1, "boss jump has a physical airborne arc", jump_height)
	_validate_frames("phase one boss")
	enemy = await _reset("boss", 174, 177)
	enemy.start_attack("bell")
	await _frames(12)
	var attack_clock: float = enemy.get("_stage_elapsed")
	enemy.take_damage(380.0, 171, 100)
	_check(enemy.phase == 1 and enemy.state == "windup" and enemy.attack_name == "bell",
		"boss resists stagger; exactly half HP is still phase one")
	_check(float(enemy.get("_stage_elapsed")) == attack_clock and enemy.velocity.x == 0.0,
		"boss hit preserves attack clock and rejects knockback")
	enemy.take_damage(1.0, 171)
	_check(enemy.phase == 2 and enemy.state == "transition" and enemy.attack_name.is_empty(),
		"below half HP starts one explicit phase transition")
	await _frames(72)
	_check(enemy.state == "transition" and _world.calls.is_empty(), "phase transition is readable and harmless")
	await _frames(6)
	_check(enemy.state == "idle", "phase transition finishes without async timer")
	for attack: String in ["sweep", "jump_slam", "bell"]:
		var before: int = enemy.attack_events_count
		enemy.start_attack(attack)
		_validate_tells(enemy, "phase two " + attack)
		var stages: Array = enemy.get("_stages")
		_check(float(stages[0]["duration"]) < 1.0, "phase two " + attack + ": shorter first tell", stages[0])
		await _attack_done(enemy)
		_check(enemy.attack_events_count - before == (2 if attack == "jump_slam" else 3),
			"phase two " + attack + ": additional segments / exactly three bells", enemy.attack_events_count - before)
	_check(_world.enemies.size() == 1, "boss never summons a ninth enemy kind")
	_validate_frames("phase two boss")
	for bounds: Vector2 in [Vector2(184.8, 199), Vector2(161.2, 147)]:
		enemy = await _reset("boss", bounds.x, bounds.y)
		enemy.ai_enabled = true
		await _frames(150)
		var inside: bool = true
		for sample: Dictionary in _world.samples:
			var pos: Vector3 = sample["pos"]
			inside = inside and pos.x >= 161.0 and pos.x <= 185.0
		_check(inside, "boss locomotion stays within x=161..185", enemy.global_position)


func _test_ledges() -> void:
	for enemy_kind: String in ["briar", "sentinel", "lancer", "arbalist", "cantor", "warden"]:
		var enemy = await _reset(enemy_kind, 38.2, 43)
		enemy.start_attack()
		await _attack_done(enemy)
		enemy.ai_enabled = true
		await _frames(120)
		var safe: bool = true
		for sample: Dictionary in _world.samples:
			var pos: Vector3 = sample["pos"]
			safe = safe and pos.x < 39.0 and pos.y > -0.15
		_check(safe, enemy_kind + ": attacks and pursuit cannot leave authored ledge", enemy.global_position)
		if not enemy.dead:
			enemy.take_damage(1.0, 35.0, 18.0)
			await _frames(25)
			_check(enemy.global_position.x < 39.0 and enemy.global_position.y > -0.15,
				enemy_kind + ": knockback also obeys ledge guard", enemy.global_position)
	var enemy = await _reset("briar", 11.3, 15)
	for body: StaticBody3D in _world.floors:
		body.queue_free()
	_world.floors.clear()
	_floor(-20, 12)
	await _frames(3)
	enemy.start_attack()
	await _attack_done(enemy)
	_check(enemy.global_position.x < 12.0 and enemy.global_position.y > -0.15,
		"ray check protects an arbitrary ledge not listed in Catalog.GAPS", enemy.global_position)
	enemy = await _reset("gargoyle", 38, 43)
	enemy.start_attack()
	await _attack_done(enemy)
	var crossed: bool = false
	for sample: Dictionary in _world.samples:
		var pos: Vector3 = sample["pos"]
		crossed = crossed or (pos.x > 39.0 and pos.x < 42.0)
	_check(crossed, "flying gargoyle is exempt from ground ledge restriction")
	_check(absf(enemy.global_position.x - 38.0) < 0.2, "gargoyle flies back across the gap")


func _test_coarse_tick() -> void:
	var enemy = await _reset("sentinel")
	enemy.set_physics_process(false)
	enemy.set_process(false)
	enemy.start_attack()
	enemy.call("_physics_process", 3.0)
	_check(enemy.state == "active" and enemy.sprite.frame == 14 and enemy.attack_events_count == 1,
		"long tick cannot consume unseen tell, both cuts and recovery in one call")
	enemy.take_damage(10000.0, 8)
	enemy.call("_physics_process", DT)
	_check(enemy.attack_events_count == 1 and _world.defeated == 1, "coarse-tick death still cancels every pending cut")