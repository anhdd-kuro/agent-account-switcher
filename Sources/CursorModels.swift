import Foundation

struct CursorUsageSnapshot: Equatable {
    let membership: String?
    let planUsed: Int?
    let autoUsed: Int?
    let apiUsed: Int?
    let resetAt: Date?
}

enum CursorMenuBarLane: String {
    case off, auto, api, both
}

struct CursorUsageState: Equatable {
    var isInstalled = false
    var snapshot: CursorUsageSnapshot?
    var error: String?
    var updatedAt: Date?
}
