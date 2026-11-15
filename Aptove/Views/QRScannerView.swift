import SwiftUI
import AVFoundation

struct QRScannerView: View {
    @Binding var isPresented: Bool
    @StateObject private var viewModel = QRScannerViewModel()
    @EnvironmentObject private var agentManager: AgentManager
    @AppStorage("appLanguage") private var appLanguage: String = ""
    @State private var showingPairingEntry = false
    @State private var isConnecting = false
    @State private var isScannerActive = false
    @State private var scannerID = UUID()
    @State private var showingPermissionDenied = false

    private enum ScannerMode { case native, software }
    @State private var scannerMode: ScannerMode = .native

    @ViewBuilder
    private var scannerLayer: some View {
        if isScannerActive && !isConnecting {
            Group {
                if scannerMode == .native {
                    NativeQRScannerRepresentable(
                        simulatedData: "https://192.168.1.100:8080/pair/local?code=123456&fp=SHA256:ABC123",
                        completion: handleScan
                    )
                    .id(scannerID)
                } else {
                    SoftwareQRScannerRepresentable(completion: handleScan)
                        .id(scannerID)
                }
            }
        } else {
            Color.black
                .ignoresSafeArea()
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                scannerLayer
                
                VStack {
                    Spacer()
                    
                    Text("Point camera at QR code")
                        .font(.headline)
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(10)
                        .padding(.bottom, 100)
                }
                
                // Connection progress overlay
                if isConnecting {
                    Color.black.opacity(0.7)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 20) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.5)
                        
                        Text(viewModel.pairingStatus.isEmpty ? String(localized: "Connecting...") : viewModel.pairingStatus)
                            .font(.headline)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding()
                        
                        Text("Please wait...")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.8))
                        
                        Button {
                            // Cancel connection
                            isConnecting = false
                            isScannerActive = true
                            scannerID = UUID() // Create fresh scanner
                        } label: {
                            Text("Cancel")
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding(.horizontal, 32)
                                .padding(.vertical, 12)
                                .background(Color.red.opacity(0.8))
                                .cornerRadius(10)
                        }
                        .padding(.top, 8)
                    }
                    .padding(40)
                    .background(.ultraThinMaterial)
                    .cornerRadius(20)
                }
            }
            .navigationTitle(Bundle.localized("Scan QR Code", language: appLanguage))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showingPairingEntry = true
                        } label: {
                            Label("Enter Pairing Code", systemImage: "number")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showingPairingEntry) {
                ManualPairingView(
                    isPresented: $showingPairingEntry,
                    onPair: { urlString in
                        Task {
                            isConnecting = true
                            await viewModel.handleQRCode(urlString)
                            if !viewModel.showingSuccess {
                                isConnecting = false
                            }
                        }
                    }
                )
            }
            .onChange(of: showingPairingEntry) { _, isShowing in
                // Stop scanner when pairing entry is shown, restart when dismissed
                isScannerActive = !isShowing && !isConnecting
            }
            .alert("Connection Error", isPresented: $viewModel.showingError) {
                Button("OK") {
                    viewModel.errorMessage = nil
                }
            } message: {
                if let error = viewModel.errorMessage {
                    Text(error)
                }
            }
            .alert("Success", isPresented: $viewModel.showingSuccess) {
                Button("OK") {
                    isPresented = false
                }
            } message: {
                Text("Agent connected successfully")
            }
            .onChange(of: viewModel.showingError) { _, showing in
                if showing {
                    isConnecting = false
                    // Reactivate scanner after error so user can try again
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if !showingPairingEntry {
                            isScannerActive = true
                            scannerID = UUID() // Create fresh scanner
                        }
                    }
                }
            }
            .onChange(of: viewModel.showingSuccess) { _, showing in
                if showing {
                    isConnecting = false
                    // Keep scanner deactivated on success
                }
            }
            .onAppear {
                viewModel.setAgentManager(agentManager)
                #if DEBUG
                print("[QRScannerView] onAppear: scannerMode=\(scannerMode), isScannerActive=\(isScannerActive)")
                #endif
                let status = AVCaptureDevice.authorizationStatus(for: .video)
                #if DEBUG
                print("[QRScannerView] Camera auth status: \(status.rawValue)")
                #endif
                if status == .denied || status == .restricted {
                    showingPermissionDenied = true
                } else {
                    #if DEBUG
                    print("[QRScannerView] Activating scanner in mode: \(scannerMode)")
                    #endif
                    isScannerActive = true
                }
            }
            .alert("camera_permission_denied_title", isPresented: $showingPermissionDenied) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) {
                    isPresented = false
                }
            } message: {
                Text("camera_permission_denied_message")
            }
            .onDisappear {
                // Stop the scanner when view disappears to release camera resources
                isScannerActive = false
                // Give time for camera to fully release
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    scannerID = UUID()
                }
            }
        }
    }
    
    private func handleScan(result: Result<ScanResult, ScanError>) {
        #if DEBUG
        print("[QRScannerView] handleScan: mode=\(scannerMode), result=\(result)")
        #endif
        // Deactivate scanner immediately to release camera
        isScannerActive = false

        switch result {
        case .success(let result):
            #if DEBUG
            print("[QRScannerView] Scan success via \(scannerMode), string length=\(result.string.count)")
            #endif
            isConnecting = true
            Task {
                await viewModel.handleQRCode(result.string)
                if !viewModel.showingSuccess {
                    isConnecting = false
                }
            }
        case .failure(let error):
            if case .permissionDenied = error {
                #if DEBUG
                print("[QRScannerView] Permission denied")
                #endif
                showingPermissionDenied = true
                isScannerActive = false
            } else if scannerMode == .native {
                // Native scanner failed (hardware QR unavailable) — try software fallback
                #if DEBUG
                print("[QRScannerView] Native scanner failed with .badOutput — switching to software fallback")
                #endif
                scannerMode = .software
                scannerID = UUID()
                isScannerActive = true
            } else {
                // Software scanner also failed (no camera at all) — open manual pairing
                #if DEBUG
                print("[QRScannerView] Software scanner also failed — opening manual pairing")
                #endif
                isScannerActive = false
                showingPairingEntry = true
            }
            // Scanner will be reactivated by onChange handler
        }
    }
}

#Preview {
    QRScannerView(isPresented: .constant(true))
}
