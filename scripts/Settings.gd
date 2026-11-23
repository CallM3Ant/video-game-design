
extends CanvasLayer

const CONFIG_PATH := "user://graphics.cfg"

const UPSCALING_OPTIONS := [
	"Bilinear",
	"FSR 1.0",
	"FSR 2.2"
]
@export var chunk_manager_path: NodePath
var chunk_manager: Node3D
const RENDER_DISTANCE_MIN := 1
const RENDER_DISTANCE_MAX := 60

const GRID_CELLS_MIN := 14
const GRID_CELLS_MAX := 100

const TERRAIN_DIFFUSE_OPTIONS := [
	"Burley",
	"Lambert",
	"Lambert Wrap",
	"Toon",
]

const TERRAIN_DIFFUSE_VALUES := [
	BaseMaterial3D.DIFFUSE_BURLEY,
	BaseMaterial3D.DIFFUSE_LAMBERT,
	BaseMaterial3D.DIFFUSE_LAMBERT_WRAP,
	BaseMaterial3D.DIFFUSE_TOON,
]

const OUTLINE_MODE_VALUES := [0, 1]

const UPSCALING_VALUES := [
	Viewport.SCALING_3D_MODE_BILINEAR,
	Viewport.SCALING_3D_MODE_FSR,
	Viewport.SCALING_3D_MODE_FSR2
]

const SHADOW_SIZE_OPTIONS := [
	"512",
	"1024",
	"2048",
	"4096",
	"8192"
]

const SHADOW_SIZE_VALUES := [
	512,
	1024,
	2048,
	4096,
	8192
]

const SHADOW_QUALITY_OPTIONS := [
	"Hard (Fastest)",
	"Very Low",
	"Low",
	"Medium",
	"High",
	"Ultra (Smoothest)"
]

const SHADOW_QUALITY_VALUES := [
	RenderingServer.SHADOW_QUALITY_HARD,
	RenderingServer.SHADOW_QUALITY_SOFT_VERY_LOW,
	RenderingServer.SHADOW_QUALITY_SOFT_LOW,
	RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM,
	RenderingServer.SHADOW_QUALITY_SOFT_HIGH,
	RenderingServer.SHADOW_QUALITY_SOFT_ULTRA
]

var viewport: Viewport

var pending: Dictionary = {}
var original: Dictionary = {}
var controls: Dictionary = {}

var settings_panel: PanelContainer
var settings_list: VBoxContainer
var terrain_cache_summary_label: Label
var status_label: Label
var menu_button: Button


func _ready() -> void:
	viewport = get_viewport()
	chunk_manager = get_node_or_null(chunk_manager_path) as Node3D

	_create_interface()
	_load_settings()

	call_deferred("_apply_graphics")


func _create_interface() -> void:
	menu_button = Button.new()
	menu_button.text = "GRAPHICS"
	menu_button.position = Vector2(-150, 20)
	menu_button.size = Vector2(130, 40)
	menu_button.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	menu_button.pressed.connect(_toggle_menu)
	add_child(menu_button)

	settings_panel = PanelContainer.new()
	settings_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	settings_panel.position = Vector2(-500, 70)
	settings_panel.size = Vector2(480, 500)
	settings_panel.custom_minimum_size = Vector2(480, 500)
	settings_panel.visible = false
	add_child(settings_panel)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 10)
	settings_panel.add_child(outer)

	var title_row := HBoxContainer.new()
	outer.add_child(title_row)

	var title := Label.new()
	title.text = "GRAPHICS SETTINGS"
	title.add_theme_font_size_override("font_size", 23)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title)

	var close_button := Button.new()
	close_button.text = "X"
	close_button.pressed.connect(_close_menu)
	title_row.add_child(close_button)

	var settings_scroll := ScrollContainer.new()
	settings_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	settings_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(settings_scroll)

	settings_list = VBoxContainer.new()
	settings_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	settings_scroll.add_child(settings_list)

	_add_section("RENDER RESOLUTION")

	_add_float_slider(
		"3D Resolution Scale",
		"scaling_3d_scale",
		0.25,
		2.0,
		0.05
	)

	_add_option(
		"Upscaling Mode",
		"scaling_3d_mode",
		UPSCALING_OPTIONS,
		UPSCALING_VALUES
	)
	_add_section("TERRAIN")

	_add_option(
		"Terrain Diffuse Mode",
		"terrain_diffuse_mode",
		TERRAIN_DIFFUSE_OPTIONS,
		TERRAIN_DIFFUSE_VALUES
	)

	_add_option(
		"Outline Mode",
		"outline_mode",
		["Off", "Screen-Space"],
		OUTLINE_MODE_VALUES
	)
	_add_float_slider(
		"Screen-Space Width (render pixels)",
		"outline_width",
		1.0,
		8.0,
		0.5
	)
	_add_float_slider(
		"Outline Edge Threshold (lower = more lines)",
		"outline_threshold",
		0.01,
		0.2,
		0.01
	)
	_add_int_slider(
		"Rendering Distance",
		"render_radius",
		1,
		60,
		1
	)

	_add_int_slider(
		"Grid Cells",
		"grid_cells",
		GRID_CELLS_MIN,
		GRID_CELLS_MAX,
		1
	)
	_add_terrain_lod_toggle()

	_add_mesh_cache_budget_control()
	_add_int_slider(
		"Mesh Pregen End (chunks beyond render; capped by unload)",
		"mesh_pregen_end_offset",
		0,
		100,
		1
	)
	_add_int_slider(
		"Chunk Unload (minimum: pregen end + 1)",
		"chunk_unload_offset",
		0,
		101,
		1
	)
	terrain_cache_summary_label = Label.new()
	terrain_cache_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	settings_list.add_child(terrain_cache_summary_label)
	_add_section("DIRECTIONAL SHADOWS")

	_add_option(
		"Shadow Size",
		"directional_size",
		SHADOW_SIZE_OPTIONS,
		SHADOW_SIZE_VALUES
	)

	_add_option(
		"Shadow Smoothness / Quality",
		"directional_quality",
		SHADOW_QUALITY_OPTIONS,
		SHADOW_QUALITY_VALUES
	)

	status_label = Label.new()
	status_label.text = "Settings loaded"
	outer.add_child(status_label)

	var buttons := HBoxContainer.new()
	outer.add_child(buttons)

	var apply_button := Button.new()
	apply_button.text = "APPLY"
	apply_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	apply_button.pressed.connect(_apply_settings)
	buttons.add_child(apply_button)

	var discard_button := Button.new()
	discard_button.text = "DISCARD"
	discard_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	discard_button.pressed.connect(_reset_settings)
	buttons.add_child(discard_button)


func _toggle_menu() -> void:
	settings_panel.visible = not settings_panel.visible


func _close_menu() -> void:
	settings_panel.visible = false


func _update_terrain_cache_summary() -> void:
	if terrain_cache_summary_label == null \
			or not pending.has("render_radius") \
			or not pending.has("mesh_pregen_end_offset") \
			or not pending.has("chunk_unload_offset"):
		return

	var render_radius := int(pending["render_radius"])
	var requested_pregen_end := (
		render_radius + int(pending["mesh_pregen_end_offset"])
	)
	var unload_radius := (
		render_radius + int(pending["chunk_unload_offset"])
	)
	var effective_pregen_end := mini(requested_pregen_end, unload_radius)
	var pregen_range := "none"
	if effective_pregen_end >= render_radius + 1:
		pregen_range = "%d-%d" % [
			render_radius + 1,
			effective_pregen_end,
		]

	var cap_text := ""
	if requested_pregen_end > unload_radius:
		cap_text = " (requested end %d; capped at %d by unload)" % [
			requested_pregen_end,
			unload_radius,
		]
	elif effective_pregen_end < render_radius + 1:
		cap_text = (
			" (configured end %d is before pregen start)"
			% requested_pregen_end
		)
	terrain_cache_summary_label.text = (
		"Effective chunk radii: render %d | pregen %s%s | unload %d"
		% [
			render_radius,
			pregen_range,
			cap_text,
			unload_radius,
		]
	)


func _add_int_slider(
	label_text: String,
	key: String,
	minimum: int,
	maximum: int,
	step: int
) -> void:
	var container := VBoxContainer.new()
	settings_list.add_child(container)

	var label := Label.new()
	label.text = label_text
	container.add_child(label)

	var slider := HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = step
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(slider)

	var value_label := Label.new()
	container.add_child(value_label)

	slider.value_changed.connect(
		func(value: float):
			var selected_value := int(value)
			if key == "chunk_unload_offset":
				selected_value = maxi(
					selected_value,
					int(pending["mesh_pregen_end_offset"]) + 1
				)
				slider.set_value_no_signal(float(selected_value))
			pending[key] = selected_value
			value_label.text = str(selected_value)
			if key == "mesh_pregen_end_offset":
				_sync_chunk_unload_minimum()
			status_label.text = "Unapplied changes"
			if key == "render_radius" \
					or key == "mesh_pregen_end_offset" \
					or key == "chunk_unload_offset":
				_update_terrain_cache_summary()
	)

	controls[key] = slider
	controls[key + "_label"] = value_label


func _sync_chunk_unload_minimum() -> void:
	if not pending.has("mesh_pregen_end_offset") \
			or not pending.has("chunk_unload_offset") \
			or not controls.has("chunk_unload_offset"):
		return

	var unload_slider := controls["chunk_unload_offset"] as HSlider
	var minimum_unload := int(pending["mesh_pregen_end_offset"]) + 1
	var unload_value := maxi(
		int(pending["chunk_unload_offset"]),
		minimum_unload
	)
	unload_slider.max_value = 101
	unload_slider.min_value = minimum_unload
	unload_slider.set_value_no_signal(float(unload_value))
	pending["chunk_unload_offset"] = unload_value
	controls["chunk_unload_offset_label"].text = str(unload_value)


func _add_mesh_cache_budget_control() -> void:
	var key := "mesh_cache_budget_mib"
	var container := VBoxContainer.new()
	settings_list.add_child(container)

	var label := Label.new()
	label.text = "Mesh Cache Budget (MiB; 0 = Unlimited)"
	container.add_child(label)

	var budget_row := HBoxContainer.new()
	container.add_child(budget_row)

	var budget_input := SpinBox.new()
	budget_input.min_value = 0
	budget_input.max_value = 4096
	budget_input.step = 16
	budget_input.value = 64
	budget_input.tooltip_text = (
		"Limits cached mesh-array data, not live meshes or cache bookkeeping. 0 is unlimited and can use large amounts of RAM."
	)
	budget_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	budget_row.add_child(budget_input)

	var value_label := Label.new()
	value_label.custom_minimum_size.x = 100
	budget_row.add_child(value_label)

	budget_input.value_changed.connect(
		func(value: float):
			var budget_mib := int(value)
			pending[key] = budget_mib
			value_label.text = (
				"Unlimited" if budget_mib == 0 else "%d MiB" % budget_mib
			)
			status_label.text = "Unapplied changes"
	)

	controls[key] = budget_input
	controls[key + "_label"] = value_label


func _add_terrain_lod_toggle() -> void:
	var toggle := CheckButton.new()
	toggle.text = "Terrain LOD"
	toggle.tooltip_text = (
		"Reduces distant terrain triangles. Existing meshes update over several frames; collision stays full resolution."
	)
	settings_list.add_child(toggle)
	toggle.toggled.connect(
		func(enabled: bool):
			pending["terrain_lod_enabled"] = enabled
			status_label.text = "Unapplied changes"
	)
	controls["terrain_lod_enabled"] = toggle


func _add_section(section_text: String) -> void:
	var separator := HSeparator.new()
	settings_list.add_child(separator)

	var label := Label.new()
	label.text = section_text
	label.add_theme_font_size_override("font_size", 16)
	settings_list.add_child(label)


func _add_option(
	label_text: String,
	key: String,
	options: Array,
	values: Array
) -> void:
	var container := VBoxContainer.new()
	settings_list.add_child(container)

	var label := Label.new()
	label.text = label_text
	container.add_child(label)

	var dropdown := OptionButton.new()
	dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	for i in range(options.size()):
		dropdown.add_item(str(options[i]), i)

	container.add_child(dropdown)

	dropdown.item_selected.connect(
		func(index: int):
			pending[key] = values[index]
			status_label.text = "Unapplied changes"
	)

	controls[key] = dropdown
	controls[key + "_values"] = values


func _add_float_slider(
	label_text: String,
	key: String,
	minimum: float,
	maximum: float,
	step: float
) -> void:
	var container := VBoxContainer.new()
	settings_list.add_child(container)

	var label := Label.new()
	label.text = label_text
	container.add_child(label)

	var slider := HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = step
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(slider)

	var value_label := Label.new()
	container.add_child(value_label)

	slider.value_changed.connect(
		func(value: float):
			pending[key] = value
			value_label.text = "%.2f" % value
			status_label.text = "Unapplied changes"
	)

	controls[key] = slider
	controls[key + "_label"] = value_label





func _load_settings(config_path: String = CONFIG_PATH) -> void:
	var defaults := {
		"scaling_3d_scale": 0.75,
		"scaling_3d_mode": Viewport.SCALING_3D_MODE_FSR,
		"directional_size": 1024,
		"directional_quality": RenderingServer.SHADOW_QUALITY_HARD,
		"terrain_diffuse_mode": BaseMaterial3D.DIFFUSE_TOON,
		"outline_mode": 0,
		"outline_width": 1.0,
		"outline_threshold": 0.04,
		"render_radius": 4,
		"grid_cells": 28,
		"terrain_lod_enabled": false,
		"mesh_cache_budget_mib": 64,
		"mesh_pregen_end_offset": 20,
		"chunk_unload_offset": 21,
	}

	var config := ConfigFile.new()
	var error := config.load(config_path)

	pending.clear()

	for key in defaults:
		if error == OK:
			pending[key] = config.get_value("graphics", key, defaults[key])
		else:
			pending[key] = defaults[key]

	if error == OK and not config.has_section_key("graphics", "outline_mode"):
		if bool(config.get_value("graphics", "outlines_enabled", false)):
			pending["outline_mode"] = 1

	pending["scaling_3d_scale"] = clampf(
		float(pending["scaling_3d_scale"]),
		0.25,
		2.0
	)

	pending["directional_size"] = int(pending["directional_size"])
	pending["directional_quality"] = int(pending["directional_quality"])
	pending["scaling_3d_mode"] = int(pending["scaling_3d_mode"])
	pending["terrain_diffuse_mode"] = int(pending["terrain_diffuse_mode"])
	if not TERRAIN_DIFFUSE_VALUES.has(pending["terrain_diffuse_mode"]):
		push_warning("Graphics: Invalid terrain diffuse mode; using Toon.")
		pending["terrain_diffuse_mode"] = BaseMaterial3D.DIFFUSE_TOON
	pending["outline_mode"] = int(pending["outline_mode"])
	if pending["outline_mode"] == 2:
		pending["outline_mode"] = 1
	if not OUTLINE_MODE_VALUES.has(pending["outline_mode"]):
		push_warning("Graphics: Invalid outline mode; using Off.")
		pending["outline_mode"] = 0
	pending["outline_width"] = clampf(float(pending["outline_width"]), 1.0, 8.0)
	pending["outline_threshold"] = clampf(float(pending["outline_threshold"]), 0.01, 0.2)
	pending["render_radius"] = clampi(
	int(pending["render_radius"]),
	RENDER_DISTANCE_MIN,
	RENDER_DISTANCE_MAX
)

	pending["grid_cells"] = clampi(
		int(pending["grid_cells"]),
		GRID_CELLS_MIN,
		GRID_CELLS_MAX
	)
	pending["terrain_lod_enabled"] = bool(pending["terrain_lod_enabled"])
	pending["mesh_cache_budget_mib"] = clampi(
		int(pending["mesh_cache_budget_mib"]),
		0,
		4096
	)
	pending["mesh_pregen_end_offset"] = clampi(
		int(pending["mesh_pregen_end_offset"]),
		0,
		100
	)
	pending["chunk_unload_offset"] = clampi(
		int(pending["chunk_unload_offset"]),
		int(pending["mesh_pregen_end_offset"]) + 1,
		101
	)

	if not SHADOW_SIZE_VALUES.has(pending["directional_size"]):
		pending["directional_size"] = 1024

	if not SHADOW_QUALITY_VALUES.has(pending["directional_quality"]):
		pending["directional_quality"] = RenderingServer.SHADOW_QUALITY_HARD

	if not UPSCALING_VALUES.has(pending["scaling_3d_mode"]):
		pending["scaling_3d_mode"] = Viewport.SCALING_3D_MODE_FSR

	original = pending.duplicate(true)

	_refresh_controls()


func _refresh_controls() -> void:
	for key in pending:
		if not controls.has(key):
			continue

		var control: Control = controls[key]
		var value: Variant = pending[key]

		if control is HSlider:
			control.set_value_no_signal(float(value))

			if key == "render_radius" or key == "grid_cells":
				controls[key + "_label"].text = str(int(value))
			else:
				controls[key + "_label"].text = "%.2f" % float(value)

		elif control is SpinBox:
			control.set_value_no_signal(float(value))
			if key == "mesh_cache_budget_mib":
				var budget_mib := int(value)
				controls[key + "_label"].text = (
					"Unlimited" if budget_mib == 0 else "%d MiB" % budget_mib
				)

		elif control is CheckButton:
			control.set_pressed_no_signal(bool(value))

		elif control is OptionButton:
			var values: Array = controls[key + "_values"]
			var index := values.find(value)

			if index >= 0:
				control.select(index)
	_sync_chunk_unload_minimum()
	_update_terrain_cache_summary()
func _save_settings(config_path: String = CONFIG_PATH) -> bool:
	var config := ConfigFile.new()

	for key in pending:
		config.set_value("graphics", key, pending[key])

	var error := config.save(config_path)

	if error != OK:
		status_label.text = "Failed to save settings! Error: " + str(error)
		return false

	return true


func _apply_graphics() -> bool:
	viewport.scaling_3d_mode = int(pending["scaling_3d_mode"])
	viewport.scaling_3d_scale = float(pending["scaling_3d_scale"])

	RenderingServer.directional_shadow_atlas_set_size(
		int(pending["directional_size"]),
		true
	)

	RenderingServer.directional_soft_shadow_filter_set_quality(
		int(pending["directional_quality"])
	)

	if chunk_manager == null:
		push_error("Graphics: ChunkManager not found. Check chunk_manager_path.")
		status_label.text = "ERROR: ChunkManager not found!"
		return false

	if not chunk_manager.has_method("set_grid_cells"):
		push_error("Graphics: ChunkManager is missing set_grid_cells().")
		status_label.text = "ERROR: Missing set_grid_cells()!"
		return false
	if not chunk_manager.has_method("set_terrain_lod_enabled"):
		push_error("Graphics: ChunkManager is missing terrain LOD support.")
		status_label.text = "ERROR: Missing terrain LOD support!"
		return false
	if not chunk_manager.has_method("set_mesh_cache_budget_mib"):
		push_error("Graphics: ChunkManager is missing set_mesh_cache_budget_mib().")
		status_label.text = "ERROR: Missing mesh-cache budget support!"
		return false
	if not chunk_manager.has_method("set_chunk_cache_radius_offsets"):
		push_error("Graphics: ChunkManager is missing set_chunk_cache_radius_offsets().")
		status_label.text = "ERROR: Missing terrain cache radius support!"
		return false
	var terrain_material := chunk_manager.get("terrain_material") as StandardMaterial3D
	if terrain_material == null:
		push_error("Graphics: ChunkManager terrain material is unavailable.")
		status_label.text = "ERROR: Terrain material unavailable!"
		return false
	var diffuse_mode := int(pending["terrain_diffuse_mode"])
	if not TERRAIN_DIFFUSE_VALUES.has(diffuse_mode):
		push_error("Graphics: Invalid terrain diffuse mode: %d." % diffuse_mode)
		status_label.text = "ERROR: Invalid terrain diffuse mode!"
		return false
	var outline := chunk_manager.get("outline_instance") as MeshInstance3D
	if outline == null or not outline.material_override is ShaderMaterial:
		push_error("Graphics: Screen-space outline is unavailable.")
		status_label.text = "ERROR: Outline material unavailable!"
		return false
	var outline_material := outline.material_override as ShaderMaterial
	var outline_mode := int(pending["outline_mode"])
	if not OUTLINE_MODE_VALUES.has(outline_mode):
		push_error("Graphics: Invalid outline mode: %d." % outline_mode)
		status_label.text = "ERROR: Invalid outline mode!"
		return false
	outline_material.set_shader_parameter("outline_width", float(pending["outline_width"]))
	outline_material.set_shader_parameter("edge_threshold", float(pending["outline_threshold"]))
	outline.visible = outline_mode == 1
	terrain_material.diffuse_mode = diffuse_mode
	chunk_manager.set("render_radius", int(pending["render_radius"]))
	chunk_manager.call(
		"set_mesh_cache_budget_mib",
		int(pending["mesh_cache_budget_mib"])
	)
	chunk_manager.call(
		"set_chunk_cache_radius_offsets",
		int(pending["mesh_pregen_end_offset"]),
		int(pending["chunk_unload_offset"])
	)
	if not bool(chunk_manager.call("set_grid_cells", int(pending["grid_cells"]))):
		status_label.text = "ERROR: Could not update terrain grid!"
		return false
	if not bool(chunk_manager.call(
		"set_terrain_lod_enabled", bool(pending["terrain_lod_enabled"])
	)):
		status_label.text = "ERROR: Could not update terrain LOD!"
		return false
	chunk_manager.call("update_loaded_chunks", true)

	return true
func _apply_settings() -> void:
	if not _apply_graphics():
		return

	if _save_settings():
		original = pending.duplicate(true)
		status_label.text = "Settings applied and saved!"
		
func _reset_settings() -> void:
	pending = original.duplicate(true)

	_refresh_controls()
	_apply_graphics()

	status_label.text = "Pending changes discarded."
