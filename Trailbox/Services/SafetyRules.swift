import Foundation
import CoreLocation

/// Pure functions. No model output can trigger or suppress these decisions.
enum SafetyRules {
    static func toblerHours(distanceKm: Double, elevationChangeMeters: Double,
                            paceMultiplier: Double = 1) -> Double {
        guard distanceKm > 0, paceMultiplier > 0 else { return 0 }
        let slope = elevationChangeMeters / (distanceKm * 1_000)
        let speedKmPerHour = 6 * exp(-3.5 * abs(slope + 0.05)) * paceMultiplier
        return distanceKm / max(speedKmPerHour, 0.2)
    }

    static func timeToDark(remainingKm: Double, elevationChangeMeters: Double,
                           paceMultiplier: Double, now: Date, sunset: Date) -> Bool {
        let hours = toblerHours(distanceKm: remainingKm,
                                elevationChangeMeters: elevationChangeMeters,
                                paceMultiplier: paceMultiplier)
        return now.addingTimeInterval(hours * 3_600) >= sunset
    }

    static func distanceFromRouteMeters(_ location: CLLocationCoordinate2D,
                                        route: [CLLocationCoordinate2D]) -> Double {
        guard !route.isEmpty else { return .infinity }
        let latitudeScale = 111_320.0
        let longitudeScale = latitudeScale * cos(location.latitude * .pi / 180)
        let projected = route.map { point in
            ((point.longitude - location.longitude) * longitudeScale,
             (point.latitude - location.latitude) * latitudeScale)
        }
        guard projected.count > 1 else { return hypot(projected[0].0, projected[0].1) }
        return zip(projected, projected.dropFirst()).map { a, b in
            let dx = b.0 - a.0
            let dy = b.1 - a.1
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0 ? max(0, min(1, -(a.0 * dx + a.1 * dy) / lengthSquared)) : 0
            return hypot(a.0 + t * dx, a.1 + t * dy)
        }.min() ?? .infinity
    }

    static func offRoute(_ location: CLLocationCoordinate2D,
                         route: [CLLocationCoordinate2D], thresholdMeters: Double = 60) -> Bool {
        distanceFromRouteMeters(location, route: route) > thresholdMeters
    }

    static func storm(olderHectopascals: Double, currentHectopascals: Double,
                      elapsedMinutes: Double, adverseForecast: Bool) -> Bool {
        elapsedMinutes <= 60 && elapsedMinutes > 0 &&
        olderHectopascals - currentHectopascals > 2 && adverseForecast
    }

    static func batteryCritical(currentPercent: Double, drainPercentPerHour: Double,
                                hoursUntilReturn: Double) -> Bool {
        currentPercent - max(0, drainPercentPerHour) * max(0, hoursUntilReturn) < 15
    }

    enum StillnessAction: Equatable { case none, prompt, sos }

    static func stillness(now: Date, lastMovement: Date, offTrail: Bool,
                          promptAt: Date?, responded: Bool) -> StillnessAction {
        guard offTrail, !responded, now.timeIntervalSince(lastMovement) > 20 * 60 else { return .none }
        if let promptAt, now.timeIntervalSince(promptAt) > 2 * 60 { return .sos }
        return .prompt
    }

    static func overdue(now: Date, expectedReturn: Date, checkedIn: Bool) -> Bool {
        !checkedIn && now >= expectedReturn.addingTimeInterval(30 * 60)
    }
}
