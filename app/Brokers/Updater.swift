import AppKit
import SwiftUI

/// Self-updater backed by GitHub Releases (kimdobinn/money).
///
/// Each release carries two assets with fixed names, so the "latest" URLs never change and no
/// GitHub API call (rate-limited per IP) is needed:
///   latest.json  {"version": "1.2.0", "notes": "..."}
///   money.zip    the signed money.app
/// A download is only installed if it is signed by the same Apple team as the running app.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    static let base = URL(string: "https://github.com/kimdobinn/money/releases/latest/download/")!
    static let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    struct Latest: Decodable, Equatable {
        var version: String
        var notes: String?
    }

    enum Phase: Equatable { case idle, checking, downloading, installing, failed(String) }

    @Published var latest: Latest?
    @Published var phase: Phase = .idle
    @Published var lastCheck: Date?
    @AppStorage("autoCheckUpdates") var autoCheck = true

    var available: Bool { latest.map { Self.newer($0.version, than: Self.current) } ?? false }

    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in if Updater.shared.autoCheck { await Updater.shared.check() } }
        }
    }

    func check() async {
        guard phase != .downloading, phase != .installing else { return }
        phase = .checking
        defer { if phase == .checking { phase = .idle } }
        var req = URLRequest(url: Self.base.appendingPathComponent("latest.json"))
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 20
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            latest = try JSONDecoder().decode(Latest.self, from: data)
            lastCheck = Date()
        } catch {
            phase = .failed("업데이트 확인 실패: \(error.localizedDescription)")
        }
    }

    /// Downloads money.zip, verifies the signature, swaps the bundle in place and relaunches.
    func install() async {
        guard available, phase != .downloading, phase != .installing else { return }
        phase = .downloading
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("money-update-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let (tmp, resp) = try await URLSession.shared.download(from: Self.base.appendingPathComponent("money.zip"))
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("다운로드 실패") }
            let zip = work.appendingPathComponent("money.zip")
            try fm.moveItem(at: tmp, to: zip)
            phase = .installing
            try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
            let new = work.appendingPathComponent("money.app")
            guard fm.fileExists(atPath: new.path) else { throw UpdateError("압축 안에 money.app이 없어요") }
            try await Self.verify(new)
            try Self.relaunch(replacing: Bundle.main.bundleURL, with: new)
        } catch {
            phase = .failed((error as? UpdateError)?.message ?? error.localizedDescription)
        }
    }

    // MARK: - helpers

    struct UpdateError: Error { let message: String; init(_ m: String) { message = m } }

    /// "1.10.0" > "1.9.2"
    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    private static func teamID(_ url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func verify(_ new: URL) async throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(new as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate), nil) == errSecSuccess
        else { throw UpdateError("새 버전의 서명이 올바르지 않아요 — 설치하지 않았어요") }
        guard let mine = teamID(Bundle.main.bundleURL), teamID(new) == mine else {
            throw UpdateError("새 버전이 같은 개발자 서명이 아니에요 — 설치하지 않았어요")
        }
    }

    private static func run(_ tool: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.terminationHandler = { p in
                p.terminationStatus == 0 ? cont.resume() : cont.resume(throwing: UpdateError("\(tool) 실패 (\(p.terminationStatus))"))
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    /// A detached shell waits for this process to exit, swaps the bundle, and opens the new one.
    private static func relaunch(replacing old: URL, with new: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "$1.old" && mv "$1" "$1.old" && /usr/bin/ditto "$2" "$1" && rm -rf "$1.old" || { rm -rf "$1"; mv "$1.old" "$1"; }
        /usr/bin/open "$1"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", script, "updater", old.path, new.path]
        try p.run()
        NSApp.terminate(nil)
    }
}

/// Settings > 업데이트 section, also used compactly in the menu bar popover.
struct UpdateSection: View {
    @ObservedObject var updater = Updater.shared

    var body: some View {
        Section("앱 업데이트") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("현재 버전 \(Updater.current)")
                    status.font(.s(.caption)).foregroundStyle(.secondary)
                }
                Spacer()
                if updater.phase == .checking || updater.phase == .downloading || updater.phase == .installing {
                    ProgressView().controlSize(.small)
                }
                if updater.available {
                    Button("v\(updater.latest!.version) 설치") { Task { await updater.install() } }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("지금 확인") { Task { await updater.check() } }
                }
            }
            if updater.available, let notes = updater.latest?.notes, !notes.isEmpty {
                Text(notes).font(.s(.caption)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Toggle("자동으로 업데이트 확인 (6시간마다)", isOn: $updater.autoCheck)
        }
    }

    @ViewBuilder private var status: some View {
        switch updater.phase {
        case .checking: Text("확인 중…")
        case .downloading: Text("다운로드 중…")
        case .installing: Text("설치 중… 앱이 다시 시작돼요")
        case .failed(let m): Text(m).foregroundStyle(.orange)
        case .idle:
            if updater.available { Text("새 버전 v\(updater.latest!.version)이 있어요") }
            else if let t = updater.lastCheck { Text("최신 버전이에요 · \(Fmt.relative(t)) 확인") }
            else { Text("아직 확인하지 않음") }
        }
    }
}

/// Small pill shown in the popover footer / dashboard when an update is ready.
struct UpdatePill: View {
    @ObservedObject var updater = Updater.shared

    var body: some View {
        if updater.available, let v = updater.latest?.version {
            Button {
                Task { await updater.install() }
            } label: {
                Label(updater.phase == .downloading || updater.phase == .installing ? "업데이트 중…" : "v\(v) 업데이트",
                      systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.accentColor)
            .help(updater.latest?.notes ?? "새 버전 설치 후 다시 시작")
        }
    }
}
