import SwiftUI
import AVFoundation
import CoreImage

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

        // Process-wide serial queue that protects AVCaptureMetadataOutput.setMetadataObjectTypes
        // and availableMetadataObjectTypes. These call into AVCaptureFigVideoDevice which has
        // non-thread-safe internal state — concurrent calls from different ScannerVC instances
        // corrupt a shared NSMutableArray and crash. Serializing here prevents that.
        private static let metadataSetupQueue = DispatchQueue(label: "qr.metadata.setup")

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
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            #if DEBUG
            print("[NativeQR] checkPermissionAndSetup: authStatus=\(status.rawValue)")
            #endif
            switch status {
            case .authorized:
                setupSession()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    #if DEBUG
                    print("[NativeQR] requestAccess result: granted=\(granted)")
                    #endif
                    if granted {
                        self?.setupSession()
                    } else {
                        DispatchQueue.main.async { self?.coordinator.completion(.failure(.permissionDenied)) }
                    }
                }
            default:
                #if DEBUG
                print("[NativeQR] Permission denied/restricted, firing .permissionDenied")
                #endif
                DispatchQueue.main.async { [weak self] in
                    self?.coordinator.completion(.failure(.permissionDenied))
                }
            }
        }

        private func setupSession() {
            sessionQueue.async { [weak self] in
                guard let self else { return }
                #if DEBUG
                print("[NativeQR] setupSession: starting on thread \(Thread.current)")
                #endif
                self.session.beginConfiguration()
                self.session.sessionPreset = .hd1280x720

                let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                #if DEBUG
                print("[NativeQR] Back camera device: \(device?.localizedName ?? "nil")")
                #endif
                guard let device,
                      let input = try? AVCaptureDeviceInput(device: device),
                      self.session.canAddInput(input) else {
                    #if DEBUG
                    print("[NativeQR] FAILED: no back camera or cannot add input — firing .badOutput")
                    #endif
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { self.coordinator.completion(.failure(.badOutput)) }
                    return
                }
                self.session.addInput(input)
                #if DEBUG
                print("[NativeQR] Added camera input: \(device.localizedName)")
                #endif

                try? device.lockForConfiguration()
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                    device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
                }
                device.unlockForConfiguration()

                let metadataOutput = AVCaptureMetadataOutput()
                guard self.session.canAddOutput(metadataOutput) else {
                    #if DEBUG
                    print("[NativeQR] FAILED: cannot add metadata output — firing .badOutput")
                    #endif
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { self.coordinator.completion(.failure(.badOutput)) }
                    return
                }
                self.session.addOutput(metadataOutput)
                #if DEBUG
                print("[NativeQR] Added metadata output")
                #endif

                // Serialize metadata type setup across all ScannerVC instances.
                // AVCaptureFigVideoDevice.supportedMetadataObjectIdentifiers has non-thread-safe
                // internal state — concurrent calls corrupt a shared NSMutableArray and abort.
                var metadataReady = false
                ScannerVC.metadataSetupQueue.sync {
                    let availableTypes = metadataOutput.availableMetadataObjectTypes
                    #if DEBUG
                    print("[NativeQR] availableMetadataObjectTypes: \(availableTypes.map { $0.rawValue })")
                    #endif
                    guard availableTypes.contains(.qr) else {
                        #if DEBUG
                        print("[NativeQR] FAILED: .qr NOT in available types")
                        #endif
                        return
                    }
                    metadataOutput.setMetadataObjectsDelegate(self.coordinator, queue: DispatchQueue.main)
                    #if DEBUG
                    print("[NativeQR] Setting metadataObjectTypes to [.qr]...")
                    #endif
                    metadataOutput.metadataObjectTypes = [.qr]
                    #if DEBUG
                    print("[NativeQR] metadataObjectTypes set successfully")
                    #endif
                    metadataReady = true
                }
                guard metadataReady else {
                    #if DEBUG
                    print("[NativeQR] FAILED: metadata setup did not complete — firing .badOutput")
                    #endif
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { self.coordinator.completion(.failure(.badOutput)) }
                    return
                }

                self.session.commitConfiguration()
                #if DEBUG
                print("[NativeQR] Session configured, starting...")
                #endif

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let preview = AVCaptureVideoPreviewLayer(session: self.session)
                    preview.videoGravity = .resizeAspectFill
                    preview.frame = self.view.bounds
                    self.view.layer.insertSublayer(preview, at: 0)
                    self.previewLayer = preview
                    self.addViewfinder()
                    #if DEBUG
                    print("[NativeQR] Preview layer added, bounds=\(self.view.bounds)")
                    #endif
                    #if targetEnvironment(simulator)
                    self.coordinator.fireSimulated(after: 1.0)
                    #endif
                }

                self.session.startRunning()
                #if DEBUG
                print("[NativeQR] Session running=\(self.session.isRunning)")
                #endif
                // Set rectOfInterest after startRunning so the preview layer transform is valid.
                DispatchQueue.main.async { [weak self] in
                    self?.updateRectOfInterest()
                }
            }
        }

        // Restrict hardware QR detection to the center viewfinder area for faster decoding.
        // Must be called after the session is running and the view has non-zero bounds;
        // otherwise metadataOutputRectConverted produces a singular-matrix error and sets
        // rectOfInterest to CGRectZero, which makes the hardware scan nothing.
        private func updateRectOfInterest() {
            guard let metadataOutput = session.outputs.compactMap({ $0 as? AVCaptureMetadataOutput }).first,
                  let previewLayer,
                  view.bounds.width > 0, view.bounds.height > 0,
                  session.isRunning else { return }
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

// MARK: - SoftwareQRScannerRepresentable
// Fallback scanner using AVCaptureVideoDataOutput + CIDetector (software QR decoding).
// Avoids AVCaptureMetadataOutput.setMetadataObjectTypes entirely, so it works on devices
// where the hardware metadata path is unavailable (e.g. Mac front camera).

struct SoftwareQRScannerRepresentable: UIViewControllerRepresentable {
    let completion: (Result<ScanResult, ScanError>) -> Void

    func makeCoordinator() -> SoftwareCoordinator {
        SoftwareCoordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> SoftwareScannerVC {
        SoftwareScannerVC(coordinator: context.coordinator)
    }

    func updateUIViewController(_ uiViewController: SoftwareScannerVC, context: Context) {}

    // MARK: SoftwareCoordinator

    final class SoftwareCoordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        let completion: (Result<ScanResult, ScanError>) -> Void
        private var fired = false
        private var isProcessing = false
        private let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                          options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])

        init(completion: @escaping (Result<ScanResult, ScanError>) -> Void) {
            self.completion = completion
        }

        func captureOutput(
            _ output: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            guard !fired, !isProcessing else { return }
            isProcessing = true
            defer { isProcessing = false }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            let features = detector?.features(in: image) ?? []
            guard let qr = features.first as? CIQRCodeFeature,
                  let string = qr.messageString, !string.isEmpty else { return }
            fired = true
            DispatchQueue.main.async { [weak self] in
                self?.completion(.success(ScanResult(string: string)))
            }
        }
    }

    // MARK: SoftwareScannerVC

    final class SoftwareScannerVC: UIViewController {
        private let coordinator: SoftwareCoordinator
        private let session = AVCaptureSession()
        private let sessionQueue = DispatchQueue(label: "qr.software.session", qos: .userInitiated)
        private var previewLayer: AVCaptureVideoPreviewLayer?

        init(coordinator: SoftwareCoordinator) {
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
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            #if DEBUG
            print("[SoftwareQR] checkPermissionAndSetup: authStatus=\(status.rawValue)")
            #endif
            switch status {
            case .authorized:
                setupSession()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    #if DEBUG
                    print("[SoftwareQR] requestAccess result: granted=\(granted)")
                    #endif
                    if granted {
                        self?.setupSession()
                    } else {
                        DispatchQueue.main.async { self?.coordinator.completion(.failure(.permissionDenied)) }
                    }
                }
            default:
                #if DEBUG
                print("[SoftwareQR] Permission denied/restricted, firing .permissionDenied")
                #endif
                DispatchQueue.main.async { [weak self] in
                    self?.coordinator.completion(.failure(.permissionDenied))
                }
            }
        }

        private func setupSession() {
            sessionQueue.async { [weak self] in
                guard let self else { return }
                #if DEBUG
                print("[SoftwareQR] setupSession: starting on thread \(Thread.current)")
                #endif
                self.session.beginConfiguration()
                self.session.sessionPreset = .hd1280x720

                // Use default camera (no .back requirement — works on Mac front camera too)
                let device = AVCaptureDevice.default(for: .video)
                #if DEBUG
                print("[SoftwareQR] Default video device: \(device?.localizedName ?? "nil")")
                #endif
                guard let device,
                      let input = try? AVCaptureDeviceInput(device: device),
                      self.session.canAddInput(input) else {
                    #if DEBUG
                    print("[SoftwareQR] FAILED: no camera or cannot add input — firing .badOutput")
                    #endif
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { self.coordinator.completion(.failure(.badOutput)) }
                    return
                }
                self.session.addInput(input)
                #if DEBUG
                print("[SoftwareQR] Added camera input: \(device.localizedName)")
                #endif

                try? device.lockForConfiguration()
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                    device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5)
                }
                device.unlockForConfiguration()

                let videoOutput = AVCaptureVideoDataOutput()
                videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                // Process frames on session queue to avoid blocking the main thread
                videoOutput.setSampleBufferDelegate(self.coordinator, queue: self.sessionQueue)
                videoOutput.alwaysDiscardsLateVideoFrames = true

                guard self.session.canAddOutput(videoOutput) else {
                    #if DEBUG
                    print("[SoftwareQR] FAILED: cannot add video output — firing .badOutput")
                    #endif
                    self.session.commitConfiguration()
                    DispatchQueue.main.async { self.coordinator.completion(.failure(.badOutput)) }
                    return
                }
                self.session.addOutput(videoOutput)
                self.session.commitConfiguration()
                #if DEBUG
                print("[SoftwareQR] Session configured with video data output")
                #endif

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let preview = AVCaptureVideoPreviewLayer(session: self.session)
                    preview.videoGravity = .resizeAspectFill
                    preview.frame = self.view.bounds
                    self.view.layer.insertSublayer(preview, at: 0)
                    self.previewLayer = preview
                    self.addViewfinder()
                    #if DEBUG
                    print("[SoftwareQR] Preview layer added, bounds=\(self.view.bounds)")
                    #endif
                }

                self.session.startRunning()
                #if DEBUG
                print("[SoftwareQR] Session running=\(self.session.isRunning)")
                #endif
            }
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
