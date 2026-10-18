import SwiftUI

@main
struct SSHClientMacApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                // Session and connection commands arrive in phase 1/2.
            }
        }
    }
}
