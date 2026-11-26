# Restored baseline: pre-placement-toggle behavior.
extends Node2D

const GRID := Vector2i(40, 40)
const TILE_W := 64.0
const TILE_H := 32.0
const UnitScene := preload("res://scenes/unit.tscn")
const OverlayScene := preload("res://scenes/selection_overlay.tscn")
const BuildingScript := preload("res://scripts/building.gd")

var units: Array[Node2D] = []
var pathfinding_queue:Array[Node2D]=[]
var pathfinding_budget:=2
var selected: Array[Node2D] = []
var selected_building:Node2D=null
var drag_start := Vector2.ZERO
var dragging := false
var camera_offset := Vector2(0, -640)
var zoom_level := 1.0
var drag_current := Vector2.ZERO
var touch_pending := false
var touch_start_screen := Vector2.ZERO
var touch_pan := false
var touch_unit_start := false
var hud_collapsed := false
var market_panel:PanelContainer
var market_sell_option:OptionButton
var market_buy_option:OptionButton
var market_amount_spin:SpinBox
var market_preview_label:Label
var market_window_open:=false
var motivation_panel:PanelContainer
var motivation_status_label:Label
var motivation_activate_button:Button
var motivation_upgrade_button:Button
var motivation_time_remaining:=0.0
var motivation_production_multiplier:=1.0
const MOTIVATION_DURATION_L1:=180.0
const MOTIVATION_DURATION_L2:=240.0
const MARKET_PRICES:Dictionary={"food":1.0,"wood":1.0,"stone":1.5,"gold":2.0}
const MARKET_MIN_AMOUNT:=10

var hud: CanvasLayer
var status_label: Label
var help_label: Label
var resources := {"wood": 500, "food": 500, "gold": 500, "stone": 500}
var buildings: Array[Node2D] = []
var building_upgrade_levels:Dictionary={}
var placing_building := false
var pending_building := ""
var building_ghost: Node2D
var placement_cursor_world := Vector2.ZERO
var placement_cursor_valid := false
var construction_sites: Array[Node2D] = []
var population := 8
var population_cap := 8
var income_timer := 0.0
var watchtower_alert_cooldown := 0.0
var enemy_resources := {"wood": 240, "food": 220, "gold": 180}
var enemy_buildings: Array[Node2D] = []
var enemy_population := 4
var enemy_population_cap := 8
var enemy_ai_timer := 0.0
var enemy_attack_timer := 0.0
var enemy_attack_cooldown := 35.0
var enemy_attack_level := 0
var enemy_attack_group: Array[Node2D] = []
var enemy_attack_active := false
var enemy_enabled := true
var enemy_toggle_button: Button
var cancel_build_button: Button
var demolish_building_button: Button
var upgrade_town_center_button: Button
var upgrade_building_button: Button
var recall_workers_button: Button
var recruit_worker_button: Button
var worker_training_remaining:=0.0
const WORKER_TRAINING_TIME:=10.0
var workers_recalled:=false
var pause_toggle_button: Button
var game_paused := false
var enemy_attack_losses := 0
var tree_positions: Array[Vector2] = []
var resource_nodes: Array[Node2D] = []
var storage_points: Array[Node2D] = []
var storage_capacity := 4000
const ResourceNodeScript := preload("res://scripts/resource_node.gd")
var building_cost := {"Farm": {"wood": 80, "gold": 30}, "House": {"wood": 100, "gold": 50}, "Barracks": {"wood": 150, "gold": 80}, "Guard Tower": {"wood": 120, "gold": 60}, "Watchtower": {"wood": 100, "gold": 50}, "Wall": {"wood": 25, "gold": 5}, "Warehouse": {"wood": 180, "gold": 70}, "Lumber Mill": {"wood": 150, "gold": 50}, "Quarry": {"wood": 150, "gold": 50}, "Gold Mine": {"wood": 150, "gold": 50}, "Mill": {"wood": 150, "gold": 50}, "Market": {"wood": 120, "gold": 60}, "Motivation Center": {"wood": 150, "gold": 50}}

func _ready() -> void:
	var overlay := OverlayScene.instantiate()
	overlay.name = "SelectionOverlay"
	add_child(overlay)
	for y in range(GRID.y):
		for x in range(GRID.x):
			var tile := Polygon2D.new()
			tile.polygon = PackedVector2Array([Vector2(0,-TILE_H/2),Vector2(TILE_W/2,0),Vector2(0,TILE_H/2),Vector2(-TILE_W/2,0)])
			tile.position = grid_to_screen(Vector2i(x,y))
			tile.color = tile_color(x,y)
			tile.z_index = -10
			add_child(tile)
			var outline := Line2D.new()
			outline.points = PackedVector2Array([Vector2(0,-TILE_H/2),Vector2(TILE_W/2,0),Vector2(0,TILE_H/2),Vector2(-TILE_W/2,0),Vector2(0,-TILE_H/2)])
			outline.width = 1.0
			outline.default_color = Color(0.12,0.18,0.1,0.24)
			tile.add_child(outline)
	add_map_details()
	create_resource_nodes()
	create_player_storage()
	for i in range(8):
		var u: Node2D = UnitScene.instantiate()
		add_child(u)
		u.set_team(0)
		u.position = grid_to_screen(Vector2i(12+i%4, 12+i/4))
		units.append(u)
	for i in range(4):
		var e: Node2D = UnitScene.instantiate()
		add_child(e)
		e.set_team(1)
		e.position = grid_to_screen(Vector2i(25+i%2, 25+i/2))
		units.append(e)
	create_enemy_base()
	create_hud()
	update_view()
	update_status()

func add_map_details() -> void:
	# Small decorative woodland patches, avoiding the starting armies.
	for p in [Vector2i(6,7),Vector2i(7,7),Vector2i(6,8),Vector2i(33,10),Vector2i(34,10),Vector2i(33,11),Vector2i(8,30),Vector2i(9,30),Vector2i(8,31)]:
		var tree := Polygon2D.new()
		tree.polygon = PackedVector2Array([Vector2(0,-22),Vector2(12,-6),Vector2(8,7),Vector2(0,12),Vector2(-8,7),Vector2(-12,-6)])
		tree.position = grid_to_screen(p)+Vector2(0,-10)
		tree_positions.append(grid_to_screen(p))
		tree.color = Color(0.12,0.32,0.16)
		tree.z_index = 1
		add_child(tree)

func create_player_storage() -> void:
	var depot:=Node2D.new()
	depot.set_script(BuildingScript)
	depot.team=0
	depot.max_health=1000
	depot.health=1000
	depot.name="Town Center"
	depot.building_type="Town Center"
	depot.town_center_level=1
	depot.position=grid_to_screen(Vector2i(11,11))
	var shape:=Polygon2D.new()
	shape.polygon=PackedVector2Array([Vector2(0,-38),Vector2(34,-14),Vector2(34,18),Vector2(0,40),Vector2(-34,18),Vector2(-34,-14)])
	shape.color=Color(0.68,0.55,0.28)
	depot.add_child(shape)
	var label:=Label.new()
	label.name="TownCenterNameLabel"
	label.text="Town Center"
	label.position=Vector2(-40,-54)
	label.scale=Vector2(0.8,0.8)
	depot.add_child(label)
	add_child(depot)
	buildings.append(depot)
	storage_points.append(depot)

func get_nearest_storage(pos:Vector2,resource_type:String="")->Node2D:
	var specialized_type={"wood":"Lumber Mill","food":"Mill","gold":"Gold Mine","stone":"Quarry"}.get(resource_type,"")
	var nearest_specialized:Node2D=null
	var best_specialized_distance:=INF
	if specialized_type!="":
		for building in buildings:
			if not is_instance_valid(building) or building.health<=0 or building.team!=0 or not building.is_complete:
				continue
			if building.building_type!=specialized_type:
				continue
			var distance:=pos.distance_to(building.position)
			if distance<best_specialized_distance:
				best_specialized_distance=distance
				nearest_specialized=building
	if nearest_specialized!=null:
		return nearest_specialized
	var town_center:Node2D=null
	var best_town_center_distance:=INF
	for building in buildings:
		if not is_instance_valid(building) or building.health<=0 or building.team!=0 or building.building_type!="Town Center":
			continue
		var distance:=pos.distance_to(building.position)
		if distance<best_town_center_distance:
			best_town_center_distance=distance
			town_center=building
	return town_center

func get_nearest_resource_node(pos:Vector2,resource_type:String)->Node2D:
	var nearest:Node2D=null
	var best=INF
	for node in resource_nodes:
		if is_instance_valid(node) and node.amount>0 and node.resource_type==resource_type:
			var d=pos.distance_to(node.position)
			if d<best:best=d;nearest=node
	return nearest

func reduce_resources_to_capacity()->void:
	var total_resources:=0
	for amount in resources.values():
		total_resources+=int(amount)
	var excess=max(0,total_resources-storage_capacity)
	var removal_per_resource=int(floor(float(excess)/4.0))
	for resource_type in ["wood","food","gold","stone"]:
		var removed=min(removal_per_resource,int(resources.get(resource_type,0)))
		resources[resource_type]-=removed

func deliver_resource(resource_type:String, quantity:int)->int:
	var total_resources:=0
	for amount in resources.values():
		total_resources+=int(amount)
	var room=max(0,storage_capacity-total_resources)
	var delivered=min(room,max(0,quantity))
	resources[resource_type]=resources.get(resource_type,0)+delivered
	update_status()
	return delivered

func create_resource_nodes() -> void:
	var deposits:Array[Dictionary]=[
		{"type":"wood","cell":Vector2i(9,14),"amount":650},{"type":"wood","cell":Vector2i(16,7),"amount":700},{"type":"wood","cell":Vector2i(21,17),"amount":600},{"type":"wood","cell":Vector2i(35,21),"amount":700},
		{"type":"food","cell":Vector2i(5,20),"amount":450},{"type":"food","cell":Vector2i(18,31),"amount":500},{"type":"food","cell":Vector2i(32,7),"amount":450},
		{"type":"gold","cell":Vector2i(19,9),"amount":800},{"type":"gold","cell":Vector2i(7,25),"amount":750},{"type":"gold","cell":Vector2i(34,33),"amount":900},
		{"type":"stone","cell":Vector2i(14,27),"amount":700},{"type":"stone","cell":Vector2i(23,5),"amount":750},{"type":"stone","cell":Vector2i(37,15),"amount":800}]
	for deposit in deposits:
		var node:=Node2D.new()
		node.set_script(ResourceNodeScript)
		node.resource_type=deposit.type
		node.amount=deposit.amount
		node.position=grid_to_screen(deposit.cell)
		add_child(node)
		resource_nodes.append(node)

func tile_color(x:int,y:int) -> Color:
	var v := float((x*17+y*31)%11)/100.0
	if (x+y)%9==0:
		return Color(0.28+v,0.39+v,0.2+v*0.5)
	return Color(0.23+v,0.42+v,0.22+v*0.5)

func grid_to_screen(cell:Vector2i) -> Vector2:
	return Vector2((cell.x-cell.y)*TILE_W/2,(cell.x+cell.y)*TILE_H/2)

func screen_to_world(p:Vector2) -> Vector2:
	return (p-camera_offset)/zoom_level

func _input(event:InputEvent) -> void:
	# Treat the Motivation Center as a modal window: prevent the game map from
	# processing clicks/touches while its controls are open.
	if is_instance_valid(motivation_panel):
		return
	if market_window_open:
		return
	if event is InputEventMouseButton:
		if event.button_index==MOUSE_BUTTON_LEFT:
			if event.pressed:
				drag_start=screen_to_world(event.position)
				drag_current=drag_start
				dragging=true
			elif dragging:
				finish_selection(screen_to_world(event.position))
				dragging=false
		elif event.button_index==MOUSE_BUTTON_RIGHT and event.pressed:
			if placing_building: place_building(screen_to_world(event.position))
			else: attack_or_move(screen_to_world(event.position))
		elif event.button_index==MOUSE_BUTTON_WHEEL_UP:
			zoom_level=min(zoom_level*1.12,2.2)
			update_view()
		elif event.button_index==MOUSE_BUTTON_WHEEL_DOWN:
			zoom_level=max(zoom_level/1.12,0.35)
			update_view()
	elif event is InputEventKey and event.pressed and event.keycode==KEY_ESCAPE:
		placing_building=false
		if is_instance_valid(building_ghost): building_ghost.queue_free(); building_ghost=null
		if is_instance_valid(help_label): help_label.text="Placement cancelled"
	elif event is InputEventMouseMotion:
		if placing_building:
			placement_cursor_world=screen_to_world(event.position)
			update_building_ghost()
		if dragging:
			drag_current=screen_to_world(event.position)
			overlay_update()
	elif event is InputEventScreenTouch:
		if event.pressed:
			if event.position.x<520.0 and event.position.y<280.0:
				dragging=false
				return
			touch_start_screen=event.position
			placement_cursor_world=screen_to_world(event.position)
			if placing_building: update_building_ghost()
			drag_start=screen_to_world(event.position)
			drag_current=drag_start
			touch_unit_start=find_player_unit_at(drag_start)!=null
			touch_pan=false
			dragging=true
		else:
			if dragging:
				var moved=event.position.distance_to(touch_start_screen)
				if touch_pan and moved>20.0:
					pass
				elif placing_building:
					place_building(screen_to_world(event.position))
				elif moved>20.0 and touch_unit_start:
					finish_selection(screen_to_world(event.position))
				else:
					touch_tap(screen_to_world(event.position))
				dragging=false
				get_node("SelectionOverlay").clear_rect()
				update_status()
			dragging=false
	elif event is InputEventScreenDrag and dragging:
		placement_cursor_world=screen_to_world(event.position)
		if placing_building: update_building_ghost()
		if not touch_unit_start and not placing_building:
			touch_pan=true
			camera_offset+=event.relative
			update_view()
		else:
			drag_current=screen_to_world(event.position)
			overlay_update()

func find_player_unit_at(pos:Vector2)->Node2D:
	var nearest:Node2D=null
	var best=48.0
	for unit in units:
		if is_instance_valid(unit) and unit.team==0:
			var d=unit.position.distance_to(pos)
			if d<best:
				best=d
				nearest=unit
	return nearest

func find_town_center_at(pos:Vector2)->Node2D:
	for building in buildings:
		if is_instance_valid(building) and building.team==0 and building.building_type=="Town Center" and building.health>0 and pos.distance_to(building.position)<90.0:
			return building
	return null

func find_player_building_at(pos:Vector2)->Node2D:
	var nearest:Node2D=null
	var best_distance:=58.0
	for building in buildings:
		if is_instance_valid(building) and building.team==0 and building.building_type!="Town Center" and building.health>0 and building.is_complete:
			var distance=building.position.distance_to(pos)
			if distance<best_distance:
				best_distance=distance
				nearest=building
	return nearest

func touch_tap(pos:Vector2)->void:
	if placing_building:
		place_building(pos)
		return
	# Manually selected workers can be reassigned to an upgrade in progress.
	var upgrading_target=find_upgrading_building_at(pos)
	if upgrading_target!=null and not selected.is_empty():
		assign_selected_workers_to_upgrade(upgrading_target)
		return
	# When workers are selected, resolve construction-site hits first and
	# issue the build order before any building-selection or movement logic.
	var site=find_unfinished_building_at(pos)
	if site!=null and not selected.is_empty():
		var assigned:=false
		for worker in selected:
			if is_instance_valid(worker) and worker.team==0:
				worker.build_target(site)
				assigned=true
		if assigned:
			help_label.text="Builders reassigned to construction!"
			return
	if site!=null:
		clear_selection()
		selected_building=site
		if is_instance_valid(cancel_build_button):cancel_build_button.visible=true
		if is_instance_valid(demolish_building_button):demolish_building_button.visible=false
		help_label.text="Construction selected — cancel to recover 60% of cost"
		return
	var town_center=find_town_center_at(pos)
	if town_center!=null:
		clear_selection()
		selected_building=town_center
		if is_instance_valid(upgrade_town_center_button): upgrade_town_center_button.visible=true
		if is_instance_valid(demolish_building_button): demolish_building_button.visible=false
		if is_instance_valid(recall_workers_button):
			recall_workers_button.visible=true
			recall_workers_button.text="Release Workers" if workers_recalled else "Recall Workers"
		help_label.text="Town Center selected — upgrade to Level 2"
		return
	var structure=find_player_building_at(pos)
	if structure!=null:
		if structure.building_type=="Market":
			clear_selection()
			selected_building=structure
			open_market_window()
			return
		if structure.building_type=="Motivation Center":
			clear_selection()
			selected_building=structure
			if is_instance_valid(demolish_building_button):demolish_building_button.visible=true
			if is_instance_valid(upgrade_building_button):upgrade_building_button.visible=(structure.is_complete and not structure.is_upgrading and structure.building_upgrade_level<2 and find_town_center_level()>=2)
			open_motivation_center_window()
			return
		clear_selection()
		selected_building=structure
		if is_instance_valid(cancel_build_button):cancel_build_button.visible=false
		if is_instance_valid(demolish_building_button):demolish_building_button.visible=true
		if is_instance_valid(upgrade_building_button):upgrade_building_button.visible=(structure.is_complete and not structure.is_upgrading and structure.building_upgrade_level<2 and find_town_center_level()>=2)
		if structure.building_type in ["Guard Tower","Watchtower"]:structure.set_range_visible(true)
		help_label.text="Building selected — demolish or upgrade (Town Center Level 2 unlocks upgrades)"
		return
	var unit=find_player_unit_at(pos)
	if unit!=null:
		clear_selection()
		add_selection(unit)
		return
	if not selected.is_empty():
		attack_or_move(pos)
	else:
		clear_selection()

func overlay_update() -> void:
	var overlay:Node = get_node("SelectionOverlay")
	overlay.set_rect(Rect2(drag_start,drag_current-drag_start).abs())

func finish_selection(end_pos:Vector2) -> void:
	if placing_building:
		place_building(end_pos)
		get_node("SelectionOverlay").clear_rect()
		return
	var box := Rect2(drag_start,end_pos-drag_start).abs()
	if box.size.length()<14.0:
		touch_tap(end_pos)
	else:
		clear_selection()
		for u in units:
			if u.team==0 and box.has_point(u.position):
				add_selection(u)
	get_node("SelectionOverlay").clear_rect()
	update_status()

func toggle_recall_workers()->void:
	var tc:=selected_building
	if not is_instance_valid(tc) or tc.team!=0 or tc.building_type!="Town Center" or tc.health<=0:
		return
	if workers_recalled:
		release_sheltered_workers(tc)
	else:
		recall_workers_into_tc(tc)
	workers_recalled=not workers_recalled
	if is_instance_valid(recall_workers_button):
		recall_workers_button.text="Release Workers" if workers_recalled else "Recall Workers"
	help_label.text="Workers sheltered inside Town Center." if workers_recalled else "Workers released and orders restored."
	update_status()

func recall_workers_into_tc(tc:Node2D)->void:
	for worker in units:
		if not is_instance_valid(worker) or worker.team!=0 or worker.health<=0 or worker.sheltered or worker.shelter_pending:
			continue
		var active_harvest=worker.harvest_target_node if is_instance_valid(worker.harvest_target_node) else worker.resume_harvest_node
		var saved:Dictionary={
			"harvest":active_harvest,
			"build":worker.build_target_site,
			"upgrade":worker.upgrade_target_building,
			"target":worker.target,
			"destination":worker.destination,
			"position":worker.position,
			"moving":worker.moving,
			"was_idle":worker.harvest_target_node==null and worker.storage_target==null and worker.build_target_site==null and worker.upgrade_target_building==null and worker.target==null and worker.carried_amount<=0 and not worker.moving,
			"carried_amount":worker.carried_amount,
			"carried_type":worker.carried_type
		}
		worker.shelter_saved_state=saved
		worker.clear_production_assignment()
		if is_instance_valid(worker.upgrade_target_building):
			worker.upgrade_target_building.unregister_upgrade_worker(worker)
		worker.harvest_target_node=null
		worker.resume_harvest_node=null
		worker.storage_target=null
		worker.build_target_site=null
		worker.upgrade_target_building=null
		worker.target=null
		worker.moving=false
		worker.path_pending=false
		worker.route=PackedVector2Array()
		worker.shelter_pending=true
		worker.shelter_tc=tc
		worker.visible=true
		worker.destination=tc.position
		worker.set_route(tc.position)
		worker.moving=true


func release_sheltered_workers(tc:Node2D)->void:
	for worker in units:
		if not is_instance_valid(worker) or worker.team!=0 or (not worker.sheltered and not worker.shelter_pending):
			continue
		worker.shelter_pending=false
		worker.shelter_tc=null
		worker.sheltered=false
		worker.visible=true
		worker.position=tc.position+Vector2((worker.get_instance_id()%5)*8-16,24)
		var saved=worker.shelter_saved_state
		worker.shelter_saved_state={}
		worker.carried_amount=int(saved.get("carried_amount",worker.carried_amount))
		worker.carried_type=str(saved.get("carried_type",worker.carried_type))
		var harvest=saved.get("harvest")
		var build=saved.get("build")
		var upgrade=saved.get("upgrade")
		var old_target=saved.get("target")
		if is_instance_valid(build) and not build.is_complete:
			worker.build_target(build)
		elif is_instance_valid(upgrade) and upgrade.is_upgrading:
			worker.upgrade_target(upgrade)
		elif is_instance_valid(harvest) and harvest.amount>0:
			worker.harvest_target(harvest)
		elif is_instance_valid(old_target) and old_target.health>0:
			worker.attack_target(old_target)
		elif int(saved.get("carried_amount",0))>0:
			worker.return_to_storage()
		elif bool(saved.get("moving",false)):
			worker.destination=saved.get("destination",worker.position)
			worker.moving=true
			worker.set_route(worker.destination)
		else:
			worker.destination=saved.get("position",worker.position)
			if worker.position.distance_to(worker.destination)>18.0:
				worker.moving=true
				worker.set_route(worker.destination)
			else:
				worker.moving=false
				worker.path_pending=false
				worker.route=PackedVector2Array()

func town_center_destroyed(tc:Node2D)->void:
	if not is_instance_valid(tc):return
	if workers_recalled:
		release_sheltered_workers(tc)
		workers_recalled=false
	if is_instance_valid(recall_workers_button):
		recall_workers_button.visible=false
		recall_workers_button.text="Recall Workers"

func clear_selection() -> void:
	close_motivation_center_window()
	for u in selected:
		u.set_selected(false)
	selected.clear()
	if is_instance_valid(selected_building):
		selected_building.set_range_visible(false)
	selected_building=null
	if is_instance_valid(cancel_build_button):cancel_build_button.visible=false
	if is_instance_valid(demolish_building_button):demolish_building_button.visible=false
	if is_instance_valid(upgrade_town_center_button):upgrade_town_center_button.visible=false
	if is_instance_valid(upgrade_building_button):upgrade_building_button.visible=false
	if is_instance_valid(recall_workers_button):recall_workers_button.visible=false

func add_selection(u:Node2D) -> void:
	if not selected.has(u):
		selected.append(u)
		u.set_selected(true)

func assign_worker_to_resource_production(worker:Node2D,resource_type:String)->void:
	if not is_instance_valid(worker) or worker.team!=0:return
	var building_type={"wood":"Lumber Mill","food":"Mill","gold":"Gold Mine","stone":"Quarry"}.get(resource_type,"")
	if building_type=="":
		worker.clear_production_assignment()
		return
	if is_instance_valid(worker.production_target_building) and worker.production_target_building.building_type==building_type:
		return
	worker.clear_production_assignment()
	var nearest:Node2D=null
	var best_distance:=INF
	for building in buildings:
		if is_instance_valid(building) and building.team==0 and building.is_complete and building.building_type==building_type and not is_instance_valid(building.production_worker):
			var distance=worker.position.distance_to(building.position)
			if distance<best_distance:
				best_distance=distance
				nearest=building
	if nearest!=null and nearest.register_production_worker(worker):
		worker.production_target_building=nearest

func attack_or_move(target_pos:Vector2) -> void:
	if selected.is_empty(): return
	var resource_node:Node2D=null
	var resource_distance:=55.0
	for node in resource_nodes:
		if is_instance_valid(node) and node.amount>0:
			var rd=node.position.distance_to(target_pos)
			if rd<resource_distance:
				resource_distance=rd
				resource_node=node
	if resource_node!=null:
		for worker in selected: worker.harvest_target(resource_node)
		help_label.text="Harvest order issued!"
		return
	var site:Node2D=null
	var site_distance:=55.0
	for b in construction_sites:
		if is_instance_valid(b) and not b.is_complete:
			var sd=b.position.distance_to(target_pos)
			if sd<site_distance:
				site_distance=sd
				site=b
	if site!=null:
		for worker in selected: worker.build_target(site)
		help_label.text="Builders assigned!"
		return
	var enemy:Node2D=null
	var best_distance:=55.0
	for u in units:
		if is_instance_valid(u) and u.team==1:
			var d=u.position.distance_to(target_pos)
			if d<best_distance:
				best_distance=d
				enemy=u
	if enemy==null:
		for structure in enemy_buildings:
			if is_instance_valid(structure) and structure.health>0:
				var d=structure.position.distance_to(target_pos)
				if d<best_distance:
					best_distance=d
					enemy=structure
	if enemy!=null:
		for soldier in selected: soldier.attack_target(enemy)
		help_label.text="Attack order issued!"
	else:
		for i in range(selected.size()):
			var offset:=Vector2((i%3)*20-20,(i/3)*18)
			selected[i].move_to(target_pos+offset)
		help_label.text="Move order issued."

func update_view() -> void:
	position=camera_offset
	scale=Vector2(zoom_level,zoom_level)

func create_hud() -> void:
	hud=CanvasLayer.new()
	hud.process_mode=Node.PROCESS_MODE_ALWAYS
	add_child(hud)
	var panel:=PanelContainer.new()
	panel.position=Vector2(8,8)
	panel.add_theme_stylebox_override("panel",make_panel_style())
	hud.add_child(panel)
	var v:=VBoxContainer.new()
	v.add_theme_constant_override("separation",2)
	panel.add_child(v)
	var top:=HBoxContainer.new()
	v.add_child(top)
	var title:=Label.new()
	title.text="MEDIEVAL RTS"
	title.add_theme_font_size_override("font_size",14)
	top.add_child(title)
	pause_toggle_button=Button.new()
	pause_toggle_button.text="Pause"
	pause_toggle_button.custom_minimum_size=Vector2(92,40)
	pause_toggle_button.anchor_left=1.0
	pause_toggle_button.anchor_right=1.0
	pause_toggle_button.anchor_top=0.0
	pause_toggle_button.anchor_bottom=0.0
	pause_toggle_button.offset_left=-104.0
	pause_toggle_button.offset_right=-8.0
	pause_toggle_button.offset_top=8.0
	pause_toggle_button.offset_bottom=48.0
	pause_toggle_button.z_index=100
	pause_toggle_button.pressed.connect(toggle_pause)
	hud.add_child(pause_toggle_button)
	var collapse:=Button.new()
	collapse.text="−"
	collapse.custom_minimum_size=Vector2(36,32)
	collapse.pressed.connect(toggle_hud)
	top.add_child(collapse)
	status_label=Label.new()
	status_label.add_theme_font_size_override("font_size",12)
	v.add_child(status_label)
	var buttons:=HBoxContainer.new()
	buttons.add_theme_constant_override("separation",3)
	v.add_child(buttons)
	var recruit:=Button.new()
	recruit.text="Soldier"
	recruit.custom_minimum_size=Vector2(64,36)
	recruit.pressed.connect(recruit_soldier)
	buttons.add_child(recruit)
	recruit_worker_button=Button.new()
	recruit_worker_button.text="Worker (50 Food)"
	recruit_worker_button.custom_minimum_size=Vector2(120,36)
	recruit_worker_button.pressed.connect(start_worker_training)
	buttons.add_child(recruit_worker_button)
	var building_rows:Array[HBoxContainer]=[buttons]
	var second_building_row:=HBoxContainer.new()
	second_building_row.add_theme_constant_override("separation",3)
	v.add_child(second_building_row)
	building_rows.append(second_building_row)
	var third_building_row:=HBoxContainer.new()
	third_building_row.add_theme_constant_override("separation",3)
	v.add_child(third_building_row)
	building_rows.append(third_building_row)
	var fourth_building_row:=HBoxContainer.new()
	fourth_building_row.add_theme_constant_override("separation",3)
	v.add_child(fourth_building_row)
	building_rows.append(fourth_building_row)
	var building_names=["Farm","House","Barracks","Tower","Wall","Store","Lumber","Quarry","Gold","Mill","Watchtower","Market","Motivation"]
	for i in range(building_names.size()):
		var building_name=building_names[i]
		var b:=Button.new()
		b.text=building_name
		b.custom_minimum_size=Vector2(54,36)
		b.pressed.connect(func(): begin_placement("Guard Tower" if building_name=="Tower" else "Warehouse" if building_name=="Store" else "Lumber Mill" if building_name=="Lumber" else "Gold Mine" if building_name=="Gold" else "Mill" if building_name=="Mill" else "Motivation Center" if building_name=="Motivation" else building_name))
		building_rows[0 if i<3 else 1 if i<6 else 2 if i<9 else 3].add_child(b)
	var enemy_row:=HBoxContainer.new()
	v.add_child(enemy_row)
	enemy_toggle_button=Button.new()
	enemy_toggle_button.text="Enemy: ON"
	enemy_toggle_button.custom_minimum_size=Vector2(110,32)
	enemy_toggle_button.pressed.connect(toggle_enemy)
	enemy_row.add_child(enemy_toggle_button)
	cancel_build_button=Button.new()
	cancel_build_button.text="Cancel Build (60%)"
	cancel_build_button.custom_minimum_size=Vector2(180,44)
	cancel_build_button.position=Vector2(8,58)
	cancel_build_button.visible=false
	cancel_build_button.z_index=100
	cancel_build_button.pressed.connect(cancel_selected_construction)
	hud.add_child(cancel_build_button)
	demolish_building_button=Button.new()
	demolish_building_button.text="Demolish (15%)"
	demolish_building_button.custom_minimum_size=Vector2(180,44)
	demolish_building_button.position=Vector2(8,106)
	demolish_building_button.visible=false
	demolish_building_button.z_index=100
	demolish_building_button.pressed.connect(demolish_selected_building)
	hud.add_child(demolish_building_button)
	upgrade_town_center_button=Button.new()
	upgrade_town_center_button.text="Upgrade Town Center (L2)"
	upgrade_town_center_button.custom_minimum_size=Vector2(220,44)
	upgrade_town_center_button.position=Vector2(8,154)
	upgrade_town_center_button.visible=false
	upgrade_town_center_button.z_index=100
	upgrade_town_center_button.pressed.connect(upgrade_selected_town_center)
	hud.add_child(upgrade_town_center_button)
	upgrade_building_button=Button.new()
	upgrade_building_button.text="Upgrade Building (L2)"
	upgrade_building_button.custom_minimum_size=Vector2(220,44)
	upgrade_building_button.position=Vector2(8,202)
	upgrade_building_button.visible=false
	upgrade_building_button.z_index=100
	upgrade_building_button.pressed.connect(upgrade_selected_building)
	hud.add_child(upgrade_building_button)
	recall_workers_button=Button.new()
	recall_workers_button.text="Recall Workers"
	recall_workers_button.custom_minimum_size=Vector2(220,44)
	recall_workers_button.position=Vector2(8,250)
	recall_workers_button.visible=false
	recall_workers_button.z_index=100
	recall_workers_button.pressed.connect(toggle_recall_workers)
	hud.add_child(recall_workers_button)
	var zoom_row:=HBoxContainer.new()
	v.add_child(zoom_row)
	var zoom_in:=Button.new()
	zoom_in.text="+"
	zoom_in.custom_minimum_size=Vector2(42,32)
	zoom_in.pressed.connect(func(): change_zoom(1.15))
	zoom_row.add_child(zoom_in)
	var zoom_out:=Button.new()
	zoom_out.text="−"
	zoom_out.custom_minimum_size=Vector2(42,32)
	zoom_out.pressed.connect(func(): change_zoom(0.87))
	zoom_row.add_child(zoom_out)
	help_label=Label.new()
	help_label.text="Tap unit, then tap destination. Drag empty map to pan."
	help_label.add_theme_font_size_override("font_size",11)
	v.add_child(help_label)

func toggle_hud()->void:
	hud_collapsed=not hud_collapsed
	status_label.visible=not hud_collapsed
	for child in hud.get_child(0).get_child(0).get_children():
		if child is HBoxContainer and child!=hud.get_child(0).get_child(0).get_child(0):
			child.visible=not hud_collapsed
	help_label.visible=not hud_collapsed

func change_zoom(factor:float)->void:
	zoom_level=clamp(zoom_level*factor,0.35,2.2)
	update_view()

func make_panel_style() -> StyleBoxFlat:
	var s:=StyleBoxFlat.new()
	s.bg_color=Color(0.07,0.09,0.07,0.88)
	s.border_color=Color(0.55,0.48,0.3,0.9)
	s.set_border_width_all(2)
	s.set_corner_radius_all(6)
	s.content_margin_left=6
	s.content_margin_right=6
	s.content_margin_top=4
	s.content_margin_bottom=4
	return s

func start_worker_training()->void:
	if worker_training_remaining>0.0:
		return
	if population>=population_cap:
		help_label.text="Population limit reached — build Houses"
		return
	if resources.food<50:
		help_label.text="Worker recruitment costs 50 Food"
		return
	var tc:Node2D=null
	for b in buildings:
		if is_instance_valid(b) and b.team==0 and b.building_type=="Town Center" and b.health>0:
			tc=b
			break
	if tc==null:
		help_label.text="Town Center unavailable"
		return
	resources.food-=50
	worker_training_remaining=WORKER_TRAINING_TIME
	if is_instance_valid(recruit_worker_button):
		recruit_worker_button.disabled=true
		recruit_worker_button.text="Training: 10s"
	help_label.text="Worker training started (10 seconds)"
	update_status()

func complete_worker_training()->void:
	var tc:Node2D=null
	for b in buildings:
		if is_instance_valid(b) and b.team==0 and b.building_type=="Town Center" and b.health>0:
			tc=b
			break
	if tc==null:
		help_label.text="Worker training cancelled — Town Center destroyed"
		worker_training_remaining=0.0
		if is_instance_valid(recruit_worker_button):
			recruit_worker_button.disabled=false
			recruit_worker_button.text="Worker (50 Food)"
		return
	var worker:Node2D=UnitScene.instantiate()
	add_child(worker)
	worker.set_team(0)
	worker.position=find_spawn_position(tc.position)
	units.append(worker)
	population+=1
	worker_training_remaining=0.0
	if is_instance_valid(recruit_worker_button):
		recruit_worker_button.disabled=false
		recruit_worker_button.text="Worker (50 Food)"
	help_label.text="Worker recruited!"
	update_status()

func recruit_soldier() -> void:
	var has_barracks:=false
	for b in buildings:
		if b.name=="Barracks" and b.is_complete: has_barracks=true
	if not has_barracks:
		help_label.text="Build a Barracks first"
		return
	if population>=population_cap:
		help_label.text="Population limit reached"
		return
	if resources.food<50 or resources.gold<25:
		help_label.text="Recruitment costs 50 food and 25 gold"
		return
	resources.food-=50
	resources.gold-=25
	population+=1
	var soldier:Node2D=UnitScene.instantiate()
	add_child(soldier)
	soldier.set_team(0)
	var barracks:Node2D=buildings.filter(func(b): return b.name=="Barracks")[0]
	soldier.position=find_spawn_position(barracks.position)
	units.append(soldier)
	update_status()
	help_label.text="Soldier recruited!"

func find_spawn_position(origin:Vector2)->Vector2:
	var offsets=[Vector2(48,0),Vector2(-48,0),Vector2(0,48),Vector2(0,-48),Vector2(48,48),Vector2(-48,-48),Vector2(48,-48),Vector2(-48,48)]
	for off in offsets:
		var p=origin+off
		if is_position_inside_map(p) and not is_unit_position_blocked(p,null):
			return p
	var fallback=snap_to_map_cell(origin+Vector2(60,60))
	if is_position_inside_map(fallback) and not is_unit_position_blocked(fallback,null):
		return fallback
	return snap_to_map_cell(origin)

func enemy_count() -> int:
	var count:=0
	for u in units:
		if u.team==1: count+=1
	return count

func begin_placement(building_name:String) -> void:
	if building_name=="Motivation Center":
		for existing in buildings:
			if is_instance_valid(existing) and existing.health>0 and existing.building_type=="Motivation Center":
				help_label.text="Only one Motivation Center can be built"
				return
	# Do not create a placement preview when the player cannot afford the building.
	if not building_cost.has(building_name):
		help_label.text="Unknown building type"
		return
	for key in building_cost[building_name]:
		if resources.get(key,0)<building_cost[building_name][key]:
			placing_building=false
			pending_building=""
			if is_instance_valid(building_ghost):
				building_ghost.queue_free()
				building_ghost=null
			placement_cursor_valid=false
			help_label.text="Not enough resources to build %s" % building_name
			return
	placing_building=true
	pending_building=building_name
	if not is_instance_valid(building_ghost):
		building_ghost=Node2D.new()
		building_ghost.name="BuildingPlacementGhost"
		building_ghost.z_index=20
		var shape:=Polygon2D.new()
		shape.name="GhostShape"
		shape.polygon=PackedVector2Array([Vector2(0,-26),Vector2(24,-10),Vector2(24,12),Vector2(0,28),Vector2(-24,12),Vector2(-24,-10)])
		shape.color=Color(0.2,1.0,0.25,0.78)
		building_ghost.add_child(shape)
		var outline:=Line2D.new()
		outline.name="GhostOutline"
		outline.points=PackedVector2Array([Vector2(0,-26),Vector2(24,-10),Vector2(24,12),Vector2(0,28),Vector2(-24,12),Vector2(-24,-10),Vector2(0,-26)])
		outline.width=3.0
		outline.default_color=Color(0.15,1.0,0.2,1.0)
		building_ghost.add_child(outline)
		var label:=Label.new()
		label.name="GhostLabel"
		label.position=Vector2(-32,-42)
		label.scale=Vector2(0.8,0.8)
		building_ghost.add_child(label)
		add_child(building_ghost)
	placement_cursor_world=screen_to_world(get_viewport().get_mouse_position())
	update_building_ghost()
	help_label.text="Move cursor, then tap/click to place %s (Esc cancels)" % building_name

func get_placement_position(pos:Vector2)->Vector2:
	return grid_to_screen(world_to_grid(pos))

func is_building_placement_valid(pos:Vector2)->bool:
	# Validate the full visual footprint, not just the placement center.
	var footprint:=PackedVector2Array([
		Vector2(0,-26),Vector2(24,-10),Vector2(24,12),
		Vector2(0,28),Vector2(-24,12),Vector2(-24,-10)
	])
	for offset in footprint:
		var edge_cell=world_to_grid(pos+offset)
		if edge_cell.x<0 or edge_cell.y<0 or edge_cell.x>=GRID.x or edge_cell.y>=GRID.y:
			return false
	var cell=world_to_grid(pos)
	if cell.x<0 or cell.y<0 or cell.x>=GRID.x or cell.y>=GRID.y:return false
	# Keep existing building spacing rules.
	for existing in buildings+enemy_buildings:
		if is_instance_valid(existing) and existing.health>0 and pos.distance_to(existing.position)<54.0:return false
	# Avoid woodland and all live resource deposits.
	for tree_pos in tree_positions:
		if pos.distance_to(tree_pos)<48.0:return false
	for node in resource_nodes:
		if is_instance_valid(node) and node.amount>0 and pos.distance_to(node.position)<42.0:return false
	# Prevent building footprints from overlapping units of either team.
	for unit in units:
		if is_instance_valid(unit) and unit.health>0 and pos.distance_to(unit.position)<42.0:return false
	# Placement also requires the currently selected building's full cost.
	if not building_cost.has(pending_building):return false
	for key in building_cost[pending_building]:
		if resources.get(key,0)<building_cost[pending_building][key]:return false
	return true

func update_building_ghost()->void:
	if not placing_building or not is_instance_valid(building_ghost):return
	var snapped=get_placement_position(placement_cursor_world)
	building_ghost.position=snapped
	placement_cursor_valid=is_building_placement_valid(snapped)
	var shape=building_ghost.get_node("GhostShape") as Polygon2D
	shape.color=Color(0.1,1.0,0.15,0.82) if placement_cursor_valid else Color(1.0,0.08,0.08,0.82)
	var outline=building_ghost.get_node("GhostOutline") as Line2D
	outline.default_color=Color(0.05,0.9,0.1,1.0) if placement_cursor_valid else Color(1.0,0.05,0.05,1.0)
	var label=building_ghost.get_node("GhostLabel") as Label
	label.text=pending_building + (" - VALID" if placement_cursor_valid else " - INVALID")
	label.modulate=Color(0.5,1.0,0.5) if placement_cursor_valid else Color(1.0,0.35,0.35)

func is_position_inside_map(pos:Vector2)->bool:
	var cell=world_to_grid(pos)
	return cell.x>=0 and cell.y>=0 and cell.x<GRID.x and cell.y<GRID.y

func snap_to_map_cell(pos:Vector2)->Vector2:
	var cell=world_to_grid(pos)
	cell.x=clampi(cell.x,0,GRID.x-1)
	cell.y=clampi(cell.y,0,GRID.y-1)
	return grid_to_screen(cell)

func place_building(pos:Vector2) -> void:
	if not placing_building: return
	pos=get_placement_position(pos)
	if not is_building_placement_valid(pos):
		help_label.text="Invalid placement: red preview cannot be placed"
		return
	var cost:Dictionary=building_cost[pending_building]
	for key in cost: resources[key]-=cost[key]
	var structure:=Node2D.new()
	structure.set_script(BuildingScript)
	structure.team=0
	structure.max_health=500 if pending_building=="Guard Tower" else 200 if pending_building=="Wall" else 300
	structure.health=structure.max_health
	structure.building_type=pending_building
	structure.building_upgrade_level=int(building_upgrade_levels.get(pending_building,1))
	structure.is_complete=false
	structure.name=pending_building
	structure.position=pos
	var shape:=Polygon2D.new()
	shape.polygon=PackedVector2Array([Vector2(0,-26),Vector2(24,-10),Vector2(24,12),Vector2(0,28),Vector2(-24,12),Vector2(-24,-10)])
	shape.color={"Farm":Color(0.65,0.55,0.25),"House":Color(0.65,0.3,0.22),"Barracks":Color(0.3,0.32,0.4),"Guard Tower":Color(0.35,0.55,0.65),"Wall":Color(0.45,0.42,0.38),"Warehouse":Color(0.55,0.48,0.32),"Lumber Mill":Color(0.35,0.52,0.25),"Quarry":Color(0.48,0.48,0.52),"Gold Mine":Color(0.72,0.62,0.22),"Mill":Color(0.75,0.72,0.48),"Watchtower":Color(0.55,0.68,0.72),"Market":Color(0.62,0.38,0.28),"Motivation Center":Color(0.42,0.52,0.68)}[pending_building]
	structure.add_child(shape)
	var label:=Label.new()
	label.name="BuildingNameLabel"
	label.text=pending_building
	label.position=Vector2(-32,-42)
	label.scale=Vector2(0.8,0.8)
	structure.add_child(label)
	add_child(structure)
	buildings.append(structure)
	construction_sites.append(structure)
	assign_builder_to_site(structure)
	placing_building=false
	if is_instance_valid(building_ghost): building_ghost.queue_free(); building_ghost=null
	help_label.text="Tap units then tap destination. Drag to pan."
	update_status()


func find_upgrading_building_at(pos:Vector2)->Node2D:
	var nearest:Node2D=null
	var best_distance:=110.0
	for structure in buildings:
		if is_instance_valid(structure) and structure.team==0 and structure.is_upgrading:
			var distance=structure.position.distance_to(pos)
			if distance<best_distance:
				best_distance=distance
				nearest=structure
	return nearest

func assign_selected_workers_to_upgrade(structure:Node2D)->void:
	if not is_instance_valid(structure) or not structure.is_upgrading:return
	var assigned:=0
	var rejected:=0
	for worker in selected:
		if not is_instance_valid(worker) or worker.team!=0:continue
		if worker.upgrade_target_building==structure:continue
		if structure.get_upgrade_worker_count()>=8:
			rejected+=1
			continue
		if worker.upgrade_target(structure):
			assigned+=1
	if assigned>0:
		help_label.text="Added %d worker(s) to upgrade — %d/8 workers" % [assigned,structure.get_upgrade_worker_count()]
	elif rejected>0:
		help_label.text="Upgrade worker limit reached (8)"
	else:
		help_label.text="No new workers assigned — %d/8 workers" % structure.get_upgrade_worker_count()

func find_unfinished_building_at(pos:Vector2)->Node2D:
	var nearest:Node2D=null
	# Larger hit radius for unfinished sites, whose labels and progress bars
	# can make their visible footprint larger than their center.
	var best_distance:=110.0
	for site in construction_sites:
		if is_instance_valid(site) and site.team==0 and not site.is_complete:
			var distance=site.position.distance_to(pos)
			if distance<best_distance:
				best_distance=distance
				nearest=site
	return nearest

func cancel_selected_construction()->void:
	var site=selected_building
	if not is_instance_valid(site) or site.is_complete or not construction_sites.has(site):
		help_label.text="Select an unfinished building first"
		return
	var cost:Dictionary=building_cost.get(site.building_type,{})
	for key in cost:
		resources[key]+=int(floor(float(cost[key])*0.6))
	# Release any builder assigned to this site and stop its movement/work state.
	for unit in units:
		if is_instance_valid(unit) and unit.build_target_site==site:
			unit.build_target_site=null
			unit.moving=false
			unit.path_pending=false
			unit.route=PackedVector2Array()
			unit.route_index=0
			unit.destination=unit.position
	if site.building_type=="House":
		population_cap=max(8,population_cap-5)
	construction_sites.erase(site)
	buildings.erase(site)
	storage_points.erase(site)
	if is_instance_valid(site):site.queue_free()
	selected_building=null
	if is_instance_valid(cancel_build_button):cancel_build_button.visible=false
	help_label.text="Construction cancelled — 60% of resources refunded"
	update_status()

func demolish_selected_building()->void:
	var structure=selected_building
	if not is_instance_valid(structure) or structure.team!=0 or not structure.is_complete or structure.building_type=="Town Center" or not buildings.has(structure):
		help_label.text="Select a completed building to demolish"
		return
	var cost:Dictionary=building_cost.get(structure.building_type,{})
	for key in cost:
		resources[key]+=int(floor(float(cost[key])*0.15))
	if structure.building_type=="Motivation Center":
		stop_motivation_effect()
	elif structure.building_type=="House":
		population_cap=max(8,population_cap-5)
	elif structure.building_type=="Warehouse":
		storage_capacity=max(4000,storage_capacity-(2000 if structure.building_upgrade_level>=2 else 1000))
		storage_points.erase(structure)
		reduce_resources_to_capacity()
	buildings.erase(structure)
	if structure.building_type=="Motivation Center":close_motivation_center_window()
	construction_sites.erase(structure)
	if is_instance_valid(structure):structure.queue_free()
	selected_building=null
	if is_instance_valid(cancel_build_button):cancel_build_button.visible=false
	if is_instance_valid(demolish_building_button):demolish_building_button.visible=false
	if is_instance_valid(upgrade_town_center_button):upgrade_town_center_button.visible=false
	if is_instance_valid(upgrade_building_button):upgrade_building_button.visible=false
	help_label.text="Building demolished — 15% of resources refunded"
	update_status()

func is_worker_idle(unit:Node2D)->bool:
	return is_instance_valid(unit) and unit.team==0 and unit.health>0 and not unit.moving and not unit.path_pending and unit.target==null and unit.harvest_target_node==null and unit.resume_harvest_node==null and unit.storage_target==null and unit.build_target_site==null and unit.upgrade_target_building==null

func assign_builder_to_site(site:Node2D)->void:
	var builder:Node2D=null
	var nearest=INF
	for unit in units:
		if is_worker_idle(unit):
			var d=unit.position.distance_to(site.position)
			if d<nearest:nearest=d;builder=unit
	if builder!=null:builder.build_target(site)

func player_unit_died(unit:Node2D)->void:
	if unit!=null and unit.team==0:
		population=max(0,population-1)
		update_status()

func upgrade_selected_town_center()->void:
	var tc=selected_building
	if not is_instance_valid(tc) or tc.building_type!="Town Center" or tc.town_center_level>=2 or tc.is_upgrading:
		help_label.text="Town Center is already upgrading or cannot be upgraded"
		return
	var cost={"wood":200,"gold":150,"stone":100}
	for key in cost:
		if resources.get(key,0)<cost[key]:
			help_label.text="Town Center upgrade requires 200 wood, 150 gold and 100 stone"
			return
	for key in cost:resources[key]-=cost[key]
	var builder:Node2D=null
	var nearest=INF
	for worker in units:
		if is_worker_idle(worker):
			var d=worker.position.distance_to(tc.position)
			if d<nearest:nearest=d;builder=worker
	if builder==null:
		for key in cost:resources[key]+=cost[key]
		help_label.text="No available worker to upgrade Town Center"
		return
	tc.begin_upgrade()
	builder.upgrade_target(tc)
	if is_instance_valid(upgrade_town_center_button):upgrade_town_center_button.visible=false
	help_label.text="Town Center upgrade started — Level 2"
	update_status()

func find_town_center_level()->int:
	for b in buildings:
		if is_instance_valid(b) and b.team==0 and b.building_type=="Town Center":return b.town_center_level
	return 1

func upgrade_selected_building()->void:
	var b=selected_building
	if not is_instance_valid(b) or b.team!=0 or not b.is_complete or b.building_type=="Town Center" or b.is_upgrading or b.building_upgrade_level>=2:
		help_label.text="Select an eligible completed building"
		return
	if find_town_center_level()<2:
		help_label.text="Upgrade Town Center to Level 2 first"
		return
	var cost={"wood":120,"gold":80,"stone":60}
	for key in cost:
		if resources.get(key,0)<cost[key]:
			help_label.text="Building upgrade requires 120 wood, 80 gold and 60 stone"
			return
	var worker:Node2D=null
	var nearest=INF
	for w in units:
		if is_worker_idle(w):
			var d=w.position.distance_to(b.position)
			if d<nearest:nearest=d;worker=w
	if worker==null:
		help_label.text="No available worker to upgrade this building"
		return
	for key in cost:resources[key]-=cost[key]
	b.begin_building_upgrade()
	worker.upgrade_target(b)
	if is_instance_valid(upgrade_building_button):upgrade_building_button.visible=false
	help_label.text="Building upgrade started — Level 2"
	update_status()

func building_upgrade_completed(b:Node2D)->void:
	building_upgrade_levels[b.building_type]=2
	if b.building_type=="House":population_cap+=3
	elif b.building_type=="Warehouse":storage_capacity+=1000
	elif b.building_type=="Watchtower":
		b.update_range_indicator_geometry()
	elif b.building_type=="Guard Tower":
		b.attack_range+=50.0
		b.attack_damage+=10
		b.update_range_indicator_geometry()
	elif b.building_type=="Barracks":
		b.max_health+=150
		b.health+=150
		b.update_health_bar()
	elif b.building_type=="Lumber Mill":pass
	elif b.building_type=="Gold Mine":pass
	elif b.building_type=="Mill":pass
	elif b.building_type=="Wall":
		b.max_health+=100
		b.health+=100
		b.update_health_bar()
	update_status()

func watchtower_alert(tower:Node2D, enemy_count_detected:int)->void:
	if watchtower_alert_cooldown>0.0:
		return
	watchtower_alert_cooldown=15.0
	if is_instance_valid(help_label):
		help_label.text="WARNING: %d enemy unit(s) detected!" % enemy_count_detected

func building_completed(b:Node2D)->void:
	construction_sites.erase(b)
	if b.team==0:
		if b.building_type=="House" and b.building_upgrade_level<2:
			population_cap+=5
		var name_label:Label=b.get_node_or_null("BuildingNameLabel")
		if is_instance_valid(name_label):
			name_label.text=b.building_type + (" Level 2" if b.building_upgrade_level>=2 else "")
		if b.building_type=="House" and b.building_upgrade_level>=2:
			population_cap+=3
		elif b.building_type=="Warehouse":
			storage_capacity+=1000
			if b.building_upgrade_level>=2:
				storage_capacity+=1000
			if not storage_points.has(b):
				storage_points.append(b)
		elif b.building_type=="Guard Tower" and b.building_upgrade_level>=2:
			b.attack_range+=50.0
			b.attack_damage+=10
			b.update_range_indicator_geometry()
		elif b.building_type=="Barracks" and b.building_upgrade_level>=2:
			b.max_health+=150
			b.health+=150
			b.update_health_bar()
		elif b.building_type=="Wall" and b.building_upgrade_level>=2:
			b.max_health+=100
			b.health+=100
			b.update_health_bar()
	update_status()

func toggle_pause()->void:
	game_paused=not game_paused
	get_tree().paused=game_paused
	if is_instance_valid(pause_toggle_button):
		pause_toggle_button.text="Resume" if game_paused else "Pause"
	if is_instance_valid(help_label):
		help_label.text="Game paused — press Resume to continue" if game_paused else "Game resumed"

func toggle_enemy()->void:
	enemy_enabled=not enemy_enabled
	if is_instance_valid(enemy_toggle_button):
		enemy_toggle_button.text="Enemy: ON" if enemy_enabled else "Enemy: OFF"
	if not enemy_enabled:
		enemy_attack_active=false
		enemy_attack_group.clear()
		for u in units:
			if is_instance_valid(u) and u.team==1:
				u.target=null
				u.harvest_target_node=null
				u.storage_target=null
				u.build_target_site=null
				u.resume_harvest_node=null
				u.moving=false
				u.path_pending=false
				u.route=PackedVector2Array()
				u.route_index=0
				u.destination=u.position
				u.acquire_timer=999999.0
	else:
		for u in units:
			if is_instance_valid(u) and u.team==1:
				u.acquire_timer=0.0
	update_status()
	help_label.text="Enemy activity disabled for testing" if not enemy_enabled else "Enemy activity enabled"

func update_status() -> void:
	if status_label:
		status_label.text="Wood: %d  Food: %d  Gold: %d  Stone: %d\nPopulation: %d/%d  Selected: %d  Enemies: %d\nBuildings: %d  Enemy base: %d  Storage: %d" % [resources.wood,resources.food,resources.gold,resources.stone,population,population_cap,selected.size(),enemy_count(),buildings.size(),enemy_buildings.size(),storage_capacity]

func _process(delta:float) -> void:
	if worker_training_remaining>0.0:
		worker_training_remaining=max(0.0,worker_training_remaining-delta)
		if is_instance_valid(recruit_worker_button):
			recruit_worker_button.text="Training: %ds" % ceili(worker_training_remaining)
		if worker_training_remaining<=0.0:
			complete_worker_training()
	watchtower_alert_cooldown=max(0.0,watchtower_alert_cooldown-delta)
	if motivation_time_remaining>0.0:
		var center_exists:=false
		for building in buildings:
			if is_instance_valid(building) and building.health>0 and building.team==0 and building.building_type=="Motivation Center" and building.is_complete:
				center_exists=true
				break
		if center_exists:
			motivation_time_remaining=max(0.0,motivation_time_remaining-delta)
		else:
			stop_motivation_effect()
		if motivation_time_remaining<=0.0:
			motivation_time_remaining=0.0
		update_motivation_center_display()
	if placing_building and is_instance_valid(building_ghost): update_building_ghost()
	if enemy_attack_active:
		monitor_enemy_attack()
	units=units.filter(func(u): return is_instance_valid(u) and u.health>0)
	process_pathfinding_queue()
	buildings=buildings.filter(func(b): return is_instance_valid(b) and b.health>0)
	enemy_buildings=enemy_buildings.filter(func(b): return is_instance_valid(b) and b.health>0)
	selected=selected.filter(func(u): return is_instance_valid(u) and u.health>0)
	if enemy_enabled:
		enemy_ai_timer += delta
		if enemy_ai_timer >= 8.0:
			enemy_ai_timer = 0.0
			enemy_ai_step()
		enemy_attack_timer += delta
		if enemy_attack_timer >= enemy_attack_cooldown:
			enemy_attack_timer = 0.0
			enemy_attack_level = min(enemy_attack_level + 1, 5)
			enemy_attack_cooldown = max(20.0, 42.0 - enemy_attack_level * 4.0)
			if not enemy_attack_active:
				begin_enemy_attack()
	income_timer+=delta
	if income_timer>=5.0:
		income_timer=0.0
		for b in buildings:
			if b.is_complete and b.name=="Farm":
				deliver_resource("food",int(round(10.0*(1.3 if b.building_upgrade_level>=2 else 1.0))))
			elif b.is_complete and b.name=="Lumber Mill" and b.has_active_production_worker():
				deliver_resource("wood",get_worker_production_amount(b))
			elif b.is_complete and b.name=="Quarry" and b.has_active_production_worker():
				deliver_resource("stone",get_worker_production_amount(b))
			elif b.is_complete and b.name=="Gold Mine" and b.has_active_production_worker():
				deliver_resource("gold",get_worker_production_amount(b))
			elif b.is_complete and b.name=="Mill" and b.has_active_production_worker():
				deliver_resource("food",get_worker_production_amount(b))
		update_status()
	var motion:=Vector2.ZERO
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT): motion.x+=1
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT): motion.x-=1
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP): motion.y+=1
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN): motion.y-=1
	if motion!=Vector2.ZERO:
		camera_offset+=motion.normalized()*520.0*delta
		update_view()

func create_enemy_base() -> void:
	# Visible enemy settlement on the opposite side of the map.
	create_enemy_building("Enemy Town Center", grid_to_screen(Vector2i(28, 28)))
	create_enemy_building("Enemy Barracks", grid_to_screen(Vector2i(26, 28)))
	create_enemy_building("Enemy Farm", grid_to_screen(Vector2i(28, 30)))

func create_enemy_building(building_name:String, pos:Vector2) -> void:
	var structure:=Node2D.new()
	structure.set_script(BuildingScript)
	structure.team=1
	structure.max_health=500 if building_name=="Enemy Town Center" else 300
	structure.health=structure.max_health
	structure.name=building_name
	structure.position=pos
	var shape:=Polygon2D.new()
	shape.polygon=PackedVector2Array([Vector2(0,-26),Vector2(24,-10),Vector2(24,12),Vector2(0,28),Vector2(-24,12),Vector2(-24,-10)])
	shape.color=Color(0.72,0.24,0.18)
	structure.add_child(shape)
	var label:=Label.new()
	label.text=building_name
	label.position=Vector2(-42,-44)
	label.scale=Vector2(0.7,0.7)
	structure.add_child(label)
	add_child(structure)
	enemy_buildings.append(structure)

func enemy_ai_step() -> void:
	if not enemy_enabled:return
	# Basic resource gathering, expansion, and periodic recruitment.
	enemy_resources.food+=18
	enemy_resources.gold+=8
	enemy_resources.wood+=12
	if enemy_buildings.size()<5 and enemy_resources.wood>=100 and enemy_resources.gold>=40:
		enemy_resources.wood-=100
		enemy_resources.gold-=40
		create_enemy_building("Enemy Farm", grid_to_screen(Vector2i(27+enemy_buildings.size()%3,30+enemy_buildings.size()/3)))
	if enemy_population_cap<14 and enemy_resources.wood>=100 and enemy_resources.gold>=50:
		enemy_resources.wood-=100
		enemy_resources.gold-=50
		enemy_population_cap+=4
		create_enemy_building("Enemy House",grid_to_screen(Vector2i(30,26+enemy_buildings.size()%4)))
	if enemy_population<enemy_population_cap and enemy_resources.food>=45 and enemy_resources.gold>=20 and enemy_has_barracks():
		enemy_resources.food-=45
		enemy_resources.gold-=20
		enemy_population+=1
		var soldier:Node2D=UnitScene.instantiate()
		add_child(soldier)
		soldier.set_team(1)
		soldier.position=grid_to_screen(Vector2i(25,27))+Vector2(20*enemy_population%60,16)
		units.append(soldier)
		if enemy_population>=10 and enemy_buildings.size()<7 and enemy_resources.wood>=150 and enemy_resources.gold>=70:
			enemy_resources.wood-=150
			enemy_resources.gold-=70
			create_enemy_building("Enemy Barracks",grid_to_screen(Vector2i(30,29)))
	update_status()

func enemy_has_barracks() -> bool:
	for b in enemy_buildings:
		if b.name=="Enemy Barracks": return true
	return false

func begin_enemy_attack() -> void:
	if not enemy_enabled:return
	var squad:Array[Node2D]=[]
	for u in units:
		if is_instance_valid(u) and u.team==1 and u.health>0:
			squad.append(u)
	var required:int = min(3+enemy_attack_level,6)
	if squad.size()<required: return
	enemy_attack_group=squad
	enemy_attack_active=true
	enemy_attack_losses=0
	# Muster at the enemy barracks before advancing as a group.
	var muster=grid_to_screen(Vector2i(26,28))
	for i in range(squad.size()): squad[i].move_to(muster+Vector2((i%3)*22,(i/3)*20))
	await get_tree().create_timer(3.0).timeout
	if not is_inside_tree() or not enemy_attack_active: return
	var target_structure:Node2D=null
	for b in buildings:
		if is_instance_valid(b) and b.health>0:
			if target_structure==null or b.name=="Barracks": target_structure=b
	if target_structure!=null:
		for soldier in enemy_attack_group:
			if is_instance_valid(soldier) and soldier.health>0: soldier.attack_target(target_structure)
	else:
		var fallback=grid_to_screen(Vector2i(12,12))
		for i in range(enemy_attack_group.size()):
			var soldier=enemy_attack_group[i]
			if is_instance_valid(soldier) and soldier.health>0: soldier.move_to(fallback+Vector2((i%3)*24,(i/3)*24))

func monitor_enemy_attack() -> void:
	if not enemy_enabled:return
	var living:=0
	for soldier in enemy_attack_group:
		if is_instance_valid(soldier) and soldier.health>0: living+=1
	var initial=enemy_attack_group.size()
	if initial>0 and living<=initial/2:
		# Retreat the surviving attack force to its base.
		var retreat=grid_to_screen(Vector2i(26,28))
		for i in range(enemy_attack_group.size()):
			var soldier=enemy_attack_group[i]
			if is_instance_valid(soldier) and soldier.health>0: soldier.move_to(retreat+Vector2((i%3)*20,(i/3)*20))
		enemy_attack_active=false
		enemy_attack_group.clear()
		return
	if living==0:
		enemy_attack_active=false
		enemy_attack_group.clear()

func request_path(unit:Node2D,to_pos:Vector2)->void:
	if not pathfinding_queue.has(unit):
		pathfinding_queue.append(unit)
	unit.pending_path_destination=to_pos

func process_pathfinding_queue()->void:
	var count=min(pathfinding_budget,pathfinding_queue.size())
	for i in range(count):
		var unit=pathfinding_queue.pop_front()
		if is_instance_valid(unit):
			unit.execute_pending_path()

func world_to_grid(pos:Vector2)->Vector2i:
	var sx=pos.x/32.0
	var sy=pos.y/16.0
	return Vector2i(roundi((sx+sy)/2.0),roundi((sy-sx)/2.0))

func is_cell_blocked(cell:Vector2i,mover:Node2D)->bool:
	if cell.x<0 or cell.y<0 or cell.x>=GRID.x or cell.y>=GRID.y:return true
	var p=grid_to_screen(cell)
	for b in buildings+enemy_buildings:
		if is_instance_valid(b) and b.health>0 and p.distance_to(b.position)<42.0:return true
	for t in tree_positions:
		if p.distance_to(t)<30.0:return true
	# Units are dynamic: do not bake their temporary positions into A* paths.
	# Soft separation and local steering are handled during movement instead.
	return false

func find_path(start_pos:Vector2,end_pos:Vector2,mover:Node2D)->PackedVector2Array:
	var start=world_to_grid(start_pos)
	var finish=world_to_grid(end_pos)
	if start==finish:return PackedVector2Array([end_pos])
	# Keep the search local to a small rectangle around the order.
	var margin=8
	var min_x=max(0,min(start.x,finish.x)-margin)
	var max_x=min(GRID.x-1,max(start.x,finish.x)+margin)
	var min_y=max(0,min(start.y,finish.y)-margin)
	var max_y=min(GRID.y-1,max(start.y,finish.y)+margin)
	var open:Array[Vector2i]=[start]
	var closed:Dictionary={}
	var came_from:Dictionary={}
	var costs:Dictionary={start:0.0}
	var scores:Dictionary={start:float(start.distance_to(finish))}
	var visited=0
	while not open.is_empty() and visited<140:
		# Find the lowest score without repeatedly sorting the whole open list.
		var best_index=0
		var best_score=float(scores.get(open[0],INF))
		for oi in range(1,open.size()):
			var candidate_score=float(scores.get(open[oi],INF))
			if candidate_score<best_score:
				best_score=candidate_score
				best_index=oi
		var current=open.pop_at(best_index)
		if closed.has(current):continue
		closed[current]=true
		visited+=1
		if current==finish:break
		for delta in [Vector2i(1,0),Vector2i(-1,0),Vector2i(0,1),Vector2i(0,-1),Vector2i(1,1),Vector2i(1,-1),Vector2i(-1,1),Vector2i(-1,-1)]:
			var next=current+delta
			if next.x<min_x or next.x>max_x or next.y<min_y or next.y>max_y:continue
			if closed.has(next):continue
			if next!=finish and is_cell_blocked(next,mover):continue
			var step=1.0 if abs(delta.x)+abs(delta.y)==1 else 1.4
			var new_cost=costs[current]+step
			if new_cost<costs.get(next,INF):
				came_from[next]=current
				costs[next]=new_cost
				scores[next]=new_cost+float(next.distance_to(finish))
				if not open.has(next):open.append(next)
	if not came_from.has(finish):return PackedVector2Array([end_pos])
	var cells:Array[Vector2i]=[]
	var cell=finish
	while cell!=start:
		cells.push_front(cell)
		if not came_from.has(cell):break
		cell=came_from[cell]
	var points:=PackedVector2Array()
	for cell_point in cells:
		points.append(grid_to_screen(cell_point))
	points.append(end_pos)
	return points

func is_unit_position_blocked(pos:Vector2, mover:Node2D, attack_target:Node2D=null) -> bool:
	# Buildings block movement; the active target is exempt so units can approach it.
	for structure in buildings + enemy_buildings:
		if is_instance_valid(structure) and structure!=attack_target and structure.health>0 and pos.distance_to(structure.position)<34.0:
			return true
	# Trees are solid obstacles for movement.
	for tree_pos in tree_positions:
		if pos.distance_to(tree_pos)<26.0:
			return true
	# Unit collisions are soft: only prevent near-exact overlap, so crowds can flow past each other.
	for other in units:
		if is_instance_valid(other) and other!=mover and other.health>0 and pos.distance_to(other.position)<12.0:
			return true
	return false
func get_motivation_center()->Node2D:
	for building in buildings:
		if is_instance_valid(building) and building.team==0 and building.health>0 and building.building_type=="Motivation Center" and building.is_complete:
			return building
	return null

func get_motivation_gather_amount(base_amount:int)->int:
	if motivation_time_remaining<=0.0:
		return base_amount
	return int(round(float(base_amount)*motivation_production_multiplier))

func get_worker_production_amount(building:Node2D)->int:
	var amount:=10.0*(1.3 if building.building_upgrade_level>=2 else 1.0)
	if motivation_time_remaining>0.0:
		amount*=motivation_production_multiplier
	return int(round(amount))

func activate_motivation_effect()->void:
	var center:=get_motivation_center()
	if center==null or center!=selected_building:
		if is_instance_valid(motivation_status_label):
			motivation_status_label.text="Select the Motivation Center to activate."
		return
	if motivation_time_remaining>0.0:
		return
	var cost_gold:int=900 if center.building_upgrade_level>=2 else 500
	var cost_food:int=1000 if center.building_upgrade_level>=2 else 800
	if resources["gold"]<cost_gold or resources["food"]<cost_food:
		if is_instance_valid(motivation_status_label):
			motivation_status_label.text="Not enough resources: need %d Gold and %d Food." % [cost_gold,cost_food]
		return
	resources["gold"]=int(resources["gold"])-cost_gold
	resources["food"]=int(resources["food"])-cost_food
	motivation_time_remaining=MOTIVATION_DURATION_L2 if center.building_upgrade_level>=2 else MOTIVATION_DURATION_L1
	motivation_production_multiplier=1.25 if center.building_upgrade_level>=2 else 1.15
	update_status()
	update_motivation_center_display()

func stop_motivation_effect()->void:
	motivation_time_remaining=0.0
	motivation_production_multiplier=1.0
	update_motivation_center_display()

func update_motivation_center_display()->void:
	if not is_instance_valid(motivation_panel):
		return
	var center:=get_motivation_center()
	if center==null:
		motivation_status_label.text="Motivation Center unavailable."
		motivation_activate_button.disabled=true
		if is_instance_valid(motivation_upgrade_button):motivation_upgrade_button.visible=false
		return
	if is_instance_valid(motivation_upgrade_button):
		motivation_upgrade_button.visible=center.building_upgrade_level<2 and not center.is_upgrading and find_town_center_level()>=2
	if motivation_time_remaining>0.0:
		var seconds_left:=ceili(motivation_time_remaining)
		motivation_status_label.text="ACTIVE — %02d:%02d remaining | +%d%% worker production" % [int(seconds_left/60),seconds_left%60,25 if center.building_upgrade_level>=2 else 15]
		motivation_activate_button.text="Active"
		motivation_activate_button.disabled=true
	else:
		motivation_status_label.text="Inactive — activation costs %d Gold and %d Food." % [900 if center.building_upgrade_level>=2 else 500,1000 if center.building_upgrade_level>=2 else 800]
		motivation_activate_button.text="Activate"
		motivation_activate_button.disabled=false

func open_motivation_center_window()->void:
	if is_instance_valid(motivation_panel):
		update_motivation_center_display()
		return
	motivation_panel=PanelContainer.new()
	motivation_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	motivation_panel.position=Vector2(-190,-125)
	motivation_panel.size=Vector2(380,250)
	motivation_panel.custom_minimum_size=Vector2(380,250)
	motivation_panel.z_index=200
	motivation_panel.add_theme_stylebox_override("panel",make_panel_style())
	hud.add_child(motivation_panel)
	var v:=VBoxContainer.new()
	v.add_theme_constant_override("separation",10)
	motivation_panel.add_child(v)
	var title:=Label.new()
	title.text="MOTIVATION CENTER"
	title.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)
	motivation_status_label=Label.new()
	motivation_status_label.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
	motivation_status_label.autowrap_mode=TextServer.AUTOWRAP_WORD_SMART
	v.add_child(motivation_status_label)
	motivation_activate_button=Button.new()
	motivation_activate_button.text="Activate"
	motivation_activate_button.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	motivation_activate_button.pressed.connect(activate_motivation_effect)
	v.add_child(motivation_activate_button)
	motivation_upgrade_button=Button.new()
	motivation_upgrade_button.text="Upgrade to Level 2 — 120 Wood, 80 Gold, 60 Stone"
	motivation_upgrade_button.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	motivation_upgrade_button.pressed.connect(func():
		close_motivation_center_window()
		upgrade_selected_building()
	)
	v.add_child(motivation_upgrade_button)
	var demolish_button:=Button.new()
	demolish_button.text="Demolish (15%)"
	demolish_button.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	demolish_button.pressed.connect(func():
		close_motivation_center_window()
		demolish_selected_building()
	)
	v.add_child(demolish_button)
	var close_button:=Button.new()
	close_button.text="Close"
	close_button.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	close_button.pressed.connect(close_motivation_center_window)
	v.add_child(close_button)
	update_motivation_center_display()

func close_motivation_center_window()->void:
	if is_instance_valid(motivation_panel):
		motivation_panel.queue_free()
	motivation_panel=null
	motivation_status_label=null
	motivation_activate_button=null
	motivation_upgrade_button=null

func open_market_window()->void:
	if market_window_open:return
	market_window_open=true
	market_panel=PanelContainer.new()
	market_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	market_panel.position=Vector2(-210,-175)
	market_panel.size=Vector2(420,350)
	market_panel.custom_minimum_size=Vector2(420,350)
	market_panel.z_index=200
	market_panel.add_theme_stylebox_override("panel",make_panel_style())
	hud.add_child(market_panel)
	var v:=VBoxContainer.new()
	v.add_theme_constant_override("separation",8)
	market_panel.add_child(v)
	var title:=Label.new()
	var market_level=selected_building.building_upgrade_level if is_instance_valid(selected_building) else 1
	title.text="MARKET — LEVEL %d" % market_level
	title.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)
	var market_info:=Label.new()
	market_info.text="Level 2 bonus: +20% when buying Gold or Stone." if market_level>=2 else "Standard exchange rates."
	market_info.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(market_info)
	var sell_row:=HBoxContainer.new()
	v.add_child(sell_row)
	var sell_label:=Label.new()
	sell_label.text="Sell:"
	sell_row.add_child(sell_label)
	market_sell_option=OptionButton.new()
	for resource in ["food","wood","stone","gold"]:
		market_sell_option.add_item(resource.capitalize())
	sell_row.add_child(market_sell_option)
	var buy_row:=HBoxContainer.new()
	v.add_child(buy_row)
	var buy_label:=Label.new()
	buy_label.text="Buy:"
	buy_row.add_child(buy_label)
	market_buy_option=OptionButton.new()
	for resource in ["food","wood","stone","gold"]:
		market_buy_option.add_item(resource.capitalize())
	market_buy_option.select(1)
	buy_row.add_child(market_buy_option)
	var amount_row:=HBoxContainer.new()
	v.add_child(amount_row)
	var amount_label:=Label.new()
	amount_label.text="Amount to sell (min 10):"
	amount_row.add_child(amount_label)
	market_amount_spin=SpinBox.new()
	market_amount_spin.min_value=10
	market_amount_spin.max_value=max(10,resources["food"])
	market_amount_spin.value=10
	market_amount_spin.step=1
	market_amount_spin.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	amount_row.add_child(market_amount_spin)
	var subtract_10_button:=Button.new()
	subtract_10_button.text="-10"
	subtract_10_button.pressed.connect(func(): adjust_market_amount(-10))
	amount_row.add_child(subtract_10_button)
	var add_10_button:=Button.new()
	add_10_button.text="+10"
	add_10_button.pressed.connect(func(): adjust_market_amount(10))
	amount_row.add_child(add_10_button)
	var subtract_100_button:=Button.new()
	subtract_100_button.text="-100"
	subtract_100_button.pressed.connect(func(): adjust_market_amount(-100))
	amount_row.add_child(subtract_100_button)
	var add_100_button:=Button.new()
	add_100_button.text="+100"
	add_100_button.pressed.connect(func(): adjust_market_amount(100))
	amount_row.add_child(add_100_button)
	market_preview_label=Label.new()
	market_preview_label.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(market_preview_label)
	var market_upgrade_button:=Button.new()
	market_upgrade_button.text="Upgrade Market (L2) — 120W 80G 60S"
	market_upgrade_button.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	market_upgrade_button.visible=market_level<2 and is_instance_valid(selected_building) and selected_building.is_complete and not selected_building.is_upgrading and find_town_center_level()>=2
	market_upgrade_button.pressed.connect(upgrade_market_from_window)
	v.add_child(market_upgrade_button)
	var action_row:=HBoxContainer.new()
	v.add_child(action_row)
	var exchange_button:=Button.new()
	exchange_button.text="Exchange"
	exchange_button.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	exchange_button.pressed.connect(execute_market_exchange)
	action_row.add_child(exchange_button)
	var close_button:=Button.new()
	close_button.text="Close"
	close_button.size_flags_horizontal=Control.SIZE_EXPAND_FILL
	close_button.pressed.connect(close_market_window)
	action_row.add_child(close_button)
	market_sell_option.item_selected.connect(update_market_preview)
	market_buy_option.item_selected.connect(update_market_preview)
	market_amount_spin.value_changed.connect(update_market_preview)
	update_market_preview(0)

func upgrade_market_from_window()->void:
	close_market_window()
	upgrade_selected_building()

func close_market_window()->void:
	market_window_open=false
	if is_instance_valid(market_panel):
		market_panel.queue_free()
	market_panel=null

func market_resource_name(index:int)->String:
	return ["food","wood","stone","gold"][index]

func adjust_market_amount(delta:int)->void:
	if not is_instance_valid(market_amount_spin):return
	var sell_type=market_resource_name(market_sell_option.selected)
	market_amount_spin.max_value=max(10,int(resources[sell_type]))
	market_amount_spin.value=clamp(market_amount_spin.value+delta,10,market_amount_spin.max_value)
	update_market_preview(0)

func market_received_amount(sell_type:String,buy_type:String,amount:int)->int:
	var received=float(amount)*MARKET_PRICES[sell_type]/MARKET_PRICES[buy_type]
	if is_instance_valid(selected_building) and selected_building.building_type=="Market" and selected_building.building_upgrade_level>=2 and buy_type in ["gold","stone"]:
		received*=1.2
	return int(floor(received))

func update_market_preview(_value:float)->void:
	if not is_instance_valid(market_preview_label):return
	var sell_type=market_resource_name(market_sell_option.selected)
	var buy_type=market_resource_name(market_buy_option.selected)
	var amount=int(market_amount_spin.value)
	if sell_type==buy_type:
		market_preview_label.text="Choose two different resources."
		return
	var received=market_received_amount(sell_type,buy_type,amount)
	market_preview_label.text="You receive: %d %s\nOwned: %d %s" % [received,buy_type.capitalize(),resources[sell_type],sell_type.capitalize()]
	market_amount_spin.max_value=max(10,int(resources[sell_type]))

func execute_market_exchange()->void:
	var sell_type=market_resource_name(market_sell_option.selected)
	var buy_type=market_resource_name(market_buy_option.selected)
	var amount=int(market_amount_spin.value)
	if sell_type==buy_type:
		market_preview_label.text="Choose two different resources."
		return
	if amount<MARKET_MIN_AMOUNT:
		market_preview_label.text="Minimum sale is 10 units."
		return
	if amount>int(resources.get(sell_type,0)):
		market_preview_label.text="Not enough %s." % sell_type.capitalize()
		return
	var received=market_received_amount(sell_type,buy_type,amount)
	if received<1:
		market_preview_label.text="Exchange amount is too small."
		return
	var total=int(resources.food)+int(resources.wood)+int(resources.gold)+int(resources.stone)
	if total-amount+received>storage_capacity:
		market_preview_label.text="Storage limit would be exceeded."
		return
	resources[sell_type]-=amount
	resources[buy_type]+=received
	update_status()
	update_market_preview(0)
	market_preview_label.text="Exchange successful: %d %s for %d %s." % [amount,sell_type.capitalize(),received,buy_type.capitalize()]

