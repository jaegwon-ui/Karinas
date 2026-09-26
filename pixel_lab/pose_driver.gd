class_name PoseDriver
extends RefCounted
## VRM 휴머노이드 뼈대에 코드로 만든 간단한 동작을 입힌다.
## 진짜 애니메이션(Mixamo 등)을 붙이기 전까지 도트 느낌을 확인하는 용도다.
##
## 각 뼈의 회전은 "스켈레톤 기준 축"의 오일러 각(도)으로 적는다.
## 캐릭터는 +Z(카메라 쪽)를 보고, 캐릭터의 왼쪽이 +X다.
## 오른쪽 뼈는 왼쪽 값을 좌우 반전해서 쓴다.

enum Motion { STAND, IDLE, BATTLE_IDLE, ATTACK }

const MOTION_LABELS := {
	Motion.STAND: "차렷",
	Motion.IDLE: "숨쉬기 대기",
	Motion.BATTLE_IDLE: "전투 대기",
	Motion.ATTACK: "공격",
}

## 동작 한 바퀴의 길이(초)
const MOTION_PERIOD := {
	Motion.STAND: 1.0,
	Motion.IDLE: 2.4,
	Motion.BATTLE_IDLE: 1.6,
	Motion.ATTACK: 1.0,
}

const HIPS_OFFSET := "_hips_offset"

var skeleton: Skeleton3D
## 손가락을 말아 쥔 주먹 (검을 들 때)
var grip := false
var _leg_length := 0.8


func _init(target: Skeleton3D) -> void:
	skeleton = target
	var upper := skeleton.find_bone("LeftUpperLeg")
	var foot := skeleton.find_bone("LeftFoot")
	if upper >= 0 and foot >= 0:
		_leg_length = skeleton.get_bone_global_rest(upper).origin.distance_to(skeleton.get_bone_global_rest(foot).origin)


func apply(motion: int, time: float) -> void:
	var period: float = MOTION_PERIOD[motion]
	var pose := _sample(_keys(motion), fposmod(time, period) / period)
	if grip:
		_add_fists(pose)
	skeleton.reset_bone_poses()
	for bone_name: String in pose:
		if bone_name == HIPS_OFFSET:
			continue
		_rotate_bone(bone_name, pose[bone_name])
	var hips := skeleton.find_bone("Hips")
	if hips >= 0 and pose.has(HIPS_OFFSET):
		skeleton.set_bone_pose_position(hips, skeleton.get_bone_rest(hips).origin + pose[HIPS_OFFSET])


func _rotate_bone(bone_name: String, degrees: Vector3) -> void:
	var idx := skeleton.find_bone(bone_name)
	if idx < 0:
		return
	var delta := Basis.from_euler(degrees * (PI / 180.0))
	var rest_global := skeleton.get_bone_global_rest(idx).basis.orthonormalized()
	var parent := skeleton.get_bone_parent(idx)
	var parent_rest_global := Basis.IDENTITY
	if parent >= 0:
		parent_rest_global = skeleton.get_bone_global_rest(parent).basis.orthonormalized()
	# 부모가 쉬는 자세일 때를 기준으로 한 상대 회전이라, 자식은 부모 회전을 자동으로 따라간다.
	var local := parent_rest_global.inverse() * delta * rest_global
	skeleton.set_bone_pose_rotation(idx, local.get_rotation_quaternion())


# ---------------------------------------------------------------- 키프레임

## [시각(0~1), 포즈] 목록 사이를 부드럽게 잇는다.
static func _sample(keys: Array, t: float) -> Dictionary:
	if keys.size() == 1:
		return keys[0][1]
	for i in keys.size() - 1:
		var a: Array = keys[i]
		var b: Array = keys[i + 1]
		if t <= b[0]:
			var w := smoothstep(0.0, 1.0, inverse_lerp(a[0], b[0], t))
			return _blend(a[1], b[1], w)
	return keys[-1][1]


static func _blend(a: Dictionary, b: Dictionary, w: float) -> Dictionary:
	var out := {}
	for key in a:
		out[key] = a[key].lerp(b.get(key, Vector3.ZERO), w)
	for key in b:
		if not out.has(key):
			out[key] = Vector3.ZERO.lerp(b[key], w)
	return out


## 왼쪽 기준 값을 받아 양쪽 뼈 모두에 넣는다.
static func _both(pose: Dictionary, part: String, left: Vector3) -> void:
	pose["Left" + part] = left
	pose["Right" + part] = Vector3(left.x, -left.y, -left.z)


static func _merge(base: Dictionary, extra: Dictionary) -> Dictionary:
	var out := base.duplicate()
	out.merge(extra, true)
	return out


## 팔을 내린 기본 자세. VRM은 T자로 팔을 벌리고 있어서 이게 없으면 허수아비가 된다.
static func _arms_down(spread := 0.0, elbow := 12.0) -> Dictionary:
	var pose := {}
	_both(pose, "UpperArm", Vector3(0, -6, -72 + spread))
	_both(pose, "LowerArm", Vector3(0, -elbow, 0))
	_both(pose, "Hand", Vector3(0, 0, -6))
	return pose


## 손바닥이 아래를 보는 T자 기준으로, 손가락 마디를 아래(-Y)로 만다.
static func _add_fists(pose: Dictionary) -> void:
	for finger in ["Index", "Middle", "Ring", "Little"]:
		for joint: String in ["Proximal", "Intermediate", "Distal"]:
			_both(pose, finger + joint, Vector3(0, 0, -75 if joint == "Proximal" else -80))
	_both(pose, "ThumbProximal", Vector3(0, -25, -20))
	_both(pose, "ThumbDistal", Vector3(0, -20, -30))


## 무릎을 굽히면 골반을 내려서 발이 바닥에 붙어 있게 한다.
func _knees(pose: Dictionary, bend: float) -> void:
	_both(pose, "UpperLeg", Vector3(-bend * 0.5, 0, 0))
	_both(pose, "LowerLeg", Vector3(bend, 0, 0))
	_both(pose, "Foot", Vector3(-bend * 0.5, 0, 0))
	var drop := _leg_length * (1.0 - cos(deg_to_rad(bend * 0.5)))
	pose[HIPS_OFFSET] = Vector3(0, -drop, 0)


func _keys(motion: int) -> Array:
	match motion:
		Motion.IDLE:
			var inhale := _merge(_arms_down(), {
				"Chest": Vector3(-2.0, 0, 0),
				"UpperChest": Vector3(-1.5, 0, 0),
				"Head": Vector3(1.5, 0, 1.0),
				"LeftShoulder": Vector3(0, 0, 2.0),
				"RightShoulder": Vector3(0, 0, -2.0),
			})
			var exhale := _merge(_arms_down(2.0, 16.0), {
				"Chest": Vector3(1.0, 0, 0),
				"Head": Vector3(-1.0, 0, -1.0),
				HIPS_OFFSET: Vector3(0, -0.004, 0),
			})
			return [[0.0, exhale], [0.5, inhale], [1.0, exhale]]

		Motion.BATTLE_IDLE:
			var keys := []
			for phase in [0.0, 0.5, 1.0]:
				var sink := 0.0 if phase == 0.5 else 1.0
				var pose := {
					"Hips": Vector3(0, 28, 0),
					"Spine": Vector3(4 + 2 * sink, -10, 0),
					"Chest": Vector3(2, -8, 0),
					"Head": Vector3(-4, -12, 0),
					"LeftUpperLeg": Vector3(-14, 0, 8),
					"RightUpperLeg": Vector3(8, 0, -8),
					# 오른팔: 무기를 앞으로 겨눈 자세
					"RightUpperArm": Vector3(0, 55, 55),
					"RightLowerArm": Vector3(0, 55, 0),
					"RightHand": Vector3(0, 0, 10),
					# 왼팔: 몸 앞으로 살짝 들어 균형
					"LeftUpperArm": Vector3(0, -30, -60),
					"LeftLowerArm": Vector3(0, -50, 0),
				}
				_knees(pose, 18.0 + 6.0 * sink)
				keys.append([phase, pose])
			return keys

		Motion.ATTACK:
			var guard: Dictionary = _keys(Motion.BATTLE_IDLE)[0][1]
			var windup := _merge(guard, {
				"Hips": Vector3(0, 45, 0),
				"Spine": Vector3(-4, 15, 0),
				"Chest": Vector3(-4, 10, 0),
				"RightUpperArm": Vector3(0, -20, -60),
				"RightLowerArm": Vector3(0, 70, 0),
			})
			var strike := _merge(guard, {
				"Hips": Vector3(0, 5, 0),
				"Spine": Vector3(12, -25, 0),
				"Chest": Vector3(8, -15, 0),
				"Head": Vector3(-6, -5, 0),
				"RightUpperArm": Vector3(0, 80, 20),
				"RightLowerArm": Vector3(0, 5, 0),
				"LeftUpperArm": Vector3(0, 20, -75),
			})
			_knees(strike, 34.0)
			return [[0.0, guard], [0.35, windup], [0.5, strike], [0.7, strike], [1.0, guard]]

	return [[0.0, _arms_down()]]
