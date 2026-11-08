class_name NavGraph
extends RefCounted

## A* over the level's route nodes. The graph is deliberately tiny (13 nodes for the
## standard layout), so this exists to be honest about reachability, not to be fast: a
## monster that cannot route to a door is a bug we want to see in a probe, not one that
## shows up as "the hunter is standing in the corner again".

var _nodes: Array = []


## Takes LevelGenerator.nav_nodes() as-is: the graph only ever reads it.
func load_nodes(nodes: Array) -> void:
	_nodes = nodes


func is_empty() -> bool:
	return _nodes.is_empty()


func node_count() -> int:
	return _nodes.size()


func position_of(index: int) -> Vector3:
	if index < 0 or index >= _nodes.size():
		return Vector3.INF
	return _nodes[index]["pos"] as Vector3


func nearest(pos: Vector3) -> int:
	var best := -1
	var best_distance := INF
	for i in _nodes.size():
		var distance := position_of(i).distance_to(pos)
		if distance < best_distance:
			best_distance = distance
			best = i
	return best


## Walkable points from `from` to `to`: both endpoints plus the node chain between them.
## Empty means unreachable, which the caller must treat as "do not move", never as
## "walk in a straight line through the wall".
func path(from: Vector3, to: Vector3) -> PackedVector3Array:
	var empty := PackedVector3Array()
	if _nodes.is_empty():
		return empty
	var start := nearest(from)
	var goal := nearest(to)
	if start < 0 or goal < 0:
		return empty
	if start == goal:
		return PackedVector3Array([to])
	var came := {}
	var cost := {start: 0.0}
	var frontier: Array = [start]
	var found := false
	while not frontier.is_empty():
		var current := _cheapest(frontier, cost, goal)
		frontier.erase(current)
		if current == goal:
			found = true
			break
		for link in _nodes[current]["links"]:
			var next := int(link)
			var step := position_of(current).distance_to(position_of(next))
			var through := float(cost[current]) + step
			if not cost.has(next) or through < float(cost[next]):
				cost[next] = through
				came[next] = current
				if not frontier.has(next):
					frontier.append(next)
	if not found:
		return empty
	var chain := PackedVector3Array([from])
	var walk := goal
	var guard := 0
	while walk != start and guard <= _nodes.size():
		chain.insert(1, position_of(walk))
		if not came.has(walk):
			return empty
		walk = int(came[walk])
		guard += 1
	chain.append(to)
	return chain


func _cheapest(frontier: Array, cost: Dictionary, goal: int) -> int:
	var best := int(frontier[0])
	var best_score := INF
	for candidate in frontier:
		var index := int(candidate)
		var score := float(cost.get(index, INF)) + position_of(index).distance_to(position_of(goal))
		if score < best_score:
			best_score = score
			best = index
	return best
