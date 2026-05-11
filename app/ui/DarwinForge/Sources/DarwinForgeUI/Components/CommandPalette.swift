import ForgeCore
import SwiftUI

/// VS Code 스타일 명령 팔레트 — ⌘K로 열고 검색해 실행.
/// CLI 9개 서브커맨드 + 자주 쓰는 자세 + 모드 전환을 한 곳에 노출.
public struct CommandPalette: View {
    @Binding public var isPresented: Bool
    public let entries: [CommandEntry]
    public let onRun: (CommandEntry) -> Void

    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var queryFocused: Bool

    public init(isPresented: Binding<Bool>,
                entries: [CommandEntry],
                onRun: @escaping (CommandEntry) -> Void) {
        self._isPresented = isPresented
        self.entries = entries
        self.onRun = onRun
    }

    public var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            list
        }
        .frame(width: 560, height: 440)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DFRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DFRadius.md, style: .continuous)
                .stroke(DFColor.textSecondary.opacity(0.18), lineWidth: 0.5)
        )
        .shadow(radius: 30)
        .onAppear {
            query = ""
            selectedIndex = 0
            queryFocused = true
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: DFSpace.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(DFColor.textSecondary)
            TextField("명령 검색  (예: 깨우기, 연결, 모션)", text: $query)
                .textFieldStyle(.plain)
                .font(DFFont.body)
                .focused($queryFocused)
                .onSubmit { runSelected() }
            Text("ESC")
                .font(DFFont.caption.monospaced())
                .foregroundStyle(DFColor.textSecondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(DFColor.elev2)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .padding(.horizontal, DFSpace.md)
        .padding(.vertical, DFSpace.sm + 2)
    }

    // MARK: - List

    private var filtered: [CommandEntry] {
        guard !query.isEmpty else { return entries }
        let q = query.lowercased()
        return entries.filter {
            $0.title.lowercased().contains(q) ||
            $0.subtitle.lowercased().contains(q) ||
            $0.keywords.contains(where: { $0.lowercased().contains(q) })
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    let items = filtered
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, e in
                        row(e, isSelected: idx == selectedIndex)
                            .id(e.id)
                            .onTapGesture {
                                isPresented = false
                                onRun(e)
                            }
                            .onHover { if $0 { selectedIndex = idx } }
                    }
                    if items.isEmpty {
                        Text("일치하는 명령이 없어요")
                            .font(DFFont.caption)
                            .foregroundStyle(DFColor.textSecondary)
                            .padding(DFSpace.md)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: query) { _, _ in selectedIndex = 0 }
            .onChange(of: selectedIndex) { _, idx in
                if idx >= 0, idx < filtered.count {
                    withAnimation(.linear(duration: 0.05)) {
                        proxy.scrollTo(filtered[idx].id, anchor: .center)
                    }
                }
            }
        }
        .background(
            // 키 핸들러
            KeyHandler(
                onUp: { selectedIndex = max(0, selectedIndex - 1) },
                onDown: { selectedIndex = min(filtered.count - 1, selectedIndex + 1) },
                onReturn: { runSelected() },
                onEscape: { isPresented = false }
            )
        )
    }

    private func row(_ e: CommandEntry, isSelected: Bool) -> some View {
        HStack(spacing: DFSpace.sm) {
            Image(systemName: e.icon)
                .frame(width: 22)
                .foregroundStyle(isSelected ? DFColor.accent : e.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.title)
                    .font(DFFont.bodyEmph)
                    .foregroundStyle(isSelected ? DFColor.textPrimary : DFColor.textPrimary)
                Text(e.subtitle)
                    .font(DFFont.caption)
                    .foregroundStyle(DFColor.textSecondary)
            }
            Spacer()
            if let shortcut = e.shortcut {
                Text(shortcut)
                    .font(DFFont.caption.monospaced())
                    .foregroundStyle(DFColor.textSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(DFColor.elev2)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            if e.dangerous {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DFColor.danger)
                    .font(.caption)
            }
        }
        .padding(.horizontal, DFSpace.md)
        .padding(.vertical, 6)
        .background(isSelected ? DFColor.accent.opacity(0.12) : Color.clear)
    }

    private func runSelected() {
        let items = filtered
        guard !items.isEmpty else { return }
        let idx = max(0, min(selectedIndex, items.count - 1))
        let entry = items[idx]
        isPresented = false
        onRun(entry)
    }
}

// MARK: - Entry

public struct CommandEntry: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let icon: String
    public let tint: Color
    public let keywords: [String]
    public let shortcut: String?
    public let dangerous: Bool
    public let action: CommandAction

    public init(id: String,
                title: String,
                subtitle: String,
                icon: String,
                tint: Color = DFColor.accent,
                keywords: [String] = [],
                shortcut: String? = nil,
                dangerous: Bool = false,
                action: CommandAction) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.tint = tint
        self.keywords = keywords
        self.shortcut = shortcut
        self.dangerous = dangerous
        self.action = action
    }
}

/// 팔레트가 트리거할 액션. 호스트 측 (StudioView 등)이 dispatch.
public enum CommandAction: Sendable {
    case connect              // 자동 포트 연결
    case disconnect
    case scanJoints
    case wakeUp
    case sleep
    case emergencyStop
    case applyPose(RobotPose)
    case importMotion         // 파일 패널
    case playSelectedPage
    case stopPlayback
    case switchSection(String)  // "studio" / "conversation" / "expert"
    case switchExpertTab(String)
    case fillFromTelemetry
    case mirrorPose
    case resetPose
    case saveCurrentPoseAsKeyframe
}

// MARK: - 표준 명령 카탈로그

public enum CommandCatalog {
    /// StudioView가 사용할 기본 카탈로그. 모든 부제는 비전문가가 한 번 읽고 이해할 수 있어야 한다.
    public static func standard() -> [CommandEntry] {
        [
            CommandEntry(
                id: "connect",
                title: "USB로 로봇과 연결",
                subtitle: "케이블이 꽂혀 있으면 가장 적합한 포트로 자동 연결해요",
                icon: "cable.connector",
                tint: DFColor.success,
                keywords: ["connect", "연결", "usb", "port", "케이블", "자동"],
                shortcut: "⌘⇧C",
                action: .connect
            ),
            CommandEntry(
                id: "disconnect",
                title: "연결 끊기",
                subtitle: "지금 사용 중인 USB 통신을 안전하게 종료해요",
                icon: "xmark.circle",
                tint: DFColor.textSecondary,
                keywords: ["disconnect", "끊기", "해제"],
                action: .disconnect
            ),
            CommandEntry(
                id: "scan",
                title: "지금 켜진 관절 찾기",
                subtitle: "1번~20번 ID에 신호를 보내 응답하는 관절 목록을 받아와요",
                icon: "magnifyingglass.circle",
                keywords: ["scan", "스캔", "관절", "id", "찾기"],
                action: .scanJoints
            ),
            CommandEntry(
                id: "wakeup",
                title: "로봇 깨우기",
                subtitle: "20개 관절 모두에 힘을 주어 자세를 잡게 해요",
                icon: "sun.max",
                tint: DFColor.warning,
                keywords: ["wake", "깨우기", "힘", "켜기"],
                shortcut: "⌘W",
                action: .wakeUp
            ),
            CommandEntry(
                id: "sleep",
                title: "로봇 재우기",
                subtitle: "관절의 힘을 부드럽게 풀어요. 손으로 받쳐주세요",
                icon: "moon",
                tint: DFColor.info,
                keywords: ["sleep", "재우기", "힘", "끄기"],
                action: .sleep
            ),
            CommandEntry(
                id: "estop",
                title: "긴급정지",
                subtitle: "지금 즉시 모든 관절의 힘을 차단해요. 로봇이 천천히 주저앉을 수 있어요",
                icon: "exclamationmark.octagon.fill",
                tint: DFColor.danger,
                keywords: ["estop", "stop", "긴급", "비상", "정지"],
                shortcut: "⌘⇧.",
                dangerous: true,
                action: .emergencyStop
            ),
            CommandEntry(
                id: "pose-idle",
                title: "기본 자세로 돌아가기",
                subtitle: "다윈 idle 자세 — 모든 관절 0°, 팔이 자연스럽게 옆으로 내려와요",
                icon: "figure.stand",
                keywords: ["pose", "idle", "기본", "자세"],
                action: .applyPose(.idle)
            ),
            CommandEntry(
                id: "pose-walk-ready",
                title: "걷기 준비 자세",
                subtitle: "보행 시작 전 무릎을 살짝 굽힌 안정 자세",
                icon: "figure.walk.motion",
                keywords: ["walk", "ready", "준비", "걷기"],
                action: .applyPose(.walkReady)
            ),
            CommandEntry(
                id: "pose-tpose",
                title: "T 자세 (진단용)",
                subtitle: "팔을 양 옆으로 수평 펼친 캘리브레이션 표준 자세",
                icon: "figure.arms.open",
                keywords: ["tpose", "t-pose", "T자", "진단", "캘리브레이션"],
                action: .applyPose(.tPose)
            ),
            CommandEntry(
                id: "mirror",
                title: "좌우 바꾸기",
                subtitle: "현재 자세의 왼쪽과 오른쪽을 거울처럼 뒤집어요",
                icon: "arrow.left.and.right",
                keywords: ["mirror", "거울", "좌우", "뒤집"],
                action: .mirrorPose
            ),
            CommandEntry(
                id: "fill-from-telemetry",
                title: "지금 로봇 자세 가져오기",
                subtitle: "실제 로봇이 취하고 있는 자세를 읽어와 편집기에 채워줘요",
                icon: "scope",
                keywords: ["capture", "캡처", "지금", "자세", "가져오기"],
                shortcut: "⌘⇧P",
                action: .fillFromTelemetry
            ),
            CommandEntry(
                id: "save-keyframe",
                title: "이 자세를 한 컷으로 저장",
                subtitle: "지금 편집 중인 동작의 마지막에 자세 한 컷을 추가해요",
                icon: "key.horizontal",
                keywords: ["keyframe", "키프레임", "한컷", "저장"],
                shortcut: "⌘K",
                action: .saveCurrentPoseAsKeyframe
            ),
            CommandEntry(
                id: "reset",
                title: "편집 자세 처음으로",
                subtitle: "지금까지 만든 자세를 모두 지우고 기본 자세로 돌아가요",
                icon: "arrow.counterclockwise",
                keywords: ["reset", "초기화", "처음"],
                action: .resetPose
            ),
            CommandEntry(
                id: "import-motion",
                title: "동작 파일 가져오기 (.mtn)",
                subtitle: "로보플러스에서 만든 동작 파일을 열어 편집해요",
                icon: "tray.and.arrow.down",
                keywords: ["import", "motion", "mtn", "동작", "가져오기", "파일"],
                action: .importMotion
            ),
            CommandEntry(
                id: "play-page",
                title: "선택한 동작 재생",
                subtitle: "지금 보고 있는 동작을 처음부터 부드럽게 재생해요",
                icon: "play.fill",
                tint: DFColor.success,
                keywords: ["play", "재생"],
                shortcut: "⌘↵",
                action: .playSelectedPage
            ),
            CommandEntry(
                id: "stop-playback",
                title: "재생 멈추기",
                subtitle: "동작 재생을 즉시 멈춰요. 관절 힘은 그대로 유지돼요",
                icon: "stop.fill",
                keywords: ["stop", "중지", "멈춤"],
                action: .stopPlayback
            ),
            CommandEntry(
                id: "section-studio",
                title: "작업실로 이동",
                subtitle: "3D로 자세를 보면서 슬라이더로 편집해요",
                icon: "rectangle.3.group.fill",
                keywords: ["studio", "스튜디오", "작업실", "3d"],
                shortcut: "⌘1",
                action: .switchSection("studio")
            ),
            CommandEntry(
                id: "section-motion",
                title: "동작 만들기로 이동",
                subtitle: "여러 자세를 시간 순서로 이어 한 동작을 만들어요",
                icon: "play.rectangle.on.rectangle",
                keywords: ["motion", "모션", "동작", "타임라인"],
                shortcut: "⌘2",
                action: .switchSection("motion")
            ),
            CommandEntry(
                id: "section-walk",
                title: "걷기 실험실로 이동",
                subtitle: "걸음 폭과 회전을 슬라이더로 바꿔보고 발 자취를 봐요",
                icon: "figure.walk",
                keywords: ["walk", "워크", "보행", "걷기"],
                shortcut: "⌘3",
                action: .switchSection("walk")
            ),
            CommandEntry(
                id: "section-conversation",
                title: "말로 시키기로 이동",
                subtitle: "자연어로 로봇과 대화하며 동작을 시켜요",
                icon: "bubble.left.and.bubble.right",
                keywords: ["conversation", "대화", "claude", "ai", "말로"],
                shortcut: "⌘4",
                action: .switchSection("conversation")
            ),
            CommandEntry(
                id: "section-expert",
                title: "전문가 도구로 이동",
                subtitle: "관절·보드·전략 등 자세한 디버깅 화면이에요",
                icon: "wrench.and.screwdriver",
                keywords: ["expert", "전문가", "console", "디버깅"],
                shortcut: "⌘5",
                action: .switchSection("expert")
            )
        ]
    }
}

// MARK: - KeyHandler (NSView wrapping AppKit keys)

private struct KeyHandler: NSViewRepresentable {
    let onUp: () -> Void
    let onDown: () -> Void
    let onReturn: () -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = KeyView()
        v.onUp = onUp; v.onDown = onDown; v.onReturn = onReturn; v.onEscape = onEscape
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class KeyView: NSView {
        var onUp: (() -> Void)?
        var onDown: (() -> Void)?
        var onReturn: (() -> Void)?
        var onEscape: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 126: onUp?()       // arrow up
            case 125: onDown?()     // arrow down
            case 36, 76: onReturn?() // return / numpad enter
            case 53:  onEscape?()   // esc
            default: super.keyDown(with: event)
            }
        }
    }
}
