import SwiftUI

/// Figma / Adobe XD 스타일 정밀 숫자 입력 필드.
///
/// 인터랙션:
///   1. **− / + 버튼** — 양옆에 22×22pt 클릭 영역 (Apple HIG 마우스 최소).
///                    클릭 시 ±step, Shift 누른 채 클릭 시 ±bigStep.
///   2. **클릭 → 편집** — 숫자 클릭하면 TextField 포커스 + 전체 선택.
///   3. **키보드** (focus 시):
///       - Enter / Tab : 커밋
///       - Esc         : 취소 (focus 진입 시점 값 복원)
///       - ↑/↓         : ±step  (선택, AppKit 기반)
///       - Shift+↑/↓   : ±bigStep
///   4. **단위 suffix** ("°", "%") — 비편집, 숫자만 편집/파싱
///   5. **외부 동기화** — value 가 외부에서 변경되면 (슬라이더 등) 자동 반영
///
/// 시각:
///   - default : 미묘한 elev2 배경 + 얇은 보더 → 입력 가능함이 명확
///   - hover   : elev2 강화
///   - focus   : accent 보더 + elev2
///   - warning : tint 색 (한계 근처 등)
public struct StepperField: View {
    @Binding public var value: Double
    public let range: ClosedRange<Double>
    public let step: Double
    public let bigStep: Double
    public let unit: String
    public let format: (Double) -> String
    public let tint: Color?
    public let fieldWidth: CGFloat?
    public let onCommit: ((Double) -> Void)?

    @State private var draft: String = ""
    @FocusState private var focused: Bool
    @State private var hovering: Bool = false
    @State private var beforeFocusValue: Double = 0

    public init(
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double = 1,
        bigStep: Double? = nil,
        unit: String = "",
        format: @escaping (Double) -> String = { "\(Int($0.rounded()))" },
        tint: Color? = nil,
        fieldWidth: CGFloat? = nil,
        onCommit: ((Double) -> Void)? = nil
    ) {
        self._value = value
        self.range = range
        self.step = step
        self.bigStep = bigStep ?? (step * 10)
        self.unit = unit
        self.format = format
        self.tint = tint
        self.fieldWidth = fieldWidth
        self.onCommit = onCommit
        // draft 초기값을 init 에 동기 — onAppear 전에도 올바른 값 표시.
        self._draft = State(initialValue: format(value.wrappedValue))
        self._beforeFocusValue = State(initialValue: value.wrappedValue)
    }

    public var body: some View {
        HStack(spacing: 3) {
            stepperButton(direction: -1, system: "minus")
            valueField
            stepperButton(direction: +1, system: "plus")
        }
        // 외부에서 value 가 변경되면 (슬라이더, 다른 입력 경로) draft 동기화.
        // 사용자가 타이핑 중일 때(focused)는 덮어쓰지 않음.
        .onChange(of: value) { _, newValue in
            if !focused {
                draft = format(newValue)
            }
        }
        // 포커스 진입 시: 원값 백업 + draft 재동기화 + (가능하면) 전체 선택.
        // 포커스 손실 시: 자동 커밋.
        .onChange(of: focused) { _, isFocused in
            if isFocused {
                beforeFocusValue = value
                draft = format(value)
                #if canImport(AppKit)
                DispatchQueue.main.async {
                    NSApp.keyWindow?.firstResponder?
                        .tryToPerform(#selector(NSText.selectAll(_:)), with: nil)
                }
                #endif
            } else {
                commit()
            }
        }
    }

    // MARK: - Value field

    private var valueField: some View {
        HStack(spacing: 0) {
            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(textTint)
                .focused($focused)
                .frame(width: fieldWidth)
                .fixedSize(horizontal: fieldWidth == nil, vertical: true)
                .onSubmit { commit() }
                .onExitCommand { revert() }   // Esc

            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(textTint.opacity(0.75))
                    .padding(.leading, 1)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 22)
        .background(fieldBackground)
        .overlay(fieldBorder)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { focused = true }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(
                focused
                    ? DFColor.elev2
                    : (hovering ? DFColor.elev2.opacity(0.65) : DFColor.elev2.opacity(0.30))
            )
    }

    private var fieldBorder: some View {
        RoundedRectangle(cornerRadius: 5)
            .stroke(
                focused ? DFColor.accent : DFColor.textSecondary.opacity(0.18),
                lineWidth: focused ? 1.0 : 0.5
            )
    }

    private var textTint: Color {
        tint ?? DFColor.textPrimary
    }

    // MARK: - Stepper buttons

    private func stepperButton(direction: Double, system: String) -> some View {
        StepperButton(
            system: system,
            direction: direction,
            step: step,
            bigStep: bigStep,
            unit: unit,
            action: { actualDir in increment(direction: actualDir) }
        )
    }

    // MARK: - Mutators

    private func increment(direction: Double) {
        let actualStep: Double = {
            #if canImport(AppKit)
            return NSEvent.modifierFlags.contains(.shift) ? bigStep : step
            #else
            return step
            #endif
        }()
        set(value + actualStep * direction, commit: true)
    }

    private func set(_ newValue: Double, commit doCommit: Bool) {
        let clamped = min(max(newValue, range.lowerBound), range.upperBound)
        let snapped = (clamped / step).rounded() * step
        value = snapped
        if !focused {
            draft = format(snapped)
        }
        if doCommit {
            onCommit?(snapped)
        }
    }

    /// 사용자가 입력한 draft 문자열을 정리·파싱·커밋.
    /// 허용: "-45", "+45", "45°", "45 °", "45.5" 등.
    private func commit() {
        let cleaned = draft
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: unit, with: "")
            .replacingOccurrences(of: "°", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard let parsed = Double(cleaned) else {
            // 파싱 실패 → 마지막 valid 값으로 복원.
            draft = format(value)
            return
        }
        set(parsed, commit: true)
        draft = format(value)
    }

    private func revert() {
        let original = beforeFocusValue
        value = original
        draft = format(original)
        focused = false
        onCommit?(original)
    }
}

// MARK: - Stepper button (자체 hover 상태 보유)

/// 22×22pt 정사각 hit-target (Apple HIG mouse 권장 최소).
/// hover 시 elev2 강조, press 시 0.92 scale.
private struct StepperButton: View {
    let system: String
    let direction: Double
    let step: Double
    let bigStep: Double
    let unit: String
    let action: (Double) -> Void

    @State private var hovering: Bool = false

    var body: some View {
        Button {
            action(direction)
        } label: {
            Image(systemName: system)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22)
                .foregroundStyle(hovering ? DFColor.textPrimary : DFColor.textSecondary)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovering ? DFColor.elev2 : DFColor.elev2.opacity(0.30))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            hovering ? DFColor.textSecondary.opacity(0.30)
                                     : DFColor.textSecondary.opacity(0.18),
                            lineWidth: 0.5
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.10), value: hovering)
        .help("\(direction > 0 ? "+" : "−")\(formatStep(step))\(unit) " +
              "(Shift: ±\(formatStep(bigStep))\(unit))")
    }

    private func formatStep(_ v: Double) -> String {
        if v == v.rounded() { return "\(Int(v))" }
        return String(format: "%.2g", v)
    }
}
