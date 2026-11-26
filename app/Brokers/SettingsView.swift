import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            AccountsTab().tabItem { Label("계정 연결", systemImage: "link") }
            DisplayTab().tabItem { Label("표시", systemImage: "paintbrush") }
            HistoryTab().tabItem { Label("히스토리", systemImage: "clock.arrow.circlepath") }
            CloudTab().tabItem { Label("동기화", systemImage: "icloud") }
        }
        .frame(width: 620)
        .padding(.vertical, 8)
        .task { await model.loadStatus() }
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                Text(t).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule()).padding(.bottom, 10)
            }
        }
    }
}

// MARK: - Accounts

struct AccountsTab: View {
    @EnvironmentObject var model: AppModel
    @State private var tossId = ""
    @State private var tossSecret = ""
    @State private var flexToken = ""
    @State private var flexQuery = ""
    @State private var gwHost = "127.0.0.1"
    @State private var gwPort = "4001"
    @State private var gwClient = "77"
    @State private var loaded = false

    var body: some View {
        let s = model.status
        Form {
            Section {
                ConnectorHeader(title: "토스증권", status: s?.connectors.toss.status ?? "disabled",
                                message: s?.connectors.toss.message)
                TextField("Client ID", text: $tossId, prompt: Text(saved(s, "tossClientId")))
                SecureField("Client Secret", text: $tossSecret, prompt: Text(saved(s, "tossClientSecret")))
                HStack {
                    if let ip = s?.publicIP {
                        Text("현재 공인 IP").foregroundStyle(.secondary)
                        Text(ip).monospaced().textSelection(.enabled)
                        Button("복사") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(ip, forType: .string)
                            model.flash("IP 복사됨 — 토스 WTS 허용 IP에 등록하세요")
                        }
                        .controlSize(.small)
                        if s?.connectors.toss.ipBlocked == true {
                            Label("미등록", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Button("저장") {
                        var v: [String: String] = [:]
                        if !tossId.isEmpty { v["tossClientId"] = tossId }
                        if !tossSecret.isEmpty { v["tossClientSecret"] = tossSecret }
                        guard !v.isEmpty else { return }
                        Task { await model.saveSecrets(v); tossId = ""; tossSecret = "" }
                    }
                    .keyboardShortcut(.defaultAction)
                }
                Text("토스증권 웹(WTS) > 설정 > Open API 에서 발급하고, 같은 화면의 '허용 IP 관리'에 위 IP를 등록하세요. 키는 macOS Keychain에만 저장됩니다.")
                    .font(.s(.caption)).foregroundStyle(.secondary)
            }

            Section {
                ConnectorHeader(
                    title: "IBKR · IB Gateway (실시간)",
                    status: s?.connectors.gateway.connected == true ? "ok" : (s?.connectors.gateway.enabled == true ? "connecting" : "disabled"),
                    message: s?.connectors.gateway.connected == true ? nil : s?.connectors.gateway.message
                )
                Toggle("Gateway 사용", isOn: Binding(
                    get: { s?.settings.ibkr.gatewayEnabled ?? true },
                    set: { v in Task { await model.updateSettings(["ibkr": ["gatewayEnabled": v]]) } }
                ))
                HStack {
                    TextField("호스트", text: $gwHost).frame(maxWidth: 180)
                    TextField("포트", text: $gwPort).frame(maxWidth: 110)
                    TextField("Client ID", text: $gwClient).frame(maxWidth: 130)
                    Spacer()
                    Button("적용") {
                        Task {
                            await model.updateSettings(["ibkr": [
                                "host": gwHost, "port": Int(gwPort) ?? 4001, "clientId": Int(gwClient) ?? 77,
                            ]])
                        }
                    }
                }
                Text("IB Gateway 설정 > API > Settings 에서 'Enable ActiveX and Socket Clients' 켜기, 'Read-Only API' 켜기, 포트 4001(실계좌). 헬퍼는 읽기 전용으로만 접속합니다.")
                    .font(.s(.caption)).foregroundStyle(.secondary)
            }

            Section {
                ConnectorHeader(
                    title: "IBKR · Flex 리포트 (백업 + 거래내역)",
                    status: s?.connectors.flex.configured == true ? (s?.connectors.flex.message == nil ? "ok" : "error") : "disabled",
                    message: s?.connectors.flex.message
                        ?? s?.connectors.flex.fetchedAt.map { "마지막 수신 \(Fmt.relative($0))" }
                )
                SecureField("Flex Token", text: $flexToken, prompt: Text(saved(s, "ibkrFlexToken")))
                HStack {
                    TextField("Query ID", text: $flexQuery)
                    Spacer()
                    Button("저장") {
                        Task {
                            if !flexQuery.isEmpty { await model.updateSettings(["ibkr": ["flexQueryId": flexQuery]]) }
                            if !flexToken.isEmpty { await model.saveSecrets(["ibkrFlexToken": flexToken]); flexToken = "" }
                        }
                    }
                }
                Text("IBKR 포털 > Performance & Reports > Flex Queries 에서 Activity Flex Query(Open Positions, Cash Report, Trades, 기간 Last 365 Days)를 만들고, Flex Web Service에서 토큰을 발급하세요.")
                    .font(.s(.caption)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: model.status) { _, _ in load() }
    }

    private func load() {
        guard !loaded, let ib = model.status?.settings.ibkr else { return }
        gwHost = ib.host; gwPort = String(ib.port); gwClient = String(ib.clientId); flexQuery = ib.flexQueryId
        loaded = true
    }

    private func saved(_ s: HelperStatus?, _ key: String) -> String {
        s?.secrets[key] == true ? "•••••• 저장됨 (변경하려면 입력)" : "입력"
    }
}

struct ConnectorHeader: View {
    let title: String
    let status: String
    let message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.s(.headline))
                Spacer()
                Circle().fill(StatusDots.color(status)).frame(width: 8, height: 8)
                Text(label).font(.s(.caption)).foregroundStyle(.secondary)
            }
            if let message { Text(message).font(.s(.caption)).foregroundStyle(.orange) }
        }
    }

    private var label: String {
        switch status {
        case "ok": return "연결됨"
        case "stale": return "지연"
        case "connecting": return "연결 대기"
        case "error": return "오류"
        default: return "미설정"
        }
    }
}

// MARK: - Display

struct DisplayTab: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(UIScale.key) private var fontScale = 1.0

    var body: some View {
        let s = model.status?.settings
        Form {
            Picker("글자 크기", selection: $fontScale) {
                ForEach(UIScale.steps, id: \.0) { v, name in
                    Text("\(name) (\(Int(v * 100))%)").tag(v)
                }
            }
            .help("대시보드·메뉴바 창의 글자 크기. 단축키 ⌘+ / ⌘- / ⌘0")
            Picker("표시 통화", selection: bind(s?.displayCurrency ?? "SGD", key: "displayCurrency")) {
                Text("SGD (S$)").tag("SGD"); Text("USD ($)").tag("USD"); Text("KRW (₩)").tag("KRW")
            }
            Picker("메뉴바 표시", selection: bind(s?.menuBarStyle ?? "both", key: "menuBarStyle")) {
                Text("총자산 + 오늘 등락").tag("both"); Text("총자산만").tag("total"); Text("오늘 등락만").tag("day")
            }
            Picker("상승/하락 색상", selection: bind(s?.colorStyle ?? "kr", key: "colorStyle")) {
                Text("한국식 (상승 빨강 · 하락 파랑)").tag("kr"); Text("미국식 (상승 초록 · 하락 빨강)").tag("us")
            }
            Picker("데모 데이터", selection: bind(s?.demoMode ?? "auto", key: "demoMode")) {
                Text("자동 (계정 연결 전까지)").tag("auto"); Text("항상 켜기").tag("on"); Text("끄기").tag("off")
            }
            Toggle("로그인 시 자동 실행", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
        }
        .formStyle(.grouped)
    }

    private func bind(_ value: String, key: String) -> Binding<String> {
        Binding(get: { value }, set: { v in Task { await model.updateSettings([key: v]) } })
    }
}

// MARK: - History

struct HistoryTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let b = model.status?.backfill
        Form {
            Section("과거 히스토리 복원") {
                Text("토스 거래내역과 IBKR Flex 거래내역, 과거 일별 종가로 계좌 개설 이후의 자산 추이를 다시 계산합니다. 계정을 처음 연결하면 자동으로 한 번 실행됩니다.")
                    .font(.s(.callout)).foregroundStyle(.secondary)
                HStack {
                    if b?.running == true { ProgressView().controlSize(.small) }
                    Text(b?.message ?? "아직 실행하지 않음").font(.s(.callout))
                    Spacer()
                    Button("지금 다시 복원") { Task { await model.runBackfill() } }
                        .disabled(b?.running == true || model.status?.demo == true)
                }
                if let last = b?.lastRun { Text("마지막 실행 \(Fmt.relative(last))").font(.s(.caption)).foregroundStyle(.secondary) }
            }
            Section("진단") {
                Button("헬퍼 로그 열기") {
                    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Brokers/brokerd.log")
                    NSWorkspace.shared.open(url)
                }
                Button("데이터 폴더 열기") {
                    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Brokers")
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .formStyle(.grouped)
    }
}
