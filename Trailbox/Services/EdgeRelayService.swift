import Foundation
import MultipeerConnectivity
import CryptoKit

/// An encrypted, incident-code-gated link exchanges only emergency events.
@MainActor
final class EdgeRelayService: NSObject, ObservableObject {
    @Published private(set) var status = "Not connected" { didSet { onStatus?(status, peerCount) } }
    @Published private(set) var peerCount = 0 { didSet { onStatus?(status, peerCount) } }
    var onStatus: ((String, Int) -> Void)?
    private let tripID: String
    private let tripTag: String
    private let peer: MCPeerID
    private let session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser!
    private var browser: MCNearbyServiceBrowser!
    var eventsProvider: (() -> [TrailEvent])?
    var receiveEvents: (([TrailEvent]) -> Void)?

    init(tripID: String, deviceID: String) {
        self.tripID = tripID
        tripTag = SHA256.hash(data: Data(tripID.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        peer = MCPeerID(displayName: String(deviceID.prefix(8)))
        session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
        advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: ["tag": tripTag], serviceType: "trailbox-sync")
        advertiser.delegate = self
        browser = MCNearbyServiceBrowser(peer: peer, serviceType: "trailbox-sync")
        browser.delegate = self
    }

    func start() {
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        status = "Searching for nearby Trailbox phones"
    }

    func stop() {
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        peerCount = 0
        status = "Not connected"
    }

    func sendSnapshot() {
        guard !session.connectedPeers.isEmpty, let all = eventsProvider?() else { return }
        let events = all.filter { $0.tripID == tripID && ($0.type == .sos || $0.type == .injuryVoice) }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(RelayEnvelope(tripID: tripID, events: events))
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
            status = "Shared \(events.count) events with \(session.connectedPeers.count) peer(s)"
        } catch { status = "Relay error: \(error.localizedDescription)" }
    }

    private struct RelayEnvelope: Codable {
        let tripID: String
        let events: [TrailEvent]
    }
}

extension EdgeRelayService: MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate, MCSessionDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                                didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?,
                                invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in invitationHandler(context == Data(tripID.utf8), session) }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in status = "Advertiser error: \(error.localizedDescription)" }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                             withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in
            guard info?["tag"] == tripTag, peer.displayName < peerID.displayName else { return }
            browser.invitePeer(peerID, to: session, withContext: Data(tripID.utf8), timeout: 15)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in status = "Browser error: \(error.localizedDescription)" }
    }

    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in
            peerCount = session.connectedPeers.count
            if state == .connected { status = "Connected to \(peerID.displayName)"; sendSnapshot() }
            if state == .notConnected { status = "Peer disconnected; searching" }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let envelope = try? decoder.decode(RelayEnvelope.self, from: data),
                  envelope.tripID == tripID else { return }
            receiveEvents?(envelope.events.filter {
                $0.tripID == tripID && ($0.type == .sos || $0.type == .injuryVoice)
            })
            status = "Received \(envelope.events.count) events from \(peerID.displayName)"
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream,
                             withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                             fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
