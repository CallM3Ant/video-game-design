@tool
extends EditorScript

func _run():
	# 2048x1024 is plenty for stars and saves tons of VRAM!
	var width = 2048
	var height = 1024
	var img = Image.create(width, height, false, Image.FORMAT_RGBA8)
	var longitude_sines := PackedFloat64Array()
	var longitude_cosines := PackedFloat64Array()
	longitude_sines.resize(width)
	longitude_cosines.resize(width)
	for x in range(width):
		var lon = (float(x) / width - 0.5) * 2.0 * PI
		longitude_sines[x] = sin(lon)
		longitude_cosines[x] = cos(lon)

	print("Baking stars... This might take a few seconds.")
	
	for y in range(height):
		var lat = (float(y) / height - 0.5) * PI
		var lat_sine := sin(lat)
		var lat_cosine := cos(lat)
		for x in range(width):
			var dir = Vector3(
				lat_cosine * longitude_sines[x], lat_sine,
				lat_cosine * longitude_cosines[x]
			).normalized()
			
			# --- Cubemap star generation logic ---
			var ad = dir.abs()
			var face_uv = Vector2()
			var face = 0
			
			if ad.x >= ad.y and ad.x >= ad.z:
				face = 0 if dir.x > 0.0 else 1
				face_uv = Vector2(dir.z, dir.y) / ad.x
			elif ad.y >= ad.z:
				face = 2 if dir.y > 0.0 else 3
				face_uv = Vector2(dir.x, dir.z) / ad.y
			else:
				face = 4 if dir.z > 0.0 else 5
				face_uv = Vector2(dir.x, dir.y) / ad.z

			var p = face_uv * 30.0
			var cell_x = int(floor(p.x))
			var cell_y = int(floor(p.y))
			var local = Vector2(p.x - cell_x, p.y - cell_y)

			var h = hash_uint((cell_x * 1597334673) ^ (cell_y * 3812015801) ^ (face * 2654435761))
			var fh = float(h & 0x00FFFFFF) / 16777215.0
			
			# If no star, leave pixel black
			if fh > 0.035:
				img.set_pixel(x, y, Color(0, 0, 0, 0))
				continue

			var h2 = hash_uint(h ^ 0x9e3779b9)
			var h3 = hash_uint(h2 ^ 0x85ebca6b)
			
			var position = Vector2(0.25 + 0.5 * float(h2 & 0xFF) / 255.0, 
								   0.25 + 0.5 * float((h2 >> 8) & 0xFF) / 255.0)
			
			# SMALLER STARS FIX: Reduced from 0.04/0.08 to 0.015/0.035
			var size = lerp(0.015, 0.035, float((h2 >> 16) & 0xFF) / 255.0)

			var delta = position - local
			var dist = delta.length()
			var core = 1.0 - smoothstep(size * 0.65, size, dist)

			# Pack data into color channels
			var r = float((h2 >> 24) & 0xFF) / 255.0       # Phase
			var g = float(h3 & 0xFF) / 255.0               # Speed
			var b = core                                   # Brightness
			
			img.set_pixel(x, y, Color(r, g, b, 1.0))

	# Save the image to the root of your project
	var path = "res://star_cache.png"
	img.save_png(path)
	print("Done! Saved star_cache.png")
	
	# Refresh the FileSystem dock
	EditorInterface.get_resource_filesystem().scan()

func hash_uint(x: int) -> int:
	x = x & 0xFFFFFFFF
	x = x ^ (x >> 16)
	x = (x * 0x85ebca6b) & 0xFFFFFFFF
	x = x ^ (x >> 13)
	x = (x * 0xc2b2ae35) & 0xFFFFFFFF
	x = x ^ (x >> 16)
	return x & 0xFFFFFFFF
