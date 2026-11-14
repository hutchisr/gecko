import Foundation

/// The app's door to the Swift XMPP core (`SwiftCore`). Commands are
/// fire-and-forget from any thread and run on the main queue in order; events
/// come back as JSON-shaped dictionaries on the main queue via `onEvent`.
final class GeckoCore {
    static let shared = GeckoCore()
    var onEvent: (([String: Any]) -> Void)?
    private var core: SwiftCore?

    private init() {}

    /// App Group shared with the Notification Service Extension, which reads
    /// the same store and keychain to fetch what a push announced.
    static let appGroupID = "group.me.anemoneya.gecko"

    func start() {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.startCore() } }
    }

    /// Closes every stream before the process ends (main thread, at
    /// termination): waits up to half a second for the closing to be written.
    func stop() {
        MainActor.assumeIsolated {
            guard let core else { return }
            NSLog("gecko-core: closing streams")
            var closed = false
            Task { await core.stop(); closed = true }
            let deadline = Date().addingTimeInterval(0.5)
            while !closed, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
    }

    /// Where data lives: `data/gecko` holds Gecko's store and files, and
    /// `data/dino` what the old Dino-based Gecko left behind (imported once).
    /// Catalyst uses per-app Library/Caches; iOS prefers the App Group
    /// container shared with the extension, falling back to per-app storage.
    static func storageDirs() -> (data: String, config: String, cache: String) {
        let fm = FileManager.default
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let legacy = (data: library.appendingPathComponent("xdg-data"),
                      config: library.appendingPathComponent("xdg-config"),
                      cache: caches.appendingPathComponent("xdg-cache"))

#if targetEnvironment(macCatalyst)
        // The local Mac build has no App Group entitlement, and asking
        // containermanager for another app's group triggers macOS's repeated
        // "access data from other apps" consent prompt. The persistent Mac
        // process does not need NSE-shared storage for local notifications.
        return (legacy.data.path, legacy.config.path, legacy.cache.path)
#else

        guard let container = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            geckoDebugLog("GeckoCore: App Group unavailable, using per-app storage")
            return (legacy.data.path, legacy.config.path, legacy.cache.path)
        }
        let shared = (data: container.appendingPathComponent("xdg-data"),
                      config: container.appendingPathComponent("xdg-config"),
                      cache: container.appendingPathComponent("xdg-cache"))
        migrateStorage(legacy.data, to: shared.data, fm: fm)
        migrateStorage(legacy.config, to: shared.config, fm: fm)
        migrateStorage(legacy.cache, to: shared.cache, fm: fm)
        return (shared.data.path, shared.config.path, shared.cache.path)
#endif
    }

    /// Move an old XDG root into the shared container, but only when the new
    /// location is empty — never clobber a container the NSE may already use.
    private static func migrateStorage(_ from: URL, to: URL, fm: FileManager) {
        guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { return }
        do {
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: from, to: to)
            geckoDebugLog("GeckoCore: migrated %@ -> %@", from.path, to.path)
        } catch {
            geckoDebugLog("GeckoCore: storage migration failed for %@: %@", from.path, error.localizedDescription)
        }
    }

    func sendStanza(account: String, xml: String) { swift { core in core.sendStanza(account: account, xml: xml) } }
    func addAccount(jid: String, password: String) { swift { core in core.addAccount(jid: jid, password: password) } }
    func signOut() { swift { core in core.signOut() } }
    func setAvatar(path: String) { swift { core in core.setAvatar(path: path) } }
    func setAlias(_ alias: String) { swift { core in core.setAlias(alias) } }
    func changePassword(_ pw: String) { swift { core in core.changePassword(pw) } }
    func requestAccountDetails() { swift { core in core.requestAccountDetails() } }
    func appForegrounded() { swift { core in core.appForegrounded() } }
    func appBackgrounded() { swift { core in core.appBackgrounded() } }
    func enablePush(proxyJid: String, node: String) { swift { core in core.enablePush(proxy: proxyJid, token: node) } }
    func setNotify(_ id: Int32, _ setting: String) { swift { core in core.setNotify(Int64(id), setting) } }
    func setPresence(show: String, status: String) { swift { core in core.setPresence(show: show, status: status) } }
    func requestSelfPresence() { swift { core in core.requestSelfPresence() } }
    func requestBlocklist() { swift { core in core.requestBlocklistEmit() } }
    func blockContact(_ jid: String) { swift { core in core.setBlocked(jid, true) } }
    func unblockContact(_ jid: String) { swift { core in core.setBlocked(jid, false) } }
    func requestPrivacy() { swift { core in core.requestPrivacy() } }
    func setSendTyping(_ on: Bool) { swift { core in core.setPrivacy("send_typing", on) } }
    func setSendMarker(_ on: Bool) { swift { core in core.setPrivacy("send_marker", on) } }
    func focusConversation(_ id: Int32) { swift { core in core.focus(Int64(id)) } }
    func blurConversation(_ id: Int32) { swift { core in core.blur(Int64(id)) } }
    func setTyping(_ id: Int32, _ typing: Bool) { swift { core in core.setTyping(Int64(id), typing) } }
    func requestAvatar(jid: String) { swift { core in core.requestAvatar(jid: jid) } }
    func sendFile(_ id: Int32, path: String) { swift { core in core.sendFile(Int64(id), path: path) } }
    func previewFileTransport(_ id: Int32, path: String, requestID: String) { swift { core in core.previewFileTransport(Int64(id), path: path, requestID: requestID) } }
    func downloadFile(_ id: Int32, item: Int32) { swift { core in core.downloadFile(Int64(id), item: Int64(item)) } }
    func joinMuc(jid: String, nick: String?) { swift { core in core.joinMuc(jid: jid, nick: nick) } }
    func acceptMucInvite(account: String, room: String, password: String?) { swift { core in core.acceptMucInvite(account: account, room: room, password: password) } }
    func createMuc(jid: String, nick: String?) { swift { core in core.createMuc(jid: jid, nick: nick) } }
    func setReaction(_ id: Int32, item: Int32, emoji: String, add: Bool) { swift { core in core.setReaction(Int64(id), item: Int64(item), emoji: emoji, add: add) } }
    func correctMessage(_ id: Int32, item: Int32, body: String) { swift { core in core.correctMessage(Int64(id), item: Int64(item), body: body) } }
    func closeConversation(_ id: Int32) { swift { core in core.closeConversation(Int64(id)) } }
    func requestOccupants(_ id: Int32) { swift { core in core.requestOccupants(Int64(id)) } }
    func startRoomMemberDM(_ id: Int32, jid: String) { swift { core in core.startRoomMemberDM(Int64(id), jid: jid) } }
    func mucKick(_ id: Int32, nick: String) { swift { core in core.mucKick(Int64(id), nick: nick) } }
    func mucSetAffiliation(_ id: Int32, jid: String, affiliation: String) { swift { core in core.mucSetAffiliation(Int64(id), jid: jid, affiliation: affiliation) } }
    func mucSetRole(_ id: Int32, nick: String, role: String) { swift { core in core.mucSetRole(Int64(id), nick: nick, role: role) } }
    func requestRoomInfo(_ id: Int32) { swift { core in core.requestRoomInfo(Int64(id)) } }
    func mucSetSubject(_ id: Int32, subject: String) { swift { core in core.mucSetSubject(Int64(id), subject) } }
    func mucInvite(_ id: Int32, jid: String) { swift { core in core.mucInvite(Int64(id), jid: jid) } }
    func mucSetName(_ id: Int32, name: String) { swift { core in core.mucSetName(Int64(id), name) } }
    func mucSetPrivate(_ id: Int32, _ priv: Bool) { swift { core in core.mucSetPrivate(Int64(id), priv) } }
    func mucSetModerated(_ id: Int32, _ moderated: Bool) { swift { core in core.mucSetModerated(Int64(id), moderated) } }
    func mucSetAvatar(_ id: Int32, path: String) { swift { core in core.mucSetAvatar(Int64(id), path: path) } }
    func addContact(jid: String, alias: String?) { swift { core in core.addContact(jid: jid, alias: alias) } }
    func removeContact(jid: String) { swift { core in core.removeContact(jid: jid) } }
    func respondSubscription(jid: String, approve: Bool) { swift { core in core.respondSubscription(jid: jid, approve: approve) } }
    func requestState() { swift { core in core.requestState() } }
    func startConversation(jid: String) { swift { core in core.startConversation(jid: jid) } }
    func requestMessages(conversation: Int32, count: Int32 = 50) { swift { core in core.requestMessages(Int64(conversation), count: Int(count)) } }
    func requestMessagesBefore(conversation: Int32, before item: Int32, count: Int32 = 50) { swift { core in core.requestMessagesBefore(Int64(conversation), before: Int64(item), count: Int(count)) } }
    func sendText(conversation: Int32, body: String, replyTo: Int32 = 0) { swift { core in core.sendText(Int64(conversation), body: body, replyTo: replyTo > 0 ? Int64(replyTo) : nil) } }
    func setEncryption(conversation: Int32, omemo: Bool) { swift { core in core.setEncryption(Int64(conversation), omemo: omemo) } }
    func cancelTransfer(item: Int32) { swift { core in core.cancelTransfer(Int64(item)) } }

    @MainActor
    private func startCore() {
        let directory = URL(fileURLWithPath: Self.storageDirs().data).appendingPathComponent("gecko")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let passwords = KeychainPasswords()
        do {
            var store = try GeckoStore(path: directory.appendingPathComponent("gecko.sqlite").path)
            store.fileRoots = [directory.appendingPathComponent("files"),
                               URL(fileURLWithPath: Self.storageDirs().data).appendingPathComponent("dino/files")]
            // First launch after the Dino-based Gecko: bring its history, keys and passwords over.
            let dino = URL(fileURLWithPath: Self.storageDirs().data).appendingPathComponent("dino")
            if try store.accounts().isEmpty,
               FileManager.default.fileExists(atPath: dino.appendingPathComponent("dino.db").path) {
                let report = try DinoImport.run(dino: dino.appendingPathComponent("dino.db").path,
                                                omemo: dino.appendingPathComponent("omemo.db").path, into: store)
                report.passwords.forEach { passwords.setPassword($1, for: $0) }
                NSLog("gecko-core: imported %d messages from Dino's database", report.messages)
            }
            let avatars = [directory.appendingPathComponent("avatars"),
                           URL(fileURLWithPath: Self.storageDirs().cache).appendingPathComponent("dino/avatars")]
            let core = SwiftCore(store: store, passwords: passwords, resource: "gecko.\(UUID().uuidString.prefix(8))",
                                 avatarDirectories: avatars) {
                [weak self] event in self?.deliver(event)
            }
            self.core = core
            core.start()
        } catch {
            deliver(["type": "fatal", "message": "\(error)"])
        }
    }

    /// Events go through JSON, so `AppModel` sees the types it always did
    /// (NSNumber, NSNull).
    private func deliver(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return }
        emit(json)
    }

    /// Runs a command on the main queue, in the order commands came (callers
    /// are on any thread).
    private func swift(_ body: @escaping @MainActor (SwiftCore) -> Void, name: String = #function) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let core = self.core { body(core) } else { NSLog("gecko-core: %@ before the core started", name) }
            }
        }
    }

    private func emit(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            geckoDebugLog("GeckoCore: undecodable event (%d bytes)", json.count)
            return
        }
        DispatchQueue.main.async { self.onEvent?(dict) }
    }
}

