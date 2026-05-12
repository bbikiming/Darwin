import SwiftUI

/// 비활성 컴포넌트 위에 얹는 "준비 중" 오버레이 + 상세 시트 (PRD §4.2 / §3.1).
///
/// 사용:
/// ```swift
/// PilotDpad(...)
///     .comingSoon("v2", title: "실 로봇 보행 조종",
///                 why: "BLOCKER C3 (실 IK) 해결 후 활성",
///                 when: "Sprint 18+",
///                 alternative: "지금: 화면의 발 trail 시뮬레이션 미리보기")
/// ```
public struct ComingSoonOverlay: ViewModifier {
    public let stage: String
    public let title: String
    public let why: String
    public let when: String
    public let alternative: String?

    @State private var showSheet = false

    public func body(content: Content) -> some View {
        ZStack {
            content
                .opacity(DFOpacity.disabled)
                .allowsHitTesting(false)
                .grayscale(0.8)

            VStack(spacing: DFSpace.xs2) {
                Image(systemName: "lock.fill")
                    .font(.system(size: DFFontSize.s18, weight: .semibold))
                    .foregroundStyle(PilotColor.comingSoon)
                Text("\(stage) 활성 예정")
                    .font(DFFont.bodyEmph)
                    .foregroundStyle(DFColor.textPrimary)
                Text(title)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                Text("탭하면 자세히")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.accent)
            }
            .padding(DFSpace.md)
            .background(
                RoundedRectangle(cornerRadius: DFRadius.md)
                    .fill(PilotColor.comingSoon.opacity(DFOpacity.o18))
                    .overlay(
                        RoundedRectangle(cornerRadius: DFRadius.md)
                            .stroke(PilotColor.comingSoon.opacity(DFOpacity.o45), lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
            .onTapGesture { showSheet = true }
        }
        .sheet(isPresented: $showSheet) { detailSheet }
    }

    @ViewBuilder
    private var detailSheet: some View {
        VStack(alignment: .leading, spacing: DFSpace.md) {
            HStack {
                Image(systemName: "lock.fill")
                    .foregroundStyle(PilotColor.comingSoon)
                Text("\(stage) 활성 예정")
                    .font(DFFont.title)
                Spacer()
                Button("닫기") { showSheet = false }
                    .keyboardShortcut(.cancelAction)
            }

            Divider()

            VStack(alignment: .leading, spacing: DFSpace.sm) {
                detailRow(label: "무엇이",         value: title)
                detailRow(label: "왜 대기 중",     value: why)
                detailRow(label: "언제",           value: when)
                if let alternative {
                    detailRow(label: "지금 할 수 있는 것", value: alternative)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(DFSpace.lg)
        .frame(width: 480, height: 320)
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: DFSpace.md) {
            Text(label)
                .font(DFFont.bodyEmph)
                .frame(width: 110, alignment: .leading)
                .foregroundStyle(DFColor.textSecondary)
            Text(value)
                .font(DFFont.body)
                .foregroundStyle(DFColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

public extension View {
    /// 비활성 컴포넌트에 "준비 중" 오버레이 + 상세 시트.
    func comingSoon(
        _ stage: String,
        title: String,
        why: String,
        when: String,
        alternative: String? = nil
    ) -> some View {
        modifier(ComingSoonOverlay(
            stage: stage,
            title: title,
            why: why,
            when: when,
            alternative: alternative
        ))
    }
}
