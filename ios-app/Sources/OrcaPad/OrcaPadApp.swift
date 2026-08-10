import SwiftUI

extension Notification.Name {
    /// Posted with a file URL when the app is asked to open a model
    /// (Files app "Open in OrcaPad", drag & drop, …).
    static let openModelURL = Notification.Name("openModelURL")
}

@main
struct OrcaPadApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    NotificationCenter.default.post(name: .openModelURL, object: url)
                }
        }
    }
}
