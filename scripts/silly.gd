# AI SCRIPT
extends Camera3D

var mouse_sensitivity := 0.002
var move_speed := 20.0
var speed_multiplier := 1.0

var min_speed := 2.0
var max_speed := 100.0

var pitch := 0.0
var yaw := 0.0


func _ready() -> void:
	yaw = rotation.y
	pitch = rotation.x


func _input(event: InputEvent) -> void:

	if event is InputEventMouseButton:

		if event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			else:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				speed_multiplier = clampf(
					speed_multiplier + 0.5,
					0.1,
					10.0
				)

		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				speed_multiplier = clampf(
					speed_multiplier - 0.5,
					0.1,
					10.0
				)

	if event is InputEventMouseMotion:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:

			yaw -= event.relative.x * mouse_sensitivity
			pitch -= event.relative.y * mouse_sensitivity

			pitch = clampf(pitch, -1.5, 1.5)

			rotation.y = yaw
			rotation.x = pitch


func _process(delta: float) -> void:

	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return

	var direction := Vector3.ZERO

	var forward := -transform.basis.z
	var right := transform.basis.x

	if Input.is_physical_key_pressed(KEY_W):
		direction += forward

	if Input.is_physical_key_pressed(KEY_S):
		direction -= forward

	if Input.is_physical_key_pressed(KEY_D):
		direction += right

	if Input.is_physical_key_pressed(KEY_A):
		direction -= right

	if Input.is_physical_key_pressed(KEY_SPACE):
		direction += Vector3.UP

	if Input.is_physical_key_pressed(KEY_CTRL):
		direction -= Vector3.UP

	if direction.length_squared() > 0.0:
		direction = direction.normalized()

	var current_speed := move_speed * speed_multiplier

	if Input.is_physical_key_pressed(KEY_SHIFT):
		current_speed *= 3.0

	global_position += direction * current_speed * delta
