import SwiftUI

@main
struct BucksCopyApp: App {
    @StateObject private var viewModel = AppEnvironment.live.makeDashboardViewModel()

    var body: some Scene {
        WindowGroup {
            DashboardView(viewModel: viewModel)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
