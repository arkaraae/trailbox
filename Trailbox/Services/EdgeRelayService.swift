import Foundation
import MultipeerConnectivity

/// Nearby phones receive a minimal SOS beacon. Medical details and exact GPS stay out of discovery.
@MainActor
final class EdgeRelayService: NSObject, ObservableObject {
    @Published private(set) var status = "Looking for nearby iPhones" { didSet { onStatus?(status, peerCount) } }
    @Published private(set) var peerCount = 0 { didSet { onStatus?(status, peerCount) } }
    var onStatus: ((String, Int) -> Void)?
    var eventsProvider: (() -> [TrailEvent])?
    var receiveEvents: (([TrailEvent]) -> Void)?
    private let deviceID: String
    private let peer: MCPeerID
    private let session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser!
    private var browser: MCNearbyServiceBrowser!
    private var started = false

    init(deviceID: String) {
        self.deviceID = deviceID
        peer = MCPeerID(displayName: String(deviceID.prefix(8)))
        session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
        advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: nil, serviceType: "trailbox-sync")
        advertiser.delegate = self
        browser = MCNearbyServiceBrowser(peer: peer, serviceType: "trailbox-sync")
        browser.delegate = self
    }

    func start() {
        guard !started else { return }
        started = true
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        status = "Looking for nearby iPhones"
    }

    func stop() {
        started = false
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        peerCount = 0
        status = "Nearby search stopped"
    }

    func sendSnapshot() {
        guard !session.connectedPeers.isEmpty else { return }
        let beacons = (eventsProvider?() ?? [])
            .filter { $0.type == .sos && $0.deviceID == deviceID && $0.payload["nearby_beacon"] != "true" }
            .suffix(5)
            .map { sos in
                TrailEvent(id: "beacon:\(sos.id)", tripID: sos.tripID, deviceID: sos.deviceID,
                           type: .sos, recordedAt: sos.recordedAt,
                           payload: ["nearby_beacon": "true",
                                     "what_happened": "Nearby hiker requested help",
                                     "location_source": "not_shared"])
            }
        guard !beacons.isEmpty else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(beacons)
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
            status = "Help alert sent to \(session.connectedPeers.count) nearby iPhone(s)"
        } catch { status = "Nearby error: \(error.localizedDescription)" }
    }
}

extension EdgeRelayService: MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate, MCSessionDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?,
                                invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in invitationHandler(true, session) }
    }
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in status = "Nearby unavailable: \(error.localizedDescription)" }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            if peer.displayName < peerID.displayName {
                browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
            }
        }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in status = "Nearby unavailable: \(error.localizedDescription)" }
    }
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            peerCount = session.connectedPeers.count
            if state == .connected { status = "Connected to nearby iPhone"; sendSnapshot() }
            if state == .notConnected { status = "Looking for nearby iPhones" }
        }
    }
    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            guard data.count < 64_000 else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let received = try? decoder.decode([TrailEvent].self, from: data) else { return }
            let safe = received.prefix(5).compactMap { event -> TrailEvent? in
                guard event.type == .sos, event.id.hasPrefix("beacon:"),
                      event.payload["nearby_beacon"] == "true",
                      UUID(uuidString: event.tripID) != nil else { return nil }
                return TrailEvent(id: event.id, tripID: event.tripID, deviceID: event.deviceID,
                                  type: .sos, recordedAt: event.recordedAt,
                                  payload: ["nearby_beacon": "true",
                                            "what_happened": "Nearby hiker requested help",
                                            "location_source": "not_shared"])
            }
            if !safe.isEmpty { receiveEvents?(safe); status = "Nearby help alert received" }
        }
    }
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream,
                             withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
