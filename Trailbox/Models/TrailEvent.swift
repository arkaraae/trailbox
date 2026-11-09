import Foundation

enum TrailEventType: String, Codable, CaseIterable {
    case tripPlan = "trip_plan"
    case position
    case paceUpdate = "pace_update"
    case vitals
    case warning
    case sos
    case injuryVoice = "injury_voice"
    case checkedIn = "checked_in"
    case hazardReport = "hazard_report"
    case sync
    case agentNote = "agent_note"
}

/// A stable, immutable event. Sync will deduplicate on `id` rather than changing prior rows.
struct TrailEvent: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let tripID: String
    let deviceID: String
    let type: TrailEventType
    let recordedAt: Date
    let payload: [String: String]

    init(id: String = UUID().uuidString, tripID: String, deviceID: String,
         type: TrailEventType, recordedAt: Date = Date(), payload: [String: String] = [:]) {
        self.id = id
        self.tripID = tripID
        self.deviceID = deviceID
        self.type = type
        self.recordedAt = recordedAt
        self.payload = payload
    }
}

/// Merge is deterministic and append-only: existing IDs always win, including conflicting payloads.
enum EventMerger {
    static func merge(existing: [TrailEvent], incoming: [TrailEvent]) -> [TrailEvent] {
        var byID: [String: TrailEvent] = [:]
        for event in existing { if byID[event.id] == nil { byID[event.id] = event } }
        for event in incoming { if byID[event.id] == nil { byID[event.id] = event } }
        return byID.values.sorted {
            if $0.recordedAt == $1.recordedAt { return $0.id < $1.id }
            return $0.recordedAt < $1.recordedAt
        }
    }
}
