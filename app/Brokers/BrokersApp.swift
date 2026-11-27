import SwiftUI

extension Notification.Name {
    static let openDashboard = Notification.Name("BrokersOpenDashboard")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Launching the app again (Spotlight, Finder, Dock) opens the dashboard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .openDashboard, object: nil)
        return true
    }
}

@main
struct BrokersApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuPopover()
                .environmentObject(model)
                .scaledFonts()
        } label: {
            MenuBarLabel()
                .environmentObject(model)
                .task { model.start(); Updater.shared.start() }
        }
        .menuBarExtraStyle(.window)

        Window("money", id: "dashboard") {
            DashboardView()
                .environmentObject(model)
                .scaledFonts()
                .frame(minWidth: 980, minHeight: 700)
                .onAppear { WindowPresence.show() }
                .onDisappear { WindowPresence.hideIfNoWindows() }
        }
        .defaultSize(width: 1180, height: 860)
        .commands { FontScaleCommands() }

        Settings {
            SettingsView()
                .environmentObject(model)
                .scaledFonts()
                .onAppear { WindowPresence.show() }
                .onDisappear { WindowPresence.hideIfNoWindows() }
        }
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        label
            .onReceive(NotificationCenter.default.publisher(for: .openDashboard)) { _ in
                openWindow(id: "dashboard")
                WindowPresence.show()
            }
    }

    @ViewBuilder
    private var label: some View {
        if let p = model.portfolio {
            let m = model.money
            let total = m.compact(p.totals.netWorthUSD)
            let day = Fmt.arrowPct(p.totals.dayPLPct)
            switch p.menuBarStyle {
            case "total": Text(total)
            case "day": Text(day)
            default: Text("\(total) \(day)")
            }
        } else {
            Image(systemName: model.helperReachable || model.cloud != nil ? "chart.line.uptrend.xyaxis" : "exclamationmark.triangle")
        }
    }
}
