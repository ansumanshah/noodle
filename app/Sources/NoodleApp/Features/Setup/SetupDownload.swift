import SwiftUI
import Observation

/// Bytes of one download that is running, read from the work folder.
struct SetupDownload: Equatable {
    var done: Int64
    var total: Int64?
}
