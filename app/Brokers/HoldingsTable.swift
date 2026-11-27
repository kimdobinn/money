import SwiftUI

/// One row of the holdings table: a combined position, or (as a child) one broker's leg.
struct HoldingRow: Identifiable {
    let id: String
    let symbol: String
    let name: String
    let brokers: [String]
    let isLeg: Bool
    let currency: String
    let quantity: Double
    let avgCost: Double?
    let lastPrice: Double?
    let dayChangePct: Double?
    let marketValue: Double?
    let unrealizedPL: Double?
    let unrealizedPLPct: Double?
    let weight: Double?
    var krwNote: String? = nil
    var children: [HoldingRow]?

    // non-optional sort keys
    var sortValue: Double { marketValue ?? -.infinity }
    var sortPL: Double { unrealizedPL ?? -.infinity }
    var sortPLPct: Double { unrealizedPLPct ?? -.infinity }
    var sortDay: Double { dayChangePct ?? -.infinity }
    var sortWeight: Double { weight ?? -.infinity }

    static func from(_ p: Position) -> HoldingRow {
        let showLegs = p.legs.count > 1 || p.legs.contains { $0.avgCostKRW != nil && p.currency != "KRW" }
        let legs: [HoldingRow]? = showLegs ? p.legs.map { l in
            HoldingRow(
                id: p.id + "|" + l.broker, symbol: BrokerStyle.short(l.broker), name: "", brokers: [l.broker],
                isLeg: true, currency: p.currency, quantity: l.quantity, avgCost: l.avgCost, lastPrice: nil,
                dayChangePct: nil, marketValue: l.marketValue, unrealizedPL: l.unrealizedPL,
                unrealizedPLPct: (l.unrealizedPL != nil && l.costBasis > 0) ? l.unrealizedPL! / l.costBasis : nil,
                weight: nil,
                krwNote: (p.currency != "KRW" ? l.avgCostKRW : nil).map { avg in
                    "원화 평단 \(Fmt.amount(avg, currency: "KRW")) · 원화 손익 \(Fmt.amount(l.plKRW ?? 0, currency: "KRW", signed: true)) (\(Fmt.pct(l.plKRWPct)))"
                },
                children: nil
            )
        } : nil
        return HoldingRow(
            id: p.id, symbol: p.symbol, name: p.name, brokers: p.legs.map(\.broker), isLeg: false,
            currency: p.currency, quantity: p.quantity, avgCost: p.avgCost, lastPrice: p.lastPrice,
            dayChangePct: p.dayChangePct, marketValue: p.marketValue, unrealizedPL: p.unrealizedPL,
            unrealizedPLPct: p.unrealizedPLPct, weight: p.weight, children: legs
        )
    }
}

struct HoldingsCard: View {
    let positions: [Position]
    let colors: PLColors
    let money: Money
    @State private var sortOrder = [KeyPathComparator(\HoldingRow.sortValue, order: .reverse)]
    @State private var search = ""
    @State private var expanded: Set<String> = []

    var body: some View {
        let rows = positions
            .filter { search.isEmpty || $0.symbol.localizedCaseInsensitiveContains(search) || $0.name.localizedCaseInsensitiveContains(search) }
            .map(HoldingRow.from)
            .sorted(using: sortOrder)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("보유 종목").font(.s(.headline))
                Text("두 증권사 합산 · 행을 눌러 증권사별·원화 평단 보기").font(.s(.caption)).foregroundStyle(.secondary)
                Spacer()
                TextField("종목 검색", text: $search).textFieldStyle(.roundedBorder).frame(width: UIScale.pt(180))
            }
            Table(of: HoldingRow.self, sortOrder: $sortOrder) {
                TableColumn("종목", value: \.symbol) { r in
                    HStack(spacing: 6) {
                        if r.isLeg {
                            Circle().fill(BrokerStyle.color(r.brokers.first ?? "")).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(r.symbol).foregroundStyle(.secondary)
                                if let note = r.krwNote {
                                    Text(note).font(.s(.caption2)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .help(r.krwNote.map { $0 + "\n원화 평단 = 매수 시점 환율 기준 (토스 앱과 소폭 다를 수 있음)" } ?? "")
                        } else {
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(spacing: 4) {
                                    Text(r.symbol).fontWeight(.semibold)
                                    ForEach(r.brokers, id: \.self) { b in
                                        Text(BrokerStyle.short(b))
                                            .font(.system(size: UIScale.pt(9), weight: .medium))
                                            .padding(.horizontal, 4).padding(.vertical, 1)
                                            .background(BrokerStyle.color(b).opacity(0.2), in: Capsule())
                                    }
                                }
                                Text(r.name).font(.s(.caption)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .cell { toggle(r) }
                }
                .width(min: UIScale.pt(120), ideal: UIScale.pt(190))
                TableColumn("수량") { r in num(Fmt.qty(r.quantity)).cell { toggle(r) } }.width(min: UIScale.pt(44), ideal: UIScale.pt(60))
                TableColumn("평단가") { r in num(Fmt.price(r.avgCost, currency: r.currency)).cell { toggle(r) } }.width(min: UIScale.pt(66), ideal: UIScale.pt(84))
                TableColumn("현재가") { r in num(r.isLeg ? "" : Fmt.price(r.lastPrice, currency: r.currency)).cell { toggle(r) } }.width(min: UIScale.pt(66), ideal: UIScale.pt(84))
                TableColumn("오늘", value: \.sortDay) { r in
                    num(r.isLeg ? "" : Fmt.pct(r.dayChangePct)).foregroundStyle(colors.color(r.dayChangePct)).cell { toggle(r) }
                }.width(min: UIScale.pt(56), ideal: UIScale.pt(70))
                TableColumn("평가금액", value: \.sortValue) { r in
                    num(r.marketValue.map { Fmt.amount($0, currency: r.currency) } ?? "—").cell { toggle(r) }
                }.width(min: UIScale.pt(84), ideal: UIScale.pt(104))
                TableColumn("손익", value: \.sortPL) { r in
                    num(r.unrealizedPL.map { Fmt.amount($0, currency: r.currency, signed: true) } ?? "—")
                        .foregroundStyle(colors.color(r.unrealizedPL)).cell { toggle(r) }
                }.width(min: UIScale.pt(80), ideal: UIScale.pt(98))
                TableColumn("수익률", value: \.sortPLPct) { r in
                    num(Fmt.pct(r.unrealizedPLPct)).foregroundStyle(colors.color(r.unrealizedPLPct)).cell { toggle(r) }
                }.width(min: UIScale.pt(58), ideal: UIScale.pt(72))
                TableColumn("비중", value: \.sortWeight) { r in
                    Group {
                    if let w = r.weight {
                        HStack(spacing: 6) {
                            GeometryReader { g in
                                Capsule().fill(.quaternary)
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(Color.accentColor.opacity(0.7)).frame(width: g.size.width * min(1, w))
                                    }
                            }
                            .frame(height: 5)
                            Text(Fmt.pct(w, signed: false)).font(.s(.caption).monospacedDigit()).frame(width: UIScale.pt(46), alignment: .trailing)
                        }
                    }
                    }
                    .cell { toggle(r) }
                }.width(min: UIScale.pt(80), ideal: UIScale.pt(110))
            } rows: {
                ForEach(rows) { r in
                    if let kids = r.children {
                        DisclosureTableRow(r, isExpanded: Binding(
                            get: { expanded.contains(r.id) },
                            set: { if $0 { expanded.insert(r.id) } else { expanded.remove(r.id) } })) {
                            ForEach(kids) { TableRow($0) }
                        }
                    } else {
                        TableRow(r)
                    }
                }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: CGFloat(min(14, max(4, rows.count + 1))) * UIScale.pt(34) + 30)
        }
        .card()
    }

    /// Click anywhere on a stock row to open/close its broker breakdown (no row selection, so no blue flash).
    private func toggle(_ r: HoldingRow) {
        guard !r.isLeg, r.children != nil else { return }
        withAnimation(.smooth(duration: 0.25)) {
            if expanded.contains(r.id) { expanded.remove(r.id) } else { expanded.insert(r.id) }
        }
    }

    private func num(_ s: String) -> Text {
        Text(s).monospacedDigit()
    }
}

private extension View {
    /// Fills the whole table cell so a click anywhere in it registers, not just on the text.
    func cell(_ tap: @escaping () -> Void) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: tap)
    }
}
