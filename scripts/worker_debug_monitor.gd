extends Node

# Debug monitor for the debug-worker-system branch.
# PASSIVE: it only reads game state. It never issues orders and never changes game state.
# Its buttons only copy/clear the monitor's own logs. F9 shows/hides the panel.
# All game variables are read through game.get(...), so a missing variable is skipped, never a crash.

const SAMPLE_INTERVAL := 1.0
const STALL_SECONDS := 8.0
const STALL_RADIUS := 12.0
const PATH_PENDING_SECONDS := 12.0
const ORPHAN_SITE_SECONDS := 10.0
const INSIDE_OBSTACLE_SECONDS := 3.0
const OVERLAP_SECONDS := 6.0
const CAPACITY_BLOCK_SECONDS := 10.0
const ECON_REPORT_SECONDS := 30.0
const LOW_FPS := 30.0
const HITCH_SECONDS := 0.1
const PATH_QUEUE_WARN := 20
const BUILDING_RADIUS := 34.0
const TREE_RADIUS := 26.0
const UNIT_SEPARATION := 18.0
const HARVEST_RANGE_GUESS := 42.0
const WHEEL_SINGLE_STEP_MAX := 1.2
const MAX_REPORT_LINES := 120
const MAX_COMMAND_LINES := 200
const HUD_IGNORE_RECT := Rect2(0.0, 0.0, 520.0, 280.0) # keep in sync with game.gd _input
const DEFAULT_PRICES := {"food": 1.0, "wood": 1.0, "stone": 1.5, "gold": 2.0} # ASSUMED prices
const LOG_PATH := "user://worker_debug.log"
const SNAPSHOT_PATH := "user://worker_debug_snapshot.txt"
const DEAD_REF_FIELDS := ["harvest_target_node", "storage_target", "build_target_site", "upgrade_target_building", "target"]
const FILTERED_ARRAYS := ["units", "buildings", "enemy_buildings", "selected"]
const UNFILTERED_ARRAYS := ["resource_nodes", "construction_sites", "storage_points"]

var game: Node = null
var elapsed := 0.0
var run_time := 0.0
var frame_max := 0.0
var snapshots: Dictionary = {}
var issue_active: Dictionary = {}
var issues_seen: Dictionary = {}
var throttle_times: Dictionary = {}
var report_lines: Array[String] = []
var command_lines: Array[String] = []

# economy / market
var last_resources: Dictionary = {}
var gains: Dictionary = {}
var econ_timer := 0.0
var market_recent := 0.0
var market_net_value := 0.0
var trade_count := 0

# buildings summary (refreshed every sample)
var type_counts: Dictionary = {}
var name_ok_counts: Dictionary = {}
var houses_l1 := 0
var houses_l2 := 0
var warehouses_l1 := 0
var warehouses_l2 := 0
var site_timers: Dictionary = {}

# capacity / population baselines
var base_pop_cap := -1
var base_storage := -1
var pop_cap_bad_samples := 0
var storage_bad_samples := 0
var pop_mismatch_samples := 0
var enemy_desync_samples := 0
var low_fps_samples := 0

# enemy
var prev_attack_active := false
var attack_started_at := 0.0
var attack_start_alive := 0
var enemy_report_timer := 0.0

# camera / input
var camera_idle_time := 0.0
var wheel_pending := false
var wheel_zoom_before := 1.0
var wheel_press_count := 0
var wheel_release_count := 0
var click_result_pending := false
var click_result_timer := 0.0
var active_touches: Dictionary = {}
var touch_down_count := 0
var emulated_mouse_count := 0
var mouse_press_count := 0

# misc counters
var peak_path_queue := 0
var path_fallback_total := 0
var training_props: Array[String] = []
var training_last: Dictionary = {}
var training_scanned := false

# ui
var layer: CanvasLayer
var panel: PanelContainer
var report_label: Label
var stats_label: Label
var copy_button: Button
var cmds_button: Button
var snapshot_button: Button

func _ready() -> void:
	game = get_parent()
	_build_panel()
	_report("INFO | Debug monitor started (passive). F9 toggles the panel.")

func _process(delta: float) -> void:
	if not is_instance_valid(game):
		return
	run_time += delta
	frame_max = maxf(frame_max, delta)
	_track_resources(delta)
	_finish_wheel_burst()
	if click_result_pending:
		click_result_timer -= delta
		if click_result_timer <= 0.0:
			click_result_pending = false
			_log_click_result()
	elapsed += delta
	if elapsed < SAMPLE_INTERVAL:
		return
	var dt := elapsed
	elapsed = 0.0
	_sample(dt)

func _sample(dt: float) -> void:
	issues_seen.clear()
	var workers := _alive_player_units()
	_check_workers(dt, workers)
	_check_buildings(dt)
	_check_population_and_capacity(workers)
	_check_economy(dt)
	_check_enemy(dt)
	_check_performance()
	_check_camera(dt, workers)
	_check_hiding(workers)
	_check_dangling_references()
	_check_path_queue()
	_watch_training()
	_update_stats(workers)
	# Forget issues whose condition no longer holds, so they can be reported again later.
	for key in issue_active.keys():
		if not issues_seen.has(key):
			issue_active.erase(key)
	frame_max = 0.0

# ---------------------------------------------------------------- workers

func _check_workers(dt: float, workers: Array) -> void:
	var alive_keys: Dictionary = {}
	var obstacles: Array = []
	for list_name in ["buildings", "enemy_buildings"]:
		var list = game.get(list_name)
		if list == null:
			continue
		for b in list:
			if is_instance_valid(b) and b.health > 0:
				obstacles.append(b)
	var trees = game.get("tree_positions")
	for worker in workers:
		var key := str(worker.get_instance_id())
		alive_keys[key] = true
		var snap: Dictionary = snapshots.get(key, {})
		var pos: Vector2 = worker.position
		var anchor: Vector2 = snap.get("anchor", pos)
		var anchor_age: float = float(snap.get("anchor_age", 0.0))
		var pending_time: float = float(snap.get("pending_time", 0.0))
		var task_idle: float = float(snap.get("task_idle", 0.0))
		var blocked_time: float = float(snap.get("blocked_time", 0.0))
		var inside_time: float = float(snap.get("inside_time", 0.0))
		var overlap_time: float = float(snap.get("overlap_time", 0.0))
		var sheltering: bool = worker.sheltered or worker.shelter_pending

		if sheltering:
			anchor = pos
			anchor_age = 0.0
			pending_time = 0.0
			task_idle = 0.0
			blocked_time = 0.0
			inside_time = 0.0
			overlap_time = 0.0
		else:
			# 1) movement stall / oscillation: marked moving but not leaving a small circle
			if worker.moving and not worker.path_pending:
				anchor_age += dt
				if pos.distance_to(anchor) > STALL_RADIUS:
					anchor = pos
					anchor_age = 0.0
				elif anchor_age >= STALL_SECONDS:
					_raise_worker(key, worker, "movement_stall", "Marked moving but stayed within %d px for %.0f s (blocked or oscillating)." % [int(STALL_RADIUS), anchor_age])
			else:
				anchor = pos
				anchor_age = 0.0

			# 2) path request pending too long
			if worker.path_pending:
				pending_time += dt
				if pending_time >= PATH_PENDING_SECONDS:
					_raise_worker(key, worker, "path_pending_timeout", "Path request pending for %.0f s." % pending_time)
			else:
				pending_time = 0.0

			# 3) suspected A* failure: a long move whose route is a single straight-line point
			if worker.moving and not worker.path_pending and worker.route.size() == 1:
				var single: Vector2 = worker.route[0]
				if pos.distance_to(single) > 240.0:
					var fb_key := key + ":path_fallback:" + _v2(single)
					if not issue_active.has(fb_key):
						path_fallback_total += 1
					_raise(fb_key, "path_fallback_suspected", "Worker %s | Long move (%d px) uses a single straight-line waypoint; A* probably gave up (node cap)." % [key, int(pos.distance_to(single))], _worker_details(worker))

			# 4) assigned task but standing far from the work spot
			var site_target = null
			if is_instance_valid(worker.build_target_site):
				site_target = worker.build_target_site
			elif is_instance_valid(worker.upgrade_target_building):
				site_target = worker.upgrade_target_building
			var task_stuck := false
			if site_target != null and not worker.moving and not worker.path_pending and pos.distance_to(worker.destination) > 16.0:
				task_stuck = true
			elif is_instance_valid(worker.harvest_target_node) and worker.storage_target == null and not worker.moving and not worker.path_pending and pos.distance_to(worker.harvest_target_node.position) > HARVEST_RANGE_GUESS:
				task_stuck = true
			if task_stuck:
				task_idle += dt
				if task_idle >= STALL_SECONDS:
					_raise_worker(key, worker, "task_without_progress", "Has a build/upgrade/harvest task but is idle and out of range for %.0f s." % task_idle)
			else:
				task_idle = 0.0

			# 5) dangling references held by the worker
			for field in DEAD_REF_FIELDS:
				if _is_dead_ref(worker.get(field)):
					_raise_worker(key, worker, "dead_reference_" + field, "Field %s points to a freed object." % field)
			var hn = worker.harvest_target_node
			if is_instance_valid(hn) and hn.amount <= 0:
				_raise_worker(key, worker, "depleted_harvest_target", "Still references a depleted resource node.")

			# 6) cargo with nothing to do (workers that are gathering/building are NOT idle)
			var has_task: bool = is_instance_valid(worker.harvest_target_node) or is_instance_valid(worker.build_target_site) or is_instance_valid(worker.upgrade_target_building) or is_instance_valid(worker.target)
			if worker.carried_amount > 0 and not has_task and worker.storage_target == null and not worker.storage_blocked_by_capacity and not worker.moving:
				_raise_worker(key, worker, "cargo_idle", "Has cargo but no task, no storage target and is not moving.")

			# 7) capacity-blocked workers
			if worker.storage_blocked_by_capacity and worker.carried_amount > 0:
				blocked_time += dt
				if _resource_total() < _geti("storage_capacity", 0):
					_raise_worker(key, worker, "blocked_storage_capacity_available", "Capacity-blocked although storage has room.")
				elif blocked_time >= CAPACITY_BLOCK_SECONDS:
					_raise_worker(key, worker, "capacity_blocked_waiting", "Waiting %.0f s with a full storage (stays blocked until reassigned)." % blocked_time)
			else:
				blocked_time = 0.0

			# 8) collision: standing inside a building / tree
			var inside_name := ""
			for b in obstacles:
				if pos.distance_to(b.position) < BUILDING_RADIUS - 4.0:
					inside_name = "building " + str(b.name)
					break
			if inside_name == "" and trees != null:
				for tp in trees:
					if pos.distance_to(tp) < TREE_RADIUS - 4.0:
						inside_name = "tree"
						break
			if inside_name != "":
				inside_time += dt
				if inside_time >= INSIDE_OBSTACLE_SECONDS:
					_raise_worker(key, worker, "inside_obstacle", "Inside %s for %.0f s; push-out collision is not resolving." % [inside_name, inside_time])
			else:
				inside_time = 0.0

			# 9) collision: two idle units stacked on each other
			var overlapped := false
			if not worker.moving:
				for other in workers:
					if other != worker and not other.sheltered and pos.distance_to(other.position) < UNIT_SEPARATION * 0.5:
						overlapped = true
						break
			if overlapped:
				overlap_time += dt
				if overlap_time >= OVERLAP_SECONDS:
					_raise_worker(key, worker, "unit_overlap", "Overlapping another idle unit for %.0f s." % overlap_time)
			else:
				overlap_time = 0.0

		snapshots[key] = {"anchor": anchor, "anchor_age": anchor_age, "pending_time": pending_time, "task_idle": task_idle, "blocked_time": blocked_time, "inside_time": inside_time, "overlap_time": overlap_time}
	for key in snapshots.keys():
		if not alive_keys.has(key):
			snapshots.erase(key)

# ---------------------------------------------------------------- buildings (names, abandoned sites)

func _check_buildings(dt: float) -> void:
	type_counts.clear()
	name_ok_counts.clear()
	houses_l1 = 0
	houses_l2 = 0
	warehouses_l1 = 0
	warehouses_l2 = 0
	var new_timers: Dictionary = {}
	var buildings = game.get("buildings")
	var units = game.get("units")
	if buildings == null or units == null:
		return
	for b in buildings:
		if not is_instance_valid(b) or b.health <= 0:
			continue
		var btype: String = str(b.building_type)
		var bname: String = str(b.name)
		var bid: int = b.get_instance_id()
		# Name mismatch: code comparing b.name == "Farm" ignores renamed duplicates.
		if btype != "" and bname != btype:
			_raise("bldg:%d:name" % bid, "building_name_mismatch", "Building node name '%s' differs from building_type '%s'. Code that compares b.name (income, recruiting) will ignore it." % [bname, btype], "pos=%s complete=%s" % [_v2(b.position), str(b.is_complete)])
		if b.is_complete:
			type_counts[btype] = int(type_counts.get(btype, 0)) + 1
			if bname == btype:
				name_ok_counts[btype] = int(name_ok_counts.get(btype, 0)) + 1
			var level: int = int(b.building_upgrade_level)
			if btype == "House":
				if level >= 2:
					houses_l2 += 1
				else:
					houses_l1 += 1
			elif btype == "Warehouse":
				if level >= 2:
					warehouses_l2 += 1
				else:
					warehouses_l1 += 1
			if bool(b.get("is_upgrading")):
				var up_workers: int = int(b.get_upgrade_active_worker_count())
				var up_key := "%d:upgrade" % bid
				if up_workers == 0:
					var t_up: float = float(site_timers.get(up_key, 0.0)) + dt
					new_timers[up_key] = t_up
					if t_up >= ORPHAN_SITE_SECONDS:
						_raise("bldg:%d:orphan_upgrade" % bid, "orphan_upgrade", "%s upgrade has had no worker for %.0f s." % [btype, t_up], "pos=%s" % _v2(b.position))
		else:
			var builders := 0
			for u in units:
				if is_instance_valid(u) and u.build_target_site == b:
					builders += 1
			var build_key := "%d:build" % bid
			if builders == 0:
				var t_build: float = float(site_timers.get(build_key, 0.0)) + dt
				new_timers[build_key] = t_build
				if t_build >= ORPHAN_SITE_SECONDS:
					_raise("bldg:%d:orphan_site" % bid, "orphan_construction_site", "%s construction site has had no builder for %.0f s." % [btype, t_build], "pos=%s" % _v2(b.position))
	site_timers = new_timers

# ---------------------------------------------------------------- population & capacity

func _check_population_and_capacity(workers: Array) -> void:
	var pop := _geti("population", -1)
	var cap := _geti("population_cap", -1)
	var storage := _geti("storage_capacity", -1)
	if base_pop_cap < 0 and cap >= 0:
		base_pop_cap = cap - (houses_l1 * 5 + houses_l2 * 8)
	if base_storage < 0 and storage >= 0:
		base_storage = storage - (warehouses_l1 * 1000 + warehouses_l2 * 2000)
	if pop >= 0 and cap >= 0:
		if pop > cap:
			_raise("game:pop_over_cap", "population_over_cap", "population=%d exceeds population_cap=%d (training/recruiting overflow)." % [pop, cap])
		if pop != workers.size():
			pop_mismatch_samples += 1
		else:
			pop_mismatch_samples = 0
		if pop_mismatch_samples >= 2:
			_raise("game:pop_mismatch", "population_mismatch", "population=%d but %d living player units exist." % [pop, workers.size()])
		var expected_cap := base_pop_cap + houses_l1 * 5 + houses_l2 * 8
		if cap != expected_cap:
			pop_cap_bad_samples += 1
		else:
			pop_cap_bad_samples = 0
		if pop_cap_bad_samples >= 2:
			_raise("game:pop_cap_mismatch", "population_cap_mismatch", "population_cap=%d but live completed houses imply %d (L1 houses=%d, L2 houses=%d). Cancel/demolish/destroy/upgrade accounting may be off." % [cap, expected_cap, houses_l1, houses_l2])
	if storage >= 0:
		var expected_storage := base_storage + warehouses_l1 * 1000 + warehouses_l2 * 2000
		if storage != expected_storage:
			storage_bad_samples += 1
		else:
			storage_bad_samples = 0
		if storage_bad_samples >= 2:
			_raise("game:storage_mismatch", "storage_capacity_mismatch", "storage_capacity=%d but live warehouses imply %d (L1=%d, L2=%d)." % [storage, expected_storage, warehouses_l1, warehouses_l2])
		if _resource_total() > storage:
			_raise("game:over_capacity", "resources_over_capacity", "Total resources %d exceed storage_capacity %d." % [_resource_total(), storage])

# ---------------------------------------------------------------- economy & market

func _price(res_name: String) -> float:
	var prices = game.get("market_prices")
	if typeof(prices) == TYPE_DICTIONARY and prices.has(res_name):
		return float(prices[res_name])
	return float(DEFAULT_PRICES.get(res_name, 1.0))

func _track_resources(delta: float) -> void:
	if _getb("market_window_open"):
		market_recent = 1.0
	else:
		market_recent = maxf(0.0, market_recent - delta)
	var res = game.get("resources")
	if typeof(res) != TYPE_DICTIONARY:
		return
	var up_value := 0.0
	var down_value := 0.0
	for key in res.keys():
		var now_amount: int = int(res[key])
		var prev_amount: int = int(last_resources.get(key, now_amount))
		var diff: int = now_amount - prev_amount
		if diff > 0:
			up_value += float(diff) * _price(str(key))
			gains[key] = int(gains.get(key, 0)) + diff
		elif diff < 0:
			down_value += float(-diff) * _price(str(key))
		last_resources[key] = now_amount
	# A trade = one resource goes up and another goes down in the same frame while the market is open.
	if market_recent > 0.0 and up_value > 0.0 and down_value > 0.0:
		trade_count += 1
		market_net_value += up_value - down_value
		var ratio := up_value / down_value
		_report("INFO | market trade | value out=%.1f in=%.1f ratio=%.2f | resources=%s" % [down_value, up_value, ratio, str(res)])
		if ratio > 1.05:
			_report("WARNING | market_value_gain | Trade returned %.0f%% more value than it cost (prices assumed: %s). Possible exploit loop; could also be a worker delivery in the same frame." % [(ratio - 1.0) * 100.0, str(DEFAULT_PRICES)])

func _check_economy(dt: float) -> void:
	econ_timer += dt
	if econ_timer < ECON_REPORT_SECONDS:
		return
	var window := econ_timer
	econ_timer = 0.0
	var parts: Array[String] = []
	for res_name in ["food", "wood", "stone", "gold"]:
		parts.append("%s=%.1f/s" % [res_name, float(gains.get(res_name, 0)) / window])
	var farms: int = int(type_counts.get("Farm", 0))
	var farms_named: int = int(name_ok_counts.get("Farm", 0))
	_report("INFO | economy | gains %s | farms=%d (name_ok=%d) lumber=%d mill=%d quarry=%d gold_mine=%d | market trades=%d net_value=%+.0f | %s" % [", ".join(parts), farms, farms_named, int(type_counts.get("Lumber Mill", 0)), int(type_counts.get("Mill", 0)), int(type_counts.get("Quarry", 0)), int(type_counts.get("Gold Mine", 0)), trade_count, market_net_value, _perf_summary()])
	if farms > 0 and int(gains.get("food", 0)) == 0:
		_raise("game:farm_no_income", "farm_no_income", "%d completed farm(s) but no food gain in the last %.0f s." % [farms, window])
	if farms > farms_named:
		_raise("game:farm_name_income", "farm_income_ignores_renamed", "%d of %d farms have a different node name, so name-based income skips them." % [farms - farms_named, farms])
	gains.clear()

# ---------------------------------------------------------------- enemy

func _check_enemy(dt: float) -> void:
	var enemy_pop := _geti("enemy_population", -1)
	var alive := _count_alive_units(1)
	var active := _getb("enemy_attack_active")
	var group = game.get("enemy_attack_group")
	var group_size := 0
	if group != null:
		group_size = group.size()
	if active and not prev_attack_active:
		attack_started_at = run_time
		attack_start_alive = alive
		_report("INFO | enemy attack started | squad=%d enemy_alive=%d enemy_population=%d player_units=%d" % [group_size, alive, enemy_pop, _count_alive_units(0)])
	elif prev_attack_active and not active:
		_report("INFO | enemy attack ended | duration=%.0fs enemy_alive=%d (was %d) player_units=%d" % [run_time - attack_started_at, alive, attack_start_alive, _count_alive_units(0)])
	prev_attack_active = active
	if enemy_pop >= 0 and enemy_pop - alive >= 2:
		enemy_desync_samples += 1
	else:
		enemy_desync_samples = 0
	if enemy_desync_samples >= 2:
		_raise("game:enemy_pop_desync", "enemy_population_desync", "enemy_population=%d but only %d enemy units are alive (counter is probably never decremented, so recruiting stalls)." % [enemy_pop, alive])
	enemy_report_timer += dt
	if enemy_report_timer >= ECON_REPORT_SECONDS:
		enemy_report_timer = 0.0
		var eb = game.get("enemy_buildings")
		var eb_count := 0
		if eb != null:
			eb_count = eb.size()
		_report("INFO | enemy | enabled=%s population=%d/%d alive=%d resources=%s buildings=%d attack_active=%s" % [str(game.get("enemy_enabled")), enemy_pop, _geti("enemy_population_cap", -1), alive, str(game.get("enemy_resources")), eb_count, str(active)])

# ---------------------------------------------------------------- performance & path queue

func _perf_summary() -> String:
	return "fps=%.0f process=%.1fms nodes=%d orphans=%d objects=%d" % [
		Performance.get_monitor(Performance.TIME_FPS),
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_COUNT))]

func _check_performance() -> void:
	var fps: float = Performance.get_monitor(Performance.TIME_FPS)
	var orphans: int = int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	if fps < LOW_FPS:
		low_fps_samples += 1
	else:
		low_fps_samples = 0
	if low_fps_samples >= 3:
		_raise("game:low_fps", "low_fps", "FPS below %.0f for %d samples." % [LOW_FPS, low_fps_samples], _perf_summary())
	if frame_max >= HITCH_SECONDS:
		_raise("game:hitch:%d" % int(run_time), "frame_hitch", "Longest frame in the last second was %.0f ms." % (frame_max * 1000.0), _perf_summary())
	if orphans > 10:
		_raise("game:orphans", "orphan_nodes", "%d orphan nodes (created but never added to the tree / not freed)." % orphans)

func _check_path_queue() -> void:
	var q = game.get("pathfinding_queue")
	if q == null:
		return
	var n: int = q.size()
	peak_path_queue = maxi(peak_path_queue, n)
	if n >= PATH_QUEUE_WARN:
		_raise("game:path_queue", "path_queue_backlog", "Pathfinding queue holds %d requests (peak %d)." % [n, peak_path_queue])

# ---------------------------------------------------------------- camera

func _zoom() -> float:
	var z = game.get("zoom_level")
	if typeof(z) == TYPE_FLOAT or typeof(z) == TYPE_INT:
		return float(z)
	return 1.0

func _check_camera(dt: float, workers: Array) -> void:
	var cam = game.get("camera_offset")
	if typeof(cam) != TYPE_VECTOR2:
		return
	var cam_offset: Vector2 = cam
	var zoom := _zoom()
	if zoom <= 0.01:
		_raise("game:bad_zoom", "bad_zoom", "zoom_level=%.4f is not usable." % zoom)
		return
	var vp: Vector2 = get_viewport().get_visible_rect().size
	var top_left: Vector2 = (Vector2.ZERO - cam_offset) / zoom
	var bottom_right: Vector2 = (vp - cam_offset) / zoom
	var view := Rect2(top_left, bottom_right - top_left)
	var tc = _find_town_center()
	if run_time < 20.0 and tc != null and not view.has_point(tc.position):
		_raise("game:camera_start", "camera_start_view", "Town Center is outside the initial view (view=%s tc=%s): the player starts without seeing the base." % [str(view), _v2(tc.position)])
	var visible_any := false
	for u in workers:
		if view.has_point(u.position):
			visible_any = true
			break
	var buildings = game.get("buildings")
	var bounds := Rect2()
	var bounds_set := false
	for list_name in ["buildings", "enemy_buildings"]:
		var list = game.get(list_name)
		if list == null:
			continue
		for b in list:
			if not is_instance_valid(b):
				continue
			if not bounds_set:
				bounds = Rect2(b.position, Vector2.ZERO)
				bounds_set = true
			else:
				bounds = bounds.expand(b.position)
			if list_name == "buildings" and view.has_point(b.position):
				visible_any = true
	if visible_any:
		camera_idle_time = 0.0
	else:
		camera_idle_time += dt
		if camera_idle_time >= 30.0:
			_raise("game:camera_lost", "camera_sees_nothing", "No friendly unit or building in view for %.0f s." % camera_idle_time)
	if bounds_set and not view.intersects(bounds.grow(800.0)):
		_raise("game:camera_outside", "camera_outside_map", "View is far from every building (approximate map bounds).", "view=%s bounds=%s" % [str(view), str(bounds)])

func _finish_wheel_burst() -> void:
	if not wheel_pending:
		return
	wheel_pending = false
	var after := _zoom()
	var ratio := after / maxf(wheel_zoom_before, 0.0001)
	_log_command("ZOOM | wheel events pressed=%d released=%d | zoom %.3f -> %.3f (x%.3f)" % [wheel_press_count, wheel_release_count, wheel_zoom_before, after, ratio], false)
	if wheel_press_count == 1 and wheel_release_count >= 1 and absf(ratio - 1.0) > 0.0001 and (ratio > WHEEL_SINGLE_STEP_MAX or ratio < 1.0 / WHEEL_SINGLE_STEP_MAX):
		_report_throttled("wheel_double", "WARNING | zoom_double_step | One wheel notch (press+release) changed zoom by x%.3f; the handler probably reacts to both press and release." % ratio, 10.0)
	wheel_press_count = 0
	wheel_release_count = 0

# ---------------------------------------------------------------- hiding / shelter

func _check_hiding(workers: Array) -> void:
	var tc = _find_town_center()
	var sheltered_count := 0
	var hidden_unsheltered := 0
	for u in workers:
		if u.sheltered:
			sheltered_count += 1
		elif not u.visible:
			hidden_unsheltered += 1
	var recalled := _getb("workers_recalled")
	if sheltered_count > 0 and tc == null:
		_raise("game:shelter_no_tc", "sheltered_without_town_center", "%d unit(s) sheltered but no live Town Center exists." % sheltered_count)
	if recalled and tc == null:
		_raise("game:recall_no_tc", "recall_without_town_center", "Recall is active but no live Town Center exists.")
	if hidden_unsheltered > 0:
		_raise("game:invisible_unit", "invisible_unit_not_sheltered", "%d unit(s) invisible but not marked sheltered." % hidden_unsheltered)
	if sheltered_count > 0 and not recalled:
		_raise("game:sheltered_recall_off", "sheltered_but_recall_off", "%d unit(s) still hidden while recall is off." % sheltered_count)

# ---------------------------------------------------------------- dangling references

func _check_dangling_references() -> void:
	for arr_name in FILTERED_ARRAYS:
		var arr = game.get(arr_name)
		if arr == null:
			continue
		var dead := 0
		for x in arr:
			if _is_dead_ref(x):
				dead += 1
		if dead > 0:
			_raise("game:dead_" + arr_name, "dead_entries_" + arr_name, "%d freed object(s) remain in game.%s after the game's own cleanup." % [dead, arr_name])
	for arr_name in UNFILTERED_ARRAYS:
		var arr = game.get(arr_name)
		if arr == null:
			continue
		var dead := 0
		for x in arr:
			if _is_dead_ref(x):
				dead += 1
		if dead >= 30:
			_raise("game:stale_" + arr_name, "stale_entries_growing_" + arr_name, "%d freed objects accumulate in game.%s (never cleaned)." % [dead, arr_name])
	var sb = game.get("selected_building")
	if _is_dead_ref(sb) or (typeof(sb) == TYPE_OBJECT and is_instance_valid(sb) and sb.health <= 0):
		_raise("game:sel_building_dead", "selected_building_dead", "selected_building points to a destroyed/freed building.")
	var sf = game.get("selected_frame")
	if typeof(sf) == TYPE_OBJECT and is_instance_valid(sf) and sf.visible and sb == null and _selected_count() == 0:
		_raise("game:stale_frame", "stale_selection_frame", "Selection frame is still visible but nothing is selected.")

func _is_dead_ref(v) -> bool:
	return typeof(v) == TYPE_OBJECT and not is_instance_valid(v)

# ---------------------------------------------------------------- training watcher

func _watch_training() -> void:
	if not training_scanned:
		training_scanned = true
		for p in game.get_property_list():
			if (int(p.usage) & PROPERTY_USAGE_SCRIPT_VARIABLE) != 0 and str(p.name).to_lower().contains("train"):
				training_props.append(str(p.name))
		_report("INFO | training watcher | variables: %s" % (", ".join(training_props) if training_props.size() > 0 else "none containing 'train' found in game.gd"))
	for pname in training_props:
		var v = game.get(pname)
		var s := str(v)
		if typeof(v) == TYPE_FLOAT:
			s = "active" if float(v) > 0.0 else "idle"
		if training_last.has(pname) and training_last[pname] != s:
			_report("INFO | training | %s: %s -> %s | population=%d/%d" % [pname, str(training_last[pname]), s, _geti("population", -1), _geti("population_cap", -1)])
		training_last[pname] = s

# ---------------------------------------------------------------- input & command log

func _input(event: InputEvent) -> void:
	if not is_instance_valid(game):
		return
	if event is InputEventKey:
		if event.pressed and not event.echo:
			if event.keycode == KEY_F9 and is_instance_valid(panel):
				panel.visible = not panel.visible
			elif event.keycode == KEY_ESCAPE:
				_log_command("KEY | ESC | placing=%s selected=%d" % [str(game.get("placing_building")), _selected_count()])
	elif event is InputEventMouseButton:
		_on_mouse_button(event)
	elif event is InputEventScreenTouch:
		_on_touch(event)

func _on_mouse_button(event: InputEventMouseButton) -> void:
	var emulated: bool = event.device == InputEvent.DEVICE_ID_EMULATION
	if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		if not wheel_pending:
			wheel_pending = true
			wheel_zoom_before = _zoom()
			wheel_press_count = 0
			wheel_release_count = 0
		if event.pressed:
			wheel_press_count += 1
		else:
			wheel_release_count += 1
		return
	if emulated:
		emulated_mouse_count += 1
	if not event.pressed:
		return
	mouse_press_count += 1
	var button_name: String = str(event.button_index)
	if event.button_index == MOUSE_BUTTON_LEFT:
		button_name = "LEFT"
	elif event.button_index == MOUSE_BUTTON_RIGHT:
		button_name = "RIGHT"
	_log_pointer("MOUSE " + button_name + (" (emulated from touch)" if emulated else ""), event.position)

func _on_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		active_touches[event.index] = event.position
		touch_down_count += 1
		_log_pointer("TOUCH finger=%d" % event.index, event.position)
		if active_touches.size() >= 2:
			_report_throttled("multitouch", "WARNING | multi_touch | %d fingers down. The game has no multi-touch/pinch handling; an extra finger can reset tap or pan state." % active_touches.size(), 3.0)
	else:
		active_touches.erase(event.index)

func _log_pointer(label: String, pos: Vector2) -> void:
	var ui_name := _ui_button_at(pos)
	var in_ignored := HUD_IGNORE_RECT.has_point(pos)
	var motivation = game.get("motivation_panel")
	var swallowed: bool = _getb("market_window_open") or (typeof(motivation) == TYPE_OBJECT and is_instance_valid(motivation))
	_log_command("%s | screen=%s world=%s | selected=%d | sel_building=%s | placing=%s | ui=%s" % [label, _v2(pos), _v2(_screen_to_world(pos)), _selected_count(), _selected_building_name(), str(game.get("placing_building")), ui_name if ui_name != "" else "-"])
	if ui_name != "" and not in_ignored and not swallowed:
		_report_throttled("ui_leak:" + ui_name, "WARNING | ui_click_may_leak | Click on button '%s' at %s is outside the game's ignored HUD rect (x<520, y<280); game.gd _input may also treat it as a map click (move order or deselect). Placement confirm buttons can be a false positive." % [ui_name, _v2(pos)], 5.0)

func _log_command(text: String, arm_result: bool = true) -> void:
	var line := "t=%.1fs | %s" % [run_time, text]
	command_lines.push_front(line)
	if command_lines.size() > MAX_COMMAND_LINES:
		command_lines.resize(MAX_COMMAND_LINES)
	_append_to_file("CMD | " + line)
	if arm_result:
		click_result_pending = true
		click_result_timer = 0.25

func _log_click_result() -> void:
	var selected = game.get("selected")
	if selected == null:
		return
	var counts: Dictionary = {}
	for u in selected:
		if is_instance_valid(u):
			var t := _task_summary(u)
			counts[t] = int(counts.get(t, 0)) + 1
	_log_command("RESULT | selected=%d tasks=%s" % [selected.size(), str(counts)], false)

func _ui_button_at(pos: Vector2) -> String:
	var roots: Array = []
	var hud = game.get("hud")
	if typeof(hud) == TYPE_OBJECT and is_instance_valid(hud):
		roots.append(hud)
	if is_instance_valid(layer):
		roots.append(layer)
	for root in roots:
		var found := _find_button(root, pos)
		if found != "":
			return found
	return ""

func _find_button(node: Node, pos: Vector2) -> String:
	for child in node.get_children():
		if child is Control:
			if not child.is_visible_in_tree():
				continue
			if child is BaseButton and child.get_global_rect().has_point(pos):
				return "%s:%s" % [str(child.name), str(child.get("text"))]
		var deeper := _find_button(child, pos)
		if deeper != "":
			return deeper
	return ""

# ---------------------------------------------------------------- helpers

func _alive_player_units() -> Array:
	var result: Array = []
	var units = game.get("units")
	if units == null:
		return result
	for u in units:
		if is_instance_valid(u) and u.team == 0 and u.health > 0:
			result.append(u)
	return result

func _count_alive_units(team_id: int) -> int:
	var count := 0
	var units = game.get("units")
	if units == null:
		return 0
	for u in units:
		if is_instance_valid(u) and u.team == team_id and u.health > 0:
			count += 1
	return count

func _find_town_center() -> Node:
	var buildings = game.get("buildings")
	if buildings == null:
		return null
	for b in buildings:
		if is_instance_valid(b) and b.health > 0 and (str(b.building_type) == "Town Center" or str(b.name) == "Town Center"):
			return b
	return null

func _selected_count() -> int:
	var s = game.get("selected")
	if s == null:
		return 0
	return s.size()

func _selected_building_name() -> String:
	var sb = game.get("selected_building")
	if typeof(sb) == TYPE_OBJECT and is_instance_valid(sb):
		return str(sb.name)
	return "-"

func _resource_total() -> int:
	var res = game.get("resources")
	var total := 0
	if typeof(res) == TYPE_DICTIONARY:
		for amount in res.values():
			total += int(amount)
	return total

func _geti(var_name: String, default_value: int) -> int:
	var v = game.get(var_name)
	if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
		return int(v)
	return default_value

func _getb(var_name: String) -> bool:
	var v = game.get(var_name)
	return typeof(v) == TYPE_BOOL and v

func _screen_to_world(pos: Vector2) -> Vector2:
	if game.has_method("screen_to_world"):
		var w = game.screen_to_world(pos)
		if typeof(w) == TYPE_VECTOR2:
			return w
	return Vector2.ZERO

func _v2(v: Vector2) -> String:
	return "(%d,%d)" % [int(v.x), int(v.y)]

func _task_summary(worker: Node) -> String:
	if worker.sheltered: return "sheltered"
	if worker.shelter_pending: return "sheltering"
	if is_instance_valid(worker.storage_target): return "delivering"
	if is_instance_valid(worker.harvest_target_node): return "gathering"
	if is_instance_valid(worker.build_target_site): return "building"
	if is_instance_valid(worker.upgrade_target_building): return "upgrading"
	if is_instance_valid(worker.target): return "combat"
	if worker.moving: return "moving"
	return "idle"

func _worker_details(worker: Node) -> String:
	return "pos=%s dest=%s route=%d/%d moving=%s pending=%s cargo=%d/%d task=%s stuck_replans=%s" % [_v2(worker.position), _v2(worker.destination), int(worker.route_index), worker.route.size(), str(worker.moving), str(worker.path_pending), worker.carried_amount, worker.cargo_capacity, _task_summary(worker), str(worker.get("stuck_replans"))]

# ---------------------------------------------------------------- reporting

func _raise_worker(worker_key: String, worker: Node, issue: String, message: String) -> void:
	_raise(worker_key + ":" + issue, issue, "Worker %s | %s" % [worker_key, message], _worker_details(worker))

func _raise(issue_key: String, issue: String, message: String, extra: String = "") -> void:
	issues_seen[issue_key] = true
	if issue_active.has(issue_key):
		return
	issue_active[issue_key] = true
	_report("WARNING | %s | %s%s" % [issue, message, ("" if extra == "" else " | " + extra)])

func _report_throttled(key: String, message: String, seconds: float) -> void:
	var last: float = float(throttle_times.get(key, -1000.0))
	if run_time - last < seconds:
		return
	throttle_times[key] = run_time
	_report(message)

func _report(message: String) -> void:
	var line := "%s | t=%.0fs | %s" % [Time.get_datetime_string_from_system(), run_time, message]
	report_lines.push_front(line)
	if report_lines.size() > MAX_REPORT_LINES:
		report_lines.resize(MAX_REPORT_LINES)
	if is_instance_valid(report_label):
		report_label.text = "\n".join(report_lines)
	print(line)
	_append_to_file(line)

func _append_to_file(line: String) -> void:
	var file := FileAccess.open(LOG_PATH, FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open(LOG_PATH, FileAccess.WRITE)
	if file != null:
		file.seek_end()
		file.store_line(line)
		file.close()

func _update_stats(workers: Array) -> void:
	if not is_instance_valid(stats_label):
		return
	stats_label.text = "FPS %.0f | pop %d/%d | units %d | enemy %d | issues %d | pathQ %d | cmds %d" % [Performance.get_monitor(Performance.TIME_FPS), _geti("population", -1), _geti("population_cap", -1), workers.size(), _count_alive_units(1), issue_active.size(), peak_path_queue, command_lines.size()]

# ---------------------------------------------------------------- snapshot

func _build_snapshot() -> String:
	var lines: Array[String] = []
	lines.append("=== SNAPSHOT t=%.1fs %s ===" % [run_time, Time.get_datetime_string_from_system()])
	lines.append("resources=%s total=%d storage_capacity=%d" % [str(game.get("resources")), _resource_total(), _geti("storage_capacity", -1)])
	lines.append("population=%d/%d | player_units=%d | enemy_units=%d | enemy_population=%d/%d | enemy_enabled=%s | attack_active=%s" % [_geti("population", -1), _geti("population_cap", -1), _count_alive_units(0), _count_alive_units(1), _geti("enemy_population", -1), _geti("enemy_population_cap", -1), str(game.get("enemy_enabled")), str(_getb("enemy_attack_active"))])
	lines.append("enemy_resources=%s" % str(game.get("enemy_resources")))
	lines.append("camera_offset=%s zoom=%.3f" % [str(game.get("camera_offset")), _zoom()])
	lines.append("perf: " + _perf_summary())
	lines.append("path queue peak=%d fallbacks_suspected=%d | input: mouse_press=%d touch_down=%d emulated_mouse=%d | market trades=%d net_value=%+.1f" % [peak_path_queue, path_fallback_total, mouse_press_count, touch_down_count, emulated_mouse_count, trade_count, market_net_value])
	var units = game.get("units")
	lines.append("--- PLAYER BUILDINGS ---")
	var buildings = game.get("buildings")
	if buildings != null and units != null:
		for b in buildings:
			if not is_instance_valid(b):
				lines.append("(freed building reference)")
				continue
			var builders := 0
			for u in units:
				if is_instance_valid(u) and (u.build_target_site == b or u.upgrade_target_building == b):
					builders += 1
			lines.append("%s | type=%s | L%d | complete=%s | upgrading=%s | hp=%d | pos=%s | workers=%d" % [str(b.name), str(b.building_type), int(b.building_upgrade_level), str(b.is_complete), str(b.get("is_upgrading")), int(b.health), _v2(b.position), builders])
	var enemy_buildings = game.get("enemy_buildings")
	var enemy_count := 0
	if enemy_buildings != null:
		enemy_count = enemy_buildings.size()
	lines.append("--- ENEMY BUILDINGS (%d) ---" % enemy_count)
	if enemy_buildings != null:
		for b in enemy_buildings:
			if is_instance_valid(b):
				lines.append("%s | hp=%d | pos=%s" % [str(b.name), int(b.health), _v2(b.position)])
	var workers := _alive_player_units()
	lines.append("--- PLAYER UNITS (%d, max 80 listed) ---" % workers.size())
	var listed := 0
	for u in workers:
		if listed >= 80:
			break
		listed += 1
		lines.append("%s | hp=%d | sheltered=%s | %s" % [str(u.get_instance_id()), int(u.health), str(u.sheltered), _worker_details(u)])
	lines.append("--- ACTIVE ISSUES (%d) ---" % issue_active.size())
	for key in issue_active.keys():
		lines.append(str(key))
	lines.append("--- RECENT REPORTS (newest first) ---")
	for i in range(mini(25, report_lines.size())):
		lines.append(report_lines[i])
	lines.append("--- RECENT COMMANDS (newest first) ---")
	for i in range(mini(40, command_lines.size())):
		lines.append(command_lines[i])
	return "\n".join(lines)

# ---------------------------------------------------------------- panel

func _on_copy_log_pressed() -> void:
	var text := "Worker Debug log is empty."
	if not report_lines.is_empty():
		text = "\n".join(report_lines)
	_copy_with_feedback(text, copy_button, "Copy Log")

func _on_copy_cmds_pressed() -> void:
	var text := "Command log is empty."
	if not command_lines.is_empty():
		text = "\n".join(command_lines)
	_copy_with_feedback(text, cmds_button, "Cmds")

func _on_snapshot_pressed() -> void:
	var text := _build_snapshot()
	var file := FileAccess.open(SNAPSHOT_PATH, FileAccess.WRITE)
	if file != null:
		file.store_string(text)
		file.close()
	_report("INFO | snapshot copied to clipboard (%d characters)" % text.length())
	_copy_with_feedback(text, snapshot_button, "Snapshot")

func _on_clear_pressed() -> void:
	report_lines.clear()
	command_lines.clear()
	issue_active.clear()
	if is_instance_valid(report_label):
		report_label.text = ""

func _copy_with_feedback(text: String, button: Button, original: String) -> void:
	DisplayServer.clipboard_set(text)
	if is_instance_valid(button):
		button.text = "Copied!"
		await get_tree().create_timer(1.5, true).timeout
		if is_instance_valid(button):
			button.text = original

func _build_panel() -> void:
	layer = CanvasLayer.new()
	layer.name = "WorkerDebugLayer"
	layer.layer = 100
	layer.process_mode = Node.PROCESS_MODE_ALWAYS # buttons keep working while the game is paused
	add_child(layer)
	panel = PanelContainer.new()
	panel.name = "WorkerDebugPanel"
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.position = Vector2(-420, 12)
	panel.size = Vector2(408, 300)
	layer.add_child(panel)
	var column := VBoxContainer.new()
	column.name = "VBoxContainer"
	panel.add_child(column)
	var header := HBoxContainer.new()
	header.name = "Header"
	column.add_child(header)
	var title := Label.new()
	title.text = "DEBUG MONITOR (passive) - F9 hide"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	stats_label = Label.new()
	stats_label.name = "Stats"
	stats_label.text = "waiting for first sample..."
	column.add_child(stats_label)
	var controls := HBoxContainer.new()
	controls.name = "Controls"
	column.add_child(controls)
	copy_button = _make_button("CopyLog", "Copy Log", _on_copy_log_pressed, controls)
	cmds_button = _make_button("CopyCmds", "Cmds", _on_copy_cmds_pressed, controls)
	snapshot_button = _make_button("Snapshot", "Snapshot", _on_snapshot_pressed, controls)
	_make_button("Clear", "Clear", _on_clear_pressed, controls)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(scroll)
	report_label = Label.new()
	report_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	report_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(report_label)

func _make_button(node_name: String, label: String, callback: Callable, parent_box: Node) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = label
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(callback)
	parent_box.add_child(button)
	return button
