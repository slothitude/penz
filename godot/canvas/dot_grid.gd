extends Control
## Dot grid helper — draws faint dot pattern for export Viewports.

const PenzTheme = preload("res://ui/theme.gd")


func _draw() -> void:
	var spacing := 30.0
	var dot_color := PenzTheme.DOT_GRID
	var dot_radius := 1.0
	var x := spacing
	while x < size.x:
		var y := spacing
		while y < size.y:
			draw_circle(Vector2(x, y), dot_radius, dot_color)
			y += spacing
		x += spacing
