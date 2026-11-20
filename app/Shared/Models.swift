import Foundation

// Mirrors the helper's JSON (helper/brokerd/aggregate.py, engine.py).

struct Portfolio: Codable, Equatable {
    var asOf: Date
    var demo: Bool
    var displayCurrency: String
    var menuBarStyle: String
    var colorStyle: String?
    var fx: FX
    var totals: Totals
    var brokers: [Broker]
    var positions: [Position]
}

struct FX: Codable, Equatable {
    var USDKRW: Double?
    var USDSGD: Double?
}

struct Totals: Codable, Equatable {
    var marketValueUSD: Double
    var costBasisUSD: Double
    var unrealizedPLUSD: Double
    var unrealizedPLPct: Double?
    var dayPLUSD: Double
    var dayPLPct: Double?
    var cashUSD: Double
    var netWorthUSD: Double
}

struct Broker: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var status: String
    var source: String
    var asOf: Date?
    var message: String?
    var marketValueUSD: Double
    var costBasisUSD: Double
    var dayPLUSD: Double
    var cash: [String: Double]
    var cashUSD: Double
    var positions: Int
    var krw: KRWSummary?
}

/// 원화 기준 손익 (토스): 매수 당시 환율로 산 원금 vs 현재 환율 평가.
struct KRWSummary: Codable, Equatable {
    var costKRW: Double
    var valueKRW: Double
    var plKRW: Double
    var plPct: Double?
    var pricePLKRW: Double
    var fxPLKRW: Double
    var complete: Bool
}

struct PositionLeg: Codable, Equatable {
    var broker: String
    var quantity: Double
    var avgCost: Double?
    var marketValue: Double?
    var costBasis: Double
    var unrealizedPL: Double?
    var avgCostKRW: Double?
    var plKRW: Double?
    var plKRWPct: Double?
    var fxPLKRW: Double?
}

struct Position: Codable, Identifiable, Equatable {
    var id: String { symbol + "|" + currency }
    var symbol: String
    var name: String
    var market: String
    var currency: String
    var quantity: Double
    var avgCost: Double?
    var lastPrice: Double?
    var prevClose: Double?
    var priceSource: String?
    var priceTime: Date?
    var marketValue: Double?
    var costBasis: Double
    var unrealizedPL: Double?
    var unrealizedPLPct: Double?
    var dayChange: Double?
    var dayChangePct: Double?
    var dayPL: Double?
    var marketValueUSD: Double?
    var weight: Double
    var legs: [PositionLeg]
}

struct History: Codable, Equatable {
    var range: String
    var intraday: Bool
    var points: [HistoryPoint]
}

struct HistoryPoint: Codable, Identifiable, Equatable {
    var t: Date
    var valueUSD: Double?
    var costUSD: Double?
    var id: Date { t }
}

struct HelperStatus: Codable, Equatable {
    struct Settings: Codable, Equatable {
        struct Toss: Codable, Equatable { var enabled: Bool }
        struct IBKR: Codable, Equatable {
            var gatewayEnabled: Bool
            var host: String
            var port: Int
            var clientId: Int
            var flexEnabled: Bool
            var flexQueryId: String
        }
        var demoMode: String
        var displayCurrency: String
        var menuBarStyle: String
        var colorStyle: String?
        var toss: Toss
        var ibkr: IBKR
    }
    struct Connectors: Codable, Equatable {
        struct Toss: Codable, Equatable {
            var configured: Bool
            var status: String
            var message: String?
            var ipBlocked: Bool
        }
        struct Gateway: Codable, Equatable {
            var enabled: Bool
            var connected: Bool
            var message: String?
        }
        struct Flex: Codable, Equatable {
            var configured: Bool
            var fetchedAt: Date?
            var message: String?
        }
        var toss: Toss
        var gateway: Gateway
        var flex: Flex
    }
    struct Backfill: Codable, Equatable {
        var running: Bool
        var lastRun: Date?
        var message: String?
    }
    var demo: Bool
    var publicIP: String?
    var secrets: [String: Bool]
    var settings: Settings
    var connectors: Connectors
    var backfill: Backfill
}

enum ISODate {
    private static let withFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Python emits microseconds ("…:52.692746+00:00"); trim to millis for Foundation.
    static func parse(_ raw: String) -> Date? {
        var s = raw
        if let dot = s.firstIndex(of: ".") {
            let fracStart = s.index(after: dot)
            let end = s[fracStart...].firstIndex(where: { !$0.isNumber }) ?? s.endIndex
            let frac = String(s[fracStart..<end].prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            s.replaceSubrange(fracStart..<end, with: frac)
            return withFrac.date(from: s)
        }
        return plain.date(from: s)
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = ISODate.parse(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date \(s)")
            }
            return date
        }
        return d
    }()
}
