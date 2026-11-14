import XCTest
@testable import GeckoKit

final class LocalNotificationPolicyTests: XCTestCase {
    private var eligible: LocalNotificationPolicyInput {
        LocalNotificationPolicyInput(
            appIsActive: false,
            isNew: true,
            isSynced: false,
            direction: "in",
            notifyEffective: "on",
            isGroupchat: false,
            mentioned: false
        )
    }

    func testPostsEligibleIncomingMessage() {
        XCTAssertTrue(shouldPostLocalNotification(eligible))
    }

    func testSuppressesInactiveDeliveryFailures() {
        var input = eligible
        input.appIsActive = true
        XCTAssertFalse(shouldPostLocalNotification(input))

        input = eligible
        input.isNew = false
        XCTAssertFalse(shouldPostLocalNotification(input))

        input = eligible
        input.isSynced = true
        XCTAssertFalse(shouldPostLocalNotification(input))

        input = eligible
        input.direction = "out"
        XCTAssertFalse(shouldPostLocalNotification(input))
    }

    func testAppliesConversationNotificationSetting() {
        var input = eligible
        input.notifyEffective = "off"
        XCTAssertFalse(shouldPostLocalNotification(input))

        input = eligible
        input.notifyEffective = "highlight"
        input.isGroupchat = true
        XCTAssertFalse(shouldPostLocalNotification(input))

        input.mentioned = true
        XCTAssertTrue(shouldPostLocalNotification(input))
    }

    func testContactRequestAlertsOncePerRequest() {
        var alerts = ContactRequestAlerts(alerted: [])
        XCTAssertTrue(alerts.shouldAlert("friend@example.org"))
        XCTAssertFalse(alerts.shouldAlert("friend@example.org"), "the sign-in repeat must stay quiet")
        XCTAssertTrue(alerts.shouldAlert("other@example.org"))

        // What was saved is what the next launch starts from.
        var relaunched = ContactRequestAlerts(alerted: alerts.alerted)
        XCTAssertFalse(relaunched.shouldAlert("friend@example.org"))

        relaunched.answered("friend@example.org")
        XCTAssertTrue(relaunched.shouldAlert("friend@example.org"), "a new request after an answer alerts again")
        XCTAssertFalse(relaunched.shouldAlert("other@example.org"))
    }
}
