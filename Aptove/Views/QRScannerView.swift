import SwiftUI
import CodeScanner

struct QRScannerView: View {
    @Binding var isPresented: Bool
    @StateObject private var viewModel = QRScannerViewModel()
    @EnvironmentObject private var agentManager: AgentManager
    @State private var showingManualEntry = false
    @State private var isConnecting = false
    @State private var connectionMessage = ""
    @State private var isScannerActive = true
    
    var body: some View {
        NavigationStack {
            ZStack {
                if isScannerActive && !isConnecting {
                    CodeScannerView(
                        codeTypes: [.qr],
                        simulatedData: "Mock QR Code Data",
                        completion: handleScan
                    )
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
                        
                        Text(connectionMessage)
                            .font(.headline)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding()
                        
                        Text("Please wait...")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.8))
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
                    Button("Manual Entry") {
                        showingManualEntry = true
                    }
                }
            }
            .sheet(isPresented: $showingManualEntry) {
                ManualConnectionView(
                    isPresented: $showingManualEntry,
                    onConnect: { config in
                        Task {
                            await viewModel.handleManualConnection(config)
                        }
                    }
                )
            }
            .onChange(of: showingManualEntry) { isShowing in
                // Stop scanner when manual entry is shown, restart when dismissed
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
                        if !showingManualEntry {
                            isScannerActive = true
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
            }
            .onDisappear {
                // Stop the scanner when view disappears to release camera resources
                isScannerActive = false
            }
        }
    }
    
    private func handleScan(result: Result<ScanResult, ScanError>) {
        // Deactivate scanner immediately to release camera
        isScannerActive = false
        
        switch result {
        case .success(let result):
            isConnecting = true
            connectionMessage = "Connecting to agent..."
            Task {
                await viewModel.handleQRCode(result.string)
                // Update connection message if still connecting
                if isConnecting && !viewModel.showingError && !viewModel.showingSuccess {
                    connectionMessage = "This may take up to 5 minutes..."
                }
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
