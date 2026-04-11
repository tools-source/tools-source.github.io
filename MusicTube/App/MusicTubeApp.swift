import SwiftUI

@main
struct MusicTubeApp: App {
    @StateObject private var appState = AppState.makeDefault()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .task {
                    AppContainer.shared.appState = appState
                    AppContainer.shared.carPlayManager?.refresh(using: appState)
                }
        }
    }
}
