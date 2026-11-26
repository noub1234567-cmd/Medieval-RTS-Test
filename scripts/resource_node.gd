extends Node2D

var resource_type:String="wood"
var amount:int=500
var depleted:bool=false

func _ready()->void:
	var shape:=Polygon2D.new()
	shape.polygon=PackedVector2Array([Vector2(0,-18),Vector2(16,-4),Vector2(12,12),Vector2(-10,12),Vector2(-16,-4)])
	shape.color={"wood":Color(0.45,0.25,0.1),"food":Color(0.25,0.75,0.22),"gold":Color(0.9,0.7,0.12),"stone":Color(0.55,0.58,0.62)}.get(resource_type,Color.WHITE)
	add_child(shape)
	var label:=Label.new()
	label.text={"wood":"Logs","food":"Berries","gold":"Gold","stone":"Stone"}.get(resource_type,resource_type)+" "+str(amount)
	label.position=Vector2(-25,-34)
	label.scale=Vector2(0.7,0.7)
	add_child(label)

func harvest(quantity:int)->int:
	if depleted:return 0
	var gathered=min(quantity,amount)
	amount-=gathered
	if amount<=0:
		depleted=true
		queue_free()
	else:
		for child in get_children():
			if child is Label: child.text={"wood":"Logs","food":"Berries","gold":"Gold","stone":"Stone"}.get(resource_type,resource_type)+" "+str(amount)
	return gathered
