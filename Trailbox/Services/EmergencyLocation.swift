import Foundation
import CoreLocation
import Combine

@MainActor
final class EmergencyLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var status = "Current GPS not requested"
    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestCurrentLocation() {
        switch manager.authorizationStatus {
        case .notDetermined:
            status = "Waiting for location permission"
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            status = "Finding current GPS position…"
            manager.requestLocation()
        case .denied, .restricted:
            status = "Location access unavailable; enter coordinates manually"
        @unknown default:
            status = "Location access unavailable"
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if manager.authorizationStatus == .authorizedAlways ||
               manager.authorizationStatus == .authorizedWhenInUse {
                requestCurrentLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard let latest = locations.last, latest.horizontalAccuracy >= 0 else { return }
            coordinate = latest.coordinate
            status = String(format: "GPS: %.5f, %.5f (±%.0f m)", latest.coordinate.latitude,
                            latest.coordinate.longitude, latest.horizontalAccuracy)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in status = "GPS unavailable: \(error.localizedDescription)" }
    }
}
