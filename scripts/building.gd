extends Node2D

const ProjectileScript := preload("res://scripts/projectile.gd")

var team:int=0
var max_health:int=300
var health:int=300
var building_type:String=""
var attack_range:float=230.0
var attack_damage:int=20
var attack_timer:float=0.0
var attack_cooldown:float=1.5
var health_bar:Polygon2D
var range_indicator:Line2D
var range_fill:Polygon2D
var construction_progress:float=0.0
var is_complete:bool=true
var construction_bar_bg:Polygon2D
var construction_bar_fill:Polygon2D
var construction_label:Label
var town_center_level:int=1
var building_upgrade_level:int=1
var is_upgrading:bool=false
var upgrade_progress:float=0.0
var upgrade_label:Label
var upgrade_bar_bg:Polygon2D
var upgrade_bar_fill:Polygon2D
var upgrade_workers:Array[Node2D]=[]
var production_worker:Node2D=null

func _ready()->void:
	if building_type=="Guard Tower" and team==0:
		create_range_indicator()
	health_bar=Polygon2D.new()
	health_bar.position=Vector2(0,-36)
	add_child(health_bar)
	update_health_bar()
	if not is_complete:
		create_construction_display()
		update_construction_display()

func create_range_indicator()->void:
	var points:=PackedVector2Array()
	for i in range(97):
		var angle=TAU*float(i)/96.0
		points.append(Vector2(cos(angle),sin(angle))*attack_range)
	range_fill=Polygon2D.new()
	range_fill.name="TowerRangeFill"
	range_fill.polygon=points
	range_fill.color=Color(0.05,0.65,1.0,0.16)
	range_fill.z_index=8
	range_fill.visible=false
	add_child(range_fill)
	range_indicator=Line2D.new()
	range_indicator.name="TowerRangeIndicator"
	range_indicator.points=points
	range_indicator.width=5.0
	range_indicator.default_color=Color(0.0,0.9,1.0,0.95)
	range_indicator.z_index=9
	range_indicator.visible=false
	add_child(range_indicator)

func update_range_indicator_geometry()->void:
	if not is_instance_valid(range_indicator) or not is_instance_valid(range_fill):return
	var points:=PackedVector2Array()
	for i in range(97):
		var angle=TAU*float(i)/96.0
		points.append(Vector2(cos(angle),sin(angle))*attack_range)
	range_indicator.points=points
	range_fill.polygon=points

func set_range_visible(value:bool)->void:
	var show_range:=value and is_complete and building_type=="Guard Tower" and team==0
	if is_instance_valid(range_indicator):
		range_indicator.visible=show_range
	if is_instance_valid(range_fill):
		range_fill.visible=show_range

func create_construction_display()->void:
	construction_label=Label.new()
	construction_label.text="Building 0%"
	construction_label.position=Vector2(-42,-58)
	construction_label.add_theme_font_size_override("font_size",12)
	construction_label.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
	construction_label.size=Vector2(84,18)
	add_child(construction_label)
	construction_bar_bg=Polygon2D.new()
	construction_bar_bg.position=Vector2(0,-46)
	construction_bar_bg.polygon=PackedVector2Array([Vector2(-22,-2),Vector2(22,-2),Vector2(22,3),Vector2(-22,3)])
	construction_bar_bg.color=Color(0.12,0.12,0.12,0.95)
	add_child(construction_bar_bg)
	construction_bar_fill=Polygon2D.new()
	construction_bar_fill.position=Vector2(-22,-46)
	construction_bar_fill.polygon=PackedVector2Array([Vector2(0,-2),Vector2(0,-2),Vector2(0,3),Vector2(0,3)])
	construction_bar_fill.color=Color(0.25,0.9,0.35,1)
	add_child(construction_bar_fill)

func update_construction_display()->void:
	if not is_instance_valid(construction_bar_fill):return
	var width=44.0*construction_progress/100.0
	construction_bar_fill.polygon=PackedVector2Array([Vector2(0,-2),Vector2(width,-2),Vector2(width,3),Vector2(0,3)])
	if is_instance_valid(construction_label):
		construction_label.text="Building %d%%" % int(construction_progress)
		construction_label.visible=not is_complete
	construction_bar_bg.visible=not is_complete
	construction_bar_fill.visible=not is_complete

func update_health_bar()->void:
	if not is_instance_valid(health_bar): return
	var ratio=float(health)/float(max_health)
	health_bar.polygon=PackedVector2Array([Vector2(-18,-2),Vector2(-18+36*ratio,-2),Vector2(-18+36*ratio,2),Vector2(-18,2)])
	health_bar.color=Color(0.2,0.9,0.25) if ratio>0.5 else Color(1,0.65,0.1) if ratio>0.25 else Color(0.95,0.2,0.15)

func is_production_building()->bool:
	return building_type in ["Mill","Lumber Mill","Gold Mine","Quarry"]

func register_production_worker(worker:Node2D)->bool:
	if not is_production_building() or not is_complete or team!=0 or not is_instance_valid(worker):return false
	if is_instance_valid(production_worker) and production_worker!=worker:return false
	production_worker=worker
	return true

func unregister_production_worker(worker:Node2D)->void:
	if production_worker==worker:production_worker=null

func has_active_production_worker()->bool:
	return is_production_building() and is_complete and team==0 and is_instance_valid(production_worker) and production_worker.health>0 and production_worker.is_working_for_production(self)

func begin_upgrade()->void:
	if building_type!="Town Center" or town_center_level>=2:return
	is_upgrading=true
	upgrade_progress=0.0
	upgrade_label=Label.new()
	upgrade_label.text="Upgrading 0%"
	upgrade_label.position=Vector2(-48,-70)
	upgrade_label.add_theme_font_size_override("font_size",12)
	upgrade_label.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
	upgrade_label.size=Vector2(96,18)
	add_child(upgrade_label)
	upgrade_bar_bg=Polygon2D.new()
	upgrade_bar_bg.position=Vector2(0,-58)
	upgrade_bar_bg.polygon=PackedVector2Array([Vector2(-24,-2),Vector2(24,-2),Vector2(24,3),Vector2(-24,3)])
	upgrade_bar_bg.color=Color(0.12,0.12,0.12,0.95)
	add_child(upgrade_bar_bg)
	upgrade_bar_fill=Polygon2D.new()
	upgrade_bar_fill.position=Vector2(-24,-58)
	upgrade_bar_fill.color=Color(0.3,0.65,1.0,1)
	upgrade_bar_fill.polygon=PackedVector2Array([Vector2(0,-2),Vector2(0,-2),Vector2(0,3),Vector2(0,3)])
	add_child(upgrade_bar_fill)

func get_upgrade_worker_count()->int:
	var valid_workers:Array[Node2D]=[]
	for worker in upgrade_workers:
		if is_instance_valid(worker) and worker.health>0 and worker.upgrade_target_building==self:
			valid_workers.append(worker)
	upgrade_workers=valid_workers
	return upgrade_workers.size()

func get_upgrade_active_worker_count()->int:
	var active:=0
	for worker in upgrade_workers:
		if is_instance_valid(worker) and worker.health>0 and worker.upgrade_target_building==self and worker.position.distance_to(position)<=58.0:
			active+=1
	return active

func get_upgrade_speed_multiplier()->float:
	return 1.0+float(min(max(get_upgrade_active_worker_count()-1,0),7))*0.1

func register_upgrade_worker(worker:Node2D)->bool:
	if not is_instance_valid(worker) or get_upgrade_worker_count()>=8:return false
	if not upgrade_workers.has(worker):
		upgrade_workers.append(worker)
	update_upgrade_display()
	return true

func unregister_upgrade_worker(worker:Node2D)->void:
	upgrade_workers.erase(worker)
	update_upgrade_display()

func update_upgrade_display()->void:
	if is_instance_valid(upgrade_label) and is_upgrading:
		upgrade_label.text="Upgrading %d%% | Workers %d/8 (%d working)" % [int(upgrade_progress),get_upgrade_worker_count(),get_upgrade_active_worker_count()]

func add_upgrade_work(amount:float)->void:
	if not is_upgrading:return
	if building_type!="Town Center":
		add_building_upgrade_work(amount)
		return
	upgrade_progress=min(100.0,upgrade_progress+amount)
	var width=48.0*upgrade_progress/100.0
	upgrade_bar_fill.polygon=PackedVector2Array([Vector2(0,-2),Vector2(width,-2),Vector2(width,3),Vector2(0,3)])
	update_upgrade_display()
	if upgrade_progress>=100.0:
		is_upgrading=false
		town_center_level=2
		upgrade_label.text="Town Center Level 2"
		var original_label=get_node_or_null("TownCenterNameLabel")
		if original_label is Label:original_label.visible=false
		upgrade_bar_bg.visible=false
		upgrade_bar_fill.visible=false
		var shape=get_node_or_null("Polygon2D")
		if shape is Polygon2D:shape.color=Color(0.15,0.45,1.0,1.0)
		var parent=get_parent()
		if parent!=null and parent.has_method("town_center_upgrade_completed"):parent.town_center_upgrade_completed(self)

func begin_building_upgrade()->void:
	if not is_complete or building_type=="Town Center" or building_upgrade_level>=2 or is_upgrading:return
	is_upgrading=true
	upgrade_progress=0.0
	upgrade_label=Label.new()
	upgrade_label.text="Upgrading 0%"
	upgrade_label.position=Vector2(-48,-70)
	upgrade_label.add_theme_font_size_override("font_size",12)
	upgrade_label.horizontal_alignment=HORIZONTAL_ALIGNMENT_CENTER
	upgrade_label.size=Vector2(96,18)
	add_child(upgrade_label)
	upgrade_bar_bg=Polygon2D.new()
	upgrade_bar_bg.position=Vector2(0,-58)
	upgrade_bar_bg.polygon=PackedVector2Array([Vector2(-24,-2),Vector2(24,-2),Vector2(24,3),Vector2(-24,3)])
	upgrade_bar_bg.color=Color(0.12,0.12,0.12,0.95)
	add_child(upgrade_bar_bg)
	upgrade_bar_fill=Polygon2D.new()
	upgrade_bar_fill.position=Vector2(-24,-58)
	upgrade_bar_fill.color=Color(0.3,0.65,1.0,1)
	upgrade_bar_fill.polygon=PackedVector2Array([Vector2(0,-2),Vector2(0,-2),Vector2(0,3),Vector2(0,3)])
	add_child(upgrade_bar_fill)

func add_building_upgrade_work(amount:float)->void:
	if not is_upgrading or building_type=="Town Center":return
	upgrade_progress=min(100.0,upgrade_progress+amount)
	var width=48.0*upgrade_progress/100.0
	upgrade_bar_fill.polygon=PackedVector2Array([Vector2(0,-2),Vector2(width,-2),Vector2(width,3),Vector2(0,3)])
	update_upgrade_display()
	if upgrade_progress>=100.0:
		is_upgrading=false
		building_upgrade_level=2
		if is_instance_valid(upgrade_label):upgrade_label.text="Level 2"
		if is_instance_valid(upgrade_bar_bg):upgrade_bar_bg.visible=false
		if is_instance_valid(upgrade_bar_fill):upgrade_bar_fill.visible=false
		var shape=get_node_or_null("Polygon2D")
		if shape is Polygon2D:shape.color=Color(0.15,0.45,1.0,1.0)
		var parent=get_parent()
		if parent!=null and parent.has_method("building_upgrade_completed"):parent.building_upgrade_completed(self)

func add_build_work(amount:float)->void:
	if is_complete:return
	construction_progress=min(100.0,construction_progress+amount)
	if construction_progress>=100.0:
		is_complete=true
		var parent=get_parent()
		if parent!=null and parent.has_method("building_completed"):
			parent.building_completed(self)
	var shape=get_node_or_null("Polygon2D")
	if shape is Polygon2D:
		shape.color.a=1.0 if is_complete else 0.55+0.4*(construction_progress/100.0)
	update_construction_display()

var watchtower_alert_timer:=0.0

func _process(delta:float)->void:
	if is_instance_valid(production_worker) and (production_worker.health<=0 or production_worker.production_target_building!=self):
		production_worker=null
	if not is_complete or team!=0:return
	var parent=get_parent()
	if building_type=="Watchtower":
		watchtower_alert_timer=max(0.0,watchtower_alert_timer-delta)
		if watchtower_alert_timer<=0.0 and parent!=null and parent.has_method("watchtower_alert"):
			var detected:=0
			for enemy_unit in parent.units:
				if is_instance_valid(enemy_unit) and enemy_unit.team==1 and enemy_unit.health>0 and position.distance_to(enemy_unit.position)<=280.0:
					detected+=1
			if detected>0:
					parent.watchtower_alert(self,detected)
					watchtower_alert_timer=15.0
		return
	if building_type!="Guard Tower":return
	attack_timer=max(0.0,attack_timer-delta)
	if attack_timer>0.0:return
	if not parent.has_method("enemy_count"):return
	var target:Node2D=null
	var nearest=attack_range
	for u in parent.units:
		if is_instance_valid(u) and u.team==1 and u.health>0:
			var d=position.distance_to(u.position)
			if d<nearest:
				nearest=d
				target=u
	if target!=null:
		var projectile := Node2D.new()
		projectile.set_script(ProjectileScript)
		projectile.target=target
		projectile.damage=attack_damage
		projectile.position=position+Vector2(0,-24)
		parent.add_child(projectile)
		attack_timer=attack_cooldown

func take_damage(amount:int)->void:
	health=max(0,health-amount)
	update_health_bar()
	if health<=0: queue_free()
