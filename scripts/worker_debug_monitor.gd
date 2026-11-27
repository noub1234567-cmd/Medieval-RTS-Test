extends Node

# Passive worker-state monitor for the debug branch. It does not issue orders or alter worker state.
const SAMPLE_INTERVAL := 1.0
const STALL_SECONDS := 8.0
const PATH_PENDING_SECONDS := 12.0

var game: Node = null
var elapsed := 0.0
var snapshots: Dictionary = {}
var issue_active: Dictionary = {}
var report_lines: Array[String] = []
var panel: PanelContainer
var report_label: Label

func _ready() -> void:
	game = get_parent()
	_build_panel()
	_report("Worker Debug Monitor started (passive mode).")

func _process(delta: float) -> void:
	elapsed += delta
	if elapsed < SAMPLE_INTERVAL:
		return
	elapsed = 0.0
	if not is_instance_valid(game):
		return
	for worker in game.units:
		if not is_instance_valid(worker) or worker.team != 0 or worker.health <= 0:
			continue
		_check_worker(worker)

func _check_worker(worker: Node) -> void:
	var key := str(worker.get_instance_id())
	var snapshot: Dictionary = snapshots.get(key, {})
	var pos: Vector2 = worker.position
	var previous_pos: Vector2 = snapshot.get("position", pos)
	var progress_time: float = float(snapshot.get("progress_time", 0.0))
	var pending_time: float = float(snapshot.get("pending_time", 0.0))

	if worker.sheltered or worker.shelter_pending:
		progress_time = 0.0
		pending_time = 0.0
	elif worker.moving and not worker.path_pending:
		if pos.distance_to(previous_pos) > 2.0:
			progress_time = 0.0
		else:
			progress_time += SAMPLE_INTERVAL
		if progress_time >= STALL_SECONDS:
			_raise_issue(key, worker, "movement_stall", "Worker appears stationary while marked moving for %.0f seconds." % progress_time)
	else:
		progress_time = 0.0

	if worker.path_pending:
		pending_time += SAMPLE_INTERVAL
		if pending_time >= PATH_PENDING_SECONDS:
			_raise_issue(key, worker, "path_pending_timeout", "Path request remains pending for %.0f seconds." % pending_time)
	else:
		pending_time = 0.0

	if is_instance_valid(worker.harvest_target_node):
		if worker.harvest_target_node.amount <= 0:
			_raise_issue(key, worker, "depleted_harvest_target", "Worker still references a depleted resource node.")
	elif worker.harvest_target_node != null:
		_raise_issue(key, worker, "invalid_harvest_target", "Harvest target reference is invalid.")

	if worker.carried_amount > 0 and worker.storage_target == null and not worker.storage_blocked_by_capacity and not worker.moving and not worker.sheltered and not worker.shelter_pending:
		_raise_issue(key, worker, "cargo_idle", "Worker has cargo but no storage target and is not moving.")

	if worker.storage_blocked_by_capacity and worker.storage_target == null and worker.carried_amount > 0:
		var total := 0
		for amount in game.resources.values():
			total += int(amount)
		if total < game.storage_capacity:
			_raise_issue(key, worker, "blocked_storage_capacity_available", "Worker remains capacity-blocked although storage currently has room.")

	snapshots[key] = {"position": pos, "progress_time": progress_time, "pending_time": pending_time}

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

func _raise_issue(worker_key: String, worker: Node, issue: String, message: String) -> void:
	var issue_key := worker_key + ":" + issue
	if issue_active.has(issue_key):
		return
	issue_active[issue_key] = true
	_report("WARNING | Worker %s | %s | %s | position=%s | cargo=%d/%d | task=%s" % [
		str(worker.get_instance_id()), issue, message, str(worker.position), worker.carried_amount, worker.cargo_capacity, _task_summary(worker)
	])

func _report(message: String) -> void:
	var line := Time.get_datetime_string_from_system() + " | " + message
	report_lines.push_front(line)
	if report_lines.size() > 80:
		report_lines.resize(80)
	if is_instance_valid(report_label):
		report_label.text = "\n".join(report_lines)
	print(line)
	var file := FileAccess.open("user://worker_debug.log", FileAccess.READ_WRITE)
	if file == null:
		file = FileAccess.open("user://worker_debug.log", FileAccess.WRITE)
	if file != null:
		file.seek_end()
		file.store_line(line)
		file.close()

func _copy_report() -> void:
	if report_lines.is_empty():
		DisplayServer.clipboard_set("Worker Debug log is empty.")
	else:
		DisplayServer.clipboard_set("\n".join(report_lines))
	var copy_button := get_node_or_null("WorkerDebugLayer/WorkerDebugPanel/VBoxContainer/Header/CopyLog")
	if is_instance_valid(copy_button):
		copy_button.text = "Copied!"
		await get_tree().create_timer(1.5).timeout
		if is_instance_valid(copy_button):
			copy_button.text = "Copy Log"

func _build_panel() -> void:
	var layer := CanvasLayer.new()
	layer.name = "WorkerDebugLayer"
	layer.layer = 100
	add_child(layer)
	panel = PanelContainer.new()
	panel.name = "WorkerDebugPanel"
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.position = Vector2(-420, 12)
	panel.size = Vector2(408, 260)
	layer.add_child(panel)
	var column := VBoxContainer.new()
	column.name = "VBoxContainer"
	panel.add_child(column)
	var header := HBoxContainer.new()
	header.name = "Header"
	column.add_child(header)
	var title := Label.new()
	title.text = "WORKER DEBUG (passive)"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	var controls := HBoxContainer.new()
	controls.name = "Controls"
	column.add_child(controls)
	var copy_button := Button.new()
	copy_button.name = "CopyLog"
	copy_button.text = "Copy Log"
	copy_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	copy_button.pressed.connect(_copy_report)
	controls.add_child(copy_button)
	var clear_button := Button.new()
	clear_button.text = "Clear"
	clear_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clear_button.pressed.connect(func(): report_lines.clear(); report_label.text = "")
	controls.add_child(clear_button)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(scroll)
	report_label = Label.new()
	report_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	report_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(report_label)
