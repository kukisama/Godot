extends Node3D
## Chapter I environment. The caller owns the camera, gameplay and update clock.
## build() is idempotent; call update_world() only while the world should animate.
## Floors end exactly at the three gaps. Scenery and water have NO collision.
## Both arena gates (158 / 187) start open. Closing at player_x > 160 is safe.
## shrine_nodes[i].set_meta("active", true) changes that checkpoint's lantern.
## Missing prepared textures are retried, without rebuilding geometry or loading
## source atlases. An editor/import pass must make new PNGs ResourceLoader-visible.

const ASSET_ROOT: String = "res://assets/environment/"
const WATER_SHADER: Shader = preload("res://shaders/water.gdshader")
const WORLD_SEED: int = 0x48424C31
const FLOOR_SPANS: Array[Vector2] = [
	Vector2(-12.0, 39.0), Vector2(42.0, 82.0),
	Vector2(85.0, 121.0), Vector2(125.0, 198.0),
]
const GAP_SPANS: Array[Vector2] = [
	Vector2(39.0, 42.0), Vector2(82.0, 85.0), Vector2(121.0, 125.0),
]
const SHRINE_X: Array[float] = [5.0, 62.0, 133.0]
const GATE_X: Array[float] = [158.0, 187.0]
const PATH_DEPTH: float = 5.8
const CAMERA_SLOPE: float = 4.6 / 24.0
const GATE_LIFT: float = 7.6

var shrine_nodes: Array[Node3D] = []

var _built: bool = false
var _clock: float = 0.0
var _asset_timer: float = 0.0
var _gate_closed: bool = false
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _terrain: Node3D
var _architecture: Node3D
var _vegetation: Node3D
var _details: Node3D
var _atmosphere: Node3D
var _environment: Environment
var _water_material: ShaderMaterial
var _textures: Dictionary = {}
var _materials: Dictionary = {}
var _arch_meshes: Dictionary = {}
var _pending_assets: Array[Dictionary] = []
var _box_batches: Dictionary = {}
var _backdrops: Array[Dictionary] = []
var _swaying: Array[Dictionary] = []
var _torches: Array[Dictionary] = []
var _shrines: Array[Dictionary] = []
var _mote_fields: Array[Dictionary] = []
var _gate_visuals: Array[Node3D] = []
var _gate_shapes: Array[CollisionShape3D] = []
var _hanging_bells: Array[Node3D] = []
var _bell_mesh: ArrayMesh
var _stone: StandardMaterial3D
var _brick: StandardMaterial3D
var _wood: StandardMaterial3D
var _bark: StandardMaterial3D
var _moss: StandardMaterial3D
var _bronze: StandardMaterial3D
var _iron: StandardMaterial3D
var _amber: StandardMaterial3D
var _ivory: StandardMaterial3D
var _mote_material: StandardMaterial3D


func build() -> void:
	if _built:
		return
	_rng.seed = WORLD_SEED
	_terrain = _group("PlayableTerrain", self)
	_architecture = _group("StoneArchitecture", self)
	_vegetation = _group("LayeredVegetation", self)
	_details = _group("ShrinesTorchesAndBells", self)
	_atmosphere = _group("Atmosphere", self)
	_make_palette()
	_make_lighting()
	_make_backdrops()
	_make_terrain()
	_make_forest()
	_make_aqueduct()
	_make_abbey()
	_make_arena()
	_make_shrines()
	_make_gates()
	_make_exit_bell()
	_make_ambient_motes()
	_flush_box_batches()
	_built = true
	update_world(0.0, 5.0)


func update_world(delta: float, player_x: float) -> void:
	if not _built:
		return
	var step: float = maxf(delta, 0.0)
	_clock += step
	_asset_timer += step
	if not _pending_assets.is_empty() and _asset_timer >= 2.0:
		_asset_timer = 0.0
		_refresh_assets()
	_update_backdrops(player_x)
	_update_torches(player_x)
	_update_shrines()
	_update_motes(player_x)
	for entry: Dictionary in _swaying:
		var sprite: Sprite3D = entry["node"] as Sprite3D
		if absf(float(entry["x"]) - player_x) > 24.0:
			continue
		var phase: float = float(entry["phase"])
		var strength: float = float(entry["strength"])
		sprite.rotation.z = sin(_clock * 0.73 + phase) * strength
	for gate: Node3D in _gate_visuals:
		var target_y: float = 0.0 if _gate_closed else GATE_LIFT
		gate.position.y = move_toward(gate.position.y, target_y, step * 8.0)
	for index: int in range(_hanging_bells.size()):
		var bell: Node3D = _hanging_bells[index]
		bell.rotation.z = sin(_clock * 0.42 + float(index)) * 0.012
	if _water_material != null:
		_water_material.set_shader_parameter("flow_time", _clock)
	var abbey_weight: float = smoothstep(78.0, 96.0, player_x)
	_environment.ambient_light_color = Color(0.43, 0.56, 0.60).lerp(
		Color(0.40, 0.49, 0.57), abbey_weight)
	_environment.fog_light_color = Color(0.20, 0.31, 0.34).lerp(
		Color(0.19, 0.26, 0.31), abbey_weight)


func close_boss_gate() -> void:
	_gate_closed = true
	_set_gate_collisions(true)


func open_boss_gate() -> void:
	_gate_closed = false
	_set_gate_collisions(false)


func _group(label: String, parent: Node) -> Node3D:
	var node: Node3D = Node3D.new()
	node.name = label
	parent.add_child(node)
	return node


func _texture(path: String) -> Texture2D:
	var cached: Texture2D = _textures.get(path) as Texture2D
	if cached != null:
		return cached
	if not ResourceLoader.exists(path, "Texture2D"):
		return null
	var loaded: Texture2D = ResourceLoader.load(path, "Texture2D") as Texture2D
	if loaded != null:
		_textures[path] = loaded
	return loaded


func _bind_texture(target: Object, property: StringName, asset: String) -> void:
	var path: String = ASSET_ROOT + asset + ".png"
	var image: Texture2D = _texture(path)
	if image != null:
		target.set(property, image)
	else:
		_pending_assets.append({"target": target, "property": property, "path": path})


func _refresh_assets() -> void:
	for index: int in range(_pending_assets.size() - 1, -1, -1):
		var binding: Dictionary = _pending_assets[index]
		var target: Object = binding["target"]
		if not is_instance_valid(target):
			_pending_assets.remove_at(index)
			continue
		var image: Texture2D = _texture(String(binding["path"]))
		if image != null:
			target.set(StringName(binding["property"]), image)
			_pending_assets.remove_at(index)


func _surface(asset: String, tint: Color, uv_scale: Vector2 = Vector2.ONE,
		uv_offset: Vector2 = Vector2.ZERO, world_uv: bool = true) -> StandardMaterial3D:
	var key: String = "%s:%s:%s:%s:%s" % [asset, tint.to_html(), uv_scale, uv_offset, world_uv]
	if _materials.has(key):
		return _materials[key] as StandardMaterial3D
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = tint
	material.roughness = 0.97
	material.metallic_specular = 0.08
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	material.texture_repeat = true
	material.uv1_scale = Vector3(uv_scale.x, uv_scale.y, 1.0)
	material.uv1_offset = Vector3(uv_offset.x, uv_offset.y, 0.0)
	material.vertex_color_use_as_albedo = true
	if not asset.is_empty():
		if world_uv:
			# Square tiles span 2.4 world units, including scaled box batches.
			material.uv1_triplanar = true
			material.uv1_world_triplanar = true
			material.uv1_triplanar_sharpness = 8.0
			material.uv1_scale = Vector3(uv_scale.x, uv_scale.y, uv_scale.x) / 2.4
		_bind_texture(material, &"albedo_texture", asset)
	_materials[key] = material
	return material


func _glowing(tint: Color, energy: float) -> StandardMaterial3D:
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = tint
	material.emission_enabled = true
	material.emission = tint
	material.emission_energy_multiplier = energy
	material.roughness = 0.65
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	return material


func _make_palette() -> void:
	_stone = _surface("stone", Color(0.67, 0.73, 0.72))
	_brick = _surface("brick", Color(0.53, 0.61, 0.61))
	_wood = _surface("wood", Color(0.62, 0.57, 0.47))
	_bark = _surface("earth", Color(0.30, 0.39, 0.37))
	_moss = _surface("moss", Color(0.38, 0.50, 0.43))
	_bronze = _surface("", Color(0.43, 0.32, 0.15))
	_bronze.metallic = 0.72
	_bronze.roughness = 0.42
	_iron = _surface("", Color(0.15, 0.22, 0.23))
	_iron.metallic = 0.65
	_amber = _glowing(Color(1.0, 0.48, 0.11), 1.4)
	_ivory = _glowing(Color(1.0, 0.85, 0.47), 1.8)
	_mote_material = StandardMaterial3D.new()
	_mote_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mote_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mote_material.vertex_color_use_as_albedo = true
	_mote_material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_mote_material.billboard_keep_scale = true
	_mote_material.no_depth_test = false
	_mote_material.disable_fog = true
	_mote_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_bell_mesh = _make_bell_mesh()


func _make_lighting() -> void:
	var world_environment: WorldEnvironment = WorldEnvironment.new()
	world_environment.name = "MoonlitAir"
	_environment = Environment.new()
	_environment.background_mode = Environment.BG_COLOR
	_environment.background_color = Color(0.055, 0.105, 0.13)
	_environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_environment.ambient_light_energy = 0.68
	_environment.ambient_light_sky_contribution = 0.0
	_environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	_environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	_environment.tonemap_exposure = 1.0
	_environment.fog_enabled = true
	_environment.fog_mode = Environment.FOG_MODE_DEPTH
	# In depth mode density is the maximum opacity, NOT exponential density.
	_environment.fog_density = 0.48
	# Camera-to-hero distance is about 24.5: fog starts BEHIND the combat plane.
	_environment.fog_depth_begin = 31.0
	_environment.fog_depth_end = 92.0
	_environment.fog_depth_curve = 1.15
	_environment.fog_light_energy = 0.65
	_environment.fog_sun_scatter = 0.06
	world_environment.environment = _environment
	_atmosphere.add_child(world_environment)
	var key: DirectionalLight3D = DirectionalLight3D.new()
	key.name = "PaleGoldMoon"
	key.rotation_degrees = Vector3(-48.0, -26.0, 0.0)
	key.light_color = Color(0.76, 0.84, 0.86)
	key.light_energy = 0.72
	key.shadow_enabled = true
	key.shadow_bias = 0.035
	key.shadow_normal_bias = 1.1
	key.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	key.directional_shadow_max_distance = 65.0
	key.directional_shadow_blend_splits = true
	_atmosphere.add_child(key)
	var fill: DirectionalLight3D = DirectionalLight3D.new()
	fill.name = "CoolStoneBounce"
	fill.rotation_degrees = Vector3(-24.0, 148.0, 0.0)
	fill.light_color = Color(0.42, 0.66, 0.80)
	fill.light_energy = 0.20
	fill.shadow_enabled = false
	_atmosphere.add_child(fill)


func _make_backdrops() -> void:
	_add_backdrop("vista", -43.0, 5.7, 29.0, 90.0, 0.028,
		Color(0.56, 0.68, 0.72, 1.0), Vector2(-100.0, 300.0))
	_add_backdrop("forest", -23.0, 4.8, 20.0, 16.0, 0.09,
		Color(0.39, 0.52, 0.53, 0.94), Vector2(-60.0, 46.0))
	_add_backdrop("abbey", -27.0, 4.9, 21.0, 136.0, 0.058,
		Color(0.48, 0.58, 0.62, 0.94), Vector2(79.0, 240.0))


func _add_backdrop(asset: String, depth: float, screen_y: float, height: float,
		anchor: float, parallax: float, tint: Color, extent: Vector2) -> void:
	var sprite: Sprite3D = Sprite3D.new()
	sprite.name = asset.capitalize() + "DistantLayer"
	sprite.pixel_size = height / 1024.0
	# Orthographic depth does not shrink sprites, and shifts their apparent height.
	# Compensate for the specified camera's pitch rather than stretching the art.
	sprite.position = Vector3(anchor, screen_y + depth * CAMERA_SLOPE, depth)
	sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	sprite.shaded = false
	sprite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sprite.modulate = tint
	_bind_texture(sprite, &"texture", asset)
	_atmosphere.add_child(sprite)
	_backdrops.append({"node": sprite, "anchor": anchor, "parallax": parallax,
		"tint": tint, "extent": extent})


func _update_backdrops(player_x: float) -> void:
	for entry: Dictionary in _backdrops:
		var sprite: Sprite3D = entry["node"] as Sprite3D
		var extent: Vector2 = entry["extent"]
		var tint: Color = entry["tint"]
		var weight: float = smoothstep(extent.x, extent.x + 12.0, player_x)
		weight *= 1.0 - smoothstep(extent.y - 12.0, extent.y, player_x)
		sprite.position.x = player_x + (float(entry["anchor"]) - player_x) * float(entry["parallax"])
		sprite.modulate = Color(tint.r, tint.g, tint.b, tint.a * weight)
		sprite.visible = sprite.texture != null and weight > 0.002


func _make_terrain() -> void:
	for index: int in range(FLOOR_SPANS.size()):
		var span: Vector2 = FLOOR_SPANS[index]
		for gap: Vector2 in GAP_SPANS:
			assert(span.y <= gap.x or span.x >= gap.y, "Floor overlaps a real gap")
		var body: StaticBody3D = StaticBody3D.new()
		body.name = "Floor%d" % index
		body.collision_layer = 1
		body.collision_mask = 0
		body.set_meta("span", span)
		body.set_meta("top_y", 0.0)
		var shape: BoxShape3D = BoxShape3D.new()
		shape.size = Vector3(span.y - span.x, 0.8, PATH_DEPTH)
		var collision: CollisionShape3D = CollisionShape3D.new()
		collision.shape = shape
		collision.position = Vector3((span.x + span.y) * 0.5, -0.4, 0.0)
		body.add_child(collision)
		_terrain.add_child(body)
		var cursor: float = span.x
		while cursor < span.y - 0.001:
			var end: float = minf(cursor + 5.25, span.y)
			_make_slab(cursor, end)
			cursor = end
		_make_retaining_courses(span)
		_make_verges(span)
		# Exposed end faces, not caps extending over a hole.
		for edge: float in [span.x, span.y]:
			var inward: float = 1.0 if is_equal_approx(edge, span.x) else -1.0
			for fragment: int in range(5):
				_batch_box("BrokenEnds", Vector3(edge + inward * 0.19, -0.19,
					-2.35 + float(fragment) * 1.15), Vector3(0.37, 0.3, 0.72),
					_stone, Color(0.81, 0.87, 0.82), _rng.randf_range(-0.1, 0.1))


func _make_slab(start: float, end: float) -> void:
	var width: float = end - start
	var center: float = (start + end) * 0.5
	var forest: bool = center < 40.0
	var bridge: bool = center >= 42.0 and center < 85.0
	var height: float = 1.15 if bridge else 3.3 + _rng.randf_range(0.0, 0.45)
	var top_asset: String = "moss" if forest else "flagstone"
	var side_asset: String = "earth" if forest else "stone"
	var top_tint: Color = Color(0.55, 0.65, 0.55) if forest else Color(0.69, 0.74, 0.71)
	var top: StandardMaterial3D = _surface(top_asset, top_tint,
		Vector2(width / 2.4, PATH_DEPTH / 2.4), Vector2(start / 2.4, 0.0), false)
	var side: StandardMaterial3D = _surface(side_asset, Color(0.50, 0.62, 0.61))
	_box(_terrain, Vector3(center, -0.18 - height * 0.5, 0.0),
		Vector3(width, height, PATH_DEPTH - 0.25), side)
	_box(_terrain, Vector3(center, -0.132, 0.0), Vector3(width, 0.24, PATH_DEPTH), _stone)
	_floor_plane(_terrain, Vector3(center, 0.0, 0.0), Vector2(width, PATH_DEPTH), top)
	_wall_quad(_terrain, Vector3(center, -0.18 - height * 0.5, 2.792),
		Vector2(width, height), side)
	_wall_quad(_terrain, Vector3(center, -0.18 - height * 0.5, -2.792),
		Vector2(width, height), side, PI)
	if forest:
		var path_material: StandardMaterial3D = _surface("earth", Color(0.50, 0.55, 0.46),
			Vector2(width / 2.0, 1.35 / 2.0), Vector2(start / 2.0, 0.0), false)
		_floor_plane(_terrain, Vector3(center, 0.006, 0.0), Vector2(width, 1.35), path_material)
	elif center > 158.0:
		_batch_box("ArenaInlay", Vector3(center, 0.004, -1.5),
			Vector3(width, 0.008, 0.045), _bronze)
		_batch_box("ArenaInlay", Vector3(center, 0.004, 1.5),
			Vector3(width, 0.008, 0.045), _bronze)


func _make_retaining_courses(span: Vector2) -> void:
	var bridge: bool = span.x >= 42.0 and span.y <= 82.0
	var courses: int = 2 if bridge else 4
	for row: int in range(courses):
		var cursor: float = span.x
		while cursor < span.y - 0.08:
			var width: float = minf(_rng.randf_range(1.0, 1.65), span.y - cursor)
			var tint: Color = Color.WHITE * _rng.randf_range(0.77, 1.04)
			tint.a = 1.0
			_batch_box("RetainingStone", Vector3(cursor + width * 0.5,
				-0.49 - float(row) * 0.51, 2.84 + _rng.randf_range(-0.035, 0.035)),
				Vector3(maxf(width - 0.045, 0.03), 0.465, 0.27), _stone, tint)
			cursor += width
	var coping: float = span.x
	while coping < span.y - 0.01:
		var width: float = minf(1.45, span.y - coping)
		for depth: float in [-2.78, 2.78]:
			_batch_box("CopingStones", Vector3(coping + width * 0.5, -0.07, depth),
				Vector3(width - 0.035, 0.14, 0.35), _stone, Color(0.96, 1.0, 0.88))
		coping += width


func _make_verges(span: Vector2) -> void:
	var cursor: float = span.x + 0.5
	while cursor < span.y - 0.4:
		var forest: bool = cursor < 40.0
		for side: float in [-1.0, 1.0]:
			var depth: float = side * _rng.randf_range(2.05, 2.65)
			_batch_box("MossEdges", Vector3(cursor, 0.015, depth),
				Vector3(_rng.randf_range(0.3, 0.9), 0.065, _rng.randf_range(0.2, 0.48)),
				_moss, Color(0.87, 0.96, 0.79), _rng.randf_range(-0.25, 0.25))
		if forest or _rng.randf() < 0.38:
			_prop("ferns", Vector3(cursor, -0.05, -2.5),
				_rng.randf_range(0.65, 1.25), Color(0.54, 0.68, 0.56), 0.024)
		# Foreground decoration stays below the actor's knees; no opaque tree wall.
		if _rng.randf() < 0.55:
			_prop("ferns", Vector3(cursor, -0.22, 3.15),
				_rng.randf_range(0.42, 0.72), Color(0.20, 0.32, 0.28), 0.035)
		for pebble: int in range(2):
			_batch_box("PathChips", Vector3(cursor + _rng.randf_range(-0.2, 0.2),
				0.02, _rng.randf_range(0.75, 1.5)),
				Vector3(_rng.randf_range(0.07, 0.2), 0.045, 0.1),
				_stone, Color(0.73, 0.79, 0.65), _rng.randf_range(-PI, PI))
		cursor += _rng.randf_range(1.25, 2.35)


func _make_forest() -> void:
	# Four depth bands: distant firs, substantial midground trunks, roadside
	# botanical detail, then only low foreground framing. Authored crowns stay clear.
	for index: int in range(17):
		var x: float = -16.0 + float(index) * 3.6 + _rng.randf_range(-0.5, 0.5)
		_tree(Vector3(x, -0.8, -13.0 - _rng.randf_range(0.0, 4.0)),
			_rng.randf_range(8.0, 11.5), true, Color(0.24, 0.37, 0.39))
	for index: int in range(10):
		var x: float = -10.0 + float(index) * 5.25
		_tree(Vector3(x, -0.35, -5.7 - _rng.randf_range(0.0, 2.2)),
			_rng.randf_range(6.6, 9.1), index % 3 == 0, Color(0.43, 0.54, 0.48))
	_arch(_architecture, Vector3(15.0, 0.0, -3.85), 4.0, 2.0, 0.65, _stone, true)
	_prop("arch", Vector3(15.0, 0.0, -4.3), 5.4, Color(0.43, 0.54, 0.49))
	_prop("dead_tree", Vector3(37.0, -0.1, -3.8), 6.2, Color(0.44, 0.57, 0.53), 0.003)
	for x: float in [2.0, 21.8, 32.0]:
		_box(_details, Vector3(x, 0.42, -1.95), Vector3(0.48, 0.84, 0.48), _stone)
		_box(_details, Vector3(x, 0.85, -1.95), Vector3(0.66, 0.13, 0.64), _moss)
		_torus(_details, Vector3(x, 0.54, -1.695), 0.1, 0.15, _bronze, true)
	_add_torch(Vector3(11.0, 2.35, -2.3), 0.82)
	_add_torch(Vector3(29.0, 2.4, -2.3), 0.9)


func _tree(origin: Vector3, height: float, fir: bool, tint: Color) -> void:
	var asset: String = "fir" if fir else "oak"
	_prop(asset, origin, height, tint, 0.002)
	var trunk: Node3D = _group("FirTrunk" if fir else "OakTrunk", _vegetation)
	trunk.position = origin + Vector3(0.0, 0.0, -0.16)
	_cylinder(trunk, Vector3(0.0, height * 0.31, 0.0),
		height * 0.62, 0.12, 0.27, _bark)
	if not fir:
		for side: float in [-1.0, 1.0]:
			_beam(trunk, Vector3(0.0, height * 0.35, 0.0),
				Vector3(side * height * 0.16, height * 0.7, -0.1), 0.12, _bark)


func _make_aqueduct() -> void:
	_water_material = ShaderMaterial.new()
	_water_material.shader = WATER_SHADER
	var river: PlaneMesh = PlaneMesh.new()
	river.size = Vector2(69.0, 44.0)
	river.subdivide_width = 80
	river.subdivide_depth = 36
	var water: MeshInstance3D = _mesh(_architecture, river, _water_material,
		Vector3(61.0, -4.8, -20.0))
	water.name = "RiverFarBelowTheBrokenBridge"
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Load-bearing arches have real open interiors and individually cut voussoirs.
	for x: float in [46.8, 56.3, 65.8, 75.3]:
		for depth: float in [-2.15, 2.1]:
			_arch(_architecture, Vector3(x, -7.15, depth), 7.45, 2.0, 0.72, _stone)
		_box(_architecture, Vector3(x - 4.2, -4.5, 0.0), Vector3(0.75, 5.3, 4.6), _brick)
	for index: int in range(10):
		var x: float = 43.5 + float(index) * 4.0
		_box(_architecture, Vector3(x, 0.59, -2.65), Vector3(0.34, 1.18, 0.37), _stone)
		_box(_architecture, Vector3(x, 1.2, -2.65), Vector3(0.49, 0.12, 0.49), _moss)
		if index % 3 != 1:
			_box(_architecture, Vector3(x + 1.4, 0.9, -2.65), Vector3(2.48, 0.24, 0.28), _stone)
		# Near rails are broken down to ankle height to preserve combat readability.
		_batch_box("BrokenNearRail", Vector3(x, 0.19, 2.7),
			Vector3(0.36, 0.38, 0.36), _stone, Color(0.72, 0.80, 0.71))
		if index % 4 == 0:
			_batch_box("BrokenNearRail", Vector3(x + 0.55, 0.12, 2.7),
				Vector3(0.86, 0.2, 0.24), _stone, Color.WHITE, -0.1)
	# Ruined sister aqueduct, well behind the player's route.
	var distant_stone: StandardMaterial3D = _surface("", Color(0.16, 0.25, 0.28))
	distant_stone.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for index: int in range(4):
		var x: float = 41.0 + float(index) * 14.0
		_arch(_architecture, Vector3(x, -6.5, -20.0), 7.6, 1.8, 0.8,
			distant_stone, index == 2)
	for x: float in [43.6, 59.2, 79.1]:
		_add_torch(Vector3(x, 2.45, -2.35), 0.85)
	for x: float in [48.0, 69.0, 80.5]:
		_prop("banner", Vector3(x, 1.6, -3.4), 3.4, Color(0.68, 0.56, 0.51), 0.014)
	for x: float in [39.0, 42.0, 82.0, 85.0]:
		var outward: float = -1.0 if x == 39.0 or x == 82.0 else 1.0
		for index: int in range(3):
			var plank: MeshInstance3D = _box(_details,
				Vector3(x + outward * 0.38, -0.09, -1.9 + float(index) * 1.75),
				Vector3(0.65, 0.12, 0.27), _wood)
			plank.rotation.z = outward * 0.12
	for index: int in range(15):
		_rock(_architecture, Vector3(_rng.randf_range(35.0, 88.0), -4.6,
			_rng.randf_range(-13.0, -5.5)),
			Vector3(_rng.randf_range(0.8, 2.1), _rng.randf_range(0.5, 1.7), 1.2), _stone)


func _make_abbey() -> void:
	var rear_stone: StandardMaterial3D = _surface("brick", Color(0.36, 0.47, 0.49))
	for index: int in range(9):
		var x: float = 87.0 + float(index) * 8.0
		_arch(_architecture, Vector3(x, 0.0, -4.5), 6.0, 3.6, 0.8,
			_stone, index == 3 or index == 7)
		_column(Vector3(x - 3.35, 0.0, -4.3), 6.3, 0.44)
		if index % 2 == 0:
			_prop("banner", Vector3(x - 2.6, 2.15, -3.7), 3.55,
				Color(0.77, 0.66, 0.62), 0.01)
			_beam(_architecture, Vector3(x - 3.4, 5.5, -4.25),
				Vector3(x - 2.1, 5.5, -3.7), 0.045, _bronze)
		if index != 4:
			_box(_architecture, Vector3(x, 0.8, -9.8), Vector3(7.8, 1.6, 0.85), rear_stone)
		_arch(_architecture, Vector3(x + 1.4, 1.6, -10.0), 6.2, 3.4, 0.65,
			rear_stone, index % 4 == 1)
		_box(_architecture, Vector3(x, 1.7, -9.5), Vector3(7.8, 0.22, 1.25), rear_stone)
		if index % 3 != 0:
			_prop("ferns", Vector3(x - 2.8, 1.78, -8.85), 1.3,
				Color(0.46, 0.65, 0.49), 0.018)
	_rose_window(Vector3(105.5, 5.15, -9.42), 1.75)
	_rose_window(Vector3(145.5, 5.2, -9.42), 1.55)
	# A collapsed gallery frames the third gap; no debris bridges z=0 collision.
	for index: int in range(7):
		var x: float = 118.0 + float(index) * 1.4
		var rubble: MeshInstance3D = _box(_architecture, Vector3(x,
			-2.7 + _rng.randf_range(-0.3, 0.3), -4.9), Vector3(1.15, 0.5, 1.0), _stone)
		rubble.rotation = Vector3(0.2, _rng.randf_range(-0.4, 0.4), _rng.randf_range(-0.7, 0.7))
	_prop("dead_tree", Vector3(124.0, -2.0, -5.4), 6.1, Color(0.51, 0.61, 0.56))
	for x: float in [90.0, 102.0, 114.5, 128.0, 141.0, 152.0]:
		_add_torch(Vector3(x, 2.65, -2.2), 1.0)
	for x: float in [97.0, 111.0, 137.0, 149.0]:
		# Side alcoves are behind the walk plane, not inaccessible raised floors.
		_box(_architecture, Vector3(x, 0.3, -3.6), Vector3(2.0, 0.6, 1.2), _brick)
		_box(_architecture, Vector3(x, 0.66, -3.6), Vector3(2.2, 0.13, 1.35), _stone)
		_prop("ferns", Vector3(x + 0.5, 0.72, -3.0), 1.15, Color(0.54, 0.69, 0.46), 0.02)


func _column(origin: Vector3, height: float, radius: float) -> void:
	var column: Node3D = _group("DressedColumn", _architecture)
	column.position = origin
	_box(column, Vector3(0.0, 0.18, 0.0), Vector3(radius * 2.8, 0.36, radius * 2.8), _stone)
	_cylinder(column, Vector3(0.0, height * 0.5, 0.0), height - 0.45,
		radius * 0.82, radius, _stone)
	for level: float in [0.48, height - 0.5]:
		_torus(column, Vector3(0.0, level, 0.0), radius * 0.89, radius * 1.16, _stone)
	_box(column, Vector3(0.0, height - 0.12, 0.0), Vector3(radius * 2.75, 0.24, radius * 2.75), _stone)
	for side: float in [-1.0, 1.0]:
		_box(column, Vector3(side * radius * 0.5, height * 0.5, radius * 0.83),
			Vector3(0.07, height - 1.1, 0.065), _brick)


func _rose_window(origin: Vector3, radius: float) -> void:
	_torus(_architecture, origin, radius * 0.88, radius, _stone, true)
	_torus(_architecture, origin + Vector3(0.0, 0.0, 0.04), radius * 0.43,
		radius * 0.47, _bronze, true)
	for index: int in range(8):
		var angle: float = float(index) * TAU / 8.0
		var direction: Vector3 = Vector3(cos(angle), sin(angle), 0.0)
		_beam(_architecture, origin + direction * radius * 0.14,
			origin + direction * radius * 0.91, 0.045, _stone)
	_rock(_architecture, origin + Vector3(0.0, 0.0, 0.06), Vector3(0.16, 0.16, 0.08), _bronze)


func _make_arena() -> void:
	var arena_stone: StandardMaterial3D = _surface("stone", Color(0.56, 0.65, 0.68))
	for x: float in [161.5, 169.0, 180.8, 188.0]:
		_column(Vector3(x, 0.0, -5.8), 9.3, 0.63)
		_box(_architecture, Vector3(x, 2.2, -7.0), Vector3(1.65, 4.4, 1.3), arena_stone)
	_arch(_architecture, Vector3(175.0, 0.0, -7.0), 11.1, 4.1, 1.25, arena_stone)
	_box(_architecture, Vector3(175.0, 8.9, -5.8), Vector3(13.0, 0.5, 1.1), _wood)
	_beam(_architecture, Vector3(170.0, 6.0, -5.8), Vector3(173.4, 8.9, -5.8), 0.17, _wood)
	_beam(_architecture, Vector3(180.0, 6.0, -5.8), Vector3(176.6, 8.9, -5.8), 0.17, _wood)
	_beam(_architecture, Vector3(175.0, 7.6, -5.8), Vector3(175.0, 8.9, -5.8), 0.07, _iron)
	_make_hanging_bell(_architecture, Vector3(175.0, 7.6, -5.8), 1.65, true)
	for x: float in [163.6, 171.4, 179.0, 184.5]:
		_box(_architecture, Vector3(x, 0.35, -2.35), Vector3(0.8, 0.7, 0.85), _stone)
		_add_torch(Vector3(x, 2.8, -2.35), 1.12)
	for x: float in [161.8, 186.5]:
		_prop("banner", Vector3(x, 2.4, -4.7), 5.7, Color(0.72, 0.52, 0.47), 0.008)
	# Recessed metal rings make a ceremonial floor, without introducing a step.
	for radius: float in [1.1, 1.65, 2.25]:
		_torus(_details, Vector3(175.0, -0.016, 0.0), radius, radius + 0.04, _bronze)
	for index: int in range(13):
		var x: float = 160.0 + float(index) * 2.15
		_batch_box("SanctumFloorJoints", Vector3(x, 0.004, 0.0),
			Vector3(0.025, 0.008, 2.9), _bronze, Color(0.55, 0.65, 0.6))


func _make_shrines() -> void:
	for index: int in range(SHRINE_X.size()):
		var shrine: Node3D = _group("Checkpoint%d" % index, _details)
		shrine.position = Vector3(SHRINE_X[index], 0.0, -1.9)
		shrine.set_meta("checkpoint_index", index)
		shrine.set_meta("checkpoint_x", SHRINE_X[index])
		shrine.set_meta("active", index == 0)
		shrine_nodes.append(shrine)
		_box(shrine, Vector3(0.0, 0.14, 0.0), Vector3(1.48, 0.28, 1.0), _stone)
		_box(shrine, Vector3(0.0, 0.32, 0.0), Vector3(1.16, 0.1, 0.84), _moss)
		for side: float in [-1.0, 1.0]:
			_cylinder(shrine, Vector3(side * 0.51, 1.25, 0.0), 1.8, 0.12, 0.16, _stone)
		_box(shrine, Vector3(0.0, 2.18, 0.0), Vector3(1.5, 0.23, 0.95), _stone)
		var roof: MeshInstance3D = _box(shrine, Vector3(0.0, 2.38, 0.0), Vector3(0.83, 0.83, 0.82), _stone)
		roof.rotation.z = PI * 0.25
		_prop("shrine", Vector3(0.0, 0.0, -0.4), 3.0, Color(0.77, 0.83, 0.72), 0.0, shrine)
		_make_hanging_bell(shrine, Vector3(0.0, 2.07, 0.11), 0.45, false)
		var indicator: StandardMaterial3D = _glowing(Color(0.39, 0.70, 0.69), 0.6)
		var lantern: MeshInstance3D = _rock(shrine, Vector3(0.0, 0.83, 0.38),
			Vector3(0.13, 0.2, 0.13), indicator)
		var ring: MeshInstance3D = _torus(shrine, Vector3(0.0, 0.4, 0.0), 0.43, 0.47, indicator)
		var light: OmniLight3D = _omni(shrine, Vector3(0.0, 1.1, 0.5), 0.7, 3.9)
		_shrines.append({"node": shrine, "material": indicator, "lamp": lantern,
			"ring": ring, "light": light, "phase": float(index) * 2.1})


func _update_shrines() -> void:
	for entry: Dictionary in _shrines:
		var shrine: Node3D = entry["node"] as Node3D
		var material: StandardMaterial3D = entry["material"] as StandardMaterial3D
		var light: OmniLight3D = entry["light"] as OmniLight3D
		var ring: MeshInstance3D = entry["ring"] as MeshInstance3D
		var lamp: MeshInstance3D = entry["lamp"] as MeshInstance3D
		var active: bool = bool(shrine.get_meta("active", false))
		var tint: Color = Color(1.0, 0.74, 0.31) if active else Color(0.28, 0.63, 0.64)
		var pulse: float = 0.92 + sin(_clock * 1.7 + float(entry["phase"])) * 0.08
		material.albedo_color = tint
		material.emission = tint
		material.emission_energy_multiplier = (1.1 if active else 0.45) * pulse
		light.light_color = tint
		light.light_energy = (0.8 if active else 0.35) * pulse
		ring.scale = Vector3(pulse, 1.0, pulse)
		lamp.position.y = 0.84 + sin(_clock * 1.4 + float(entry["phase"])) * 0.055


func _make_gates() -> void:
	for index: int in range(GATE_X.size()):
		var x: float = GATE_X[index]
		var body: StaticBody3D = StaticBody3D.new()
		body.name = "BossEntranceGate" if index == 0 else "BossExitGate"
		body.collision_layer = 1
		body.collision_mask = 0
		body.position = Vector3(x, 0.0, 0.0)
		var box_shape: BoxShape3D = BoxShape3D.new()
		box_shape.size = Vector3(0.44, 7.2, 6.4)
		var collision: CollisionShape3D = CollisionShape3D.new()
		collision.name = "GateCollision"
		collision.position.y = 3.6
		collision.shape = box_shape
		collision.disabled = not _gate_closed
		body.add_child(collision)
		_terrain.add_child(body)
		_gate_shapes.append(collision)
		var frame: Node3D = _group("GateFrame%d" % index, _architecture)
		frame.position.x = x
		for depth: float in [-3.3, 3.3]:
			_box(frame, Vector3(0.0, 4.0, depth), Vector3(0.7, 8.0, 0.65), _stone)
			_box(frame, Vector3(0.0, 0.24, depth), Vector3(0.95, 0.48, 0.88), _stone)
		_box(frame, Vector3(0.0, 8.0, 0.0), Vector3(0.85, 0.55, 7.2), _stone)
		var door: Node3D = _group("RaisedPortcullis%d" % index, _architecture)
		door.position = Vector3(x, 0.0 if _gate_closed else GATE_LIFT, 0.0)
		for bar: int in range(9):
			var depth: float = -2.8 + float(bar) * 0.7
			_box(door, Vector3(0.0, 3.4, depth), Vector3(0.16, 6.8, 0.12), _iron)
		for y: float in [0.6, 3.4, 6.25]:
			_box(door, Vector3(0.0, y, 0.0), Vector3(0.27, 0.2, 5.95), _bronze)
		for depth: float in [-2.75, 2.75]:
			_box(door, Vector3(0.1, 3.4, depth), Vector3(0.035, 6.65, 0.045), _amber)
		_beam(door, Vector3(0.0, 0.65, -2.8), Vector3(0.0, 6.2, 2.8), 0.075, _bronze)
		_gate_visuals.append(door)


func _set_gate_collisions(enabled: bool) -> void:
	# Toggle only the gate shapes, deferred for callers inside a physics callback.
	# Entrance occupies [157.78, 158.22], never a wall ahead of a trigger at >160.
	for shape: CollisionShape3D in _gate_shapes:
		if shape.is_inside_tree():
			shape.set_deferred(&"disabled", not enabled)
		else:
			shape.disabled = not enabled


func _make_exit_bell() -> void:
	var pavilion: Node3D = _group("TheLastBellAt191", _details)
	pavilion.position = Vector3(191.0, 0.0, -1.45)
	for side: float in [-1.0, 1.0]:
		_cylinder(pavilion, Vector3(side * 1.4, 2.25, 0.0), 4.5, 0.18, 0.27, _stone)
		_box(pavilion, Vector3(side * 1.4, 0.17, 0.0), Vector3(0.75, 0.34, 0.8), _stone)
	_box(pavilion, Vector3(0.0, 4.45, 0.0), Vector3(3.4, 0.35, 0.9), _wood)
	_beam(pavilion, Vector3(-1.4, 3.3, 0.0), Vector3(-0.45, 4.4, 0.0), 0.12, _wood)
	_beam(pavilion, Vector3(1.4, 3.3, 0.0), Vector3(0.45, 4.4, 0.0), 0.12, _wood)
	_make_hanging_bell(pavilion, Vector3(0.0, 4.2, 0.0), 1.1, true)
	_torus(_details, Vector3(191.0, -0.019, 0.0), 1.75, 1.80, _bronze)
	_omni(pavilion, Vector3(0.0, 2.8, 1.1), 1.0, 5.0)
	_tree(Vector3(196.5, 0.0, -5.3), 8.3, false, Color(0.52, 0.55, 0.44))
	_prop("ferns", Vector3(193.4, 0.0, -2.2), 1.4, Color(0.58, 0.69, 0.54), 0.02)


func _add_torch(origin: Vector3, energy: float) -> void:
	var root: Node3D = _group("VotiveTorch", _details)
	root.position = origin
	_box(root, Vector3(0.0, -origin.y + 0.08, -0.2), Vector3(0.3, 0.16, 0.34), _stone)
	_beam(root, Vector3(0.0, -origin.y + 0.12, -0.2), Vector3(0.0, -0.62, -0.2), 0.045, _iron)
	_beam(root, Vector3(0.0, -0.7, -0.18), Vector3(0.0, -0.07, 0.06), 0.065, _wood)
	_beam(root, Vector3(0.0, -0.55, -0.45), Vector3(0.0, -0.4, 0.04), 0.045, _iron)
	_torus(root, Vector3(0.0, -0.02, 0.04), 0.095, 0.145, _bronze)
	_prop("torch", Vector3(0.0, -0.8, -0.17), 1.36, Color(0.81, 0.76, 0.63), 0.0, root)
	var flame: MeshInstance3D = _rock(root, Vector3(0.0, 0.17, 0.08), Vector3(0.12, 0.31, 0.10), _amber)
	flame.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var core: MeshInstance3D = _rock(root, Vector3(0.0, 0.13, 0.16), Vector3(0.055, 0.17, 0.045), _ivory)
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var light: OmniLight3D = _omni(root, Vector3(0.0, 0.22, 0.35), energy, 4.7)
	_torches.append({"node": root, "flame": flame, "light": light,
		"energy": energy, "phase": _rng.randf_range(0.0, TAU)})
	_add_motes("TorchEmbers", Vector2(origin.x - 0.18, origin.x + 0.18),
		Vector2(origin.y + 0.1, origin.y + 1.2), Vector2(origin.z, origin.z + 0.25),
		6, Color(1.0, 0.63, 0.23), 2)


func _omni(parent: Node3D, position: Vector3, energy: float, radius: float) -> OmniLight3D:
	var light: OmniLight3D = OmniLight3D.new()
	light.position = position
	light.light_color = Color(1.0, 0.66, 0.31)
	light.light_energy = energy
	light.omni_range = radius
	light.omni_attenuation = 1.5
	# Compatibility has a finite per-object light budget. Short ranges, chunked
	# ground and one shadow-casting sun avoid overlapping shadowed point lights.
	light.shadow_enabled = false
	light.distance_fade_enabled = true
	light.distance_fade_begin = 37.0
	light.distance_fade_length = 14.0
	parent.add_child(light)
	return light


func _update_torches(player_x: float) -> void:
	for entry: Dictionary in _torches:
		var root: Node3D = entry["node"] as Node3D
		root.visible = absf(root.position.x - player_x) < 31.0
		if not root.visible:
			continue
		var phase: float = float(entry["phase"])
		var flicker: float = 0.94 + 0.055 * sin(_clock * 7.3 + phase)
		flicker += 0.035 * sin(_clock * 13.1 + phase * 2.3)
		var light: OmniLight3D = entry["light"] as OmniLight3D
		var flame: MeshInstance3D = entry["flame"] as MeshInstance3D
		light.light_energy = float(entry["energy"]) * flicker
		flame.scale = Vector3(0.12 * (2.0 - flicker), 0.31 * flicker, 0.10)
		flame.rotation.z = sin(_clock * 4.8 + phase) * 0.075


func _make_ambient_motes() -> void:
	_add_motes("ForestFireflies", Vector2(-10.0, 39.0), Vector2(0.35, 4.8),
		Vector2(-5.5, 1.6), 80, Color(0.89, 0.88, 0.48), 1)
	_add_motes("RiverSpray", Vector2(39.0, 85.0), Vector2(-1.5, 2.2),
		Vector2(-8.0, -2.0), 46, Color(0.49, 0.69, 0.71), 0)
	_add_motes("AbbeyDust", Vector2(85.0, 158.0), Vector2(0.4, 6.0),
		Vector2(-5.0, 1.0), 100, Color(0.86, 0.82, 0.64), 0)
	_add_motes("BelfryDust", Vector2(158.0, 198.0), Vector2(0.5, 6.5),
		Vector2(-5.0, 0.5), 45, Color(0.90, 0.77, 0.51), 0)


func _add_motes(label: String, span: Vector2, heights: Vector2, depths: Vector2,
		amount: int, tint: Color, mode: int) -> void:
	var quad: QuadMesh = QuadMesh.new()
	quad.size = Vector2.ONE
	var multimesh: MultiMesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = quad
	multimesh.instance_count = amount
	var instance: MultiMeshInstance3D = MultiMeshInstance3D.new()
	instance.name = label
	instance.multimesh = multimesh
	instance.material_override = _mote_material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_atmosphere.add_child(instance)
	var positions: Array[Vector3] = []
	var phases: PackedFloat32Array = PackedFloat32Array()
	var sizes: PackedFloat32Array = PackedFloat32Array()
	for index: int in range(amount):
		positions.append(Vector3(_rng.randf_range(span.x, span.y),
			_rng.randf_range(heights.x, heights.y), _rng.randf_range(depths.x, depths.y)))
		phases.append(_rng.randf_range(0.0, TAU))
		sizes.append(_rng.randf_range(0.018, 0.052) if mode == 1 else _rng.randf_range(0.012, 0.032))
		multimesh.set_instance_transform(index, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * sizes[index]), positions[index]))
		multimesh.set_instance_color(index, Color(tint.r, tint.g, tint.b, 0.5))
	_mote_fields.append({"node": instance, "mesh": multimesh, "positions": positions,
		"phases": phases, "sizes": sizes, "tint": tint, "mode": mode,
		"span": span, "heights": heights})


func _update_motes(player_x: float) -> void:
	for field: Dictionary in _mote_fields:
		var node: MultiMeshInstance3D = field["node"] as MultiMeshInstance3D
		var span: Vector2 = field["span"]
		node.visible = player_x > span.x - 17.0 and player_x < span.y + 17.0
		if not node.visible:
			continue
		var multimesh: MultiMesh = field["mesh"] as MultiMesh
		var positions: Array = field["positions"]
		var phases: PackedFloat32Array = field["phases"]
		var sizes: PackedFloat32Array = field["sizes"]
		var tint: Color = field["tint"]
		var heights: Vector2 = field["heights"]
		var mode: int = int(field["mode"])
		for index: int in range(positions.size()):
			var base: Vector3 = positions[index]
			var phase: float = phases[index]
			var position: Vector3 = base
			var alpha: float = 0.48
			if mode == 1:
				position += Vector3(sin(_clock * 0.45 + phase) * 0.43,
					cos(_clock * 0.6 + phase * 1.7) * 0.24, sin(_clock * 0.4 + phase) * 0.18)
				alpha = 0.3 + 0.6 * pow(0.5 + 0.5 * sin(_clock * 1.35 + phase), 2.0)
			else:
				var speed: float = 0.35 if mode == 2 else 0.075
				var cycle: float = fposmod(phase / TAU + _clock * speed / (heights.y - heights.x), 1.0)
				position.y = lerpf(heights.x, heights.y, cycle)
				position.x += sin(_clock * 0.6 + phase) * (0.1 if mode == 2 else 0.34)
				alpha = sin(cycle * PI) * (0.78 if mode == 2 else 0.4)
			multimesh.set_instance_transform(index,
				Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * sizes[index]), position))
			multimesh.set_instance_color(index, Color(tint.r, tint.g, tint.b, alpha))


func _prop(asset: String, origin: Vector3, height: float, tint: Color,
		sway: float = 0.0, parent: Node3D = null) -> Sprite3D:
	var sprite: Sprite3D = Sprite3D.new()
	sprite.name = asset.capitalize()
	sprite.position = origin
	sprite.pixel_size = height / 512.0
	# Prepared 384x512 props have their ground contact at source y ~= 480.
	sprite.offset = Vector2(0.0, 224.0)
	sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	# Background art carries its own light; only roadside props receive torchlight.
	sprite.shaded = origin.z > -3.5 and origin.z < 2.9
	sprite.double_sided = true
	sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISCARD
	sprite.alpha_scissor_threshold = 0.38
	sprite.modulate = tint
	sprite.flip_h = _rng.randf() < 0.5 and asset != "torch" and asset != "shrine"
	sprite.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sprite.visibility_range_end = 64.0
	_bind_texture(sprite, &"texture", asset)
	var target: Node3D = _vegetation if parent == null else parent
	target.add_child(sprite)
	if sway > 0.0:
		var level_x: float = origin.x + target.position.x
		_swaying.append({"node": sprite, "strength": sway,
			"phase": _rng.randf_range(0.0, TAU), "x": level_x})
	return sprite


func _arch(parent: Node3D, origin: Vector3, opening: float, pier_height: float,
		depth: float, material: Material, broken: bool = false) -> void:
	var arch: Node3D = _group("BrokenArch" if broken else "VoussoirArch", parent)
	arch.position = origin
	var radius: float = opening * 0.5
	var thickness: float = 0.48 if opening < 8.0 else 0.68
	for side: float in [-1.0, 1.0]:
		var x: float = side * (radius + thickness * 0.5)
		_box(arch, Vector3(x, pier_height * 0.5, 0.0),
			Vector3(thickness, pier_height, depth), material)
		_box(arch, Vector3(x, 0.14, 0.0), Vector3(thickness + 0.22, 0.28, depth + 0.2), material)
		_box(arch, Vector3(x, pier_height - 0.08, 0.0),
			Vector3(thickness + 0.18, 0.2, depth + 0.12), material)
	var count: int = 15
	var angle_step: float = PI / float(count)
	var key: String = "%s:%s:%s" % [radius, thickness, depth]
	var wedge: ArrayMesh = _arch_meshes.get(key) as ArrayMesh
	if wedge == null:
		wedge = _make_wedge(radius, radius + thickness, depth, angle_step * 0.48)
		_arch_meshes[key] = wedge
	for index: int in range(count):
		if broken and (index == 6 or index == 7 or index == 8):
			continue
		var stone: MeshInstance3D = _mesh(arch, wedge, material, Vector3(0.0, pier_height, 0.0))
		stone.rotation.z = (float(index) + 0.5) * angle_step
		if index * 2 == count - 1:
			stone.scale.z = 1.12


func _make_wedge(inner: float, outer: float, depth: float, half_angle: float) -> ArrayMesh:
	var a: float = -half_angle
	var b: float = half_angle
	var p0: Vector3 = Vector3(cos(a) * inner, sin(a) * inner, -depth * 0.5)
	var p1: Vector3 = Vector3(cos(a) * outer, sin(a) * outer, -depth * 0.5)
	var p2: Vector3 = Vector3(cos(b) * outer, sin(b) * outer, -depth * 0.5)
	var p3: Vector3 = Vector3(cos(b) * inner, sin(b) * inner, -depth * 0.5)
	var offset: Vector3 = Vector3(0.0, 0.0, depth)
	var tool: SurfaceTool = SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	_quad(tool, p0 + offset, p1 + offset, p2 + offset, p3 + offset)
	_quad(tool, p3, p2, p1, p0)
	_quad(tool, p1, p2, p2 + offset, p1 + offset)
	_quad(tool, p0, p0 + offset, p3 + offset, p3)
	_quad(tool, p0, p1, p1 + offset, p0 + offset)
	_quad(tool, p3, p3 + offset, p2 + offset, p2)
	return tool.commit()


func _quad(tool: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	var normal: Vector3 = (b - a).cross(c - a).normalized()
	var vertices: Array[Vector3] = [a, b, c, d]
	var uv: Array[Vector2] = [Vector2.ZERO, Vector2.RIGHT, Vector2.ONE, Vector2.DOWN]
	# Godot uses clockwise front faces; normals point outward independently.
	for index: int in [0, 2, 1, 0, 3, 2]:
		tool.set_normal(normal)
		tool.set_uv(uv[index])
		tool.add_vertex(vertices[index])


func _make_bell_mesh() -> ArrayMesh:
	var profile: PackedVector2Array = PackedVector2Array([
		Vector2(0.96, 0.0), Vector2(1.0, 0.08), Vector2(0.89, 0.18),
		Vector2(0.75, 0.38), Vector2(0.55, 0.69), Vector2(0.39, 1.03),
		Vector2(0.35, 1.20), Vector2(0.23, 1.31), Vector2(0.015, 1.34),
	])
	var tool: SurfaceTool = SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for row: int in range(profile.size() - 1):
		for segment: int in range(24):
			var a: float = float(segment) * TAU / 24.0
			var b: float = float(segment + 1) * TAU / 24.0
			var lower: Vector2 = profile[row]
			var upper: Vector2 = profile[row + 1]
			_quad(tool, Vector3(cos(a) * lower.x, lower.y, sin(a) * lower.x),
				Vector3(cos(a) * upper.x, upper.y, sin(a) * upper.x),
				Vector3(cos(b) * upper.x, upper.y, sin(b) * upper.x),
				Vector3(cos(b) * lower.x, lower.y, sin(b) * lower.x))
	return tool.commit()


func _make_hanging_bell(parent: Node3D, suspension: Vector3, scale_factor: float,
		animate: bool) -> Node3D:
	var bell: Node3D = _group("CastBronzeBell", parent)
	bell.position = suspension
	bell.scale = Vector3.ONE * scale_factor
	_mesh(bell, _bell_mesh, _bronze, Vector3(0.0, -1.48, 0.0))
	_torus(bell, Vector3(0.0, -1.42, 0.0), 0.91, 1.035, _bronze)
	_torus(bell, Vector3(0.0, -0.22, 0.0), 0.2, 0.24, _iron)
	_beam(bell, Vector3(0.0, -0.12, 0.0), Vector3(0.0, -1.56, 0.0), 0.055, _iron)
	_rock(bell, Vector3(0.0, -1.55, 0.0), Vector3(0.13, 0.15, 0.13), _iron)
	_torus(bell, Vector3(0.0, -1.02, 0.0), 0.68, 0.705, _iron)
	if animate:
		_hanging_bells.append(bell)
	return bell


func _mesh(parent: Node3D, mesh: Mesh, material: Material, position: Vector3) -> MeshInstance3D:
	var instance: MeshInstance3D = MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.position = position
	instance.visibility_range_end = 76.0
	parent.add_child(instance)
	return instance


func _box(parent: Node3D, position: Vector3, size: Vector3, material: Material) -> MeshInstance3D:
	# Shared world-triplanar surfaces avoid stretching on long beams/thin caps.
	var box: BoxMesh = BoxMesh.new()
	box.size = size
	return _mesh(parent, box, material, position)


func _floor_plane(parent: Node3D, position: Vector3, size: Vector2,
		material: Material) -> MeshInstance3D:
	var plane: PlaneMesh = PlaneMesh.new()
	plane.size = size
	var instance: MeshInstance3D = _mesh(parent, plane, material, position)
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return instance


func _wall_quad(parent: Node3D, position: Vector3, size: Vector2,
		material: Material, yaw: float = 0.0) -> void:
	var quad: QuadMesh = QuadMesh.new()
	quad.size = size
	var instance: MeshInstance3D = _mesh(parent, quad, material, position)
	instance.rotation.y = yaw


func _cylinder(parent: Node3D, position: Vector3, height: float, top_radius: float,
		bottom_radius: float, material: Material) -> MeshInstance3D:
	var cylinder: CylinderMesh = CylinderMesh.new()
	cylinder.height = height
	cylinder.top_radius = top_radius
	cylinder.bottom_radius = bottom_radius
	cylinder.radial_segments = 12
	cylinder.rings = 1
	return _mesh(parent, cylinder, material, position)


func _beam(parent: Node3D, from: Vector3, to: Vector3, radius: float,
		material: Material) -> MeshInstance3D:
	var displacement: Vector3 = to - from
	var instance: MeshInstance3D = _cylinder(parent, (from + to) * 0.5,
		displacement.length(), radius * 0.82, radius, material)
	instance.quaternion = Quaternion(Vector3.UP, displacement.normalized())
	return instance


func _rock(parent: Node3D, position: Vector3, scale_value: Vector3,
		material: Material) -> MeshInstance3D:
	var sphere: SphereMesh = SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 7
	sphere.rings = 3
	var instance: MeshInstance3D = _mesh(parent, sphere, material, position)
	instance.scale = scale_value
	return instance


func _torus(parent: Node3D, position: Vector3, inner: float, outer: float,
		material: Material, upright: bool = false) -> MeshInstance3D:
	var torus: TorusMesh = TorusMesh.new()
	torus.inner_radius = inner
	torus.outer_radius = outer
	torus.rings = 24
	torus.ring_segments = 6
	var instance: MeshInstance3D = _mesh(parent, torus, material, position)
	if upright:
		instance.rotation.x = PI * 0.5
	return instance


func _batch_box(label: String, position: Vector3, size: Vector3, material: Material,
		tint: Color = Color.WHITE, yaw: float = 0.0) -> void:
	if not _box_batches.has(label):
		_box_batches[label] = {"material": material, "transforms": [], "colors": []}
	var batch: Dictionary = _box_batches[label]
	var transforms: Array = batch["transforms"]
	var colors: Array = batch["colors"]
	var basis: Basis = Basis(Vector3.UP, yaw) * Basis.IDENTITY.scaled(size)
	transforms.append(Transform3D(basis, position))
	colors.append(tint)


func _flush_box_batches() -> void:
	for key: Variant in _box_batches:
		var batch: Dictionary = _box_batches[key]
		var transforms: Array = batch["transforms"]
		var colors: Array = batch["colors"]
		var cube: BoxMesh = BoxMesh.new()
		cube.size = Vector3.ONE
		var multimesh: MultiMesh = MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.use_colors = true
		multimesh.mesh = cube
		multimesh.instance_count = transforms.size()
		for index: int in range(transforms.size()):
			var transform: Transform3D = transforms[index]
			var color: Color = colors[index]
			multimesh.set_instance_transform(index, transform)
			multimesh.set_instance_color(index, color)
		var instance: MultiMeshInstance3D = MultiMeshInstance3D.new()
		instance.name = String(key)
		instance.multimesh = multimesh
		instance.material_override = batch["material"] as Material
		_terrain.add_child(instance)
	_box_batches.clear()