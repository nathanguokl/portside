import AppKit
import SwiftUI

enum PortsideBrand {
    static let blue = Color(red: 8.0 / 255, green: 118.0 / 255, blue: 239.0 / 255)

    // The packaged app carries its resource bundle in Contents/Resources.
    // SwiftPM supplies Bundle.module when running directly from the build folder.
    private static let resources: Bundle = {
        if let url = Bundle.main.url(forResource: "Portside_Portside", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()

    static let logo: NSImage? = resources.url(forResource: "portside-logo", withExtension: "png", subdirectory: "Branding")
        .flatMap { NSImage(contentsOf: $0) }

    static let applicationIcon: NSImage? = {
        let url = Bundle.main.url(forResource: "Portside", withExtension: "icns")
            ?? resources.url(forResource: "portside-icon", withExtension: "png", subdirectory: "Branding")
        return url.flatMap { NSImage(contentsOf: $0) }
    }()
}

@MainActor final class PortsideAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        ExternalOpenInbox.shared.onTerminate?()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        ExternalOpenInbox.shared.receive(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return !ExternalOpenInbox.shared.presentWindow()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // AppKit also needs an explicit running-app icon when SwiftPM or a
        // direct executable launch has not supplied one through LaunchServices.
        if let icon = PortsideBrand.applicationIcon {
            NSApplication.shared.applicationIconImage = icon
        }
        ExternalOpenInbox.shared.finishedLaunching = true
        ExternalOpenInbox.shared.presentWindow()
    }
}

struct PortsideLogo: View {
    var size: CGFloat

    var body: some View {
        Group {
            if let logo = PortsideBrand.logo {
                Image(nsImage: logo).renderingMode(.original).resizable().scaledToFit()
            } else {
                Image(systemName: "p.square.fill").resizable().scaledToFit().foregroundStyle(PortsideBrand.blue)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
