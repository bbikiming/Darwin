import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// QR 코드 이미지 생성 뷰 — "우편 주소 쓴 봉투를 카메라가 읽는 것처럼"
/// payload 문자열을 CIQRCodeGenerator 로 변환하고 SwiftUI Image 로 렌더링한다.
///
/// 기술: CoreImage `CIQRCodeGenerator` 필터 (macOS 10.10+) 사용.
/// 오류 정정: H 레벨 (30% 손실 허용) — 화면 오염·각도 흔들림에 강인.
/// 색상: dark 모듈 = system 기본(검정/흰색), light 배경 = 흰색(스캐너 대비 최적).
/// 캐시: 동일 payload 재호출 시 재계산 없이 캐시된 Image 반환.
@available(macOS 11.0, *)
public struct QRCodeImage: View {

    // MARK: - 공개 입력

    /// QR 코드로 인코딩할 문자열 페이로드.
    public let payload: String

    /// 렌더링 크기 (가로=세로 정사각형, pt 단위).
    public let size: CGFloat

    // MARK: - 내부 상태

    /// payload 캐시 — 동일 문자열이면 재계산 없음.
    @State private var cachedPayload: String = ""
    @State private var cachedImage: Image? = nil

    // MARK: - 초기화

    public init(payload: String, size: CGFloat = 160) {
        self.payload = payload
        self.size = size
    }

    // MARK: - Body

    public var body: some View {
        Group {
            if let img = resolvedImage() {
                img
                    .interpolation(.none)           // 픽셀 선명도 유지 (nearest-neighbor)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .accessibilityLabel(accessibilityDescription)
            } else {
                // 생성 실패 fallback — 회색 사각형 + 아이콘
                ZStack {
                    RoundedRectangle(cornerRadius: DFRadius.sm)
                        .fill(Color(nsColor: .controlBackgroundColor))
                    Image(systemName: "qrcode")
                        .font(.system(size: size * 0.3))
                        .foregroundStyle(.secondary)
                }
                .frame(width: size, height: size)
                .accessibilityLabel("QR 코드 생성 실패")
            }
        }
    }

    // MARK: - Helpers

    /// 접근성 레이블 — VoiceOver 사용자에게 페이로드 설명 제공.
    private var accessibilityDescription: String {
        // payload 에서 host/port 추출하여 더 친절한 설명 생성.
        "페어링 QR 코드"
    }

    /// 캐시 조회 → miss 시 생성. 순수 함수처럼 동작하되 State 로 메모이제이션.
    private func resolvedImage() -> Image? {
        if cachedPayload == payload, let cached = cachedImage {
            return cached
        }
        let generated = Self.makeQRImage(from: payload, size: size)
        DispatchQueue.main.async {
            cachedPayload = payload
            cachedImage = generated
        }
        return generated ?? cachedImage
    }

    // MARK: - 정적 생성 (테스트 가능)

    /// payload → SwiftUI Image 변환. 실패 시 nil 반환.
    ///
    /// - Parameters:
    ///   - payload: UTF-8 인코딩할 문자열.
    ///   - size: 출력 이미지 픽셀 크기 (pt 아님 — CGImage 해상도).
    /// - Returns: 성공 시 `Image`, 실패 시 `nil`.
    public static func makeQRImage(from payload: String, size: CGFloat) -> Image? {
        guard let ciImage = makeCIImage(from: payload) else { return nil }
        guard let cgImage = renderCGImage(from: ciImage, size: size) else { return nil }
        #if canImport(AppKit)
        let nsImage = NSImage(cgImage: cgImage,
                              size: NSSize(width: size, height: size))
        return Image(nsImage: nsImage)
        #else
        let uiImage = UIImage(cgImage: cgImage)
        return Image(uiImage: uiImage)
        #endif
    }

    /// CoreImage CIQRCodeGenerator → CIImage (스케일 전 원본 픽셀).
    public static func makeCIImage(from payload: String) -> CIImage? {
        guard let data = payload.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("H", forKey: "inputCorrectionLevel") // H = 30% 손실 허용
        return filter.outputImage
    }

    /// CIImage → 스케일된 CGImage. white 배경 + dark 모듈 색상 유지.
    private static func renderCGImage(from ciImage: CIImage, size: CGFloat) -> CGImage? {
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        // 원본 픽셀 대비 목표 크기 배율
        let scale = size / max(extent.width, extent.height)
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let scaled = ciImage.transformed(by: transform)

        // 배경 흰색 — 스캐너가 light 모듈을 항상 흰색으로 기대하므로 고정
        let whiteBackground = CIImage(color: CIColor.white)
            .cropped(to: scaled.extent)
        let composited = scaled.composited(over: whiteBackground)

        return CIContext().createCGImage(composited, from: composited.extent)
    }
}
