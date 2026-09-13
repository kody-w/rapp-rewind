import Foundation

public struct NativeCommand: Equatable, Sendable {
    public enum Action: String, Sendable {
        case doctor, search, stats, capture, timeline, prune, bench, open
    }

    public let action: Action
    public let query: String
    public let app: String?
    public let since: String?
    public let limit: Int
    public let days: Int
    public let frameID: Int64?

    public static func parse(_ arguments: [String]) throws -> Self {
        guard let first = arguments.first, let action = Action(rawValue: first),
              arguments.joined().utf8.count <= 16_384 else {
            throw RewindError.invalidAction("use doctor, search, stats, capture, timeline, prune, bench, or open")
        }
        var positional: [String] = []
        var options: [String: String] = [:]
        var index = 1
        let allowed: Set<String>
        switch action {
        case .search: allowed = ["--app", "--since", "--limit"]
        case .timeline: allowed = ["--since", "--limit"]
        case .prune: allowed = ["--days"]
        default: allowed = []
        }
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                guard allowed.contains(argument), options[argument] == nil,
                      index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    throw RewindError.invalidAction("unsupported, repeated, or missing option: \(argument). The native bridge never accepts --yes or starts recording.")
                }
                options[argument] = arguments[index + 1]
                index += 2
            } else {
                positional.append(argument)
                index += 1
            }
        }
        var frameID: Int64?
        switch action {
        case .search:
            guard !positional.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RewindError.invalidAction("search needs query text")
            }
        case .open:
            guard positional.count == 1, let id = Int64(positional[0]), id > 0 else {
                throw RewindError.invalidAction("open needs one positive frame ID")
            }
            frameID = id
        default:
            guard positional.isEmpty else { throw RewindError.invalidAction("unexpected positional arguments") }
        }
        let defaultLimit = action == .timeline ? 400 : 20
        guard let limit = Int(options["--limit"] ?? String(defaultLimit)), (1...1000).contains(limit),
              let days = Int(options["--days"] ?? "30"), (0...36500).contains(days) else {
            throw RewindError.invalidAction("limit must be 1–1000 and days must be 0–36500")
        }
        return Self(
            action: action, query: positional.joined(separator: " "), app: options["--app"],
            since: options["--since"] ?? (action == .timeline ? "1d" : nil),
            limit: limit, days: days, frameID: frameID
        )
    }
}

public enum NativeRoute: Equatable, Sendable {
    case capture
    case search(String)
    case timeline
    case diagnostics
    case stats
    case prune(Int)
    case open(Int64)

    public static func parse(_ url: URL) throws -> Self {
        guard url.absoluteString.utf8.count <= 8192,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "rapp-rewind", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
              let host = parts.host else { throw RewindError.invalidAction("invalid Rewind URL") }
        let items = parts.queryItems ?? []
        func only(_ name: String) throws -> String {
            guard items.count == 1, items[0].name == name, let value = items[0].value else {
                throw RewindError.invalidAction("expected a single \(name) parameter")
            }
            return value
        }
        switch host {
        case "search":
            let query = try only("query")
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RewindError.invalidAction("search needs query text")
            }
            return .search(query)
        case "prune":
            guard let days = Int(try only("days")), (0...36500).contains(days) else {
                throw RewindError.invalidAction("invalid retention days")
            }
            return .prune(days)
        case "open":
            guard let id = Int64(try only("id")), id > 0 else { throw RewindError.invalidAction("invalid frame ID") }
            return .open(id)
        default:
            guard items.isEmpty else { throw RewindError.invalidAction("unexpected URL parameters") }
            switch host {
            case "capture": return .capture
            case "timeline": return .timeline
            case "diagnostics": return .diagnostics
            case "stats": return .stats
            default: throw RewindError.invalidAction("this URL cannot start recording, delete history, or execute commands")
            }
        }
    }
}
