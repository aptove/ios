import SwiftUI

struct ManualConnectionView: View {
    @Binding var isPresented: Bool
    let onConnect: (ConnectionConfig) -> Void
    
    @State private var url = "https://"
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var protocolVersion = "acp"
    @State private var version = "1.0.0"
    
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var isConnecting = false
    
    @FocusState private var focusedField: Field?
    
    enum Field {
        case url, clientId, clientSecret
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Form {
                    Section {
                        TextField("URL", text: $url)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .focused($focusedField, equals: .url)
                        
                        TextField("Client ID (optional for local)", text: $clientId)
                            .textContentType(.username)
                            .autocapitalization(.none)
                            .focused($focusedField, equals: .clientId)
                        
                        SecureField("Client Secret (optional for local)", text: $clientSecret)
                            .textContentType(.password)
                            .focused($focusedField, equals: .clientSecret)
                    } header: {
                        Text("Connection Details")
                    } footer: {
                        Text("Enter the agent connection details. URL must use HTTPS for production or WS/WSS for local development. Credentials are optional for local connections.")
                    }
                    
                    Section {
                        TextField("Protocol Version", text: $protocolVersion)
                            .disabled(true)
                        
                        TextField("Version", text: $version)
                    } header: {
                        Text("Advanced")
                    }
                    
                    Section {
                        Button("Connect") {
                            connectAgent()
                        }
                        .disabled(!isValid || isConnecting)
                        .frame(maxWidth: .infinity)
                    }
                }
                .disabled(isConnecting)
                
                // Connection progress overlay
                if isConnecting {
                    Color.black.opacity(0.7)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 20) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.5)
                        
                        Text("Connecting to agent...")
                            .font(.headline)
                            .foregroundColor(.white)
                        
                        Text("This may take up to 5 minutes if authorization is required")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                        
                        Button {
                            // Cancel connection
                            isConnecting = false
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
            .navigationTitle("Manual Connection")
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
            .alert("Invalid Configuration", isPresented: $showingError) {
                Button("OK") {
                    errorMessage = ""
                }
            } message: {
                Text(errorMessage)
            }
        }
    }
    
    private var isValid: Bool {
        let hasValidProtocol = url.hasPrefix("https://") || url.hasPrefix("http://") || 
                              url.hasPrefix("wss://") || url.hasPrefix("ws://")
        let isSecure = url.hasPrefix("https://") || url.hasPrefix("wss://")
        
        // For secure connections, require credentials
        if isSecure {
            return hasValidProtocol && !clientId.isEmpty && !clientSecret.isEmpty && protocolVersion == "acp"
        } else {
            // For local connections, credentials are optional
            return hasValidProtocol && protocolVersion == "acp"
        }
    }
    
    private func connectAgent() {
        isConnecting = true
        let trimmedClientId = clientId.trimmingCharacters(in: .whitespaces)
        let trimmedClientSecret = clientSecret.trimmingCharacters(in: .whitespaces)
        
        let config = ConnectionConfig(
            url: url.trimmingCharacters(in: .whitespaces),
            clientId: trimmedClientId.isEmpty ? nil : trimmedClientId,
            clientSecret: trimmedClientSecret.isEmpty ? nil : trimmedClientSecret,
            protocolVersion: protocolVersion,
            version: version
        )
        
        do {
            try config.validate()
            onConnect(config)
            // Note: isPresented will be dismissed by parent view on success
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
            isConnecting = false
        }
    }
}

#Preview {
    ManualConnectionView(
        isPresented: .constant(true),
        onConnect: { _ in }
    )
}
