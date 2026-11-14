import Foundation

/// Connects the account, catches up on the archives (storing and decrypting
/// into the app's shared database) and calls back once with the incoming
/// messages and the unread total collected within the time budget (or on
/// timeout). Storing and acknowledging here means the server stops pushing
/// that message, and the app shows what was decrypted once.
enum NSEFetcher {
    static func fetch(timeoutMs: Int32, completion: @escaping (NSEFetchResult) -> Void) {
        // A stable, per-install resource for the extension: a repeat wake then
        // replaces its own server session instead of leaving a new one each
        // time, and it never collides with the app's "gecko.<hex>" resource.
        let defaults = UserDefaults(suiteName: "group.me.anemoneya.gecko")
        let resource: String
        if let saved = defaults?.string(forKey: "nseResource") {
            resource = saved
        } else {
            resource = "gecko-nse." + UUID().uuidString.prefix(8).lowercased()
            defaults?.set(resource, forKey: "nseResource")
        }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                SwiftFetch.run(resource: resource, timeout: TimeInterval(timeoutMs) / 1000, completion: completion)
            }
        }
    }
}

struct NSEFetchResult {
    let messages: [NSEMessage]
    let unreadCount: Int?
}

/// One decrypted incoming message, with the conversation's notify policy so
/// the extension can decide whether to present or suppress it.
struct NSEMessage {
    let conversationJid: String
    let conversationName: String
    let sender: String
    let body: String
    let notify: String        // "on" | "off" | "highlight" | "default"
    let isGroupchat: Bool
    let mentioned: Bool

    init(json: [String: Any]) {
        conversationJid = json["jid"] as? String ?? ""
        conversationName = json["conversation_name"] as? String ?? ""
        sender = json["from"] as? String ?? ""
        body = json["body"] as? String ?? ""
        notify = json["notify"] as? String ?? "on"
        isGroupchat = json["groupchat"] as? Bool ?? false
        mentioned = json["mentioned"] as? Bool ?? false
    }

    /// Apply the conversation's per-chat notification setting.
    var isMuted: Bool {
        switch notify {
        case "off": return true
        case "highlight": return isGroupchat && !mentioned
        default: return false
        }
    }
}

/// The Swift core's catch-up for one push.
@MainActor
private final class SwiftFetch {
    /// Keeps the fetch alive until it reports.
    private static var current: SwiftFetch?
    private let store: GeckoStore
    private let completion: (NSEFetchResult) -> Void
    private var core: SwiftCore?
    private var order: [Int64] = []
    private var items: [Int64: [String: Any]] = [:]
    private var finished = false

    private init(store: GeckoStore, completion: @escaping (NSEFetchResult) -> Void) {
        self.store = store
        self.completion = completion
    }

    static func run(resource: String, timeout: TimeInterval, completion: @escaping (NSEFetchResult) -> Void) {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.me.anemoneya.gecko"),
              let store = try? GeckoStore(path: container.appendingPathComponent("xdg-data/gecko/gecko.sqlite").path),
              (try? store.accounts().contains { $0.enabled }) == true else {
            return completion(NSEFetchResult(messages: [], unreadCount: nil))
        }
        let fetch = SwiftFetch(store: store, completion: completion)
        current = fetch
        let core = SwiftCore(store: store, passwords: KeychainPasswords(), resource: resource, avatarDirectories: [],
                             forNotifications: true) { [weak fetch] event in fetch?.receive(event) }
        fetch.core = core
        core.onCaughtUp = { [weak fetch] in fetch?.finish() }
        core.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak fetch] in fetch?.finish() }
    }

    private func receive(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "message":
            guard event["direction"] as? String == "in", let item = event["item"] as? Int64 else { return }
            if items[item] == nil { order.append(item) }
            items[item] = event
        case "connection_error":
            finish()
        default:
            break
        }
    }

    private func finish() {
        guard !finished, let core else { return }
        finished = true
        var conversations: [Int64: [String: Any]] = [:]
        for conversation in (try? store.conversationList()) ?? [] {
            if let id = conversation["id"] as? Int64 { conversations[id] = conversation }
        }
        let messages = order.compactMap { items[$0] }.compactMap { item -> NSEMessage? in
            guard let id = item["conversation"] as? Int64, let conversation = conversations[id] else { return nil }
            let room = conversation["kind"] as? String == "groupchat"
            let name = conversation["name"] as? String ?? ""
            let body = item["content"] as? String == "file"
                ? "📎 " + (item["file_name"] as? String ?? "File") : item["body"] as? String ?? ""
            return NSEMessage(json: [
                "jid": conversation["jid"] as? String ?? "", "conversation_name": name,
                "from": room ? item["from_display"] as? String ?? "" : name, "body": body,
                "notify": conversation["notify"] as? String ?? "on", "groupchat": room,
                "mentioned": item["mentioned"] as? Bool ?? false,
            ])
        }
        let unread = core.unreadTotal()
        Task {
            await core.stop()
            completion(NSEFetchResult(messages: messages, unreadCount: unread))
            Self.current = nil
        }
    }
}
