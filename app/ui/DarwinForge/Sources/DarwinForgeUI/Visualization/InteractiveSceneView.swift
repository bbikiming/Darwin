import AppKit
import SceneKit

/// 커스텀 인터랙션을 가진 SCNView — Unity / Blender 스타일.
///
/// **인터랙션**
/// - 클릭+드래그: orbit (target 중심 회전)
/// - 스페이스+드래그: pan (object-drag — 드래그 방향으로 robot이 따라옴)
/// - 휠 / 트랙패드 스크롤: zoom
///
/// **부드러움**
/// - 60Hz 별도 타이머가 desired state와 applied state를 lerp으로 보간 → 입력이
///   거칠어도 카메라 동선은 매끄럽게.
/// - 드래그 끝나면 마지막 속도를 inertia로 점진 감속.
/// - 모든 감도는 view 크기에 정규화 (작은 창에서 한 바퀴 = 큰 창에서 한 바퀴).
public final class InteractiveSceneView: SCNView {

    // MARK: - Desired (사용자 입력의 즉각 반영) vs Applied (보간된 카메라 상태)
    //
    // 기본 시점: robot의 정면이 카메라 쪽을 향하도록.
    //
    // ROBOTIS X+(정면) → SceneKit Z-, 카메라는 SceneKit Z- 쪽에 있어야 정면을 봄.
    // 즉 azimuth = π. -0.35 차감으로 우측 isometric.
    //
    // **Sprint 16 revert** (사용자 보고: "원래 앞을 비췄는데 뒤를 비추고있어서"):
    // 한 차례 azimuth=−0.35 로 변경 시도했으나 그게 등쪽이었다 → 원본 `.pi-0.35`
    // 가 정면이었음을 확인. 카메라 azimuth 는 원본 유지.
    //
    // `defaultTarget Y` 와 rig `root.y` 는 새 walkReady (deep squat, hip ±36°
    // /knee ±53°) 자세에 맞춰 0.30→0.20, 0.345→0.265 로 정정 (floor 접지).

    /// 기본 시점: 정면(robot 가슴이 카메라 쪽) + 살짝 우측 isometric.
    /// **v1.11 (2026-05-17 사용자 재요청)**: 1.80 → 1.45 (cinema-fit). 작은 창에서도
    /// 로봇이 화면 ~45% 차지. 더 큰 frame 은 `autoDistance` 가 추가 zoom-in.
    public static let defaultAzimuth: CGFloat = .pi - 0.35
    public static let defaultElevation: CGFloat = 0.05
    public static let defaultDistance: CGFloat = 1.45
    public static let defaultTarget = SCNVector3(0, 0.20, 0)

    /// **v1.11 (2026-05-17 사용자 요청)**: frame width 기준 distance auto-fit.
    /// 사용자가 manual zoom (wheel/trackpad) 한 후엔 비활성 → manual override 우선.
    private var hasUserAdjustedZoom: Bool = false

    /// frame width 에 따른 auto distance. user override 없을 때만 적용.
    /// **공격적 zoom 범위** (재작업):
    ///   - 500pt 이하 → 1.55 (좁은 창, 약간만 가깝게)
    ///   - 800pt   → 1.30
    ///   - 1200pt  → 1.05
    ///   - 1600pt+ → 0.85 (와이드 모니터, 로봇이 화면 ~65% 차지)
    private static func autoDistance(forWidth width: CGFloat) -> CGFloat {
        if width <= 500 { return 1.55 }
        if width >= 1600 { return 0.85 }
        // 500..1600 → 1.55..0.85 선형.
        let t = (width - 500) / 1100
        return 1.55 - t * 0.70
    }

    private var desiredAzimuth:   CGFloat = InteractiveSceneView.defaultAzimuth
    private var desiredElevation: CGFloat = InteractiveSceneView.defaultElevation
    private var desiredDistance:  CGFloat = InteractiveSceneView.defaultDistance
    private var desiredTarget = InteractiveSceneView.defaultTarget

    private var azimuth:    CGFloat = InteractiveSceneView.defaultAzimuth
    private var elevation:  CGFloat = InteractiveSceneView.defaultElevation
    private var distance:   CGFloat = InteractiveSceneView.defaultDistance
    private var target = InteractiveSceneView.defaultTarget

    // MARK: - Inertia 속도

    private var azVelocity: CGFloat = 0
    private var elVelocity: CGFloat = 0
    private var distVelocity: CGFloat = 0           // 거리 배율 속도(곱셈)
    private var panVelocity = SCNVector3(0, 0, 0)   // world-space target 변화량

    // MARK: - Tunables (Unity 스타일)

    /// 한 픽셀 드래그당 회전 (라디안). View 너비로 정규화 — 1000px = 0.5 rad.
    private let orbitSensitivity: CGFloat = 0.0050

    /// 한 픽셀 드래그당 pan (m). distance에 비례. 1m 거리 + 1000px = 1m 이동.
    private let panSensitivity: CGFloat = 0.0010

    /// 휠 한 노치당 줌 비율.
    private let zoomSensitivity: CGFloat = 0.080
    private let trackpadZoomSensitivity: CGFloat = 0.012

    /// 보간/감속.
    private let smoothing: CGFloat = 0.32     // 0=정지, 1=즉시. 0.32면 한 프레임에 32% 따라감
    private let inertiaDecay: CGFloat = 0.88  // 매 프레임 감속
    private let velocityCutoff: CGFloat = 0.0005

    /// **W4 (2026-06-12)** — ViewCube/Home 프리셋 전환용 별도 smoothing.
    /// 기존 0.32 보다 느긋(0.18)해 "툭 끊기는 점프" 대신 부드러운 호를 그린다.
    /// 60fps × 0.18 이면 ~24프레임(≈0.4s) 안에 시각적으로 도달(잔차 <1.5°).
    private let transitionSmoothing: CGFloat = 0.18

    /// 프로그램적 프리셋 전환 진행 플래그. `true` 동안 tick 은 `transitionSmoothing`
    /// 으로 보간하고, 도달(epsilon) 시 해제한다. drag/scroll 같은 사용자 입력은
    /// 즉시 일반 `smoothing` 으로 복귀(전환 인터럽트).
    private var isTransitioning = false

    /// **W4 (2026-06-12)** — 턴테이블 자동 회전 (rad/s, 기본 0=off).
    /// `> 0` 이면 tick 마다 `desiredAzimuth` 를 rate/60 만큼 증가시켜 모델을
    /// 천천히 회전시킨다. **idle CPU 계약 예외**: 사용자가 명시적으로 켰을 때만
    /// 연속 tick 이 도므로 `isFullyIdle` 가 `!= 0` 을 반드시 검사한다(아래).
    /// (Timer 는 항상 60Hz 로 살아있고 `isFullyIdle` 가 body 를 게이트하므로 별도
    /// 재시작이 필요 없다 — `!= 0` 이면 다음 tick 부터 자동으로 body 가 돈다.)
    public var turntableRadPerSec: CGFloat = 0

    /// **W4 (2026-06-12)** — DOF(피사계 심도) 시네마틱 토글 (기본 off, 옵트인).
    /// Studio/Motion 의 "시네마틱" 토글에서만 켜며, **헤드리스 스냅샷 renderer 에는
    /// 미적용**(`renderImage` 는 `InteractiveSceneView` 를 만들지 않으므로 자동 제외 —
    /// 스냅샷 결정성 보존). 초점거리는 tick 에서 카메라-타깃 거리로 갱신.
    public var depthOfFieldEnabled: Bool = false {
        didSet {
            if depthOfFieldEnabled != oldValue { applyDepthOfFieldState() }
        }
    }

    /// 줌 한계.
    public var minDistance: CGFloat = 0.20
    public var maxDistance: CGFloat = 5.00

    private var spaceDown = false
    private var lastDragLocation: NSPoint?
    private var isDragging: Bool { lastDragLocation != nil }

    private var tickTimer: Timer?

    // MARK: - Init

    public override init(frame: CGRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        configure()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    deinit {
        tickTimer?.invalidate()
    }

    private func configure() {
        allowsCameraControl = false
        wantsLayer = true
        startTickLoop()
    }

    private func startTickLoop() {
        tickTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.current.add(t, forMode: .common)
        tickTimer = t
    }

    // MARK: - First responder + key tracking

    public override var acceptsFirstResponder: Bool { true }
    public override func becomeFirstResponder() -> Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        Task { @MainActor [weak self] in
            self?.window?.makeFirstResponder(self)
        }
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 {            // space
            spaceDown = true
            NSCursor.openHand.push()
            return                          // beep 방지
        }
        super.keyDown(with: event)
    }

    public override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceDown = false
            NSCursor.pop()
            return
        }
        super.keyUp(with: event)
    }

    // MARK: - Mouse

    public override func mouseDown(with event: NSEvent) {
        beginDrag(at: convert(event.locationInWindow, from: nil))
        if spaceDown { NSCursor.closedHand.push() }
    }

    public override func mouseDragged(with event: NSEvent) {
        handleDrag(to: convert(event.locationInWindow, from: nil), forcePan: spaceDown)
    }

    public override func mouseUp(with event: NSEvent) {
        endDrag()
        if spaceDown { NSCursor.pop() }
    }

    /// 휠 클릭 (middle mouse button) — 사용자 요청: orbit (앞뒤·좌우 회전).
    public override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseDown(with: event); return }
        beginDrag(at: convert(event.locationInWindow, from: nil))
        NSCursor.crosshair.push()
    }

    public override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseDragged(with: event); return }
        // 휠 클릭 드래그 = orbit (사용자 요청). spaceDown 무시.
        handleDrag(to: convert(event.locationInWindow, from: nil), forcePan: false)
    }

    public override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseUp(with: event); return }
        endDrag()
        NSCursor.pop()
    }

    // MARK: - Drag core (shared between left + middle buttons)

    private func beginDrag(at point: NSPoint) {
        lastDragLocation = point
        window?.makeFirstResponder(self)
        // **W4**: 사용자 입력이 프로그램적 전환을 인터럽트 → 일반 smoothing 복귀.
        isTransitioning = false
        // 드래그 시작 시 inertia 차단.
        azVelocity = 0
        elVelocity = 0
        distVelocity = 0
        panVelocity = SCNVector3(0, 0, 0)
    }

    private func handleDrag(to point: NSPoint, forcePan: Bool) {
        guard let last = lastDragLocation else { return }
        let dx = point.x - last.x
        let dy = point.y - last.y
        lastDragLocation = point

        let normW = max(bounds.width, 1)
        let nx = dx / normW * 1000.0
        let ny = dy / normW * 1000.0

        if forcePan {
            panInObjectDirection(nx: nx, ny: ny)
        } else {
            // orbit
            let azDelta = -nx * orbitSensitivity
            let elDelta = -ny * orbitSensitivity
            desiredAzimuth   += azDelta
            desiredElevation = clampElevation(desiredElevation + elDelta)
            azVelocity = azDelta
            elVelocity = elDelta
        }
    }

    private func endDrag() {
        lastDragLocation = nil
    }

    public override func scrollWheel(with event: NSEvent) {
        let raw = event.scrollingDeltaY
        let factor: CGFloat = event.hasPreciseScrollingDeltas
            ? trackpadZoomSensitivity
            : zoomSensitivity
        // 반전: 위로 스크롤 → 줌 아웃 (멀어짐), 아래로 → 줌 인 (가까워짐).
        let scale = exp(raw * factor)
        isTransitioning = false        // **W4**: zoom 입력도 전환 인터럽트.
        desiredDistance = clampDistance(desiredDistance * scale)
        let velContribution: CGFloat = event.hasPreciseScrollingDeltas ? 0.15 : 0.50
        distVelocity = (distVelocity + (1 - scale)) * velContribution
        // v1.11: 사용자가 manual zoom 한 후로는 frame-adaptive auto-fit 비활성.
        hasUserAdjustedZoom = true
    }

    /// **v1.11 (2026-05-17 사용자 요청)**: frame width 변경 시 distance auto-fit.
    /// macOS HSplitView drag 으로 detail 폭이 늘어나면 로봇이 가운데 작게 보이지 않게
    /// distance 를 자동으로 줄여서 (zoom in) 빈 영역 해소. 사용자가 한 번이라도
    /// manual zoom 한 후엔 override 됨 (`hasUserAdjustedZoom`).
    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard !hasUserAdjustedZoom else { return }
        let target = Self.autoDistance(forWidth: newSize.width)
        // tick loop 가 smoothing 으로 따라감 (즉시 jerk 없음).
        desiredDistance = clampDistance(target)
    }

    // MARK: - Pan helpers

    /// Pan — 좌우는 viewport-drag, 상하는 object-drag (사용자 요청 비대칭 반전).
    private func panInObjectDirection(nx: CGFloat, ny: CGFloat) {
        guard let cam = pointOfView else { return }
        let m = cam.worldTransform
        let right = SCNVector3(m.m11, m.m12, m.m13)
        let up    = SCNVector3(m.m21, m.m22, m.m23)
        let factor = panSensitivity * desiredDistance
        let mx = -nx * factor      // 좌우: viewport-drag (그대로)
        let my = -ny * factor      // 상하: 반전 (사용자 요청 — drag 방향과 같이 robot 움직임)
        let dt = SCNVector3(
            right.x * mx + up.x * my,
            right.y * mx + up.y * my,
            right.z * mx + up.z * my
        )
        desiredTarget = SCNVector3(
            desiredTarget.x + dt.x,
            desiredTarget.y + dt.y,
            desiredTarget.z + dt.z
        )
        panVelocity = dt
    }

    // MARK: - 60Hz tick (smoothing + inertia)

    /// **v1.11 (2026-05-17)**: frame width auto-fit 의 last applied snapshot.
    /// `tick` 에서 5pt 이상 변경 감지하면 `desiredDistance` 업데이트 (`setFrameSize`
    /// 가 SwiftUI Representable 라이프사이클에서 안정적으로 호출되지 않을 수도 있어서
    /// 60Hz tick 가 source of truth — 강력한 보장).
    private var lastAppliedAutoFitWidth: CGFloat = -1

    /// **v1.14.8.1 (2026-05-21) — critic HIGH fix**: idle early-return.
    /// 종전: 60Hz Timer 가 view init 시 무조건 시작 → 미연결/정지 상태에서도
    ///       60 wake-ups/s × applyCameraInternal (SCNTransaction begin/commit) 실행.
    ///       app-wide idle CPU floor 의 가장 큰 원인.
    /// 신규: 모든 velocity 0 + applied==desired + auto-fit width 동일 = "변화 없음" →
    ///       tick body 전체 skip. Timer.fire wake 자체는 남지만 (~5µs/tick) CPU 작업
    ///       (~50-100µs/tick) 의 95%+ 절감. 사용자가 drag / scroll 시 즉시 복귀.
    /// **v1.14.8.2 (2026-05-21) — 2차 code-reviewer HIGH fix**: epsilon 비교.
    /// 종전 `==` 는 smoothing snap (line 336-358 cutoff 0.0008 → 직접 assign) 덕분에
    /// 작동했으나 fragile — cutoff 변경 또는 외부 desired-set 시 영구 non-idle 위험.
    /// 신규: epsilon = cutoff (0.0008) 와 일관. 동일 효과 + 방어적.
    private static let idleEpsilon: CGFloat = 0.0008
    /// **W4 (2026-06-12)**: 턴테이블이 켜져 있으면 절대 idle 이 아니다 — `desiredAzimuth`
    /// 를 매 tick 증가시켜야 하므로 idle skip 과 정면 충돌. **반드시** 이 조건 선행.
    /// (테스트 가시성 위해 `internal` — `InteractiveSceneViewBehaviorTests` 에서 검증.)
    var isFullyIdle: Bool {
        guard turntableRadPerSec == 0 else { return false }
        guard !isTransitioning else { return false }
        guard !isDragging else { return false }
        guard abs(azVelocity) < Self.idleEpsilon,
              abs(elVelocity) < Self.idleEpsilon,
              abs(distVelocity) < Self.idleEpsilon else { return false }
        guard abs(panVelocity.x) < Self.idleEpsilon,
              abs(panVelocity.y) < Self.idleEpsilon,
              abs(panVelocity.z) < Self.idleEpsilon else { return false }
        guard abs(azimuth - desiredAzimuth) < Self.idleEpsilon,
              abs(elevation - desiredElevation) < Self.idleEpsilon,
              abs(distance - desiredDistance) < Self.idleEpsilon else { return false }
        guard abs(target.x - desiredTarget.x) < Self.idleEpsilon,
              abs(target.y - desiredTarget.y) < Self.idleEpsilon,
              abs(target.z - desiredTarget.z) < Self.idleEpsilon else { return false }
        // auto-fit: bounds width 변경 5pt 이내면 idle 로 간주 (변경 임계 line 299와 정합).
        if !hasUserAdjustedZoom {
            let w = bounds.width
            if w > 10 && abs(w - lastAppliedAutoFitWidth) > 5 { return false }
        }
        return true
    }

    private func tick() {
        // **v1.14.8.1 (2026-05-21) perf — critic HIGH fix**: idle 시 작업 skip.
        if isFullyIdle { return }

        // 0) **v1.11 frame-adaptive zoom** — manual override 없을 때만, 매 tick frame 감지.
        if !hasUserAdjustedZoom {
            let w = bounds.width
            if w > 10, abs(w - lastAppliedAutoFitWidth) > 5 {
                lastAppliedAutoFitWidth = w
                desiredDistance = clampDistance(Self.autoDistance(forWidth: w))
            }
        }

        // 0.5) **W4 턴테이블** — 켜져 있으면 매 tick desiredAzimuth 를 한 스텝 회전.
        // 60Hz 기준 rate/60. 누적이라 사용자 orbit 입력과 자연스럽게 합산된다.
        if turntableRadPerSec != 0 {
            desiredAzimuth += turntableRadPerSec / 60.0
        }

        // 1) Inertia — 드래그 중이 아니면 마지막 속도를 desired에 적용 후 감속.
        if !isDragging {
            desiredAzimuth   += azVelocity
            desiredElevation = clampElevation(desiredElevation + elVelocity)
            desiredDistance  = clampDistance(desiredDistance * (1 + distVelocity))
            desiredTarget = SCNVector3(
                desiredTarget.x + panVelocity.x,
                desiredTarget.y + panVelocity.y,
                desiredTarget.z + panVelocity.z
            )

            azVelocity   *= inertiaDecay
            elVelocity   *= inertiaDecay
            distVelocity *= inertiaDecay
            panVelocity = SCNVector3(
                panVelocity.x * inertiaDecay,
                panVelocity.y * inertiaDecay,
                panVelocity.z * inertiaDecay
            )

            if abs(azVelocity)   < velocityCutoff { azVelocity = 0 }
            if abs(elVelocity)   < velocityCutoff { elVelocity = 0 }
            if abs(distVelocity) < velocityCutoff { distVelocity = 0 }
            if hypot(panVelocity.x, hypot(panVelocity.y, panVelocity.z)) < velocityCutoff {
                panVelocity = SCNVector3(0, 0, 0)
            }
        }

        // 2) Smoothing — applied state가 desired에 점진 접근.
        //    Cutoff: lerp이 아주 가까워지면 정확히 desired로 snap (무한 접근 방지).
        //    **W4**: 프로그램적 프리셋 전환 중에는 느긋한 `transitionSmoothing` 사용.
        let s = isTransitioning ? transitionSmoothing : smoothing
        azimuth   = lerp(azimuth, desiredAzimuth, s)
        if abs(desiredAzimuth - azimuth) < 0.0008 { azimuth = desiredAzimuth }
        elevation = lerp(elevation, desiredElevation, s)
        if abs(desiredElevation - elevation) < 0.0008 { elevation = desiredElevation }
        distance  = lerp(distance, desiredDistance, s)
        if abs(desiredDistance - distance) < 0.0008 { distance = desiredDistance }
        let tdx = desiredTarget.x - target.x
        let tdy = desiredTarget.y - target.y
        let tdz = desiredTarget.z - target.z
        if (tdx*tdx + tdy*tdy + tdz*tdz) < 0.000001 {
            target = desiredTarget
        } else {
            target = SCNVector3(
                lerp(target.x, desiredTarget.x, s),
                lerp(target.y, desiredTarget.y, s),
                lerp(target.z, desiredTarget.z, s)
            )
        }

        // **W4**: 전환이 도달하면 플래그 해제 → 다음 사용자 입력은 일반 smoothing.
        if isTransitioning,
           azimuth == desiredAzimuth, elevation == desiredElevation,
           distance == desiredDistance, target.x == desiredTarget.x,
           target.y == desiredTarget.y, target.z == desiredTarget.z {
            isTransitioning = false
        }

        applyCameraInternal()

        // **W4 DOF**: 초점거리 = 카메라-타깃 거리. 켜져 있을 때만 갱신.
        if depthOfFieldEnabled { updateFocusDistance() }
    }

    // MARK: - Camera apply

    /// orbit/pan/zoom state → 카메라 transform.
    public func applyCamera() {
        // 외부 호출용 — desired/applied를 동시 set 후 즉시 반영.
        azimuth = desiredAzimuth
        elevation = desiredElevation
        distance = desiredDistance
        target = desiredTarget
        applyCameraInternal()
    }

    private func applyCameraInternal() {
        guard let cam = pointOfView else { return }
        let cosE = cos(elevation)
        let x = distance * cosE * sin(azimuth)
        let y = distance * sin(elevation)
        let z = distance * cosE * cos(azimuth)
        cam.position = SCNVector3(target.x + x,
                                  target.y + y,
                                  target.z + z)
        cam.look(at: target)
    }

    /// 정면 기본 view로 부드럽게 복귀.
    /// **W4 (2026-06-12)**: 종전 `instant: true` 점프 → ease 전환(`transitionSmoothing`).
    /// 롤백이 필요하면 `instant: true` 한 줄로 복원 가능.
    public func resetCamera() {
        transitionTo(
            azimuth: Self.defaultAzimuth,
            elevation: Self.defaultElevation,
            distance: Self.defaultDistance,
            target: Self.defaultTarget,
            instant: false
        )
    }

    /// 카메라를 (azimuth, elevation, distance, target)로 전환.
    ///
    /// `instant=true`: applied state를 desired와 동일하게 즉시 set.
    ///                 lerp 우회 → 1프레임에 절대 view로 jump.
    ///                 face/reset 버튼처럼 정확도가 우선인 호출에 사용.
    /// `instant=false`(기본): desired만 갱신 → 60Hz lerp이 부드럽게 따라감.
    public func transitionTo(azimuth: CGFloat,
                              elevation: CGFloat,
                              distance: CGFloat? = nil,
                              target: SCNVector3? = nil,
                              instant: Bool = false) {
        // **W4 최단경로 보정**: azimuth 를 절대값으로 대입하면 현재값과 목표값이
        // 2π 경계를 사이에 둘 때 카메라가 한 바퀴 가까이 도는 케이스가 생긴다.
        // 현재 applied azimuth 기준 최단 delta 를 더해 desired 를 잡는다.
        desiredAzimuth = self.azimuth + shortestAngleDelta(from: self.azimuth, to: azimuth)
        desiredElevation = clampElevation(elevation)
        if let d = distance { desiredDistance = clampDistance(d) }
        if let t = target { desiredTarget = t }

        azVelocity = 0; elVelocity = 0; distVelocity = 0
        panVelocity = SCNVector3(0, 0, 0)

        if instant {
            // 롤백 경로: 절대값으로 즉시 이동. lerp 우회.
            isTransitioning = false
            self.azimuth = desiredAzimuth
            self.elevation = desiredElevation
            self.distance = desiredDistance
            self.target = desiredTarget
            applyCameraInternal()
        } else {
            // **W4**: 부드러운 호 전환. tick 이 transitionSmoothing 으로 보간.
            isTransitioning = true
        }
    }

    /// ViewCube의 6 face + isometric preset으로 부드럽게 전환.
    /// **W4 (2026-06-12)**: 종전 `instant: true` 점프 → ease 전환. 롤백은 1줄.
    public func goToFace(_ face: CameraFace) {
        transitionTo(
            azimuth: face.azimuth,
            elevation: face.elevation,
            distance: Self.defaultDistance,
            target: Self.defaultTarget,
            instant: false
        )
    }

    /// 현재 카메라 상태 (외부 ViewCube 위젯이 회전 동기화에 사용).
    public var currentAzimuth: CGFloat { azimuth }
    public var currentElevation: CGFloat { elevation }

    // MARK: - Helpers

    @inline(__always)
    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }

    @inline(__always)
    private func clampElevation(_ v: CGFloat) -> CGFloat {
        let limit: CGFloat = .pi / 2 - 0.05
        return max(-limit, min(limit, v))
    }

    @inline(__always)
    private func clampDistance(_ v: CGFloat) -> CGFloat {
        max(minDistance, min(maxDistance, v))
    }

    // MARK: - DOF (W4 시네마틱)

    /// DOF on/off 토글 시 카메라 플래그 일괄 적용. 초점거리는 즉시 1회 갱신.
    private func applyDepthOfFieldState() {
        guard let cam = pointOfView?.camera else { return }
        cam.wantsDepthOfField = depthOfFieldEnabled
        if depthOfFieldEnabled {
            cam.fStop = 5.6
            cam.apertureBladeCount = 6
            updateFocusDistance()
        }
    }

    /// 초점거리 = 현재 카메라-타깃 거리. tick + 토글 시점에 호출.
    private func updateFocusDistance() {
        pointOfView?.camera?.focusDistance = distance
    }
}

// MARK: - CameraFace

/// ViewCube의 6 면 + isometric preset.
public enum CameraFace: String, CaseIterable, Identifiable, Sendable {
    case front, back, left, right, top, bottom, isometric

    public var id: String { rawValue }

    /// orbit azimuth (라디안). 좌표 매핑 (MeshRig axis-angle 120° 후):
    /// ROS X+(robot 정면) → SceneKit Z-, ROS Y-(robot 우측) → SceneKit X+.
    /// 카메라 위치 = (d·cos(el)·sin(az), y, d·cos(el)·cos(az)):
    /// - az = π:   cam at (0, y, -d) = SceneKit Z- → robot 정면 보임
    /// - az = 0:   cam at (0, y,  d) = SceneKit Z+ → robot 등 보임
    /// - az = π/2: cam at (d, y,  0) = SceneKit X+ → robot 우측면 보임
    public var azimuth: CGFloat {
        switch self {
        case .front:     return .pi                // robot의 가슴·눈
        case .back:      return 0                   // robot의 등
        case .right:     return .pi / 2             // robot의 우측면
        case .left:      return -.pi / 2            // robot의 좌측면
        case .top:       return .pi                 // 위에서 — 정면 az 기준
        case .bottom:    return .pi
        case .isometric: return .pi - 0.55          // 정면 + 살짝 우측 (기본)
        }
    }

    public var elevation: CGFloat {
        switch self {
        case .front, .back, .left, .right: return 0
        case .top:        return  .pi / 2 - 0.05
        case .bottom:     return -.pi / 2 + 0.05
        case .isometric:  return 0.16
        }
    }

    public var label: String {
        switch self {
        case .front:     return "앞"
        case .back:      return "뒤"
        case .left:      return "왼쪽"
        case .right:     return "오른쪽"
        case .top:       return "위"
        case .bottom:    return "아래"
        case .isometric: return "기본"
        }
    }

    public var icon: String {
        switch self {
        case .front:     return "person.fill"
        case .back:      return "figure.stand"
        case .left:      return "arrowshape.left.fill"
        case .right:     return "arrowshape.right.fill"
        case .top:       return "arrow.down.to.line.compact"
        case .bottom:    return "arrow.up.to.line.compact"
        case .isometric: return "cube.fill"
        }
    }
}
