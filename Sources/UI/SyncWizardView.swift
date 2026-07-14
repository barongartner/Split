import SwiftUI

/// The beat-match sync wizard. Each listener, wearing their headphones, taps
/// arrow keys until the beep they hear lands on the on-screen pulse. Their
/// final value reveals their headphones' latency; the wizard then aligns the
/// whole group to the slowest pair. Nobody holds anything up to anything.
struct SyncWizardView: View {
    @Environment(RouteSupervisor.self) private var supervisor
    @Environment(\.dismiss) private var dismiss

    private enum Step: Equatable {
        case intro
        case tune(Int)          // index into routeIDs
        case phantom            // Direct route's listener (optional)
        case verify
    }

    @State private var step: Step = .intro
    @State private var routeIDs: [UUID] = []
    @State private var grid = BeatGrid.startingSoon()
    @State private var tunerValue: Double = 0
    @State private var tuned: [UUID: Double] = [:]
    @State private var phantomTuned: Double?
    @State private var applied = false
    @State private var clickTestOn = false
    @State private var lastNudge: Double = 0
    @FocusState private var keyFocus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
        }
        .padding(24)
        .frame(width: 560, height: 480)
        .onAppear {
            supervisor.beginCalibration()
            routeIDs = supervisor.tunableRouteIDs
        }
        .onDisappear {
            supervisor.endCalibration(revert: !applied)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .intro: intro
        case .tune(let i): tuner(routeIndex: i)
        case .phantom: phantomTuner
        case .verify: verify
        }
    }

    // MARK: - Intro

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sync everyone up")
                .font(.title2.weight(.semibold))
            Text("One at a time, each listener keeps their headphones on, watches the arrows fly toward the line, and taps ← → until the beep lands **right as they meet**. About 15 seconds per person. Split figures out the rest.")
            if routeIDs.isEmpty {
                Text("No routes can be tuned right now — a route needs its app open (so its engine is live) before it can beep.")
                    .foregroundStyle(.orange)
            } else {
                Text("Tuning \(routeIDs.count) route\(routeIDs.count == 1 ? "" : "s")\(supervisor.directRoute != nil ? ", plus a check for the Direct route" : "").")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Start") { advanceToTune(0) }
                    .buttonStyle(.borderedProminent)
                    .disabled(routeIDs.isEmpty && supervisor.directRoute == nil)
            }
        }
    }

    // MARK: - Beat-match screens

    private func routeName(_ id: UUID) -> String {
        supervisor.table.routes.first { $0.id == id }?.appDisplayName ?? "?"
    }

    private func tuner(routeIndex i: Int) -> some View {
        let id = routeIDs[i]
        return beatMatchBody(
            title: "\(routeName(id)) → \(supervisor.table.routes.first { $0.id == id }?.primaryLeg?.deviceName ?? "")",
            subtitle: "Whoever wears these headphones: tap ← → until the beep lands exactly when the arrows meet the line. (⇧ for fine steps.)",
            onChange: { supervisor.setTunerDelay(routeID: id, ms: tunerValue) },
            onConfirm: {
                tuned[id] = tunerValue
                if i + 1 < routeIDs.count {
                    advanceToTune(i + 1)
                } else if supervisor.directRoute != nil {
                    advanceToPhantom()
                } else {
                    applyAndVerify()
                }
            }
        )
    }

    private var phantomTuner: some View {
        beatMatchBody(
            title: "Direct route check — \(supervisor.directRoute?.primaryLeg?.deviceName ?? "")",
            subtitle: "Optional: whoever listens on the Direct route does the same beat-match. Nothing is changed for them — Split just learns whether their device can keep up with the group.",
            skippable: true,
            onChange: { supervisor.setPhantomDelay(ms: tunerValue) },
            onConfirm: {
                phantomTuned = tunerValue
                applyAndVerify()
            },
            onSkip: {
                phantomTuned = nil
                applyAndVerify()
            }
        )
    }

    private func beatMatchBody(title: String, subtitle: String, skippable: Bool = false,
                               onChange: @escaping () -> Void,
                               onConfirm: @escaping () -> Void,
                               onSkip: (() -> Void)? = nil) -> some View {
        VStack(spacing: 14) {
            Text(title).font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            BeatTrack(grid: grid)
                .frame(width: 460, height: 96)

            HStack(spacing: 12) {
                Slider(value: Binding(
                    get: { tunerValue },
                    set: { tunerValue = $0; onChange() }
                ), in: 0...600)
                Text("\(Int(tunerValue)) ms")
                    .font(.title3.monospacedDigit())
                    .frame(width: 76, alignment: .trailing)
            }

            Text("← → move 10 ms · ⇧← ⇧→ move 2 ms · Return when it feels right")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
            HStack {
                Button("Cancel") { dismiss() }
                if skippable, let onSkip {
                    Button("Skip") { onSkip() }
                }
                Spacer()
                Button("Sounds right") { onConfirm() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .focusable()
        .focused($keyFocus)
        .onAppear { keyFocus = true }
        .onKeyPress { press in
            let step: Double = press.modifiers.contains(.shift) ? 2 : 10
            switch press.key {
            case .leftArrow: tunerValue = max(tunerValue - step, 0); onChange(); return .handled
            case .rightArrow: tunerValue = min(tunerValue + step, 600); onChange(); return .handled
            case .return: onConfirm(); return .handled
            default: return .ignored
            }
        }
    }

    // MARK: - Verify

    private var verify: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Synced")
                .font(.title2.weight(.semibold))

            ForEach(routeIDs, id: \.self) { id in
                if let route = supervisor.table.routes.first(where: { $0.id == id }) {
                    HStack {
                        Text(route.appDisplayName).frame(width: 150, alignment: .leading)
                        Text("headphones ≈ \(Int(route.impliedLatencyMs ?? 0)) ms behind")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("delay \(Int(route.delayMs)) ms")
                            .font(.caption.monospacedDigit())
                    }
                }
            }

            if let lead = supervisor.directLeadMs, lead > 25 {
                Text("Heads up: the Direct route runs \(Int(lead)) ms ahead of the group and can't be delayed. Put the slowest headphones on the Direct route if that bothers anyone.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Divider()

            Toggle("Group click test — everyone should hear ONE click, together", isOn: Binding(
                get: { clickTestOn },
                set: { on in
                    clickTestOn = on
                    if on {
                        grid = BeatGrid.startingSoon()
                        supervisor.startGroupClick(grid: grid)
                    } else {
                        supervisor.stopAllInjection()
                    }
                }
            ))

            VStack(alignment: .leading, spacing: 4) {
                Text("Match the picture (moves everyone together):")
                    .font(.callout)
                Slider(value: Binding(
                    get: { lastNudge },
                    set: { new in
                        supervisor.nudgeAllTappedDelays(by: new - lastNudge)
                        lastNudge = new
                    }
                ), in: supervisor.masterNudgeFloorMs + lastNudge...250)
                Text("If lips are ahead of the sound, drag left; behind, drag right. The Direct route can't shift.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Transitions

    private func advanceToTune(_ i: Int) {
        guard i < routeIDs.count else {
            if supervisor.directRoute != nil { advanceToPhantom() } else { applyAndVerify() }
            return
        }
        let id = routeIDs[i]
        grid = BeatGrid.startingSoon()
        // Seed with the previous tune, else the device's claimed latency — a
        // rough starting point that shortens the hunt.
        let route = supervisor.table.routes.first { $0.id == id }
        if let implied = route?.impliedLatencyMs {
            tunerValue = implied
        } else if let leg = route?.primaryLeg,
                  let device = supervisor.deviceMonitor.device(uid: leg.deviceUID) {
            tunerValue = Double(CA.reportedOutputLatencyFrames(device.id)) / max(device.sampleRate, 1) * 1000
        } else {
            tunerValue = 0
        }
        supervisor.startTunerBeep(routeID: id, grid: grid)
        supervisor.setTunerDelay(routeID: id, ms: tunerValue)
        step = .tune(i)
    }

    private func advanceToPhantom() {
        grid = BeatGrid.startingSoon()
        tunerValue = 150
        if supervisor.startPhantomBeep(grid: grid) {
            supervisor.setPhantomDelay(ms: tunerValue)
            step = .phantom
        } else {
            applyAndVerify()
        }
    }

    private func applyAndVerify() {
        supervisor.stopAllInjection()
        supervisor.applyTunedDelays(tuned, phantomTuned: phantomTuned)
        applied = true
        lastNudge = 0
        step = .verify
    }
}

/// The visual beat, rhythm-game style: an arrow flies in from each edge and
/// they meet at the center line exactly on every grid tick. The eye can
/// anticipate motion far better than it can react to a flash, which is why
/// rhythm games render beats this way — and why this beats the old pulse ring.
struct BeatTrack: View {
    let grid: BeatGrid

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { ctx, size in
                let period = grid.periodMs / 1000.0
                let t = context.date.timeIntervalSince(grid.date0)
                // True modulo so the pre-anchor lead-in has the arrows already
                // mid-flight, meeting the line dead on the very first beep.
                var phase = (t.truncatingRemainder(dividingBy: period)) / period
                if phase < 0 { phase += 1 }
                let flash = phase < 0.10 ? 1.0 - phase / 0.10 : 0.0

                let midY = size.height / 2
                let inset: CGFloat = 12
                let centerX = size.width / 2

                // The track.
                var base = Path()
                base.move(to: CGPoint(x: inset, y: midY))
                base.addLine(to: CGPoint(x: size.width - inset, y: midY))
                ctx.stroke(base, with: .color(Color.secondary.opacity(0.25)), lineWidth: 2)

                // The center line — flares the instant the arrows meet.
                let targetH = 24 + 14 * flash
                var target = Path()
                target.move(to: CGPoint(x: centerX, y: midY - targetH))
                target.addLine(to: CGPoint(x: centerX, y: midY + targetH))
                ctx.stroke(target,
                           with: .color(Color.accentColor.opacity(0.7 + 0.3 * flash)),
                           style: StrokeStyle(lineWidth: 3 + 3 * flash, lineCap: .round))
                if flash > 0 {
                    let r = 10 + 30 * (1 - flash)
                    let burst = Path(ellipseIn: CGRect(x: centerX - r, y: midY - r,
                                                       width: 2 * r, height: 2 * r))
                    ctx.stroke(burst, with: .color(Color.accentColor.opacity(0.55 * flash)), lineWidth: 2)
                }

                // The arrows: tips travel edge → center, arriving on the tick,
                // brightening and growing as they close in.
                let travel = centerX - inset
                let tipL = inset + travel * phase
                let tipR = size.width - inset - travel * phase
                let closeness = 0.45 + 0.55 * phase
                let ah = 8 + 3 * phase   // arrow half-height
                let aw = 13 + 4 * phase  // arrow length
                let style = StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)

                var left = Path()
                left.move(to: CGPoint(x: tipL - aw, y: midY - ah))
                left.addLine(to: CGPoint(x: tipL, y: midY))
                left.addLine(to: CGPoint(x: tipL - aw, y: midY + ah))
                ctx.stroke(left, with: .color(Color.accentColor.opacity(closeness)), style: style)

                var right = Path()
                right.move(to: CGPoint(x: tipR + aw, y: midY - ah))
                right.addLine(to: CGPoint(x: tipR, y: midY))
                right.addLine(to: CGPoint(x: tipR + aw, y: midY + ah))
                ctx.stroke(right, with: .color(Color.accentColor.opacity(closeness)), style: style)
            }
        }
    }
}
