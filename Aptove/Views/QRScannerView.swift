import SwiftUI
import CodeScanner

struct QRScannerView: View {
    @Binding var isPresented: Bool
    @StateObject private var viewModel = QRScannerViewModel()
    @EnvironmentObject private var agentManager: AgentManager
    @State private var showingPairingEntry = false
    @State private var isConnecting = false
    @State private var isScannerActive = true
    @State private var scannerID = UUID() // Force recreation of scanner
    
    var body: some View {
        NavigationStack {
            ZStack {
                if isScannerActive && !isConnecting {
                    CodeScannerView(
                        codeTypes: [.qr],
                        simulatedData: "https://192.168.1.100:8080/pair/local?code=123456&fp=SHA256:ABC123",
                        completion: handleScan
                    )
                    .id(scannerID) // Use ID to force complete recreation
                } else {
                    Color.black
                        .ignoresSafeArea()
                }
                
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
                        
                        Text(viewModel.pairingStatus.isEmpty ? "Connecting..." : viewModel.pairingStatus)
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
            .navigationTitle("Scan QR Code")
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
            .onChange(of: showingPairingEntry) { isShowing in
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
            .onChange(of: viewModel.showingError) { showing in
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
            .onChange(of: viewModel.showingSuccess) { showing in
                if showing {
                    isConnecting = false
                    // Keep scanner deactivated on success
                }
            }
            .onAppear {
                viewModel.setAgentManager(agentManager)
                isScannerActive = true
                scannerID = UUID() // Force new scanner instance
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
        // Deactivate scanner immediately to release camera
        isScannerActive = false
        
        switch result {
        case .success(let result):
            isConnecting = true
            Task {
                await viewModel.handleQRCode(result.string)
            }
        case .failure(let error):
            viewModel.errorMessage = error.localizedDescription
            viewModel.showingError = true
            // Scanner will be reactivated by onChange handler
        }
    }
}

#Preview {
    QRScannerView(isPresented: .constant(true))
}
