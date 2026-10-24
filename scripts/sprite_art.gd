extends RefCounted
## The PixelLab sprites in res://sprites/, made by tools/make_sprites.py.
## Each sheet is a row of frames with the feet or base on its bottom edge. Anything missing
## is simply not offered here, and world_view.gd draws that thing in code instead.

const DIR := "res://sprites/"

var _sheets := {} # name -> {texture, frames, fps}


func _init() -> void:
	var file := FileAccess.open(DIR + "sprites.json", FileAccess.READ)
	if file == null:
		return
	var manifest = JSON.parse_string(file.get_as_text())
	if typeof(manifest) != TYPE_DICTIONARY:
		return
	for sprite_name: String in manifest:
		var path := DIR + sprite_name + ".png"
		if not ResourceLoader.exists(path):
			continue
		var entry: Dictionary = manifest[sprite_name]
		_sheets[sprite_name] = {
			"texture": load(path),
			"frames": maxi(1, int(entry.get("frames", 1))),
			"fps": float(entry.get("fps", 0)),
		}


func has(sprite_name: String) -> bool:
	return _sheets.has(sprite_name)


## Height of a sprite's frames in its own pixels.
func height_of(sprite_name: String) -> float:
	return float((_sheets[sprite_name].texture as Texture2D).get_height())


## Draws a sprite standing on `base` (its bottom centre) at `scale` screen pixels per sprite pixel.
## `t` picks the frame of an animation; `facing` -1 mirrors it to face left.
func draw(canvas: CanvasItem, sprite_name: String, base: Vector2, scale: float, t := 0.0,
		facing := 1.0, tint := Color.WHITE) -> void:
	var sheet: Dictionary = _sheets[sprite_name]
	var texture: Texture2D = sheet.texture
	var w := float(texture.get_width()) / float(sheet.frames)
	var h := float(texture.get_height())
	canvas.draw_set_transform(base, 0.0, Vector2(scale * facing, scale))
	canvas.draw_texture_rect_region(texture, Rect2(-w / 2.0, -h, w, h), Rect2(_frame(sheet, t) * w, 0, w, h), tint)
	canvas.draw_set_transform(Vector2.ZERO)


## Draws a sprite as large as fits in `rect`, standing on its bottom edge, or filling it when `stretch`.
func draw_fit(canvas: CanvasItem, sprite_name: String, rect: Rect2, t := 0.0, tint := Color.WHITE,
		stretch := false) -> void:
	var sheet: Dictionary = _sheets[sprite_name]
	var texture: Texture2D = sheet.texture
	var w := float(texture.get_width()) / float(sheet.frames)
	var h := float(texture.get_height())
	var source := Rect2(_frame(sheet, t) * w, 0, w, h)
	if stretch:
		canvas.draw_texture_rect_region(texture, rect, source, tint)
		return
	draw(canvas, sprite_name, Vector2(rect.get_center().x, rect.end.y), minf(rect.size.x / w, rect.size.y / h), t, 1.0, tint)


func _frame(sheet: Dictionary, t: float) -> int:
	var fps: float = sheet.fps
	var frames: int = sheet.frames
	return int(t * fps) % frames if fps > 0.0 else 0
