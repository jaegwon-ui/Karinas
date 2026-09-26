class_name KnightKit
extends Node3D
## 아무 VRM 캐릭터에나 붙이는 여기사 장비: 펄럭이는 망토, 검, 어깨 갑옷.
## 망토는 점과 막대로 된 간단한 천 물리(베를레 적분)로 움직이고, 몸통과 다리를 뚫지 않게 밀어낸다.
## 모든 계산은 스켈레톤 공간 기준 오프셋으로 적었다. 캐릭터는 +Z를 보고 왼쪽이 +X다.

const TOON := preload("res://pixel_lab/toon_flat.gdshader")

# 망토 모양
const COLS := 9
const ROWS := 13
const TOP_WIDTH := 0.30
const BOTTOM_WIDTH := 0.62
const LENGTH := 1.02
const ITERATIONS := 14
const SUBSTEP := 1.0 / 120.0

## 바람 세기. 0이면 축 늘어지고, 클수록 뒤로 휘날린다.
var wind_strength := 1.0

var _skeleton: Skeleton3D
var _points: PackedVector3Array
var _previous: PackedVector3Array
var _links: Array[Vector3i] = []  # (a, b, 없음) 쌍
var _link_rest: PackedFloat32Array
var _time := 0.0
var _accumulator := 0.0

var _cape_mesh := ImmediateMesh.new()
var _cape_material: ShaderMaterial
var _materials: Array[ShaderMaterial] = []
var _sword: Node3D
var _pauldrons: Array[Node3D] = []


func setup(skeleton: Skeleton3D) -> void:
	_skeleton = skeleton
	top_level = true

	_cape_material = _toon_material(Color(0.55, 0.08, 0.12), Color(0.28, 0.04, 0.14), Color(0.8, 0.24, 0.2))
	_cape_material.set_shader_parameter("trim_start", 0.93)
	var cape := MeshInstance3D.new()
	cape.mesh = _cape_mesh
	cape.material_override = _cape_material
	add_child(cape)

	_sword = _build_sword()
	add_child(_sword)
	for side in [1.0, -1.0]:
		var pauldron := _build_pauldron()
		pauldron.set_meta("side", side)
		add_child(pauldron)
		_pauldrons.append(pauldron)

	_init_cloth()


func set_light_direction(dir: Vector3) -> void:
	for mat in _materials:
		mat.set_shader_parameter("light_dir", dir)


func _process(delta: float) -> void:
	if _skeleton == null:
		return
	_time += delta
	_accumulator = min(_accumulator + delta, 0.1)
	while _accumulator >= SUBSTEP:
		_accumulator -= SUBSTEP
		_step_cloth(SUBSTEP)
	_draw_cape()
	_place_props()


# ---------------------------------------------------------------- 뼈 위치

func _bone_origin(name: String) -> Vector3:
	var idx := _skeleton.find_bone(name)
	return _skeleton.global_transform * _skeleton.get_bone_global_pose(idx).origin


## 쉬는 자세에서 지금 자세까지 이 뼈가 얼마나 돌았는지(월드 기준)
func _bone_turn(name: String) -> Basis:
	var idx := _skeleton.find_bone(name)
	var turn := _skeleton.get_bone_global_pose(idx).basis.orthonormalized() * _skeleton.get_bone_global_rest(idx).basis.orthonormalized().inverse()
	var skel := _skeleton.global_basis.orthonormalized()
	return skel * turn * skel.inverse()


## 몸통 기준 방향들(월드)
func _torso_axes() -> Dictionary:
	var turn := _bone_turn("UpperChest") * _skeleton.global_basis.orthonormalized()
	return {
		"forward": (turn * Vector3.BACK).normalized(),  # Vector3.BACK = +Z = 캐릭터 정면
		"left": (turn * Vector3.RIGHT).normalized(),
		"up": (turn * Vector3.UP).normalized(),
	}


# ---------------------------------------------------------------- 망토 천 물리

func _anchor_points() -> PackedVector3Array:
	var axes := _torso_axes()
	var left := _bone_origin("LeftUpperArm")
	var right := _bone_origin("RightUpperArm")
	var neck := _bone_origin("Neck")
	var out := PackedVector3Array()
	for c in COLS:
		var u := float(c) / (COLS - 1)  # 0 = 왼쪽, 1 = 오른쪽
		var across := left.lerp(right, u)
		across = across.lerp(Vector3(across.x, neck.y - 0.03, across.z), 0.6)
		var curve := 1.0 - pow(u * 2.0 - 1.0, 2.0)  # 가운데가 등 쪽으로 더 둥글게
		out.append(across - axes["forward"] * (0.07 + 0.035 * curve) + axes["up"] * 0.01)
	return out


func _init_cloth() -> void:
	var anchors := _anchor_points()
	var axes := _torso_axes()
	_points.resize(COLS * ROWS)
	for r in ROWS:
		var v := float(r) / (ROWS - 1)
		for c in COLS:
			var u := float(c) / (COLS - 1) - 0.5
			var top: Vector3 = anchors[c]
			var spread := (BOTTOM_WIDTH - TOP_WIDTH) * u * v
			_points[r * COLS + c] = top + axes["left"] * -spread - axes["forward"] * 0.05 * v + Vector3.DOWN * LENGTH * v
	_previous = _points.duplicate()

	_links.clear()
	for r in ROWS:
		for c in COLS:
			var i := r * COLS + c
			if c + 1 < COLS:
				_links.append(Vector3i(i, i + 1, 0))
			if r + 1 < ROWS:
				_links.append(Vector3i(i, i + COLS, 0))
			if r + 1 < ROWS and c + 1 < COLS:
				_links.append(Vector3i(i, i + COLS + 1, 0))
				_links.append(Vector3i(i + 1, i + COLS, 0))
			if r + 2 < ROWS:
				_links.append(Vector3i(i, i + COLS * 2, 0))  # 굽힘 저항
	_link_rest.resize(_links.size())
	for k in _links.size():
		_link_rest[k] = _points[_links[k].x].distance_to(_points[_links[k].y])


func _step_cloth(dt: float) -> void:
	var axes := _torso_axes()
	var back: Vector3 = -axes["forward"]
	var left: Vector3 = axes["left"]
	var gust := 1.0 + 0.55 * sin(_time * 1.7) + 0.3 * sin(_time * 4.3 + 1.3)
	var wind: Vector3 = (back * 5.5 * gust + left * 1.6 * sin(_time * 1.1) + Vector3.UP * 0.8) * wind_strength
	var gravity := Vector3(0, -9.8, 0)

	for r in range(1, ROWS):
		var v := float(r) / (ROWS - 1)
		for c in COLS:
			var i := r * COLS + c
			var ripple := sin(_time * 7.0 - r * 0.9 + c * 0.7) * 1.6 * wind_strength
			var accel: Vector3 = gravity + wind * v + back * ripple * v
			var p := _points[i]
			_points[i] = p + (p - _previous[i]) * 0.985 + accel * dt * dt
			_previous[i] = p

	var anchors := _anchor_points()
	var capsules := _body_capsules()
	for _iteration in ITERATIONS:
		for c in COLS:
			_points[c] = anchors[c]
		for k in _links.size():
			var link := _links[k]
			var a := _points[link.x]
			var b := _points[link.y]
			var d := b - a
			var length := d.length()
			if length < 0.00001:
				continue
			var correction := d * (1.0 - _link_rest[k] / length) * 0.5
			var a_pinned := link.x < COLS
			var b_pinned := link.y < COLS
			if a_pinned and not b_pinned:
				_points[link.y] = b - correction * 2.0
			elif b_pinned and not a_pinned:
				_points[link.x] = a + correction * 2.0
			elif not a_pinned:
				_points[link.x] = a + correction
				_points[link.y] = b - correction
		for i in range(COLS, _points.size()):
			_points[i] = _push_out(_points[i], capsules)
	for c in COLS:
		_points[c] = anchors[c]
		_previous[c] = anchors[c]


## 망토가 뚫고 들어가면 안 되는 몸 부위: [시작, 끝, 반지름]
func _body_capsules() -> Array:
	return [
		[_bone_origin("Hips"), _bone_origin("Neck"), 0.15],
		[_bone_origin("LeftUpperLeg"), _bone_origin("LeftLowerLeg"), 0.1],
		[_bone_origin("RightUpperLeg"), _bone_origin("RightLowerLeg"), 0.1],
		[_bone_origin("LeftLowerLeg"), _bone_origin("LeftFoot"), 0.075],
		[_bone_origin("RightLowerLeg"), _bone_origin("RightFoot"), 0.075],
	]


static func _push_out(p: Vector3, capsules: Array) -> Vector3:
	for capsule in capsules:
		var a: Vector3 = capsule[0]
		var b: Vector3 = capsule[1]
		var radius: float = capsule[2]
		var ab := b - a
		var t: float = clamp((p - a).dot(ab) / max(ab.length_squared(), 0.00001), 0.0, 1.0)
		var closest := a + ab * t
		var offset := p - closest
		var dist := offset.length()
		if dist < radius and dist > 0.00001:
			p = closest + offset / dist * radius
	return p


func _draw_cape() -> void:
	var back: Vector3 = -_torso_axes()["forward"]
	var normals := PackedVector3Array()
	normals.resize(_points.size())
	for r in ROWS - 1:
		for c in COLS - 1:
			var i := r * COLS + c
			var n := (_points[i + COLS] - _points[i]).cross(_points[i + 1] - _points[i])
			for j in [i, i + 1, i + COLS, i + COLS + 1]:
				normals[j] += n
	_cape_mesh.clear_surfaces()
	_cape_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for r in ROWS - 1:
		for c in COLS - 1:
			var quad := [r * COLS + c, r * COLS + c + 1, (r + 1) * COLS + c, (r + 1) * COLS + c + 1]
			for j in [0, 1, 2, 1, 3, 2]:  # 앞면(겉감)이 등 바깥쪽을 보도록
				var i: int = quad[j]
				var n := normals[i].normalized()
				_cape_mesh.surface_set_normal(n if n.dot(back) >= 0.0 else -n)
				_cape_mesh.surface_set_uv(Vector2(float(i % COLS) / (COLS - 1), float(i / COLS) / (ROWS - 1)))
				_cape_mesh.surface_add_vertex(_points[i])
	_cape_mesh.surface_end()


# ---------------------------------------------------------------- 검과 어깨 갑옷

func _place_props() -> void:
	# 검: 오른손 주먹 속을 지나 엄지 쪽(+Z)으로 칼날이 뻗는다
	var hand := _bone_origin("RightHand")
	var turn := _bone_turn("RightHand")
	var skel := _skeleton.global_basis.orthonormalized()
	_sword.global_transform = Transform3D(turn * skel, hand + turn * skel * Vector3(-0.065, -0.015, 0.01))

	for pauldron in _pauldrons:
		var side: float = pauldron.get_meta("side")
		var bone := "LeftUpperArm" if side > 0 else "RightUpperArm"
		var arm_turn := _bone_turn(bone)
		var joint := _bone_origin(bone)
		var base := Basis(Vector3.BACK, -side * 0.35)  # 쉬는 자세에서 바깥쪽으로 살짝 기운 돔
		pauldron.global_transform = Transform3D(arm_turn * skel * base, joint + arm_turn * skel * Vector3(side * 0.03, 0.035, 0.0))


func _build_sword() -> Node3D:
	var root := Node3D.new()
	var steel := _toon_material(Color(0.72, 0.77, 0.88), Color(0.38, 0.4, 0.58), Color(0.95, 0.97, 1.0))
	var gold := _toon_material(Color(0.86, 0.66, 0.26), Color(0.55, 0.33, 0.14), Color(1.0, 0.88, 0.5))
	var leather := _toon_material(Color(0.32, 0.18, 0.14), Color(0.18, 0.09, 0.1), Color(0.42, 0.26, 0.2))
	# 칼날은 +Z로 뻗는다
	root.add_child(_box(Vector3(0.012, 0.045, 0.78), Vector3(0, 0, 0.47), steel))
	root.add_child(_box(Vector3(0.03, 0.2, 0.03), Vector3(0, 0, 0.07), gold))  # 가드
	root.add_child(_box(Vector3(0.028, 0.028, 0.13), Vector3(0, 0, 0.0), leather))  # 손잡이
	root.add_child(_box(Vector3(0.045, 0.045, 0.045), Vector3(0, 0, -0.08), gold))  # 폼멜
	return root


func _build_pauldron() -> Node3D:
	var steel := _toon_material(Color(0.62, 0.66, 0.78), Color(0.3, 0.3, 0.48), Color(0.9, 0.93, 1.0))
	var dome := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.is_hemisphere = true
	sphere.radius = 0.085
	sphere.height = 0.06
	sphere.radial_segments = 16
	sphere.rings = 6
	dome.mesh = sphere
	dome.material_override = steel
	var root := Node3D.new()
	root.add_child(dome)
	return root


func _box(size: Vector3, offset: Vector3, material: ShaderMaterial) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = offset
	mesh.material_override = material
	return mesh


func _toon_material(base: Color, shade: Color, highlight: Color) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = TOON
	mat.set_shader_parameter("base_color", base)
	mat.set_shader_parameter("shade_color", shade)
	mat.set_shader_parameter("highlight_color", highlight)
	_materials.append(mat)
	return mat
