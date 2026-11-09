import XCTest
@testable import Trailbox

final class TrailboxTests: XCTestCase {
    private func sample(_ id: String, _ type: TrailEventType = .position, _ payload: String = "a") -> TrailEvent {
        TrailEvent(id: id, tripID: "trip", deviceID: "device", type: type,
                   recordedAt: Date(timeIntervalSince1970: 1000), payload: ["value": payload])
    }

    func testMergeDeduplicatesIDs() {
        let a = sample("a")
        XCTAssertEqual(EventMerger.merge(existing: [a], incoming: [a]).count, 1)
    }

    func testExistingEventWinsConflictingDuplicate() {
        let first = sample("same", .position, "original")
        let conflicting = sample("same", .sos, "modified")
        XCTAssertEqual(EventMerger.merge(existing: [first], incoming: [conflicting]).first, first)
    }

    func testMergeTieOrderByID() {
        let events = EventMerger.merge(existing: [sample("z")], incoming: [sample("b")])
        XCTAssertEqual(events.map(\.id), ["b", "z"])
    }

    func testGPXParsesEightPoints() throws {
        let points = try GPXTrack.bundled()
        XCTAssertEqual(points.count, 8)
        XCTAssertEqual(points.first?.elevationMeters, 160)
        XCTAssertEqual(points.last!.timestamp.timeIntervalSince(points.first!.timestamp), 35 * 60)
    }

    func testSQLitePersistsAndDeduplicates() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let record = sample("persist")
        do {
            let store = try EventStore(path: path)
            XCTAssertTrue(try store.append(record))
            XCTAssertFalse(try store.append(record))
        }
        let reopened = try EventStore(path: path)
        XCTAssertEqual(try reopened.events(for: "trip"), [record])
    }

    func testSQLiteCollectsPairedIncidentAcrossTrips() throws {
        let store = try EventStore(path: ":memory:")
        let own = sample("own")
        let foreign = TrailEvent(id: "helper", tripID: "incident", deviceID: "passerby",
                                 type: .injuryVoice, payload: ["transcript": "ankle injury"])
        try store.append(own)
        try store.merge([foreign])
        XCTAssertEqual(Set(try store.allEvents().map(\.id)), ["own", "helper"])
        XCTAssertEqual(try store.events(for: "trip"), [own])
    }

    func testSQLiteMergeRespectsFirstWriter() throws {
        let store = try EventStore(path: ":memory:")
        let a = sample("same", .position, "original")
        XCTAssertEqual(try store.merge([a, a]), 1)
        XCTAssertEqual(try store.merge([sample("same", .sos, "altered")]), 0)
        XCTAssertEqual(try store.events(for: "trip").first, a)
    }
}
