import SwiftUI

/// 자산 목표 (e.g. 1억 모으기): stored locally, compared against 총자산 (주식 + 현금).
enum Goal {
    static let amountKey = "goalAmount"
    static let currencyKey = "goalCurrency"
    static let nameKey = "goalName"
    static let enabledKey = "goalEnabled"

    /// Net worth expressed in the goal's currency.
    static func current(_ p: Portfolio, currency: String) -> Double {
        let usd = p.totals.netWorthUSD
        switch currency {
        case "KRW": return usd * (p.fx.USDKRW ?? 0)
        case "SGD": return usd * (p.fx.USDSGD ?? 0)
        default: return usd
        }
    }

    /// "1억", "1억 2,000만", "1,693만" for KRW; "$100K" style otherwise.
    static func fmt(_ v: Double, _ ccy: String) -> String {
        let a = abs(v), sign = v < 0 ? "-" : ""
        if ccy == "KRW" {
            let eok = Int(a / 1e8)
            let man = Int((a.truncatingRemainder(dividingBy: 1e8)) / 1e4)
            let nf = NumberFormatter()
            nf.numberStyle = .decimal
            let manStr = nf.string(from: NSNumber(value: man)) ?? "\(man)"
            if eok > 0 { return sign + (man > 0 ? "\(eok)억 \(manStr)만" : "\(eok)억") }
            if man > 0 { return sign + "\(manStr)만" }
            return sign + "₩" + (nf.string(from: NSNumber(value: Int(a))) ?? "\(Int(a))")
        }
        let s = Fmt.symbol(for: ccy)
        if a >= 1e6 { return "\(sign)\(s)\(String(format: a.truncatingRemainder(dividingBy: 1e6) == 0 ? "%.0f" : "%.2f", a / 1e6))M" }
        if a >= 1e4 { return "\(sign)\(s)\(String(format: a.truncatingRemainder(dividingBy: 1e3) == 0 ? "%.0f" : "%.1f", a / 1e3))K" }
        return Fmt.amount(v, currency: ccy, digits: 0)
    }

    static func presets(_ ccy: String) -> [Double] {
        ccy == "KRW" ? [3e7, 5e7, 1e8, 2e8, 3e8, 5e8, 1e9] : [5e4, 1e5, 2.5e5, 5e5, 1e6]
    }
}

/// Progress ring with the percentage in the middle.
struct GoalRing: View {
    let progress: Double
    var lineWidth: CGFloat = 5
    var showText = true

    var body: some View {
        let done = progress >= 1
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, progress)))
                .stroke(
                    done ? AnyShapeStyle(Color.green)
                         : AnyShapeStyle(AngularGradient(colors: [.accentColor.opacity(0.6), .accentColor], center: .center)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: progress)
            if showText {
                Text(done ? "🎉" : "\(Int((progress * 100).rounded(.down)))%")
                    .font(.system(size: UIScale.pt(lineWidth > 6 ? 22 : 10), weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
    }
}

/// Compact goal indicator for the dashboard header; click to see details / edit.
struct GoalBadge: View {
    let portfolio: Portfolio
    @AppStorage(Goal.amountKey) private var amount = 1e8
    @AppStorage(Goal.currencyKey) private var currency = "KRW"
    @AppStorage(Goal.nameKey) private var name = "1억 모으기"
    @AppStorage(Goal.enabledKey) private var enabled = true
    @State private var open = false

    var body: some View {
        if enabled {
            let cur = Goal.current(portfolio, currency: currency)
            let progress = amount > 0 ? cur / amount : 0
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    GoalRing(progress: progress, lineWidth: 4).frame(width: UIScale.pt(34), height: UIScale.pt(34))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("🎯 \(name)").font(.s(.caption).weight(.semibold)).lineLimit(1)
                        Text("\(Goal.fmt(cur, currency)) / \(Goal.fmt(amount, currency))")
                            .font(.s(.caption2)).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.quaternary.opacity(0.5), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("자산 목표 — 눌러서 자세히 보기·수정")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                GoalDetail(portfolio: portfolio).scaledFonts()
            }
        }
    }
}

/// Popover: big ring, milestones, remaining amount, and the goal editor.
struct GoalDetail: View {
    let portfolio: Portfolio
    @AppStorage(Goal.amountKey) private var amount = 1e8
    @AppStorage(Goal.currencyKey) private var currency = "KRW"
    @AppStorage(Goal.nameKey) private var name = "1억 모으기"
    @AppStorage(Goal.enabledKey) private var enabled = true
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        let cur = Goal.current(portfolio, currency: currency)
        let progress = amount > 0 ? cur / amount : 0
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 18) {
                GoalRing(progress: progress, lineWidth: 10).frame(width: UIScale.pt(96), height: UIScale.pt(96))
                VStack(alignment: .leading, spacing: 4) {
                    Text("🎯 \(name)").font(.s(.headline))
                    Text(Goal.fmt(cur, currency)).font(.system(size: UIScale.pt(24), weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("목표 \(Goal.fmt(amount, currency)) · \(Fmt.pct(progress, signed: false))")
                        .font(.s(.callout)).foregroundStyle(.secondary).monospacedDigit()
                    if progress >= 1 {
                        Text("목표 달성! 다음 목표를 세워보세요").font(.s(.callout).weight(.medium)).foregroundStyle(.green)
                    } else {
                        Text("남은 금액 \(Goal.fmt(amount - cur, currency))").font(.s(.callout).weight(.medium))
                    }
                }
            }
            MilestoneBar(progress: progress, amount: amount, currency: currency)
            Text("총자산(주식 + 현금, 두 증권사 합산) 기준 · 환율은 실시간")
                .font(.s(.caption2)).foregroundStyle(.tertiary)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { editing.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: UIScale.pt(10), weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(editing ? 90 : 0))
                        Text("목표 수정").font(.s(.callout))
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if editing { editor.padding(.top, 8).font(.s(.callout)) }
            }
        }
        .padding(18)
        .frame(width: UIScale.pt(400))
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("이름").frame(width: 50, alignment: .leading)
                TextField("예: 1억 모으기", text: $name).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("통화").frame(width: 50, alignment: .leading)
                Picker("", selection: $currency) {
                    Text("KRW").tag("KRW"); Text("USD").tag("USD"); Text("SGD").tag("SGD")
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            HStack {
                Text("금액").frame(width: 50, alignment: .leading)
                TextField(currency == "KRW" ? "예: 100000000" : "예: 100000", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(applyDraft)
                Button("적용", action: applyDraft).disabled(parsedDraft == nil)
            }
            if let v = parsedDraft {
                Text("= \(Goal.fmt(v, currency))").font(.s(.caption)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(Goal.presets(currency), id: \.self) { v in
                    Button(Goal.fmt(v, currency)) { amount = v; draft = "" }
                        .buttonStyle(.bordered).controlSize(.small)
                        .tint(v == amount ? .accentColor : nil)
                }
            }
            Toggle("대시보드·메뉴바에 목표 표시", isOn: $enabled).font(.s(.caption))
        }
    }

    /// Accepts "100000000", "1억", "5000만", "1.5억", "100k", "1m".
    private var parsedDraft: Double? {
        var s = draft.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "").lowercased()
        guard !s.isEmpty else { return nil }
        var mult = 1.0
        for (suffix, m) in [("억", 1e8), ("천만", 1e7), ("만", 1e4), ("k", 1e3), ("m", 1e6)] where s.hasSuffix(suffix) {
            mult = m
            s.removeLast(suffix.count)
            break
        }
        guard let n = Double(s), n > 0 else { return nil }
        return n * mult
    }

    private func applyDraft() {
        if let v = parsedDraft { amount = v; draft = "" }
    }
}

/// Horizontal bar with 25/50/75% milestone ticks.
struct MilestoneBar: View {
    let progress: Double
    let amount: Double
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(LinearGradient(colors: [.accentColor.opacity(0.6), progress >= 1 ? .green : .accentColor],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(8, g.size.width * min(1, max(0, progress))))
                        .animation(.easeOut(duration: 0.6), value: progress)
                    ForEach([0.25, 0.5, 0.75], id: \.self) { m in
                        Rectangle().fill(.background.opacity(0.8)).frame(width: 2)
                            .offset(x: g.size.width * m - 1)
                    }
                }
            }
            .frame(height: UIScale.pt(10))
            HStack {
                ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { m in
                    Text(Goal.fmt(amount * m, currency).replacingOccurrences(of: "₩0", with: "0"))
                        .font(.s(.caption2)).monospacedDigit()
                        .foregroundStyle(progress >= m ? Color.primary : Color.secondary)
                    if m < 1 { Spacer() }
                }
            }
        }
    }
}

/// One-line goal bar for the menu bar popover.
struct GoalMiniBar: View {
    let portfolio: Portfolio
    @AppStorage(Goal.amountKey) private var amount = 1e8
    @AppStorage(Goal.currencyKey) private var currency = "KRW"
    @AppStorage(Goal.nameKey) private var name = "1억 모으기"
    @AppStorage(Goal.enabledKey) private var enabled = true

    var body: some View {
        if enabled, amount > 0 {
            let cur = Goal.current(portfolio, currency: currency)
            let progress = cur / amount
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("🎯 \(name)").font(.s(.caption).weight(.semibold))
                    Spacer()
                    Text("\(Goal.fmt(cur, currency)) / \(Goal.fmt(amount, currency)) · \(Fmt.pct(progress, signed: false))")
                        .font(.s(.caption)).monospacedDigit().foregroundStyle(.secondary)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(progress >= 1 ? Color.green : Color.accentColor)
                            .frame(width: max(6, g.size.width * min(1, max(0, progress))))
                    }
                }
                .frame(height: 6)
            }
        }
    }
}
