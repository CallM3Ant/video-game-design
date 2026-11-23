
extends CanvasLayer

signal terrain_detail_changed(level: int)
signal atmosphere_quality_changed(level: int)

@export var sun_path: NodePath

var sun: DirectionalLight3D
var panel: PanelContainer
var stats_label: Label
var render_label: Label
var terrain_label: Label
var atmosphere_label: Label

var stats_timer := 0.0


func _ready() -> void:
	sun = get_node_or_null(sun_path) as DirectionalLight3D
	get_viewport().scaling_3d_scale = 0.85
	_build_ui()


func _process(delta: float) -> void:
	stats_timer += delta

	if stats_timer >= 0.25:
		stats_timer = 0.0

		var fps := Engine.get_frames_per_second()
		var frame_ms := 1000.0 / maxf(float(fps), 1.0)

		stats_label.text = "FPS: %d    Frame time: %.2f ms" % [
			fps,
			frame_ms
		]


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		if event.pressed and not event.echo:
			if event.keycode == KEY_F3:
				panel.visible = not panel.visible


func _build_ui() -> void:
	panel = PanelContainer.new()
	panel.position = Vector2(20, 20)
	panel.custom_minimum_size = Vector2(340, 0)
	add_child(panel)

	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 10)
	panel.add_child(layout)

	var title := Label.new()
	title.text = "GRAPHICS LAB  |  F3 to hide"
	title.add_theme_font_size_override("font_size", 18)
	layout.add_child(title)

	stats_label = Label.new()
	stats_label.text = "FPS: --    Frame time: --"
	layout.add_child(stats_label)

	_add_separator(layout)

	_add_option(
		layout,
		"Directional Shadow Resolution",
		["1024", "2048", "4096"],
		1,
		_on_shadow_resolution_changed
	)

	_add_option(
		layout,
		"Directional Shadow Filtering",
		[
			"Hard (Fastest)",
			"Soft Very Low",
			"Soft Low",
			"Soft Medium",
			"Soft High"
		],
		1,
		_on_shadow_filter_changed
	)

	_add_separator(layout)

	_add_slider(
		layout,
		"3D Render Scale",
		0.50,
		1.00,
		0.05,
		0.85,
		_on_render_scale_changed,
		"render"
	)

	_add_separator(layout)

	_add_slider(
		layout,
		"Terrain Detail",
		0,
		2,
		1,
		1,
		_on_terrain_detail_changed,
		"terrain"
	)

	_add_slider(
		layout,
		"Atmosphere Quality",
		0,
		2,
		1,
		2,
		_on_atmosphere_quality_changed,
		"atmosphere"
	)


func _add_separator(parent: VBoxContainer) -> void:
	var separator := HSeparator.new()
	parent.add_child(separator)


func _add_option(
	parent: VBoxContainer,
	title: String,
	options: Array,
	default_index: int,
	callback: Callable
) -> void:
	var label := Label.new()
	label.text = title
	parent.add_child(label)

	var dropdown := OptionButton.new()

	for i in range(options.size()):
		dropdown.add_item(options[i], i)

	dropdown.select(default_index)
	dropdown.item_selected.connect(callback)
	parent.add_child(dropdown)


func _add_slider(
	parent: VBoxContainer,
	title: String,
	min_value: float,
	max_value: float,
	step: float,
	default_value: float,
	callback: Callable,
	kind: String
) -> void:
	var label := Label.new()
	label.text = title
	parent.add_child(label)

	var slider := HSlider.new()
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = step
	slider.value = default_value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.value_changed.connect(callback)
	parent.add_child(slider)

	if kind == "render":
		render_label = Label.new()
		parent.add_child(render_label)
		_update_render_label(default_value)

	elif kind == "terrain":
		terrain_label = Label.new()
		parent.add_child(terrain_label)
		_update_quality_label(terrain_label, int(default_value))

	elif kind == "atmosphere":
		atmosphere_label = Label.new()
		parent.add_child(atmosphere_label)
		_update_quality_label(atmosphere_label, int(default_value))


func _on_shadow_resolution_changed(index: int) -> void:
	var sizes := [1024, 2048, 4096]
	RenderingServer.directional_shadow_atlas_set_size(
		sizes[index],
		true
	)


func _on_shadow_filter_changed(index: int) -> void:
	RenderingServer.directional_soft_shadow_filter_set_quality(index)


func _on_render_scale_changed(value: float) -> void:
	get_viewport().scaling_3d_scale = value
	_update_render_label(value)


func _update_render_label(value: float) -> void:
	render_label.text = "Render scale: %.0f%%" % (value * 100.0)


func _on_terrain_detail_changed(value: float) -> void:
	var level := int(value)
	_update_quality_label(terrain_label, level)
	terrain_detail_changed.emit(level)


func _on_atmosphere_quality_changed(value: float) -> void:
	var level := int(value)
	_update_quality_label(atmosphere_label, level)
	atmosphere_quality_changed.emit(level)


func _update_quality_label(label: Label, level: int) -> void:
	var names := ["Low", "Medium", "High"]
	label.text = names[clampi(level, 0, 2)]
