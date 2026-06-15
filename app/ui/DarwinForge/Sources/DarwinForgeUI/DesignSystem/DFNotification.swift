import SwiftUI

/// 사이클 V279-3 (V278-1 권고) — Notification taxonomy (IBM Carbon 4-step).
///
/// # 비유
///
/// 카페의 알림 종류:
/// - Toast: 손님이 카운터에서 받는 영수증 — 잠깐 보고 사라짐
/// - Inline: 메뉴판의 "오늘의 추천" 옆 작은 표시 — context 안
/// - Banner: 카페 입구의 안내문 — 화면 상단 / 영역 전체
/// - Modal: 카드 결제 페이지 — 사용자 응답 강제 (overlay)
///
/// IBM Carbon Notification taxonomy:
/// https://carbondesignsystem.com/components/notification
///
/// # 4 type
///
/// 1. **Toast** — 일시적 (3-5초 후 자동 사라짐). 비차단. 예: "저장됐어요"
/// 2. **Inline** — view 안 context 위치. 비차단. 예: form 필드 옆 "유효하지 않은 IP 주소"
/// 3. **Banner** — view 전체 상단/하단. 비차단 또는 dismiss 가능. 예: "robot 연결 끊김 — 재연결 중"
/// 4. **Modal** — overlay sheet/alert. 차단 (사용자 응답 필요). 예: "정말 emergency stop 하시겠습니까?"
///
/// Modal 은 SwiftUI native `.alert` / `.confirmationDialog` 사용 권고
/// (별도 wrapper 불필요).
public enum DFNotification {

    /// Severity (KoreanUX.Tone 과 연동).
    ///
    /// 색상은 DFColor token 만 사용 — 직접 hex 금지.
    public enum Severity {
        case success, info, warning, error, critical

        /// 의미 색상 — DFColor semantic palette 매핑.
        public var color: Color {
            switch self {
            case .success:  return DFColor.success
            case .info:     return DFColor.info
            case .warning:  return DFColor.warning
            case .error:    return DFColor.danger
            case .critical: return DFColor.severe
            }
        }

        /// SF Symbol 이름 — Apple HIG 의미론.
        public var iconName: String {
            switch self {
            case .success:  return "checkmark.circle.fill"
            case .info:     return "info.circle.fill"
            case .warning:  return "exclamationmark.triangle.fill"
            case .error:    return "xmark.octagon.fill"
            case .critical: return "exclamationmark.octagon.fill"
            }
        }
    }
}

// MARK: - Toast (일시적, 비차단)

/// Toast — 일시적 알림. ZStack overlay 권고.
///
/// # 비유
///
/// 영수증 — 카운터에서 받아 잠깐 보고 휴지통에 버린다.
/// 사용자 동작을 방해하지 않고 3-5초 후 자동 사라짐.
///
/// # 사용
///
/// ```swift
/// .overlay(alignment: .top) {
///     DFToast(title: "저장됐어요", severity: .success)
/// }
/// ```
public struct DFToast: View {
    public let title: String
    public let severity: DFNotification.Severity

    public init(title: String, severity: DFNotification.Severity = .info) {
        self.title = title
        self.severity = severity
    }

    public var body: some View {
        HStack(spacing: DFSpace.xs) {
            Image(systemName: severity.iconName)
                .foregroundStyle(severity.color)
            Text(title)
                .font(DFFont.body)
                .foregroundStyle(DFColor.textPrimary)
        }
        .padding(.horizontal, DFSpace.md)
        .padding(.vertical, DFSpace.xs)
        .background(
            RoundedRectangle(cornerRadius: DFRadius.md)
                .fill(.regularMaterial)
                .shadow(radius: 4, y: 2)
        )
    }
}

// MARK: - Inline (context 안, 비차단)

/// Inline — context 안 알림. 행/필드 옆 표시.
///
/// # 비유
///
/// 메뉴판의 "오늘의 추천" 별표 — 메뉴 안에 자연스레 녹아 있음.
/// form 필드 / 행 / 카드 옆에 caption 크기로 표시.
///
/// # 사용
///
/// ```swift
/// VStack {
///     TextField("IP", text: $ip)
///     DFInlineNotice(title: "유효하지 않은 IP 형식", severity: .error)
/// }
/// ```
public struct DFInlineNotice: View {
    public let title: String
    public let severity: DFNotification.Severity

    public init(title: String, severity: DFNotification.Severity = .info) {
        self.title = title
        self.severity = severity
    }

    public var body: some View {
        HStack(spacing: DFSpace.xs2) {
            Image(systemName: severity.iconName)
                .font(DFFont.caption)
                .foregroundStyle(severity.color)
            Text(title)
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary)
        }
    }
}

// MARK: - Banner (view 전체, dismiss 가능)

/// Banner — view 전체 영역 알림. dismiss 가능 옵션.
///
/// # 비유
///
/// 카페 입구의 "오늘 휴무" 안내문 — 들어오는 모든 사람이 본다.
/// view 상단 / 하단 전체 폭에 표시. message 와 onDismiss 선택 지원.
///
/// # 사용
///
/// ```swift
/// VStack {
///     DFBanner(
///         title: "로봇 연결이 끊겼어요",
///         message: "USB 케이블을 확인해 주세요",
///         severity: .error,
///         onDismiss: { showBanner = false }
///     )
///     // 나머지 view
/// }
/// ```
public struct DFBanner: View {
    public let title: String
    public let message: String?
    public let severity: DFNotification.Severity
    public let onDismiss: (() -> Void)?

    public init(
        title: String,
        message: String? = nil,
        severity: DFNotification.Severity = .info,
        onDismiss: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.severity = severity
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(alignment: .top, spacing: DFSpace.sm) {
            Image(systemName: severity.iconName)
                .foregroundStyle(severity.color)
            VStack(alignment: .leading, spacing: DFSpace.xs2) {
                Text(title)
                    .font(DFFont.body.weight(.semibold))
                if let message = message {
                    Text(message)
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary)
                }
            }
            Spacer()
            if let onDismiss = onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(DFFont.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("닫기")
            }
        }
        .padding(DFSpace.md)
        .background(
            RoundedRectangle(cornerRadius: DFRadius.sm)
                .fill(severity.color.opacity(0.10))
        )
    }
}
