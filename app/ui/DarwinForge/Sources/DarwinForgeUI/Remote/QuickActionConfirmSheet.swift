import SwiftUI

/// 퀵 액션 확인 다이얼로그 모델 (실기 UI 결함 fix, 2026-06-12).
///
/// 종전 `.alert(message: Text(action.command))` 는 수백 줄 스크립트(demoBuildPatched 등)를
/// 본문에 그대로 노출 → 다이얼로그가 화면 세로를 넘어 실행/취소 버튼이 잘려 클릭 불가
/// (실기 브링업 중 앱 채널 배포 불능 — SSH 폴백으로 우회했던 결함). 표시 계약:
///   - 다이얼로그 본문(타이틀/디테일/요약)에 스크립트 전문을 절대 넣지 않는다.
///   - 전문은 "명령 보기" 접기(고정 최대 높이 ScrollView, monospaced)로 분리.
///   - destructive 의미는 danger 카테고리만 (빌드류는 파괴적 아님).
struct QuickActionConfirmModel {
    let action: QuickAction

    var title: String { "\(action.label) 실행?" }
    var detailText: String { action.detail }

    /// 영향 요약 한 줄 — 액션 지정(`confirmSummary`) 우선, 없으면 카테고리 기본 문구.
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
                DFButton(model.isDestructive ? .danger : .primary, size: .medium,
                         action: onRun) { Text("실행") }
            }
        }
        .padding(DFSpace.lg)
        .frame(width: 460)
        .background(DFColor.card)
    }
}
