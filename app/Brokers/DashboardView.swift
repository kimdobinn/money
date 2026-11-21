import Charts
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("dashboardTab") private var tab = "portfolio"

    var body: some View {
        Group {
            if tab == "watch" && model.helperReachable {
                WatchlistView()
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
                Picker("", selection: $tab) {
                    Label("포트폴리오", systemImage: "chart.pie").tag("portfolio")
                    Label("관심 종목", systemImage: "star").tag("watch")
                }
                .pickerStyle(.segmented).labelsHidden()
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
                Text("포트폴리오").font(.title2.weight(.semibold))
                HStack(spacing: 10) {
                    StatusDots(brokers: p.brokers, reachable: model.helperReachable)
                    Text("· 업데이트 \(Fmt.relative(model.lastUpdate))").font(.caption).foregroundStyle(.secondary)
                    if let usdsgd = p.fx.USDSGD, let usdkrw = p.fx.USDKRW {
                        Text(String(format: "· USD/SGD %.4f · USD/KRW %.1f", usdsgd, usdkrw))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            CurrencyPicker(selection: p.displayCurrency) { model.setDisplayCurrency($0) }
                .frame(width: 180)
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
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: big ? 26 : 21, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            Text(sub).font(.caption.monospacedDigit()).foregroundStyle(color == .primary ? .secondary : color)
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
    static let ranges = ["1D", "1W", "1M", "3M", "YTD", "1Y", "ALL"]

    var body: some View {
        let m = model.money
        let pts = (model.history?.points ?? []).filter { $0.valueUSD != nil }
        let hasCost = pts.contains { $0.costUSD != nil }
        let first = pts.first?.valueUSD ?? 0
        let last = pts.last?.valueUSD ?? 0
        let change = last - first
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("자산 추이").font(.headline)
                    if let sel = selected, let p = nearest(pts, sel) {
                        Text("\(p.t.formatted(date: .abbreviated, time: model.history?.intraday == true ? .shortened : .omitted)) · \(m.full(p.valueUSD ?? 0))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    } else if pts.count > 1 {
                        Text("기간 변동 \(m.full(change, signed: true)) (\(Fmt.pct(first > 0 ? change / first : nil)))")
                            .font(.caption.monospacedDigit()).foregroundStyle(model.colors.color(change))
                    }
                }
                Spacer()
                YScaleToggle(zeroBaseline: $zeroBaseline)
                Picker("", selection: $model.historyRange) {
                    ForEach(Self.ranges, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 330)
            }
            if pts.count < 2 {
                ContentUnavailableView(
                    "아직 기록이 없어요",
                    systemImage: "chart.xyaxis.line",
                    description: Text("헬퍼가 5분마다 기록합니다. 과거 거래내역 복원은 설정 > 히스토리에서 실행할 수 있어요.")
                )
                .frame(height: 260)
            } else {
                let values = pts.map { m.convert($0.valueUSD ?? 0) } + pts.compactMap { $0.costUSD.map(m.convert) }
                let lo = zeroBaseline ? 0 : (values.min() ?? 0) * 0.98
                let hi = (values.max() ?? 1) * (zeroBaseline ? 1.05 : 1.01)
                Chart {
                    ForEach(pts) { p in
                        AreaMark(x: .value("t", p.t), yStart: .value("lo", lo), yEnd: .value("평가", m.convert(p.valueUSD ?? 0)))
                            .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.25), .accentColor.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("t", p.t), y: .value("평가", m.convert(p.valueUSD ?? 0)), series: .value("s", "평가금액"))
                            .foregroundStyle(Color.accentColor)
                            .interpolationMethod(.monotone)
                        if hasCost, let c = p.costUSD {
                            LineMark(x: .value("t", p.t), y: .value("원금", m.convert(c)), series: .value("s", "투자원금"))
                                .foregroundStyle(.secondary)
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                    }
                    if let sel = selected, let p = nearest(pts, sel) {
                        RuleMark(x: .value("t", p.t)).foregroundStyle(.secondary.opacity(0.4))
                            .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                                HoverTag(
                                    title: p.t.formatted(date: .abbreviated, time: model.history?.intraday == true ? .shortened : .omitted),
                                    value: m.full(p.valueUSD ?? 0),
                                    lines: hoverLines(p, first: first, m: m)
                                )
                            }
                        PointMark(x: .value("t", p.t), y: .value("평가", m.convert(p.valueUSD ?? 0)))
                            .foregroundStyle(Color.accentColor)
                        if let c = p.costUSD {
                            PointMark(x: .value("t", p.t), y: .value("원금", m.convert(c)))
                                .foregroundStyle(.secondary).symbolSize(20)
                        }
                    }
                }
                .chartYScale(domain: lo...max(hi, lo + 1))
                .chartYAxis {
                    AxisMarks(position: .trailing) { v in
                        AxisGridLine()
                        AxisValueLabel { if let d = v.as(Double.self) { Text(compactAxis(d, m)) } }
                    }
                }
                .chartXSelection(value: $selected)
                .animation(.easeInOut(duration: 0.3), value: zeroBaseline)
                .frame(height: 260)
                if hasCost {
                    HStack(spacing: 14) {
                        Label("평가금액", systemImage: "line.diagonal").foregroundStyle(Color.accentColor)
                        Label("투자원금", systemImage: "line.diagonal").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
        }
        .card()
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

    private func compactAxis(_ v: Double, _ m: Money) -> String {
        if m.currency == .KRW { return String(format: "%.1f억", v / 1e8) }
        return v >= 1e6 ? String(format: "%.2fM", v / 1e6) : String(format: "%.0fK", v / 1e3)
    }
}

/// Floating value label shown above the hover cursor on charts.
struct HoverTag: View {
    let title: String
    let value: String
    var lines: [(String, String, Color)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
            ForEach(lines.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    Text(lines[i].0).foregroundStyle(.secondary)
                    Text(lines[i].1).foregroundStyle(lines[i].2).monospacedDigit()
                }
                .font(.caption2)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
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
            Text("종목 비중").font(.headline)
            HStack(spacing: 20) {
                Chart(slices) { s in
                    SectorMark(angle: .value("v", s.value), innerRadius: .ratio(0.62), angularInset: 1.2)
                        .foregroundStyle(by: .value("종목", s.id))
                        .opacity(hover == nil || hover == s.id ? 1 : 0.35)
                }
                .chartLegend(.hidden)
                .chartForegroundStyleScale(domain: slices.map(\.id), range: Array(Self.palette.prefix(slices.count)))
                .frame(width: 170, height: 170)
                .overlay {
                    VStack(spacing: 2) {
                        Text("\(positions.count)").font(.title2.weight(.semibold))
                        Text("종목").font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(slices.enumerated()), id: \.element.id) { i, s in
                        HStack {
                            Circle().fill(Self.palette[i % Self.palette.count]).frame(width: 8, height: 8)
                            Text(s.id).font(.callout.weight(.medium))
                            Spacer()
                            Text(money.compact(s.value)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            Text(Fmt.pct(s.weight, signed: false)).font(.callout.monospacedDigit()).frame(width: 60, alignment: .trailing)
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
    let brokers: [Broker]
    let money: Money
    let colors: PLColors

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("증권사별").font(.headline)
            BrokerSplitBar(brokers: brokers, money: money)
            ForEach(brokers) { b in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Circle().fill(BrokerStyle.color(b.id)).frame(width: 9, height: 9)
                        Text(b.name).font(.callout.weight(.semibold))
                        SourceBadge(broker: b)
                        Spacer()
                        Text(money.full(b.marketValueUSD + b.cashUSD)).font(.callout.monospacedDigit().weight(.medium))
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
                    if let msg = b.message {
                        Label(msg, systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
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
            Text(k).font(.caption2).foregroundStyle(.secondary)
            Text(v).font(.caption.monospacedDigit()).foregroundStyle(c)
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
                Text("원화 기준 손익").font(.caption).foregroundStyle(.secondary)
                Text("\(Fmt.amount(k.plKRW, currency: "KRW", signed: true)) (\(Fmt.pct(k.plPct)))")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(colors.color(k.plKRW))
                Image(systemName: "info.circle").font(.caption2).foregroundStyle(.tertiary)
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
            .font(.caption2.monospacedDigit())
        }
        .padding(.top, 2)
    }
}

struct SourceBadge: View {
    let broker: Broker
    var body: some View {
        let (text, color): (String, Color) = {
            switch broker.source {
            case "api", "gateway": return ("실시간", .green)
            case "flex": return ("전일 기준", .yellow)
            case "demo": return ("데모", .gray)
            default: return (broker.status == "error" ? "오류" : "연결 중", broker.status == "error" ? .red : .gray)
            }
        }()
        Text(text)
            .font(.caption2.weight(.medium))
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
