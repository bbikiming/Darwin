import AppKit
import UniformTypeIdentifiers

private enum Design {
    static let windowSize = NSSize(width: 920, height: 660)
    static let windowMinSize = NSSize(width: 840, height: 600)
    static let outerInset: CGFloat = 20
    static let sectionGap: CGFloat = 16
    static let cardInset: CGFloat = 16
    static let cornerRadius: CGFloat = 13
    static let sidebarWidth: CGFloat = 260
    static let bodyFont: CGFloat = 13
    static let captionFont: CGFloat = 12
    static let titleFont: CGFloat = 22
}

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var retainedDelegate: AppDelegate?

    var windowController: InjectorWindowController?

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = NSImage(named: "AppIcon")
        installMainMenu()

        let controller = InjectorWindowController()
        windowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

final class InjectorWindowController: NSWindowController {
    init() {
        let viewController = InjectorViewController()
        let window = NSWindow(contentViewController: viewController)
        window.title = "Darwin Switch RCM Injector"
        window.setContentSize(Design.windowSize)
        window.minSize = Design.windowMinSize
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

final class InjectorViewController: NSViewController {
    private let repoRoot: URL
    private let injectorScript: URL
    private let appSupport: URL
    private let logsURL: URL

    private let payloadField = NSTextField()
    private let payloadFileLabel = NSTextField(labelWithString: "")
    private let scriptStatus = NSTextField(labelWithString: "")
    private let payloadStatus = NSTextField(labelWithString: "")
    private let usbStatus = NSTextField(labelWithString: "")
    private let rcmStatus = NSTextField(labelWithString: "")
    private let connectionTitle = NSTextField(labelWithString: "")
    private let connectionBody = NSTextField(labelWithString: "")
    private let footerStatus = NSTextField(labelWithString: "")
    private let checkButton = NSButton(title: "준비 검사", target: nil, action: nil)
    private let refreshButton = NSButton(title: "연결 다시 확인", target: nil, action: nil)
    private let injectButton = NSButton(title: "Hekate 주입", target: nil, action: nil)
    private let chooseButton = NSButton(title: "파일 선택", target: nil, action: nil)
    private let revealButton = NSButton(title: "Finder에서 보기", target: nil, action: nil)
    private let logsButton = NSButton(title: "로그 폴더 열기", target: nil, action: nil)
    private let clearButton = NSButton(title: "로그 비우기", target: nil, action: nil)
    private let logView = NSTextView()

    private var rcmDetected = false
    private var runningProcess: Process?
    private var pollTimer: Timer?

    init() {
        let bundleURL = Bundle.main.bundleURL
        let discoveredRepoRoot = Self.discoverRepoRoot(from: bundleURL)
        let rootFromBundle = discoveredRepoRoot ?? bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bundledResourceRoot = Bundle.main.resourceURL ?? bundleURL
        let bundledScript = bundledResourceRoot.appendingPathComponent("darwin-switch-rcm-inject.sh")
        let repoScript = rootFromBundle.appendingPathComponent("tools/switch-pilot/mac-rcm-injector/darwin-switch-rcm-inject.sh")
        if FileManager.default.isExecutableFile(atPath: bundledScript.path) {
            self.repoRoot = rootFromBundle
            self.injectorScript = bundledScript
        } else {
            self.repoRoot = rootFromBundle
            self.injectorScript = repoScript
        }
        self.appSupport = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DarwinSwitchRCM")
        self.logsURL = appSupport.appendingPathComponent("logs")
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    private static func discoverRepoRoot(from startURL: URL) -> URL? {
        var cursor = startURL.standardizedFileURL
        let fileManager = FileManager.default
        for _ in 0..<12 {
            let toolsPath = cursor.appendingPathComponent("tools/switch-pilot/mac-rcm-injector/darwin-switch-rcm-inject.sh").path
            let distPath = cursor.appendingPathComponent("dist/switch-pilot").path
            var isDirectory = ObjCBool(false)
            let hasDist = fileManager.fileExists(atPath: distPath, isDirectory: &isDirectory) && isDirectory.boolValue
            if fileManager.isExecutableFile(atPath: toolsPath) || hasDist {
                return cursor
            }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path {
                break
            }
            cursor = parent
        }
        return nil
    }

    override func loadView() {
        let root = NSVisualEffectView()
        root.material = .windowBackground
        root.blendingMode = .behindWindow
        root.state = .active
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildInterface()
        payloadField.stringValue = findDefaultPayload()?.path ?? ""
        appendLog("앱이 준비되었습니다.\n")
        appendLog("SD 카드는 스위치에 넣고, Mac에는 로컬 Hekate payload를 남겨둔 상태가 가장 안정적입니다.\n\n")
        validateState()
        refreshRCMStatus()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshRCMStatus(silent: true)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(refreshButton)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        pollTimer?.invalidate()
        runningProcess?.terminate()
    }

    private func buildInterface() {
        let root = NSStackView()
        root.orientation = .horizontal
        root.spacing = Design.sectionGap
        root.edgeInsets = NSEdgeInsets(
            top: Design.outerInset + 30,
            left: Design.outerInset,
            bottom: Design.outerInset,
            right: Design.outerInset
        )
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        root.addArrangedSubview(makeSidebar())
        root.addArrangedSubview(makeMainColumn())
    }

    private func makeSidebar() -> NSView {
        let box = makeCard(fill: NSColor.controlBackgroundColor.withAlphaComponent(0.72))
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: Design.sidebarWidth).isActive = true

        let stack = makeVStack(spacing: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(stack)
        pin(stack, to: box.contentView!, inset: Design.cardInset)

        let icon = NSImageView()
        icon.image = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 58),
            icon.heightAnchor.constraint(equalToConstant: 58)
        ])

        let titleStack = makeVStack(spacing: 4)
        titleStack.addArrangedSubview(makeLabel("Darwin RCM", size: 21, weight: .semibold))
        titleStack.addArrangedSubview(makeLabel("스위치용 Hekate 주입", size: Design.bodyFont, color: .secondaryLabelColor))

        let header = makeHStack(spacing: 12, alignment: .centerY)
        header.addArrangedSubview(icon)
        header.addArrangedSubview(titleStack)
        stack.addArrangedSubview(header)

        stack.addArrangedSubview(makeDivider())
        stack.addArrangedSubview(makeChecklist())
        stack.addArrangedSubview(makeDivider())

        stack.addArrangedSubview(makeStatusRow(symbol: "terminal", title: "주입 도구", value: scriptStatus))
        stack.addArrangedSubview(makeStatusRow(symbol: "doc", title: "Payload", value: payloadStatus))
        stack.addArrangedSubview(makeStatusRow(symbol: "cable.connector", title: "USB/libusb", value: usbStatus))
        stack.addArrangedSubview(makeStatusRow(symbol: "switch.2", title: "RCM 연결", value: rcmStatus))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        stack.addArrangedSubview(spacer)

        let note = makeLabel(
            "RCM/APX 감지 후 주입 가능",
            size: Design.captionFont,
            color: .secondaryLabelColor
        )
        note.maximumNumberOfLines = 3
        stack.addArrangedSubview(note)

        return box
    }

    private func makeChecklist() -> NSView {
        let stack = makeVStack(spacing: 10)
        stack.addArrangedSubview(makeSectionTitle("진행 순서"))
        stack.addArrangedSubview(makeStep(number: "1", text: "SD 카드를 스위치에 삽입"))
        stack.addArrangedSubview(makeStep(number: "2", text: "전원 완전 종료"))
        stack.addArrangedSubview(makeStep(number: "3", text: "RCM jig 장착 후 VOL+ + POWER"))
        stack.addArrangedSubview(makeStep(number: "4", text: "검은 화면 상태에서 Mac에 연결"))
        return stack
    }

    private func makeMainColumn() -> NSView {
        let stack = makeVStack(spacing: Design.sectionGap)
        stack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        stack.addArrangedSubview(makeConnectionPanel())
        stack.addArrangedSubview(makePayloadPanel())
        stack.addArrangedSubview(makeActionPanel())
        stack.addArrangedSubview(makeLogPanel())
        stack.addArrangedSubview(makeFooter())
        return stack
    }

    private func makeConnectionPanel() -> NSView {
        let box = makeCard()
        let stack = makeVStack(spacing: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(stack)
        pin(stack, to: box.contentView!, inset: Design.cardInset)

        let heading = makeHStack(spacing: 12, alignment: .centerY)
        heading.addArrangedSubview(makeSymbol("dot.radiowaves.left.and.right", pointSize: 24, color: .systemBlue))

        let textStack = makeVStack(spacing: 3)
        connectionTitle.font = .systemFont(ofSize: Design.titleFont, weight: .semibold)
        connectionTitle.textColor = .labelColor
        connectionBody.font = .systemFont(ofSize: Design.bodyFont)
        connectionBody.textColor = .secondaryLabelColor
        connectionBody.maximumNumberOfLines = 2
        textStack.addArrangedSubview(connectionTitle)
        textStack.addArrangedSubview(connectionBody)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        heading.addArrangedSubview(textStack)
        heading.addArrangedSubview(spacer)
        heading.addArrangedSubview(refreshButton)

        configureButton(refreshButton, symbol: "arrow.clockwise")
        refreshButton.target = self
        refreshButton.action = #selector(refreshPressed)
        refreshButton.toolTip = "스위치가 APX/RCM으로 잡히는지 다시 확인합니다."

        stack.addArrangedSubview(heading)

        let detail = makeLabel(
            "정상 RCM 상태에서는 스위치 화면이 계속 검은색이고, Mac USB 장치 목록에는 APX로 표시됩니다.",
            size: Design.captionFont,
            color: .secondaryLabelColor
        )
        detail.maximumNumberOfLines = 2
        stack.addArrangedSubview(detail)
        return box
    }

    private func makePayloadPanel() -> NSView {
        let box = makeCard()
        let stack = makeVStack(spacing: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(stack)
        pin(stack, to: box.contentView!, inset: Design.cardInset)

        let titleRow = makeHStack(spacing: 10, alignment: .centerY)
        titleRow.addArrangedSubview(makeSymbol("shippingbox", pointSize: 18, color: .systemBlue))
        titleRow.addArrangedSubview(makeSectionTitle("주입할 Hekate payload"))
        let titleSpacer = NSView()
        titleSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleRow.addArrangedSubview(titleSpacer)
        titleRow.addArrangedSubview(payloadFileLabel)
        payloadFileLabel.font = .systemFont(ofSize: Design.captionFont, weight: .medium)
        payloadFileLabel.textColor = .secondaryLabelColor
        payloadFileLabel.lineBreakMode = .byTruncatingMiddle
        stack.addArrangedSubview(titleRow)

        let row = makeHStack(spacing: 10, alignment: .centerY)
        payloadField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        payloadField.placeholderString = "hekate_ctcaer_*.bin 파일 경로"
        payloadField.target = self
        payloadField.action = #selector(payloadEdited)
        payloadField.toolTip = "SD가 스위치에 들어가면 /Volumes/SWITCHSD 경로는 사라지므로 Mac 로컬 파일을 권장합니다."

        configureButton(chooseButton, symbol: "folder")
        chooseButton.target = self
        chooseButton.action = #selector(choosePayload)
        chooseButton.toolTip = "다른 Hekate payload 파일을 선택합니다."

        configureButton(revealButton, symbol: "magnifyingglass")
        revealButton.target = self
        revealButton.action = #selector(revealPayload)
        revealButton.toolTip = "선택한 payload를 Finder에서 표시합니다."

        row.addArrangedSubview(payloadField)
        row.addArrangedSubview(chooseButton)
        row.addArrangedSubview(revealButton)
        stack.addArrangedSubview(row)

        let hint = makeLabel(
            "권장: dist/switch-pilot/hekate_ctcaer_6.5.2.bin 처럼 Mac 안에 있는 복사본을 사용하세요.",
            size: Design.captionFont,
            color: .secondaryLabelColor
        )
        hint.maximumNumberOfLines = 2
        stack.addArrangedSubview(hint)
        return box
    }

    private func makeActionPanel() -> NSView {
        let box = makeCard()
        let stack = makeVStack(spacing: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(stack)
        pin(stack, to: box.contentView!, inset: Design.cardInset)

        stack.addArrangedSubview(makeSectionTitle("실행"))

        let row = makeHStack(spacing: 10, alignment: .centerY)
        configureButton(checkButton, symbol: "checkmark.shield")
        configureButton(injectButton, symbol: "bolt.fill", isPrimary: true)
        configureButton(logsButton, symbol: "folder.badge.gearshape")
        configureButton(clearButton, symbol: "trash")

        checkButton.target = self
        checkButton.action = #selector(runCheck)
        checkButton.toolTip = "payload, libusb, APX 감지를 검사합니다. 실제 주입은 하지 않습니다."

        injectButton.target = self
        injectButton.action = #selector(runInjection)
        injectButton.keyEquivalent = "\r"
        injectButton.toolTip = "RCM/APX 감지 후 Hekate payload를 주입합니다."

        logsButton.target = self
        logsButton.action = #selector(openLogs)

        clearButton.target = self
        clearButton.action = #selector(clearLogs)

        row.addArrangedSubview(checkButton)
        row.addArrangedSubview(injectButton)
        row.addArrangedSubview(logsButton)
        row.addArrangedSubview(clearButton)
        stack.addArrangedSubview(row)

        let hint = makeLabel(
            "주입 중에는 USB-C 케이블을 분리하지 마세요. 성공하면 스위치에 Hekate/Nyx 화면이 나타납니다.",
            size: Design.captionFont,
            color: .secondaryLabelColor
        )
        hint.maximumNumberOfLines = 2
        stack.addArrangedSubview(hint)
        return box
    }

    private func makeLogPanel() -> NSView {
        let box = makeCard()
        box.setContentHuggingPriority(.defaultLow, for: .vertical)
        let stack = makeVStack(spacing: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.contentView?.addSubview(stack)
        pin(stack, to: box.contentView!, inset: Design.cardInset)

        let row = makeHStack(spacing: 8, alignment: .centerY)
        row.addArrangedSubview(makeSymbol("text.alignleft", pointSize: 16, color: .secondaryLabelColor))
        row.addArrangedSubview(makeSectionTitle("실행 로그"))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        stack.addArrangedSubview(row)

        logView.isEditable = false
        logView.isRichText = false
        logView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        logView.textColor = .labelColor
        logView.backgroundColor = NSColor.textBackgroundColor
        logView.textContainerInset = NSSize(width: 12, height: 10)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .lineBorder
        scroll.documentView = logView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        stack.addArrangedSubview(scroll)
        return box
    }

    private func makeFooter() -> NSView {
        let stack = makeHStack(spacing: 10, alignment: .centerY)
        footerStatus.font = .systemFont(ofSize: Design.captionFont)
        footerStatus.textColor = .secondaryLabelColor
        footerStatus.lineBreakMode = .byTruncatingMiddle

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let quit = NSButton(title: "닫기", target: self, action: #selector(closeApp))
        configureButton(quit)
        stack.addArrangedSubview(footerStatus)
        stack.addArrangedSubview(spacer)
        stack.addArrangedSubview(quit)
        return stack
    }

    private func makeStatusRow(symbol: String, title: String, value: NSTextField) -> NSView {
        let row = makeHStack(spacing: 10, alignment: .centerY)
        row.addArrangedSubview(makeSymbol(symbol, pointSize: 15, color: .secondaryLabelColor))

        let textStack = makeVStack(spacing: 2)
        textStack.addArrangedSubview(makeLabel(title, size: Design.captionFont, color: .secondaryLabelColor))
        value.font = .systemFont(ofSize: 13, weight: .medium)
        value.lineBreakMode = .byTruncatingTail
        textStack.addArrangedSubview(value)

        row.addArrangedSubview(textStack)
        return row
    }

    private func makeStep(number: String, text: String) -> NSView {
        let row = makeHStack(spacing: 9, alignment: .centerY)

        let badge = NSTextField(labelWithString: number)
        badge.alignment = .center
        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 9
        badge.layer?.backgroundColor = NSColor.systemBlue.cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 18),
            badge.heightAnchor.constraint(equalToConstant: 18)
        ])

        let label = makeLabel(text, size: 12.5, color: .labelColor)
        label.maximumNumberOfLines = 2
        row.addArrangedSubview(badge)
        row.addArrangedSubview(label)
        return row
    }

    private func makeCard(fill: NSColor = NSColor.controlBackgroundColor.withAlphaComponent(0.86)) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = Design.cornerRadius
        box.borderColor = NSColor.separatorColor.withAlphaComponent(0.45)
        box.borderWidth = 1
        box.fillColor = fill
        return box
    }

    private func makeDivider() -> NSView {
        let divider = NSBox()
        divider.boxType = .separator
        return divider
    }

    private func makeVStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func makeHStack(spacing: CGFloat, alignment: NSLayoutConstraint.Attribute = .top) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = alignment
        stack.spacing = spacing
        return stack
    }

    private func makeSectionTitle(_ text: String) -> NSTextField {
        makeLabel(text, size: Design.bodyFont, weight: .semibold)
    }

    private func makeLabel(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func makeSymbol(_ name: String, pointSize: CGFloat, color: NSColor) -> NSImageView {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        let imageView = NSImageView(image: image ?? NSImage())
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        imageView.contentTintColor = color
        imageView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: max(18, pointSize + 4)),
            imageView.heightAnchor.constraint(equalToConstant: max(18, pointSize + 4))
        ])
        return imageView
    }

    private func configureButton(_ button: NSButton, symbol: String? = nil, isPrimary: Bool = false) {
        button.bezelStyle = .rounded
        button.controlSize = isPrimary ? .large : .regular
        button.font = .systemFont(ofSize: isPrimary ? 14 : 13, weight: .medium)
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.contentTintColor = isPrimary ? .white : .controlTextColor
        }
        if isPrimary {
            button.bezelColor = .systemBlue
        }
    }

    private func pin(_ child: NSView, to parent: NSView, inset: CGFloat) {
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }

    private func findDefaultPayload() -> URL? {
        let candidates: [URL] = [
            repoRoot.appendingPathComponent("dist/switch-pilot/hekate_ctcaer_6.5.2.bin"),
            appSupport.appendingPathComponent("payloads/hekate_ctcaer_6.5.2.bin")
        ]

        for candidate in candidates where FileManager.default.isReadableFile(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    private func validateState() {
        let scriptOK = FileManager.default.isExecutableFile(atPath: injectorScript.path)
        let payloadOK = FileManager.default.isReadableFile(atPath: payloadField.stringValue)
        let libusbOK = findLibUSB() != nil

        payloadFileLabel.stringValue = payloadOK
            ? URL(fileURLWithPath: payloadField.stringValue).lastPathComponent
            : "파일 선택 필요"

        setStatus(scriptStatus, text: scriptOK ? "준비됨" : "스크립트 없음", state: scriptOK ? .ok : .bad)
        setStatus(payloadStatus, text: payloadOK ? "선택됨" : "선택 필요", state: payloadOK ? .ok : .bad)
        setStatus(usbStatus, text: libusbOK ? "준비됨" : "libusb 필요", state: libusbOK ? .ok : .bad)

        if runningProcess != nil {
            connectionTitle.stringValue = "작업 실행 중"
            connectionBody.stringValue = "완료될 때까지 USB-C 케이블을 분리하지 마세요."
        } else if rcmDetected {
            connectionTitle.stringValue = "스위치가 RCM으로 연결됨"
            connectionBody.stringValue = "APX 장치를 감지했습니다. Hekate 주입을 진행할 수 있습니다."
        } else {
            connectionTitle.stringValue = "스위치 연결 대기 중"
            connectionBody.stringValue = "RCM jig로 진입한 뒤 USB-C 데이터 케이블로 Mac에 연결하세요."
        }

        injectButton.isEnabled = scriptOK && payloadOK && libusbOK && rcmDetected && runningProcess == nil
        injectButton.bezelColor = injectButton.isEnabled ? .systemBlue : nil
        injectButton.contentTintColor = injectButton.isEnabled ? .white : .secondaryLabelColor
        checkButton.isEnabled = scriptOK && payloadOK && runningProcess == nil
        refreshButton.isEnabled = runningProcess == nil
        chooseButton.isEnabled = runningProcess == nil
        revealButton.isEnabled = payloadOK
        logsButton.isEnabled = true

        if runningProcess != nil {
            footerStatus.stringValue = "실행 중입니다. 완료 전까지 케이블을 분리하지 마세요."
        } else if !rcmDetected {
            footerStatus.stringValue = "스위치가 APX/RCM으로 감지되면 Hekate 주입 버튼이 활성화됩니다."
        } else {
            footerStatus.stringValue = "준비 완료. Hekate 주입을 시작할 수 있습니다."
        }
    }

    private func findLibUSB() -> String? {
        let candidates = [
            "/opt/homebrew/lib/libusb-1.0.dylib",
            "/usr/local/lib/libusb-1.0.dylib",
            "/opt/homebrew/opt/libusb/lib/libusb-1.0.dylib",
            "/usr/local/opt/libusb/lib/libusb-1.0.dylib"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private enum StatusState {
        case ok
        case waiting
        case bad

        var color: NSColor {
            switch self {
            case .ok: return .systemGreen
            case .waiting: return .systemOrange
            case .bad: return .systemRed
            }
        }
    }

    private func setStatus(_ label: NSTextField, text: String, state: StatusState) {
        let value = NSMutableAttributedString(string: "● \(text)")
        value.addAttribute(.foregroundColor, value: state.color, range: NSRange(location: 0, length: 1))
        value.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 2, length: text.count))
        label.attributedStringValue = value
    }

    private func refreshRCMStatus(silent: Bool = false) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let detected = Self.detectAPX()
            DispatchQueue.main.async {
                guard let self else { return }
                self.rcmDetected = detected
                self.setStatus(self.rcmStatus, text: detected ? "APX 감지됨" : "연결 대기", state: detected ? .ok : .waiting)
                if !silent {
                    self.appendLog(detected ? "[앱] APX RCM 장치를 감지했습니다.\n" : "[앱] 아직 APX RCM 장치를 찾지 못했습니다.\n")
                }
                self.validateState()
            }
        }
    }

    private static func detectAPX() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "/usr/sbin/ioreg -p IOUSB -l -w0 | /usr/bin/grep -E 'APX|NVIDIA Corp.|\"idVendor\" = 2389|\"idProduct\" = 29473' || true"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return false
        }

        let normalized = output.replacingOccurrences(of: " ", with: "")
        if output.localizedCaseInsensitiveContains("APX")
            && output.localizedCaseInsensitiveContains("NVIDIA Corp.") {
            return true
        }
        if output.contains("APX@")
            || output.contains("USB Product Name\" = \"APX")
            || output.contains("kUSBProductString\" = \"APX")
            || (normalized.contains("\"idVendor\"=2389") && normalized.contains("\"idProduct\"=29473")) {
            return true
        }

        for block in output.components(separatedBy: "+-o ") {
            let hasAPXName = block.contains("\"USB Product Name\" = \"APX\"")
                || block.contains("\"kUSBProductString\" = \"APX\"")
                || block.contains("APX@")
            let hasTegraIDs = block.contains("\"idVendor\" = 2389")
                && block.contains("\"idProduct\" = 29473")
            if hasAPXName || hasTegraIDs {
                return true
            }
        }

        return false
    }

    @objc private func payloadEdited() {
        validateState()
    }

    @objc private func choosePayload() {
        let panel = NSOpenPanel()
        panel.title = "Hekate payload 선택"
        panel.message = "Mac에 저장된 hekate_ctcaer_*.bin 파일을 선택하세요."
        if let binType = UTType(filenameExtension: "bin") {
            panel.allowedContentTypes = [binType]
        }
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            payloadField.stringValue = url.path
            appendLog("[앱] Payload 선택: \(url.path)\n")
            validateState()
        }
    }

    @objc private func revealPayload() {
        let path = payloadField.stringValue
        guard FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func openLogs() {
        try? FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(logsURL)
    }

    @objc private func clearLogs() {
        logView.string = ""
        appendLog("로그를 비웠습니다.\n")
    }

    @objc private func refreshPressed() {
        refreshRCMStatus()
    }

    @objc private func runCheck() {
        runInjector(arguments: ["--payload", payloadField.stringValue, "--check-only"], label: "준비 검사")
    }

    @objc private func runInjection() {
        let alert = NSAlert()
        alert.messageText = "Hekate를 주입할까요?"
        alert.informativeText = "스위치 화면이 검은 상태이고 RCM/APX가 감지된 경우에만 진행하세요."
        alert.addButton(withTitle: "주입")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        runInjector(arguments: ["--payload", payloadField.stringValue, "--no-wait"], label: "Hekate 주입")
    }

    private func runInjector(arguments: [String], label: String) {
        guard runningProcess == nil else { return }
        validateState()

        appendLog("\n[앱] \(label) 시작\n")
        appendLog("[앱] 스크립트: \(injectorScript.path)\n")
        appendLog("[앱] 인자: \(arguments.joined(separator: " "))\n\n")

        let process = Process()
        process.executableURL = injectorScript
        process.arguments = arguments
        process.currentDirectoryURL = repoRoot

        var environment = ProcessInfo.processInfo.environment
        environment["DARWIN_SWITCH_RCM_NONINTERACTIVE"] = "1"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        runningProcess = process
        validateState()

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
                return
            }
            DispatchQueue.main.async {
                self?.appendLog(text)
            }
        }

        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                self?.runningProcess = nil
                self?.appendLog("\n[앱] \(label) 종료 코드: \(finished.terminationStatus)\n")
                self?.refreshRCMStatus(silent: true)
                self?.validateState()
            }
        }

        do {
            try process.run()
        } catch {
            runningProcess = nil
            appendLog("[앱] 실행 실패: \(error.localizedDescription)\n")
            validateState()
        }
    }

    private func appendLog(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.labelColor
        ]
        logView.textStorage?.append(NSAttributedString(string: text, attributes: attributes))
        logView.scrollToEndOfDocument(nil)
    }

    @objc private func closeApp() {
        NSApp.terminate(nil)
    }
}

private func installMainMenu() {
    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(
        withTitle: "Darwin Switch RCM Injector 종료",
        action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q"
    )
    appMenuItem.submenu = appMenu
    mainMenu.addItem(appMenuItem)
    NSApp.mainMenu = mainMenu
}
