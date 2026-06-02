#if canImport(IOKit)
import Foundation
import IOKit
import IOKit.hid

/// **DJI Virtual Joystick** USB HID 디바이스의 macOS 측 클라이언트.
///
/// # 왜 IOKit HID Manager 인가
///
/// DJI FPV Remote Controller 3 (VID=0x2CA3 / PID=0x1021, USB Product Name
/// "DJI Virtual Joystick") 은 MFi 인증을 받지 않은 표준 USB HID 게임패드를 노출한다.
/// macOS 의 `GameController.framework` 는 **MFi-인증된 컨트롤러만** 자동 노출하므로
/// (확인: 본 디바이스는 `ioreg` 에서 `GameControllerType = 0` 로 표시되고 `GCController.
/// controllers()` 에 등장하지 않는다), MFi 미인증 HID 게임패드는 **IOKit HID Manager**
/// 로 직접 enumerate 해야 한다.
///
/// # 비유
///
/// USB 케이블이 그냥 "꽂혀 있는 상태" 와, 호스트 쪽에서 "이 케이블을 통해 데이터를
/// 읽겠다" 라고 말한 상태는 다르다. `GameController.framework` 는 인증된 케이블만
/// 자동으로 들어준다. `IOHIDManager` 는 어떤 종류의 케이블이든 일단 손을 흔들면
/// (`open` + `register input report callback`) 데이터를 받게 해 준다.
///
/// # 책임 분리
///
/// - 본 클래스: **운영체제와의 통신** 만 담당 (open/close, callback 등록, 콜백에서
///   raw `Data` 추출).
/// - `DJIVirtualJoystickReport.decode(_:)`: 추출된 byte 를 구조화된 stick/button
///   값으로 디코딩 (순수 함수 → 단위 테스트 100%).
/// - `DJIVirtualJoystickMapper`: 디코딩된 값을 cockpit 의 leftX/leftY/turn 컨벤션
///   으로 변환 (순수 함수).
/// - `DJIVirtualJoystickWatcher`: 위 셋을 묶어 CockpitState 에 stick 입력 push.
///
/// # 충돌 안전
///
/// `IOHIDManager` 자체가 "shared" 인스턴스 모델이라 같은 macOS 세션에서 여러
/// 프로세스가 동시에 열어도 OS 가 각 프로세스에 독립 콜백을 발사한다. 다른 터미널
/// 에서 동시 진행 중인 빌드 / DJI Virtual Flight 같은 외부 시뮬레이터와 함께 떠
/// 있어도 본 클라이언트와 충돌하지 않는다.
///
/// # Lifecycle
///
/// ```
///  init() → start() → (자동) deviceMatched → (자동) inputReport → onReport(...)
///                                                                      ↓
///                                                              stop() → 콜백 해제
/// ```
@MainActor
public final class DJIVirtualJoystickHIDClient {

    // MARK: - Public callbacks

    /// raw 13-byte input report 가 도착할 때마다 호출. main actor 에서 실행되므로
    /// UI 갱신 직접 수행 가능.
    public var onReport: ((DJIVirtualJoystickReport) -> Void)?

    /// DJI Virtual Joystick 이 연결되었을 때 호출. 인자는 product name.
    public var onConnect: ((String) -> Void)?

    /// 연결이 끊겼을 때 호출.
    public var onDisconnect: (() -> Void)?

    // MARK: - State

    public private(set) var isRunning: Bool = false
    public private(set) var matchedProductName: String?
    public private(set) var lastInputReportAt: Date?
    /// 디버그 / 진단용 — 누적 input report 수신 수.
    public private(set) var inputReportCount: Int = 0

    /// IOKit Manager 가 callback 에 self 를 unmanaged 로 넘기기 위한 cookie.
    /// 강한 참조 사이클 방지를 위해 release 는 stop() 에서 명시 수행.
    private var manager: IOHIDManager?
    /// 현재 binding 된 device — disconnect 시 callback 해제용.
    private var boundDevice: IOHIDDevice?
    /// HID input report 의 정확한 길이만 받는 backing buffer.
    ///
    /// **왜 raw pointer 인가**: `Array<UInt8>` 의 storage 는 alloc churn 또는
    /// retain/release 사이클로 silent reallocation 될 수 있다. 본 buffer 는
    /// `IOHIDDeviceRegisterInputReportCallback` 에 등록되어 OS 가 매 input report
    /// 마다 같은 pointer 에 write 하므로, lifetime 동안 절대 옮겨지면 안 된다.
    /// `UnsafeMutablePointer.allocate` 는 객체 lifetime 동안 stable.
    private let reportBuffer: UnsafeMutablePointer<UInt8>

    public init() {
        let size = DJIVirtualJoystickReport.reportSize
        self.reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        self.reportBuffer.initialize(repeating: 0, count: size)
    }

    deinit {
        // **주의**: deinit 은 nonisolated 라 stop() 호출 불가. 사용자가 disappear
        // hook 에서 stop() 명시 호출해야 한다 (Watcher 가 본 invariant 준수).
        // 본 deinit 은 manager close + buffer 해제만 best-effort 수행.
        if let mgr = manager {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        reportBuffer.deinitialize(count: DJIVirtualJoystickReport.reportSize)
        reportBuffer.deallocate()
    }

    // MARK: - Lifecycle

    public func start() {
        guard !isRunning else { return }
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault,
                                     IOOptionBits(kIOHIDOptionsTypeNone))
        manager = mgr

        // Vendor + product 매칭 — DJI Virtual Joystick 만 잡는다. 다른 DJI 제품
        // (드론 자체, 카메라 등) 이 같은 vendor 로 노출되어도 무시.
        let matching: [String: Any] = [
            kIOHIDVendorIDKey  as String: DJIVirtualJoystickReport.vendorID,
            kIOHIDProductIDKey as String: DJIVirtualJoystickReport.productID,
        ]
        IOHIDManagerSetDeviceMatching(mgr, matching as CFDictionary)

        // Device match / removal 콜백 — Swift 에서 C-callback 사용 시 unmanaged
        // self pointer 패턴이 안전.
        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(
            mgr, DJIVirtualJoystickHIDClient.cMatchingCallback, opaqueSelf)
        IOHIDManagerRegisterDeviceRemovalCallback(
            mgr, DJIVirtualJoystickHIDClient.cRemovalCallback, opaqueSelf)

        IOHIDManagerScheduleWithRunLoop(
            mgr,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue)

        // Open — kIOHIDOptionsTypeNone 으로 충분. seizeDevice 옵션은 다른 프로세스
        // (DJI 자체 시뮬레이터 등) 와 충돌할 수 있어 사용하지 않는다.
        let res = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        if res == kIOReturnSuccess {
            isRunning = true
            // 이미 연결되어 있는 디바이스에 대해서도 동일 match 콜백을 즉시 발사하므로
            // 별도 enumerate 코드는 필요 없다.
        } else {
            // open 실패 시 manager 해제 (재시도 가능 상태로 복귀).
            IOHIDManagerUnscheduleFromRunLoop(
                mgr,
                CFRunLoopGetMain(),
                CFRunLoopMode.defaultMode.rawValue)
            manager = nil
            isRunning = false
        }
    }

    public func stop() {
        guard isRunning, let mgr = manager else { return }
        // `IOHIDManagerClose` 가 manager 가 알고 있는 모든 device 의 input report
        // callback 을 자동 해제한다. 명시 `IOHIDDeviceRegisterInputReportCallback(
        // device, ..., nil, nil)` 호출은 device 가 이미 unscheduled 인 경우 race 가
        // 있어 (콜백 등록 자체가 비동기) 생략 — 더 단순/안전.
        boundDevice = nil
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerUnscheduleFromRunLoop(
            mgr,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue)
        manager = nil
        isRunning = false
        matchedProductName = nil
        onDisconnect?()
    }

    // MARK: - Bridge from C callbacks back into Swift main actor

    /// C-callback 에서 호출되는 brokerage method. main actor 위로 hop.
    fileprivate nonisolated func _matched(device: IOHIDDevice) {
        let name = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString)
                     as? String) ?? "DJI Virtual Joystick"
        Task { @MainActor in
            self.bind(device: device, name: name)
        }
    }

    fileprivate nonisolated func _removed(device: IOHIDDevice) {
        Task { @MainActor in
            if self.boundDevice == device {
                self.boundDevice = nil
                self.matchedProductName = nil
                self.onDisconnect?()
            }
        }
    }

    /// C-callback 에서 호출. 콜백은 임의 스레드에서 발사되므로 main actor 로 hop
    /// 한 후 Report 디코딩 + onReport 발사.
    ///
    /// **buffer lifetime**: 콜백이 받는 pointer 는 callback return 후 OS 가 재사용
    /// 한다 (다음 input report 가 같은 buffer 에 덮어쓰임). 따라서 Task 에 넘기기
    /// 전에 즉시 `Data(bytes:count:)` 로 복사. 13 bytes 라 alloc 비용 무시 가능.
    fileprivate nonisolated func _inputReport(bytes: UnsafeMutablePointer<UInt8>, length: Int) {
        let copy = Data(bytes: bytes, count: length)
        Task { @MainActor in
            self.inputReportCount &+= 1
            self.lastInputReportAt = Date()
            if let report = DJIVirtualJoystickReport.decode(copy) {
                self.onReport?(report)
            }
        }
    }

    // MARK: - Bind device

    @MainActor
    private func bind(device: IOHIDDevice, name: String) {
        boundDevice = device
        matchedProductName = name
        onConnect?(name)

        // input report callback — 13-byte buffer 를 미리 확보, 콜백마다 같은 buffer
        // 에 OS 가 write.
        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(
            device,
            reportBuffer,
            DJIVirtualJoystickReport.reportSize,
            DJIVirtualJoystickHIDClient.cInputReportCallback,
            opaqueSelf)
    }

    // MARK: - C callback trampolines
    //
    // IOKit C API 가 받는 callback signature 는 unmanaged pointer 만 받으므로
    // 본 trampoline 이 unmanaged → strong ref 로 변환 후 instance method 위임.

    private static let cMatchingCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        let client = Unmanaged<DJIVirtualJoystickHIDClient>
            .fromOpaque(context).takeUnretainedValue()
        client._matched(device: device)
    }

    private static let cRemovalCallback: IOHIDDeviceCallback = { context, _, _, device in
        guard let context else { return }
        let client = Unmanaged<DJIVirtualJoystickHIDClient>
            .fromOpaque(context).takeUnretainedValue()
        client._removed(device: device)
    }

    private static let cInputReportCallback: IOHIDReportCallback = {
        context, _, _, _, _, report, reportLength in
        guard let context else { return }
        let client = Unmanaged<DJIVirtualJoystickHIDClient>
            .fromOpaque(context).takeUnretainedValue()
        client._inputReport(bytes: report, length: reportLength)
    }
}
#endif
