import Foundation

/// Test-only stand-in so `Snapshot`'s subscript type-checks without the app target.
enum UsageSources {
    static func emptyLane(_ key: LaneKey) -> Lane {
        .empty(key, sub: "not connected")
    }
}
