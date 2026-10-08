extends RefCounted
## The walk polygon follows the open floor in the generated background.

const CELL := 24.0
const PLAYER_RADIUS := 15.0
const NPC_RADIUS := 27.0
const WALK_POINTS: Array[Vector2] = [
	Vector2(350, 360), Vector2(1215, 360), Vector2(1215, 562),
	Vector2(1510, 580), Vector2(1470, 668), Vector2(1250, 700),
	Vector2(1220, 956), Vector2(357, 956), Vector2(322, 710),
	Vector2(192, 658), Vector2(280, 527), Vector2(332, 453)
]

var walk_polygon := PackedVector2Array(WALK_POINTS)
var grid := AStarGrid2D.new()
var npc_positions: Array[Vector2] = []
var walkable_cells: Array[Vector2i] = []


func setup(positions: Array[Vector2]) -> void:
	npc_positions = positions.duplicate()
	grid.region = Rect2i(0, 0, 67, 42)
	grid.cell_size = Vector2(CELL, CELL)
	grid.offset = Vector2(CELL / 2.0, CELL / 2.0)
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	grid.update()
	walkable_cells.clear()
	for y in range(grid.region.size.y):
		for x in range(grid.region.size.x):
			var cell := Vector2i(x, y)
			var free: bool = is_walkable(grid.get_point_position(cell))
			grid.set_point_solid(cell, not free)
			if free:
				walkable_cells.append(cell)


func is_walkable(point: Vector2) -> bool:
	if not Geometry2D.is_point_in_polygon(point, walk_polygon):
		return false
	for index in range(8):
		var edge: Vector2 = point + Vector2.from_angle(index * TAU / 8.0) * PLAYER_RADIUS
		if not Geometry2D.is_point_in_polygon(edge, walk_polygon):
			return false
	for npc: Vector2 in npc_positions:
		if point.distance_to(npc) < NPC_RADIUS + PLAYER_RADIUS:
			return false
	return true


func slide_move(from: Vector2, motion: Vector2) -> Vector2:
	var result: Vector2 = from
	var steps: int = maxi(1, ceili(motion.length() / 6.0))
	var step: Vector2 = motion / float(steps)
	for _index in range(steps):
		if is_walkable(result + step):
			result += step
		else:
			var horizontal := Vector2(step.x, 0.0)
			if is_walkable(result + horizontal):
				result += horizontal
			var vertical := Vector2(0.0, step.y)
			if is_walkable(result + vertical):
				result += vertical
	return result


func find_path(from: Vector2, target: Vector2) -> PackedVector2Array:
	if walkable_cells.is_empty():
		return PackedVector2Array()
	var start: Vector2i = _nearest_cell(from)
	var finish: Vector2i = _nearest_cell(target)
	var raw: PackedVector2Array = grid.get_point_path(start, finish)
	if raw.is_empty():
		return raw
	# Keep the user's exact click when its final segment is safe.
	if is_walkable(target) and _line_is_clear(raw[raw.size() - 1], target):
		raw.append(target)
	var path := PackedVector2Array()
	var anchor: Vector2 = from
	var index: int = 0
	while index < raw.size():
		var furthest: int = index
		while furthest + 1 < raw.size() and _line_is_clear(anchor, raw[furthest + 1]):
			furthest += 1
		if anchor.distance_to(raw[furthest]) > 1.0:
			path.append(raw[furthest])
		anchor = raw[furthest]
		index = furthest + 1
	return path


func _nearest_cell(point: Vector2) -> Vector2i:
	var result: Vector2i = walkable_cells[0]
	var distance: float = INF
	for cell: Vector2i in walkable_cells:
		var candidate: float = grid.get_point_position(cell).distance_squared_to(point)
		if candidate < distance:
			distance = candidate
			result = cell
	return result


func _line_is_clear(from: Vector2, to: Vector2) -> bool:
	var steps: int = maxi(1, ceili(from.distance_to(to) / 6.0))
	for index in range(1, steps + 1):
		if not is_walkable(from.lerp(to, float(index) / float(steps))):
			return false
	return true