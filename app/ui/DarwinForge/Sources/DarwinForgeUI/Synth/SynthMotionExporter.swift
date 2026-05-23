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
        }
    }
}
