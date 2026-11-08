import SwiftUI
import AVFoundation

// Local equivalents of the CodeScanner types used in QRScannerView —
// keeps the handleScan closure unchanged.
struct ScanResult {
    let string: String
}

enum ScanError: Error {
    case permissionDenied
    case badOutput
}

// MARK: - NativeQRScannerRepresentable

struct NativeQRScannerRepresentable: UIViewControllerRepresentable {
    var simulatedData: String = ""
    let completion: (Result<ScanResult, ScanError>) -> Void

    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC(coordinator: context.coordinator)
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerVC, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(simulatedData: simulatedData, completion: completion)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let simulatedData: String
        let completion: (Result<ScanResult, ScanError>) -> Void
        private var fired = false

        init(simulatedData: String, completion: @escaping (Result<ScanResult, ScanError>) -> Void) {
            self.simulatedData = simulatedData
            self.completion = completion
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !fired,
                  let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let string = obj.stringValue else { return }
            fired = true
            DispatchQueue.main.async { [weak self] in
                self?.completion(.success(ScanResult(string: string)))
            }
        }

        func fireSimulated(after delay: TimeInterval) {
            guard !simulatedData.isEmpty else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.fired else { return }
                self.fired = true
                self.completion(.success(ScanResult(string: self.simulatedData)))
            }
        }
    }

    // MARK: ScannerVC

    final class ScannerVC: UIViewController {
        private let coordinator: Coordinator
        private let session = AVCaptureSession()
        private let sessionQueue = DispatchQueue(label: "qr.session", qos: .userInitiated)
        private var previewLayer: AVCaptureVideoPreviewLayer?

        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            checkPermissionAndSetup()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.bounds
            updateRectOfInterest()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            sessionQueue.async { [weak self] in
                guard let self, !self.session.isRunning else { return }
                self.session.startRunning()
            }
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            sessionQueue.async { [weak self] in
                self?.session.stopRunning()
            }
        }

        private func checkPermissionAndSetup() {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                setupSession()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    if granted {
                        self?.setupSession()
                    } else {
                        DispatchQueue.main.async { self?.coordinator.completion(.failure(.permissionDenied)) }
                    }
                }
            default:
                DispatchQueue.main.async { [weak self] in
                    self?.coordinator.completion(.failure(.permissionDenied))
                }
            }
        }

        private func setupSession() {
            sessionQueue.async { [weak self] in
                guard let self else { return }
                self.session.beginConfiguration()
                self.session.sessionPreset = .hd1280x720

                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                      let input = try? AVCaptureDeviceInput(device: device),
                      self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { self.coordinator.completion(.failure(.badOutput)) }
                    return
                }
                self.session.addInput(input)

                try? device.lockForConfiguration()
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                    device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
                }
                device.unlockForConfiguration()

                let metadataOutput = AVCaptureMetadataOutput()
                guard self.session.canAddOutput(metadataOutput) else {
                    self.session.commitConfiguration()
                    return
                }
                self.session.addOutput(metadataOutput)
                // Delegate fires on main queue — no extra dispatch needed in metadataOutput(_:didOutput:)
                metadataOutput.setMetadataObjectsDelegate(self.coordinator, queue: DispatchQueue.main)
                metadataOutput.metadataObjectTypes = [.qr]

                self.session.commitConfiguration()

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let preview = AVCaptureVideoPreviewLayer(session: self.session)
                    preview.videoGravity = .resizeAspectFill
                    preview.frame = self.view.bounds
                    self.view.layer.insertSublayer(preview, at: 0)
                    self.previewLayer = preview
                    self.updateRectOfInterest()
                    self.addViewfinder()
                    #if targetEnvironment(simulator)
                    self.coordinator.fireSimulated(after: 1.0)
                    #endif
                }

                self.session.startRunning()
            }
        }

        // Restrict hardware QR detection to the center viewfinder area for faster decoding.
        private func updateRectOfInterest() {
            guard let metadataOutput = session.outputs.compactMap({ $0 as? AVCaptureMetadataOutput }).first,
                  let previewLayer else { return }
            let bounds = view.bounds
            let size = min(bounds.width, bounds.height) * 0.6
            let rect = CGRect(
                x: bounds.midX - size / 2,
                y: bounds.midY - size / 2,
                width: size,
                height: size
            )
            metadataOutput.rectOfInterest = previewLayer.metadataOutputRectConverted(fromLayerRect: rect)
        }

        private func addViewfinder() {
            let bounds = view.bounds
            let size = min(bounds.width, bounds.height) * 0.6
            let box = UIView(frame: CGRect(
                x: bounds.midX - size / 2,
                y: bounds.midY - size / 2,
                width: size,
                height: size
            ))
            box.layer.borderColor = UIColor.white.cgColor
            box.layer.borderWidth = 2
            box.layer.cornerRadius = 12
            box.backgroundColor = .clear
            view.addSubview(box)
        }
    }
}
