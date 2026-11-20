import SwiftUI

enum DisplayCurrency: String, CaseIterable, Identifiable {
    case USD, SGD, KRW
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .USD: return "$"
        case .SGD: return "S$"
        case .KRW: return "₩"
        }
    }
    var label: String {
        switch self {
        case .USD: return "USD"
        case .SGD: return "SGD"
        case .KRW: return "KRW"
        }
    }
}

struct Money {
    let currency: DisplayCurrency
    let fx: FX

    init(_ code: String, fx: FX) {
        currency = DisplayCurrency(rawValue: code) ?? .USD
        self.fx = fx
    }

    func convert(_ usd: Double) -> Double {
        switch currency {
        case .USD: return usd
        case .SGD: return usd * (fx.USDSGD ?? 1)
        case .KRW: return usd * (fx.USDKRW ?? 1)
        }
    }

    /// Full amount, e.g. "S$154,210" / "₩162,334,000".
    func full(_ usd: Double, signed: Bool = false) -> String {
        Fmt.amount(convert(usd), currency: currency.rawValue, signed: signed)
    }

    /// Short amount for the menu bar / widgets, e.g. "S$154.2K" / "₩1.62억".
    func compact(_ usd: Double, signed: Bool = false) -> String {
        let v = convert(usd)
        let sign = signed ? (v > 0 ? "+" : (v < 0 ? "-" : "")) : (v < 0 ? "-" : "")
        let a = abs(v)
        if currency == .KRW {
            if a >= 1e8 { return "\(sign)₩\(String(format: "%.2f", a / 1e8))억" }
            if a >= 1e4 { return "\(sign)₩\(String(format: "%.0f", a / 1e4))만" }
            return "\(sign)₩\(String(format: "%.0f", a))"
        }
        let s = currency.symbol
        if a >= 1e6 { return "\(sign)\(s)\(String(format: "%.2f", a / 1e6))M" }
        if a >= 1e4 { return "\(sign)\(s)\(String(format: "%.1f", a / 1e3))K" }
        return "\(sign)\(s)\(String(format: "%.0f", a))"
    }
}

enum Fmt {
    static func symbol(for code: String) -> String {
        switch code {
        case "USD": return "$"
        case "SGD": return "S$"
        case "KRW": return "₩"
        case "HKD": return "HK$"
        case "EUR": return "€"
        case "GBP": return "£"
        case "JPY": return "¥"
        default: return code + " "
        }
    }

    static func digits(for code: String) -> Int { (code == "KRW" || code == "JPY") ? 0 : 2 }

    static func amount(_ v: Double, currency: String, signed: Bool = false, digits: Int? = nil) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        let d = digits ?? Self.digits(for: currency)
        nf.minimumFractionDigits = d
        nf.maximumFractionDigits = d
        let body = nf.string(from: NSNumber(value: abs(v))) ?? "\(abs(v))"
        let sign = v < 0 ? "-" : (signed && v > 0 ? "+" : "")
        return sign + symbol(for: currency) + body
    }

    static func price(_ v: Double?, currency: String) -> String {
        guard let v else { return "—" }
        let d = currency == "KRW" ? 0 : (v < 1 ? 4 : 2)
        return amount(v, currency: currency, digits: d)
    }

    static func pct(_ v: Double?, signed: Bool = true) -> String {
        guard let v, v.isFinite else { return "—" }
        let s = String(format: "%.2f%%", abs(v) * 100)
        if !signed { return s }
        return (v > 0 ? "+" : (v < 0 ? "-" : "")) + s
    }

    static func arrowPct(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "—" }
        let arrow = v > 0 ? "▲" : (v < 0 ? "▼" : "")
        return arrow + String(format: "%.2f%%", abs(v) * 100)
    }

    static func qty(_ v: Double) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.maximumFractionDigits = v == v.rounded() ? 0 : 4
        return nf.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    static func relative(_ d: Date?) -> String {
        guard let d else { return "—" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

/// 한국식(상승=빨강, 하락=파랑) or 미국식(상승=초록, 하락=빨강).
struct PLColors {
    let style: String
    init(_ style: String?) { self.style = style ?? "kr" }

    var up: Color { style == "us" ? Color(red: 0.13, green: 0.66, blue: 0.38) : Color(red: 0.94, green: 0.27, blue: 0.27) }
    var down: Color { style == "us" ? Color(red: 0.94, green: 0.27, blue: 0.27) : Color(red: 0.20, green: 0.45, blue: 0.95) }

    func color(_ v: Double?) -> Color {
        guard let v, v != 0 else { return .secondary }
        return v > 0 ? up : down
    }
}

enum BrokerStyle {
    static func color(_ id: String) -> Color {
        switch id {
        case "toss": return Color(red: 0.19, green: 0.51, blue: 0.96)  // Toss blue
        case "ibkr": return Color(red: 0.96, green: 0.58, blue: 0.18)  // amber: avoids clashing with P/L red
        default: return .gray
        }
    }

    static func short(_ id: String) -> String {
        switch id {
        case "toss": return "토스"
        case "ibkr": return "IBKR"
        default: return id
        }
    }
}
