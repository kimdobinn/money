import Charts
import SwiftUI

/// 관심 종목: searchable watchlist on the left, price chart of the selected symbol on the right.
struct WatchlistView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("watchSelected") private var selected = ""
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: UIScale.pt(340))
            Divider()
            Group {
                if let item = model.watchlist?.items.first(where: { $0.symbol == selected }) {
                    SymbolDetailView(item: item).id(item.symbol)
                } else if model.watchlist?.available == false {
                    ContentUnavailableView("토스 계정 연결이 필요해요", systemImage: "link",
                                           description: Text("관심 종목 시세와 차트는 토스 Open API로 가져와요."))
                } else {
                    ContentUnavailableView("종목을 선택하세요", systemImage: "chart.xyaxis.line",
                                           description: Text("왼쪽 목록에서 종목을 고르면 가격 추이를 보여드려요."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: selectFirstIfNeeded)
        .onChange(of: model.watchlist?.items.map(\.symbol)) { selectFirstIfNeeded() }
    }

    private func selectFirstIfNeeded() {
        guard let items = model.watchlist?.items, !items.isEmpty else { return }
        if !items.contains(where: { $0.symbol == selected }) { selected = items[0].symbol }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("종목 추가 — 티커·이름 검색 (QQQ, 애플, Nvidia)", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let r = results.first { pick(r) } }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .padding(10)
            .task(id: query) {
                let q = query.trimmingCharacters(in: .whitespaces)
                guard !q.isEmpty else { results = []; return }
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                results = await model.search(q)
            }
            Divider()
            if !query.isEmpty {
                searchResults
            } else {
                watchList
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    private var searchResults: some View {
        List {
            if results.isEmpty {
                Text(model.watchlist?.searchReady == false ? "종목 목록을 준비 중이에요…" : "검색 결과가 없어요")
                    .foregroundStyle(.secondary)
            }
            ForEach(results) { r in
                Button { pick(r) } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(r.symbol).fontWeight(.semibold)
                                if r.isETF { Badge("ETF", .purple) }
                                Badge(r.exchange ?? r.market, .gray)
                            }
                            Text([r.name, r.englishName].compactMap { $0 }.filter { $0 != r.symbol }.joined(separator: " · "))
                                .font(.s(.caption)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: r.watched ? "checkmark.circle.fill" : "plus.circle")
                            .foregroundStyle(r.watched ? Color.green : Color.accentColor)
                            .font(.s(.title3))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
    }

    private func pick(_ r: SearchResult) {
        Task {
            if !r.watched { await model.addWatch(r.symbol) }
            selected = r.symbol
            query = ""
            searchFocused = false
        }
    }

    @ViewBuilder
    private var watchList: some View {
        let items = model.watchlist?.items ?? []
        if items.isEmpty {
            ContentUnavailableView {
                Label("관심 종목이 없어요", systemImage: "star")
            } description: {
                Text("위 검색창에서 ETF·주식을 찾아 추가하고 ☆로 즐겨찾기 하세요.")
            }
            .frame(maxHeight: .infinity)
        } else {
            let starred = items.filter(\.starred)
            let others = items.filter { !$0.starred }
            List(selection: Binding(get: { selected }, set: { if let s = $0 { selected = s } })) {
                if !starred.isEmpty {
                    Section("즐겨찾기") {
                        ForEach(starred) { row($0) }
                            .onMove { model.moveWatch(starred: true, from: $0, to: $1) }
                    }
                }
                if !others.isEmpty {
                    Section(starred.isEmpty ? "관심 종목" : "그 외") {
                        ForEach(others) { row($0) }
                            .onMove { model.moveWatch(starred: false, from: $0, to: $1) }
                    }
                }
            }
            .listStyle(.sidebar)
            .onDeleteCommand { Task { await model.removeWatch(selected) } }
        }
    }

    private func row(_ it: WatchItem) -> some View {
        WatchRow(item: it, colors: model.colors) { Task { await model.setStar(it.symbol, !it.starred) } }
            .tag(it.symbol)
            .contextMenu {
                Button(it.starred ? "즐겨찾기 해제" : "즐겨찾기") { Task { await model.setStar(it.symbol, !it.starred) } }
                Divider()
                Button("관심 종목에서 삭제", role: .destructive) { Task { await model.removeWatch(it.symbol) } }
            }
    }
}

struct WatchRow: View {
    let item: WatchItem
    let colors: PLColors
    let toggleStar: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            DragHandle()
            Button(action: toggleStar) {
                Image(systemName: item.starred ? "star.fill" : "star")
                    .foregroundStyle(item.starred ? Color.yellow : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(item.starred ? "즐겨찾기 해제" : "즐겨찾기 (메뉴 막대에도 표시)")
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(item.symbol).fontWeight(.semibold)
                    if item.isETF { Badge("ETF", .purple) }
                    if item.held != nil { Badge("보유", .blue) }
                }
                Text(item.displayName).font(.s(.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Sparkline(values: item.spark + (item.price.map { [$0] } ?? []), color: colors.color(item.changePct))
                .frame(width: UIScale.pt(54), height: 22)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Fmt.price(item.price, currency: item.ccy)).monospacedDigit()
                Text(Fmt.pct(item.changePct)).font(.s(.caption)).monospacedDigit()
                    .foregroundStyle(colors.color(item.changePct))
            }
            .frame(minWidth: UIScale.pt(70), alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}

/// ≡ grip shown at the left of each row; the whole row is draggable, this makes it discoverable.
struct DragHandle: View {
    @State private var hover = false

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.s(.callout))
            .foregroundStyle(hover ? Color.secondary : Color.secondary.opacity(0.45))
            .frame(width: 14)
            .contentShape(Rectangle())
            .onHover { inside in
                hover = inside
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .help("드래그해서 순서 바꾸기")
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        if values.count > 1, let lo = values.min(), let hi = values.max() {
            Chart(Array(values.enumerated()), id: \.offset) { i, v in
                LineMark(x: .value("i", i), y: .value("v", v))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.2))
            }
            .foregroundStyle(color)
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .chartYScale(domain: lo...max(hi, lo + 0.0001))
        } else {
            Color.clear
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color
    init(_ text: String, _ color: Color) { self.text = text; self.color = color }

    var body: some View {
        Text(text)
            .font(.system(size: UIScale.pt(9), weight: .medium))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
    }
}

// MARK: - Detail

struct SymbolDetailView: View {
    @EnvironmentObject var model: AppModel
    let item: WatchItem
    @AppStorage("watchRange") private var range = "1Y"
    @AppStorage("chartZeroBaseline") private var zeroBaseline = false
    @State private var chart: PriceChart?
    @State private var error: String?
    @State private var loading = false
    @State private var selected: Date?
    static let ranges = ["1D", "1W", "1M", "3M", "YTD", "1Y", "5Y", "ALL"]

    var body: some View {
        let pts = livePoints
        let first = pts.first?.price ?? 0
        let last = item.price ?? pts.last?.price ?? 0
        let base = range == "1D" ? (chart?.prevClose ?? first) : first
        let change = last - base
        let c = model.colors
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(last: last)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rangeTitle).font(.s(.headline))
                            if base > 0 {
                                Text("\(Fmt.amount(change, currency: item.ccy, signed: true)) (\(Fmt.pct(change / base)))")
                                    .font(.s(.caption).monospacedDigit()).foregroundStyle(c.color(change))
                            }
                        }
                        Spacer()
                        if loading { ProgressView().controlSize(.small) }
                        YScaleToggle(zeroBaseline: $zeroBaseline)
                        Picker("", selection: $range) {
                            ForEach(Self.ranges, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: UIScale.pt(380))
                    }
                    chartView(pts, base: base, color: c.color(change) == .secondary ? .accentColor : c.color(change))
                        .frame(height: 320)
                        .padding(.top, HoverTag.reserve)
                    stats(pts, last: last, base: base)
                }
                .card()
            }
            .padding(20)
        }
        .task(id: range) { await reloadLoop() }
    }

    private var rangeTitle: String {
        switch range {
        case "1D": return "오늘"
        case "1W": return "최근 1주"
        case "1M": return "최근 1개월"
        case "3M": return "최근 3개월"
        case "YTD": return "올해"
        case "1Y": return "최근 1년"
        case "5Y": return "최근 5년"
        default: return "상장 이후 전체"
        }
    }

    private func reloadLoop() async {
        selected = nil
        if chart?.range != range { chart = nil }
        while !Task.isCancelled {
            loading = true
            do {
                chart = try await model.chart(item.symbol, range: range)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
            try? await Task.sleep(for: .seconds(range == "1D" ? 30 : range == "1W" ? 120 : 600))
        }
    }

    /// Chart points plus the live quote, so the line moves in real time between reloads.
    private var livePoints: [PricePoint] {
        guard var pts = chart?.points, chart?.range == range, let last = pts.last else { return chart?.points ?? [] }
        guard let px = item.price, let ts = item.priceTime else { return pts }
        if chart?.intraday == true {
            if ts > last.t { pts.append(PricePoint(t: ts, price: px)) }
        } else {
            let tz = TimeZone(identifier: item.market == "KR" ? "Asia/Seoul" : "America/New_York")!
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = tz
            let qd = cal.dateComponents([.year, .month, .day], from: ts)
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            let ld = utc.dateComponents([.year, .month, .day], from: last.t)
            if qd == ld {
                pts[pts.count - 1].price = px
            } else if ts > last.t {
                let day = utc.date(from: DateComponents(year: qd.year, month: qd.month, day: qd.day, hour: 12)) ?? ts
                pts.append(PricePoint(t: day, price: px))
            }
        }
        return pts
    }

    private func header(last: Double) -> some View {
        let c = model.colors
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.displayName).font(.s(.title2).weight(.semibold))
                    Button { Task { await model.setStar(item.symbol, !item.starred) } } label: {
                        Image(systemName: item.starred ? "star.fill" : "star")
                            .foregroundStyle(item.starred ? Color.yellow : Color.secondary)
                            .font(.s(.title3))
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 6) {
                    Text(item.symbol).font(.s(.callout).weight(.medium))
                    if let en = item.englishName, en != item.displayName {
                        Text(en).font(.s(.callout)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if item.isETF { Badge("ETF", .purple) }
                    if let ex = item.exchange { Badge(ex, .gray) }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.price(last, currency: item.ccy))
                    .font(.system(size: UIScale.pt(28), weight: .semibold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText()).animation(.default, value: last)
                HStack(spacing: 6) {
                    Text("오늘").foregroundStyle(.secondary)
                    Text("\(Fmt.amount(item.change ?? 0, currency: item.ccy, signed: true)) (\(Fmt.pct(item.changePct)))")
                        .foregroundStyle(c.color(item.changePct))
                }
                .font(.s(.callout).monospacedDigit())
                Text("실시간 · \(Fmt.relative(item.priceTime))").font(.s(.caption2)).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func chartView(_ pts: [PricePoint], base: Double, color: Color) -> some View {
        if pts.count < 2 {
            Group {
                if let error {
                    ContentUnavailableView("차트를 불러오지 못했어요", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView("차트 불러오는 중…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let prices = pts.map(\.price) + [item.held?.avgCost, range == "1D" ? chart?.prevClose : nil].compactMap { $0 }
            let lo = zeroBaseline ? 0 : (prices.min() ?? 0) * 0.98
            let hi = (prices.max() ?? 1) * (zeroBaseline ? 1.05 : 1.02)
            let intraday = chart?.intraday == true
            Chart {
                ForEach(pts) { p in
                    AreaMark(x: .value("t", p.t), yStart: .value("lo", lo), yEnd: .value("가격", p.price))
                        .foregroundStyle(.linearGradient(colors: [color.opacity(0.22), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("t", p.t), y: .value("가격", p.price))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 1.6))
                }
                if range == "1D", let pc = chart?.prevClose {
                    RuleMark(y: .value("전일 종가", pc))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .bottom, alignment: .leading) {
                            Text("전일 종가 \(Fmt.price(pc, currency: item.ccy))").font(.s(.caption2)).foregroundStyle(.secondary)
                        }
                }
                if let avg = item.held?.avgCost {
                    RuleMark(y: .value("내 평단", avg))
                        .foregroundStyle(Color.orange.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("내 평단 \(Fmt.price(avg, currency: item.ccy))").font(.s(.caption2)).foregroundStyle(.orange)
                        }
                }
                if let sel = selected, let p = nearest(pts, sel) {
                    RuleMark(x: .value("t", p.t)).foregroundStyle(.secondary.opacity(0.4))
                        .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            HoverTag(
                                title: p.t.formatted(date: .abbreviated, time: intraday ? .shortened : .omitted),
                                value: Fmt.price(p.price, currency: item.ccy),
                                lines: hoverLines(p, base: base)
                            )
                        }
                    PointMark(x: .value("t", p.t), y: .value("가격", p.price)).foregroundStyle(color)
                }
            }
            .chartYScale(domain: lo...max(hi, lo + 0.01))
            .chartYAxis { AxisMarks(position: .trailing) }
            .chartXSelection(value: $selected)
            .animation(.easeInOut(duration: 0.3), value: zeroBaseline)
        }
    }

    private func hoverLines(_ p: PricePoint, base: Double) -> [(String, String, Color)] {
        let c = model.colors
        var out: [(String, String, Color)] = []
        if base > 0 {
            let d = p.price - base
            out.append((range == "1D" ? "전일 대비" : "기간 시작 대비", Fmt.pct(d / base), c.color(d)))
        }
        if let cur = item.price, p.price > 0 {
            let d = cur - p.price
            out.append(("현재가까지", Fmt.pct(d / p.price), c.color(d)))
        }
        if let avg = item.held?.avgCost, avg > 0 {
            let d = p.price - avg
            out.append(("내 평단 대비", Fmt.pct(d / avg), c.color(d)))
        }
        return out
    }

    private func stats(_ pts: [PricePoint], last: Double, base: Double) -> some View {
        let c = model.colors
        let hi = pts.max { $0.price < $1.price }
        let lo = pts.min { $0.price < $1.price }
        return HStack(spacing: 24) {
            stat("기간 최고", hi.map { Fmt.price($0.price, currency: item.ccy) } ?? "—",
                 hi.map { $0.t.formatted(date: .abbreviated, time: .omitted) })
            stat("기간 최저", lo.map { Fmt.price($0.price, currency: item.ccy) } ?? "—",
                 lo.map { $0.t.formatted(date: .abbreviated, time: .omitted) })
            if let h = hi, h.price > 0 {
                stat("최고가 대비", Fmt.pct((last - h.price) / h.price), nil, color: c.color(last - h.price))
            }
            if let held = item.held {
                let pl = (last - held.avgCost) * held.quantity
                stat("보유", "\(Fmt.qty(held.quantity))주 · 평단 \(Fmt.price(held.avgCost, currency: item.ccy))",
                     "평가손익 \(Fmt.amount(pl, currency: item.ccy, signed: true)) (\(Fmt.pct(held.avgCost > 0 ? (last - held.avgCost) / held.avgCost : nil)))",
                     subColor: c.color(pl))
            }
            Spacer()
        }
    }

    private func stat(_ title: String, _ value: String, _ sub: String?, color: Color = .primary, subColor: Color = .secondary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.s(.caption)).foregroundStyle(.secondary)
            Text(value).font(.s(.callout).weight(.medium)).monospacedDigit().foregroundStyle(color)
            if let sub { Text(sub).font(.s(.caption2)).monospacedDigit().foregroundStyle(subColor) }
        }
    }

    private func nearest(_ pts: [PricePoint], _ d: Date) -> PricePoint? {
        // points are sorted by time: binary search instead of a linear scan (ALL ranges have ~1500 points)
        var lo = 0, hi = pts.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if pts[mid].t < d { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(pts[lo - 1].t.timeIntervalSince(d)) < abs(pts[lo].t.timeIntervalSince(d)) { return pts[lo - 1] }
        return pts.indices.contains(lo) ? pts[lo] : nil
    }
}
