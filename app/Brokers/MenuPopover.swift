import SwiftUI

struct MenuPopover: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage("dashboardTab") private var tab = "portfolio"
    @AppStorage("watchSelected") private var watchSelected = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let p = model.portfolio {
                content(p)
            } else {
                HelperDownView().padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 360)
    }

    @ViewBuilder
    private func content(_ p: Portfolio) -> some View {
        let m = model.money
        let c = model.colors
        VStack(alignment: .leading, spacing: 14) {
            if p.demo { DemoBanner(compact: true) }
            HStack(alignment: .firstTextBaseline) {
                Text("총자산").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                CurrencyPicker(selection: p.displayCurrency) { model.setDisplayCurrency($0) }
                    .frame(width: 150)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(m.full(p.totals.netWorthUSD))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.default, value: p.totals.netWorthUSD)
                HStack(spacing: 12) {
                    Label {
                        Text("오늘 \(m.full(p.totals.dayPLUSD, signed: true)) (\(Fmt.pct(p.totals.dayPLPct)))")
                    } icon: { EmptyView() }
                        .foregroundStyle(c.color(p.totals.dayPLUSD))
                    Text("총 \(m.full(p.totals.unrealizedPLUSD, signed: true)) (\(Fmt.pct(p.totals.unrealizedPLPct)))")
                        .foregroundStyle(c.color(p.totals.unrealizedPLUSD))
                }
                .font(.callout.monospacedDigit())
            }

            BrokerSplitBar(brokers: p.brokers, money: m)
            if let k = p.brokers.first(where: { $0.id == "toss" })?.krw {
                HStack(spacing: 6) {
                    Text("토스 원화 기준").foregroundStyle(.secondary)
                    Text("\(Fmt.amount(k.plKRW, currency: "KRW", signed: true)) (\(Fmt.pct(k.plPct)))")
                        .foregroundStyle(c.color(k.plKRW))
                    Text("· 환율 \(Fmt.amount(k.fxPLKRW, currency: "KRW", signed: true))")
                        .foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit())
            }

            VStack(spacing: 6) {
                ForEach(p.positions.prefix(8)) { pos in
                    MiniPositionRow(pos: pos, money: m, colors: c)
                }
                if p.positions.count > 8 {
                    Text("외 \(p.positions.count - 8)종목").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            let starred = (model.watchlist?.items ?? []).filter(\.starred)
            if !starred.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("즐겨찾기", systemImage: "star.fill").font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(starred) { it in
                        Button {
                            tab = "watch"
                            watchSelected = it.symbol
                            openWindow(id: "dashboard")
                            WindowPresence.show()
                        } label: {
                            MiniWatchRow(item: it, colors: c).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            StatusDots(brokers: model.portfolio?.brokers ?? [], reachable: model.helperReachable)
            Spacer()
            Button {
                openWindow(id: "dashboard")
                WindowPresence.show()
            } label: { Label("대시보드", systemImage: "rectangle.grid.2x2") }
            Button {
                WindowPresence.show()
                openSettings()
            } label: { Image(systemName: "gearshape") }
                .help("설정")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("종료")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct MiniPositionRow: View {
    let pos: Position
    let money: Money
    let colors: PLColors

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(pos.symbol).font(.callout.weight(.semibold))
                    ForEach(pos.legs, id: \.broker) { leg in
                        Circle().fill(BrokerStyle.color(leg.broker)).frame(width: 5, height: 5)
                    }
                }
                Text("\(Fmt.qty(pos.quantity))주 · 평단 \(Fmt.price(pos.avgCost, currency: pos.currency))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(money.full(pos.marketValueUSD ?? 0)).font(.callout.monospacedDigit())
                Text(Fmt.arrowPct(pos.dayChangePct))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(colors.color(pos.dayChangePct))
            }
        }
    }
}

struct MiniWatchRow: View {
    let item: WatchItem
    let colors: PLColors

    var body: some View {
        HStack(spacing: 8) {
            Text(item.symbol).font(.callout.weight(.semibold))
            Text(item.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Sparkline(values: item.spark + (item.price.map { [$0] } ?? []), color: colors.color(item.changePct))
                .frame(width: 44, height: 16)
            Text(Fmt.price(item.price, currency: item.ccy)).font(.callout.monospacedDigit())
            Text(Fmt.arrowPct(item.changePct)).font(.caption.monospacedDigit())
                .foregroundStyle(colors.color(item.changePct))
                .frame(width: 62, alignment: .trailing)
        }
    }
}

struct BrokerSplitBar: View {
    let brokers: [Broker]
    let money: Money

    var body: some View {
        let total = max(1, brokers.reduce(0) { $0 + $1.marketValueUSD + $1.cashUSD })
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(brokers) { b in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(BrokerStyle.color(b.id))
                            .frame(width: max(4, geo.size.width * (b.marketValueUSD + b.cashUSD) / total))
                    }
                }
            }
            .frame(height: 8)
            HStack(spacing: 14) {
                ForEach(brokers) { b in
                    HStack(spacing: 5) {
                        Circle().fill(BrokerStyle.color(b.id)).frame(width: 7, height: 7)
                        Text(b.name).font(.caption)
                        Text(money.compact(b.marketValueUSD + b.cashUSD))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Text(String(format: "%.0f%%", (b.marketValueUSD + b.cashUSD) / total * 100))
                            .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

struct StatusDots: View {
    let brokers: [Broker]
    let reachable: Bool

    var body: some View {
        HStack(spacing: 8) {
            if !reachable {
                Label("헬퍼 꺼짐", systemImage: "circle.fill").foregroundStyle(.red)
            } else {
                ForEach(brokers) { b in
                    HStack(spacing: 4) {
                        Circle().fill(Self.color(b.status)).frame(width: 7, height: 7)
                        Text(BrokerStyle.short(b.id))
                    }
                    .help(Self.describe(b))
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    static func color(_ status: String) -> Color {
        switch status {
        case "ok": return .green
        case "stale", "connecting": return .yellow
        case "error": return .red
        default: return .gray
        }
    }

    static func describe(_ b: Broker) -> String {
        let src: String
        switch b.source {
        case "api": src = "토스 Open API (실시간)"
        case "gateway": src = "IB Gateway (실시간)"
        case "flex": src = "Flex 리포트 (전일 기준)"
        case "demo": src = "데모 데이터"
        default: src = b.source
        }
        var s = "\(b.name): \(src) · \(Fmt.relative(b.asOf))"
        if let m = b.message { s += "\n\(m)" }
        return s
    }
}

struct CurrencyPicker: View {
    let selection: String
    let onChange: (DisplayCurrency) -> Void

    var body: some View {
        Picker("", selection: Binding(
            get: { DisplayCurrency(rawValue: selection) ?? .SGD },
            set: { onChange($0) }
        )) {
            ForEach(DisplayCurrency.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }
}

struct DemoBanner: View {
    var compact = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
            Text(compact ? "데모 데이터 표시 중" : "데모 데이터를 표시하고 있어요. 설정에서 토스·IBKR 계정을 연결하면 실제 데이터로 바뀝니다.")
            Spacer()
            Button("계정 연결") {
                WindowPresence.show()
                openSettings()
            }
            .controlSize(.small)
        }
        .font(.caption)
        .padding(8)
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct HelperDownView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("헬퍼(brokerd)가 실행 중이 아니에요", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.orange)
            Text("데이터를 모으는 백그라운드 헬퍼에 연결할 수 없습니다. 터미널에서 아래 명령으로 설치·재시작하세요.")
                .font(.callout).foregroundStyle(.secondary)
            Text("~/Brokers/helper/install.sh")
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
