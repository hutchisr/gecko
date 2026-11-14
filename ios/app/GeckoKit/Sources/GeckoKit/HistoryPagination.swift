/// Pagination state for raw content-item pages. This deliberately never reads
/// rendered messages: unsupported items and out-of-window updates must not move
/// or replace the database cursor.
struct HistoryPagination {
    private(set) var nextBeforeItemID: Int32?
    private(set) var pendingBeforeItemID: Int32?
    private(set) var reachedBeginning = false
    private var latestPageItemIDs = Set<Int32>()

    var canLoadOlder: Bool {
        nextBeforeItemID != nil && !reachedBeginning
    }

    mutating func replaceWithLatestPage(
        itemIDs: [Int32],
        oldestItemID: Int32?,
        complete: Bool
    ) {
        latestPageItemIDs = Set(itemIDs)
        nextBeforeItemID = oldestItemID
        pendingBeforeItemID = nil
        reachedBeginning = complete || oldestItemID == nil
    }

    /// Returns whether the cached older rows still connect to this latest page.
    /// Only raw history rows prove overlap; incidental live updates do not.
    mutating func refreshLatestPage(
        itemIDs: [Int32],
        oldestItemID: Int32?,
        complete: Bool
    ) -> Bool {
        guard !complete, !latestPageItemIDs.isDisjoint(with: itemIDs) else {
            replaceWithLatestPage(itemIDs: itemIDs, oldestItemID: oldestItemID, complete: complete)
            return false
        }
        latestPageItemIDs = Set(itemIDs)
        return true
    }

    mutating func beginOlderRequest() -> Int32? {
        guard pendingBeforeItemID == nil, !reachedBeginning,
              let nextBeforeItemID else { return nil }
        pendingBeforeItemID = nextBeforeItemID
        return nextBeforeItemID
    }

    @discardableResult
    mutating func receiveOlderPage(
        requestedBeforeItemID: Int32,
        oldestItemID: Int32?,
        complete: Bool
    ) -> Bool {
        guard pendingBeforeItemID == requestedBeforeItemID else { return false }
        pendingBeforeItemID = nil
        if let oldestItemID {
            nextBeforeItemID = oldestItemID
        }
        reachedBeginning = complete || oldestItemID == nil || oldestItemID == requestedBeforeItemID
        return true
    }
}
