extends CharacterBody3D
## Shared sprite animation and readable combat feedback on a real 3D body.

var game: Node
var kind := ""
var health := 100.0
var max_health := 100.0
var dead := false
var facing := 1
var body_height := 2.0
var sprite: Sprite3D
var visual: Node3D
var tell: MeshInstance3D
var hp_fill: MeshInstance3D
var hp_back: MeshInstance3D
var hit_flash := 0.0
var bar_time := 0.0
var squash := Vector2.ONE
var visual_tilt := 0.0
var animation_name := ""
var animation_finished := false
var animation_frame := 0
var animation_start := 0
var animation_count := 6
var animation_fps := 10.0
var animation_loop := true
var animation_clock := 0.0
var pixel_scale := 0.013
var textures: Dictionary = {}
var telegraph_strength := 0.0
var _visual_time := 0.0

func setup_actor(world: Node, actor_kind: String, hp: float, size_px: float = 0.013, height_units: float = 2.0) -> void:
	game = world
	kind = actor_kind
	health = hp
	max_health = hp
	pixel_scale = size_px
	body_height = height_units
	collision_layer = 2 if actor_kind == "hero" else 4
	collision_mask = 1
	floor_snap_length = 0.18
	var collider := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.34 if actor_kind != "boss" else 0.75
	capsule.height = maxf(height_units, capsule.radius * 2.0)
	collider.shape = capsule
	collider.position.y = capsule.height * 0.5
	add_child(collider)
	visual = Node3D.new()
	add_child(visual)
	sprite = Sprite3D.new()
	sprite.hframes = 6
	sprite.vframes = 4
	sprite.pixel_size = size_px
	sprite.position.y = 104.0 * size_px
	sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	sprite.shaded = false
	sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	sprite.alpha_scissor_threshold = 0.3
	sprite.double_sided = true
	visual.add_child(sprite)
	set_sheet("hero_motion" if actor_kind == "hero" else actor_kind)
	var shadow := MeshInstance3D.new()
	var shadow_mesh := PlaneMesh.new()
	shadow_mesh.size = Vector2(1.15, 0.65) * (1.9 if actor_kind == "boss" else 1.0)
	shadow.mesh = shadow_mesh
	shadow.material_override = flat_material(Color(0.02, 0.04, 0.05, 0.3))
	shadow.position = Vector3(0, 0.035, -0.01)
	shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(shadow)
	tell = MeshInstance3D.new()
	var marker := QuadMesh.new()
	marker.size = Vector2(0.18, 0.18)
	tell.mesh = marker
	tell.material_override = flat_material(Color(1.0, 0.65, 0.2))
	tell.position = Vector3(0, body_height + 0.4, 0.05)
	tell.rotation.z = PI * 0.25
	tell.visible = false
	add_child(tell)
	hp_back = _make_bar(Color(0.05, 0.08, 0.08, 0.8), 0.9)
	hp_fill = _make_bar(Color(0.92, 0.70, 0.40), 0.84)
	hp_fill.position.z += 0.01
	play_animation("idle", 0, 6, 8.0)
	add_to_group("actors")

func _make_bar(color: Color, width: float) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(width, 0.055)
	node.mesh = quad
	node.material_override = flat_material(color)
	node.position = Vector3(0, body_height + 0.16, 0.08)
	node.visible = false
	add_child(node)
	return node

static func flat_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	if color.a < 1.0:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return material

func set_sheet(sheet: String) -> void:
	if not textures.has(sheet):
		var path := "res://assets/sprites/%s.png" % sheet
		if ResourceLoader.exists(path):
			textures[sheet] = load(path)
		else:
			return
	sprite.texture = textures[sheet]

func play_animation(label: String, first: int, count: int = 6, fps: float = 12.0, looped: bool = true, sheet: String = "") -> void:
	if label == animation_name:
		return
	if not sheet.is_empty():
		set_sheet(sheet)
	animation_name = label
	animation_start = first
	animation_count = count
	animation_fps = fps
	animation_loop = looped
	animation_clock = 0.0
	animation_frame = 0
	animation_finished = false
	if sprite:
		sprite.frame = first

func _process(delta: float) -> void:
	if not is_instance_valid(sprite):
		return
	_visual_time += delta
	hit_flash = maxf(0.0, hit_flash - delta)
	bar_time = maxf(0.0, bar_time - delta)
	animation_clock += delta
	var raw_frame := int(animation_clock * animation_fps)
	animation_finished = raw_frame >= animation_count
	animation_frame = raw_frame % animation_count if animation_loop else mini(raw_frame, animation_count - 1)
	sprite.frame = animation_start + animation_frame
	sprite.flip_h = facing < 0
	sprite.modulate = Color(2.0, 1.65, 1.25) if hit_flash > 0.0 else Color.WHITE
	visual.scale = Vector3(squash.x, squash.y, 1.0)
	visual.rotation.z = lerpf(visual.rotation.z, visual_tilt, minf(delta * 15.0, 1.0))
	squash = squash.lerp(Vector2.ONE, minf(delta * 12.0, 1.0))
	tell.visible = telegraph_strength > 0.0 and not dead
	tell.scale = Vector3.ONE * (1.0 + 0.6 * sin(_visual_time * 24.0)) * (0.75 + telegraph_strength)
	hp_back.visible = bar_time > 0.0 and not dead and kind != "hero" and kind != "boss"
	hp_fill.visible = hp_back.visible
	hp_fill.scale.x = maxf(0.001, health / max_health)
	hp_fill.position.x = -0.42 * (1.0 - health / max_health)

func apply_damage(amount: float, from_x: float, force: float = 4.0) -> bool:
	if dead:
		return false
	health = maxf(0.0, health - amount)
	dead = health <= 0.0
	hit_flash = 0.13
	bar_time = 3.5
	var away := signf(global_position.x - from_x)
	if away == 0.0:
		away = -float(facing)
	velocity.x = away * force
	squash = Vector2(1.08, 0.91)
	return true

func is_ahead(point: Vector3, reach: float, vertical: float = 2.1) -> bool:
	var offset := point - global_position
	return absf(offset.x) <= reach and offset.x * facing >= -0.45 and absf(offset.y) < vertical