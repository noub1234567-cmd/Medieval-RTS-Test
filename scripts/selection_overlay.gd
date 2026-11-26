extends Node2D
var box=Rect2()
func set_rect(r):
	box=r
	queue_redraw()
func clear_rect():
	box=Rect2()
	queue_redraw()
func _draw():
	if box.size.length()>1:
		draw_rect(box,Color(0.4,0.7,1,0.18),true)
		draw_rect(box,Color(0.5,0.8,1,0.8),false,2)
