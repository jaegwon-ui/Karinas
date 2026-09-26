# 도트 작업 파일

## knight_paintover.aseprite

3D로 렌더링한 여기사를 밑그림으로 깔아둔 Aseprite 파일이야. 이 위에 직접 도트를 찍으면 돼.

| 레이어 | 설명 |
|---|---|
| 도트 | 여기에 최종 도트를 찍어 |
| 스케치 | 대충 잡는 선이나 덩어리용 |
| 3D 가이드 | 렌더한 밑그림. 잠겨 있고 43% 투명도. 레이어를 더블클릭하면 투명도를 바꿀 수 있어 |

- 태그: `전투대기` 8프레임(0.2초씩), `공격` 10프레임(0.1초씩)
- 캔버스 120×120, 캐릭터 키 약 96px
- 팔레트가 파일 안에 들어 있어. 다른 파일에서 쓰려면 `palettes/karinas_knight.gpl`을 불러오면 돼

### 추천 순서

1. 키 포즈부터: 전투대기 1번, 공격 4~6번처럼 동작의 핵심 장면만 먼저
2. 실루엣을 한 색으로 채워서 모양이 읽히는지 보기
3. 명암을 큰 덩어리로 (한 부위에 3~4색)
4. 외곽선은 필요한 곳에만 (머리, 망토 끝처럼 배경과 섞이는 곳)
5. 사이 프레임은 마지막에. 어니언 스킨(F3)을 켜면 앞뒤 프레임이 비쳐 보여

가이드는 참고용이야. 포즈를 더 과장하거나 프레임을 빼도 괜찮아.

### 스프라이트 시트로 내보내기

`File > Export Sprite Sheet`, 또는 명령줄로:

```
aseprite -b art/knight_paintover.aseprite --layer "도트" --sheet knight_sheet.png --data knight_sheet.json --format json-array
```

### 가이드 다시 만들기

```
godot --path . --fixed-fps 50 -- --sequence=/tmp/battle --motion=battle_idle --px=96 --yaw=35 --dnf
godot --path . --fixed-fps 50 -- --sequence=/tmp/attack --motion=attack --px=96 --yaw=35 --dnf
python3 tools/aseprite_starter.py --out art/knight_paintover.aseprite \
    --tag 전투대기:/tmp/battle:10:200 --tag 공격:/tmp/attack:5:100 \
    --palette-out art/palettes/karinas_knight.gpl
```
