extends Node2D

var team:int=0
var selected:bool=false
var destination:=Vector2.ZERO
var route:PackedVector2Array=PackedVector2Array()
var route_index:=0
var stuck_timer:=0.0
var last_position:=Vector2.ZERO
var moving:=false
var speed:=120.0
var max_health:=100
var health:=100
var attack_damage:=15
var attack_range:=42.0
var detection_range:=220.0
var attack_cooldown:=1.0
var attack_timer:=0.0
var acquire_timer:=0.0
var target_path_timer:=0.0
var pending_path_destination:=Vector2.ZERO
var path_pending:=false
var harvest_target_node:Node2D=null
var resume_harvest_node:Node2D=null
var harvest_timer:=0.0
var carried_amount:=0
var carried_type:String=""
var cargo_capacity:=100
var storage_target:Node2D=null
var storage_recheck_timer:=0.0
var storage_retry_timer:=0.0
var storage_blocked_by_capacity:=false
var build_target_site:Node2D=null
var upgrade_target_building:Node2D=null
var production_target_building:Node2D=null
var target:Node2D=null
var body:Polygon2D
var ring:Line2D
var health_bar:Polygon2D
var death_notified:=false

func _ready()->void:
	destination=position
	body=Polygon2D.new()
	body.polygon=PackedVector2Array([Vector2(0,-14),Vector2(9,-4),Vector2(7,8),Vector2(0,13),Vector2(-7,8),Vector2(-9,-4)])
	body.color=team_color()
	body.name="Body"
	add_child(body)
	ring=Line2D.new()
	ring.name="Ring"
	ring.points=PackedVector2Array([Vector2(-15,0),Vector2(0,-8),Vector2(15,0),Vector2(0,8),Vector2(-15,0)])
	ring.width=2.0
	ring.default_color=Color(1,0.9,0.3)
	add_child(ring)
	ring.visible=false
	health_bar=Polygon2D.new()
	health_bar.position=Vector2(0,-22)
	add_child(health_bar)
	update_health_bar()

func team_color()->Color:
	return Color(0.25,0.48,0.85) if team==0 else Color(0.8,0.25,0.22)

func set_team(t:int)->void:
	team=t
	if is_instance_valid(body):body.color=team_color()

func set_selected(v:bool)->void:
	selected=v
	if is_instance_valid(ring):ring.visible=v

func set_route(to_pos:Vector2)->void:
	var parent=get_parent()
	if parent!=null and parent.has_method("request_path"):
		pending_path_destination=to_pos
		path_pending=true
		parent.request_path(self,to_pos)
	else:
		route=PackedVector2Array([to_pos])
		route_index=0

func execute_pending_path()->void:
	path_pending=false
	var parent=get_parent()
	if parent!=null and parent.has_method("find_path"):
		route=parent.find_path(position,pending_path_destination,self)
	else:
		route=PackedVector2Array([pending_path_destination])
	route_index=0

func clear_production_assignment()->void:
	if is_instance_valid(production_target_building):
		production_target_building.unregister_production_worker(self)
	production_target_building=null

func is_working_for_production(site:Node2D)->bool:
	if storage_blocked_by_capacity:return false
	if production_target_building!=site or not is_instance_valid(site):return false
	var expected_type={"Lumber Mill":"wood","Mill":"food","Gold Mine":"gold","Quarry":"stone"}.get(site.building_type,"")
	if expected_type=="":return false
	if is_instance_valid(harvest_target_node) and harvest_target_node.resource_type==expected_type:return true
	return carried_amount>0 and carried_type==expected_type

func move_to(p:Vector2)->void:
	clear_production_assignment()
	var parent=get_parent()
	if parent!=null and parent.has_method("snap_to_map_cell"):
		p=parent.snap_to_map_cell(p)
	target=null
	harvest_target_node=null
	storage_target=null
	build_target_site=null
	upgrade_target_building=null
	# Manual movement cancels the work assignment, but must not discard carried resources.
	resume_harvest_node=null
	destination=p
	moving=true
	set_route(p)

func harvest_target(node:Node2D)->void:
	if node==null or not is_instance_valid(node) or team!=0:return
	var parent=get_parent()
	if parent!=null and parent.has_method("assign_worker_to_resource_production"):
		parent.assign_worker_to_resource_production(self,node.resource_type)
	target=null
	storage_target=null
	build_target_site=null
	upgrade_target_building=null
	harvest_target_node=node
	resume_harvest_node=node
	storage_blocked_by_capacity=false
	if carried_amount>0:
		return_to_storage()
		return
	moving=true
	destination=node.position
	set_route(destination)

func resume_after_delivery(resource_type:String,parent:Node)->void:
	# Reset the storage/movement state before assigning the worker back to harvesting.
	harvest_timer=0.0
	storage_target=null
	build_target_site=null
	target=null
	carried_amount=0
	carried_type=""
	harvest_target_node=null
	moving=false
	path_pending=false
	route=PackedVector2Array()
	route_index=0
	if is_instance_valid(resume_harvest_node) and resume_harvest_node.amount>0:
		var previous_deposit=resume_harvest_node
		resume_harvest_node=null
		harvest_target(previous_deposit)
		return
	resume_harvest_node=null
	if parent!=null and resource_type!="":
		var next_node=parent.get_nearest_resource_node(position,resource_type)
		if next_node!=null:
			harvest_target(next_node)
			return
	moving=false
	destination=position

func return_to_storage()->void:
	var parent=get_parent()
	if parent==null:return
	harvest_target_node=null
	storage_target=parent.get_nearest_storage(position,carried_type)
	storage_recheck_timer=0.0
	storage_retry_timer=1.0
	moving=storage_target!=null
	path_pending=false
	route=PackedVector2Array()
	route_index=0
	if storage_target!=null:
		destination=storage_target.position
		set_route(destination)
	else:
		moving=false

func get_building_approach_point(site:Node2D)->Vector2:
	if site==null or not is_instance_valid(site):return position
	var away=(position-site.position).normalized()
	if away.length()<0.1:away=Vector2(1,0)
	return site.position+away*52.0

func build_target(site:Node2D)->void:
	clear_production_assignment()
	if team!=0 or site==null or not is_instance_valid(site) or site.is_complete:return
	target=null
	harvest_target_node=null
	storage_target=null
	upgrade_target_building=null
	build_target_site=site
	resume_harvest_node=null
	moving=true
	destination=get_building_approach_point(site)
	set_route(destination)

func upgrade_target(site:Node2D)->bool:
	clear_production_assignment()
	if team!=0 or site==null or not is_instance_valid(site) or not site.is_upgrading:return false
	if upgrade_target_building!=null and is_instance_valid(upgrade_target_building):
		upgrade_target_building.unregister_upgrade_worker(self)
	target=null
	harvest_target_node=null
	storage_target=null
	build_target_site=null
	upgrade_target_building=site
	resume_harvest_node=null
	moving=true
	destination=get_building_approach_point(site)
	if not site.register_upgrade_worker(self):
		upgrade_target_building=null
		moving=false
		return false
	set_route(destination)
	return true

func attack_target(enemy:Node2D)->void:
	clear_production_assignment()
	harvest_target_node=null
	storage_target=null
	build_target_site=null
	if enemy==null or not is_instance_valid(enemy):return
	target=enemy
	target_path_timer=0.0
	moving=false

func acquire_player_target()->void:
	var parent=get_parent()
	if not parent.has_method("enemy_count"):return
	var closest:Node2D=null
	var nearest=detection_range
	for candidate in parent.units:
		if is_instance_valid(candidate) and candidate.team==0 and candidate.health>0:
			var d=position.distance_to(candidate.position)
			if d<nearest:nearest=d;closest=candidate
	if closest!=null:attack_target(closest)

func take_damage(amount:int)->void:
	if health<=0:return
	health=max(0,health-amount)
	update_health_bar()
	if health<=0 and not death_notified:
		death_notified=true
		var parent=get_parent()
		if team==0 and parent!=null and parent.has_method("player_unit_died"):
			parent.player_unit_died(self)
		queue_free()

func update_health_bar()->void:
	if not is_instance_valid(health_bar):return
	var ratio=float(health)/float(max_health)
	health_bar.polygon=PackedVector2Array([Vector2(-12,-2),Vector2(-12+24*ratio,-2),Vector2(-12+24*ratio,2),Vector2(-12,2)])
	health_bar.color=Color(0.2,0.9,0.25) if ratio>0.5 else Color(1,0.65,0.1) if ratio>0.25 else Color(0.95,0.2,0.15)

func _process(delta:float)->void:
	# Retry storage assignment for any full worker whose storage target was lost.
	if team==0 and carried_amount>=cargo_capacity and storage_target==null and not storage_blocked_by_capacity:
		storage_retry_timer-=delta
		if storage_retry_timer<=0.0:
			return_to_storage()
	if storage_target!=null:
		# Periodically reassess storage options while travelling; switch immediately
		# if another live storage has become the closest to the worker's current position.
		storage_recheck_timer-=delta
		if storage_recheck_timer<=0.0:
			storage_recheck_timer=0.6
			var parent_for_storage=get_parent()
			if parent_for_storage!=null and parent_for_storage.has_method("get_nearest_storage"):
				var closest_storage=parent_for_storage.get_nearest_storage(position,carried_type)
				if closest_storage!=storage_target:
					storage_target=closest_storage
					path_pending=false
					route=PackedVector2Array()
					route_index=0
					if storage_target!=null:
						destination=storage_target.position
						set_route(destination)
		if not is_instance_valid(storage_target) or storage_target.health<=0:
			return_to_storage()
		elif position.distance_to(storage_target.position)<=76.0:
			moving=false
			var parent=get_parent()
			if parent!=null and carried_amount>0:
				var delivered=parent.deliver_resource(carried_type,carried_amount)
				carried_amount-=delivered
				if carried_amount<=0:
					var old_type=carried_type
					resume_after_delivery(old_type,parent)
				else:
					# Storage is full: stop here instead of repeatedly attempting an impossible deposit.
					storage_target=null
					storage_blocked_by_capacity=true
					moving=false
		else:
			moving=true
			var approach_direction=(position-storage_target.position).normalized()
			if approach_direction.length()<0.1:approach_direction=Vector2(1,0)
			destination=storage_target.position
			if route.is_empty() or route[route.size()-1].distance_to(destination)>8.0:set_route(destination)
	if harvest_target_node!=null and storage_target==null:
		if not is_instance_valid(harvest_target_node) or harvest_target_node.amount<=0:
			var exhausted_type=carried_type if carried_type!="" else harvest_target_node.resource_type if is_instance_valid(harvest_target_node) else ""
			harvest_target_node=null
			if carried_amount>0:return_to_storage()
			elif exhausted_type!="":
				var next=get_parent().get_nearest_resource_node(position,exhausted_type)
				if next!=null:harvest_target(next)
			else:moving=false
		else:
			var d_h=position.distance_to(harvest_target_node.position)
			if d_h>30.0:
				moving=true
				destination=harvest_target_node.position
				if route.is_empty() or route[route.size()-1].distance_to(destination)>8.0:set_route(destination)
			else:
				moving=false
				harvest_timer+=delta
				if carried_amount>=cargo_capacity:return_to_storage()
				elif harvest_timer>=1.5:
					harvest_timer=0.0
					var gather_amount:=10
					var parent_for_production=get_parent()
					if parent_for_production!=null and parent_for_production.has_method("get_motivation_gather_amount"):
						gather_amount=parent_for_production.get_motivation_gather_amount(gather_amount)
					var amount=harvest_target_node.harvest(min(gather_amount,cargo_capacity-carried_amount))
					carried_amount+=amount
					carried_type=harvest_target_node.resource_type
					if carried_amount>=cargo_capacity or harvest_target_node.amount<=0:return_to_storage()
	if production_target_building!=null and (not is_instance_valid(production_target_building) or not production_target_building.is_complete or production_target_building.health<=0):
		clear_production_assignment()
	if upgrade_target_building!=null:
		if not is_instance_valid(upgrade_target_building) or not upgrade_target_building.is_upgrading:
			if is_instance_valid(upgrade_target_building):
				upgrade_target_building.unregister_upgrade_worker(self)
			upgrade_target_building=null
			moving=false
			if carried_amount>0:
				return_to_storage()
		elif position.distance_to(upgrade_target_building.position)<=58.0:
			moving=false
			path_pending=false
			route=PackedVector2Array()
			var worker_count=max(1,upgrade_target_building.get_upgrade_active_worker_count())
			var speed_multiplier=upgrade_target_building.get_upgrade_speed_multiplier()
			upgrade_target_building.add_upgrade_work(delta*8.0*speed_multiplier/float(worker_count))
		else:
			moving=true
			destination=get_building_approach_point(upgrade_target_building)
			if route.is_empty() or route[route.size()-1].distance_to(destination)>8.0:set_route(destination)
	if build_target_site!=null:
		if not is_instance_valid(build_target_site) or build_target_site.is_complete:
			build_target_site=null
			moving=false
		elif position.distance_to(build_target_site.position)<=58.0:
			moving=false
			path_pending=false
			route=PackedVector2Array()
			build_target_site.add_build_work(delta*10.0)
		else:
			moving=true
			destination=get_building_approach_point(build_target_site)
			if route.is_empty() or route[route.size()-1].distance_to(destination)>8.0:set_route(destination)
	attack_timer=max(0.0,attack_timer-delta)
	acquire_timer-=delta
	var parent_for_enemy=get_parent()
	var enemy_active=parent_for_enemy!=null and parent_for_enemy.get("enemy_enabled")
	if team==1 and enemy_active and target==null and acquire_timer<=0.0:
		acquire_timer=1.5
		acquire_player_target()
	if target!=null:
		if not is_instance_valid(target) or target.health<=0:target=null
		else:
			var d=target.position-position
			if d.length()>attack_range:
				var parent=get_parent()
				target_path_timer-=delta
				if route.is_empty() or target_path_timer<=0.0:
					destination=target.position
					set_route(destination)
					target_path_timer=1.25
				move_along_route(delta,parent,target)
			elif attack_timer<=0.0:
				target.take_damage(attack_damage)
				attack_timer=attack_cooldown
				if is_instance_valid(target) and target.health>0 and target.has_method("attack_target") and target.team!=team:target.attack_target(self)
	if moving and target==null:
		var parent=get_parent()
		if parent!=null:move_along_route(delta,parent,storage_target)

func move_along_route(delta:float,parent:Node,target_override:Node=null)->void:
	if path_pending:return
	if route.is_empty():set_route(destination)
	if route.is_empty():return
	if route_index>=route.size():route_index=route.size()-1
	var waypoint=route[route_index]
	if position.distance_to(waypoint)<14.0 and route_index<route.size()-1:
		route_index+=1
		waypoint=route[route_index]
	var direction=waypoint-position
	if direction.length()<3.0:
		if route_index>=route.size()-1:
			moving=false
			return
		route_index+=1
		return
	# Add gentle lateral steering around nearby units instead of freezing on collision.
	var steer=Vector2.ZERO
	for other in parent.units:
		if is_instance_valid(other) and other!=self and other.health>0:
			var separation=position-other.position
			var distance=separation.length()
			if distance>0.0 and distance<28.0:
				steer+=separation.normalized()*(28.0-distance)/28.0
	var move_direction=direction.normalized()
	if steer.length()>0.01:
		move_direction=(move_direction+steer*0.65).normalized()
	var step=move_direction*min(speed*delta,direction.length())
	var candidate=position+step
	if not parent.has_method("is_unit_position_blocked") or not parent.is_unit_position_blocked(candidate,self,target_override):
		position=candidate
		stuck_timer=0.0
	else:
		# Slide along static obstacles by testing each axis separately.
		var slide_x=position+Vector2(step.x,0)
		var slide_y=position+Vector2(0,step.y)
		var moved=false
		if abs(step.x)>0.1 and not parent.is_unit_position_blocked(slide_x,self,target_override):
			position=slide_x
			moved=true
		elif abs(step.y)>0.1 and not parent.is_unit_position_blocked(slide_y,self,target_override):
			position=slide_y
			moved=true
		if moved:
			stuck_timer=0.0
		else:
			# Try a short lateral sidestep to escape unit congestion before replanning.
			var lateral=Vector2(-direction.normalized().y,direction.normalized().x)
			var sidestep= speed*delta*0.8
			var escaped=false
			for side in [1.0,-1.0]:
				var side_candidate=position+lateral*side*sidestep
				if not parent.is_unit_position_blocked(side_candidate,self,target_override):
					position=side_candidate
					escaped=true
					break
			stuck_timer+=delta
			if escaped:
				stuck_timer=0.0
			elif stuck_timer>=0.75:
				set_route(destination)
				stuck_timer=0.0
