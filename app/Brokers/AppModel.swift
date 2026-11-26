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
    @Published var retrying: Set<String> = []
    @Published var gatewayLaunching = false
    @Published var retryResult: [String: RetryResult] = [:]
    @Published var watchlist: WatchlistResponse?
    /// Signed-in Google account (shared with the helper via cloud.json).
    @Published var cloud: CloudSession? = CloudSession.load()
    /// True while numbers come from Firestore because this Mac has no helper.
    @Published var cloudMode = false
    @Published var cloudUpdated: Date?
    @Published var cloudError: String?
    @Published var signingIn = false
    private var cloudFetchedAt = Date.distantPast
    private var cloudHistory: [String: History] = [:]
    private var cloudHistoryAt = Date.distantPast
    private var uploadedGoal: String?
    static let viewOnly = "보기 전용이에요 — 데이터를 모으는 Mac에서 해주세요"

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
                await self?.loadWatchlist()
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
            noteFinishedWork(old: portfolio, new: p)
            if p != portfolio { portfolio = p }
            helperReachable = true
            cloudMode = false
            lastUpdate = Date()
        } catch {
            helperReachable = false
            await loadFromCloud()
        }
    }

    // MARK: - 클라우드 (다른 Mac의 데이터 보기)

    private func loadFromCloud() async {
        guard let s = cloud else {
            if cloudMode { cloudMode = false; portfolio = nil }
            return
        }
        if Date().timeIntervalSince(cloudFetchedAt) < 30 { return }  // host uploads once a minute
        cloudFetchedAt = Date()
        do {
            guard let doc = try await CloudClient.shared.get(s, "state/live"),
                  let p = doc.decode(Portfolio.self, "portfolio")
            else { throw CloudError.noData }
            if p != portfolio { portfolio = p }
            if let w = doc.decode(WatchlistResponse.self, "watchlist"), w != watchlist { watchlist = w }
            if let st = doc.decode(HelperStatus.self, "status"), st != status { status = st }
            cloudUpdated = doc.date("updated")
            lastUpdate = cloudUpdated
            cloudError = nil
            if !cloudMode {
                cloudMode = true
                await loadHistory()
            }
            await pullGoal(s)
        } catch {
            cloudError = error.localizedDescription
        }
    }

    private func loadCloudHistory() async {
        guard let s = cloud else { return }
        if !cloudHistory.isEmpty && Date().timeIntervalSince(cloudHistoryAt) < 300 { return }
        cloudHistoryAt = Date()
        if let doc = try? await CloudClient.shared.get(s, "state/history"),
           let h = doc.decode([String: History].self, "ranges") {
            cloudHistory = h
        }
    }

    private static func goalJSON() -> String {
        let d = UserDefaults.standard
        let g: [String: Any] = [
            "amount": d.object(forKey: Goal.amountKey) as? Double ?? 1e8,
            "currency": d.string(forKey: Goal.currencyKey) ?? "KRW",
            "name": d.string(forKey: Goal.nameKey) ?? "1억 모으기",
            "enabled": d.object(forKey: Goal.enabledKey) as? Bool ?? true,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: g, options: .sortedKeys)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Data Mac: keep the goal in the cloud so viewer Macs show the same one.
    private func pushGoal() async {
        guard let s = cloud, !cloudMode, helperReachable else { return }
        let g = Self.goalJSON()
        guard g != uploadedGoal else { return }
        if (try? await CloudClient.shared.put(s, "state/prefs", strings: ["goal": g])) != nil { uploadedGoal = g }
    }

    private var goalPulledAt = Date.distantPast
    private func pullGoal(_ s: CloudSession) async {
        guard Date().timeIntervalSince(goalPulledAt) > 300 else { return }
        goalPulledAt = Date()
        guard let doc = try? await CloudClient.shared.get(s, "state/prefs"),
              let raw = doc.string("goal"),
              let g = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
        else { return }
        let d = UserDefaults.standard
        if let v = g["amount"] as? Double { d.set(v, forKey: Goal.amountKey) }
        if let v = g["currency"] as? String { d.set(v, forKey: Goal.currencyKey) }
        if let v = g["name"] as? String { d.set(v, forKey: Goal.nameKey) }
        if let v = g["enabled"] as? Bool { d.set(v, forKey: Goal.enabledKey) }
    }

    func signInCloud() async {
        guard let cfg = CloudConfig.shared else { flash(CloudError.notConfigured.localizedDescription); return }
        guard !signingIn else { return }
        signingIn = true
        defer { signingIn = false }
        do {
            let s = try await GoogleSignIn.signIn(cfg)
            try s.save()
            await CloudClient.shared.reset()
            cloud = s
            uploadedGoal = nil
            NSApp.activate()
            flash("\(s.email ?? "Google 계정")으로 로그인했어요")
            let _: CloudState? = try? await api.write("POST", "v1/cloud/sync")
            await pushGoal()
            try? await Task.sleep(for: .seconds(3))
            await loadStatus()
            if !helperReachable { await loadPortfolio() }
        } catch {
            flash(error.localizedDescription)
        }
    }

    func signOutCloud() async {
        CloudSession.delete()
        await CloudClient.shared.reset()
        cloud = nil
        cloudHistory = [:]
        cloudError = nil
        if cloudMode { cloudMode = false; portfolio = nil; history = nil; watchlist = nil; status = nil }
        let _: CloudState? = try? await api.write("POST", "v1/cloud/sync")
        await loadStatus()
    }

    /// Blocks helper-only actions on a viewer Mac.
    private func viewOnly() -> Bool {
        if cloudMode { flash(Self.viewOnly) }
        return cloudMode
    }

    func loadWatchlist() async {
        if let w: WatchlistResponse = try? await api.get("v1/watchlist"), w != watchlist { watchlist = w }
    }

    // MARK: - 관심 종목

    func search(_ q: String) async -> [SearchResult] {
        if cloudMode { return [] }
        let r: SearchResponse? = try? await api.get("v1/search", query: ["q": q])
        return r?.results ?? []
    }

    func addWatch(_ symbol: String) async {
        if viewOnly() { return }
        do {
            let w: WatchlistResponse = try await api.write("POST", "v1/watchlist", body: ["symbol": symbol])
            watchlist = w
            flash("\(symbol) 관심 종목에 추가했어요")
        } catch {
            flash(error.localizedDescription)
        }
    }

    func removeWatch(_ symbol: String) async {
        if viewOnly() { return }
        if let w: WatchlistResponse = try? await api.write("DELETE", "v1/watchlist/\(symbol)") { watchlist = w }
    }

    /// Drag-and-drop reorder within one section (즐겨찾기 or the rest).
    func moveWatch(starred: Bool, from: IndexSet, to: Int) {
        if viewOnly() { return }
        guard var items = watchlist?.items else { return }
        var section = items.filter { $0.starred == starred }
        section.move(fromOffsets: from, toOffset: to)
        let rest = items.filter { $0.starred != starred }
        items = starred ? section + rest : rest + section
        watchlist?.items = items  // optimistic
        let order = items.map(\.symbol)
        Task {
            if let w: WatchlistResponse = try? await api.write("PUT", "v1/watchlist-order", body: ["symbols": order]) {
                watchlist = w
            }
        }
    }

    func setStar(_ symbol: String, _ starred: Bool) async {
        if viewOnly() { return }
        if let i = watchlist?.items.firstIndex(where: { $0.symbol == symbol }) {
            watchlist?.items[i].starred = starred  // optimistic
        }
        if let w: WatchlistResponse = try? await api.write("PUT", "v1/watchlist/\(symbol)", body: ["starred": starred]) {
            watchlist = w
        }
    }

    func chart(_ symbol: String, range: String) async throws -> PriceChart {
        if cloudMode { throw APIError.http(0, "보기 전용 Mac에서는 차트를 불러올 수 없어요") }
        return try await api.get("v1/chart", query: ["symbol": symbol, "range": range])
    }

    func loadStatus() async {
        if let s: HelperStatus = try? await api.get("v1/status"), s != status { status = s }
        await pushGoal()
    }

    func loadHistory() async {
        if !cloudMode, let h: History = try? await api.get("v1/history", query: ["range": historyRange]) {
            history = h
            return
        }
        guard cloudMode else { return }
        await loadCloudHistory()
        if let h = cloudHistory[historyRange], h != history { history = h }
    }

    // MARK: - Writes

    func updateSettings(_ patch: [String: Any]) async {
        if viewOnly() { return }
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
        if viewOnly() { return }
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
        if cloudMode {
            cloudFetchedAt = .distantPast
            cloudHistoryAt = .distantPast
            await loadFromCloud()
            await loadHistory()
            flash("클라우드에서 다시 받았어요")
            return
        }
        let _: [String: Bool]? = try? await api.write("POST", "v1/refresh")
        await loadPortfolio()
        flash("새로고침 요청했습니다")
    }

    /// 증권사 하나만 지금 다시 연결 (와이파이 ↔ 핫스팟 전환 직후 등).
    func retry(_ broker: String) async {
        guard !retrying.contains(broker), !viewOnly() else { return }
        retrying.insert(broker)
        retryResult[broker] = nil
        defer { retrying.remove(broker) }
        let r: RetryResult
        do {
            r = try await api.write("POST", "v1/refresh/\(broker)")
        } catch {
            r = RetryResult(ok: false, message: error.localizedDescription)
        }
        retryResult[broker] = r
        flash(r.message)
        await loadPortfolio()
        await loadStatus()
        Task {
            try? await Task.sleep(for: .seconds(8))
            if retryResult[broker] == r { retryResult[broker] = nil }
        }
    }

    // MARK: - IB Gateway

    /// ~/Applications/IB Gateway 10.xx/IB Gateway 10.xx.app (newest version wins).
    static func gatewayAppURL() -> URL? {
        let fm = FileManager.default
        let roots = [fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
                     URL(fileURLWithPath: "/Applications")]
        func isGateway(_ u: URL) -> Bool {
            u.pathExtension == "app" && u.lastPathComponent.hasPrefix("IB Gateway")
                && !u.lastPathComponent.contains("Uninstaller")
        }
        var found: [URL] = []
        for r in roots {
            for d in (try? fm.contentsOfDirectory(at: r, includingPropertiesForKeys: nil)) ?? []
            where d.lastPathComponent.hasPrefix("IB Gateway") {
                if isGateway(d) { found.append(d); continue }
                found += ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []).filter(isGateway)
            }
        }
        return found.max { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Open IB Gateway (login stays with the user), then wait up to 3 min for it to accept API connections.
    func launchGateway() async {
        guard !gatewayLaunching, !viewOnly() else { return }
        guard let url = Self.gatewayAppURL() else {
            flash("IB Gateway 앱을 찾을 수 없어요 (~/Applications)")
            return
        }
        gatewayLaunching = true
        defer { gatewayLaunching = false }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        } catch {
            flash("IB Gateway를 열 수 없어요: \(error.localizedDescription)")
            return
        }
        flash("IB Gateway를 열었어요 — 로그인하면 자동으로 연결돼요")
        for _ in 0..<36 {
            try? await Task.sleep(for: .seconds(5))
            let r: RetryResult? = try? await api.write("POST", "v1/refresh/ibkr?quick=true")
            if r?.ok == true {
                retryResult["ibkr"] = RetryResult(ok: true, message: "IB Gateway 연결됨")
                flash("IB Gateway 연결됨")
                await loadPortfolio()
                await loadStatus()
                try? await Task.sleep(for: .seconds(8))
                retryResult["ibkr"] = nil
                return
            }
        }
        flash("3분 안에 IB Gateway 연결이 안 됐어요 — 로그인 후 '다시 연결'을 눌러주세요")
    }

    /// IBKR Web API: start the local Client Portal Gateway, open its login page in the browser,
    /// then wait up to 5 min for the user to log in (IBKR app approval).
    func ibkrWebLogin() async {
        guard !gatewayLaunching, !viewOnly() else { return }
        gatewayLaunching = true
        defer { gatewayLaunching = false }
        struct Login: Decodable { let ok: Bool; let url: String; let message: String? }
        let r: Login
        do {
            r = try await api.write("POST", "v1/ibkr/web/login")
        } catch {
            flash("IBKR 웹 로그인을 시작할 수 없어요: \(error.localizedDescription)")
            return
        }
        guard r.ok, let url = URL(string: r.url) else {
            flash(r.message ?? "IBKR 웹 게이트웨이를 시작하지 못했어요")
            return
        }
        NSWorkspace.shared.open(url)
        flash("브라우저에서 IBKR에 로그인해주세요 — 로그인하면 자동으로 연결돼요")
        for _ in 0..<100 {
            try? await Task.sleep(for: .seconds(3))
            let res: RetryResult? = try? await api.write("POST", "v1/refresh/ibkr?quick=true")
            if res?.ok == true {
                retryResult["ibkr"] = RetryResult(ok: true, message: "IBKR 연결됨")
                flash("IBKR 실시간 연결됨")
                await loadPortfolio()
                await loadStatus()
                try? await Task.sleep(for: .seconds(8))
                retryResult["ibkr"] = nil
                return
            }
        }
        flash("5분 안에 IBKR 로그인이 확인되지 않았어요 — 다시 시도해주세요")
    }

    /// Background job (e.g. Flex report) just finished → show ✓/✗ briefly.
    private func noteFinishedWork(old: Portfolio?, new: Portfolio) {
        for b in new.brokers where b.busy == nil {
            guard let was = old?.brokers.first(where: { $0.id == b.id })?.busy else { continue }
            let failed = b.message?.contains("실패") == true
            let r = RetryResult(ok: !failed, message: failed ? (b.message ?? "\(was) 실패") : was.replacingOccurrences(of: "받는 중", with: "받음"))
            retryResult[b.id] = r
            Task {
                try? await Task.sleep(for: .seconds(8))
                if retryResult[b.id] == r { retryResult[b.id] = nil }
            }
        }
    }

    func runBackfill() async {
        if viewOnly() { return }
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
