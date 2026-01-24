import SwiftUI
import CodeScanner

struct QRScannerView: View {
    @Binding var isPresented: Bool
    @StateObject private var viewModel = QRScannerViewModel()
    @State private var showingManualEntry = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                CodeScannerView(
                    codeTypes: [.qr],
                    simulatedData: "Mock QR Code Data",
                    completion: handleScan
                )
                
                VStack {
                    Spacer()
                    
                    Text("Point camera at QR code")
                        .font(.headline)
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(10)
                        .padding(.bottom, 100)
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
        }
    }
    
    private func handleScan(result: Result<ScanResult, ScanError>) {
        switch result {
        case .success(let result):
            Task {
                await viewModel.handleQRCode(result.string)
            }
        case .failure(let error):
            viewModel.errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    QRScannerView(isPresented: .constant(true))
}
