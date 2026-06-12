import SwiftUI

/// 우측 콘솔 — 실행 기록(명령+결과 카드) 스트림 (기획 3.2).
///
/// 정직한 결과 표시: exit 0 = success 톤, 비-0 = 중립 배경 + 빨강 exit 뱃지
/// (종전엔 실패 출력도 초록으로 칠했다), 전송 실패 = danger.
/// pin-to-bottom: 바닥 근처에서만 자동 스크롤 — 위로 스크롤해 과거를 읽는 중에
/// 새 결과가 와도 시점을 뺏지 않고 "새 결과 N건" 점프 캡슐을 띄운다.
struct RemoteConsoleView: View {
    @EnvironmentObject private var shell: RemoteShell
    /// 재실행 요청 — 카탈로그 매칭 시 confirm 위계를 재경유해야 하므로 부모가 처리.
    let onRerun: (String) -> Void

    @State private var pinnedToBottom = true
    @State private var unseenCount = 0
    @State private var toast: String?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DFSpace.sm3) {
                        header
                        if shell.history.isEmpty {
                            emptyState
                        } else {
                            ForEach(shell.history) { ex in
                                ExchangeCard(exchange: ex, onRerun: onRerun,
                                             onCopied: { showToast("결과를 복사했어요") })
                                    .id(ex.id)
                            }
                        }
                        // 바닥 감지 마커 — 보이면 pinned 로 간주.
                        Color.clear.frame(height: 1)
                            .id("console-bottom")
                            .onAppear { pinnedToBottom = true; unseenCount = 0 }
                            .onDisappear { pinnedToBottom = false }
                    }
                    .padding(DFSpace.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: shell.history.count) { _, _ in
                    if pinnedToBottom {
                        withAnimation { proxy.scrollTo("console-bottom", anchor: .bottom) }
                    } else {
                        unseenCount += 1
                    }
                }
                .onChange(of: unseenCount) { _, n in
                    // 점프 캡슐 클릭 시 0 으로 리셋 → 바닥 이동.
                    if n == 0 {
                        withAnimation { proxy.scrollTo("console-bottom", anchor: .bottom) }
                    }
                }
            }

            if unseenCount > 0 {
                Button { unseenCount = 0 } label: {
                    Label("새 결과 \(unseenCount)건", systemImage: "arrow.down")
                        .font(DFFont.caption)
                        .padding(.horizontal, DFSpace.sm2)
                        .padding(.vertical, DFSpace.xs)
                        .background(DFColor.accent)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(DFSpace.md)
            }

            if let toast {
                DFToast(title: toast, severity: .success)
                    .padding(DFSpace.md)
                    .transition(.opacity)
            }
        }
    }

    private var header: some View {
        HStack {
            Spacer()
            if !shell.history.isEmpty {
                Button {
                    let n = shell.history.count
                    shell.clear()
                    showToast("기록 \(n)건을 지웠어요")
                } label: {
                    Label("기록 지우기", systemImage: "trash")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .help("실행 기록을 모두 지웁니다 — 로봇엔 영향 없음 (⇧⌘K)")
            }
        }
    }

    private var emptyState: some View {
        DFEmptyState(
            icon: "terminal.fill",
            title: "첫 명령을 보내 보세요",
            message: "왼쪽 목록을 누르거나 아래 입력창에 셸 명령을 입력하면 로봇에서 실행돼요.\n⌘F 로 33개 명령을 검색할 수 있어요.",
            tint: DFColor.forge
        )
        .padding(.top, DFSpace.lg)
    }

    private func showToast(_ msg: String) {
        withAnimation { toast = msg }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { toast = nil }
        }
    }
}

/// 명령 1회 실행 카드 — 메타 행(시각·명령·exit·경과) + 출력 블록.
struct ExchangeCard: View {
    let exchange: RemoteShell.Exchange
    let onRerun: (String) -> Void
    let onCopied: () -> Void

    @State private var hovering = false
    @State private var expanded = false

    private static let collapseLineLimit = 15

    var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs2) {
            metaRow
            if let err = exchange.error {
                Label(err, systemImage: "exclamationmark.circle.fill")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let result = exchange.result {
                resultBlock(result)
            } else {
                HStack(spacing: DFSpace.xs2) {
                    ProgressView().controlSize(.small)
                    Text("실행 중 — 응답 대기")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary)
                }
            }
        }
        .padding(DFSpace.sm2)
        .background(hovering ? DFColor.hoverBg : DFColor.card)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.sm)
                .stroke(DFColor.textSecondary.opacity(DFOpacity.o10), lineWidth: 0.5)
        )
        .onHover { hovering = $0 }
    }

    private var metaRow: some View {
        HStack(spacing: DFSpace.xs2) {
            Text(Self.timeFormatter.string(from: exchange.sentAt))
                .font(DFFont.dataSmall)
                .foregroundStyle(DFColor.textSecondary)
            Text("$ \(firstLine(exchange.command))")
                .font(DFFont.mono)
                .foregroundStyle(DFColor.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(exchange.command)
            Spacer(minLength: DFSpace.xs)
            exitChip
            if let ms = exchange.elapsedMs {
                Text("\(ms)ms")
                    .font(DFFont.dataSmall)
                    .foregroundStyle(DFColor.textSecondary)
            }
            if hovering {
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(exchange.result ?? exchange.error ?? exchange.command,
                                 forType: .string)
                    onCopied()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: DFFontSize.s10))
                }
                .buttonStyle(.plain)
                .help("결과 복사")

                Button { onRerun(exchange.command) } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: DFFontSize.s10))
                }
                .buttonStyle(.plain)
                .help("다시 실행 — 확인 단계가 있는 명령은 다시 물어봐요")
            }
        }
    }

    @ViewBuilder
    private var exitChip: some View {
        if exchange.error != nil {
            DFChip("연결 실패", style: .danger, mono: true)
        } else if let code = exchange.exitCode {
            DFChip("exit \(code)", style: code == 0 ? .success : .danger, mono: true)
        } else if exchange.result != nil {
            DFChip("—", style: .neutral, mono: true)
        }
    }

    @ViewBuilder
    private func resultBlock(_ result: String) -> some View {
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        let isLong = lines.count > Self.collapseLineLimit
        let shown = (expanded || !isLong)
            ? result
            : lines.prefix(Self.collapseLineLimit).joined(separator: "\n")

        VStack(alignment: .leading, spacing: DFSpace.xs) {
            DFCodeBlock(shown, scrollable: false, minHeight: nil,
                        maxHeight: expanded ? nil : DFDataLayout.codeBlockMaxH)
            if isLong {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Text(expanded ? "접기" : "전체 보기 (\(lines.count)줄)")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.accent)
                }
                .buttonStyle(.plain)
            }
            // 권한 거부 보조 안내(기획 4.3) — 원인 + 다음 행동.
            if (exchange.exitCode ?? 0) != 0,
               result.lowercased().contains("permission denied") {
                Text("sudo 가 필요한 명령일 수 있어요.")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
        }
        // 결과 배경 의미론: 성공만 success 톤 — 실패를 초록으로 칠하지 않는다.
        .background(
            ((exchange.exitCode ?? 0) == 0 && exchange.error == nil)
                ? DFColor.success.opacity(DFOpacity.o06) : Color.clear
        )
    }

    private func firstLine(_ s: String) -> String {
        String(s.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
