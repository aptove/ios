import SwiftUI

struct SplashView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image("AptoveLockup")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 240)
        }
    }
}
