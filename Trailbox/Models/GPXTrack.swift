import Foundation
import CoreLocation

struct TrackPoint: Sendable {
    let latitude: Double
    let longitude: Double
    let elevationMeters: Double
    let timestamp: Date

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

enum GPXError: Error {
    case missingTrack
    case invalidXML
}

enum GPXTrack {
    static func bundled(named name: String = "sample-hike") throws -> [TrackPoint] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "gpx") else {
            throw GPXError.missingTrack
        }
        return try parse(data: Data(contentsOf: url))
    }

    static func parse(data: Data) throws -> [TrackPoint] {
        let delegate = GPXParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), !delegate.points.isEmpty else { throw GPXError.invalidXML }
        return delegate.points
    }
}

private final class GPXParserDelegate: NSObject, XMLParserDelegate {
    private var latitude: Double?
    private var longitude: Double?
    private var elevation: Double = 0
    private var time: Date?
    private var currentField = ""
    private var contents = ""
    var points: [TrackPoint] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        if name == "trkpt" {
            latitude = attributeDict["lat"].flatMap(Double.init)
            longitude = attributeDict["lon"].flatMap(Double.init)
            elevation = 0
            time = nil
        }
        currentField = name
        contents = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        contents += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.components(separatedBy: ":").last ?? elementName
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "ele" { elevation = Double(trimmed) ?? 0 }
        if name == "time" { time = ISO8601DateFormatter().date(from: trimmed) }
        if name == "trkpt", let latitude, let longitude {
            // The sample includes timestamps. Other GPX files without timestamps get synthetic times.
            let stamp = time ?? Date(timeIntervalSince1970: 0).addingTimeInterval(Double(points.count) * 300)
            points.append(TrackPoint(latitude: latitude, longitude: longitude,
                                     elevationMeters: elevation, timestamp: stamp))
        }
        contents = ""
        currentField = ""
    }
}
