import SwiftUI

/// **콕핏 걸음 로직 LAB (2026-05-31)** — 조종 중 보행 로직을 라이브로 전환·비교.
///
/// # 목적
///
/// "왜 이렇게 걷는가"를 즉석에서 실험한다. 데모(공식 ROBOTIS Walking)가 답지이므로,
/// 조종하면서 **엔진 / 밸런스 알고리즘 / 프리셋**을 바꿔가며 어느 조합이 가장 자연스럽게
/// (지면과 평행, 뒤뚱거림 없이) 걷는지 비교할 수 있게 한다.
///
/// # 비유
///
/// 자동차 주행 중 ECU 맵을 스위치로 바꿔보며 승차감을 비교하는 다이얼과 같다.
///
/// # 노출 축 (모두 `WalkLabSession` 의 기존 라이브 setter — 즉시 반영)
///
/// - **엔진**: `macSparseKeyframe`(Mac 키프레임) vs `robotisOnboard`(로봇 온보드, 데모급).
///   엔진 전환 시 세션이 자동으로 보행을 안전 정지(`walkingEngine.didSet`).
/// - **밸런스 알고리즘**: 꺼짐 / ROBOTIS 기본(P) / Hybrid B+A / 관찰만.
///   `balanceExperimentConfig.algorithmMode` 변경 → corrector 재생성.
/// - **프리셋 빠른 전환**: 제자리/천천히/보통/빠르게 — `pilotStart(preset:)`.
struct CockpitWalkLogicPanel: View {
    @Environment(WalkLabSession.self) private var session
    /// 텔레메트리 경로/안전게이트 상태를 읽기 위한 store (W5, 계약 §D.5).
    @EnvironmentObject private var store: ConnectionStore

    /// 빠른 전환용 테스트 프리셋 (회전은 스틱으로 — 여기선 전진 계열만).
    private static let testPresets: [WalkLabPreset] = [.march, .slowWalk, .normalWalk, .fastWalk]

    var body: some View {
        @Bindable var s = session
        VStack(alignment: .leading, spacing: 8) {
            Text("걸음 로직 LAB")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(CockpitColors.cyan)
            Text("바꿔가며 어느 게 잘 걷는지 비교 — 각 시도는 자동 저장됩니다")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            // 1) 보행 엔진 — 가장 큰 차이를 만드는 축 (공식 vs 우리 구현)
            row(label: "보행기") {
                Picker("", selection: $s.walkingEngine) {
                    ForEach(WalkingEngine.allCases) { eng in
                        Text(engineDisplay(eng)).tag(eng)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .labelsHidden()
                .frame(width: 168)
                // mid-walk 엔진 전환은 trial/세션 헤더가 START config만 잡아 오귀속 →
                // 보행 중엔 엔진 잠금(밸런스/프리셋은 corrector 재생성·샘플 반영이라 허용).
                .disabled(session.isRobotWalking)
                .accessibilityIdentifier("cockpit.walklogic.engine")
            }
            Text(engineHint)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(session.walkingEngine == .robotisOnboard ? CockpitColors.live : CockpitColors.warn)
                .fixedSize(horizontal: false, vertical: true)
            if session.isRobotWalking {
                Text("보행 중 — 보행기 잠금 (정지 후 변경)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }

            // 1.5) 텔레메트리 경로 + 안전게이트 — 온보드(SSH) vs LAN 정직성(계약 §D.5)
            telemetryPathRow

            // 2) 밸런스 보정 — Mac측 미세 조정 (대개 체감 차이 작음)
            row(label: "밸런스") {
                Picker("", selection: balanceModeBinding) {
                    ForEach(BalanceAlgorithmMode.allCases) { mode in
                        Text(balanceDisplay(mode)).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .labelsHidden()
                .frame(width: 168)
                .accessibilityIdentifier("cockpit.walklogic.balanceMode")
            }
            Text("Mac측 보정 — 전송 지연 탓에 대개 큰 차이 없음. 진짜 차이는 위 '보행기'.")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)

            // 3) 프리셋 빠른 전환
            Text("프리셋 (걸음 속도/보폭)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
            HStack(spacing: 4) {
                ForEach(Self.testPresets) { preset in
                    presetButton(preset)
                }
            }

            // 4) 라이브 상태
            Text(statusLine)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cockpitPanel(tint: CockpitColors.cyan, strokeOpacity: 0.3)
    }

    // MARK: - Subviews

    /// 텔레메트리 경로 배지("온보드(SSH)" vs "Mac 키프레임/LAN") + 안전게이트 온/오프라인.
    ///
    /// **정직성(W5)**: 온보드 모드는 IMU/전압만 업링크(관절/온도 없음)하므로 어느 경로로
    /// 데이터가 흐르고 안전게이트가 살아있는지 항상 노출. 지연(`.onboardStale`)/오프라인은
    /// 호박/회색으로 강등 — stale 데이터를 fresh-green 으로 표시하지 않는다.
    private var telemetryPathRow: some View {
        let mode = store.telemetryMode
        let link = ConnectionLinkKind.classify(host: store.activeConnectionHost)
        return HStack(spacing: 6) {
            Image(systemName: mode.iconSystemName)
                .font(.system(size: 9, weight: .bold))
            Text(mode.pathLabel)
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
            // 유선/무선 + 케이블 의존 경고 — 조종 중에도 "랜선 뽑으면 끊김"을 인지.
            // host 없으면(USB/미연결) 표기 생략 — 유선/무선 개념이 없음.
            if mode != .offline, !store.activeConnectionHost.trimmingCharacters(in: .whitespaces).isEmpty {
                Image(systemName: link.icon)
                    .font(.system(size: 8, weight: .bold))
                Text(link.label)
                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                if link.requiresCable {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(CockpitColors.warn)
                }
            }
            Spacer(minLength: 4)
            // 정직성 fix(codex): Mac 게이트 실제 동작 여부. 온보드는 "로봇 자율".
            let gateOK = mode.safetyBanner.level == .ok
            Image(systemName: gateOK ? "checkmark.shield.fill"
                  : (mode == .onboard ? "shield.lefthalf.filled" : "shield.slash.fill"))
                .font(.system(size: 9, weight: .bold))
            Text(gateOK ? "게이트 온라인" : (mode == .onboard ? "게이트: 로봇 자율" : "게이트 오프라인"))
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
        }
        .foregroundStyle(telemetryTone)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(telemetryTone.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(telemetryTone.opacity(0.35), lineWidth: 1))
    }

    /// 경로 배지 tone — cockpit 네온 팔레트로 매핑(라이브=green, 지연=amber, 오프라인=회색).
    private var telemetryTone: Color {
        switch store.telemetryMode {
        case .lan, .onboard: return CockpitColors.live
        case .onboardStale:  return CockpitColors.warn
        case .offline:       return Color.white.opacity(0.5)
        }
    }

    private func row<Content: View>(label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.65))
                .frame(width: 38, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func presetButton(_ preset: WalkLabPreset) -> some View {
        let active = session.current == preset
        return Button {
            _ = session.pilotStart(preset: preset)
        } label: {
            Text(preset.label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(active ? .black : .white.opacity(0.85))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(active ? CockpitColors.live : Color.white.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("cockpit.walklogic.preset.\(preset.rawValue)")
    }

    // MARK: - 표시 라벨 (공식 vs 우리 구현 명확화 — UX 라이팅)

    /// 보행 엔진 — "공식(데모와 동일)" 인지 "우리 구현" 인지 명시.
    private func engineDisplay(_ eng: WalkingEngine) -> String {
        switch eng {
        case .macSparseKeyframe: return "Mac 키프레임 (우리 구현)"
        case .robotisOnboard:    return "ROBOTIS 온보드 (공식·데모)"
        }
    }

    /// 현재 선택된 엔진의 한 줄 설명.
    private var engineHint: String {
        switch session.walkingEngine {
        case .macSparseKeyframe: return "우리 구현 — 전송 지연으로 뒤뚱거림"
        case .robotisOnboard:    return "싸커 데모의 공식 보행 (로봇 patch·SSH 필요)"
        }
    }

    /// 밸런스 보정 모드 — 모두 Mac측 보정. 라벨에 출처/성격 명시.
    private func balanceDisplay(_ mode: BalanceAlgorithmMode) -> String {
        switch mode {
        case .off:             return "끄기"
        case .robotisPControl: return "ROBOTIS 기본 (P) · 우리 구현"
        case .hybridBA:        return "Hybrid (우리 실험)"
        case .observeOnly:     return "관찰만 (로그)"
        }
    }

    // MARK: - Bindings / status

    /// `balanceExperimentConfig` 의 algorithmMode 만 갈아끼우는 바인딩.
    private var balanceModeBinding: Binding<BalanceAlgorithmMode> {
        Binding(
            get: { session.balanceExperimentConfig.algorithmMode },
            set: { newMode in
                var cfg = session.balanceExperimentConfig
                cfg.algorithmMode = newMode
                session.balanceExperimentConfig = cfg   // didSet → corrector 재생성
            }
        )
    }

    private var statusLine: String {
        let eng = session.walkingEngine.shortLabel
        let mode = session.balanceExperimentConfig.algorithmMode.label
        let preset = session.current == .idle ? "정지" : session.current.label
        return "▸ \(eng) · 밸런스 \(mode) · \(preset)"
    }
}
