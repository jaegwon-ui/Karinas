# Karinas

4인 협동 서브컬처 게임 실험 프로젝트 (Godot 4.7, 비상업).

## 지금 들어 있는 것

- `pixel_lab/`: 도트 룩 실험실. VRM 캐릭터를 저해상도로 렌더링하고 외곽선을 입혀 도트처럼 만든다.
- `characters/samples/`: CC0 샘플 모델 (라이선스는 폴더 안 `LICENSE.md`)
- `addons/vrm`, `addons/Godot-MToon-Shader`: [V-Sekai/godot-vrm](https://github.com/V-Sekai/godot-vrm) (MIT, commit e15199f)
- `assets/fonts/Galmuri11.woff2`: [갈무리](https://github.com/quiple/galmuri) 폰트 (OFL 1.1)

## 알려진 문제

- 실험실 조작판의 글자가 표시되지 않음 (폰트 복제 코드 버그)
- 동작(공격 등)은 코드로 만든 임시 포즈라 어색함

## 명령줄로 캡처하기

```
# 방향별 이미지와 스프라이트 시트
godot --path . -- --capture=저장폴더

# GIF용 연속 프레임 (초당 50장, 머리카락 흔들림까지 일정하게)
godot --path . --fixed-fps 50 -- --sequence=저장폴더 --motion=idle --px=128 --yaw=35 [--spin] [--loops=2]
```

`--motion` 은 `stand`, `idle`, `battle_idle`, `attack` 중 하나.
