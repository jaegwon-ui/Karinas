extends Control
## 도트 룩 실험실
## VRM 캐릭터를 아주 작은 해상도로 렌더링한 뒤 외곽선과 색 단계를 입혀 도트처럼 보이게 한다.
## 모델은 characters/ 폴더에 .vrm 을 넣거나, 창에 파일을 끌어다 놓으면 된다.
##
## 명령줄 캡처(확인용):
##   godot --path . -- --capture=저장폴더 [--model=res://characters/...vrm]

const CHARACTERS_DIR := "res://characters"
const FONT := preload("res://assets/fonts/Galmuri11.woff2")
const POST_SHADER := preload("res://pixel_lab/pixel_post.gdshader")

const VIEWS := {"정면": 0.0, "3/4": 35.0, "측면": 90.0, "뒤": 180.0}
const EXPRESSIONS := {"기본": "", "기쁨": "happy", "화남": "angry", "슬픔": "sad", "편안": "relaxed", "놀람": "surprised"}
const SHEET_FRAMES := 8

# 도트 설정
var pixel_height := 96          ## 캐릭터 키가 몇 픽셀로 찍힐지
var yaw_degrees := 35.0
var pitch_degrees := 8.0
var light_yaw_degrees := -35.0
var auto_rotate := false
var motion: int = PoseDriver.Motion.IDLE
var expression := ""

var _time := 0.0
var _capturing := false
var _blink_timer := 3.0
var _model: Node3D
var _model_height := 1.6
var _pose: PoseDriver
var _anim: AnimationPlayer
var _model_paths := PackedStringArray()

# 렌더링 파이프라인: 3D(저해상도) → 후처리(외곽선, 색) → 화면에 정수배 확대
var _pixel_viewport: SubViewport
var _post_viewport: SubViewport
var _hires_viewport: SubViewport
var _pixel_camera: Camera3D
var _hires_camera: Camera3D
var _pivot: Node3D
var _light: DirectionalLight3D
var _post_material: ShaderMaterial
var _display: TextureRect
var _hires_display: TextureRect
var _stage: Control

# UI
var _model_option: OptionButton
var _info_label: Label
var _status_label: Label
var _size_label: Label


func _ready() -> void:
	theme = _make_theme()
	_build_pipeline()
	_build_ui()
	get_window().files_dropped.connect(_on_files_dropped)
	_refresh_model_list()

	var args := _user_args()
	if args.has("model"):
		_load_model(args["model"])
	elif not _model_paths.is_empty():
		_load_model(_model_paths[0])
	else:
		_show_placeholder()

	if args.has("capture"):
		_run_capture(args["capture"])
	elif args.has("sequence"):
		_run_sequence(args["sequence"], args)


func _process(delta: float) -> void:
	if not _capturing:
		_time += delta
		if auto_rotate:
			yaw_degrees = fposmod(yaw_degrees + delta * 45.0, 360.0)
		_update_blink(delta)
	_apply_frame()
	_layout_display()


func _apply_frame() -> void:
	if _pose:
		_pose.apply(motion, _time)
	_pivot.rotation_degrees.y = yaw_degrees
	_light.rotation_degrees = Vector3(-40.0, light_yaw_degrees, 0.0)
	_update_camera(_pixel_camera)
	_update_camera(_hires_camera)


# ---------------------------------------------------------------- 렌더링 파이프라인

func _build_pipeline() -> void:
	_pixel_viewport = SubViewport.new()
	_pixel_viewport.name = "PixelViewport"
	_pixel_viewport.world_3d = World3D.new()
	_pixel_viewport.transparent_bg = true
	_pixel_viewport.msaa_3d = Viewport.MSAA_DISABLED
	_pixel_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_pixel_viewport)

	var world := Node3D.new()
	world.name = "World"
	_pixel_viewport.add_child(world)

	_pivot = Node3D.new()
	_pivot.name = "ModelPivot"
	world.add_child(_pivot)

	_light = DirectionalLight3D.new()
	_light.light_energy = 1.1
	world.add_child(_light)

	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.85, 0.85, 0.95)
	env.ambient_light_energy = 0.55
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	world.add_child(world_env)

	_pixel_camera = _make_camera()
	_pixel_viewport.add_child(_pixel_camera)

	# 같은 3D 세계를 매끈하게 보여주는 비교용 화면
	_hires_viewport = SubViewport.new()
	_hires_viewport.name = "HiResViewport"
	_hires_viewport.world_3d = _pixel_viewport.world_3d
	_hires_viewport.transparent_bg = true
	_hires_viewport.msaa_3d = Viewport.MSAA_4X
	_hires_viewport.size = Vector2i(360, 360)
	_hires_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_hires_viewport)
	_hires_camera = _make_camera()
	_hires_viewport.add_child(_hires_camera)

	# 후처리: 저해상도 그림을 1:1로 받아 외곽선과 색 보정을 한다. 저장도 여기서 꺼낸다.
	_post_viewport = SubViewport.new()
	_post_viewport.name = "PostViewport"
	_post_viewport.transparent_bg = true
	_post_viewport.disable_3d = true
	_post_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_post_viewport)
	var post_rect := TextureRect.new()
	post_rect.texture = _pixel_viewport.get_texture()
	post_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_post_material = ShaderMaterial.new()
	_post_material.shader = POST_SHADER
	post_rect.material = _post_material
	_post_viewport.add_child(post_rect)

	_set_pixel_height(pixel_height)


func _make_camera() -> Camera3D:
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.near = 0.05
	cam.far = 50.0
	cam.current = true
	return cam


func _update_camera(cam: Camera3D) -> void:
	# 화면 높이의 80%쯤이 캐릭터 키가 되도록 잡고, 발밑에 여백을 조금 둔다.
	var frame := _model_height * 1.25
	var center := Vector3(0.0, frame * 0.5 - _model_height * 0.06, 0.0)
	var pitch := deg_to_rad(pitch_degrees)
	cam.size = frame
	cam.position = center + Vector3(0.0, sin(pitch), cos(pitch)) * 10.0
	cam.look_at(center)


func _set_pixel_height(value: int) -> void:
	pixel_height = value
	var side := int(round(value * 1.25))
	_pixel_viewport.size = Vector2i(side, side)
	_post_viewport.size = Vector2i(side, side)
	var post_rect := _post_viewport.get_child(0) as TextureRect
	post_rect.size = Vector2(side, side)
	if _size_label:
		_size_label.text = "캔버스 %d×%d px" % [side, side]


## 화면에 정수배로만 확대해야 픽셀 크기가 들쭉날쭉하지 않다.
func _layout_display() -> void:
	if not _display or not _stage:
		return
	var src := Vector2(_post_viewport.size)
	var area := _stage.size - Vector2(24, 24)
	var scale_factor: float = max(1.0, floor(min(area.x / src.x, area.y / src.y)))
	_display.size = src * scale_factor
	_display.position = ((_stage.size - _display.size) * 0.5).floor()


# ---------------------------------------------------------------- 모델

func _refresh_model_list() -> void:
	_model_paths = VrmLoader.find_models(CHARACTERS_DIR)
	_model_paths.sort()
	_model_option.clear()
	for path in _model_paths:
		_model_option.add_item(path.trim_prefix(CHARACTERS_DIR + "/"))
	if _model_paths.is_empty():
		_model_option.add_item("(characters 폴더가 비어 있어)")


func _load_model(path: String) -> void:
	_set_status("불러오는 중: %s" % path.get_file())
	var model := VrmLoader.load_model(path)
	if model == null:
		_set_status("모델을 못 읽었어: %s" % path.get_file())
		return
	_clear_model()
	_model = model
	_pivot.add_child(model)

	var skeleton := model.find_child("GeneralSkeleton", true, false) as Skeleton3D
	if skeleton == null:
		skeleton = _first_of_type(model, "Skeleton3D") as Skeleton3D
	_pose = PoseDriver.new(skeleton) if skeleton else null
	_anim = model.get_node_or_null("AnimationPlayer") as AnimationPlayer
	_fit_model(model)
	_prepare_materials_for_pixels(model)
	_apply_expression()

	var index := _model_paths.find(path)
	if index >= 0:
		_model_option.select(index)
	_info_label.text = _describe_model(model, path)
	_set_status("불러옴: %s" % path.get_file())


## 작은 해상도에서 튀는 효과를 끈다.
## - 매트캡 림(_SphereAdd): 가장자리 반짝임이 금색 점처럼 흩어진다
## - MToon 외곽선(next_pass): 얇은 선이 끊겨 붉은 점이 된다. 외곽선은 후처리 셰이더가 대신 그린다
func _prepare_materials_for_pixels(model: Node) -> void:
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		for i in mesh.mesh.get_surface_count():
			var mat := mesh.get_active_material(i)
			if mat is ShaderMaterial:
				mat.set_shader_parameter("_SphereAdd", null)
			if mat:
				mat.next_pass = null


func _clear_model() -> void:
	for child in _pivot.get_children():
		child.queue_free()
	_model = null
	_pose = null
	_anim = null


## 발이 바닥(y=0)에 닿고 가운데 서도록 맞춘다.
func _fit_model(model: Node3D) -> void:
	var bounds := AABB()
	var first := true
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mesh := node as MeshInstance3D
		var box := mesh.global_transform * mesh.get_aabb()
		bounds = box if first else bounds.merge(box)
		first = false
	if first:
		return
	model.position.y -= bounds.position.y
	_model_height = max(bounds.size.y, 0.1)


func _describe_model(model: Node, path: String) -> String:
	var meta: Resource = model.get("vrm_meta")
	if meta == null:
		return "%s\n(VRM 정보 없음)" % path.get_file()
	var title: String = meta.get("title")
	var author: String = meta.get("author")
	var license_name: String = meta.get("license_name")
	var redistribution: String = meta.get("allow_redistribution")
	var lines := [
		"이름: %s" % (title if title else path.get_file().get_basename()),
		"만든 사람: %s" % (author if author else "(비어 있음)"),
		"라이선스: %s" % (license_name if license_name else "(비어 있음)"),
	]
	if redistribution == "Disallow":
		lines.append("[주의] 재배포 금지 모델이야. 깃에 올리지 마")
	return "\n".join(lines)


func _show_placeholder() -> void:
	_clear_model()
	var body := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.18
	capsule.height = 1.2
	body.mesh = capsule
	body.position.y = 0.6
	var head := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.13
	sphere.height = 0.26
	head.mesh = sphere
	head.position.y = 1.36
	var root := Node3D.new()
	root.add_child(body)
	root.add_child(head)
	_pivot.add_child(root)
	_model = root
	_model_height = 1.5
	_info_label.text = "모델이 없어서 임시 인형을 보여주는 중이야.\ncharacters 폴더에 .vrm 을 넣어줘."


func _on_files_dropped(files: PackedStringArray) -> void:
	for file in files:
		if file.get_extension().to_lower() in VrmLoader.SUPPORTED_EXTENSIONS:
			_load_model(file)
			return
	_set_status(".vrm 이나 .glb 파일만 넣을 수 있어")


static func _first_of_type(root: Node, type_name: String) -> Node:
	var found := root.find_children("*", type_name, true, false)
	return found[0] if not found.is_empty() else null


# ---------------------------------------------------------------- 표정

func _apply_expression() -> void:
	if _anim == null:
		return
	var anim_name := _find_animation(expression) if expression else ""
	if anim_name:
		_anim.play(anim_name)
	elif _anim.has_animation("RESET"):
		_anim.play("RESET")


func _update_blink(delta: float) -> void:
	if _anim == null or expression != "":
		return
	_blink_timer -= delta
	if _blink_timer <= 0.0:
		_blink_timer = randf_range(2.5, 5.0)
		var blink := _find_animation("blink")
		if blink:
			_anim.play(blink)
			get_tree().create_timer(0.12).timeout.connect(_apply_expression)


func _find_animation(wanted: String) -> String:
	for anim_name in _anim.get_animation_list():
		if anim_name.to_lower() == wanted.to_lower():
			return anim_name
	return ""


# ---------------------------------------------------------------- 저장

func _export_dir() -> String:
	var dir := "res://exports" if OS.has_feature("editor") else "user://exports"
	var absolute := ProjectSettings.globalize_path(dir)
	DirAccess.make_dir_recursive_absolute(absolute)
	return absolute


func _model_slug() -> String:
	if _model == null:
		return "empty"
	return String(_model.name).to_snake_case()


func _grab_frame() -> Image:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	return _post_viewport.get_texture().get_image()


func _save_png(image: Image, path: String, upscale := 4) -> void:
	image.save_png(path)
	if upscale > 1:
		var big := image.duplicate() as Image
		big.resize(image.get_width() * upscale, image.get_height() * upscale, Image.INTERPOLATE_NEAREST)
		big.save_png(path.get_basename() + "_x%d.png" % upscale)


func save_current_frame(dir := "") -> String:
	if dir.is_empty():
		dir = _export_dir()
	var image := await _grab_frame()
	var path := dir.path_join("%s_%dpx.png" % [_model_slug(), pixel_height])
	_save_png(image, path)
	_set_status("저장했어: %s" % path)
	return path


## 지금 동작을 한 바퀴 돌며 SHEET_FRAMES장을 가로로 이어 붙인 스프라이트 시트를 만든다.
func save_sprite_sheet(dir := "") -> String:
	if _capturing:
		return ""
	if dir.is_empty():
		dir = _export_dir()
	_capturing = true
	var restore_time := _time
	var period: float = PoseDriver.MOTION_PERIOD[motion]
	var side := _post_viewport.size
	var sheet := Image.create_empty(side.x * SHEET_FRAMES, side.y, false, Image.FORMAT_RGBA8)
	for i in SHEET_FRAMES:
		var target := period * i / SHEET_FRAMES
		# 머리카락 흔들림(스프링 본)이 따라올 시간을 조금 준 뒤 찍는다.
		_time = target - 0.25
		while _time < target:
			_time = min(_time + 1.0 / 60.0, target)
			await get_tree().process_frame
		var frame := await _grab_frame()
		frame.convert(Image.FORMAT_RGBA8)
		sheet.blit_rect(frame, Rect2i(Vector2i.ZERO, side), Vector2i(side.x * i, 0))
	var motion_slug: String = ["stand", "idle", "battle_idle", "attack"][motion]
	var path := dir.path_join("%s_%s_%dpx_sheet.png" % [_model_slug(), motion_slug, pixel_height])
	_save_png(sheet, path)
	_time = restore_time
	_capturing = false
	_set_status("스프라이트 시트 저장: %s" % path)
	return path


# ---------------------------------------------------------------- 명령줄 캡처 (확인용)

func _user_args() -> Dictionary:
	var out := {}
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--"):
			var parts := arg.trim_prefix("--").split("=", true, 1)
			out[parts[0]] = parts[1] if parts.size() > 1 else ""
	return out


## GIF/영상용 연속 프레임. 부드럽게 뽑으려면 --fixed-fps 50 과 함께 실행한다.
##   godot --path . --fixed-fps 50 -- --sequence=폴더 --motion=idle --px=128 --yaw=35 [--spin] [--loops=2] [--raw]
func _run_sequence(dir: String, args: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	var slugs := ["stand", "idle", "battle_idle", "attack"]
	motion = max(0, slugs.find(args.get("motion", "idle")))
	_set_pixel_height(int(args.get("px", "128")))
	var start_yaw := float(args.get("yaw", "35"))
	yaw_degrees = start_yaw
	var fps := float(args.get("fps", "50"))  # --fixed-fps 값과 맞춘다
	var period: float = PoseDriver.MOTION_PERIOD[motion]
	var total := int(round(period * int(args.get("loops", "1")) * fps))
	_capturing = true
	# 한 바퀴 먼저 돌려서 머리카락이 자리를 잡게 한다.
	var warmup := int(round(period * fps))
	for i in warmup + total:
		_time = i / fps
		if args.has("spin"):
			yaw_degrees = start_yaw + 360.0 * float(max(0, i - warmup)) / total
		await RenderingServer.frame_post_draw
		if i >= warmup:
			var n := i - warmup
			_post_viewport.get_texture().get_image().save_png(dir.path_join("frame_%04d.png" % n))
			if args.has("raw"):
				_pixel_viewport.get_texture().get_image().save_png(dir.path_join("raw_%04d.png" % n))
	print("SEQUENCE_DONE ", total, " frames @ ", fps, "fps -> ", dir)
	get_tree().quit()


func _run_capture(dir: String) -> void:
	dir = ProjectSettings.globalize_path(dir) if dir.begins_with("res://") or dir.begins_with("user://") else dir
	DirAccess.make_dir_recursive_absolute(dir)
	await get_tree().create_timer(0.5).timeout
	for view in ["정면", "3/4", "측면"]:
		yaw_degrees = VIEWS[view]
		for px in [64, 96, 128, 160]:
			_set_pixel_height(px)
			var image := await _grab_frame()
			_save_png(image, dir.path_join("view_%d_%dpx.png" % [int(VIEWS[view]), px]))
	yaw_degrees = VIEWS["3/4"]
	_set_pixel_height(96)
	for m in PoseDriver.Motion.values():
		motion = m
		await save_sprite_sheet(dir)
	motion = PoseDriver.Motion.IDLE
	await get_tree().create_timer(0.3).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(dir.path_join("ui.png"))
	_hires_viewport.get_texture().get_image().save_png(dir.path_join("hires.png"))
	print("CAPTURE_DONE ", dir)
	get_tree().quit()


# ---------------------------------------------------------------- UI

func _make_theme() -> Theme:
	var font := FONT.duplicate() as FontFile
	font.antialiasing = TextServer.FONT_ANTIALIASING_NONE
	font.hinting = TextServer.HINTING_NONE
	font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	var t := Theme.new()
	t.default_font = font
	t.default_font_size = 12
	return t


func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color("1b1a24")
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var root := HBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var panel_bg := PanelContainer.new()
	panel_bg.custom_minimum_size.x = 300
	root.add_child(panel_bg)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel_bg.add_child(scroll)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12)
	scroll.add_child(margin)
	var panel := VBoxContainer.new()
	panel.add_theme_constant_override("separation", 6)
	margin.add_child(panel)

	_stage = Control.new()
	_stage.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stage.clip_contents = true
	root.add_child(_stage)
	var stage_bg := ColorRect.new()
	stage_bg.color = Color("2a2838")
	stage_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_stage.add_child(stage_bg)
	_display = TextureRect.new()
	_display.texture = _post_viewport.get_texture()
	_display.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_display.stretch_mode = TextureRect.STRETCH_SCALE
	_stage.add_child(_display)

	_hires_display = TextureRect.new()
	_hires_display.texture = _hires_viewport.get_texture()
	_hires_display.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_hires_display.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_hires_display.size = Vector2(180, 180)
	_hires_display.position = Vector2(12, 12)
	_stage.add_child(_hires_display)
	var hires_label := Label.new()
	hires_label.text = "원본 3D"
	hires_label.position = Vector2(16, 196)
	hires_label.modulate = Color(1, 1, 1, 0.6)
	_stage.add_child(hires_label)

	_status_label = Label.new()
	_status_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_status_label.offset_top = -28
	_status_label.offset_left = 12
	_status_label.modulate = Color(1, 1, 1, 0.7)
	_stage.add_child(_status_label)

	# --- 왼쪽 조작판
	_title(panel, "Karinas 도트 실험실")

	_section(panel, "모델")
	_model_option = OptionButton.new()
	_model_option.item_selected.connect(func(i: int) -> void:
		if i < _model_paths.size():
			_load_model(_model_paths[i]))
	panel.add_child(_model_option)
	var model_buttons := HBoxContainer.new()
	panel.add_child(model_buttons)
	_button(model_buttons, "목록 새로고침", _refresh_model_list)
	_button(model_buttons, "폴더 열기", func() -> void:
		OS.shell_open(ProjectSettings.globalize_path(CHARACTERS_DIR)))
	_info_label = Label.new()
	_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info_label.modulate = Color(1, 1, 1, 0.75)
	panel.add_child(_info_label)
	_hint(panel, "창에 .vrm 파일을 끌어다 놓아도 돼")

	_section(panel, "도트 크기")
	_slider(panel, "캐릭터 키(px)", 48, 256, 8, pixel_height, func(v: float) -> void: _set_pixel_height(int(v)))
	_size_label = Label.new()
	_size_label.modulate = Color(1, 1, 1, 0.6)
	panel.add_child(_size_label)
	_set_pixel_height(pixel_height)

	_section(panel, "방향과 카메라")
	var view_row := HBoxContainer.new()
	panel.add_child(view_row)
	var yaw_slider := _slider(panel, "회전", 0, 360, 1, yaw_degrees, func(v: float) -> void: yaw_degrees = v)
	for view_name: String in VIEWS:
		_button(view_row, view_name, func() -> void:
			yaw_degrees = VIEWS[view_name]
			yaw_slider.value = yaw_degrees)
	_check(panel, "자동 회전", auto_rotate, func(on: bool) -> void: auto_rotate = on)
	_slider(panel, "카메라 높이 각도", -10, 45, 1, pitch_degrees, func(v: float) -> void: pitch_degrees = v)
	_slider(panel, "빛 방향", -180, 180, 5, light_yaw_degrees, func(v: float) -> void: light_yaw_degrees = v)

	_section(panel, "동작과 표정")
	var motions := OptionButton.new()
	for m: int in PoseDriver.MOTION_LABELS:
		motions.add_item(PoseDriver.MOTION_LABELS[m], m)
	motions.select(motions.get_item_index(motion))
	motions.item_selected.connect(func(i: int) -> void: motion = motions.get_item_id(i))
	panel.add_child(motions)
	var faces := OptionButton.new()
	for label: String in EXPRESSIONS:
		faces.add_item(label)
	faces.item_selected.connect(func(i: int) -> void:
		expression = EXPRESSIONS[faces.get_item_text(i)]
		_apply_expression())
	panel.add_child(faces)

	_section(panel, "도트 다듬기")
	_check(panel, "외곽선", true, func(on: bool) -> void: _post_material.set_shader_parameter("outline_enabled", on))
	_check(panel, "외곽선 대각선까지", false, func(on: bool) -> void: _post_material.set_shader_parameter("outline_diagonal", on))
	var outline_color := ColorPickerButton.new()
	outline_color.color = Color(0.13, 0.08, 0.16)
	outline_color.custom_minimum_size.y = 24
	outline_color.color_changed.connect(func(c: Color) -> void: _post_material.set_shader_parameter("outline_color", c))
	panel.add_child(outline_color)
	_slider(panel, "색 단계 (0=끔)", 0, 16, 1, 0, func(v: float) -> void: _post_material.set_shader_parameter("color_levels", v))
	_slider(panel, "채도", 0.5, 1.6, 0.05, 1.1, func(v: float) -> void: _post_material.set_shader_parameter("saturation", v))

	_section(panel, "저장")
	_button(panel, "지금 프레임 PNG 저장", save_current_frame)
	_button(panel, "스프라이트 시트 저장 (%d프레임)" % SHEET_FRAMES, save_sprite_sheet)
	_button(panel, "저장 폴더 열기", func() -> void: OS.shell_open(_export_dir()))


func _title(parent: Control, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 24)
	label.add_theme_color_override("font_color", Color("ffd6e8"))
	parent.add_child(label)


func _section(parent: Control, text: String) -> void:
	parent.add_child(HSeparator.new())
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Color("9fd8ff"))
	parent.add_child(label)


func _hint(parent: Control, text: String) -> void:
	var label := Label.new()
	label.text = text
	label.modulate = Color(1, 1, 1, 0.5)
	parent.add_child(label)


func _button(parent: Control, text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.pressed.connect(callback)
	parent.add_child(button)
	return button


func _check(parent: Control, text: String, value: bool, callback: Callable) -> CheckBox:
	var box := CheckBox.new()
	box.text = text
	box.button_pressed = value
	box.toggled.connect(callback)
	parent.add_child(box)
	return box


func _slider(parent: Control, text: String, min_value: float, max_value: float, step: float, value: float, callback: Callable) -> HSlider:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var value_label := Label.new()
	row.add_child(value_label)
	var slider := HSlider.new()
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = step
	slider.value = value
	value_label.text = _format_value(value, step)
	slider.value_changed.connect(func(v: float) -> void:
		value_label.text = _format_value(v, step)
		callback.call(v))
	parent.add_child(slider)
	return slider


static func _format_value(v: float, step: float) -> String:
	return str(int(v)) if step >= 1.0 else "%.2f" % v


func _set_status(text: String) -> void:
	if _status_label:
		_status_label.text = text
	print(text)
