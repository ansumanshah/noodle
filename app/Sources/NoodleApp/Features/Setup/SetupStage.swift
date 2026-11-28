import SwiftUI
import Observation

enum SetupStage: Int, Equatable {
    case detect, plan, download, engine, importChoice, install, importing, container, done, failed
}
