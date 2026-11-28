import SwiftUI
import AppKit
import NoodleCore

/// Noodle's own icon from the app bundle. A development run has no bundle, so it falls back to the icon in Resources.
@MainActor
enum SetupIcon {
    static var image: NSImage {
        if Bundle.main.bundleURL.pathExtension == "app" { return NSApplication.shared.applicationIconImage }
        if let url = NoodlePaths.resolve().resourcesDirectory?.appendingPathComponent("AppIcon.icns"),
           let icon = NSImage(contentsOf: url) { return icon }
        return NSApplication.shared.applicationIconImage
    }
}
