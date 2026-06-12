import SwiftUI

/// 퀵 액션 확인 다이얼로그 모델 (실기 UI 결함 fix, 2026-06-12 · UX 리디자인 2026-06-13).
///
/// 종전 `.alert(message: Text(action.command))` 는 수백 줄 스크립트(demoBuildPatched 등)를
/// 본문에 그대로 노출 → 다이얼로그가 화면 세로를 넘어 실행/취소 버튼이 잘려 클릭 불가
/// (실기 브링업 중 앱 채널 배포 불능 — SSH 폴백으로 우회했던 결함). 표시 계약:
///   - 다이얼로그 본문(타이틀/디테일/요약)에 스크립트 전문을 절대 넣지 않는다.
///   - 전문은 "명령 보기" 접기(고정 최대 높이 ScrollView, monospaced)로 분리.
///   - destructive 의미는 danger 카테고리만 (빌드류는 파괴적 아님).
///   - 제목은 질문형("~할까요?"), 실행 버튼은 액션 전용 동사("재부팅" 등) —
///     "확인" 같은 무의미 동사로 무엇이 실행되는지 가리지 않는다.
struct QuickActionConfirmModel {
    let action: QuickAction
    /// 확인 시점의 동적 컨텍스트 1행 — 예: "현재: SSH 연결됨 · 보행 모드".
    /// 시트는 stateless 유지(레이아웃 테스트 보존) — 호출자가 주입.
    var contextLine: String?

    init(action: QuickAction, contextLine: String? = nil) {
        self.action = action
        self.contextLine = contextLine
    }

    var title: String { action.confirmTitle ?? "\(action.label) — 실행할까요?" }
    var detailText: String { action.detail }
    /// 실행 버튼 동사 — 무엇이 일어나는지 버튼만 봐도 알게.
    var runVerb: String { action.confirmVerb ?? "실행" }

    /// 영향 요약 — 액션 지정(`confirmSummary`) 우선, 없으면 카테고리 기본 문구.
    var summaryText: String {
        if let s = action.confirmSummary { return s }
        switch action.category {
        case .danger:  return "되돌리기 어려운 동작입니다 — 로봇 상태를 확인하고 실행하세요."
        case .robotis: return "로봇에서 빌드/재시작이 일어날 수 있어요 — 약 1~2분."
        case .service: return "로봇 서비스 구성이 변경됩니다."
        case .system, .bus: return "로봇에서 명령이 실행됩니다."
        }
    }

    var isDestructive: Bool { action.category == .danger }
    /// danger 는 1.5초 홀드 버튼(T3) — 떨리는 손의 더블클릭으로 발화 불가.
    var requiresHold: Bool { action.confirmTier == .hold }

    /// 회귀 가드용 — 다이얼로그 *본문*에 들어가는 전체 텍스트(명령 전문 비포함 계약).
    var dialogBodyText: String { [title, detailText, summaryText].joined(separator: "\n") }
}

/// 확인 시트 — 어떤 명령 길이에서도 실행/취소 버튼이 잘리지 않는 고정 폭/상한 레이아웃.
struct QuickActionConfirmSheet: View {
    let model: QuickActionConfirmModel
    let onRun: () -> Void
    let onCancel: () -> Void

    @State private var showCommand = false

    var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.md) {
            HStack(spacing: DFSpace.sm) {
                Image(systemName: model.action.icon)
                    .font(.system(size: DFFontSize.s16, weight: .semibold))
                    .foregroundStyle(model.action.category.tint)
                VStack(alignment: .leading, spacing: DFSpace.micro2) {
                    Text(model.title).font(DFFont.bodyEmph)
                    Text(model.detailText)
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary)
                }
                Spacer(minLength: 0)
            }

            Text(model.summaryText)
                .font(DFFont.body)
                .foregroundStyle(DFColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // T3 컨텍스트 — 실행 직전, 지금 로봇이 어떤 상태인지 한 줄(기획 5.3).
            if let ctx = model.contextLine {
                Label(ctx, systemImage: "dot.radiowaves.left.and.right")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }

            // 스크립트 전문은 접기 안으로 — 고정 최대 높이라 버튼이 절대 밀려나지 않는다.
            // (DisclosureGroup 대신 명시 버튼: macOS 기본 디스클로저는 삼각형만 클릭
            //  영역이라 라벨 클릭이 무시된다 — 전행 클릭 가능하게.)
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showCommand.toggle() }
            } label: {
                HStack(spacing: DFSpace.xs) {
                    Image(systemName: showCommand ? "chevron.down" : "chevron.right")
                        .font(.system(size: DFFontSize.s9, weight: .bold))
                    Label("명령 보기", systemImage: "chevron.left.forwardslash.chevron.right")
                        .font(DFFont.caption)
                }
                .foregroundStyle(DFColor.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showCommand {
                ScrollView {
                    Text(model.action.command)
                        .font(.system(size: DFFontSize.s11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DFSpace.sm)
                }
                .frame(maxHeight: 240)
                .background(DFColor.canvas)
                .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
            }

            HStack(spacing: DFSpace.sm) {
                Spacer()
                DFButton(.ghost, size: .medium, action: onCancel) { Text("취소") }
                    .keyboardShortcut(.cancelAction)
                // 의도적으로 .defaultAction(Return) 단축키 없음 — 원격 스크립트 실행
                // 확인은 명시 클릭만 허용(암묵 실행 경로 제거).
                if model.requiresHold {
                    HoldToConfirmButton(label: model.runVerb, action: onRun)
                } else {
                    DFButton(model.isDestructive ? .danger : .primary, size: .medium,
                             action: onRun) { Text(model.runVerb) }
                }
            }
        }
        .padding(DFSpace.lg)
        .frame(width: 460)
        .background(DFColor.card)
    }
}

/// T3 홀드 확인 버튼 — 1.5초 누르고 있어야 발화(기획 5.1).
///
/// 진행 표시: 좌→우 danger 채움. 중도에 떼면 리셋. 클릭(짧은 누름)은 흔들림
/// 애니메이션 없이 그냥 무시 — 마찰 자체가 메시지다.
struct HoldToConfirmButton: View {
    let label: String
    let action: () -> Void

    static let holdDuration: TimeInterval = 1.5

    @State private var pressing = false
    @State private var fired = false

    var body: some View {
        Text("길게 눌러 \(label)")
            .font(DFFont.bodyEmph)
            .foregroundStyle(.white)
            .padding(.horizontal, DFSpace.md)
            .frame(height: DFSize.buttonHMedium)
            .background(
                ZStack(alignment: .leading) {
                    DFColor.danger.opacity(DFOpacity.o30)
                    GeometryReader { geo in
                        Rectangle()
                            .fill(DFColor.danger)
                            .frame(width: pressing ? geo.size.width : 0)
                            .animation(pressing
                                       ? .linear(duration: Self.holdDuration)
                                       : .easeOut(duration: 0.15),
                                       value: pressing)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.button))
            .contentShape(RoundedRectangle(cornerRadius: DFRadius.button))
            .onLongPressGesture(minimumDuration: Self.holdDuration) {
                guard !fired else { return }
                fired = true
                action()
            } onPressingChanged: { isPressing in
                pressing = isPressing
            }
            .help("실수 방지 — \(Int(Self.holdDuration * 1000))ms 동안 누르고 있어야 실행됩니다")
            .accessibilityLabel("\(label) — 길게 눌러 실행")
    }
}
