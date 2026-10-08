extends Node3D
## Call slash ONCE at a committed strike, not every animation frame.
## All sparks, arcs, rings and impact flashes share the same 256-slot pool.
## No timers, tweens, physics bodies, textures or self-spawning particles.

const MAX_EFFECTS: int = 256
const SLASH_LIFETIME: float = 0.205
const SPARK_MIN_LIFETIME: float = 0.30
const SPARK_MAX_LIFETIME: float = 0.70
const ARC_BANDS: Array[Vector3] = [
	Vector3(0.68, 1.02, 0.16),
	Vector3(0.84, 1.00, 0.54),
	Vector3(0.975, 1.015, 0.92),
]

enum Kind { SPARK, SLASH, RING, FLASH }

class EffectSlot extends RefCounted:
	var node: MeshInstance3D
	var material: StandardMaterial3D
	var arc_mesh: ImmediateMesh
	var kind: int = Kind.SPARK
	var age: float = 0.0
	var lifetime: float = 0.5
	var velocity: Vector3 = Vector3.ZERO
	var tint: Color = Color.WHITE
	var base_scale: Vector3 = Vector3.ONE
	var floor_y: float = 0.0
	var bounced: bool = false
	var facing: int = 1


## Optional. With no game assigned the node is usable in an isolated VFX scene.
var game: Node
var active_count: int:
	get:
		return _active.size()
var pooled_count: int:
	get:
		return _active.size() + _free.size()

var _active: Array[EffectSlot] = []
var _free: Array[EffectSlot] = []
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _spark_mesh: QuadMesh
var _ring_mesh: ImmediateMesh
var _flash_mesh: ImmediateMesh


func _init() -> void:
	# Explicitly respect SceneTree pausing even if the game parent is ALWAYS.
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_rng.randomize()


func burst(pos: Vector3, tint: Color, count: int) -> void:
	if count <= 0 or not _valid_request(pos, tint) or not _can_emit():
		return
	_ensure_meshes()
	# Recycle a low-priority spark if necessary to retain the contact accent.
	var flash: EffectSlot = _acquire(Kind.FLASH, pos, tint, 0.105, true)
	if flash != null:
		flash.node.mesh = _flash_mesh
		flash.base_scale = Vector3.ONE * 0.27
		flash.node.scale = flash.base_scale
		flash.node.rotation.z = _rng.randf_range(-0.4, 0.4)
	# A hostile/accidental count cannot cause an unbounded allocation or loop.
	var available: int = mini(clampi(count, 0, MAX_EFFECTS), MAX_EFFECTS - active_count)
	for index: int in range(available):
		var life: float = _rng.randf_range(SPARK_MIN_LIFETIME, SPARK_MAX_LIFETIME)
		var spark: EffectSlot = _acquire(Kind.SPARK, pos, tint, life)
		if spark == null:
			break
		spark.node.mesh = _spark_mesh
		var angle: float = _rng.randf_range(-0.35, PI + 0.35)
		var speed: float = _rng.randf_range(1.8, 5.2)
		spark.velocity = Vector3(cos(angle) * speed, sin(angle) * speed + 0.5,
			_rng.randf_range(-0.28, 0.45))
		spark.base_scale = Vector3(_rng.randf_range(0.075, 0.17),
			_rng.randf_range(0.018, 0.035), 1.0)
		spark.floor_y = minf(pos.y - 0.035, 0.035)
		spark.node.scale = spark.base_scale
		spark.node.rotation.z = atan2(spark.velocity.y, spark.velocity.x)


func slash(pos: Vector3, facing: int, tint: Color, radius: float) -> void:
	if not _valid_request(pos, tint) or not is_finite(radius) or radius <= 0.0 or not _can_emit():
		return
	var arc: EffectSlot = _acquire(Kind.SLASH, pos, tint, SLASH_LIFETIME, true)
	if arc == null:
		return
	if arc.arc_mesh == null:
		arc.arc_mesh = ImmediateMesh.new()
	arc.node.mesh = arc.arc_mesh
	arc.facing = -1 if facing < 0 else 1
	arc.base_scale = Vector3.ONE * clampf(radius, 0.08, 6.0)
	arc.node.scale = arc.base_scale
	_draw_slash(arc, 0.0)


func ring(pos: Vector3, tint: Color, radius: float = 1.0) -> void:
	if not _valid_request(pos, tint) or not is_finite(radius) or radius <= 0.0 or not _can_emit():
		return
	_ensure_meshes()
	var wave: EffectSlot = _acquire(Kind.RING, pos + Vector3(0, 0.035, 0), tint, 0.42, true)
	if wave == null:
		return
	wave.node.mesh = _ring_mesh
	wave.base_scale = Vector3.ONE * clampf(radius, 0.08, 6.0)
	wave.node.scale = wave.base_scale * 0.25


func clear() -> void:
	for index: int in range(_active.size() - 1, -1, -1):
		_release(index)


func _process(delta: float) -> void:
	if not is_finite(delta) or delta <= 0.0:
		return
	if is_instance_valid(game):
		var state: String = str(game.get("state"))
		if state == "title" or state == "victory":
			clear()
			return
		if state != "playing" and state != "dead":
			return
	for index: int in range(_active.size() - 1, -1, -1):
		var slot: EffectSlot = _active[index]
		slot.age += delta
		if slot.age >= slot.lifetime:
			_release(index)
			continue
		var progress: float = slot.age / slot.lifetime
		var opacity: float = 1.0 - smoothstep(0.10, 1.0, progress)
		match slot.kind:
			Kind.SPARK:
				# Integrate short substeps so a long frame does not tunnel a spark.
				var remaining: float = delta
				while remaining > 0.00001:
					var step: float = minf(remaining, 1.0 / 60.0)
					slot.velocity.y -= 8.0 * step
					slot.velocity *= exp(-1.3 * step)
					slot.node.position += slot.velocity * step
					if slot.node.position.y <= slot.floor_y and slot.velocity.y < 0.0:
						slot.node.position.y = slot.floor_y
						slot.velocity.y = -slot.velocity.y * (0.22 if not slot.bounced else 0.0)
						slot.velocity.x *= 0.55
						slot.bounced = true
					remaining -= step
				slot.node.rotation.z = atan2(slot.velocity.y, slot.velocity.x)
				slot.node.scale = slot.base_scale * lerpf(1.0, 0.25, progress)
			Kind.SLASH:
				_draw_slash(slot, progress)
				opacity = 1.0 - smoothstep(0.35, 1.0, progress)
			Kind.RING:
				var expansion: float = lerpf(0.25, 1.0, 1.0 - pow(1.0 - progress, 3.0))
				slot.node.scale = slot.base_scale * expansion
				opacity *= 0.65
			Kind.FLASH:
				slot.node.scale = slot.base_scale * lerpf(1.0, 1.7, progress)
				opacity = pow(1.0 - progress, 2.0)
		slot.material.albedo_color = Color(slot.tint, slot.tint.a * opacity)


func _can_emit() -> bool:
	if is_inside_tree() and get_tree().paused:
		return false
	if not is_instance_valid(game):
		return true
	var state: String = str(game.get("state"))
	return state == "playing" or state == "dead"


func _valid_request(pos: Vector3, tint: Color) -> bool:
	return pos.is_finite() and is_finite(tint.r) and is_finite(tint.g) \
		and is_finite(tint.b) and is_finite(tint.a) and tint.a > 0.0


func _acquire(kind: int, pos: Vector3, tint: Color, lifetime: float,
		priority: bool = false) -> EffectSlot:
	if active_count >= MAX_EFFECTS:
		if not priority:
			return null
		var victim: int = 0
		for index: int in range(_active.size()):
			if _active[index].kind == Kind.SPARK:
				victim = index
				break
		_release(victim)
	var slot: EffectSlot
	if not _free.is_empty():
		slot = _free.pop_back()
	else:
		slot = EffectSlot.new()
		slot.node = MeshInstance3D.new()
		slot.node.name = "PooledEffect%d" % pooled_count
		slot.node.top_level = true
		slot.node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		slot.material = StandardMaterial3D.new()
		slot.material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		slot.material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		slot.material.cull_mode = BaseMaterial3D.CULL_DISABLED
		slot.material.vertex_color_use_as_albedo = true
		slot.material.disable_fog = true
		# Keep normal depth testing: effects never shine through architecture.
		slot.node.material_override = slot.material
		add_child(slot.node)
		slot.node.top_level = true
	slot.kind = kind
	slot.age = 0.0
	slot.lifetime = lifetime
	slot.tint = Color(clampf(tint.r, 0.0, 1.0), clampf(tint.g, 0.0, 1.0),
		clampf(tint.b, 0.0, 1.0), clampf(tint.a, 0.0, 1.0))
	slot.velocity = Vector3.ZERO
	slot.base_scale = Vector3.ONE
	slot.bounced = false
	slot.facing = 1
	slot.node.transform = Transform3D(Basis.IDENTITY, pos)
	slot.node.visible = true
	slot.material.albedo_color = slot.tint
	_active.append(slot)
	return slot


func _release(index: int) -> void:
	var slot: EffectSlot = _active[index]
	slot.node.visible = false
	slot.node.mesh = null
	if slot.arc_mesh != null:
		slot.arc_mesh.clear_surfaces()
	_active.remove_at(index)
	_free.append(slot)


func _ensure_meshes() -> void:
	if _spark_mesh != null:
		return
	_spark_mesh = QuadMesh.new()
	_spark_mesh.size = Vector2.ONE
	_ring_mesh = ImmediateMesh.new()
	_ring_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for segment: int in range(48):
		var a: float = TAU * float(segment) / 48.0
		var b: float = TAU * float(segment + 1) / 48.0
		var outer_a: Vector3 = Vector3(cos(a), 0, sin(a))
		var outer_b: Vector3 = Vector3(cos(b), 0, sin(b))
		_quad(_ring_mesh, outer_a, outer_b, outer_b * 0.965, outer_a * 0.965,
			Color.WHITE, Color.WHITE)
	_ring_mesh.surface_end()
	_flash_mesh = ImmediateMesh.new()
	_flash_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for point: int in range(4):
		var angle: float = float(point) * PI * 0.5
		var tip: Vector3 = Vector3(cos(angle), sin(angle), 0)
		var side: Vector3 = Vector3(-sin(angle), cos(angle), 0) * 0.17
		_flash_mesh.surface_set_color(Color(1, 1, 1, 0))
		_flash_mesh.surface_add_vertex(tip)
		_flash_mesh.surface_set_color(Color.WHITE)
		_flash_mesh.surface_add_vertex(side)
		_flash_mesh.surface_add_vertex(-side)
	_flash_mesh.surface_end()


func _draw_slash(slot: EffectSlot, progress: float) -> void:
	var mesh: ImmediateMesh = slot.arc_mesh
	mesh.clear_surfaces()
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	# The leading edge travels top-to-bottom, mirrored for a leftward strike.
	# Every vertex stays in the forward half-plane; no full-circle screen wash.
	var leading: float = lerpf(1.15, -1.30, smoothstep(0.0, 0.78, progress))
	var trailing: float = minf(1.40, leading + lerpf(0.26, 1.85,
		smoothstep(0.0, 0.25, progress)))
	for layer_index: int in range(ARC_BANDS.size()):
		var band: Vector3 = ARC_BANDS[layer_index]
		var depth: float = 0.025 + float(layer_index) * 0.008
		for segment: int in range(20):
			var u: float = float(segment) / 20.0
			var v: float = float(segment + 1) / 20.0
			var a: float = lerpf(leading, trailing, u)
			var b: float = lerpf(leading, trailing, v)
			var thickness_a: float = sin(PI * pow(u, 0.55))
			var thickness_b: float = sin(PI * pow(v, 0.55))
			var inner_a: float = lerpf(band.y, band.x, thickness_a)
			var inner_b: float = lerpf(band.y, band.x, thickness_b)
			var direction_a: Vector3 = Vector3(cos(a) * float(slot.facing), sin(a) * 0.88, 0)
			var direction_b: Vector3 = Vector3(cos(b) * float(slot.facing), sin(b) * 0.88, 0)
			var z: Vector3 = Vector3(0, 0, depth)
			_quad(mesh, direction_a * band.y + z, direction_b * band.y + z,
				direction_b * inner_b + z, direction_a * inner_a + z,
				Color(1, 1, 1, band.z * pow(1.0 - u, 0.7)),
				Color(1, 1, 1, band.z * pow(1.0 - v, 0.7)))
	mesh.surface_end()


func _quad(mesh: ImmediateMesh, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		color_a: Color, color_b: Color) -> void:
	for vertex: int in [0, 1, 2, 0, 2, 3]:
		mesh.surface_set_color(color_a if vertex == 0 or vertex == 3 else color_b)
		match vertex:
			0: mesh.surface_add_vertex(a)
			1: mesh.surface_add_vertex(b)
			2: mesh.surface_add_vertex(c)
			3: mesh.surface_add_vertex(d)