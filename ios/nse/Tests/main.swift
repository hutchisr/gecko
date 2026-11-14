import Foundation
import UserNotifications

// Host-only boundary doubles: exercise the real NotificationService without
// starting the XMPP core, accessing the shared account database, or contacting APNs.
// swiftc ios/nse/NotificationService.swift ios/nse/Tests/main.swift -o /tmp/gecko-nse-check
struct NSEMessage {
    let conversationJid: String
    let conversationName: String
    let sender: String
    let body: String
    let isMuted: Bool
    let isGroupchat: Bool
}

struct NSEFetchResult {
    let messages: [NSEMessage]
    let unreadCount: Int?
}

enum NSEFetcher {
    static var result = NSEFetchResult(messages: [], unreadCount: nil)

    static func fetch(timeoutMs: Int32, completion: @escaping (NSEFetchResult) -> Void) {
        completion(result)
    }
}

func deliver(_ messages: [NSEMessage]) -> UNNotificationContent {
    NSEFetcher.result = NSEFetchResult(messages: messages, unreadCount: 3)
    let original = UNMutableNotificationContent()
    original.title = "Gecko"
    original.body = "New message"
    let request = UNNotificationRequest(identifier: "selection-check", content: original, trigger: nil)
    var delivered: UNNotificationContent?
    NotificationService().didReceive(request) { delivered = $0 }
    guard let delivered else { fatalError("Notification did not complete") }
    precondition(delivered.badge?.intValue == 3, "Unread badge must include muted conversations")
    return delivered
}

let direct = NSEMessage(
    conversationJid: "friend@example.org", conversationName: "Friend", sender: "Friend",
    body: "Direct message", isMuted: false, isGroupchat: false)
let room = NSEMessage(
    conversationJid: "room@example.org", conversationName: "Room", sender: "Member",
    body: "Room message", isMuted: false, isGroupchat: true)
let muted = NSEMessage(
    conversationJid: "muted@example.org", conversationName: "Muted", sender: "Muted member",
    body: "Muted message", isMuted: true, isGroupchat: true)

for batch in [[direct, muted], [muted, direct]] {
    let content = deliver(batch)
    precondition(content.title == "Friend" && content.body == "Direct message")
    precondition(content.userInfo["conversationJid"] as? String == "friend@example.org")
    precondition(content.subtitle.isEmpty, "Muted messages must not inflate the preview count")
}
let mixed = deliver([direct, room, muted])
precondition(mixed.title == "Room" && mixed.body == "Member: Room message")
precondition(mixed.userInfo["conversationJid"] as? String == "room@example.org")
precondition(mixed.subtitle == "2 new messages")
let suppressed = deliver([muted])
precondition(suppressed.title.isEmpty && suppressed.body.isEmpty && suppressed.userInfo.isEmpty)
let empty = deliver([])
precondition(empty.title == "Gecko" && empty.body == "New message")
print("Notification selection passed: mixed orderings, latest eligible preview, eligible count, all-muted, empty fetch")
