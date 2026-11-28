extends Node2D

const ProjectileScript = preload("res://scripts/projectile.gd")

var team:int=0
var soldier_data:Resource=null
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
var sheltered:=false
var shelter_pending:=false
var shelter_tc:Node2D=null
var shelter_saved_state:Dictionary={}

const UNIT_SEPARATION:=18.0
const BUILDING_COLLISION_RADIUS:=34.0
const TREE_COLLISION_RADIUS:=26.0
const HARVEST_RANGE:=38.0
var stuck_replans:=0

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
	if team!=0:return Color(0.8,0.25,0.22)
	if soldier_data==null:return Color(0.25,0.75,0.35) # Workers: green
	match soldier_data.unit_id:
		"light_infantry":return Color(0.25,0.48,0.85) # Blue
		"heavy_infantry":return Color(0.9,0.25,0.2) # Red
		"archer":return Color(1.0,0.78,0.2) # Yellow
		"cavalry":return Color(0.65,0.3,0.85) # Purple
	return Color(0.25,0.48,0.85)

func set_team(t:int)->void:
	team=t
	if is_instance_valid(body):body.color=team_color()

func apply_soldier_data(data:Resource)->void:
	if data==null:return
	soldier_data=data
	speed=data.movement_speed
	max_health=data.max_health
	health=max_health
	attack_damage=data.attack_damage
	attack_range=data.attack_range
	detection_range=data.detection_range
	attack_cooldown=data.attack_cooldown
	if is_instance_valid(body):body.color=team_color()
	update_health_bar()

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

func move_to(p:Vector2,snap_to_cell:bool=true)->void:
	clear_production_assignment()
	var parent=get_parent()
	if snap_to_cell and parent!=null and parent.has_method("snap_to_map_cell"):
		p=parent.snap_to_map_cell(p)
	p=get_free_destination(p)
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
	if node==null or not is_instance_valid(node) or team!=0 or soldier_data!=null:return
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
	var parent:=get_parent()
	if parent==null or not parent.has_method("find_path") or not parent.has_method("is_unit_position_blocked"):
		var fallback_away:Vector2=(position-site.position).normalized()
		if fallback_away.length()<0.1:fallback_away=Vector2(1,0)
		return site.position+fallback_away*52.0
	# Test several approach points around the structure and keep the shortest clear route.
	var best_point:=Vector2.ZERO
	var best_route_length:=INF
	for angle_index in range(16):
		var angle:=TAU*float(angle_index)/16.0
		var candidate:=site.position+Vector2(cos(angle),sin(angle))*52.0
		# Reserve distinct approach slots for workers assigned to this same structure.
		var slot_reserved:=false
		for other in parent.units:
			if not is_instance_valid(other) or other==self or other.health<=0:continue
			if other.build_target_site!=site and other.upgrade_target_building!=site:continue
			if other.destination.distance_to(candidate)<28.0:
				slot_reserved=true
				break
		if slot_reserved:continue
		if parent.is_unit_position_blocked(candidate,self,site):continue
		var candidate_route:PackedVector2Array=parent.find_path(position,candidate,self)
		if candidate_route.is_empty():continue
		var previous:=position
		var route_clear:=true
		var route_length:=0.0
		for waypoint in candidate_route:
			var segment_length:=previous.distance_to(waypoint)
			route_length+=segment_length
			var sample_count:=max(1,int(ceil(segment_length/8.0)))
			for sample_index in range(1,sample_count+1):
				var sample_pos:=previous.lerp(waypoint,float(sample_index)/float(sample_count))
				if parent.is_unit_position_blocked(sample_pos,self,site):
					route_clear=false
					break
			if not route_clear:break
			previous=waypoint
		if route_clear and route_length<best_route_length:
			best_route_length=route_length
			best_point=candidate
	if best_route_length<INF:
		return best_point
	# Preserve the previous behavior if every candidate is temporarily blocked.
	var away:Vector2=(position-site.position).normalized()
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
	if sheltered:return
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
	if sheltered or health<=0:return
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
	if sheltered:return
	if shelter_pending:
		if not is_instance_valid(shelter_tc) or shelter_tc.health<=0:
			shelter_pending=false
			shelter_tc=null
		else:
			if position.distance_to(shelter_tc.position)<=64.0:
				shelter_pending=false
				sheltered=true
				visible=false
				moving=false
				path_pending=false
				route=PackedVector2Array()
				position=shelter_tc.position
				return
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
			if d_h>HARVEST_RANGE:
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
		elif position.distance_to(destination)<=12.0:
			moving=false
			path_pending=false
			route=PackedVector2Array()
			var worker_count=max(1,upgrade_target_building.get_upgrade_active_worker_count())
			var speed_multiplier=upgrade_target_building.get_upgrade_speed_multiplier()
			upgrade_target_building.add_upgrade_work(delta*8.0*speed_multiplier/float(worker_count))
		else:
			moving=true
			# Keep the assigned approach slot stable while travelling.
			if route.is_empty() or route[route.size()-1].distance_to(destination)>8.0:set_route(destination)
	if build_target_site!=null:
		if not is_instance_valid(build_target_site) or build_target_site.is_complete:
			build_target_site=null
			moving=false
		elif position.distance_to(destination)<=12.0:
			moving=false
			path_pending=false
			route=PackedVector2Array()
			build_target_site.add_build_work(delta*10.0)
		else:
			moving=true
			# Keep the assigned approach slot stable while travelling.
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
				if soldier_data!=null and soldier_data.attack_type=="ranged":
					var projectile:Node2D=Node2D.new()
					projectile.set_script(ProjectileScript)
					projectile.set("target",target)
					projectile.set("damage",attack_damage)
					projectile.set("speed",420.0)
					projectile.position=position+Vector2(0,-6)
					var projectile_parent=get_parent()
					if projectile_parent!=null:projectile_parent.add_child(projectile)
					else:target.take_damage(attack_damage)
				else:
					target.take_damage(attack_damage)
				attack_timer=attack_cooldown
				if is_instance_valid(target) and target.health>0 and target.has_method("attack_target") and target.team!=team:target.attack_target(self)
	if moving and target==null:
		var parent=get_parent()
		if parent!=null:move_along_route(delta,parent,storage_target)
	resolve_collisions(delta)

func move_along_route(delta:float,parent:Node,_target_override:Node=null)->void:
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
			stuck_replans=0
			return
		route_index+=1
		return
	var move_direction:Vector2=direction.normalized()
	var lateral:=Vector2(-move_direction.y,move_direction.x)
	var steer:=Vector2.ZERO
	for other in parent.units:
		if is_instance_valid(other) and other!=self and other.health>0 and not other.sheltered:
			var separation:Vector2=position-other.position
			var distance:=separation.length()
			if distance>0.0 and distance<30.0:
				var weight:=(30.0-distance)/30.0
				steer+=separation.normalized()*weight
				# Someone is ahead: pass on the right so head-on units do not deadlock.
				if (-separation.normalized()).dot(move_direction)>0.4:
					steer+=lateral*weight*0.8
	if steer.length()>0.01:
		move_direction=(move_direction+steer*0.5).normalized()
	var distance_before_move:=position.distance_to(waypoint)
	var step_length:=minf(speed*delta,direction.length())
	position+=move_direction*step_length
	push_out_of_obstacles(parent,move_direction,step_length)
	if position.distance_to(waypoint)<distance_before_move-0.5:
		stuck_timer=0.0
		stuck_replans=0
	else:
		stuck_timer+=delta
		if stuck_timer>=0.75:
			stuck_timer=0.0
			stuck_replans+=1
			# Close to an unreachable final point: stop instead of replanning forever.
			if route_index>=route.size()-1 and position.distance_to(waypoint)<60.0 and stuck_replans>=2:
				moving=false
				stuck_replans=0
			else:
				set_route(destination)


func collision_pushability()->float:
	# Higher value = this unit yields more when overlapped.
	if moving or target!=null:return 0.4
	if is_instance_valid(harvest_target_node) or is_instance_valid(build_target_site) or is_instance_valid(upgrade_target_building) or is_instance_valid(storage_target):return 0.2
	return 1.0

func resolve_collisions(delta:float)->void:
	var parent=get_parent()
	if parent==null:return
	push_out_of_obstacles(parent,Vector2.ZERO,0.0)
	separate_from_units(parent,delta)
	push_out_of_obstacles(parent,Vector2.ZERO,0.0)

func push_out_of_circle(center:Vector2,radius:float,move_direction:Vector2,step_length:float)->void:
	var offset:Vector2=position-center
	var dist:=offset.length()
	if dist>=radius:return
	var normal:Vector2=offset/dist if dist>0.001 else Vector2(0,1)
	position=center+normal*radius
	# Heading straight into the obstacle would stall completely, so slide sideways.
	if step_length>0.0 and move_direction!=Vector2.ZERO and -normal.dot(move_direction)>0.75:
		var tangent:=Vector2(-normal.y,normal.x)
		var side:=tangent.dot(destination-position)
		if absf(side)<1.0:
			side=1.0 if get_instance_id()%2==0 else -1.0
		position+=tangent*signf(side)*step_length*0.6

func push_out_of_obstacles(parent:Node,move_direction:Vector2,step_length:float)->void:
	for list_name in ["buildings","enemy_buildings"]:
		var list=parent.get(list_name)
		if list==null:continue
		for structure in list:
			if is_instance_valid(structure) and structure.health>0:
				push_out_of_circle(structure.position,BUILDING_COLLISION_RADIUS,move_direction,step_length)
	var trees=parent.get("tree_positions")
	if trees!=null:
		for tree_pos in trees:
			push_out_of_circle(tree_pos,TREE_COLLISION_RADIUS,move_direction,step_length)

func separate_from_units(parent:Node,delta:float)->void:
	var all_units=parent.get("units")
	if all_units==null:return
	var my_push:=collision_pushability()
	var total:=Vector2.ZERO
	for other in all_units:
		if not is_instance_valid(other) or other==self or other.health<=0 or other.sheltered:continue
		var offset:Vector2=position-other.position
		var dist:=offset.length()
		if dist>=UNIT_SEPARATION:continue
		var direction:Vector2
		if dist>0.01:
			direction=offset/dist
		else:
			var angle:=float(get_instance_id()%360)*PI/180.0
			direction=Vector2(cos(angle),sin(angle))
		var other_push:float=other.collision_pushability()
		total+=direction*(UNIT_SEPARATION-dist)*(my_push/(my_push+other_push))
	if total!=Vector2.ZERO:
		position+=total.limit_length(maxf(speed*delta*0.8,4.0))

func get_free_destination(p:Vector2)->Vector2:
	var parent=get_parent()
	if parent==null:return p
	for pass_index in range(3):
		var moved:=false
		for list_name in ["buildings","enemy_buildings"]:
			var list=parent.get(list_name)
			if list==null:continue
			for structure in list:
				if not is_instance_valid(structure) or structure.health<=0:continue
				var offset:Vector2=p-structure.position
				var dist:=offset.length()
				if dist<BUILDING_COLLISION_RADIUS+4.0:
					var normal:Vector2=offset/dist if dist>0.001 else Vector2(0,1)
					p=structure.position+normal*(BUILDING_COLLISION_RADIUS+6.0)
					moved=true
		var trees=parent.get("tree_positions")
		if trees!=null:
			for tree_pos in trees:
				var offset:Vector2=p-tree_pos
				var dist:=offset.length()
				if dist<TREE_COLLISION_RADIUS+4.0:
					var normal:Vector2=offset/dist if dist>0.001 else Vector2(0,1)
					p=tree_pos+normal*(TREE_COLLISION_RADIUS+6.0)
					moved=true
		if not moved:break
	return p
