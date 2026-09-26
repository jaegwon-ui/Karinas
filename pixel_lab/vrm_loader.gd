class_name VrmLoader
extends RefCounted
## .vrm / .glb 파일을 게임 실행 중에 불러온다.
## 에디터 플러그인은 에디터 안에서만 동작하므로, 실행 중에는 VRM 확장을 직접 등록해야 한다.

const VRM0_EXTENSION := preload("res://addons/vrm/vrm_extension.gd")
const VRM1_EXTENSIONS: Array[Script] = [
	preload("res://addons/vrm/1.0/VRMC_vrm.gd"),
	preload("res://addons/vrm/1.0/VRMC_node_constraint.gd"),
	preload("res://addons/vrm/1.0/VRMC_springBone.gd"),
	preload("res://addons/vrm/1.0/VRMC_materials_hdr_emissiveMultiplier.gd"),
	preload("res://addons/vrm/1.0/VRMC_materials_mtoon.gd"),
]

## EditorSceneFormatImporter.IMPORT_GENERATE_TANGENT_ARRAYS. 실행 빌드에는 그 클래스가 없어서 숫자로 적는다.
const IMPORT_GENERATE_TANGENT_ARRAYS := 8

const SUPPORTED_EXTENSIONS: PackedStringArray = ["vrm", "glb"]


static func load_model(path: String) -> Node3D:
	var gltf := GLTFDocument.new()
	var extensions: Array[GLTFDocumentExtension] = [VRM0_EXTENSION.new()]
	for script in VRM1_EXTENSIONS:
		extensions.append(script.new())
	for extension in extensions:
		gltf.register_gltf_document_extension(extension, true)

	var state := GLTFState.new()
	state.handle_binary_image = GLTFState.HANDLE_BINARY_EMBED_AS_UNCOMPRESSED
	var err := gltf.append_from_file(ProjectSettings.globalize_path(path), state, IMPORT_GENERATE_TANGENT_ARRAYS)
	var scene: Node3D = null
	if err == OK:
		scene = gltf.generate_scene(state) as Node3D
	else:
		push_error("모델을 읽지 못했어: %s (%s)" % [path, error_string(err)])

	for extension in extensions:
		gltf.unregister_gltf_document_extension(extension)
	return scene


## 폴더 아래의 모델 파일을 하위 폴더까지 전부 찾는다.
static func find_models(root: String) -> PackedStringArray:
	var found := PackedStringArray()
	var dir := DirAccess.open(root)
	if dir == null:
		return found
	for sub in dir.get_directories():
		found.append_array(find_models(root.path_join(sub)))
	for file in dir.get_files():
		if file.get_extension().to_lower() in SUPPORTED_EXTENSIONS:
			found.append(root.path_join(file))
	return found
