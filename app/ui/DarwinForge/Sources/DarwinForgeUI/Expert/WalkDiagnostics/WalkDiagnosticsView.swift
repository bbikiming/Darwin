import Charts
import ForgeCore
import SwiftUI

/// 전문가 콘솔 — 보행 진단 (Walk Diagnostics).
///
/// **워크랩과의 차이점**:
///   - 워크랩: 친화적 UX, 발 자취 + 안전 점수 + 3D 모델 + 6 슬라이더로 학습용.
///   - 본 뷰: Bloomberg 터미널 스타일 — 멀티 채널 strip chart, 합성 IMU,
///     complementary filter 라이브 데모, sliding-window 통계, CSV 익스포트.
///     monospaced + 고밀도 + 정밀 표기 + 키보드 드라이브.
///
/// **데이터 소스 (2026-05-16 v1.1.1)**:
///   - **미리보기 (Preview)**: `SyntheticImuGenerator` — Mac 안 `WalkEngine` 의
///     발 trajectory 로부터 finite-diff + Gaussian noise 로 합성. 로봇 미연결에서도
///     동작. preset 으로 6 가지 보행 모드 시각화. 보행 알고리즘 검증 + 필터 α 튜닝용.
///   - **실측 (Live)**: `ConnectionStore.lastTelemetry.imu` — CM-740 register 38-49
///     의 12-byte BULK READ (Bus.readImu → forge-core 의 `CmController::read_imu`).
///     ConnectionStore 가 매 200ms (5Hz) 폴링. 로봇 연결 + IMU 응답 필요.
///
/// 레이아웃 (반응형):
///   - 상단: 툴바 — Run/Pause/Step/Reset · 모드 picker · 샘플레이트 · 단위 · CSV
///   - 좌측 (≥1100 width): WalkCommand + (preview) 합성 IMU 노이즈 + 필터 α
///   - 가운데 (fill): gyro chart · accel chart · 필터 추정 chart · phase ribbon
///   - 우측 (≥1280 width): 라이브 numeric + 채널별 통계 (min/max/μ/σ/RMS) +
///                        최근 sample log
public struct WalkDiagnosticsView: View {
    // MARK: - Connection store (live mode IMU source)
    @EnvironmentObject private var store: ConnectionStore
    // v1.11.21: 워크랩 세션 — 운영 상태 / corrector / fallPrediction 통합 표시용.
    @Environment(WalkLabSession.self) private var walkLabSession

    // MARK: - Data source mode
    @State private var source: DiagnosticsSource = .preview

    // MARK: - State (Walk command)
    @State private var cmdX: Double = 0.0
    @State private var cmdY: Double = 0.0
    @State private var cmdA: Double = 0.0
    @State private var enabled: Bool = false
    /// **Phase G12 (2026-05-15)**: preset quick-select — nil 이면 manual 입력 중.
    @State private var activePreset: WalkLabPreset? = nil

    // MARK: - State (IMU synthesis params)
    @State private var gyroNoiseSigma: Double = 0.02
    @State private var accelNoiseSigma: Double = 0.05
    @State private var filterAlpha: Double = 0.98

    // MARK: - Live mode tracking
    /// ConnectionStore.lastTelemetry 의 timestamp 가 변경됐을 때만 sample append.
    /// 같은 ImuRaw 가 여러 번 publish 돼도 중복 append 방지.
    @State private var lastLiveImuTimestamp: Date?
    /// Live 모드 누적 시작 시각 — chart x 축 origin.
    @State private var liveStartedAt: Date?
    /// 실측 모드 전용 — Walk Command 의 결과를 실 로봇 다리 12관절로 송출 할지.
    /// 기본 OFF. ON 시 100ms 마다 WalkLab.swift 의 walkPoseFromSample 패턴으로 송출.
    @State private var sendWalkToRobot: Bool = false
    /// 실 로봇 송출 타이머 — sendWalkToRobot && enabled && bus 있음 일 때만 가동.
    @State private var walkSenderTicker: Timer?

    // MARK: - Units
    @State private var unitGyro: GyroUnit = .radPerSec
    @State private var unitAccel: AccelUnit = .mPerSec2
    @State private var unitAngle: AngleUnit = .degrees

    // MARK: - Sample rate
    @State private var sampleRateHz: Int = 100

    // MARK: - Channel visibility
    @State private var showGx = true
    @State private var showGy = true
    @State private var showGz = true
    @State private var showAx = true
    @State private var showAy = true
    @State private var showAz = true
    @State private var showFilterRoll = true
    @State private var showFilterPitch = true
    @State private var showAccRoll = false
    @State private var showAccPitch = false

    // MARK: - Engine + buffers
    @State private var engine = WalkEngine()
    @State private var generator = SyntheticImuGenerator()
    @State private var filter = ComplementaryFilterSwift()
    @State private var lastFoot: FootTargets?
    @State private var ticker: Timer?
    @State private var simTime: Double = 0  // 초 — 가동 시간 누적.
    @State private var sampleId: Int = 0

    // Time series buffers (10 초 ≈ 1000 samples @ 100Hz)
    @StateObject private var data = WalkDiagnosticsData()

    // MARK: - Toolbar / commands
    @State private var lastExportPath: String?
    @State private var showExportToast: Bool = false

    public init() {}

    /// `ConnectionStore.status == .connected(...)` pattern match helper.
    /// `Status.connected(BoardSnapshot)` associated value 때문에 직접 `==` 비교 불가.
    private var isStoreConnected: Bool {
        if case .connected = store.status { return true }
        return false
    }

    public var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 1280
            let regular = geo.size.width >= 1100

            VStack(spacing: DFSpace.none) {
                toolbar
                    .padding(.horizontal, DFSpace.md)
                    .padding(.vertical, DFSpace.sm)
                    .background(DFColor.elev2)
                    .overlay(Divider(), alignment: .bottom)

                HStack(alignment: .top, spacing: DFSpace.md) {
                    if regular {
                        leftPanel
                            .frame(width: DFLayout.diagnosticLeft)
                    }
                    centerPanel
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if wide {
                        rightPanel
                            .frame(width: DFLayout.diagnosticRight)
                    }
                }
                .padding(DFSpace.md)

                if !regular {
                    // 컴팩트 — 좌/우 패널을 아래로 펴 보임.
                    Divider()
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: DFSpace.md) {
                            leftPanel.frame(width: 280)
                            rightPanel.frame(width: 300)
                        }
                        .padding(DFSpace.md)
                    }
                    .frame(maxHeight: 360)
                }
            }
        }
        .background(DFColor.canvas)
        .overlay(toast, alignment: .top)
        .overlay(alignment: .top) {
            // Live + 미연결 / IMU 미가용 시 차트 위에 안내 배너.
            if source == .live {
                if !isStoreConnected {
                    liveDisconnectedBanner.padding(.top, 56)
                } else if store.isImuUnavailable {
                    liveImuUnavailableBanner.padding(.top, 56)
                }
            }
        }
        .dfDensity(.dataDense)
        // Live 모드: ConnectionStore 의 새 telemetry snapshot 마다 live append 호출.
        // compactMap 으로 nil snap 은 skip; liveAppend 가 source/enabled/timestamp dedup 판단.
        .onReceive(store.$lastTelemetry.compactMap { $0 }) { snap in
            liveAppend(snap)
        }
        .onDisappear { stop() }
    }

    // MARK: - Live mode banners

    private var liveDisconnectedBanner: some View {
        HStack(spacing: DFSpace.xs2) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(DFColor.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("로봇이 연결되지 않았어요")
                    .font(.system(size: DFFontSize.s11, weight: .semibold))
                Text("좌측의 ‘원격 명령’ 메뉴에서 로봇을 연결하면 실제 자세 센서와 모터 데이터가 여기 표시됩니다.")
                    .font(.system(size: DFFontSize.s9))
                    .foregroundStyle(DFColor.textSecondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.md)
                .stroke(DFColor.textSecondary.opacity(DFOpacity.o25), lineWidth: 0.5)
        )
    }

    private var liveImuUnavailableBanner: some View {
        HStack(spacing: DFSpace.xs2) {
            Image(systemName: "sensor.tag.radiowaves.forward.slash")
                .foregroundStyle(DFColor.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("자세 센서가 응답하지 않아요")
                    .font(.system(size: DFFontSize.s11, weight: .semibold))
                Text("로봇은 연결됐지만 CM-740 IMU 레지스터(38–49번)가 응답하지 않습니다. 펌웨어 버전이나 컨트롤러 모델을 확인해 주세요.")
                    .font(.system(size: DFFontSize.s9))
                    .foregroundStyle(DFColor.textSecondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.md)
                .stroke(DFColor.warning.opacity(DFOpacity.o45), lineWidth: 0.5)
        )
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: DFSpace.md) {
            // Mode picker (preview / live) — 보행 진단의 데이터 소스 선택.
            HStack(spacing: DFSpace.xs2) {
                Picker("", selection: $source) {
                    ForEach(DiagnosticsSource.allCases) { src in
                        Label(src.label, systemImage: src.icon).tag(src)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .frame(width: 200)
                .onChange(of: source) { _, _ in
                    // 모드 전환 = 데이터 의미가 달라짐 → 차트 초기화.
                    stop()
                    reset()
                }
            }

            Divider().frame(height: 22)

            // Run / Pause / Step / Reset
            HStack(spacing: DFSpace.xs2) {
                DFButton(.primary, size: .small, action: toggleRun) {
                    HStack(spacing: DFSpace.xs) {
                        Image(systemName: enabled ? "pause.fill" : "play.fill")
                        Text(enabled ? "일시정지" : "실행")
                    }
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(source == .live && !isStoreConnected)
                DFButton(.secondary, size: .small, action: stepOnce) {
                    HStack(spacing: DFSpace.xs) {
                        Image(systemName: "forward.frame.fill")
                        Text("스텝")
                    }
                }
                .disabled(enabled || source == .live)  // live 는 폴링 cadence 고정.
                DFButton(.ghost, size: .small, action: reset) {
                    HStack(spacing: DFSpace.xs) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("리셋")
                    }
                }
            }

            Divider().frame(height: 22)

            // Sample rate — preview 에서만 의미가 있음. live 는 ConnectionStore 폴링에 종속.
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: "metronome").foregroundStyle(DFColor.textSecondary)
                if source == .preview {
                    Picker("", selection: $sampleRateHz) {
                        Text("50 Hz").tag(50)
                        Text("100 Hz").tag(100)
                        Text("200 Hz").tag(200)
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .labelsHidden()
                    .frame(width: 86)
                    .onChange(of: sampleRateHz) { _, _ in if enabled { restart() } }
                } else {
                    Text("초당 5회")
                        .font(.system(size: DFFontSize.s10, design: .monospaced))
                        .foregroundStyle(DFColor.textSecondary)
                        .help("실측 모드는 초당 5회 고정으로 로봇 상태를 읽어옵니다")
                }
            }

            Divider().frame(height: 22)

            // Units
            HStack(spacing: DFSpace.xs2) {
                Picker("자이로", selection: $unitGyro) {
                    Text("rad/s").tag(GyroUnit.radPerSec)
                    Text("deg/s").tag(GyroUnit.degPerSec)
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
                .controlSize(.small)
                .labelsHidden()
                Picker("가속도", selection: $unitAccel) {
                    Text("m/s²").tag(AccelUnit.mPerSec2)
                    Text("g").tag(AccelUnit.g)
                }
                .pickerStyle(.segmented)
                .frame(width: 90)
                .controlSize(.small)
                .labelsHidden()
            }

            Divider().frame(height: 22)

            // CSV export
            DFButton(.secondary, size: .small, action: exportCsv) {
                HStack(spacing: DFSpace.xs) {
                    Image(systemName: "tablecells")
                    Text("CSV")
                }
            }
            .keyboardShortcut("s", modifiers: [.command])

            Spacer()

            // Status pill
            statusPill
        }
    }

    private var statusPill: some View {
        let on = enabled
        let modeTint: Color = source == .preview ? DFColor.info : DFColor.success
        let modeTag: String = source == .preview ? "미리보기" : "실측"
        return HStack(spacing: DFSpace.xs2) {
            // 모드 배지 — 합성/실측 구분.
            Text(modeTag)
                .font(.system(size: DFFontSize.s9, weight: .bold))
                .foregroundStyle(modeTint)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(modeTint, lineWidth: 0.8)
                )
            Text("·").foregroundStyle(DFColor.textSecondary)
            // 동작 상태.
            Circle()
                .fill(on ? DFColor.success : DFColor.textSecondary)
                .frame(width: 7, height: 7)
                .shadow(color: on ? DFColor.success.opacity(DFOpacity.o70) : .clear, radius: 3)
            Text(on ? "기록 중" : "멈춤")
                .font(.system(size: DFFontSize.s10, weight: .semibold))
                .foregroundStyle(on ? DFColor.success : DFColor.textSecondary)
            Text("·").foregroundStyle(DFColor.textSecondary)
            Text(String(format: "%.1f초", simTime))
                .font(.system(size: DFFontSize.s10, design: .monospaced))
                .foregroundStyle(DFColor.textSecondary)
            Text("·").foregroundStyle(DFColor.textSecondary)
            Text("\(data.gyroX.samples.count)샘플")
                .font(.system(size: DFFontSize.s10, design: .monospaced))
                .foregroundStyle(DFColor.textSecondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(DFColor.elev2))
        .overlay(Capsule().stroke(modeTint.opacity(DFOpacity.o40), lineWidth: 0.5))
    }

    // MARK: - Left panel (input controls)

    private var leftPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DFSpace.md) {
                // Walk Command — 양쪽 모드에 표시. 일관된 UX + 실측에서도 보행 명령 테스트 가능.
                commandCard
                if source == .preview {
                    noiseCard
                } else {
                    // 실측 모드 전용 — 위 명령을 실 로봇으로 송출하는 토글 + 안전 가드.
                    walkSendCard
                    powerCard
                    linkCard
                    imuCard
                    // v1.11.21: 워크랩에서 업데이트된 운영 / CoM / ankle / 예측 통합.
                    WalkLabIntegrationCards()
                    motorsCard
                    boardCard
                }
                filterCard
                channelToggleCard
            }
        }
    }

    // MARK: - Live mode data cards
    //
    // **UX 라이팅 원칙**:
    //   - 카드 제목: 한 단어 명사 (배터리·연결·자세 센서·모터·메인보드)
    //   - 라벨: 2~4글자 친근한 명사 (전압·통신·온도·펌웨어)
    //   - 값: 숫자 + 단위 monospaced (11.8 V, 5.2 ms, 47 °C)
    //   - 상태 칩: 일상 표현 (양호 / 부족 / 위험, 방금 / 12초 전, 모두 꺼짐 / 16개 켜짐)
    //   - 빈 상태: 진행형 안내 ("데이터 모으는 중…", "응답 기다리는 중…")
    //   - 단위 기호는 영문 (V, ms, °C, Hz) 유지 — 한글 단어보다 짧고 즉시 인식.

    /// 배터리 — 전압 큰 숫자 + 등급 칩 + 60초 sparkline.
    private var powerCard: some View {
        let voltage = store.lastTelemetry?.board?.voltageVolts
        let level = batteryLevel(voltage)
        return DFPanel(
            "배터리",
            subtitle: "전압과 흐름",
            icon: level.icon,
            tint: level.tint
        ) {
            VStack(alignment: .leading, spacing: DFSpace.xs) {
                HStack(alignment: .firstTextBaseline, spacing: DFSpace.xs) {
                    Text(voltage.map { String(format: "%.1f", $0) } ?? "—")
                        .font(.system(size: 26, weight: .black, design: .monospaced))
                        .foregroundStyle(level.tint)
                    Text("V")
                        .font(.system(size: DFFontSize.s10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DFColor.textSecondary)
                    Spacer()
                    Text(level.label)
                        .font(.system(size: DFFontSize.s9, weight: .bold))
                        .foregroundStyle(level.tint)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(Capsule().stroke(level.tint, lineWidth: 0.8))
                }
                if store.voltageHistory.count > 1 {
                    voltageSparkline.frame(height: 28)
                    Text("최근 \(store.voltageHistory.count)초")
                        .font(.system(size: DFFontSize.s9))
                        .foregroundStyle(DFColor.textSecondary)
                } else {
                    Text("데이터 모으는 중…")
                        .font(.system(size: DFFontSize.s9))
                        .foregroundStyle(DFColor.textSecondary)
                }
            }
        }
    }

    private var voltageSparkline: some View {
        let pts = store.voltageHistory
        return Chart {
            ForEach(Array(pts.enumerated()), id: \.offset) { idx, v in
                LineMark(x: .value("t", idx), y: .value("V", v))
                    .foregroundStyle(DFColor.success)
                    .interpolationMethod(.catmullRom)
                AreaMark(x: .value("t", idx), y: .value("V", v))
                    .foregroundStyle(LinearGradient(
                        colors: [DFColor.success.opacity(DFOpacity.o25),
                                 DFColor.success.opacity(0)],
                        startPoint: .top, endPoint: .bottom))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: minMaxDomain(pts, pad: 0.3))
    }

    private func minMaxDomain(_ vs: [Double], pad: Double) -> ClosedRange<Double> {
        guard let lo = vs.min(), let hi = vs.max() else { return 0...1 }
        if lo == hi { return (lo - pad)...(hi + pad) }
        return (lo - pad)...(hi + pad)
    }

    /// 실측 모드 전용 — 위 Walk Command 의 결과를 실 로봇으로 송출할지 결정하는 카드.
    /// 토글 ON + 보행 enabled + bus 있음 → 100ms 마다 다리 12관절 명령 송출.
    ///
    /// **안전 설계**:
    ///   - 기본 OFF — 사용자가 명시적으로 켜야 송출 시작.
    ///   - bus == nil 시 토글 자체 disabled.
    ///   - 송출 중일 때 빨간 경고 메시지 + 카드 외곽선 빨강.
    ///   - 모드 전환·뷰 사라짐 시 자동 OFF + Timer 정지.
    private var walkSendCard: some View {
        let isSending = sendWalkToRobot && isStoreConnected && enabled
        let tint: Color = isSending ? DFColor.danger : DFColor.textSecondary
        return DFPanel(
            "보행 명령 송출",
            subtitle: "위 명령을 실 로봇 다리 12관절로",
            icon: isSending ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash",
            tint: tint
        ) {
            VStack(alignment: .leading, spacing: DFSpace.xs) {
                Toggle(isOn: $sendWalkToRobot) {
                    Label(
                        sendWalkToRobot ? "송출 켜짐" : "송출 꺼짐",
                        systemImage: sendWalkToRobot ? "bolt.fill" : "bolt.slash"
                    )
                    .foregroundStyle(sendWalkToRobot ? DFColor.danger : DFColor.textSecondary)
                }
                .toggleStyle(.switch)
                .disabled(!isStoreConnected)
                .help(isStoreConnected
                    ? "켜면 위 슬라이더·preset 의 명령이 100ms 마다 다리 12관절로 송출됩니다. 안전한 환경에서만 사용하세요."
                    : "로봇 연결 후 사용 가능합니다.")
                .onChange(of: sendWalkToRobot) { _, _ in updateWalkSender() }
                .onChange(of: enabled) { _, _ in updateWalkSender() }

                if !isStoreConnected {
                    Text("로봇이 연결되지 않아 송출할 수 없습니다.")
                        .font(.system(size: DFFontSize.s9))
                        .foregroundStyle(DFColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if isSending {
                    Text("⚠ 슬라이더·preset 변경이 즉시 모터로 송출됩니다. ‘쉼’ preset 또는 토글을 꺼서 중단하세요.")
                        .font(.system(size: DFFontSize.s9, weight: .semibold))
                        .foregroundStyle(DFColor.danger)
                        .fixedSize(horizontal: false, vertical: true)
                } else if sendWalkToRobot && !enabled {
                    Text("‘보행 시작’ 또는 preset 을 눌러 동작을 시작하면 송출이 시작됩니다.")
                        .font(.system(size: DFFontSize.s9))
                        .foregroundStyle(DFColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("OFF: 슬라이더 변경은 차트(실 IMU)만 영향. 실 모터는 움직이지 않습니다.")
                        .font(.system(size: DFFontSize.s9))
                        .foregroundStyle(DFColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private struct BatteryLevel { let label: String; let tint: Color; let icon: String }

    /// 배터리 등급 기준 — ROBOTIS-OP2 (3S Li-ion, 만충 12.6V, 안전 하한 10.5V).
    private func batteryLevel(_ v: Double?) -> BatteryLevel {
        guard let v else { return .init(label: "확인 중", tint: DFColor.textSecondary, icon: "battery.0percent") }
        if v >= 11.5 { return .init(label: "양호", tint: DFColor.success, icon: "battery.100percent") }
        if v >= 10.5 { return .init(label: "부족", tint: DFColor.warning, icon: "battery.50percent") }
        return .init(label: "위험", tint: DFColor.danger, icon: "battery.25percent")
    }

    /// 연결 — 주소, 연결 시간, 응답 속도, 통신 성공률.
    private var linkCard: some View {
        DFPanel(
            "연결",
            subtitle: "로봇과의 통신 상태",
            icon: "network",
            tint: DFColor.accent
        ) {
            VStack(alignment: .leading, spacing: DFSpace.xs) {
                metaRow("주소", endpointLabel(store.activeEndpoint))
                metaRow("연결 시간", store.connectedAt.map { Self.fmtDuration(-$0.timeIntervalSinceNow) } ?? "—")
                metaRow("응답 속도",
                        store.lastRoundTripMs.map { String(format: "%.1f ms", $0) } ?? "—",
                        color: rttColor(store.lastRoundTripMs))
                metaRow("통신",
                        "성공 \(store.successCount)회 · 실패 \(store.failureCount)회",
                        color: store.failureCount == 0 ? DFColor.textPrimary : DFColor.warning)
            }
        }
    }

    private func endpointLabel(_ ep: Endpoint?) -> String {
        guard let ep else { return "—" }
        switch ep {
        case .usbSerial(let path):
            // 풀 path 는 너무 길어서 마지막 segment 만. 사용자에겐 그게 더 식별성 높음.
            let comp = (path as NSString).lastPathComponent
            return "USB · \(comp)"
        case .network(let host, let port):
            return "\(host):\(port)"
        }
    }

    private func rttColor(_ ms: Double?) -> Color {
        guard let ms else { return DFColor.textPrimary }
        if ms < 10 { return DFColor.success }
        if ms < 50 { return DFColor.textPrimary }
        if ms < 200 { return DFColor.warning }
        return DFColor.danger
    }

    /// 자세 센서 — CM-740 IMU 의 출처/주기/응답 상태.
    private var imuCard: some View {
        DFPanel(
            "자세 센서",
            subtitle: "CM-740 IMU",
            icon: "gyroscope",
            tint: DFColor.success
        ) {
            VStack(alignment: .leading, spacing: DFSpace.xs) {
                metaRow("출처", "레지스터 38–49번")
                metaRow("갱신", "초당 5회")
                metaRow("마지막 수신",
                        store.lastImuSuccessAt.map { Self.fmtRel($0) } ?? "신호 없음",
                        color: store.isImuStale ? DFColor.warning : DFColor.textPrimary)
                metaRow("수집 샘플", "\(data.gyroX.samples.count)개")
                if store.imuConsecutiveFailures > 0 {
                    metaRow("연속 실패",
                            "\(store.imuConsecutiveFailures)회",
                            color: DFColor.danger)
                }
                metaRow("측정 범위", "±2000 °/s · ±2 g")
                Divider().padding(.vertical, 2)
                Text("측정 범위는 16비트 정수 기준으로 가정한 값입니다. 실제 로봇에서 검증 후 정정 예정 (cm.rs:166).")
                    .font(.system(size: DFFontSize.s9))
                    .foregroundStyle(DFColor.textSecondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 모터(관절) — 응답 개수, 토크 상태, 평균/최고 온도.
    private var motorsCard: some View {
        let joints = store.lastTelemetry?.joints ?? [:]
        let total = joints.count
        let torqueOn = joints.values.filter { $0.torqueEnabled }.count
        let avgTempInt: Int? = joints.isEmpty ? nil :
            Int(joints.values.reduce(0) { $0 + Int($1.presentTemperature) } / max(1, joints.count))
        let hottest: (JointID, JointState)? = joints
            .max { $0.value.presentTemperature < $1.value.presentTemperature }
            .map { ($0.key, $0.value) }
        return DFPanel(
            "모터",
            subtitle: "관절 상태",
            icon: "gearshape.2",
            tint: DFColor.torque
        ) {
            VStack(alignment: .leading, spacing: DFSpace.xs) {
                metaRow("응답 중", "20개 중 \(total)개")
                metaRow("힘 들어감",
                        torqueOn == 0 ? "모두 꺼짐" : "\(torqueOn)개 켜짐",
                        color: torqueOn == 0 ? DFColor.textSecondary : DFColor.torque)
                if let t = avgTempInt {
                    metaRow("평균 온도", "\(t) °C", color: tempColor(Double(t)))
                }
                if let (jid, j) = hottest {
                    metaRow("가장 뜨거운",
                            jointShortName(jid),
                            color: tempColor(Double(j.presentTemperature)))
                    HStack {
                        Spacer()
                        Text("\(j.presentTemperature) °C")
                            .font(.system(size: DFFontSize.s10, weight: .bold, design: .monospaced))
                            .foregroundStyle(tempColor(Double(j.presentTemperature)))
                    }
                }
                if total == 0 {
                    Text("관절 응답 기다리는 중…")
                        .font(.system(size: DFFontSize.s9))
                        .foregroundStyle(DFColor.textSecondary)
                }
            }
        }
    }

    /// 관절 ID 의 사용자 친화적 짧은 이름. `R_KNEE` → `오른 무릎`.
    private func jointShortName(_ id: JointID) -> String {
        switch id {
        case .rShoulderPitch: return "오른 어깨 앞뒤"
        case .lShoulderPitch: return "왼 어깨 앞뒤"
        case .rShoulderRoll:  return "오른 어깨 옆"
        case .lShoulderRoll:  return "왼 어깨 옆"
        case .rElbow:         return "오른 팔꿈치"
        case .lElbow:         return "왼 팔꿈치"
        case .rHipYaw:        return "오른 골반 회전"
        case .lHipYaw:        return "왼 골반 회전"
        case .rHipRoll:       return "오른 골반 옆"
        case .lHipRoll:       return "왼 골반 옆"
        case .rHipPitch:      return "오른 골반 앞뒤"
        case .lHipPitch:      return "왼 골반 앞뒤"
        case .rKnee:          return "오른 무릎"
        case .lKnee:          return "왼 무릎"
        case .rAnklePitch:    return "오른 발목 앞뒤"
        case .lAnklePitch:    return "왼 발목 앞뒤"
        case .rAnkleRoll:     return "오른 발목 옆"
        case .lAnkleRoll:     return "왼 발목 옆"
        case .headPan:        return "머리 좌우"
        case .headTilt:       return "머리 위아래"
        }
    }

    private func tempColor(_ c: Double) -> Color {
        if c >= 65 { return DFColor.danger }
        if c >= 55 { return DFColor.warning }
        if c >= 40 { return DFColor.torque }
        return DFColor.success
    }

    /// 메인보드 — CM-730/740 모델, 펌웨어 버전, 버튼 상태.
    private var boardCard: some View {
        let board = store.lastTelemetry?.board
        return DFPanel(
            "메인보드",
            subtitle: "로봇 컨트롤러",
            icon: "cpu",
            tint: DFColor.info
        ) {
            VStack(alignment: .leading, spacing: DFSpace.xs) {
                metaRow("모델", board.map { boardModelLabel($0.modelNumber) } ?? "—")
                metaRow("펌웨어", board.map { "v\($0.version)" } ?? "—")
                metaRow("버튼", board.map { buttonLabel($0.button) } ?? "—")
            }
        }
    }

    private func boardModelLabel(_ model: UInt16) -> String {
        switch model {
        case 730: return "CM-730 · 1세대"
        case 740: return "CM-740 · 2세대"
        default:  return "모델 \(model)"
        }
    }

    private func buttonLabel(_ bits: UInt8) -> String {
        // CM-740 펌웨어: bit 0 = MODE, bit 1 = START, bit 2 = USER.
        // 버튼 이름은 로봇 본체에 인쇄된 문구 그대로 (사용자가 보고 그대로 인식).
        var labels: [String] = []
        if bits & 0b001 != 0 { labels.append("MODE") }
        if bits & 0b010 != 0 { labels.append("START") }
        if bits & 0b100 != 0 { labels.append("USER") }
        return labels.isEmpty ? "안 눌림" : labels.joined(separator: " + ")
    }

    /// Generic compact key-value row used across all live cards.
    private func metaRow(_ label: String, _ value: String, color: Color = DFColor.textPrimary) -> some View {
        HStack {
            Text(label)
                .font(.system(size: DFFontSize.s9, design: .monospaced))
                .foregroundStyle(DFColor.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: DFFontSize.s10, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private static func fmtRel(_ d: Date) -> String {
        let secs = -d.timeIntervalSinceNow
        if secs < 1 { return "방금" }
        if secs < 60 { return String(format: "%.0f초 전", secs) }
        if secs < 3600 { return String(format: "%.0f분 전", secs / 60) }
        return String(format: "%.0f시간 전", secs / 3600)
    }

    private static func fmtDuration(_ secs: TimeInterval) -> String {
        let s = max(0, Int(secs))
        if s < 60 { return "\(s)초" }
        if s < 3600 { return "\(s / 60)분 \(s % 60)초" }
        return "\(s / 3600)시간 \(s / 60 % 60)분"
    }

    private var commandCard: some View {
        DFPanel(
            "Walk Command",
            subtitle: "preset 또는 직접 입력",
            icon: "figure.walk",
            tint: DFColor.accent
        ) {
            VStack(alignment: .leading, spacing: DFSpace.sm) {
                // **Phase G12 (Codex audit 4th pass, 2026-05-15)**: preset quick-select.
                // 사용자가 보행 진단 의도를 명확히 — 6개 preset 클릭 시 cmdX/Y/A 자동 채움.
                Text("PRESET")
                    .font(.system(size: DFFontSize.s9, weight: .bold, design: .monospaced))
                    .foregroundStyle(DFColor.textSecondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 4)], spacing: 4) {
                    ForEach(WalkLabPreset.allCases) { preset in
                        Button(action: { applyPreset(preset) }) {
                            VStack(spacing: 2) {
                                Image(systemName: preset.icon)
                                    .font(.system(size: DFFontSize.s10))
                                Text(preset.label)
                                    .font(.system(size: DFFontSize.s9, design: .monospaced))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                            .frame(maxWidth: .infinity)
                            .background(activePreset == preset
                                ? DFColor.accent.opacity(DFOpacity.o20)
                                : DFColor.elev2)
                            .overlay(
                                RoundedRectangle(cornerRadius: DFRadius.xs)
                                    .stroke(activePreset == preset
                                        ? DFColor.accent
                                        : DFColor.textSecondary.opacity(DFOpacity.o20),
                                            lineWidth: 0.5)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: DFRadius.xs))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Divider().padding(.vertical, 2)
                Text("MANUAL")
                    .font(.system(size: DFFontSize.s9, weight: .bold, design: .monospaced))
                    .foregroundStyle(DFColor.textSecondary)
                numericRow(label: "x", unit: "m/cyc", value: $cmdX, range: -0.05...0.05, step: 0.005, fmt: "%+.3f")
                numericRow(label: "y", unit: "m/cyc", value: $cmdY, range: -0.03...0.03, step: 0.005, fmt: "%+.3f")
                numericRow(label: "a", unit: "rad/cyc", value: $cmdA, range: -0.3...0.3, step: 0.01, fmt: "%+.3f")
            }
            .onChange(of: cmdX) { _, _ in pushCommand(); activePreset = nil }
            .onChange(of: cmdY) { _, _ in pushCommand(); activePreset = nil }
            .onChange(of: cmdA) { _, _ in pushCommand(); activePreset = nil }
        }
    }

    /// **Phase G12 (2026-05-15)**: preset 클릭 시 cmdX/Y/A 를 preset 의 walk command 로 자동
    /// 채움. WalkLabPreset.command 의 (x, y, a) 가 cycle 당 이동량 — diagnostic engine 의
    /// numeric input 과 단위 호환.
    private func applyPreset(_ preset: WalkLabPreset) {
        let cmd = preset.command
        cmdX = cmd.x
        cmdY = cmd.y
        cmdA = cmd.a
        activePreset = preset
        // onChange 가 activePreset 을 nil 로 되돌릴 수 있어 다시 설정.
        DispatchQueue.main.async { activePreset = preset }
        pushCommand()
    }

    private var noiseCard: some View {
        DFPanel(
            "Synthetic IMU",
            subtitle: "white Gaussian noise σ",
            icon: "waveform.path.ecg",
            tint: DFColor.info
        ) {
            VStack(alignment: .leading, spacing: DFSpace.sm) {
                numericRow(label: "gyro σ", unit: "rad/s", value: $gyroNoiseSigma,
                           range: 0.0...0.2, step: 0.005, fmt: "%.3f")
                numericRow(label: "accel σ", unit: "m/s²", value: $accelNoiseSigma,
                           range: 0.0...0.5, step: 0.01, fmt: "%.3f")
                Text("실 로봇 IMU FFI(v1.1) 추가 전 합성 모드. WalkEngine 의 발 trajectory 로부터 finite-diff + ZMP 근사.")
                    .font(.system(size: DFFontSize.s9, design: .monospaced))
                    .foregroundStyle(DFColor.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .onChange(of: gyroNoiseSigma) { _, v in generator.gyroNoiseSigma = v }
            .onChange(of: accelNoiseSigma) { _, v in generator.accelNoiseSigma = v }
        }
    }

    private var filterCard: some View {
        DFPanel(
            "Complementary Filter",
            subtitle: "α · roll/pitch 추정",
            icon: "function",
            tint: DFColor.torque
        ) {
            VStack(alignment: .leading, spacing: DFSpace.sm) {
                numericRow(label: "α (gyro weight)", unit: "", value: $filterAlpha,
                           range: 0.50...0.999, step: 0.005, fmt: "%.3f")
                HStack {
                    Text("τ ≈").font(.system(size: DFFontSize.s10, design: .monospaced))
                        .foregroundStyle(DFColor.textSecondary)
                    Text("\(timeConstantMs) ms")
                        .font(.system(size: DFFontSize.s10, weight: .bold, design: .monospaced))
                        .foregroundStyle(DFColor.torque)
                    Spacer()
                    Text("@ \(sampleRateHz) Hz")
                        .font(.system(size: DFFontSize.s9, design: .monospaced))
                        .foregroundStyle(DFColor.textSecondary)
                }
                DFButton(.ghost, size: .small, action: { filter.reset() }) {
                    HStack(spacing: DFSpace.xs) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("필터 리셋")
                    }
                }
            }
            .onChange(of: filterAlpha) { _, v in filter.gyroWeight = v }
        }
    }

    private var channelToggleCard: some View {
        DFPanel("채널 표시", icon: "eye", tint: DFColor.textSecondary) {
            VStack(alignment: .leading, spacing: DFSpace.xs) {
                channelToggle("gyro.x", color: gyroX_color, isOn: $showGx)
                channelToggle("gyro.y", color: gyroY_color, isOn: $showGy)
                channelToggle("gyro.z", color: gyroZ_color, isOn: $showGz)
                Divider().padding(.vertical, 2)
                channelToggle("accel.x", color: accelX_color, isOn: $showAx)
                channelToggle("accel.y", color: accelY_color, isOn: $showAy)
                channelToggle("accel.z", color: accelZ_color, isOn: $showAz)
                Divider().padding(.vertical, 2)
                channelToggle("filter.roll", color: filterRoll_color, isOn: $showFilterRoll)
                channelToggle("filter.pitch", color: filterPitch_color, isOn: $showFilterPitch)
                channelToggle("acc.roll", color: accRoll_color, isOn: $showAccRoll)
                channelToggle("acc.pitch", color: accPitch_color, isOn: $showAccPitch)
            }
        }
    }

    private func channelToggle(_ label: String, color: Color, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: DFSpace.xs2) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: 12, height: 2)
                Text(label)
                    .font(.system(size: DFFontSize.s10, design: .monospaced))
            }
        }
        .toggleStyle(.checkbox)
        .controlSize(.mini)
    }

    // MARK: - Center panel (charts)

    private var centerPanel: some View {
        VStack(spacing: DFSpace.md) {
            TimeSeriesStripChart(
                channels: [
                    .init(id: "gx", label: "gyro.x", color: gyroX_color, samples: visibleSamples(data.gyroX, unit: unitGyro), visible: showGx),
                    .init(id: "gy", label: "gyro.y", color: gyroY_color, samples: visibleSamples(data.gyroY, unit: unitGyro), visible: showGy),
                    .init(id: "gz", label: "gyro.z", color: gyroZ_color, samples: visibleSamples(data.gyroZ, unit: unitGyro), visible: showGz),
                ],
                title: "GYROSCOPE",
                yUnit: unitGyro.label,
                height: 160
            )

            TimeSeriesStripChart(
                channels: [
                    .init(id: "ax", label: "accel.x", color: accelX_color, samples: visibleSamples(data.accelX, unit: unitAccel), visible: showAx),
                    .init(id: "ay", label: "accel.y", color: accelY_color, samples: visibleSamples(data.accelY, unit: unitAccel), visible: showAy),
                    .init(id: "az", label: "accel.z", color: accelZ_color, samples: visibleSamples(data.accelZ, unit: unitAccel), visible: showAz),
                ],
                title: "ACCELEROMETER",
                yUnit: unitAccel.label,
                height: 160
            )

            TimeSeriesStripChart(
                channels: [
                    .init(id: "fr", label: "filter.roll",  color: filterRoll_color,  samples: visibleSamples(data.filterRoll,  unit: unitAngle), visible: showFilterRoll),
                    .init(id: "fp", label: "filter.pitch", color: filterPitch_color, samples: visibleSamples(data.filterPitch, unit: unitAngle), visible: showFilterPitch),
                    .init(id: "ar", label: "acc.roll",     color: accRoll_color,     samples: visibleSamples(data.accRoll,     unit: unitAngle), visible: showAccRoll),
                    .init(id: "ap", label: "acc.pitch",    color: accPitch_color,    samples: visibleSamples(data.accPitch,    unit: unitAngle), visible: showAccPitch),
                ],
                title: "ATTITUDE ESTIMATE",
                yUnit: unitAngle.label,
                height: 140
            )

            PhaseRibbon(marks: data.phaseMarks, height: 28)
        }
    }

    // MARK: - Right panel (live numerics + stats + log)

    private var rightPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DFSpace.md) {
                liveNumericCard
                statsCard
                sampleLogCard
            }
        }
    }

    private var liveNumericCard: some View {
        DFPanel("Live", icon: "waveform", tint: DFColor.accent) {
            VStack(alignment: .leading, spacing: DFSpace.xs) {
                liveRow("gyro.x", data.gyroX.samples.last?.v, scale: unitGyro)
                liveRow("gyro.y", data.gyroY.samples.last?.v, scale: unitGyro)
                liveRow("gyro.z", data.gyroZ.samples.last?.v, scale: unitGyro)
                Divider()
                liveRow("accel.x", data.accelX.samples.last?.v, scale: unitAccel)
                liveRow("accel.y", data.accelY.samples.last?.v, scale: unitAccel)
                liveRow("accel.z", data.accelZ.samples.last?.v, scale: unitAccel)
                Divider()
                liveRow("filter.roll",  data.filterRoll.samples.last?.v,  scale: unitAngle)
                liveRow("filter.pitch", data.filterPitch.samples.last?.v, scale: unitAngle)
                phaseLiveRow
            }
        }
    }

    /// "phase" 행 — scalar / integer (단위 변환 불필요).
    private var phaseLiveRow: some View {
        HStack {
            Text("phase")
                .font(.system(size: DFFontSize.s10, design: .monospaced))
                .foregroundStyle(DFColor.textSecondary)
                .frame(width: 100, alignment: .leading)
            Spacer()
            Text(data.phaseMarks.last.map { "\($0.phase.rawValue)" } ?? "—")
                .font(.system(size: DFFontSize.s11, weight: .semibold, design: .monospaced))
                .foregroundStyle(DFColor.textPrimary)
            Text("")
                .frame(width: 38)
        }
    }

    private func liveRow<U: UnitConvertible>(_ label: String, _ v: Double?, scale: U) -> some View {
        HStack {
            Text(label)
                .font(.system(size: DFFontSize.s10, design: .monospaced))
                .foregroundStyle(DFColor.textSecondary)
                .frame(width: 100, alignment: .leading)
            Spacer()
            Text(v.map { String(format: "%+10.4f", scale.convert($0)) } ?? "—")
                .font(.system(size: DFFontSize.s11, weight: .semibold, design: .monospaced))
                .foregroundStyle(DFColor.textPrimary)
            Text(scale.label)
                .font(.system(size: DFFontSize.s9, design: .monospaced))
                .foregroundStyle(DFColor.textSecondary)
                .frame(width: 38, alignment: .trailing)
        }
    }

    private var statsCard: some View {
        DFPanel("Stats (\(data.gyroX.samples.count) samples)",
                icon: "chart.bar.doc.horizontal",
                tint: DFColor.info) {
            VStack(alignment: .leading, spacing: DFSpace.micro2) {
                statsHeader
                statsRow("gyro.x",  data.gyroX.stats,  scale: unitGyro)
                statsRow("gyro.y",  data.gyroY.stats,  scale: unitGyro)
                statsRow("gyro.z",  data.gyroZ.stats,  scale: unitGyro)
                statsRow("accel.x", data.accelX.stats, scale: unitAccel)
                statsRow("accel.y", data.accelY.stats, scale: unitAccel)
                statsRow("accel.z", data.accelZ.stats, scale: unitAccel)
            }
        }
    }

    private var statsHeader: some View {
        HStack(spacing: DFSpace.xs) {
            Text("").frame(width: 56, alignment: .leading)
            Text("μ").frame(width: 50, alignment: .trailing)
            Text("σ").frame(width: 44, alignment: .trailing)
            Text("min").frame(width: 50, alignment: .trailing)
            Text("max").frame(width: 50, alignment: .trailing)
        }
        .font(.system(size: DFFontSize.s9, weight: .bold, design: .monospaced))
        .foregroundStyle(DFColor.textSecondary)
    }

    private func statsRow<U: UnitConvertible>(_ label: String, _ stats: SignalStatistics, scale: U) -> some View {
        HStack(spacing: DFSpace.xs) {
            Text(label)
                .font(.system(size: DFFontSize.s9, design: .monospaced))
                .foregroundStyle(DFColor.textSecondary)
                .frame(width: 56, alignment: .leading)
            Text(String(format: "%+.3f", scale.convert(stats.mean))).frame(width: 50, alignment: .trailing)
            Text(String(format: "%.3f",  scale.convert(stats.stdDev))).frame(width: 44, alignment: .trailing)
            Text(String(format: "%+.2f", scale.convert(stats.min))).frame(width: 50, alignment: .trailing)
            Text(String(format: "%+.2f", scale.convert(stats.max))).frame(width: 50, alignment: .trailing)
        }
        .font(.system(size: DFFontSize.s9, design: .monospaced))
        .foregroundStyle(DFColor.textPrimary.opacity(DFOpacity.o85))
    }

    private var sampleLogCard: some View {
        DFPanel("Last frames", icon: "list.bullet.rectangle", tint: DFColor.textSecondary) {
            VStack(alignment: .leading, spacing: DFSpace.micro) {
                let tail = data.recentLog.suffix(8).reversed()
                ForEach(Array(tail.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: DFFontSize.s9, design: .monospaced))
                        .foregroundStyle(DFColor.textPrimary.opacity(DFOpacity.o85))
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: - Numeric row (label + slider + value)

    private func numericRow(label: String, unit: String,
                            value: Binding<Double>,
                            range: ClosedRange<Double>,
                            step: Double,
                            fmt: String) -> some View {
        VStack(alignment: .leading, spacing: DFSpace.micro2) {
            HStack {
                Text(label)
                    .font(.system(size: DFFontSize.s10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DFColor.textSecondary)
                Spacer()
                Text(String(format: fmt, value.wrappedValue))
                    .font(.system(size: DFFontSize.s11, weight: .bold, design: .monospaced))
                    .foregroundStyle(DFColor.textPrimary)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: DFFontSize.s9, design: .monospaced))
                        .foregroundStyle(DFColor.textSecondary)
                }
            }
            HStack(spacing: DFSpace.xs) {
                Slider(value: value, in: range, step: step)
                    .controlSize(.mini)
                    .tint(DFColor.accent)
                Stepper("", value: value, in: range, step: step)
                    .labelsHidden()
                    .controlSize(.mini)
            }
        }
    }

    // MARK: - Engine control

    private func toggleRun() {
        if enabled { stop() } else { start() }
    }

    private func start() {
        switch source {
        case .preview:
            enabled = true
            pushCommand()
            ticker?.invalidate()
            let dt = 1.0 / Double(sampleRateHz)
            ticker = Timer.scheduledTimer(withTimeInterval: dt, repeats: true) { _ in
                Task { @MainActor in previewTick(dt: dt) }
            }
        case .live:
            // 실측 모드는 ConnectionStore 가 IMU 폴링 중. ‘기록 활성화’ + WalkEngine 도
            // 함께 시작 — walk sender 가 켜져 있으면 실 로봇으로 명령이 송출됨.
            guard isStoreConnected else { return }
            enabled = true
            liveStartedAt = Date()
            lastLiveImuTimestamp = nil
            pushCommand()       // WalkEngine 에 enabled=true 알림 (tick 결과가 의미)
            updateWalkSender()  // sendWalkToRobot 켜져 있으면 송출 Timer 시작.
        }
    }

    private func stop() {
        enabled = false
        ticker?.invalidate()
        ticker = nil
        engine.setCommand(x: cmdX, y: cmdY, a: cmdA, enabled: false)
        updateWalkSender()  // enabled==false 이면 walk sender 자동 정지.
    }

    private func restart() {
        stop(); start()
    }

    private func reset() {
        stop()
        simTime = 0
        sampleId = 0
        lastFoot = nil
        filter.reset()
        engine = WalkEngine()
        liveStartedAt = nil
        lastLiveImuTimestamp = nil
        data.clear()
    }

    private func pushCommand() {
        // Walk command 는 양쪽 모드에서 WalkEngine 갱신 — preview 는 차트 생성용,
        // live 는 walk sender 가 ticking 할 때 다리 명령 산출용. 명령 전송 자체는
        // sendWalkToRobot 토글이 통제 (walkSendCard).
        engine.setCommand(x: cmdX, y: cmdY, a: cmdA, enabled: enabled)
    }

    // MARK: - Live walk sender (실측 모드 전용 — 실 로봇 다리 12관절 송출)

    /// Walk sender Timer 의 활성화 조건을 재평가하고 start/stop 결정.
    /// - 조건 모두 true: source==.live, sendWalkToRobot, enabled, bus != nil.
    /// - 토글 / enabled / source / bus 변경 시마다 호출.
    private func updateWalkSender() {
        let shouldRun = (source == .live) && sendWalkToRobot && enabled && isStoreConnected
        if shouldRun {
            startWalkSender()
        } else {
            stopWalkSender()
        }
    }

    private func startWalkSender() {
        walkSenderTicker?.invalidate()
        // 100ms cadence — WalkLab.swift 와 동일. 너무 빠르면 모터 부담, 너무 느리면 swing 끊김.
        walkSenderTicker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in walkSenderTick() }
        }
    }

    private func stopWalkSender() {
        walkSenderTicker?.invalidate()
        walkSenderTicker = nil
    }

    /// 매 tick — WalkEngine.tick(100ms) → walkPoseFromSample → 다리 12관절 setPosition.
    /// **WalkLab.swift 의 walkPoseFromSample 과 동일 alg** (코드 중복은 차후 ForgeCore 로 추출).
    @MainActor
    private func walkSenderTick() {
        guard let bus = store.bus, enabled, sendWalkToRobot else {
            stopWalkSender()
            return
        }
        let sample = engine.tick(dtMs: 100)
        let pose = walkPoseFromSample(sample)
        let legJoints: [JointID] = [
            .rHipYaw, .lHipYaw, .rHipRoll, .lHipRoll,
            .rHipPitch, .lHipPitch, .rKnee, .lKnee,
            .rAnklePitch, .lAnklePitch, .rAnkleRoll, .lAnkleRoll
        ]
        for j in legJoints {
            _ = try? bus.setPosition(j, raw: UInt16(clamping: pose.raw(j)))
        }
    }

    /// WalkLab.swift 와 동일한 단순 IK — walkReady 기반에 phase swing 적용.
    /// 별도 IK 모듈 추출 전까지 임시 중복. v1.6 에서 ForgeCore.WalkIK 로 옮길 예정.
    private func walkPoseFromSample(_ s: FootTargets) -> RobotPose {
        let phaseT = s.elapsedMs / 1000.0
        let swing = sin(phaseT * 2.0 * .pi) * 0.15  // ±0.15 rad ~ ±8.6°
        var p = RobotPose.walkReady.positions
        let lHipPitchBase = p[.lHipPitch] ?? 1896
        let rHipPitchBase = p[.rHipPitch] ?? 2200
        p[.lHipPitch] = lHipPitchBase + Int(swing * 2048.0 / .pi)
        p[.rHipPitch] = rHipPitchBase - Int(swing * 2048.0 / .pi)
        return RobotPose(positions: p)
    }

    private func stepOnce() {
        guard source == .preview else { return }
        let dt = 1.0 / Double(sampleRateHz)
        // 한 번만 켰다 끄기 — engine 의 tick 은 enabled 와 무관하지만 일관성 위해.
        engine.setCommand(x: cmdX, y: cmdY, a: cmdA, enabled: true)
        previewTick(dt: dt)
        engine.setCommand(x: cmdX, y: cmdY, a: cmdA, enabled: false)
    }

    // MARK: - Tick handlers per source

    /// 미리보기 모드 — WalkEngine + SyntheticImuGenerator 으로 합성 sample 생성.
    private func previewTick(dt: Double) {
        let dtMs = UInt32(max(1, Int(dt * 1000)))
        let foot = engine.tick(dtMs: dtMs)
        simTime += dt

        let cmd = SyntheticImuGenerator.Command(x: cmdX, y: cmdY, a: cmdA)
        let imu = generator.sample(prev: lastFoot, curr: foot, dtSeconds: dt, command: cmd)
        lastFoot = foot
        filter.update(imu, dtSeconds: dt)

        // Accelerometer-only attitude (즉시 추정, drift 없음 — filter 와 비교용).
        let accRoll  = atan2(imu.accel.y, imu.accel.z)
        let accPitch = atan2(-imu.accel.x, (imu.accel.y * imu.accel.y + imu.accel.z * imu.accel.z).squareRoot())

        data.append(
            t: simTime, idCounter: &sampleId,
            gyro: imu.gyro, accel: imu.accel,
            filterRoll: filter.rollRad, filterPitch: filter.pitchRad,
            accRoll: accRoll, accPitch: accPitch,
            phase: foot.phase, foot: foot
        )
    }

    /// 실측 모드 — `TelemetrySnapshot` 의 새 IMU sample 을 chart 버퍼에 append.
    /// onReceive 에서 호출. `enabled == true` 일 때만 기록 (사용자가 "▶ 실행" 누른 상태).
    ///
    /// **변환** (v1.7, 2026-05-17 정정): ROBOTIS-OP2 firmware 기준 10-bit ADC raw u16,
    /// center 512. `gyroXDps` / `accelXG` accessor 가 (raw-512) × LSB scale 을 자동 처리.
    /// atan2 비율은 scale 무관이라 raw 부호만 ROBOTIS RL=X / FB=Y 매핑에 맞으면 정확.
    private func liveAppend(_ snap: TelemetrySnapshot) {
        guard source == .live, enabled, let imu = snap.imu else { return }
        // ConnectionStore 가 같은 sample 을 publish 할 수도 있어 timestamp 기준 dedup.
        if let last = lastLiveImuTimestamp, snap.timestamp <= last { return }
        lastLiveImuTimestamp = snap.timestamp

        let start = liveStartedAt ?? snap.timestamp
        if liveStartedAt == nil { liveStartedAt = start }
        let t = snap.timestamp.timeIntervalSince(start)
        simTime = t

        // ImuRaw → SI units. gyroXDps 는 (raw-512) × (2000/512) °/s → rad/s 변환.
        let degToRad = Double.pi / 180.0
        let gyro = SIMD3<Double>(
            imu.gyroXDps * degToRad,
            imu.gyroYDps * degToRad,
            imu.gyroZDps * degToRad
        )
        // accel: g → m/s². accelXG = (raw-512) × (1/256) (provisional 10-bit ADC scale).
        let gToMs2 = 9.80665
        let accel = SIMD3<Double>(
            imu.accelXG * gToMs2,
            imu.accelYG * gToMs2,
            imu.accelZG * gToMs2
        )

        // dt 추정: 직전 sample 과의 timestamp 간격. 첫 sample 은 5Hz 가정.
        let dt: Double
        if data.gyroX.samples.last?.t != nil, let prevT = data.gyroX.samples.last?.t {
            dt = max(0.001, t - prevT)
        } else {
            dt = 0.2  // ConnectionStore default cadence.
        }

        // ComplementaryFilterSwift 는 preview 와 공유 — live 에서도 동일 필터 시각화.
        let imuSample = ImuSampleSwift(gyro: gyro, accel: accel)
        filter.update(imuSample, dtSeconds: dt)

        // ROBOTIS axis convention: RL_ACCEL=X (roll), FB_ACCEL=Y (pitch).
        let accRoll  = atan2(accel.x, (accel.y * accel.y + accel.z * accel.z).squareRoot())
        let accPitch = atan2(accel.y, (accel.x * accel.x + accel.z * accel.z).squareRoot())

        // 실측 모드는 WalkEngine phase 가 없음 — phase0 (idle) 로 표기. foot=nil.
        data.append(
            t: t, idCounter: &sampleId,
            gyro: gyro, accel: accel,
            filterRoll: filter.rollRad, filterPitch: filter.pitchRad,
            accRoll: accRoll, accPitch: accPitch,
            phase: .phase0, foot: nil
        )
    }

    // MARK: - CSV export

    private func exportCsv() {
        let csv = data.toCsv(gyroUnit: unitGyro, accelUnit: unitAccel, angleUnit: unitAngle)
        let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("walk-diag-\(ts).csv")
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            lastExportPath = url.path
            withAnimation { showExportToast = true }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                withAnimation { showExportToast = false }
            }
        } catch {
            lastExportPath = "export 실패: \(error.localizedDescription)"
            withAnimation { showExportToast = true }
        }
    }

    @ViewBuilder
    private var toast: some View {
        if showExportToast, let path = lastExportPath {
            HStack(spacing: DFSpace.xs2) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DFColor.success)
                Text(path)
                    .font(.system(size: DFFontSize.s10, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 480)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(DFColor.success.opacity(DFOpacity.strong), lineWidth: 0.5))
            .padding(.top, 64)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Helpers

    private var timeConstantMs: Int {
        // τ = dt × α/(1−α). dt = 1000/sampleRateHz ms.
        let dt = 1000.0 / Double(sampleRateHz)
        let alpha = max(0.001, min(0.999, filterAlpha))
        return Int(dt * alpha / (1 - alpha))
    }

    private func visibleSamples<U: UnitConvertible>(_ buffer: TimeSeriesBuffer, unit: U) -> [TimeSample] {
        buffer.samples.map { TimeSample(id: $0.id, t: $0.t, v: unit.convert($0.v)) }
    }

    // MARK: - Channel colors

    // DFChartPalette 의미 팔레트 사용 — Sprint D 통합 (이전 로컬 RGB 제거).
    private var gyroX_color: Color { DFChartPalette.gyroX }
    private var gyroY_color: Color { DFChartPalette.gyroY }
    private var gyroZ_color: Color { DFChartPalette.gyroZ }
    private var accelX_color: Color { DFChartPalette.accelX }
    private var accelY_color: Color { DFChartPalette.accelY }
    private var accelZ_color: Color { DFChartPalette.accelZ }
    /// Filter 추정 roll/pitch — 보조 magenta/cyan.
    private var filterRoll_color: Color { DFColor.torque }
    private var filterPitch_color: Color { DFColor.info }
    /// Accelerometer 추정 (필터 전) — filter 색상의 dim 버전.
    private var accRoll_color: Color { DFColor.torque.opacity(DFOpacity.o45) }
    private var accPitch_color: Color { DFColor.info.opacity(DFOpacity.o45) }
}

// MARK: - Units

public protocol UnitConvertible {
    var label: String { get }
    func convert(_ v: Double) -> Double
}

public enum GyroUnit: UnitConvertible {
    case radPerSec, degPerSec
    public var label: String { self == .radPerSec ? "rad/s" : "deg/s" }
    public func convert(_ v: Double) -> Double { self == .radPerSec ? v : v * 180.0 / .pi }
}

public enum AccelUnit: UnitConvertible {
    case mPerSec2, g
    public var label: String { self == .mPerSec2 ? "m/s²" : "g" }
    public func convert(_ v: Double) -> Double { self == .mPerSec2 ? v : v / 9.80665 }
}

public enum AngleUnit: UnitConvertible {
    case radians, degrees
    public var label: String { self == .radians ? "rad" : "deg" }
    public func convert(_ v: Double) -> Double { self == .radians ? v : v * 180.0 / .pi }
}

// MARK: - Data source mode

/// 보행 진단의 데이터 소스. UI 상에서 "미리보기" / "실측" 두 가지로 노출.
///
/// - **preview**: SyntheticImuGenerator — `WalkEngine` 발 trajectory finite-diff +
///   Gaussian noise. 로봇 미연결에서도 동작 (보행 알고리즘 시각화 + 필터 튜닝용).
/// - **live**: `ConnectionStore.lastTelemetry?.imu` — CM-740 register 38-49 BULK READ.
///   ConnectionStore 폴링 cadence (현재 5Hz) 에 의존. 로봇 연결 + IMU 응답 필요.
public enum DiagnosticsSource: String, CaseIterable, Identifiable {
    case preview
    case live

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .preview: return "미리보기"
        case .live:    return "실측"
        }
    }

    public var icon: String {
        switch self {
        case .preview: return "play.tv"
        case .live:    return "antenna.radiowaves.left.and.right"
        }
    }

    /// 사용자에게 보일 한 줄 설명 — toolbar 우측 status badge 아래.
    public var subtitle: String {
        switch self {
        case .preview: return "합성 시뮬레이션 — 로봇 불필요"
        case .live:    return "CM-740 IMU 5Hz 실측"
        }
    }
}

// MARK: - Data store

@MainActor
final class WalkDiagnosticsData: ObservableObject {
    let gyroX = TimeSeriesBuffer(capacity: 1000)
    let gyroY = TimeSeriesBuffer(capacity: 1000)
    let gyroZ = TimeSeriesBuffer(capacity: 1000)
    let accelX = TimeSeriesBuffer(capacity: 1000)
    let accelY = TimeSeriesBuffer(capacity: 1000)
    let accelZ = TimeSeriesBuffer(capacity: 1000)
    let filterRoll = TimeSeriesBuffer(capacity: 1000)
    let filterPitch = TimeSeriesBuffer(capacity: 1000)
    let accRoll = TimeSeriesBuffer(capacity: 1000)
    let accPitch = TimeSeriesBuffer(capacity: 1000)

    @Published var phaseMarks: [PhaseRibbon.Mark] = []
    @Published var recentLog: [String] = []
    private var nextPhaseId: Int = 0

    /// IMU sample append. `foot` 은 preview 모드에서만 의미 (recentLog 의 L.z/R.z 표시) —
    /// live 모드에선 nil (FootTargets 가 internal init 만 노출 + 실 발 위치는 모르므로).
    func append(t: Double, idCounter: inout Int,
                gyro: SIMD3<Double>, accel: SIMD3<Double>,
                filterRoll: Double, filterPitch: Double,
                accRoll: Double, accPitch: Double,
                phase: WalkPhase, foot: FootTargets?) {
        gyroX.append(t: t, v: gyro.x)
        gyroY.append(t: t, v: gyro.y)
        gyroZ.append(t: t, v: gyro.z)
        accelX.append(t: t, v: accel.x)
        accelY.append(t: t, v: accel.y)
        accelZ.append(t: t, v: accel.z)
        self.filterRoll.append(t: t, v: filterRoll)
        self.filterPitch.append(t: t, v: filterPitch)
        self.accRoll.append(t: t, v: accRoll)
        self.accPitch.append(t: t, v: accPitch)

        phaseMarks.append(PhaseRibbon.Mark(id: nextPhaseId, t: t, phase: phase))
        nextPhaseId += 1
        if phaseMarks.count > 1500 {
            phaseMarks.removeFirst(phaseMarks.count - 1500)
        }

        idCounter += 1
        let footTail: String
        if let f = foot {
            footTail = String(format: " L.z=%+.3f R.z=%+.3f", f.leftXYZ.z, f.rightXYZ.z)
        } else {
            footTail = ""
        }
        let line = String(
            format: "%6.3fs ph=%d g=(%+6.3f %+6.3f %+6.3f) a=(%+6.2f %+6.2f %+6.2f)%@",
            t, phase.rawValue,
            gyro.x, gyro.y, gyro.z,
            accel.x, accel.y, accel.z,
            footTail as NSString
        )
        recentLog.append(line)
        if recentLog.count > 32 { recentLog.removeFirst(recentLog.count - 32) }

        // ObservableObject 변경 알림 — published 가 아닌 properties 를 한꺼번에 알림.
        objectWillChange.send()
    }

    func clear() {
        gyroX.clear(); gyroY.clear(); gyroZ.clear()
        accelX.clear(); accelY.clear(); accelZ.clear()
        filterRoll.clear(); filterPitch.clear()
        accRoll.clear(); accPitch.clear()
        phaseMarks.removeAll()
        recentLog.removeAll()
        nextPhaseId = 0
        objectWillChange.send()
    }

    /// CSV — 모든 sample 을 시간순으로 dump.
    func toCsv(gyroUnit: GyroUnit, accelUnit: AccelUnit, angleUnit: AngleUnit) -> String {
        var out = "# walk-diag export at \(ISO8601DateFormatter().string(from: Date()))\n"
        out += "# units: gyro=\(gyroUnit.label) accel=\(accelUnit.label) angle=\(angleUnit.label)\n"
        out += "t_s,phase,gx,gy,gz,ax,ay,az,filt_roll,filt_pitch,acc_roll,acc_pitch\n"

        let n = min(min(gyroX.samples.count, gyroY.samples.count), gyroZ.samples.count)
        for i in 0..<n {
            let t = gyroX.samples[i].t
            let phase = phaseAt(t: t)
            let row: [String] = [
                String(format: "%.4f", t),
                "\(phase)",
                String(format: "%+.6f", gyroUnit.convert(gyroX.samples[i].v)),
                String(format: "%+.6f", gyroUnit.convert(gyroY.samples[i].v)),
                String(format: "%+.6f", gyroUnit.convert(gyroZ.samples[i].v)),
                String(format: "%+.6f", accelUnit.convert(accelX.samples[i].v)),
                String(format: "%+.6f", accelUnit.convert(accelY.samples[i].v)),
                String(format: "%+.6f", accelUnit.convert(accelZ.samples[i].v)),
                String(format: "%+.6f", angleUnit.convert(filterRoll.samples[i].v)),
                String(format: "%+.6f", angleUnit.convert(filterPitch.samples[i].v)),
                String(format: "%+.6f", angleUnit.convert(accRoll.samples[i].v)),
                String(format: "%+.6f", angleUnit.convert(accPitch.samples[i].v)),
            ]
            out += row.joined(separator: ",") + "\n"
        }
        return out
    }

    private func phaseAt(t: Double) -> Int {
        // 가장 가까운 마크의 phase. O(log n) 가능하나 export 는 1회성 — O(n) 으로 단순.
        var last: UInt8 = 0
        for m in phaseMarks {
            if m.t > t { break }
            last = m.phase.rawValue
        }
        return Int(last)
    }
}
