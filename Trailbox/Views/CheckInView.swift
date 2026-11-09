import SwiftUI

struct CheckInView: View {
    @EnvironmentObject private var model: TrailboxViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 54)).foregroundStyle(.orange)
                Text("Are you okay?").font(.largeTitle.bold())
                Text("Trailbox noticed \((model.checkInReason ?? "a safety signal").replacingOccurrences(of: "_", with: " ")).")
                    .multilineTextAlignment(.center)
                if let deadline = model.checkInPromptedAt?.addingTimeInterval(120) {
                    Text("SOS in").font(.caption)
                    Text(deadline, style: .timer).font(.system(size: 36, weight: .bold, design: .rounded))
                }
                if let coordinate = model.liveCoordinate {
                    Text(String(format: "Location %.5f, %.5f", coordinate.latitude, coordinate.longitude))
                        .font(.system(.footnote, design: .monospaced))
                } else { Text("Waiting for GPS position").font(.footnote) }
                Button("I'm okay") { model.confirmSafe() }
                    .buttonStyle(.borderedProminent).tint(.green)
                Button("Send SOS now") { model.sendSOSForCheckIn() }
                    .buttonStyle(.borderedProminent).tint(.red)
                Text("If you do not respond within 2 minutes, Trailbox records an SOS and attempts delivery through a configured connection.")
                    .font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            .padding(25)
            .navigationTitle("Safety check-in")
        }
    }
}
