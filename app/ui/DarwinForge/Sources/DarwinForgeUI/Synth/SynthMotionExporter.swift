import ForgeCore
import Foundation

/// 사이클 180 (P0 #3.2 fix, cycle 177 audit): Synth 합성 결과 (`resultJSON`) → Motion
/// Studio 적용 path 의 pure logic.
///
/// # 비유
///
/// 음식 조리 과정 (Synth) 과 진열 (Motion Studio) 사이의 conveyor belt. 이전엔 사용자가
/// 결과를 한 그릇 에서 다른 그릇 으로 외부 도구 (forge CLI) 로 옮겨야 함 → 사용 흐름 끊김.
/// 이제 본 exporter 가 JSON 디코딩 + 유효성 검사 + page list 추출 을 책임.
///
/// # 디자인
///
/// - **Pure logic**: view layer 무관 (decode + validate). 테스트 격리 용이.
/// - **명시 error**: caller 가 사용자 에러 메시지 매핑 분기 가능.
/// - **page 만 반환**: 사용자가 robotGeneration / version 등 motion-doc 메타데이터 까지
///   덮어쓰지 않게. Motion Studio 가 자체 metadata 유지.
public enum SynthMotionExporter {

    /// 추출 결과 / 실패.
    public enum ExportError: Error, Equatable {
        /// JSON 자체가 비어있음 (Synthesize 안 함 / 실패).
        case emptyJSON
        /// JSON 디코딩 실패 — Motion Doc schema 불일치.
        case decodeFailed(String)
        /// 디코딩은 됐는데 pages 배열 이 비어있음 (의미 없는 결과).
        case noPages
        /// 사이클 187 (codex MAJOR fix): UInt8 page ID overflow.
        /// `existingMaxId + pages.count > 255` 시 ID 재할당 불가능.
        /// associated: (existingMaxId, importCount).
        case idOverflow(existingMaxId: Int, importCount: Int)
    }

    /// `resultJSON` (Synthesize 결과) → MotionPage 배열 추출.
    ///
    /// - Parameter resultJSON: SynthBridge 의 motionJSON 출력 (또는 SynthModel.resultJSON).
    ///   nil / 공백 = `.emptyJSON`.
    public static func pages(from resultJSON: String?) -> Result<[MotionPage], ExportError> {
        guard let raw = resultJSON?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return .failure(.emptyJSON)
        }
        do {
            let doc = try MotionDoc.from(json: raw)
            guard !doc.pages.isEmpty else {
                return .failure(.noPages)
            }
            return .success(doc.pages)
        } catch {
            return .failure(.decodeFailed(error.localizedDescription))
        }
    }

    /// 사용자 표시용 한국어 메시지.
    public static func koreanMessage(for error: ExportError) -> String {
        switch error {
        case .emptyJSON:
            return "합성 결과가 없습니다 — 먼저 Synthesize 를 실행하세요"
        case .decodeFailed(let detail):
            return "합성 결과 디코딩 실패 — \(detail)"
        case .noPages:
            return "합성 결과에 적용할 페이지가 없습니다"
        case .idOverflow(let max, let count):
            return "Motion Studio 의 page ID 가 최대치 (255) 초과 — 기존 max=\(max) + 새 \(count) 페이지. " +
                   "기존 page 일부 삭제 후 다시 시도하세요."
        }
    }

    /// 사이클 187 (codex MAJOR fix): import 시 신규 page 의 ID 재할당 — overflow guard.
    ///
    /// # 동작
    ///
    /// 1. existingMaxId 가 (255 - importCount) 보다 크면 `.idOverflow` 반환.
    /// 2. 안전한 경우 `existingMaxId + 1` 부터 순차 할당, name prefix "Synth · " 추가.
    /// 3. UInt8(clamping:) 사용 X — 보장된 범위 내에서 직접 UInt8 변환.
    ///
    /// 종전 (cycle 180): `UInt8(clamping: existingMaxId + 1 + offset)` — 255 silently
    /// clamp 로 duplicate ID 생성 가능. cycle 185 codex MAJOR finding.
    public static func reassignPageIds(
        existingMaxId: Int,
        importPages: [MotionPage]
    ) -> Result<[MotionPage], ExportError> {
        let count = importPages.count
        guard existingMaxId + count <= 255 else {
            return .failure(.idOverflow(existingMaxId: existingMaxId, importCount: count))
        }
        var reassigned: [MotionPage] = []
        for (offset, p) in importPages.enumerated() {
            // 보장 범위 — overflow guard 통과 후 직접 UInt8 안전.
            let newId = UInt8(existingMaxId + 1 + offset)
            reassigned.append(MotionPage(
                id: newId,
                name: p.name.isEmpty ? "Synth \(newId)" : "Synth · \(p.name)",
                compliance: p.compliance,
                nextPage: p.nextPage,
                exitPage: p.exitPage,
                repeat: p.repeat,
                speed: p.speed,
                accel: p.accel,
                steps: p.steps
            ))
        }
        return .success(reassigned)
    }
}
