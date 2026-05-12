# Godot Engine — 가벼운 오픈소스 게임 엔진

## 한 줄 소개

MIT 오픈 소스 게임 엔진. 가볍고 빠른 학습. 휴머노이드 시뮬은 Unity/UE5
대비 약하지만, **DarwinForge의 보조 시각화 도구**로 후보.

## 핵심 정보

| 항목 | 내용 |
|------|------|
| 라이선스 | MIT |
| 플랫폼 | macOS Apple Silicon 네이티브 |
| 언어 | GDScript (Python 유사) + C# 옵션 |
| 강점 | 가벼움 (~50 MB), 빠름, 풀 오픈소스 |
| 약점 | 휴머노이드 RL 생태계 약함 |

## 우리 가능성

URDF → Godot 변환 도구 미존재 (확인 필요). 직접 작성 필요.

DarwinForge가 Godot로 3D 시각화를 outsource 한다면:
- DarwinForge.app → JSON-RPC → Godot.app (3D 자세 표시)
- 2-app 구조라 복잡 — SceneKit이 더 단순.

## 차용 우선순위

★ — 6순위. SceneKit이 macOS 네이티브에 더 적합.

## 출처

- Godot: https://godotengine.org/
- Godot 4.x: https://godotengine.org/article/godot-4-0/
