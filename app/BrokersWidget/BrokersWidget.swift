import SwiftUI
import WidgetKit

struct PortfolioEntry: TimelineEntry {
    let date: Date
    let portfolio: Portfolio?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> PortfolioEntry { PortfolioEntry(date: .now, portfolio: nil) }

    func getSnapshot(in context: Context, completion: @escaping (PortfolioEntry) -> Void) {
        Task { completion(PortfolioEntry(date: .now, portfolio: try? await APIClient().get("v1/portfolio"))) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PortfolioEntry>) -> Void) {
        Task {
            let p: Portfolio? = try? await APIClient().get("v1/portfolio")
            let entry = PortfolioEntry(date: .now, portfolio: p)
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(300))))
        }
    }
}

struct WidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: PortfolioEntry

    var body: some View {
        if let p = entry.portfolio {
            let m = Money(p.displayCurrency, fx: p.fx)
            let c = PLColors(p.colorStyle)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                        Text(p.demo ? "총자산 · 데모" : "총자산")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Text(m.compact(p.totals.netWorthUSD))
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.6).lineLimit(1)
                    Text("오늘 \(Fmt.arrowPct(p.totals.dayPLPct))")
                        .font(.caption.weight(.medium)).foregroundStyle(c.color(p.totals.dayPLUSD))
                    Text(m.compact(p.totals.dayPLUSD, signed: true))
                        .font(.caption).foregroundStyle(c.color(p.totals.dayPLUSD))
                    Spacer(minLength: 0)
                    Text("총 손익 \(Fmt.pct(p.totals.unrealizedPLPct))")
                        .font(.caption2).foregroundStyle(c.color(p.totals.unrealizedPLUSD))
                }
                if family != .systemSmall {
                    VStack(spacing: 5) {
                        ForEach(p.positions.prefix(family == .systemLarge ? 12 : 5)) { pos in
                            HStack {
                                Text(pos.symbol).font(.caption.weight(.semibold))
                                Spacer()
                                Text(m.compact(pos.marketValueUSD ?? 0)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(Fmt.arrowPct(pos.dayChangePct))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(c.color(pos.dayChangePct))
                                    .frame(width: 58, alignment: .trailing)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle").font(.title2)
                Text("헬퍼에 연결할 수 없어요").font(.caption)
            }
            .foregroundStyle(.secondary)
        }
    }
}

@main
struct BrokersWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "BrokersPortfolio", provider: Provider()) { entry in
            WidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("포트폴리오")
        .description("토스 + IBKR 합산 총자산과 오늘 손익")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
