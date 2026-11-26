extends Node2D

var target:Node2D=null
var damage:int=20
var speed:float=520.0
var direction:=Vector2.RIGHT
var trail:Line2D
var arrow:Polygon2D

func _ready()->void:
	z_index=30
	trail=Line2D.new()
	trail.points=PackedVector2Array([Vector2(-12,0),Vector2(0,0)])
	trail.width=3.0
	trail.default_color=Color(1.0,0.82,0.25,1.0)
	add_child(trail)
	arrow=Polygon2D.new()
	arrow.polygon=PackedVector2Array([Vector2(0,0),Vector2(-8,-4),Vector2(-8,4)])
	arrow.color=Color(1.0,0.92,0.55,1.0)
	add_child(arrow)

func _process(delta:float)->void:
	if not is_instance_valid(target) or target.health<=0:
		queue_free()
		return
	var offset=target.position-position
	if offset.length()<=speed*delta+8.0:
		position=target.position
		target.take_damage(damage)
		queue_free()
		return
	direction=offset.normalized()
	position+=direction*speed*delta
	rotation=direction.angle()
