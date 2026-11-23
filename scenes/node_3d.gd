extends Node3D
# Terrain collision test harness. Attach to any Node3D. Needs a Camera3D.
# Boxes: layer 2. Terrain: layer 1. Ray mask covers both.

const BOX_SIZE := 1.5
const BOX_LAYER := 2
const TERRAIN_LAYER := 1
const GRAB_MIN_DISTANCE := 3.0
const GRAB_MAX_DISTANCE := 40.0
const GRAB_SCROLL_STEP := 1.5
const THROW_SAMPLE_FRAMES := 5

@export var spawn_count := 5
@export var spawn_height := 12.0
@export var spawn_forward := 6.0
@export var box_mass := 5.0
@export var initial_spawn := true

var camera: Camera3D
var grabbed_body: RigidBody3D
var grab_distance := 8.0
var grab_offset_local := Vector3.ZERO
var recent_positions: Array[Vector3] = []
var hud_label: Label
var shared_box_mesh: BoxMesh
var shared_box_shape: BoxShape3D


func _ready() -> void:
	camera = get_viewport().get_camera_3d()
	if camera == null:
		push_error("No camera in viewport.")
		set_process(false)
		set_physics_process(false)
		return
	shared_box_mesh = BoxMesh.new()
	shared_box_mesh.size = Vector3.ONE * BOX_SIZE
	shared_box_shape = BoxShape3D.new()
	shared_box_shape.size = Vector3.ONE * BOX_SIZE
	_setup_hud()
	if initial_spawn:
		_spawn_boxes()


func _setup_hud() -> void:
	var canvas := CanvasLayer.new()
	canvas.layer = 10
	add_child(canvas)

	hud_label = Label.new()
	hud_label.position = Vector2(12, 260)
	hud_label.add_theme_color_override("font_color", Color.YELLOW)
	hud_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	hud_label.add_theme_constant_override("shadow_offset_x", 2)
	hud_label.add_theme_constant_override("shadow_offset_y", 2)
	hud_label.add_theme_font_size_override("font_size", 18)
	hud_label.text = (
		"[ COLLISION TEST ]\n" +
		"Click+drag box:  grab / throw\n" +
		"Scroll:          grab distance\n" +
		"Space:           spawn box\n" +
		"R:               reset boxes\n" +
		"Esc:             toggle mouse capture"
	)
	canvas.add_child(hud_label)


func _spawn_boxes() -> void:
	var forward := -camera.global_basis.z
	forward.y = 0.0
	if forward.length() < 0.001:
		forward = Vector3.FORWARD
	forward = forward.normalized()

	var base := camera.global_position + forward * spawn_forward + Vector3.UP * spawn_height

	for i in range(spawn_count):
		var angle := TAU * float(i) / float(spawn_count)
		var offset := Vector3(cos(angle) * 3.0, 0.0, sin(angle) * 3.0)
		_spawn_box_at(base + offset)


func _spawn_box_at(pos: Vector3) -> void:
	var body := RigidBody3D.new()
	body.mass = box_mass
	print("[Test] Spawning box. Layer: ", body.collision_layer, " Mask: ", body.collision_mask)
	body.collision_layer = BOX_LAYER
	body.collision_mask = TERRAIN_LAYER | BOX_LAYER

	var mesh := MeshInstance3D.new()
	mesh.mesh = shared_box_mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.from_hsv(randf(), 0.7, 0.9)
	mat.roughness = 0.5
	mesh.material_override = mat
	body.add_child(mesh)

	var shape := CollisionShape3D.new()
	shape.shape = shared_box_shape
	body.add_child(shape)

	# 1. Add to tree first
	add_child(body) 
	
	# 2. Now it's safe to set the global position
	body.global_position = pos
	
func _input(event: InputEvent) -> void:
	if camera == null:
		return

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_try_grab()
			else:
				_release()
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and grabbed_body != null:
			grab_distance = minf(grab_distance + GRAB_SCROLL_STEP, GRAB_MAX_DISTANCE)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and grabbed_body != null:
			grab_distance = maxf(grab_distance - GRAB_SCROLL_STEP, GRAB_MIN_DISTANCE)

	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE:
				var spawn_pos := camera.global_position + -camera.global_basis.z * 5.0 + Vector3.UP * 3.0
				_spawn_box_at(spawn_pos)	
			KEY_R:
				_reset_boxes()
			KEY_ESCAPE:
				Input.mouse_mode = (
					Input.MOUSE_MODE_VISIBLE
					if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
					else Input.MOUSE_MODE_CAPTURED
				)


func _try_grab() -> void:
	var mouse_pos := get_viewport().get_mouse_position()
	var from := camera.project_ray_origin(mouse_pos)
	var dir := camera.project_ray_normal(mouse_pos)
	var to := from + dir * 1000.0

	var query := PhysicsRayQueryParameters3D.create(from, to, TERRAIN_LAYER | BOX_LAYER)
	var result := get_world_3d().direct_space_state.intersect_ray(query)

	if result.is_empty():
		return
	var collider: Object = result.collider
	if not (collider is RigidBody3D):
		return

	grabbed_body = collider as RigidBody3D
	grabbed_body.freeze = true

	var hit_point: Vector3 = result.position
	grab_distance = clampf(
		camera.global_position.distance_to(hit_point),
		GRAB_MIN_DISTANCE, GRAB_MAX_DISTANCE
	)

	# Camera-local offset keeps the grab point under the cursor as you look around
	grab_offset_local = camera.global_basis.inverse() * (grabbed_body.global_position - hit_point)

	recent_positions.clear()


func _release() -> void:
	if grabbed_body == null:
		return
	grabbed_body.freeze = false

	if recent_positions.size() >= 2:
		var count := recent_positions.size() - 1
		var delta_t := count / float(Engine.physics_ticks_per_second)
		if delta_t > 0.0:
			grabbed_body.linear_velocity = (recent_positions[-1] - recent_positions[0]) / delta_t

	grabbed_body = null
	recent_positions.clear()


func _physics_process(_delta: float) -> void:
	if grabbed_body == null or camera == null:
		return

	var mouse_pos := get_viewport().get_mouse_position()
	var dir := camera.project_ray_normal(mouse_pos)

	var target := camera.global_position + dir * grab_distance
	target += camera.global_basis * grab_offset_local

	grabbed_body.global_position = target

	recent_positions.append(target)
	if recent_positions.size() > THROW_SAMPLE_FRAMES:
		recent_positions.pop_front()
	for child in get_children():
		if child is RigidBody3D and not child.freeze:
			if child.global_position.y < -100.0:
				printerr("[Test] BOX FELL THROUGH THE WORLD! Y pos: ", child.global_position.y)
				child.queue_free() 
func _reset_boxes() -> void:
	for child in get_children():
		if child is RigidBody3D:
			child.queue_free()
	await get_tree().process_frame
	_spawn_boxes()
