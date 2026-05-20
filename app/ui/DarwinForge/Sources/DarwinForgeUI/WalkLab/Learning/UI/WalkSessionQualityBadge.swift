import SwiftUI

/// 데이터 품질 등급 + useClass 라벨을 한 줄에 표시. 색 = grade 별 tint.
public struct WalkSessionQualityBadge: View {
    public let grade: WalkSessionGrade
    public let useClass: WalkSessionUseClass

    public init(grade: WalkSessionGrade, useClass: WalkSessionUseClass) {
        self.grade = grade
        self.useClass = useClass
    }

    public var body: some View {
        HStack(spacing: 6) {
            Text(grade.rawValue)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(gradeTint.opacity(0.18))
                .foregroundStyle(gradeTint)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            Text(WalkSessionLabels.useClassLabel(useClass))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var gradeTint: Color {
        switch grade {
        case .A: return .green
        case .B: return .blue
        case .C: return .orange
        case .D: return .yellow
        case .F: return .red
        }
    }
}
