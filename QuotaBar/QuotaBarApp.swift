import SwiftUI

@main
struct QuotaBarApp: App {
    @StateObject private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environmentObject(store)
        } label: {
            Text(store.menuTitle)
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}
