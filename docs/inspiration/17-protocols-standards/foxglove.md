# Foxglove (구 Foxglove Studio) — 로봇 데이터 시각화

## 한 줄 소개

ROS / ROS2 / mcap / bag 파일 시각화 + 라이브 스트리밍 도구. RViz의 모던 후속.

## 핵심 정보

| 항목 | 내용 |
|------|------|
| 회사 | Foxglove (Y Combinator W22) |
| 라이선스 | MPL 2.0 (오픈) + 상용 |
| 플랫폼 | Web / Electron (Mac / Linux / Windows) |
| 통신 | WebSocket / ROS bridge / mcap files |
| 데이터 포맷 | **mcap** (자체) — bag 후속 |

## DarwinForge 적용 ★★

### 시나리오 — 트레이스 시각화

DarwinForge가 mcap 파일로 IMU + 관절 상태 + 명령 트레이스를 export →
Foxglove로 열어 분석.

```rust
// app/core/forge-core/src/recorder.rs (신규 후보)
pub struct TraceRecorder {
    writer: McapWriter,
}

impl TraceRecorder {
    pub fn record_joint_state(&mut self, t: Duration, state: &JointState) {
        // mcap 토픽 /darwin/joint_states 에 protobuf 저장
    }
}
```

→ `forge record --port ... --output trace.mcap` CLI 명령.
→ Foxglove에서 "Open File" → trace.mcap → 3D 자세 + plot 시각화.

장점:
- 표준 포맷 → 다른 사용자와 공유 쉬움
- 학술 발표 / 디버깅에 표준
- Web 기반이라 macOS / Linux / Windows 어디서든

## Foxglove WebSocket 라이브

DarwinForge가 WebSocket 서버 띄우면 Foxglove가 실시간 시각화. 별도 시각화
앱 만들 필요 없음.

→ `forge serve --port ... --foxglove-ws 8765` 같은 명령.
→ Foxglove에서 `ws://localhost:8765` 연결.

## 차용 우선순위

★★ — 트레이스 분석 기능 추가 시 1순위. Sprint 12+ 후보.

## 출처

- Foxglove: https://foxglove.dev/
- mcap 포맷: https://mcap.dev/
- Foxglove GitHub: https://github.com/foxglove/studio
