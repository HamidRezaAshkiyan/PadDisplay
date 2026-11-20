import SwiftUI

@main
struct PadDisplayApp: App {
    private let appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(state: appState)
        } label: {
            Image(systemName: appState.isRunning ? "ipad.landscape" : "display")
        }
        .menuBarExtraStyle(.window)
    }
}
