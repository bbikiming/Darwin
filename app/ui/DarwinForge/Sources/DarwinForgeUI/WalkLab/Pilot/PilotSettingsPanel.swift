import SwiftUI

/// **v1.22.x (2026-05-22) — Pilot 4 차원 종합 설정 panel**.
///
/// 사이클 84 + 85 에서 `PilotPreferences` 모델 + `RootView` wire-up + UserDefaults 영속
/// store 가 구성됐으나 **사용자 UI 부재** — 슬라이더 → `store.save()` 호출 path 가 없었음.
/// 본 panel 이 4 차원 (lr / fb / yaw / smoothing) 슬라이더를 노출하고 "저장" 버튼이
/// production 영속을 트리거.
///
/// # 비유
///
/// 게임 그래픽 설정 화면 — 4개 슬라이더를 자유롭게 조절하며 즉시 preview, "적용/저장"
/// 누르면 다음 실행에도 유지. preview 만 시도하고 닫으면 영속 안 됨 (사용자 의도 명확).
///
/// # `KeyboardPilotPanel.sensitivityRow` 와 차이
///
/// - 기존: keyboard 전용 1차원 multiplier — `@AppStorage` 직접.
/// - 본 panel: 4 차원 종합 — `PilotPreferences` 모델 + 명시 store. multiplier 와 직교.
///
/// 두 컨트롤이 충돌 가능 — 둘 다 `bridge.scale` 을 write. 마지막 변경이 우선. 사용자에겐
/// keyboard panel = 빠른 ±, settings panel = 정밀 절대값 조정으로 분리된 mental model.
///
/// # UX 흐름
///
/// 1. onAppear — store.load() → @State 4 값 초기화 (bridge 와 동기 가정).
/// 2. 슬라이더 onChange → bridge.scale / smoothingFactor 즉시 갱신 (real-time preview).
/// 3. "저장" 클릭 → store.save(현 슬라이더 조합) — UserDefaults 기록.
/// 4. "기본값" 클릭 → 슬라이더 4개 + bridge 동시 reset.
@MainActor
public struct PilotSettingsPanel: View {

    // MARK: - 외부 의존성

    /// bridge — slider 변경 시 즉시 scale / smoothingFactor write (real-time preview).
    private let bridge: WalkLabRCBridge

    /// 영속 store — "저장" 버튼만 호출. 슬라이더 onChange 는 호출 안 함 (사용자 의도 명확).
    private let store: PilotPreferencesStore

    // MARK: - Slider 상태

    @State private var scaleLR: Double
    @State private var scaleFB: Double
    @State private var scaleYaw: Double
    @State private var smoothingFactor: Double

    /// "저장됨" 임시 표시 — 사용자가 save 클릭 후 1.5초간 visual feedback.
    @State private var savedFlash: Bool = false

    // MARK: - Init

    public init(bridge: WalkLabRCBridge, store: PilotPreferencesStore) {
        self.bridge = bridge
        self.store = store
        // @State 초기값은 store.load() 가 적절 — RootView 가 이미 launch 시 bridge 에 적용.
        // 본 panel 진입 시 bridge 가 사용자 마지막 저장값 보유 가정.
        let prefs = store.load()
        _scaleLR = State(initialValue: prefs.scaleLR)
        _scaleFB = State(initialValue: prefs.scaleFB)
        _scaleYaw = State(initialValue: prefs.scaleYaw)
        _smoothingFactor = State(initialValue: prefs.smoothingFactor)
    }

    // MARK: - Body

    public var body: some View {
        VStack(alignment: .leading, spacing: DFSpace.sm) {
            header
            sliderRow(label: "좌우 (LR)",
                      value: $scaleLR,
                      onChange: applyToBridge)
            sliderRow(label: "전후 (FB)",
                      value: $scaleFB,
                      onChange: applyToBridge)
            sliderRow(label: "회전 (Yaw)",
                      value: $scaleYaw,
                      onChange: applyToBridge)
            sliderRow(label: "smoothing (EMA)",
                      value: $smoothingFactor,
                      onChange: applyToBridge)
            actionRow
        }
        .padding(DFSpace.sm3)
        .frame(width: 280)
        .background(DFColor.canvas.opacity(DFOpacity.o85 + 0.07))
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.card))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.card)
                .stroke(DFColor.textSecondary.opacity(DFOpacity.o30),
                        lineWidth: DFSize.borderHairline)
        )
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: DFSpace.xs2) {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(DFColor.accent)
                .font(DFFont.bodySmall)
            Text("Pilot 감도 설정")
                .font(DFFont.captionEmph)
            Spacer()
            if savedFlash {
                HStack(spacing: DFSpace.micro) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.success)
                    Text("저장됨")
                        .font(DFFont.caption)
                        .foregroundStyle(DFColor.success)
                }
            }
        }
    }

    /// 단일 슬라이더 row — label + 현재 값 + slider. 0..1 range, 0.05 step.
    private func sliderRow(label: String,
                           value: Binding<Double>,
                           onChange: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: DFSpace.micro2) {
            HStack {
                Text(label)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(DFFont.monoLabel)
                    .foregroundStyle(DFColor.textPrimary)
            }
            Slider(value: value, in: 0.0 ... 1.0, step: 0.05)
                .controlSize(.mini)
                .onChange(of: value.wrappedValue) { _, _ in
                    onChange()
                }
        }
    }

    private var actionRow: some View {
        HStack(spacing: DFSpace.xs2) {
            Button(action: resetToDefaults) {
                Text("기본값")
                    .font(DFFont.caption)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("4개 슬라이더 + bridge 를 출하 기본값으로 되돌림 (저장 X)")

            Button(action: saveCurrent) {
                Text("저장")
                    .font(DFFont.captionEmph)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(DFColor.accent)
            .help("현재 슬라이더 조합을 UserDefaults 에 영속 — 다음 실행에도 유지")
        }
    }

    // MARK: - Actions

    /// 슬라이더 변경 시 bridge 에 즉시 반영 (real-time preview). store.save 는 안 함.
    private func applyToBridge() {
        Self.apply(
            PilotPreferences(scaleLR: scaleLR, scaleFB: scaleFB,
                             scaleYaw: scaleYaw, smoothingFactor: smoothingFactor),
            to: bridge
        )
    }

    /// "저장" — 현재 슬라이더 조합을 store 에 영속.
    private func saveCurrent() {
        let prefs = PilotPreferences(
            scaleLR: scaleLR,
            scaleFB: scaleFB,
            scaleYaw: scaleYaw,
            smoothingFactor: smoothingFactor
        )
        store.save(prefs)
        // 1.5초간 "저장됨" 표시 후 자동 hide.
        savedFlash = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            savedFlash = false
        }
    }

    /// "기본값" — slider 4개 + bridge 동시 reset. 저장은 안 함 (명시 클릭 필요).
    private func resetToDefaults() {
        let d = PilotPreferences.defaultValues
        scaleLR = d.scaleLR
        scaleFB = d.scaleFB
        scaleYaw = d.scaleYaw
        smoothingFactor = d.smoothingFactor
        applyToBridge()
    }

    // MARK: - Test seam (internal — 같은 module 의 test target 만 호출)

    /// **테스트 진입점** — slider onChange / 기본값 / 저장 의 logic 가 동일 path 사용하도록
    /// 분리. SwiftUI host 없이 @State 접근 불가 → 본 정적 helper 가 같은 동작 (bridge mutation
    /// + store.save) 을 노출. 단일 source of truth 보장.
    static func apply(_ prefs: PilotPreferences, to bridge: WalkLabRCBridge) {
        bridge.scale = TelloRCMapper.Scale(
            fb: prefs.scaleFB,
            lr: prefs.scaleLR,
            yaw: prefs.scaleYaw
        )
        bridge.smoothingFactor = prefs.smoothingFactor
    }
}
