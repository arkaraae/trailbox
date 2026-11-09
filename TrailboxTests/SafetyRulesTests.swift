import XCTest
import CoreLocation
@testable import Trailbox

final class SafetyRulesTests: XCTestCase {
    func testToblerTimeAndDarknessUseRemainingElevation() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertGreaterThan(SafetyRules.toblerHours(distanceKm: 3, elevationChangeMeters: 500),
                             SafetyRules.toblerHours(distanceKm: 3, elevationChangeMeters: 0))
        XCTAssertTrue(SafetyRules.timeToDark(remainingKm: 3, elevationChangeMeters: 500,
                                              paceMultiplier: 1, now: now,
                                              sunset: now.addingTimeInterval(3_600)))
        XCTAssertFalse(SafetyRules.timeToDark(remainingKm: 0.1, elevationChangeMeters: 0,
                                               paceMultiplier: 1, now: now,
                                               sunset: now.addingTimeInterval(3_600)))
    }

    func testOffRouteUsesPolylineDistance() {
        let route = [CLLocationCoordinate2D(latitude: 37, longitude: -122),
                     CLLocationCoordinate2D(latitude: 37, longitude: -121.999)]
        XCTAssertFalse(SafetyRules.offRoute(CLLocationCoordinate2D(latitude: 37.0002, longitude: -121.9995), route: route))
        XCTAssertTrue(SafetyRules.offRoute(CLLocationCoordinate2D(latitude: 37.001, longitude: -121.9995), route: route))
    }

    func testStormNeedsPressureAndForecast() {
        XCTAssertTrue(SafetyRules.storm(olderHectopascals: 1010, currentHectopascals: 1007.8,
                                        elapsedMinutes: 45, adverseForecast: true))
        XCTAssertFalse(SafetyRules.storm(olderHectopascals: 1010, currentHectopascals: 1007.8,
                                         elapsedMinutes: 45, adverseForecast: false))
        XCTAssertFalse(SafetyRules.storm(olderHectopascals: 1010, currentHectopascals: 1007.8,
                                         elapsedMinutes: 70, adverseForecast: true))
    }

    func testProjectedBattery() {
        XCTAssertTrue(SafetyRules.batteryCritical(currentPercent: 30, drainPercentPerHour: 10,
                                                  hoursUntilReturn: 2))
        XCTAssertFalse(SafetyRules.batteryCritical(currentPercent: 70, drainPercentPerHour: 10,
                                                   hoursUntilReturn: 2))
    }

    func testStillnessEscalatesAfterUnansweredPrompt() {
        let now = Date(timeIntervalSince1970: 10_000)
        let lastMovement = now.addingTimeInterval(-21 * 60)
        XCTAssertEqual(SafetyRules.stillness(now: now, lastMovement: lastMovement,
                                              offTrail: true, promptAt: nil, responded: false), .prompt)
        XCTAssertEqual(SafetyRules.stillness(now: now, lastMovement: lastMovement,
                                              offTrail: true, promptAt: now.addingTimeInterval(-121),
                                              responded: false), .sos)
        XCTAssertEqual(SafetyRules.stillness(now: now, lastMovement: lastMovement,
                                              offTrail: true, promptAt: nil, responded: true), .none)
    }

    func testOverdueRequiresMissingCheckIn() {
        let returnTime = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(SafetyRules.overdue(now: returnTime.addingTimeInterval(1_799), expectedReturn: returnTime, checkedIn: false))
        XCTAssertTrue(SafetyRules.overdue(now: returnTime.addingTimeInterval(1_800), expectedReturn: returnTime, checkedIn: false))
        XCTAssertFalse(SafetyRules.overdue(now: returnTime.addingTimeInterval(2_000), expectedReturn: returnTime, checkedIn: true))
    }
}
