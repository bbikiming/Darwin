import Foundation
import ForgeCore

/// 연결 상태의 health/telemetry 통계만 격리.
///
/// # 비유
///
/// 자동차 계기판은 엔진 제어 ECU 와는 별도 부품이다. 디스플레이는 계측값만 보여주고,
/// 엔진 동작 결정은 ECU 가 한다. 동일하게 이 store 는 통신 success/failure 카운터·
/// IMU/FSR/sparkline 표시용 raw 값만 보관한다. 연결 lifecycle (`connect/disconnect`) 결정은
/// `ConnectionStore` 가 한다.
///
/// # 분리 동기 (Wave 4.2.1, 사이클 V260-1)
///
/// 종전: `ConnectionStore` (1945 LOC) 안에 telemetry 통계 + IMU health + FSR + sparkline 등
/// health 관련 @Published 가 17개 산재. SwiftUI 가 store 의 어느 한 필드 변경에도 전체 view
/// graph 재평가 → 작은 통계 갱신이 큰 비용. 또한 god object 화로 변경 영향 추적 곤란.
///
/// 신규: `ConnectionHealthStore` 분리. `ConnectionStore.health` 로 expose. 기존 view 가
/// 참조하는 `store.lastSuccessAt` 같은 path 는 `ConnectionStore` 에서 backward-compat
/// computed property (delegate to `health.lastSuccessAt`) 로 유지 — view migration 불필요.
@MainActor
public final class ConnectionHealthStore: ObservableObject {

    // MARK: - 통신 통계 (telemetry loop 1Hz 갱신)

    /// 가장 최근 성공한 boardSnapshot 호출의 wall-clock 시점.
    /// 대시보드의 "마지막 통신" 표시용. 연결됨 상태에서 매 1초 갱신.
    @Published public private(set) var lastSuccessAt: Date?
    /// 연결 시작 시각 — uptime 계산용.
    @Published public private(set) var connectedAt: Date?
    /// 누적 통신 통계 (대시보드 카드).
    @Published public private(set) var successCount: Int = 0
    @Published public private(set) var failureCount: Int = 0
    /// 마지막 boardSnapshot 호출의 측정 latency (ms). 없으면 nil.
    @Published public private(set) var lastRoundTripMs: Double?

    // MARK: - IMU 전용 health

    /// IMU 는 board snapshot 과 별도 read — 같은 bus 라도 일부 펌웨어 / 모델은 IMU register
    /// 응답 안 함. 전체 watchdog 에 합치면 "연결 끊김" 으로 오진. 별도 카운터로 추적.
    @Published public private(set) var lastImuSuccessAt: Date?
    @Published public private(set) var imuConsecutiveFailures: Int = 0
    @Published public private(set) var lastImuError: String?
    /// Mac-side successful-read counter — IMU read 성공할 때마다 ++.
    @Published public private(set) var imuSequenceCount: UInt32 = 0
    /// Mac-side complementary filter (Sprint 18 Phase E, Codex 잔여 4 v1.5 minimal viable).
    @Published public private(set) var imuFilter: ImuFilter = ImuFilter()
    /// LiveGyroPanel 용 raw sample.
    @Published public private(set) var lastImuRaw: ImuRaw? = nil

    // MARK: - Bus 누적 실패 카운터

    /// 누적 bus write 실패 (setPosition / setTorque / setPGain 등).
    @Published public private(set) var busWriteFailureCount: Int = 0
    /// 누적 bus read 실패 (readImu / boardSnapshot / readState).
    @Published public private(set) var busReadFailureCount: Int = 0

    // MARK: - Sparkline (60 sample = 1 Hz 폴링 시 1분)

    @Published public private(set) var voltageHistory: [Double] = []
    @Published public private(set) var avgTempHistory: [Double] = []

    // MARK: - FSR (foot pressure) — board 미장착 시 3회 실패로 자동 disable

    @Published public private(set) var lastFsrLeft: FsrReading? = nil
    @Published public private(set) var lastFsrRight: FsrReading? = nil
    @Published public private(set) var lastFsrSuccessAt: Date? = nil
    @Published public private(set) var fsrConsecutiveFailures: Int = 0
    @Published public private(set) var fsrPollingDisabled: Bool = false

    // MARK: - 정적 임계

    /// IMU 가 5초 이상 응답 없으면 stale — UI 가 "IMU 오래됨" 라벨 표시.
    public var isImuStale: Bool {
        guard let at = lastImuSuccessAt else { return imuConsecutiveFailures > 0 }
        return Date().timeIntervalSince(at) > 5.0
    }

    /// IMU 가 3회 연속 실패 + 마지막 성공이 없거나 30초 이상 전이면 unavailable.
    public var isImuUnavailable: Bool {
        if let at = lastImuSuccessAt {
            return Date().timeIntervalSince(at) > 30.0 && imuConsecutiveFailures >= 3
        }
        return imuConsecutiveFailures >= 3
    }

    public init() {}

    // MARK: - Connect/Disconnect lifecycle

    /// 연결 성공 시 — 모든 통신 카운터 초기화 + 최초 boardSnapshot RTT 기록.
    public func recordConnected(rttMs: Double, at now: Date = Date()) {
        connectedAt = now
        lastSuccessAt = now
        successCount = 1
        failureCount = 0
        lastRoundTripMs = rttMs
    }

    /// 연결 종료 — telemetry 통계 + sparkline 만 초기화. IMU/FSR raw 는 별도 reset.
    /// (IMU scale 진단 sample 은 ConnectionStore 가 별도 관리)
    public func resetConnectionStats() {
        connectedAt = nil
        lastSuccessAt = nil
        lastRoundTripMs = nil
        voltageHistory.removeAll()
        avgTempHistory.removeAll()
    }

    /// 전체 reset — 테스트 / 명시적 reset 용. 모든 health 상태 초기화.
    public func reset() {
        lastSuccessAt = nil
        connectedAt = nil
        successCount = 0
        failureCount = 0
        lastRoundTripMs = nil
        lastImuSuccessAt = nil
        imuConsecutiveFailures = 0
        lastImuError = nil
        imuSequenceCount = 0
        imuFilter = ImuFilter()
        lastImuRaw = nil
        busWriteFailureCount = 0
        busReadFailureCount = 0
        voltageHistory.removeAll()
        avgTempHistory.removeAll()
        lastFsrLeft = nil
        lastFsrRight = nil
        lastFsrSuccessAt = nil
        fsrConsecutiveFailures = 0
        fsrPollingDisabled = false
    }

    // MARK: - 통신 성공/실패 mutator

    /// boardSnapshot 성공 — RTT + 카운터 갱신.
    public func recordSuccess(rttMs: Double, at now: Date = Date()) {
        lastRoundTripMs = rttMs
        lastSuccessAt = now
        successCount &+= 1
    }

    /// boardSnapshot 실패 — 카운터만 증가.
    public func recordFailure() {
        failureCount &+= 1
    }

    // MARK: - IMU mutator

    /// IMU read 성공 — filter update + raw 보관 + counter 리셋.
    public func recordImuSuccess(raw: ImuRaw, at now: Date = Date()) {
        imuFilter.update(raw)
        lastImuRaw = raw
        lastImuSuccessAt = now
        imuConsecutiveFailures = 0
        lastImuError = nil
        imuSequenceCount &+= 1
    }

    /// IMU read 실패 — counter / lastError 갱신 + bus read 실패 누적.
    public func recordImuFailure(error: Error) {
        imuConsecutiveFailures &+= 1
        busReadFailureCount &+= 1
        lastImuError = error.localizedDescription
    }

    // MARK: - Bus 실패 카운터 (개별 mutator)

    /// WalkLabSession 의 setPosition catch 경로 등에서 호출.
    public func bumpBusWriteFailure() {
        busWriteFailureCount &+= 1
    }

    /// IMU 외 bus read 실패 (boardSnapshot 등) 시 호출.
    public func bumpBusReadFailure() {
        busReadFailureCount &+= 1
    }

    // MARK: - Sparkline

    /// 전압 1Hz 샘플 추가 — 60개 cap.
    public func appendVoltage(_ value: Double) {
        voltageHistory.append(value)
        if voltageHistory.count > 60 { voltageHistory.removeFirst() }
    }

    /// 평균 온도 1Hz 샘플 추가 — 60개 cap.
    public func appendAvgTemp(_ value: Double) {
        avgTempHistory.append(value)
        if avgTempHistory.count > 60 { avgTempHistory.removeFirst() }
    }

    // MARK: - FSR

    /// 좌/우 FSR 성공 read — 부분 성공도 허용 (한 쪽만 success 가능).
    public func updateFsr(left: FsrReading?, right: FsrReading?, at now: Date = Date()) {
        var ok = false
        if let l = left { lastFsrLeft = l; ok = true }
        if let r = right { lastFsrRight = r; ok = true }
        if ok {
            lastFsrSuccessAt = now
            fsrConsecutiveFailures = 0
        }
    }

    /// FSR 양쪽 모두 실패 — counter 증가. 3회 도달 시 caller 가 `disableFsrPolling()` 호출.
    public func bumpFsrFailure() {
        fsrConsecutiveFailures &+= 1
    }

    /// FSR polling 자동 비활성 — board 미장착 시 spam 차단.
    public func disableFsrPolling() {
        fsrPollingDisabled = true
    }
}
