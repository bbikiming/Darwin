import SwiftUI

/// **v1.22.0 (2026-05-22) Phase 5 — Voice pilot panel**.
///
/// `VoicePilotAdapter` 의 reactive 상태를 시각화 + 사용자가 토글 버튼으로 명시적 start/stop.
/// `KeyboardPilotPanel` / `TelloPilotHud` 와 동일 design language — 280pt width,
/// `DFColor.canvas.opacity(0.92)` background, RoundedRectangle 8pt corner.
///
/// # UX 설계
///
/// 1. 헤더: `mic.fill` 아이콘 + "Voice Pilot" + 상태 chip (대기/녹음중/오류)
/// 2. 토글 버튼 (눌러서 시작/정지) — primary CTA
/// 3. 마지막 인식 텍스트 — `"..."` 인용 안에 표시, 매칭 keyword 있으면 강조
/// 4. 지원 키워드 표 (한/영 매핑) — collapsed 가능
/// 5. 권한 거부 안내 — `lastError` 있을 때만 노출
///
/// # 안전 / 권한 정책
///
/// `.onAppear` 에서 자동 `start()` 안 함 — 마이크 권한 다이얼로그가 사용자 동의 없이 즉시
/// 떠서 UX 나쁨. 사용자가 명시적 마이크 버튼 클릭 시에만 `start()` → 권한 요청.
/// `.onDisappear` 에서 자동 `stop()` — overlay 닫힐 때 마이크 점유 누수 차단.
///
/// # 의존
///
/// `bridge: WalkLabRCBridge` — adapter init 의존성. session.pilotBridge 와 동일.
/// `VoicePilotAdapter` 는 @State 로 view 내부 lifecycle 관리 — view dismount 시 자동 release.
@MainActor
public struct VoicePilotPanel: View {

    // MARK: - 외부 의존성 (parent 가 주입)

    /// adapter 가 키워드 매칭 후 호출할 bridge.
    private let bridge: WalkLabRCBridge

    /// **테스트 / 시뮬레이션 용** — 별도 `VoiceRecognizing` 주입 가능.
    /// nil 이면 production `SpeechFrameworkRecognizer` 사용 (실 마이크).
    private let injectedRecognizer: (any VoiceRecognizing)?

    // MARK: - 내부 상태

    /// adapter 인스턴스 — view lifecycle 과 동기화. dismount 시 stop().
    /// **주의**: `@State` 가 init 시 생성된 값을 보존. recognizer 주입 시 첫 init 만 반영.
    @State private var adapter: VoicePilotAdapter?

    /// 지원 키워드 표 펼침 여부 — 기본 false (공간 절약).
    @State private var keywordsExpanded: Bool = false

    // MARK: - Init

    // MARK: - Harness DI (Wave 3 Phase 3.3, 사이클 243)
    @Environment(\.harness) private var harness

    /// Production init — 기본 `SpeechFrameworkRecognizer` 사용 (실 마이크).
    public init(bridge: WalkLabRCBridge) {
        self.bridge = bridge
        self.injectedRecognizer = nil
    }

    /// 테스트 init — `MockVoiceRecognizer` 등 임의 source 주입.
    public init(bridge: WalkLabRCBridge, recognizer: any VoiceRecognizing) {
        self.bridge = bridge
        self.injectedRecognizer = recognizer
    }

    // MARK: - Body

    public var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            header
            toggleButton
            recognizedTextRow
            keywordsSection
            errorRow
        }
        .padding(DFSpace.sm3)
        .frame(width: 280)
        .background(DFColor.canvas.opacity(DFOpacity.o85 + 0.07))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.card)
                .stroke(borderColor, lineWidth: borderWidth)
        )
        .onAppear { ensureAdapter() }
        // **중요**: onDisappear 에 stop() — overlay 닫혀도 마이크 점유 끊김 보장.
        // adapter 의 @MainActor deinit 가 properties 접근 불가이므로 명시 정리.
        .onDisappear { adapter?.stop() }
    }

    // MARK: - Subviews

    /// 헤더: 아이콘 + "Voice Pilot" + 상태 chip.
    private var header: some View {
        HStack(spacing: DFSpace.xs2) {
            Image(systemName: isListening ? "mic.fill" : "mic.slash")
                .foregroundStyle(isListening ? DFColor.accent : DFColor.textSecondary)
                .font(DFFont.bodySmall)
            Text("Voice Pilot")
                .font(DFFont.captionEmph)
            Spacer()
            statusChip
        }
    }

    /// 상태 chip — 녹음중/대기/오류.
    private var statusChip: some View {
        HStack(spacing: DFSpace.micro) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 6, height: 6)
            Text(statusLabel)
                .font(DFFont.caption)
                .foregroundStyle(statusDotColor)
        }
        .padding(.horizontal, DFSpace.xs2)
        .padding(.vertical, 2)
        .background(statusDotColor.opacity(DFOpacity.o18))
        .clipShape(Capsule())
    }

    /// 마이크 토글 버튼 — 사용자 명시적 start/stop. **자동 start 금지**.
    private var toggleButton: some View {
        Button(action: toggleListening) {
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: isListening ? "stop.circle.fill" : "mic.circle.fill")
                    .font(DFFont.sectionMedium)
                Text(isListening ? "녹음 정지" : "녹음 시작")
                    .font(DFFont.bodySmallEmph)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DFSpace.xs2)
        }
        .buttonStyle(.borderedProminent)
        .tint(isListening ? DFColor.danger : DFColor.accent)
        .controlSize(.regular)
        .help(isListening ? "음성 인식 중단" : "마이크 권한 요청 후 음성 인식 시작")
    }

    /// 마지막 인식 텍스트 — "..." 인용 안에. 매칭 keyword 있으면 색 강조.
    @ViewBuilder
    private var recognizedTextRow: some View {
        if let text = adapter?.lastRecognized, !text.isEmpty {
            VStack(alignment: .leading, spacing: DFSpace.micro) {
                Text("들린 말")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                HStack(spacing: DFSpace.xs2) {
                    Text("\u{201C}\(text)\u{201D}")
                        .font(DFFont.bodySmall.italic())
                        .lineLimit(2)
                        .foregroundStyle(DFColor.textPrimary)
                    Spacer(minLength: 0)
                    if let matched = adapter?.lastMatchedKeyword {
                        matchedKeywordBadge(matched)
                    }
                }
            }
            .padding(.horizontal, DFSpace.xs2)
            .padding(.vertical, DFSpace.xs)
            .background(DFColor.textSecondary.opacity(DFOpacity.ghost))
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.statusTile))
        } else if isListening {
            Text("말씀하세요 — 예: \u{201C}걸어\u{201D}, \u{201C}stop\u{201D}, \u{201C}비상\u{201D}")
                .font(DFFont.caption)
                .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.dim))
                .padding(.vertical, DFSpace.micro2)
        }
    }

    private func matchedKeywordBadge(_ keyword: String) -> some View {
        let isSafety = keyword == "emergency" || keyword == "recovery"
        let tint = isSafety ? DFColor.danger : DFColor.success
        return Text(keyword)
            .font(DFFont.monoLabel)
            .foregroundStyle(tint)
            .padding(.horizontal, DFSpace.xs2)
            .padding(.vertical, 1)
            .background(tint.opacity(DFOpacity.o15))
            .clipShape(Capsule())
    }

    /// 지원 키워드 표 — 펼침/접힘 토글.
    private var keywordsSection: some View {
        VStack(alignment: .leading, spacing: DFSpace.xs) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.18)) {
                    keywordsExpanded.toggle()
                }
            }) {
                HStack(spacing: DFSpace.xs) {
                    Image(systemName: keywordsExpanded ? "chevron.down" : "chevron.right")
                        .font(DFFont.caption)
                    Text("지원 키워드")
                        .font(DFFont.caption)
                    Spacer()
                }
                .foregroundStyle(DFColor.textSecondary)
            }
            .buttonStyle(.plain)

            if keywordsExpanded {
                keywordsTable
            }
        }
    }

    private var keywordsTable: some View {
        VStack(alignment: .leading, spacing: DFSpace.micro2) {
            keywordRow(korean: "걸어", english: "walk / march", action: "보행 시작")
            keywordRow(korean: "정지", english: "stop / idle", action: "보행 정지")
            keywordRow(korean: "조깅", english: "jog", action: "조깅 시작")
            keywordRow(korean: "비상", english: "emergency", action: "긴급 정지", danger: true)
            keywordRow(korean: "복구", english: "recover", action: "긴급 해제", danger: true)
        }
        .padding(DFSpace.xs2)
        .background(DFColor.textSecondary.opacity(DFOpacity.ghost))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.statusTile))
    }

    private func keywordRow(korean: String,
                            english: String,
                            action: String,
                            danger: Bool = false) -> some View {
        HStack(spacing: DFSpace.xs) {
            Text(korean)
                .font(DFFont.monoLabel)
                .foregroundStyle(danger ? DFColor.danger : DFColor.textPrimary)
                .frame(width: 36, alignment: .leading)
            Text(english)
                .font(DFFont.monoLabel)
                .foregroundStyle(DFColor.textSecondary)
                .frame(width: 96, alignment: .leading)
            Text(action)
                .font(DFFont.caption)
                .foregroundStyle(danger ? DFColor.danger : DFColor.textSecondary)
            Spacer(minLength: 0)
        }
    }

    /// 권한 거부 / 엔진 에러 안내 — `lastError` 있을 때만.
    @ViewBuilder
    private var errorRow: some View {
        if let err = adapter?.lastError {
            HStack(alignment: .top, spacing: DFSpace.xs2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("음성 인식 사용 불가")
                        .font(DFFont.bodySmallEmph)
                        .foregroundStyle(DFColor.warning)
                    Text(err)
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("시스템 설정 > 개인정보 > 음성 인식 / 마이크 에서 허용")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.textSecondary.opacity(DFOpacity.dim))
                }
                Spacer(minLength: 0)
            }
            .padding(DFSpace.xs2)
            .background(DFColor.warning.opacity(DFOpacity.o10))
            .clipShape(RoundedRectangle(cornerRadius: DFRadius.statusTile))
        }
    }

    // MARK: - Derived state

    private var isListening: Bool { adapter?.isListening ?? false }

    private var statusLabel: String {
        if adapter?.lastError != nil { return "오류" }
        if isListening { return "녹음중" }
        return "대기"
    }

    private var statusDotColor: Color {
        if adapter?.lastError != nil { return DFColor.warning }
        if isListening { return DFColor.success }
        return DFColor.textSecondary
    }

    private var borderColor: Color {
        isListening ? DFColor.accent : DFColor.textSecondary.opacity(DFOpacity.o30)
    }

    private var borderWidth: CGFloat {
        isListening ? 2 : DFSize.borderHairline
    }

    // MARK: - Actions

    /// 마이크 토글 — 사용자 명시 클릭. **권한 다이얼로그는 본 메소드 첫 호출 시점에 OS 가 제시**.
    private func toggleListening() {
        guard let adapter else { return }
        if adapter.isListening {
            adapter.stop()
            harness.record(
                .pilotVoiceToggle, level: .info, actor: .user,
                data: ["listening": AnyCodable(false)]
            )
        } else {
            adapter.start()
            harness.record(
                .pilotVoiceToggle, level: .info, actor: .user,
                data: ["listening": AnyCodable(true)]
            )
        }
    }

    /// `@State` adapter 가 nil 일 때 (첫 onAppear) 인스턴스 생성.
    /// init 의 recognizer 주입 여부에 따라 production / test 분기.
    /// **주의**: adapter 생성만, 자동 start() 안 함. 사용자 토글 버튼 클릭 후 start.
    private func ensureAdapter() {
        guard adapter == nil else { return }
        if let injected = injectedRecognizer {
            adapter = VoicePilotAdapter(bridge: bridge, recognizer: injected)
        } else {
            adapter = VoicePilotAdapter(bridge: bridge)
        }
    }
}
