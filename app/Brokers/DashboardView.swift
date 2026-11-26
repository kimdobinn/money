import Charts
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("dashboardTab") private var tab = "portfolio"

    var body: some View {
        Group {
            if tab == "watch" && (model.helperReachable || model.cloudMode) {
                WatchlistView()
            } else if tab == "chat" && model.helperReachable {
                ChatView()
            } else if let p = model.portfolio {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if p.demo { DemoBanner() }
                        header(p)
                        KPIRow(p: p, money: model.money, colors: model.colors)
                        HistoryCard()
                        HStack(alignment: .top, spacing: 16) {
                            AllocationCard(positions: p.positions, money: model.money)
                            BrokersCard(brokers: p.brokers, money: model.money, colors: model.colors)
                        }
                        HoldingsCard(positions: p.positions, colors: model.colors, money: model.money)
                    }
                    .padding(20)
                }
            } else {
                HelperDownView().padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .principal) {
                TabSwitcher(selection: $tab, tabs: [
                    ("portfolio", "포트폴리오", "chart.pie.fill", "1"),
                    ("watch", "관심 종목", "star.fill", "2"),
                    ("chat", "어시스턴트", "bubble.left.and.text.bubble.right.fill", "3"),
                ])
            }
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.refreshNow() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("지금 새로고침")
            }
        }
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                Text(t).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: model.toast)
    }

    private func header(_ p: Portfolio) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("포트폴리오").font(.s(.title2).weight(.semibold))
                HStack(spacing: 10) {
                    StatusDots(brokers: p.brokers, reachable: model.helperReachable || model.cloudMode)
                    if model.cloudMode {
                        CloudSyncLabel().font(.s(.caption))
                    } else {
                        Text("· 업데이트 \(Fmt.relative(model.lastUpdate))").font(.s(.caption)).foregroundStyle(.secondary)
                    }
                    if let usdsgd = p.fx.USDSGD, let usdkrw = p.fx.USDKRW {
                        Text(String(format: "· USD/SGD %.4f · USD/KRW %.1f", usdsgd, usdkrw))
                            .font(.s(.caption).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            GoalBadge(portfolio: p)
                .padding(.trailing, 8)
            CurrencyPicker(selection: p.displayCurrency) { model.setDisplayCurrency($0) }
                .frame(width: UIScale.pt(180))
        }
    }
}

// MARK: - KPI

struct KPIRow: View {
    let p: Portfolio
    let money: Money
    let colors: PLColors

    var body: some View {
        let t = p.totals
        HStack(spacing: 12) {
            KPICard(title: "총자산", value: money.full(t.netWorthUSD), sub: "주식 + 현금", color: .primary, big: true)
            KPICard(title: "주식 평가금액", value: money.full(t.marketValueUSD), sub: "원금 \(money.full(t.costBasisUSD))", color: .primary)
            KPICard(title: "총 손익", value: money.full(t.unrealizedPLUSD, signed: true), sub: Fmt.pct(t.unrealizedPLPct), color: colors.color(t.unrealizedPLUSD))
            KPICard(title: "오늘 손익", value: money.full(t.dayPLUSD, signed: true), sub: Fmt.pct(t.dayPLPct), color: colors.color(t.dayPLUSD))
            KPICard(title: "현금", value: money.full(t.cashUSD), sub: "\(Int((t.cashUSD / max(1, t.netWorthUSD)) * 100))% 비중", color: .primary)
        }
    }
}

struct KPICard: View {
    let title: String
    let value: String
    let sub: String
    let color: Color
    var big = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.s(.subheadline)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: UIScale.pt(big ? 26 : 21), weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            Text(sub).font(.s(.caption).monospacedDigit()).foregroundStyle(color == .primary ? .secondary : color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

// MARK: - History chart

struct HistoryCard: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: Date?
    /// Shared by every value chart: false = zoom to the data range, true = Y axis starts at 0 (scale-correct).
    @AppStorage("chartZeroBaseline") private var zeroBaseline = false
    /// "value" = 평가금액, "profit" = 투자수익 only (평가금액 − 순투입액).
    @AppStorage("historyMode") private var mode = "value"
    static let ranges = ["1D", "1W", "1M", "3M", "YTD", "1Y", "ALL"]

    var body: some View {
        let m = model.money
        let pts = (model.history?.points ?? []).filter { $0.valueUSD != nil }
        let canProfit = pts.contains { $0.investedUSD != nil }
        let profit = canProfit && mode == "profit"
        let hasCost = !profit && pts.contains { $0.costUSD != nil }
        let first = pts.first.map { y($0, profit) } ?? 0
        let last = pts.last.map { y($0, profit) } ?? 0
        let change = last - first
        let timeStyle: Date.FormatStyle.TimeStyle = model.history?.intraday == true ? .shortened : .omitted
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profit ? "투자 수익 추이" : "자산 추이").font(.s(.headline))
                    if let sel = selected, let p = nearest(pts, sel) {
                        Text("\(p.t.formatted(date: .abbreviated, time: timeStyle)) · \(m.full(y(p, profit), signed: profit))")
                            .font(.s(.caption).monospacedDigit()).foregroundStyle(.secondary)
                    } else if pts.count > 1 {
                        if profit {
                            HStack(spacing: 10) {
                                Text("기간 수익 \(m.full(change, signed: true))").foregroundStyle(model.colors.color(change))
                                Text("누적 \(m.full(last, signed: true))").foregroundStyle(.secondary)
                            }
                            .font(.s(.caption).monospacedDigit())
                        } else {
                            Text("기간 변동 \(m.full(change, signed: true)) (\(Fmt.pct(first > 0 ? change / first : nil)))")
                                .font(.s(.caption).monospacedDigit()).foregroundStyle(model.colors.color(change))
                        }
                    }
                }
                Spacer()
                if canProfit {
                    Picker("", selection: $mode) {
                        Text("자산").tag("value")
                        Text("수익").tag("profit")
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .help("자산 = 주식 평가금액 · 수익 = 평가금액 − 순투입액 (새로 넣은 돈을 빼고 투자로 번 돈만)")
                }
                YScaleToggle(zeroBaseline: $zeroBaseline)
                Picker("", selection: $model.historyRange) {
                    ForEach(Self.ranges, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: UIScale.pt(330))
            }
            if pts.count < 2 {
                ContentUnavailableView(
                    "아직 기록이 없어요",
                    systemImage: "chart.xyaxis.line",
                    description: Text("헬퍼가 5분마다 기록합니다. 과거 거래내역 복원은 설정 > 히스토리에서 실행할 수 있어요.")
                )
                .frame(height: 260)
            } else {
                let values = pts.map { m.convert(y($0, profit)) } + (hasCost ? pts.compactMap { $0.costUSD.map(m.convert) } : [])
                let vmin = values.min() ?? 0, vmax = values.max() ?? 1
                let pad = max((vmax - vmin) * 0.04, abs(vmax) * 0.005, 1)
                let lo = profit
                    ? (zeroBaseline ? min(0, vmin) - pad : vmin - pad)
                    : (zeroBaseline ? 0 : vmin * 0.98)
                let hi = profit
                    ? (zeroBaseline ? max(0, vmax) + pad : vmax + pad)
                    : vmax * (zeroBaseline ? 1.05 : 1.01)
                let base = profit ? min(max(0, lo), hi) : lo
                let lineColor = profit ? model.colors.color(last) : Color.accentColor
                Chart {
                    ForEach(pts) { p in
                        AreaMark(x: .value("t", p.t), yStart: .value("lo", base), yEnd: .value("v", m.convert(y(p, profit))))
                            .foregroundStyle(.linearGradient(colors: [lineColor.opacity(0.22), lineColor.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("t", p.t), y: .value("v", m.convert(y(p, profit))), series: .value("s", "main"))
                            .foregroundStyle(lineColor)
                            .interpolationMethod(.monotone)
                        if hasCost, let c = p.costUSD {
                            LineMark(x: .value("t", p.t), y: .value("원금", m.convert(c)), series: .value("s", "투자원금"))
                                .foregroundStyle(.secondary)
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                    }
                    if profit && lo < 0 && hi > 0 {
                        RuleMark(y: .value("0", 0))
                            .foregroundStyle(.secondary.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    if let sel = selected, let p = nearest(pts, sel) {
                        RuleMark(x: .value("t", p.t)).foregroundStyle(.secondary.opacity(0.4))
                            .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                                HoverTag(
                                    title: p.t.formatted(date: .abbreviated, time: timeStyle),
                                    value: m.full(y(p, profit), signed: profit),
                                    lines: profit ? profitLines(p, first: first, m: m) : hoverLines(p, first: first, m: m)
                                )
                            }
                        PointMark(x: .value("t", p.t), y: .value("v", m.convert(y(p, profit))))
                            .foregroundStyle(lineColor)
                        if hasCost, let c = p.costUSD {
                            PointMark(x: .value("t", p.t), y: .value("원금", m.convert(c)))
                                .foregroundStyle(.secondary).symbolSize(20)
                        }
                    }
                }
                .chartYScale(domain: lo...max(hi, lo + 1))
                .chartYAxis {
                    AxisMarks(position: .trailing) { v in
                        AxisGridLine()
                        AxisValueLabel { if let d = v.as(Double.self) { Text(compactAxis(d, m, span: hi - lo)) } }
                    }
                }
                .chartXSelection(value: $selected)
                .animation(.easeInOut(duration: 0.3), value: zeroBaseline)
                .animation(.easeInOut(duration: 0.3), value: profit)
                .frame(height: 260)
                .padding(.top, HoverTag.reserve)
                if profit {
                    Text("투자 수익 = 주식 평가금액 − 순투입액(매수 − 매도 금액). 실현손익 포함 · 입금·예수금·배당 제외")
                        .font(.s(.caption)).foregroundStyle(.secondary)
                } else if hasCost {
                    HStack(spacing: 14) {
                        Label("평가금액", systemImage: "line.diagonal").foregroundStyle(Color.accentColor)
                        Label("투자원금", systemImage: "line.diagonal").foregroundStyle(.secondary)
                    }
                    .font(.s(.caption))
                }
            }
        }
        .card()
    }

    /// Charted value: 평가금액, or 투자수익 (평가금액 − 순투입액).
    private func y(_ p: HistoryPoint, _ profit: Bool) -> Double {
        let v = p.valueUSD ?? 0
        return profit ? v - (p.investedUSD ?? v) : v
    }

    private func profitLines(_ p: HistoryPoint, first: Double, m: Money) -> [(String, String, Color)] {
        let d = y(p, true) - first
        var out: [(String, String, Color)] = [("기간 시작 대비", m.full(d, signed: true), model.colors.color(d))]
        out.append(("평가금액", m.full(p.valueUSD ?? 0), .secondary))
        if let inv = p.investedUSD { out.append(("순투입", m.full(inv), .secondary)) }
        return out
    }

    private func hoverLines(_ p: HistoryPoint, first: Double, m: Money) -> [(String, String, Color)] {
        var out: [(String, String, Color)] = []
        let v = p.valueUSD ?? 0
        if first > 0 {
            let d = v - first
            out.append(("기간 시작 대비", "\(m.full(d, signed: true)) (\(Fmt.pct(d / first)))", model.colors.color(d)))
        }
        if let c = p.costUSD, c > 0 {
            out.append(("투자원금", m.full(c), .secondary))
            out.append(("손익", "\(m.full(v - c, signed: true)) (\(Fmt.pct((v - c) / c)))", model.colors.color(v - c)))
        }
        return out
    }

    private func nearest(_ pts: [HistoryPoint], _ d: Date) -> HistoryPoint? {
        pts.min { abs($0.t.timeIntervalSince(d)) < abs($1.t.timeIntervalSince(d)) }
    }

    /// Axis labels with just enough decimals that neighbouring ticks never read the same
    /// (e.g. KRW 1,700만 / 1,750만 instead of 0.2억 / 0.2억).
    private func compactAxis(_ v: Double, _ m: Money, span: Double) -> String {
        let step = max(span / 5, 1e-9)  // ≈ tick spacing
        func fmt(_ x: Double, unit: Double, suffix: String, prefix: String = "") -> String {
            let digits = min(3, max(0, Int(ceil(-log10(step / unit)))))
            let nf = NumberFormatter()
            nf.numberStyle = .decimal
            nf.minimumFractionDigits = digits
            nf.maximumFractionDigits = digits
            return prefix + (nf.string(from: NSNumber(value: x / unit)) ?? "\(x / unit)") + suffix
        }
        let top = abs(v) + span
        if m.currency == .KRW {
            return top >= 1e8 && step >= 1e7 ? fmt(v, unit: 1e8, suffix: "억") : fmt(v, unit: 1e4, suffix: "만")
        }
        if top >= 1e6 { return fmt(v, unit: 1e6, suffix: "M") }
        if top >= 1e4 { return fmt(v, unit: 1e3, suffix: "K") }
        return fmt(v, unit: 1, suffix: "")
    }
}

/// Large labeled tabs for the window toolbar (icon + title, ⌘1 / ⌘2).
struct TabSwitcher: View {
    @Binding var selection: String
    let tabs: [(id: String, title: String, icon: String, key: Character)]
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.id) { t in
                let on = selection == t.id
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = t.id }
                } label: {
                    Label(t.title, systemImage: t.icon)
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: UIScale.pt(13), weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.white : Color.primary.opacity(0.75))
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        .frame(minWidth: UIScale.pt(120))
                        .background {
                            if on {
                                Capsule().fill(Color.accentColor).matchedGeometryEffect(id: "tab", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(t.key), modifiers: .command)
                .help("\(t.title) (⌘\(t.key))")
            }
        }
        .padding(3)
        .background(Capsule().fill(.quaternary.opacity(0.7)))
    }
}

/// Floating value label shown above the hover cursor on charts.
struct HoverTag: View {
    let title: String
    let value: String
    var lines: [(String, String, Color)] = []

    /// Height reserved above a chart's plot area so the tag never covers the line.
    static var reserve: CGFloat { UIScale.pt(44) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value).font(.s(.callout).weight(.semibold)).monospacedDigit()
                Text(title).font(.s(.caption2)).foregroundStyle(.secondary)
            }
            if !lines.isEmpty {
                HStack(spacing: 10) {
                    ForEach(lines.indices, id: \.self) { i in
                        HStack(spacing: 4) {
                            Text(lines[i].0).foregroundStyle(.secondary)
                            Text(lines[i].1).foregroundStyle(lines[i].2).monospacedDigit()
                        }
                    }
                }
                .font(.s(.caption2))
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary))
        .fixedSize()
    }
}

/// Y-axis mode switch for value charts: zoomed (default) vs. starting at 0.
struct YScaleToggle: View {
    @Binding var zeroBaseline: Bool

    var body: some View {
        Picker("", selection: $zeroBaseline) {
            Text("확대").tag(false)
            Text("0부터").tag(true)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .help("세로축: 확대 = 변동이 잘 보이게 데이터 범위에 맞춤 · 0부터 = 0에서 시작해 실제 비율대로 표시")
    }
}

// MARK: - Allocation

struct AllocationCard: View {
    let positions: [Position]
    let money: Money
    @State private var hover: String?

    struct Slice: Identifiable {
        let id: String
        let value: Double
        let weight: Double
    }

    var body: some View {
        let top = positions.prefix(7).map { Slice(id: $0.symbol, value: $0.marketValueUSD ?? 0, weight: $0.weight) }
        let rest = positions.dropFirst(7)
        let slices = top + (rest.isEmpty ? [] : [Slice(id: "기타", value: rest.reduce(0) { $0 + ($1.marketValueUSD ?? 0) }, weight: rest.reduce(0) { $0 + $1.weight })])
        VStack(alignment: .leading, spacing: 12) {
            Text("종목 비중").font(.s(.headline))
            HStack(spacing: 20) {
                Chart(slices) { s in
                    SectorMark(angle: .value("v", s.value), innerRadius: .ratio(0.62), angularInset: 1.2)
                        .foregroundStyle(by: .value("종목", s.id))
                        .opacity(hover == nil || hover == s.id ? 1 : 0.35)
                }
                .chartLegend(.hidden)
                .chartForegroundStyleScale(domain: slices.map(\.id), range: Array(Self.palette.prefix(slices.count)))
                .frame(width: UIScale.pt(170), height: 170)
                .overlay {
                    VStack(spacing: 2) {
                        Text("\(positions.count)").font(.s(.title2).weight(.semibold))
                        Text("종목").font(.s(.caption)).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(slices.enumerated()), id: \.element.id) { i, s in
                        HStack {
                            Circle().fill(Self.palette[i % Self.palette.count]).frame(width: 8, height: 8)
                            Text(s.id).font(.s(.callout).weight(.medium))
                            Spacer()
                            Text(money.compact(s.value)).font(.s(.callout).monospacedDigit()).foregroundStyle(.secondary)
                            Text(Fmt.pct(s.weight, signed: false)).font(.s(.callout).monospacedDigit()).frame(width: UIScale.pt(60), alignment: .trailing)
                        }
                        .contentShape(Rectangle())
                        .onHover { hover = $0 ? s.id : nil }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    static let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .mint, .gray]
}

// MARK: - Brokers

struct BrokersCard: View {
    @EnvironmentObject var model: AppModel
    let brokers: [Broker]
    let money: Money
    let colors: PLColors

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("증권사별").font(.s(.headline))
            BrokerSplitBar(brokers: brokers, money: money)
            ForEach(brokers) { b in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Circle().fill(BrokerStyle.color(b.id)).frame(width: 9, height: 9)
                        Text(b.name).font(.s(.callout).weight(.semibold))
                        SourceBadge(broker: b)
                        if !model.cloudMode {
                            RetryButton(broker: b)
                            if b.id == "ibkr" && !b.isLive && b.source != "demo" {
                                GatewayLaunchButton()
                            }
                        }
                        Spacer()
                        Text(money.full(b.marketValueUSD + b.cashUSD)).font(.s(.callout).monospacedDigit().weight(.medium))
                    }
                    HStack(spacing: 14) {
                        stat("주식", money.full(b.marketValueUSD))
                        stat("현금", money.full(b.cashUSD))
                        stat("손익", money.full(b.marketValueUSD - b.costBasisUSD, signed: true), colors.color(b.marketValueUSD - b.costBasisUSD))
                        stat("오늘", money.full(b.dayPLUSD, signed: true), colors.color(b.dayPLUSD))
                    }
                    if let k = b.krw {
                        KRWBreakdown(k: k, colors: colors)
                    }
                    if let busy = b.busy {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 12, height: 12)
                            Text(busy + "…")
                        }
                        .font(.s(.caption)).foregroundStyle(.secondary)
                    }
                    if let r = model.retryResult[b.id] {
                        Label(r.message, systemImage: r.ok ? "checkmark.circle" : "xmark.circle")
                            .font(.s(.caption)).foregroundStyle(r.ok ? .green : .red)
                    } else if b.cached == true {
                        TimelineView(.periodic(from: .now, by: 30)) { _ in
                            Label("Last fetched \(Fmt.stamp(b.asOf)) · \(Fmt.relative(b.asOf))", systemImage: "clock")
                                .font(.s(.caption)).foregroundStyle(.secondary)
                        }
                        .help(b.message.map { "연결 안 됨: \($0)" } ?? "연결 안 됨 — 마지막으로 받은 보유내역을 표시 중")
                    } else if let msg = b.message {
                        Label(msg, systemImage: "info.circle").font(.s(.caption)).foregroundStyle(.orange)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func stat(_ k: String, _ v: String, _ c: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.s(.caption2)).foregroundStyle(.secondary)
            Text(v).font(.s(.caption).monospacedDigit()).foregroundStyle(c)
        }
    }
}

/// 원화 기준 손익 = 주가 손익 + 환차손익.
struct KRWBreakdown: View {
    let k: KRWSummary
    let colors: PLColors

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("원화 기준 손익").font(.s(.caption)).foregroundStyle(.secondary)
                Text("\(Fmt.amount(k.plKRW, currency: "KRW", signed: true)) (\(Fmt.pct(k.plPct)))")
                    .font(.s(.caption).monospacedDigit().weight(.semibold))
                    .foregroundStyle(colors.color(k.plKRW))
                Image(systemName: "info.circle").font(.s(.caption2)).foregroundStyle(.tertiary)
                    .help("매수 당시 환율로 계산한 원화 원금 \(Fmt.amount(k.costKRW, currency: "KRW")) 대비 현재 원화 평가금액 \(Fmt.amount(k.valueKRW, currency: "KRW")).\n토스 앱은 평가 환율이 조금 달라 수치가 소폭 다를 수 있어요.")
            }
            GeometryReader { geo in
                let total = max(1, abs(k.pricePLKRW) + abs(k.fxPLKRW))
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2).fill(colors.color(k.pricePLKRW).opacity(0.75))
                        .frame(width: max(2, geo.size.width * abs(k.pricePLKRW) / total))
                    RoundedRectangle(cornerRadius: 2).fill(colors.color(k.fxPLKRW).opacity(0.35))
                        .frame(width: max(2, geo.size.width * abs(k.fxPLKRW) / total))
                }
            }
            .frame(height: 5)
            HStack(spacing: 14) {
                Text("주가 \(Fmt.amount(k.pricePLKRW, currency: "KRW", signed: true))")
                    .foregroundStyle(colors.color(k.pricePLKRW))
                Text("환율 \(Fmt.amount(k.fxPLKRW, currency: "KRW", signed: true))")
                    .foregroundStyle(colors.color(k.fxPLKRW))
            }
            .font(.s(.caption2).monospacedDigit())
        }
        .padding(.top, 2)
    }
}

/// 증권사 하나만 지금 다시 연결.
struct RetryButton: View {
    @EnvironmentObject var model: AppModel
    let broker: Broker

    var body: some View {
        let busy = model.retrying.contains(broker.id)
        Button { Task { await model.retry(broker.id) } } label: {
            HStack(spacing: 4) {
                if busy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                Text(busy ? "연결 중…" : "다시 연결")
            }
            .font(.s(.caption2))
        }
        .buttonStyle(.borderless)
        .disabled(busy || broker.source == "demo")
        .help("\(broker.name)에 지금 다시 연결하고 보유내역을 새로 받아와요 (와이파이 ↔ 핫스팟 전환 후 등)")
    }
}

/// IBKR live connection: web login (Client Portal Gateway, works on any network) when installed,
/// otherwise open the IB Gateway app. Login itself always stays with the user.
struct GatewayLaunchButton: View {
    @EnvironmentObject var model: AppModel
    var compact = false

    var body: some View {
        let web = model.status?.connectors.webapi?.available == true
        Button { Task { web ? await model.ibkrWebLogin() : await model.launchGateway() } } label: {
            HStack(spacing: 4) {
                if model.gatewayLaunching {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: web ? "person.badge.key" : "power")
                }
                if !compact { Text(model.gatewayLaunching ? "로그인 대기 중…" : (web ? "IBKR 로그인" : "Gateway 켜기")) }
            }
            .font(.s(.caption2))
        }
        .buttonStyle(.borderless)
        .disabled(model.gatewayLaunching)
        .help(web
              ? "브라우저에서 IBKR에 로그인하면 실시간으로 연결돼요 — 학교 와이파이에서도 돼요 (최대 5분 대기)"
              : "IB Gateway 앱을 열어요. 로그인하면 자동으로 연결돼요 (최대 3분 대기)")
        .contextMenu {
            if web { Button("IB Gateway 앱으로 연결") { Task { await model.launchGateway() } } }
        }
    }
}

struct SourceBadge: View {
    let broker: Broker
    var body: some View {
        let (text, color): (String, Color) = {
            if broker.cached == true { return ("연결 안 됨", .orange) }
            switch broker.source {
            case "api", "gateway", "webapi": return ("실시간", .green)
            case "flex": return ("전일 기준", .yellow)
            case "demo": return ("데모", .gray)
            default: return (broker.status == "error" ? "오류" : "연결 중", broker.status == "error" ? .red : .gray)
            }
        }()
        Text(text)
            .font(.s(.caption2).weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .help(StatusDots.describe(broker))
    }
}

extension View {
    func card() -> some View {
        padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5)))
    }
}
