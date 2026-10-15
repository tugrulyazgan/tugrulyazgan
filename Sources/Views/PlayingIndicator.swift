import SwiftUI

/// Animated sound bars indicator (like Spotify's playing animation).
struct PlayingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0 ..< 3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(.green)
                    .frame(width: 3)
                    .scaleEffect(
                        y: animating ? CGFloat.random(in: 0.3 ... 1.0) : 0.4,
                        anchor: .bottom
                    )
                    .animation(
                        .easeInOut(duration: 0.4)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.15),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}
