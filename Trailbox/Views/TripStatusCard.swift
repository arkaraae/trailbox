import SwiftUI
import CoreLocation

/// Dashboard card inspired by the supplied "The right path" reference.
struct TripStatusCard: View {
    @ObservedObject var model: TrailboxViewModel

    private var progress: CGFloat {
        guard model.points.count > 1 else { return 0 }
        return CGFloat(model.pointIndex) / CGFloat(model.points.count - 1)
    }

    private var distanceMiles: Double {
        if model.isLiveTracking { return model.liveDistanceMeters / 1_609.344 }
        guard model.pointIndex > 0 else { return 0 }
        return zip(model.points.prefix(model.pointIndex), model.points.dropFirst().prefix(model.pointIndex))
            .reduce(0) { total, pair in
                total + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                    .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
            } / 1_609.344
    }

    private var elapsed: String {
        let seconds = Int(model.isLiveTracking ? model.liveElapsedSeconds : model.elapsedSeconds)
        return String(format: "%02d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "map")
                    .font(.system(size: 22, weight: .light))
                    .frame(width: 54, height: 54)
                    .background(.white.opacity(0.1), in: Circle())
                Text(model.importedRouteName.map { ($0 as NSString).deletingPathExtension } ?? "Demo route")
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.58, green: 0.92, blue: 0.43))
                    .lineLimit(1)
                Spacer(minLength: 0)
                VStack(spacing: 4) {
                    ForEach(0..<5, id: \.self) { index in
                        Circle().fill(index == min(4, Int(progress * 5)) ? .white : .white.opacity(0.25))
                            .frame(width: 6, height: 6)
                    }
                }
            }
            RouteProgressLine(progress: progress)
                .frame(height: 43)
            VStack(alignment: .leading, spacing: 5) {
                Text(elapsed).font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("Time").font(.system(size: 20)).foregroundStyle(.white.opacity(0.62))
            }
            Rectangle().fill(.white.opacity(0.28)).frame(height: 1)
            VStack(alignment: .leading, spacing: 5) {
                Text(String(format: "%.1f mi", distanceMiles))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("Distance").font(.system(size: 20)).foregroundStyle(.white.opacity(0.62))
            }
        }
        .padding(22)
        .foregroundStyle(.white)
        .background {
            RoundedRectangle(cornerRadius: 34)
                .fill(Color(red: 0.18, green: 0.19, blue: 0.19))
                .overlay(alignment: .bottom) {
                    Ellipse().fill(Color(red: 0.20, green: 0.26, blue: 0.23).opacity(0.8))
                        .frame(height: 85).blur(radius: 35).clipped()
                }
                .clipShape(RoundedRectangle(cornerRadius: 34))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("trailbox.tripStatus")
    }
}

private struct RouteProgressLine: View {
    let progress: CGFloat
    private let samples: [CGFloat] = [0.64, 0.51, 0.37, 0.45, 0.69, 0.57, 0.65, 0.48, 0.67, 0.78, 0.70]

    var body: some View {
        GeometryReader { geometry in
            let points = samples.enumerated().map { index, y in
                CGPoint(x: geometry.size.width * CGFloat(index) / CGFloat(samples.count - 1),
                        y: geometry.size.height * y)
            }
            let marker = markerPoint(points)
            ZStack(alignment: .topLeading) {
                path(points).stroke(.white.opacity(0.24), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                path(points).trimmedPath(from: 0, to: max(0.01, progress))
                    .stroke(Color(red: 0.58, green: 0.92, blue: 0.43),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                Circle().fill(Color(red: 0.29, green: 0.58, blue: 0.95))
                    .frame(width: 24, height: 24)
                    .overlay(Circle().stroke(.white, lineWidth: 3))
                    .position(marker)
            }
        }
        .accessibilityLabel("Route progress \(Int(progress * 100)) percent")
    }

    private func path(_ points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for index in 1..<points.count { path.addLine(to: points[index]) }
        }
    }

    private func markerPoint(_ points: [CGPoint]) -> CGPoint {
        guard points.count > 1 else { return .zero }
        let scaled = max(0, min(1, progress)) * CGFloat(points.count - 1)
        let index = min(points.count - 2, Int(scaled))
        let fraction = scaled - CGFloat(index)
        return CGPoint(x: points[index].x + (points[index + 1].x - points[index].x) * fraction,
                       y: points[index].y + (points[index + 1].y - points[index].y) * fraction)
    }
}
