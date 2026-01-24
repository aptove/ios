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
    
    @FocusState private var focusedField: Field?
    
    enum Field {
        case url, clientId, clientSecret
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("URL", text: $url)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .focused($focusedField, equals: .url)
                    
                    TextField("Client ID", text: $clientId)
                        .textContentType(.username)
                        .autocapitalization(.none)
                        .focused($focusedField, equals: .clientId)
                    
                    SecureField("Client Secret", text: $clientSecret)
                        .textContentType(.password)
                        .focused($focusedField, equals: .clientSecret)
                } header: {
                    Text("Connection Details")
                } footer: {
                    Text("Enter the agent connection details. URL must use HTTPS.")
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
                    .disabled(!isValid)
                    .frame(maxWidth: .infinity)
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
        url.hasPrefix("https://") &&
        !clientId.isEmpty &&
        !clientSecret.isEmpty &&
        protocolVersion == "acp"
    }
    
    private func connectAgent() {
        let config = ConnectionConfig(
            url: url.trimmingCharacters(in: .whitespaces),
            clientId: clientId.trimmingCharacters(in: .whitespaces),
            clientSecret: clientSecret.trimmingCharacters(in: .whitespaces),
            protocolVersion: protocolVersion,
            version: version
        )
        
        do {
            try config.validate()
            onConnect(config)
            isPresented = false
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }
}

#Preview {
    ManualConnectionView(
        isPresented: .constant(true),
        onConnect: { _ in }
    )
}
