import AppKit
import ServiceManagement
import SwiftUI
import WidgetKit

@MainActor
final class AppModel: ObservableObject {
    @Published var portfolio: Portfolio?
    @Published var status: HelperStatus?
    @Published var history: History?
    @Published var historyRange: String = "1M" {
        didSet { Task { await loadHistory() } }
    }
    @Published var helperReachable = true
    @Published var lastUpdate: Date?
    @Published var toast: String?

    let api = APIClient()
    private var loops: [Task<Void, Never>] = []

    var money: Money {
        Money(portfolio?.displayCurrency ?? "SGD", fx: portfolio?.fx ?? FX(USDKRW: nil, USDSGD: nil))
    }
    var colors: PLColors { PLColors(portfolio?.colorStyle) }

    func start() {
        guard loops.isEmpty else { return }
        enableLaunchAtLoginOnce()
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.loadPortfolio()
                try? await Task.sleep(for: .seconds(3))
            }
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.loadStatus()
                try? await Task.sleep(for: .seconds(15))
            }
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.loadHistory()
                WidgetCenter.shared.reloadAllTimelines()
                try? await Task.sleep(for: .seconds(300))
            }
        })
    }

    func loadPortfolio() async {
        do {
            let p: Portfolio = try await api.get("v1/portfolio")
            if p != portfolio { portfolio = p }
            helperReachable = true
            lastUpdate = Date()
        } catch {
            helperReachable = false
        }
    }

    func loadStatus() async {
        if let s: HelperStatus = try? await api.get("v1/status"), s != status { status = s }
    }

    func loadHistory() async {
        if let h: History = try? await api.get("v1/history", query: ["range": historyRange]) { history = h }
    }

    // MARK: - Writes

    func updateSettings(_ patch: [String: Any]) async {
        do {
            let s: HelperStatus = try await api.write("PUT", "v1/settings", body: patch)
            status = s
            await loadPortfolio()
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            flash(error.localizedDescription)
        }
    }

    func saveSecrets(_ values: [String: String]) async {
        do {
            let s: HelperStatus = try await api.write("PUT", "v1/secrets", body: values)
            status = s
            flash("저장했습니다 (Keychain)")
            try? await Task.sleep(for: .seconds(3))
            await loadPortfolio()
            await loadStatus()
        } catch {
            flash(error.localizedDescription)
        }
    }

    func refreshNow() async {
        let _: [String: Bool]? = try? await api.write("POST", "v1/refresh")
        await loadPortfolio()
        flash("새로고침 요청했습니다")
    }

    func runBackfill() async {
        let _: HelperStatus.Backfill? = try? await api.write("POST", "v1/backfill")
        await loadStatus()
    }

    func setDisplayCurrency(_ c: DisplayCurrency) {
        Task { await updateSettings(["displayCurrency": c.rawValue]) }
    }

    func flash(_ msg: String) {
        toast = msg
        Task {
            try? await Task.sleep(for: .seconds(3))
            if toast == msg { toast = nil }
        }
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                flash("로그인 항목 설정 실패: \(error.localizedDescription)")
            }
            objectWillChange.send()
        }
    }

    private func enableLaunchAtLoginOnce() {
        let key = "didAutoEnableLaunchAtLogin"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }
}

/// Shows a Dock icon only while a regular window is open (menu-bar app otherwise).
enum WindowPresence {
    static func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    static func hideIfNoWindows() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let visible = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
            if !visible { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
