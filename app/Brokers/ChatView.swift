import SwiftUI

// MARK: - Model

struct ChatConversation: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var created: Int
    var updated: Int
}

struct ChatMessage: Codable, Identifiable, Equatable {
    var id: Int
    var role: String
    var text: String
    var tools: [String]
    var ts: Int
}

struct ChatMemory: Codable, Identifiable, Equatable {
    var id: Int
    var text: String
    var created: Int
    var updated: Int
}

private struct ChatEvent: Decodable {
    var type: String
    var delta: String?
    var name: String?
    var label: String?
    var conversationId: String?
    var title: String?
    var message: String?
}

@MainActor
final class ChatModel: ObservableObject {
    @Published var conversations: [ChatConversation] = []
    @Published var currentId: String?
    @Published var messages: [ChatMessage] = []
    @Published var memories: [ChatMemory] = []
    @Published var streaming = false
    @Published var streamText = ""
    @Published var streamTools: [String] = []
    @Published var error: String?
    @Published var claudeAvailable = true

    private let api = APIClient()
    private var task: Task<Void, Never>?

    func load() async {
        struct Convs: Decodable { var conversations: [ChatConversation] }
        struct Status: Decodable { var claude: Bool }
        if let s: Status = try? await api.get("v1/chat/status") { claudeAvailable = s.claude }
        if let c: Convs = try? await api.get("v1/chat/conversations") { conversations = c.conversations }
        await loadMemories()
    }

    func loadMemories() async {
        struct Mems: Decodable { var memories: [ChatMemory] }
        if let m: Mems = try? await api.get("v1/chat/memory") { memories = m.memories }
    }

    func open(_ id: String?) async {
        guard !streaming else { return }
        currentId = id
        error = nil
        guard let id else { messages = []; return }
        struct Conv: Decodable { var messages: [ChatMessage] }
        if let c: Conv = try? await api.get("v1/chat/conversations/\(id)") { messages = c.messages }
    }

    func delete(_ id: String) async {
        let _: EmptyOK? = try? await api.write("DELETE", "v1/chat/conversations/\(id)")
        if currentId == id { currentId = nil; messages = [] }
        await load()
    }

    func deleteMemory(_ id: Int) async {
        let _: EmptyOK? = try? await api.write("DELETE", "v1/chat/memory/\(id)")
        await loadMemories()
    }

    func stop() { task?.cancel() }

    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !streaming else { return }
        error = nil
        messages.append(ChatMessage(id: -Int.random(in: 1...1_000_000), role: "user", text: text, tools: [], ts: Int(Date().timeIntervalSince1970)))
        streaming = true
        streamText = ""
        streamTools = []
        task = Task { await self.stream(text) }
    }

    private func goalContext() -> [String: Any]? {
        let d = UserDefaults.standard
        guard d.bool(forKey: Goal.enabledKey), d.double(forKey: Goal.amountKey) > 0 else { return nil }
        return ["name": d.string(forKey: Goal.nameKey) ?? "", "amount": d.double(forKey: Goal.amountKey),
                "currency": d.string(forKey: Goal.currencyKey) ?? "USD"]
    }

    private func stream(_ text: String) async {
        defer {
            streaming = false
            task = nil
        }
        var req = URLRequest(url: APIClient.base.appendingPathComponent("v1/chat"))
        req.httpMethod = "POST"
        req.timeoutInterval = 900
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let tok = APIClient.writeToken() { req.setValue(tok, forHTTPHeaderField: "X-Brokers-Token") }
        var body: [String: Any] = ["message": text, "model": UserDefaults.standard.string(forKey: "chatModel") ?? "sonnet"]
        if let id = currentId { body["conversationId"] = id }
        if let g = goalContext() { body["goal"] = g }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                error = "헬퍼 오류 \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
                return
            }
            for try await line in bytes.lines {
                guard let ev = try? JSONDecoder().decode(ChatEvent.self, from: Data(line.utf8)) else { continue }
                switch ev.type {
                case "start":
                    if currentId == nil, let id = ev.conversationId {
                        currentId = id
                        conversations.insert(ChatConversation(id: id, title: ev.title ?? "", created: 0, updated: Int(Date().timeIntervalSince1970)), at: 0)
                    }
                case "text": streamText += ev.delta ?? ""
                case "tool": if let l = ev.label { streamTools.append(l) }
                case "error": error = ev.message ?? "오류"
                default: break
                }
            }
        } catch is CancellationError {
        } catch let e as URLError where e.code == .cancelled {
        } catch {
            self.error = error.localizedDescription
        }
        let reply = streamText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reply.isEmpty {
            messages.append(ChatMessage(id: -Int.random(in: 1...1_000_000), role: "assistant", text: reply, tools: Array(NSOrderedSet(array: streamTools)) as? [String] ?? streamTools, ts: Int(Date().timeIntervalSince1970)))
        }
        streamText = ""
        streamTools = []
        await load()
    }
}

// MARK: - Views

struct ChatView: View {
    @StateObject private var chat = ChatModel()
    @State private var input = ""
    @State private var showMemory = false
    @AppStorage("chatModel") private var modelChoice = "sonnet"
    @FocusState private var inputFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 230)
            Divider()
            VStack(spacing: 0) {
                transcript
                Divider()
                composer
            }
        }
        .task { await chat.load() }
        .sheet(isPresented: $showMemory) { MemorySheet(chat: chat) }
    }

    // sidebar: conversations + memory
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                Task { await chat.open(nil) }
                inputFocused = true
            } label: {
                Label("새 대화", systemImage: "square.and.pencil").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(12)
            .disabled(chat.streaming)
            .keyboardShortcut("n", modifiers: .command)

            List(selection: Binding(get: { chat.currentId }, set: { id in Task { await chat.open(id) } })) {
                ForEach(chat.conversations) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title.isEmpty ? "새 대화" : c.title).lineLimit(1).font(.s(.callout))
                        Text(Fmt.relative(Date(timeIntervalSince1970: TimeInterval(c.updated))))
                            .font(.s(.caption2)).foregroundStyle(.secondary)
                    }
                    .tag(c.id as String?)
                    .contextMenu {
                        Button("대화 삭제", role: .destructive) { Task { await chat.delete(c.id) } }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            Button { showMemory = true } label: {
                HStack {
                    Image(systemName: "brain")
                    Text("기억")
                    Spacer()
                    Text("\(chat.memories.count)").foregroundStyle(.secondary).monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(12)
            .help("대화에서 기억한 내용 — 모든 대화에서 사용돼요")
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if chat.messages.isEmpty && !chat.streaming {
                        EmptyChat(available: chat.claudeAvailable) { q in chat.send(q) }
                    }
                    ForEach(chat.messages) { m in
                        MessageRow(message: m)
                    }
                    if chat.streaming {
                        StreamingRow(text: chat.streamText, tools: chat.streamTools)
                    }
                    if let e = chat.error {
                        Label(e, systemImage: "exclamationmark.triangle").font(.s(.callout)).foregroundStyle(.red)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 28).padding(.vertical, 20)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: chat.messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: chat.streamText) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.currentId) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Picker("", selection: $modelChoice) {
                Text("Haiku").tag("haiku")
                Text("Sonnet").tag("sonnet")
                Text("Opus").tag("opus")
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .padding(.bottom, 6)
            .help("모델 — Haiku: 가장 빠름 · Sonnet: 기본 · Opus: 복잡한 분석용 (Max 사용량을 더 씀)")
            TextField("포트폴리오에 대해 물어보세요…", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.s(.body))
                .lineLimit(1...8)
                .focused($inputFocused)
                .onSubmit(submit)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            if chat.streaming {
                Button { chat.stop() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 26)) }
                    .buttonStyle(.plain).help("답변 중지")
            } else {
                Button(action: submit) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 26)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : Color.accentColor)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("보내기 (Return) · 줄바꿈 (⌥Return)")
            }
        }
        .padding(14)
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity)
        .onAppear { inputFocused = true }
    }

    private func submit() {
        let t = input
        guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !chat.streaming else { return }
        input = ""
        chat.send(t)
    }
}

private struct EmptyChat: View {
    let available: Bool
    let ask: (String) -> Void
    private let suggestions = [
        "내 포트폴리오 요약해줘",
        "이번 달 수익률이랑 손익 원인 알려줘",
        "레버리지 ETF 비중이 너무 높은지 봐줘",
        "QLD 매수 내역 정리해줘",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("money 어시스턴트").font(.s(.title2).weight(.semibold))
            Text("토스·IBKR 보유 종목, 거래 내역, 자산 추이를 직접 확인하고 답해요. 알려준 목표나 성향은 기억해두고 다음 대화에서도 써요.")
                .font(.s(.callout)).foregroundStyle(.secondary)
            if !available {
                Label("Claude Code CLI(claude)를 찾을 수 없어요. 설치하고 터미널에서 `claude`로 로그인해주세요.", systemImage: "exclamationmark.triangle")
                    .font(.s(.callout)).foregroundStyle(.orange)
            }
            FlowRow(items: suggestions) { s in
                Button(s) { ask(s) }.buttonStyle(.bordered).controlSize(.regular)
            }
        }
        .padding(.top, 40)
    }
}

private struct FlowRow<Content: View>: View {
    let items: [String]
    let content: (String) -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(stride(from: 0, to: items.count, by: 2).map { $0 }, id: \.self) { i in
                HStack(spacing: 8) {
                    ForEach(items[i..<min(i + 2, items.count)], id: \.self) { content($0) }
                }
            }
        }
    }
}

private struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 80)
                Text(message.text)
                    .font(.s(.body))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if !message.tools.isEmpty {
                    ToolChips(tools: Array(NSOrderedSet(array: message.tools)) as? [String] ?? message.tools, live: false)
                }
                MarkdownText(text: message.text)
            }
        }
    }
}

private struct StreamingRow: View {
    let text: String
    let tools: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !tools.isEmpty {
                ToolChips(tools: Array(NSOrderedSet(array: tools)) as? [String] ?? tools, live: text.isEmpty)
            }
            if text.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(tools.last.map { "\($0) 중…" } ?? "생각 중…").font(.s(.callout)).foregroundStyle(.secondary)
                }
            } else {
                MarkdownText(text: text)
                ProgressView().controlSize(.mini)
            }
        }
    }
}

private struct ToolChips: View {
    let tools: [String]
    let live: Bool
    var body: some View {
        HStack(spacing: 6) {
            ForEach(tools, id: \.self) { t in
                Label(t, systemImage: t.contains("기억") ? "brain" : t.contains("웹") ? "globe" : "chart.bar.doc.horizontal")
                    .font(.s(.caption2))
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct MemorySheet: View {
    @ObservedObject var chat: ChatModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("기억").font(.s(.title3).weight(.semibold))
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("대화 중에 어시스턴트가 저장한 내용이에요. 모든 새 대화에서 참고해요. 바꾸고 싶으면 채팅으로 말하거나 여기서 지우세요.")
                .font(.s(.caption)).foregroundStyle(.secondary)
            if chat.memories.isEmpty {
                Text("아직 기억한 내용이 없어요.").foregroundStyle(.secondary).padding(.vertical, 20)
            } else {
                List {
                    ForEach(chat.memories) { m in
                        HStack(alignment: .top) {
                            Text(m.text).textSelection(.enabled)
                            Spacer()
                            Button(role: .destructive) { Task { await chat.deleteMemory(m.id) } } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("이 기억 삭제")
                        }
                    }
                }
                .frame(minHeight: 260)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await chat.loadMemories() }
    }
}

// MARK: - Minimal markdown (paragraphs, headings, lists, tables, code blocks)

struct MarkdownText: View {
    let text: String

    private enum Block: Hashable {
        case heading(Int, String)
        case paragraph(String)
        case bullet(String, Int)
        case numbered(String, String)
        case table([[String]])
        case code(String)
        case rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                view(b)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(_ b: Block) -> some View {
        switch b {
        case let .heading(level, s):
            inline(s).font(.s(level <= 2 ? .title3 : .headline).weight(.semibold)).padding(.top, 4)
        case let .paragraph(s):
            inline(s).font(.s(.body)).fixedSize(horizontal: false, vertical: true)
        case let .bullet(s, indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                inline(s).font(.s(.body)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case let .numbered(n, s):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(n).foregroundStyle(.secondary).monospacedDigit()
                inline(s).font(.s(.body)).fixedSize(horizontal: false, vertical: true)
            }
        case let .table(rows):
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    GridRow {
                        ForEach(Array(r.enumerated()), id: \.offset) { _, c in
                            inline(c).font(.s(.callout).monospacedDigit().weight(i == 0 ? .semibold : .regular))
                        }
                    }
                    if i == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        case let .code(s):
            Text(s).font(.system(.callout, design: .monospaced))
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        case .rule:
            Divider()
        }
    }

    private func inline(_ s: String) -> Text {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let a = try? AttributedString(markdown: s, options: opts) { return Text(a) }
        return Text(s)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var para: [String] = []
        var table: [[String]] = []
        var code: [String]? = nil
        func flushPara() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] }
        }
        func flushTable() {
            if !table.isEmpty { out.append(.table(table)); table = [] }
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { flushPara(); flushTable(); code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if line.hasPrefix("|") {
                flushPara()
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-:".contains($0) } }) { continue }
                table.append(cells)
                continue
            }
            flushTable()
            if line.isEmpty { flushPara(); continue }
            if line == "---" || line == "***" { flushPara(); out.append(.rule); continue }
            if let m = line.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
                flushPara(); out.append(.heading(m.1.count, String(m.2))); continue
            }
            if let m = raw.firstMatch(of: /^(\s*)[-*•]\s+(.*)$/) {
                flushPara(); out.append(.bullet(String(m.2), m.1.count / 2)); continue
            }
            if let m = line.firstMatch(of: /^(\d+[.)])\s+(.*)$/) {
                flushPara(); out.append(.numbered(String(m.1), String(m.2))); continue
            }
            para.append(line)
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flushPara()
        flushTable()
        return out
    }
}
