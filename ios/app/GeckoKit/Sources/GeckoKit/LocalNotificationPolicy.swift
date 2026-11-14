struct LocalNotificationPolicyInput {
    var appIsActive: Bool
    var isNew: Bool
    var isSynced: Bool
    var direction: String
    var notifyEffective: String
    var isGroupchat: Bool
    var mentioned: Bool
}

func shouldPostLocalNotification(_ input: LocalNotificationPolicyInput) -> Bool {
    guard !input.appIsActive, input.isNew, !input.isSynced, input.direction == "in" else {
        return false
    }
    switch input.notifyEffective {
    case "off":
        return false
    case "highlight":
        return !input.isGroupchat || input.mentioned
    default:
        return true
    }
}

/// Which contact requests still deserve an alert. A pending request is
/// repeated by the server at every sign-in, so a requester alerts once and
/// then stays quiet until their request is answered.
struct ContactRequestAlerts {
    /// Requesters already alerted; the caller keeps this across launches.
    private(set) var alerted: [String]

    init(alerted: [String]) {
        self.alerted = alerted
    }

    mutating func shouldAlert(_ jid: String) -> Bool {
        guard !alerted.contains(jid) else { return false }
        alerted.append(jid)
        return true
    }

    mutating func answered(_ jid: String) {
        alerted.removeAll { $0 == jid }
    }
}
