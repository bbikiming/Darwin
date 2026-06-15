import SwiftUI

/// 사이클 179 (P0 #3.1 fix, cycle 177 audit): Studio 의 connection 상태 → DFStatusBadge
/// 결정 logic + view.
///
/// # 비유
///
/// 식당 의 "이건 진짜 음식 / 시뮬레이션 음식 / 손님 보기 전용" 라벨. 사용자가 자기 행동
/// (슬라이더 / 보내기 button) 의 효과를 한눈에 구분. 이전엔 bus 미연결 시 슬라이더 움직임이
/// 화면에만 반영되는데 아무런 indication 없어 "왜 로봇이 안 움직이지?" 혼란.
///
/// # 4 가지 상태 (MotionStudioView.sourceModeBadge 와 유사하나 더 단순)
///
/// | bus | liveApply | 결정 |
/// |-----|-----------|------|
/// | nil | — | `.simulationOnly` — 슬라이더 움직임이 화면에만 반영 |
/// | 연결 | true | `.appliedToRobot` — 슬라이더 → 즉시 motor |
/// | 연결 | false | nil (보내기 button 만 사용 — 명시 action 있음) |
///
/// 본 helper 는 pure logic — view-less 검증 가능.
public enum StudioConnectionStateBadge {
    /// 본 상태에 해당하는 `DFStatusBadge` 반환. nil = 표시 안 함.
    ///
    /// - Parameters:
    ///   - hasBus: ConnectionStore.bus != nil 여부.
    ///   - liveApply: StudioView 의 liveApply toggle 활성 여부.
    public static func resolve(hasBus: Bool, liveApply: Bool) -> DFStatusBadge? {
        if !hasBus {
            return .simulationOnly
        }
        if liveApply {
            return .appliedToRobot
        }
        return nil
    }
}
