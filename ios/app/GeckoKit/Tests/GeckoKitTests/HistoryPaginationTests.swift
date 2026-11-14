import XCTest
@testable import GeckoKit

final class HistoryPaginationTests: XCTestCase {
    func testFreshPaginationCannotLoadWithoutCursor() {
        XCTAssertFalse(HistoryPagination().canLoadOlder)
    }

    func testInitialRequestUsesRawPageCursor() {
        var paging = HistoryPagination()
        paging.replaceWithLatestPage(itemIDs: [101, 102], oldestItemID: 101, complete: false)

        XCTAssertTrue(paging.canLoadOlder)
        XCTAssertEqual(paging.beginOlderRequest(), 101)
        XCTAssertTrue(paging.canLoadOlder)
    }

    func testDecodedEmptyPageStillAdvancesRawCursor() {
        var paging = HistoryPagination()
        paging.replaceWithLatestPage(itemIDs: [101, 102], oldestItemID: 101, complete: false)
        XCTAssertEqual(paging.beginOlderRequest(), 101)

        XCTAssertTrue(paging.receiveOlderPage(
            requestedBeforeItemID: 101,
            oldestItemID: 51,
            complete: false))
        XCTAssertEqual(paging.beginOlderRequest(), 51)
    }

    func testLatestRefreshPreservesDeeperCursor() {
        var paging = HistoryPagination()
        paging.replaceWithLatestPage(itemIDs: Array(101...150), oldestItemID: 101, complete: false)
        XCTAssertEqual(paging.beginOlderRequest(), 101)
        XCTAssertTrue(paging.receiveOlderPage(
            requestedBeforeItemID: 101,
            oldestItemID: 51,
            complete: false))

        XCTAssertTrue(paging.refreshLatestPage(
            itemIDs: Array(121...170), oldestItemID: 121, complete: false))

        XCTAssertEqual(paging.beginOlderRequest(), 51)
    }

    func testCompleteLatestRefreshInvalidatesPendingRequest() {
        var paging = HistoryPagination()
        paging.replaceWithLatestPage(itemIDs: Array(101...150), oldestItemID: 101, complete: false)
        XCTAssertEqual(paging.beginOlderRequest(), 101)

        XCTAssertFalse(paging.refreshLatestPage(
            itemIDs: Array(80...120), oldestItemID: 80, complete: true))

        XCTAssertFalse(paging.receiveOlderPage(
            requestedBeforeItemID: 101,
            oldestItemID: 51,
            complete: false))
        XCTAssertNil(paging.beginOlderRequest())
    }

    func testResponseFromBeforeResetIsIgnored() {
        var paging = HistoryPagination()
        paging.replaceWithLatestPage(itemIDs: [101, 102], oldestItemID: 101, complete: false)
        XCTAssertEqual(paging.beginOlderRequest(), 101)

        paging.replaceWithLatestPage(itemIDs: [201, 202], oldestItemID: 201, complete: false)

        XCTAssertFalse(paging.receiveOlderPage(
            requestedBeforeItemID: 101,
            oldestItemID: 51,
            complete: false))
        XCTAssertEqual(paging.beginOlderRequest(), 201)
    }

    func testNonAdvancingCursorStopsPagination() {
        var paging = HistoryPagination()
        paging.replaceWithLatestPage(itemIDs: [101, 102], oldestItemID: 101, complete: false)
        XCTAssertEqual(paging.beginOlderRequest(), 101)

        XCTAssertTrue(paging.receiveOlderPage(
            requestedBeforeItemID: 101,
            oldestItemID: 101,
            complete: false))
        XCTAssertFalse(paging.canLoadOlder)
        XCTAssertNil(paging.beginOlderRequest())
    }

    func testDisjointRefreshMakesMissingHistoryReachableFromCompleteAndPartialCaches() throws {
        let database = (1...110).map(Int32.init)
        let latest = Array(database.suffix(50))
        for oldComplete in [true, false] {
            var paging = HistoryPagination()
            paging.replaceWithLatestPage(
                itemIDs: Array(database.prefix(10)), oldestItemID: 1, complete: oldComplete)

            XCTAssertFalse(paging.refreshLatestPage(
                itemIDs: latest, oldestItemID: latest.first, complete: false))
            XCTAssertTrue(paging.canLoadOlder)
            var loaded = latest
            // The two older pages must cover 11...60, then 1...10. The old
            // reachedBeginning flag or cursor must not strand either range.
            for _ in 0..<2 {
                let before = try XCTUnwrap(paging.beginOlderRequest())
                let boundary = try XCTUnwrap(database.firstIndex(of: before))
                let page = Array(database[..<boundary].suffix(50))
                XCTAssertTrue(paging.receiveOlderPage(
                    requestedBeforeItemID: before,
                    oldestItemID: page.first,
                    complete: page.count < 50))
                loaded.insert(contentsOf: page, at: 0)
            }
            XCTAssertEqual(loaded, database)
            XCTAssertNil(paging.beginOlderRequest())
        }
    }

    func testDisjointRefreshRejectsPendingResponseAfterStartingNewRequest() {
        var paging = HistoryPagination()
        paging.replaceWithLatestPage(itemIDs: Array(1...50), oldestItemID: 1, complete: false)
        XCTAssertEqual(paging.beginOlderRequest(), 1)

        XCTAssertFalse(paging.refreshLatestPage(
            itemIDs: Array(61...110), oldestItemID: 61, complete: false))
        XCTAssertEqual(paging.beginOlderRequest(), 61)
        XCTAssertFalse(paging.receiveOlderPage(
            requestedBeforeItemID: 1, oldestItemID: nil, complete: true))
        XCTAssertTrue(paging.receiveOlderPage(
            requestedBeforeItemID: 61, oldestItemID: 11, complete: false))
        XCTAssertEqual(paging.beginOlderRequest(), 11)
    }

    func testRawOverlapPreservesPendingRequestWithoutAssumingIDChronology() {
        var paging = HistoryPagination()
        // Raw item 88 may be an unsupported call, absent from rendered messages.
        // The other IDs deliberately do not increase with chronological order.
        paging.replaceWithLatestPage(itemIDs: [501, 12, 88], oldestItemID: 501, complete: false)
        XCTAssertEqual(paging.beginOlderRequest(), 501)

        XCTAssertTrue(paging.refreshLatestPage(
            itemIDs: [88, 7, 600], oldestItemID: 88, complete: false))
        XCTAssertNil(paging.beginOlderRequest())
        XCTAssertTrue(paging.receiveOlderPage(
            requestedBeforeItemID: 501, oldestItemID: 900, complete: false))
        XCTAssertEqual(paging.beginOlderRequest(), 900)
    }

    func testOverlappingRefreshPreservesCompleteHistoryAndUpdatesOverlapEvidence() {
        var paging = HistoryPagination()
        paging.replaceWithLatestPage(itemIDs: Array(1...10), oldestItemID: 1, complete: true)

        XCTAssertTrue(paging.refreshLatestPage(
            itemIDs: Array(5...54), oldestItemID: 5, complete: false))
        XCTAssertTrue(paging.refreshLatestPage(
            itemIDs: Array(54...103), oldestItemID: 54, complete: false))
        XCTAssertNil(paging.beginOlderRequest())

        XCTAssertFalse(paging.refreshLatestPage(
            itemIDs: Array(104...153), oldestItemID: 104, complete: false))
        XCTAssertEqual(paging.beginOlderRequest(), 104)
    }
}
