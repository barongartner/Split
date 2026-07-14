import SwiftUI

/// Shown once, before the first tap ever exists — the audio-recording prompt
/// is one-shot, so it shouldn't arrive as a surprise.
struct OnboardingView: View {
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Before you route anything")
                .font(.title2.weight(.semibold))

            Label {
                Text("When you add your first route, macOS will ask to allow **System Audio Recording** for Split. That permission is how Split captures an app's audio to send it to your headphones. Click Allow — without it every route stays silent.")
            } icon: {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.tint)
            }

            Label {
                Text("Using AirPods? Set them to **Connect to This Mac: When Last Connected** (System Settings → Bluetooth → your AirPods) so they don't jump to your iPhone mid-movie. Do the same on the phone.")
            } icon: {
                Image(systemName: "airpods.gen3")
                    .foregroundStyle(.tint)
            }

            Label {
                Text("Netflix and other DRM video: play it in **Chrome** to route it like any app, or put it on the **Direct route** (works even in Safari and the Apple TV app).")
            } icon: {
                Image(systemName: "film")
                    .foregroundStyle(.tint)
            }

            Label {
                Text("Bluetooth headphones lag behind wired ones. Every route has a **delay slider** — nudge the faster routes until lips sync.")
            } icon: {
                Image(systemName: "clock.arrow.2.circlepath")
                    .foregroundStyle(.tint)
            }

            HStack {
                Spacer()
                Button("Got it") { done() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
