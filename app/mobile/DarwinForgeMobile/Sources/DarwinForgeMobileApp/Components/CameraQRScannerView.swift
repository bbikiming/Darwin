import SwiftUI
#if canImport(UIKit) && canImport(AVFoundation)
import AVFoundation
import UIKit

/// QR code scanner backed by `AVCaptureSession` + `AVCaptureMetadataOutput`.
///
/// Apple references:
/// - [AVFoundation Capture overview](https://developer.apple.com/documentation/avfoundation/capture-setup)
/// - [AVCaptureMetadataOutput / metadataObjectTypes](https://developer.apple.com/documentation/avfoundation/avcapturemetadataoutput)
/// - [AVCaptureDevice.requestAccess](https://developer.apple.com/documentation/avfoundation/avcapturedevice/1624584-requestaccess)
///
/// Usage:
/// ```
/// CameraQRScannerView { payload in
///     // payload = raw QR string (JSON or pairing token)
/// }
/// ```
///
/// Requirements:
/// - Info.plist 의 `NSCameraUsageDescription` 가 채워져 있어야 함.
/// - simulator 에는 카메라가 없으므로 항상 실패 (priming/manual fallback 사용).
public struct CameraQRScannerView: UIViewControllerRepresentable {

    public typealias OnScan = (String) -> Void
    public typealias OnError = (CameraQRScannerError) -> Void

    let onScan: OnScan
    let onError: OnError

    public init(onScan: @escaping OnScan, onError: @escaping OnError = { _ in }) {
        self.onScan = onScan
        self.onError = onError
    }

    public func makeUIViewController(context: Context) -> CameraQRScannerController {
        let vc = CameraQRScannerController()
        vc.onScan = onScan
        vc.onError = onError
        return vc
    }

    public func updateUIViewController(_ uiViewController: CameraQRScannerController,
                                       context: Context) {
        // 단일 스캔 후 dismiss 패턴이라 별도 업데이트 불필요.
    }
}

public enum CameraQRScannerError: Error, Sendable, Equatable {
    case unauthorized
    case noCamera
    case sessionFailed(String)
}

/// UIKit-backed scanner. Single-shot — 첫 QR 인식 후 session 정지 + onScan 호출.
public final class CameraQRScannerController: UIViewController,
                                               AVCaptureMetadataOutputObjectsDelegate {

    var onScan: CameraQRScannerView.OnScan?
    var onError: CameraQRScannerView.OnError?

    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var didScan = false

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
        addReticle()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning {
            session.stopRunning()
        }
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video) else {
            onError?(.noCamera)
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                onError?(.sessionFailed("cannot add input"))
                return
            }
            session.addInput(input)
        } catch {
            onError?(.sessionFailed(String(describing: error)))
            return
        }

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            onError?(.sessionFailed("cannot add metadata output"))
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        // QR 만 인식 (그 외 barcode 는 무시).
        let supported = output.availableMetadataObjectTypes
        output.metadataObjectTypes = supported.contains(.qr) ? [.qr] : supported

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.insertSublayer(preview, at: 0)
        self.preview = preview
    }

    private func addReticle() {
        // 가운데 정렬된 가이드 사각형 + 안내 텍스트.
        let reticleSize: CGFloat = 240
        let reticle = UIView()
        reticle.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
        reticle.layer.borderWidth = 2
        reticle.layer.cornerRadius = 16
        reticle.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(reticle)
        NSLayoutConstraint.activate([
            reticle.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            reticle.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            reticle.widthAnchor.constraint(equalToConstant: reticleSize),
            reticle.heightAnchor.constraint(equalToConstant: reticleSize)
        ])

        let label = UILabel()
        label.text = "Mac DarwinForge 의 QR 코드를\n사각형 안에 맞춰주세요"
        label.textColor = .white
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textAlignment = .center
        label.numberOfLines = 2
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.topAnchor.constraint(equalTo: reticle.bottomAnchor, constant: 20),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24)
        ])
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    public func metadataOutput(_ output: AVCaptureMetadataOutput,
                               didOutput metadataObjects: [AVMetadataObject],
                               from connection: AVCaptureConnection) {
        guard !didScan,
              let first = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              first.type == .qr,
              let value = first.stringValue, !value.isEmpty else { return }
        didScan = true
        // Haptic feedback (light) on capture
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        session.stopRunning()
        onScan?(value)
    }
}

// MARK: - Permission helper

public enum CameraPermission {
    public enum Status: Sendable, Equatable {
        case authorized, denied, restricted, notDetermined
    }

    public static var current: Status {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    /// Request video access — returns `true` if granted.
    public static func request() async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                cont.resume(returning: granted)
            }
        }
    }
}

#endif
