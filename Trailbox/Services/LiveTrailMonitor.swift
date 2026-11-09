import Foundation
import CoreLocation
import CoreMotion

/// Foreground location and impact samples. Decision thresholds live in SafetyRules.
@MainActor
final class LiveTrailMonitor: NSObject, CLLocationManagerDelegate {
    var onLocation: ((CLLocation) -> Void)?
    var onImpact: ((Double) -> Void)?
    var onStatus: ((String) -> Void)?
    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionManager()
    private var active = false
    private var lastImpactAt = Date.distantPast

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 10
    }

    func start() {
        active = true
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else { startSensorsIfAuthorized() }
    }

    func stop() {
        active = false
        locationManager.stopUpdatingLocation()
        motionManager.stopAccelerometerUpdates()
        onStatus?("Live monitoring stopped")
    }

    private func startSensorsIfAuthorized() {
        guard active else { return }
        guard locationManager.authorizationStatus == .authorizedWhenInUse ||
              locationManager.authorizationStatus == .authorizedAlways else {
            onStatus?("Location permission required")
            return
        }
        locationManager.startUpdatingLocation()
        if motionManager.isAccelerometerAvailable {
            motionManager.accelerometerUpdateInterval = 0.1
            motionManager.startAccelerometerUpdates(to: .main) { [weak self] sample, _ in
                guard let sample else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.active else { return }
                    let a = sample.acceleration
                    let magnitude = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
                    if SafetyRules.possibleFall(impactG: magnitude),
                       Date().timeIntervalSince(self.lastImpactAt) > 30 {
                        self.lastImpactAt = Date()
                        self.onImpact?(magnitude)
                    }
                }
            }
        }
        onStatus?("Live GPS and impact monitoring active")
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in startSensorsIfAuthorized() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard active, let location = locations.last, location.horizontalAccuracy >= 0 else { return }
            onLocation?(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in onStatus?("GPS: \(error.localizedDescription)") }
    }
}
