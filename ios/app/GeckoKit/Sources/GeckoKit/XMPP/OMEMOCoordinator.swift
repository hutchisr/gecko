import Foundation
import GRDB

/// OMEMO for one connected account: keeps our device list and bundle
/// published, learns contacts' devices, sets up sessions, and encrypts and
/// decrypts message bodies (XEP-0384 v0.3).
@MainActor
final class OMEMOCoordinator {
    enum Decrypted: Equatable {
        case text(String)
        /// A key-transport message: it only (re)built a session.
        case keyTransport
        /// Encrypted for other devices, not this one.
        case notForUs
        case failed(String)
    }

    typealias Request = (_ iq: StanzaNode, _ then: @escaping (StanzaNode) -> Void) -> Void

    let session: OMEMOSession
    private let store: GeckoStore
    private let account: String
    private let request: Request
    private let send: (StanzaNode) -> Void
    /// Device lists fetched this session, by bare JID.
    private var deviceLists: [String: [UInt32]] = [:]
    /// Devices whose bundle could not be used this session ("jid/device").
    private var unusable: Set<String> = []

    init(store: GeckoStore, account: String, request: @escaping Request, send: @escaping (StanzaNode) -> Void) throws {
        self.store = store
        self.account = account
        self.request = request
        self.send = send
        session = try OMEMOSession(store: store, account: account, trust: Self.blindTrust(store, account))
    }

    /// Blind trust before verification: a new device is trusted until the
    /// user has verified one of that contact's devices (or turned blind
    /// trust off); a device whose key changed, or that was distrusted, is not.
    static func blindTrust(_ store: GeckoStore, _ account: String) -> OMEMOSession.Trust {
        { jid, device, key in
            (try? store.db.write { db -> Bool in
                let row = try Row.fetchOne(db, sql: "SELECT identityKey, trust FROM omemoDevice WHERE account = ? AND jid = ? AND device = ?",
                                           arguments: [account, jid, Int64(device)])
                if let known = row?["identityKey"] as Data?, known != key { return false }
                switch row?["trust"] as String? {
                case "untrusted": return false
                case "trusted", "verified": return true
                default:
                    let blind = try Bool.fetchOne(db, sql: "SELECT enabled FROM omemoBlindTrust WHERE account = ? AND jid = ?",
                                                  arguments: [account, jid]) ?? true
                    guard blind else { return false }
                    try db.execute(sql: """
                        INSERT INTO omemoDevice (account, jid, device, identityKey, trust, lastSeen) VALUES (?, ?, ?, ?, 'trusted', ?)
                        ON CONFLICT(account, jid, device) DO UPDATE SET identityKey = excluded.identityKey, trust = 'trusted'
                        """, arguments: [account, jid, Int64(device), key, Date()])
                    return true
                }
            }) ?? false
        }
    }

    // MARK: Our device

    /// Makes sure our device is in our published list and our bundle is current.
    func start() {
        fetchDevices(account) { [weak self] devices in
            guard let self else { return }
            if !devices.contains(session.deviceID) {
                let list = devices + [session.deviceID]
                deviceLists[account] = list
                publish(OMEMOStanzas.deviceList, item: "current", OMEMOStanzas.deviceListPayload(list))
            }
            publishBundle()
        }
    }

    private func publishBundle() {
        guard let bundle = try? session.bundle() else { return }
        publish(OMEMOStanzas.bundleNode(session.deviceID), item: "current", OMEMOStanzas.bundlePayload(bundle))
    }

    private func publish(_ node: String, item: String, _ payload: StanzaNode) {
        request(OMEMOStanzas.publish(node, item: item, payload, id: "omemo-\(UUID().uuidString)")) { reply in
            if reply["type"] == "error" { NSLog("gecko-omemo: publishing %@ failed", node) }
        }
    }

    // MARK: Devices and sessions

    /// A contact (or we) published a new device list.
    func devicesChanged(_ jid: String, _ devices: [UInt32]) {
        deviceLists[jid] = devices
        if jid == account, !devices.contains(session.deviceID) {
            // Another client of ours dropped this device: put it back.
            let list = devices + [session.deviceID]
            deviceLists[account] = list
            publish(OMEMOStanzas.deviceList, item: "current", OMEMOStanzas.deviceListPayload(list))
        }
    }

    private func fetchDevices(_ jid: String, then: @escaping ([UInt32]) -> Void) {
        if let known = deviceLists[jid] { return then(known) }
        request(Avatars.itemsQuery(OMEMOStanzas.deviceList, to: jid, id: "omemo-list-\(UUID().uuidString)")) {
            [weak self] reply in
            let devices = OMEMOStanzas.devices(reply) ?? []
            self?.deviceLists[jid] = devices
            then(devices)
        }
    }

    /// Learns the devices of `jids` and sets up any missing sessions, then calls back.
    func prepare(_ jids: [String], then: @escaping () -> Void) {
        var waiting = jids.count
        for jid in jids {
            fetchDevices(jid) { [weak self] devices in
                guard let self else { return }
                let missing = devices.filter {
                    !(jid == self.account && $0 == self.session.deviceID) && !self.session.hasSession(jid, $0)
                        && !self.unusable.contains("\(jid)/\($0)")
                }
                var pending = missing.count
                let done = {
                    waiting -= 1
                    if waiting == 0 { then() }
                }
                if pending == 0 { return done() }
                for device in missing {
                    startSession(jid, device) {
                        pending -= 1
                        if pending == 0 { done() }
                    }
                }
            }
        }
    }

    private func startSession(_ jid: String, _ device: UInt32, then: @escaping () -> Void) {
        request(Avatars.itemsQuery(OMEMOStanzas.bundleNode(device), to: jid, id: "omemo-bundle-\(UUID().uuidString)")) {
            [weak self] reply in
            guard let self else { return }
            do {
                guard let bundle = OMEMOStanzas.bundle(reply) else { throw OMEMOError(code: -1, step: "no bundle") }
                try session.startSession(jid, device, bundle: bundle)
            } catch {
                unusable.insert("\(jid)/\(device)")
                NSLog("gecko-omemo: no session with %@/%u: %@", jid, device, "\(error)")
            }
            then()
        }
    }

    // MARK: Messages

    /// The `<encrypted/>` and its companions for a body to `jid` (and our other
    /// devices), after `prepare`; nil when `jid` has no device we can reach.
    func encrypt(_ body: String, to jid: String) -> [StanzaNode]? {
        encrypt(body, to: [jid])
    }

    /// For several recipients (a private room's members): nil when none of
    /// them has a device we can reach.
    func encrypt(_ body: String, to jids: [String]) -> [StanzaNode]? {
        guard let sealed = try? OMEMOStanzas.seal(body) else { return nil }
        var keys: [(device: UInt32, data: Data, preKey: Bool)] = []
        var reachedPeer = false
        for target in Set(jids + [account]) {
            for device in deviceLists[target] ?? [] where !(target == account && device == session.deviceID) {
                guard session.hasSession(target, device),
                      let key = try? session.encrypt(sealed.keyMaterial, for: target, device) else { continue }
                keys.append((device, key.data, key.preKey))
                if target != account { reachedPeer = true }
            }
        }
        guard reachedPeer else { return nil }
        return OMEMOStanzas.encrypted(from: session.deviceID, iv: sealed.iv, payload: sealed.payload, keys: keys)
    }

    /// Opens an encrypted message from `sender` (a bare JID: the contact, or
    /// us for a copy from another of our devices). `live`: not from the
    /// archive, so a failure says the session is broken now and is repaired.
    func decrypt(_ encrypted: StanzaNode, from sender: String, live: Bool) -> Decrypted {
        guard let received = OMEMOStanzas.received(encrypted, for: session.deviceID) else { return .notForUs }
        do {
            let material = try session.decrypt(received.key, preKey: received.preKey, from: sender, received.sender)
            if received.preKey, (try? session.refillPreKeys()) == true { publishBundle() }
            guard let payload = received.payload else { return .keyTransport }
            return .text(try OMEMOStanzas.open(payload, iv: received.iv, keyMaterial: material))
        } catch let error as OMEMOError where live && !received.preKey && error.code != -1001 {
            // A session that stopped decrypting (lost or out of step on the
            // other side): set up a new one and tell them through it, so their
            // next message decrypts. A duplicate (-1001) needs nothing.
            repair(sender, received.sender)
            return .failed("\(error)")
        } catch {
            return .failed("\(error)")
        }
    }

    private func repair(_ jid: String, _ device: UInt32) {
        startSession(jid, device) { [weak self] in
            guard let self, session.hasSession(jid, device), let sealed = try? OMEMOStanzas.seal(""),
                  let key = try? session.encrypt(sealed.keyMaterial, for: jid, device) else { return }
            send(StanzaNode("message", XMPPNS.client, ["to": jid, "type": "chat", "id": UUID().uuidString],
                            OMEMOStanzas.encrypted(from: session.deviceID, iv: sealed.iv, payload: nil,
                                                   keys: [(device, key.data, key.preKey)])))
        }
    }
}
