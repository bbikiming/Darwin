import SwiftUI

/// **v1.11.23 (2026-05-21)** — 상태 표시 표준 컴포넌트.
///
/// macOS HIG + Apple Design 가이드 정합:
/// - 로딩 / 에러 / 인라인 알림 시각 일관성
/// - `DFEmptyState` (기존) 와 동일 디자인 언어
/// - Reduce Motion / a11y 자동 대응

// MARK: - DFLoadingState

/// 로딩 상태 — full view 채움. ProgressView + 메시지 + 부가 hint.
public struct DFLoadingState: View {
    public let title: String
    public let message: String?
    public let tint: Color

    public init(title: String = "로딩 중…",
                message: String? = nil,
                tint: Color = DFColor.accent) {
        self.title = title
        self.message = message
        self.tint = tint
    }

    public var body: some View {
        VStack(spacing: DFSpace.md) {
            ProgressView()
                .controlSize(.large)
                .tint(tint)
            VStack(spacing: 4) {
                Text(title)
                    .font(DFFont.title)
                    .foregroundStyle(DFColor.textPrimary)
                if let message {
                    Text(message)
                        .font(DFFont.body)
                        .foregroundStyle(DFColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DFSpace.lg)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(message ?? "")")
    }
}

// MARK: - DFErrorState

/// 에러 상태 — full view 채움. icon + title + detail + retry action (optional).
public struct DFErrorState<Action: View>: View {
    public let title: String
    public let detail: String
    public let icon: String
    @ViewBuilder public let action: () -> Action

    public init(title: String = "오류가 발생했습니다",
                detail: String,
                icon: String = "exclamationmark.triangle.fill",
                @ViewBuilder action: @escaping () -> Action = { EmptyView() }) {
        self.title = title
        self.detail = detail
        self.icon = icon
        self.action = action
    }

    public var body: some View {
        VStack(spacing: DFSpace.md) {
            // v1.11.23 (Codex MED fix): a11y combine 을 icon+title+detail 그룹에만 적용.
            // action button 은 별도 a11y 노출 — VoiceOver 가 "오류 상태" + "재시도 버튼"
            // 으로 분리 인식. 종전: parent combine 이 button focus 까지 흡수.
            VStack(spacing: DFSpace.md) {
                ZStack {
                    Circle().fill(DFColor.danger.opacity(DFOpacity.ghost))
                        .frame(width: 72, height: 72)
                    Image(systemName: icon)
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(DFColor.danger)
                }
                VStack(spacing: 4) {
                    Text(title)
                        .font(DFFont.title)
                        .foregroundStyle(DFColor.textPrimary)
                    Text(detail)
                        .font(DFFont.body)
                        .foregroundStyle(DFColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 360)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("오류: \(title). \(detail)")
            // action button 은 a11y 별도 — 사용자가 VoiceOver 로 focus 이동 가능.
            action()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DFSpace.lg)
    }
}

// MARK: - DFInlineMessage

/// 인라인 알림 — section 안에 inline 으로 표시되는 메시지.
/// info / success / warning / danger 4가지 톤.
public struct DFInlineMessage: View {
    public enum Tone {
        case info, success, warning, danger

        var icon: String {
            switch self {
            case .info:    return "info.circle.fill"
            case .success: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .danger:  return "xmark.octagon.fill"
            }
        }

        var color: Color {
            switch self {
            case .info:    return DFColor.info
            case .success: return DFColor.success
            case .warning: return DFColor.warning
            case .danger:  return DFColor.danger
            }
        }

        var voiceOverPrefix: String {
            switch self {
            case .info:    return "안내"
            case .success: return "성공"
            case .warning: return "경고"
            case .danger:  return "오류"
            }
        }
    }

    public let tone: Tone
    public let title: String
    public let detail: String?

    public init(tone: Tone, title: String, detail: String? = nil) {
        self.tone = tone
        self.title = title
        self.detail = detail
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DFSpace.sm) {
            Image(systemName: tone.icon)
                .font(.system(size: DFFontSize.s14, weight: .semibold))
                .foregroundStyle(tone.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DFFont.bodyEmph)
                    .foregroundStyle(DFColor.textPrimary)
                if let detail {
                    Text(detail)
                        .font(DFFont.label)
                        .foregroundStyle(DFColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DFSpace.sm2)
        .background(tone.color.opacity(DFOpacity.o10))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.sm)
                .stroke(tone.color.opacity(DFOpacity.o30), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tone.voiceOverPrefix): \(title). \(detail ?? "")")
    }
}

#if DEBUG
#Preview("Loading") {
    DFLoadingState(title: "연결 중…", message: "로봇과 통신을 시도하고 있습니다.")
        .frame(width: 480, height: 320)
}

#Preview("Error with retry") {
    DFErrorState(
        title: "연결 실패",
        detail: "192.168.123.1:5530 에 도달할 수 없습니다. 이더넷 케이블을 확인해 주세요."
    ) {
        Button("다시 시도") {}
            .buttonStyle(.borderedProminent)
    }
    .frame(width: 480, height: 320)
}

#Preview("Inline messages") {
    VStack(spacing: 12) {
        DFInlineMessage(tone: .info, title: "안내", detail: "거치대를 확인하세요.")
        DFInlineMessage(tone: .success, title: "보정 ON", detail: "1초 ramp 시작.")
        DFInlineMessage(tone: .warning, title: "기울기 35°+", detail: "보행 속도 70% 자동 감속.")
        DFInlineMessage(tone: .danger, title: "토크 OFF", detail: "비상 정지 완료. 복구 절차 진행.")
    }
    .padding()
    .frame(width: 460)
}
#endif
