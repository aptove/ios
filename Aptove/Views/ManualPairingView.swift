import SwiftUI

/// View for manually entering a pairing code when QR scanning isn't possible
struct ManualPairingView: View {
    @Binding var isPresented: Bool
    let onPair: (String) -> Void
    
    @State private var bridgeAddress = ""
    @State private var pairingCode = ""
    @State private var fingerprint = ""
    @State private var useHTTPS = true
    @State private var pairingType: PairingTypeOption = .local
    
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var isPairing = false
    
    @FocusState private var focusedField: Field?
    
    enum Field {
        case address, code, fingerprint
    }
    
    enum PairingTypeOption: String, CaseIterable {
        case local = "Local Bridge"
        case cloudflare = "Cloudflare Tunnel"
        
        var path: String {
            switch self {
            case .local: return "/pair/local"
            case .cloudflare: return "/pair/cloudflare"
            }
        }
        
        var requiresFingerprint: Bool {
            switch self {
            case .local: return true
            case .cloudflare: return false
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Form {
                    Section {
                        Picker("Connection Type", selection: $pairingType) {
                            ForEach(PairingTypeOption.allCases, id: \.self) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                    } header: {
                        Text("Pairing Type")
                    } footer: {
                        Text(pairingType == .local 
                            ? "For bridges running on your local network" 
                            : "For bridges exposed via Cloudflare Tunnel")
                    }
                    
                    Section {
                        TextField("Bridge Address (e.g., 192.168.1.100:8080)", text: $bridgeAddress)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .address)
                        
                        if pairingType == .local {
                            Toggle("Use HTTPS", isOn: $useHTTPS)
                        }
                    } header: {
                        Text("Bridge Address")
                    } footer: {
                        Text("Enter the IP address and port shown in your terminal")
                    }
                    
                    Section {
                        TextField("Pairing Code (6 digits)", text: $pairingCode)
                            .keyboardType(.numberPad)
                            .focused($focusedField, equals: .code)
                            .onChange(of: pairingCode) { newValue in
                                // Limit to 6 digits
                                let filtered = newValue.filter { $0.isNumber }
                                if filtered.count > 6 {
                                    pairingCode = String(filtered.prefix(6))
                                } else {
                                    pairingCode = filtered
                                }
                            }
                    } header: {
                        Text("Pairing Code")
                    } footer: {
                        Text("Enter the 6-digit code shown in your terminal. Codes expire after 60 seconds.")
                    }
                    
                    if pairingType.requiresFingerprint {
                        Section {
                            TextField("SHA256:XX:XX:XX...", text: $fingerprint)
                                .font(.system(.body, design: .monospaced))
                                .autocapitalization(.none)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .fingerprint)
                        } header: {
                            Text("Certificate Fingerprint")
                        } footer: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Required for security. Copy the TLS fingerprint shown in your terminal.")
                                Text("⚠️ This protects against man-in-the-middle attacks.")
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                    
                    Section {
                        Button {
                            startPairing()
                        } label: {
                            HStack {
                                Spacer()
                                Text("Connect")
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                        }
                        .disabled(!isValid || isPairing)
                    }
                }
                .disabled(isPairing)
                
                // Pairing progress overlay
                if isPairing {
                    Color.black.opacity(0.7)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 20) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.5)
                        
                        Text("Connecting to bridge...")
                            .font(.headline)
                            .foregroundColor(.white)
                        
                        if pairingType == .local {
                            Text("Validating certificate fingerprint...")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.8))
                        }
                        
                        Button {
                            isPairing = false
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
            .navigationTitle("Enter Pairing Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                
                ToolbarItem(placement: .keyboard) {
                    HStack {
                        Spacer()
                        Button("Done") {
                            focusedField = nil
                        }
                    }
                }
            }
            .alert("Pairing Error", isPresented: $showingError) {
                Button("OK") {
                    errorMessage = ""
                }
            } message: {
                Text(errorMessage)
            }
        }
    }
    
    private var isValid: Bool {
        let hasAddress = !bridgeAddress.trimmingCharacters(in: .whitespaces).isEmpty
        let hasCode = pairingCode.count == 6
        
        if pairingType.requiresFingerprint {
            let hasFingerprint = !fingerprint.trimmingCharacters(in: .whitespaces).isEmpty
            return hasAddress && hasCode && hasFingerprint
        }
        
        return hasAddress && hasCode
    }
    
    private func startPairing() {
        isPairing = true
        
        // Build the pairing URL
        let scheme = (pairingType == .local && useHTTPS) || pairingType == .cloudflare ? "https" : "http"
        let address = bridgeAddress.trimmingCharacters(in: .whitespaces)
        let code = pairingCode.trimmingCharacters(in: .whitespaces)
        
        var urlString = "\(scheme)://\(address)\(pairingType.path)?code=\(code)"
        
        // Add fingerprint for local connections
        if pairingType == .local && !fingerprint.isEmpty {
            let fp = fingerprint.trimmingCharacters(in: .whitespaces)
            // URL encode the fingerprint (colons become %3A)
            if let encoded = fp.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                urlString += "&fp=\(encoded)"
            }
        }
        
        print("🔗 ManualPairingView: Built pairing URL: \(urlString)")
        
        // Validate URL
        guard URL(string: urlString) != nil else {
            errorMessage = "Invalid URL format. Please check the bridge address."
            showingError = true
            isPairing = false
            return
        }
        
        // Call the pairing handler
        onPair(urlString)
        
        // Note: isPairing will be reset by parent when pairing completes/fails
    }
}

#Preview {
    ManualPairingView(
        isPresented: .constant(true),
        onPair: { url in print("Pairing with: \(url)") }
    )
}
