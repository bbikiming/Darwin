import ForgeCore
import SwiftUI

/// 사이클 V281-1 (V280-A1) — `WalkLabView` Tertiary 보조 정보 disclosure 분리.
///
/// # 비유
///
/// 자동차 dashboard 의 **글러브박스** — 평소엔 닫혀 있고 (Hick's Law: 핵심
/// 의사결정 화면에서 부수 정보 분리), 필요할 때만 펼치는 보조 정보 (자이로 raw
/// panel / 모드 안내 / 발 좌표 + 온도). Nielsen #8 minimalist.
///
/// # 책임 (Single Responsibility)
///
/// - **`LiveGyroPanel`** — 워크랩 진입 즉시 자이로 실시간 패널 (v1.11.17)
/// - **`simOnlyNotice`** — 시뮬 vs 실 송출 경계 안내 (preset = 실 송출,
///   슬라이더 = page 재합성)
/// - **`footTargetsCard`** — phase / L/R 발 좌표 / 모터 온도 / elapsed
///
/// # 비-책임 (절대 안 함)
///
/// - 3D scene rendering
/// - 사이드 disclosure 그룹 (운용 / 진단)
/// - actionBar / banner / sidebar
/// - session lifecycle
///
/// # 의존성
///
/// - `@Environment(WalkLabSession.self)` — phase / 발 좌표 / 온도 / elapsed read
/// - `@EnvironmentObject ConnectionStore` — bus 유무 (simOnlyNotice 라벨링)
/// - `@Binding var expandedAuxInfo: Bool` — 부모 `@AppStorage` 와 연결
///
/// behavior 0 변경 — V281-1 이전 inline 구현과 layout / animation / visibility
/// 모두 동일 (pure structural refactoring).
struct WalkLabAuxSection: View {
    @Environment(WalkLabSession.self) private var session
    @EnvironmentObject private var store: ConnectionStore
    @Binding var expandedAuxInfo: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $expandedAuxInfo) {
            VStack(spacing: DFSpace.sm) {
                // **v1.11.17 (2026-05-19)**: 워크랩 진입 즉시 자이로 실시간 패널.
                LiveGyroPanel()
                simOnlyNotice
                footTargetsCard
            }
            .padding(.top, DFSpace.xs)
        } label: {
            WalkLabDisclosureHeader(icon: "info.circle",
                                   title: "보조 정보",
                                   subtitle: "자이로 · 모드 안내 · 발 좌표")
        }
    }

    /// 시뮬 vs 실 송출 경계 안내. 프리셋/고급 슬라이더 모두 실 송출 page 합성에 반영.
    private var simOnlyNotice: some View {
        let walking = session.isRobotWalking
        let connected = store.bus != nil
        let title: String = {
            if walking { return "🤖 보행 cycle 송출 중 — 실 로봇 동작" }
            if connected && session.cradleConfirmed {
                return "프리셋 보행 = 실 송출 활성 · 슬라이더 = 실시간 반영"
            }
            return "프리셋 보행 = 실 송출 (연결 + cradle 후) · 슬라이더 = page 재합성"
        }()
        let detail = "프리셋(제자리·천천히·보통·빠르게·공 접근 킥·좌/우회전)은 ROBOTIS walking 기반 step 시퀀스를 모터에 직접 송출합니다. 고급 슬라이더(보폭/측면/회전/주기/발 들기/균형)는 진행 중인 실 보행 page를 debounce 후 재합성합니다."
        let tint: Color = walking ? DFColor.success : DFColor.info
        return HStack(spacing: DFSpace.sm) {
            Image(systemName: walking ? "figure.walk.motion" : "info.circle.fill")
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: DFSpace.micro) {
                Text(title)
                    .font(DFFont.sectionBody)
                Text(detail)
                    .font(DFFont.label)
                    .foregroundStyle(DFColor.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, DFSpace.sm2)
        .padding(.vertical, DFSpace.xs2)
        .background(tint.opacity(DFOpacity.o10))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.button)
                .stroke(tint.opacity(DFOpacity.o30), lineWidth: DFSize.borderStrong)
        )
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.button))
    }

    /// **2026-05-16 검증**: 좁은 detail 폭 (480pt) 에서 HStack 컬럼 5개 + Spacer +
    /// 다이버 2개 = ~540pt content > 460pt available → 잠재 overflow.
    /// 해결: 컬럼 자체 `.lineLimit(1)` + monospace text 가 자동 truncate.
    /// 추가 보호: `.fixedSize(horizontal: false, vertical: true)` 명시 — wrap
    /// 회피 + Spacer 우측 정렬 보장.
    private var footTargetsCard: some View {
        HStack(spacing: DFSpace.md - 2) {
            VStack(alignment: .leading, spacing: DFSpace.micro2) {
                Text("Phase").font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
                Text(session.phaseLabel)
                    .font(DFFont.monoBody)
                    .lineLimit(1)
            }
            Divider().frame(height: DFSpace.xl)
            VStack(alignment: .leading, spacing: DFSpace.micro2) {
                Text("L (x,y,z)").font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
                Text(fmt3(session.leftFoot))
                    .font(DFFont.mono)
                    .lineLimit(1)
            }
            VStack(alignment: .leading, spacing: DFSpace.micro2) {
                Text("R (x,y,z)").font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
                Text(fmt3(session.rightFoot))
                    .font(DFFont.mono)
                    .lineLimit(1)
            }
            Divider().frame(height: DFSpace.xl)
            VStack(alignment: .leading, spacing: DFSpace.micro2) {
                Text("Temp").font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
                Text(String(format: "%.1f°C", session.maxMotorTemp))
                    .font(DFFont.mono)
                    .foregroundStyle(tempColor)
                    .lineLimit(1)
            }
            Spacer(minLength: DFSpace.xs)
            VStack(alignment: .trailing, spacing: DFSpace.micro2) {
                Text("Elapsed").font(DFFont.caption).foregroundStyle(DFColor.textSecondary)
                Text("\(session.elapsedMs) ms")
                    .font(DFFont.mono)
                    .lineLimit(1)
            }
        }
        .padding(DFSpace.sm2)
        .background(DFColor.elev2)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.card))
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 모터 온도 색상 — DFLoadColor 5단계 매핑 (45/50/60°C 임계값).
    private var tempColor: Color {
        let t = session.maxMotorTemp
        if t >= 60 { return DFColor.danger }
        if t >= 50 { return DFLoadColor.high }
        if t >= 45 { return DFColor.warning }
        return DFColor.textSecondary
    }

    private func fmt3(_ v: SIMD3<Double>) -> String {
        String(format: "%+.3f %+.3f %+.3f", v.x, v.y, v.z)
    }
}
