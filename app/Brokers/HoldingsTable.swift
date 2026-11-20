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

    var body: some View {
        let rows = positions
            .filter { search.isEmpty || $0.symbol.localizedCaseInsensitiveContains(search) || $0.name.localizedCaseInsensitiveContains(search) }
            .map(HoldingRow.from)
            .sorted(using: sortOrder)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("보유 종목").font(.headline)
                Text("두 증권사 합산 · ▸ 를 눌러 증권사별·원화 평단 보기").font(.caption).foregroundStyle(.secondary)
                Spacer()
                TextField("종목 검색", text: $search).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            Table(rows, children: \.children, sortOrder: $sortOrder) {
                TableColumn("종목", value: \.symbol) { r in
                    HStack(spacing: 6) {
                        if r.isLeg {
                            Circle().fill(BrokerStyle.color(r.brokers.first ?? "")).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(r.symbol).foregroundStyle(.secondary)
                                if let note = r.krwNote {
                                    Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .help(r.krwNote.map { $0 + "\n원화 평단 = 매수 시점 환율 기준 (토스 앱과 소폭 다를 수 있음)" } ?? "")
                        } else {
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(spacing: 4) {
                                    Text(r.symbol).fontWeight(.semibold)
                                    ForEach(r.brokers, id: \.self) { b in
                                        Text(BrokerStyle.short(b))
                                            .font(.system(size: 9, weight: .medium))
                                            .padding(.horizontal, 4).padding(.vertical, 1)
                                            .background(BrokerStyle.color(b).opacity(0.2), in: Capsule())
                                    }
                                }
                                Text(r.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                .width(min: 150, ideal: 200)
                TableColumn("수량") { r in num(Fmt.qty(r.quantity)) }.width(70)
                TableColumn("평단가") { r in num(Fmt.price(r.avgCost, currency: r.currency)) }.width(90)
                TableColumn("현재가") { r in num(r.isLeg ? "" : Fmt.price(r.lastPrice, currency: r.currency)) }.width(90)
                TableColumn("오늘", value: \.sortDay) { r in
                    num(r.isLeg ? "" : Fmt.pct(r.dayChangePct)).foregroundStyle(colors.color(r.dayChangePct))
                }.width(75)
                TableColumn("평가금액", value: \.sortValue) { r in
                    num(r.marketValue.map { Fmt.amount($0, currency: r.currency) } ?? "—")
                }.width(110)
                TableColumn("손익", value: \.sortPL) { r in
                    num(r.unrealizedPL.map { Fmt.amount($0, currency: r.currency, signed: true) } ?? "—")
                        .foregroundStyle(colors.color(r.unrealizedPL))
                }.width(105)
                TableColumn("수익률", value: \.sortPLPct) { r in
                    num(Fmt.pct(r.unrealizedPLPct)).foregroundStyle(colors.color(r.unrealizedPLPct))
                }.width(80)
                TableColumn("비중", value: \.sortWeight) { r in
                    if let w = r.weight {
                        HStack(spacing: 6) {
                            GeometryReader { g in
                                Capsule().fill(.quaternary)
                                    .overlay(alignment: .leading) {
                                        Capsule().fill(Color.accentColor.opacity(0.7)).frame(width: g.size.width * min(1, w))
                                    }
                            }
                            .frame(height: 5)
                            Text(Fmt.pct(w, signed: false)).font(.caption.monospacedDigit()).frame(width: 46, alignment: .trailing)
                        }
                    }
                }.width(min: 100, ideal: 120)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: CGFloat(min(14, max(4, rows.count + 1))) * 34 + 30)
        }
        .card()
    }

    private func num(_ s: String) -> Text {
        Text(s).monospacedDigit()
    }
}
