import SwiftUI
import LocalAuthentication

extension Notification.Name {
    static let aptoveSplashComplete = Notification.Name("aptoveSplashComplete")
}

struct BiometricLockView: View {
    let onUnlock: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var biometryType: LABiometryType = .none

    private var lockIcon: String {
        switch biometryType {
        case .faceID:   return "faceid"
        case .touchID:  return "touchid"
        default:        return "lock.fill"
        }
    }

    var body: some View {
        VStack(spacing: 32) {
            Image(systemName: lockIcon)
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("biometric_locked_title")
                .font(.title2)
                .fontWeight(.semibold)

            Button("biometric_unlock_button") {
                authenticate()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onAppear {
            let context = LAContext()
            var error: NSError?
            context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
            biometryType = context.biometryType
        }
        // Cold start: AptoveApp posts this after the splash finishes fading.
        .onReceive(NotificationCenter.default.publisher(for: .aptoveSplashComplete)) { _ in
            authenticate()
        }
        // Background→foreground: phase becomes .active after the app is the key
        // window, so the prompt fires at the right moment.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { authenticate() }
        }
    }

    private func authenticate() {
        let context = LAContext()
        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: NSLocalizedString("biometric_lock_reason", comment: "")
        ) { success, _ in
            guard success else { return }
            Task { @MainActor in onUnlock() }
        }
    }
}
