import ForgeCore
import SwiftUI

/// 2026-05-17: MotionStudio 의 동작들을 의미별 그룹핑.
///
/// 자동 분류 — id range / name pattern 기반. `MotionPage` 자체를 수정하지 않고
/// helper 로 추론 → 기존 도큐먼트 호환성 유지.
///
/// **ID 매핑 규약 (StarterMotionLibrary.starterDoc 와 일치 — 사이클 246)**:
/// - 1..=54: ROBOTIS 공식 motion_4096.bin catalog → `.official`
/// - 110..=119: ReferenceMotionLibrary walk progression → `.walking`
/// - 120..=129: ergonomic → `.daily`
/// - 130..=139: greetings → `.greeting`
/// - 140..=149: social → `.greeting`
/// - 200..=204: prebundled (idle/tPose/bow/wave/sit) → `.basic`
/// - 220..=: libraryStarterPages — name pattern 으로 세분류
/// - 그 외: `.custom` (사용자 작성)
public enum MotionStudioCategory: String, CaseIterable, Identifiable, Hashable {
    case basic       // 기본 동작 (idle, tPose, walkReady)
    case greeting    // 인사 / 사회
    case expression  // 감정 표현
    case dance       // 댄스
    case sport       // 운동 / 스포츠
    case combat      // 격투 / 방어
    case daily       // 일상 / ergonomic
    case yoga        // 요가 / 밸런스
    case walking     // 보행 테스트
    case official    // ROBOTIS 공식 catalog
    case custom      // 사용자 작성

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .basic:      return "기본"
        case .greeting:   return "인사"
        case .expression: return "감정"
        case .dance:      return "댄스"
        case .sport:      return "운동"
        case .combat:     return "격투"
        case .daily:      return "일상"
        case .yoga:       return "요가"
        case .walking:    return "보행 테스트"
        case .official:   return "ROBOTIS 공식"
        case .custom:     return "사용자"
        }
    }

    /// SF Symbol icon — sidebar Section header 용.
    public var icon: String {
        switch self {
        case .basic:      return "figure.stand"
        case .greeting:   return "hand.wave.fill"
        case .expression: return "face.smiling"
        case .dance:      return "music.note"
        case .sport:      return "figure.run"
        case .combat:     return "figure.boxing"
        case .daily:      return "figure.walk"
        case .yoga:       return "figure.mind.and.body"
        case .walking:    return "figure.walk.motion"
        case .official:   return "shippingbox.fill"
        case .custom:     return "person.fill"
        }
    }

    /// 표시 순서 — sidebar 에서 위에서 아래로.
    public var sortOrder: Int {
        switch self {
        case .basic:      return 0
        case .official:   return 1
        case .greeting:   return 2
        case .expression: return 3
        case .dance:      return 4
        case .sport:      return 5
        case .combat:     return 6
        case .yoga:       return 7
        case .daily:      return 8
        case .walking:    return 9
        case .custom:     return 10
        }
    }

    /// MotionPage 의 id / name 으로부터 자동 분류.
    /// `starterDoc` 의 ID 매핑 + name keyword 기반.
    public static func categorize(_ page: MotionPage) -> MotionStudioCategory {
        // ID 매핑 우선 — 명확한 source 기반.
        if (1...54).contains(page.id)    { return .official }
        if (110...119).contains(page.id) { return .walking }
        if (120...129).contains(page.id) { return .daily }
        if (130...139).contains(page.id) { return .greeting }
        if (140...149).contains(page.id) { return .greeting }
        if (200...204).contains(page.id) { return .basic }

        // ID 220+ 또는 그 외 — name 으로 세분류.
        let name = page.name
        // 격투 키워드
        if name.contains("펀치") || name.contains("콤보") || name.contains("복싱")
            || name.contains("어퍼컷") || name.contains("가드") || name.contains("방어") {
            return .combat
        }
        // 인사 키워드
        if name.contains("인사") || name.contains("악수") || name.contains("경례")
            || name.contains("손 흔들") || name.contains("박수") || name.contains("만세")
            || name.contains("환영") {
            return .greeting
        }
        // 감정 / 표정
        if name.contains("환호") || name.contains("좌절") || name.contains("생각")
            || name.contains("놀람") || name.contains("부끄") || name.contains("기쁨")
            || name.contains("슬픔") || name.contains("두리번") || name.contains("끄덕")
            || name.contains("표현") {
            return .expression
        }
        // 댄스
        if name.contains("댄스") || name.contains("말춤") || name.contains("강남")
            || name.contains("힙합") || name.contains("리듬") || name.contains("로봇 댄스") {
            return .dance
        }
        // 요가
        if name.contains("요가") || name.contains("나무 자세") || name.contains("전사")
            || name.contains("산 자세") || name.contains("호흡") || name.contains("명상") {
            return .yoga
        }
        // 축구 / 스포츠
        if name.contains("축구") || name.contains("발차기") || name.contains("골키퍼")
            || name.contains("스로인") || name.contains("드리블") || name.contains("패스") {
            return .sport
        }
        // 일상 / 운동
        if name.contains("스쿼트") || name.contains("스트레칭") || name.contains("앉기")
            || name.contains("일어서") || name.contains("기도") || name.contains("합장")
            || name.contains("의자") || name.contains("lunge") || name.contains("런지")
            || name.contains("가리키") {
            return .daily
        }
        // 매칭 없음 — 사용자 작성으로 추정.
        return .custom
    }
}
