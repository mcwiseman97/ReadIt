import AppKit
import SwiftUI

@main
struct ReadItApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var appState: AppState { appDelegate.appState }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(appState.preferences)
                .environmentObject(appState.engine)
        } label: {
            Image(systemName: "text.bubble.fill")
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(appState.preferences)
                .environmentObject(appState.engine)
                .frame(width: 460, height: 420)
        }
    }
}
