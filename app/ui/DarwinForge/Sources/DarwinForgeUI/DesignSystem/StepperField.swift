import SwiftUI

/// Figma / Adobe XD 스타일 정밀 숫자 입력 필드.
///
/// 인터랙션:
///   1. **클릭** → 텍스트 필드로 전환, 커서 진입
///   2. **▲▼ 스피너** → 1단위 (또는 step) 증감. hover 시 표시
///   3. **드래그-스크럽** → 숫자 영역 가로 드래그 (1px ≈ step). Figma 시그니처
///   4. **키보드** (focus 시):
///       - ↑/↓        : ±step
///       - Shift+↑/↓  : ±bigStep (10×step)
///       - Enter/Tab  : 커밋
///       - Esc        : 취소 (원값 복원)
///   5. **단위 suffix** ("°", "%") — 비편집, 숫자만 편집
///
/// 시각 상태:
///   - default : 평문 (텍스트만)
///   - hover   : subtle elev2 배경 + ▲▼ 표시 + 가로-리사이즈 커서
///   - focus   : accent 보더 + elev2 배경
///   - warning : tint 색 적용 (한계 근처 등)
public struct StepperField: View {
    @Binding public var value: Double
    public let range: ClosedRange<Double>
    public let step: Double
    public let bigStep: Double
    public let unit: String
    public let format: (Double) -> String
    public let tint: Color?
    public let onCommit: ((Double) -> Void)?
    public let width: CGFloat?

    @State private var draft: String = ""
    @FocusState private var focused: Bool
    @State private var hovering: Bool = false
    @State private var scrubbing: Bool = false
    @State private var scrubStart: Double = 0
    @State private var beforeFocusValue: Double = 0

    public init(
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double = 1,
        bigStep: Double? = nil,
        unit: String = "",
        format: @escaping (Double) -> String = { "\(Int($0.rounded()))" },
        tint: Color? = nil,
        width: CGFloat? = nil,
        onCommit: ((Double) -> Void)? = nil
    ) {
        self._value = value
        self.range = range
        self.step = step
        self.bigStep = bigStep ?? (step * 10)
        self.unit = unit
        self.format = format
        self.tint = tint
        self.width = width
        self.onCommit = onCommit
    }

    public var body: some View {
        HStack(spacing: 1) {
            valueField
            stepperButtons
                .opacity(hovering || focused ? 1 : 0)
                .frame(width: hovering || focused ? 12 : 0)
                .clipped()
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: focused)
    }

    // MARK: - Field

    @ViewBuilder
    private var valueField: some View {
        HStack(spacing: 0) {
            TextField("", text: textBinding)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(textTint)
                .focused($focused)
                .frame(width: width)
                .fixedSize(horizontal: width == nil, vertical: true)
                .onSubmit { commit() }
                .onKeyPress(.escape) { revert(); return .handled }
                .onKeyPress(.upArrow) {
                    increment(direction: +1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    increment(direction: -1)
                    return .handled
                }

            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(textTint)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(fieldBackground)
        .overlay(fieldBorder)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onHover { isOver in
            hovering = isOver
            #if canImport(AppKit)
            if isOver && !focused {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
            #endif
        }
        .gesture(scrubGesture)
        .onChange(of: focused) { _, isFocused in
            if isFocused {
                beforeFocusValue = value
                draft = format(value)
            } else if !scrubbing {
                commit()
            }
        }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(focused ? DFColor.elev2
                  : (hovering ? DFColor.elev2.opacity(0.55) : Color.clear))
    }

    private var fieldBorder: some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(focused ? DFColor.accent : Color.clear, lineWidth: 0.8)
    }

    private var textTint: Color {
        tint ?? DFColor.textPrimary
    }

    /// 비편집 시에는 format(value), 편집 시에는 draft 사용.
    private var textBinding: Binding<String> {
        Binding(
            get: { focused ? draft : format(value) },
            set: { draft = $0 }
        )
    }

    // MARK: - Stepper buttons

    private var stepperButtons: some View {
        VStack(spacing: 0) {
            stepperArrow(direction: +1, system: "chevron.up")
            stepperArrow(direction: -1, system: "chevron.down")
        }
    }

    private func stepperArrow(direction: Double, system: String) -> some View {
        Button {
            increment(direction: direction)
        } label: {
            Image(systemName: system)
                .font(.system(size: 7, weight: .bold))
                .frame(width: 12, height: 9)
                .contentShape(Rectangle())
                .foregroundStyle(DFColor.textSecondary)
        }
        .buttonStyle(.plain)
        .help("\(direction > 0 ? "+" : "−")\(Int(step))\(unit)  (↑/↓: ±\(Int(step)), Shift+↑/↓: ±\(Int(bigStep)))")
    }

    // MARK: - Scrub gesture (Figma drag-to-scrub)

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { drag in
                if !scrubbing {
                    scrubbing = true
                    scrubStart = value
                }
                let delta = Double(drag.translation.width) * step
                set(scrubStart + delta, commit: false)
            }
            .onEnded { _ in
                if scrubbing {
                    scrubbing = false
                    onCommit?(value)
                }
            }
    }

    // MARK: - Mutators

    private func increment(direction: Double) {
        #if canImport(AppKit)
        let modifiers = NSEvent.modifierFlags
        let actualStep: Double = modifiers.contains(.shift) ? bigStep : step
        #else
        let actualStep: Double = step
        #endif
        set(value + actualStep * direction, commit: true)
    }

    private func set(_ newValue: Double, commit doCommit: Bool) {
        let clamped = min(max(newValue, range.lowerBound), range.upperBound)
        let snapped = (clamped / step).rounded() * step
        value = snapped
        if doCommit {
            onCommit?(snapped)
        }
    }

    private func commit() {
        // 비어 있으면 원값 유지.
        let cleaned = draft.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: unit, with: "")
        guard let parsed = Double(cleaned) else {
            draft = format(value)
            return
        }
        set(parsed, commit: true)
        draft = format(value)
    }

    private func revert() {
        value = beforeFocusValue
        draft = format(value)
        focused = false
    }
}
