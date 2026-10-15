import Foundation

struct RobotsRules: @unchecked Sendable {
    struct Rule {
        var allow: Bool
        var length: Int
        var regex: NSRegularExpression
    }

    var rules: [Rule] = []
    var crawlDelay: Double = 0
    var sitemaps: [String] = []

    static let allowAll = RobotsRules()

    static func parse(_ text: String, agent: String) -> RobotsRules {
        struct Group { var rules: [Rule] = []; var delay: Double = 0 }
        var groups: [String: Group] = [:]
        var current: [String] = []
        var lastWasAgent = false
        var sitemaps: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine
            if let i = line.firstIndex(of: "#") { line = String(line[..<i]) }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "user-agent":
                if !lastWasAgent { current = [] }
                current.append(value.lowercased())
                lastWasAgent = true
            case "allow", "disallow":
                lastWasAgent = false
                guard !value.isEmpty, let rx = pattern(value) else { continue }
                let rule = Rule(allow: key == "allow", length: value.count, regex: rx)
                for a in current { groups[a, default: Group()].rules.append(rule) }
            case "crawl-delay":
                lastWasAgent = false
                if let d = Double(value) { for a in current { groups[a, default: Group()].delay = d } }
            case "sitemap":
                lastWasAgent = false
                if !value.isEmpty { sitemaps.append(value) }
            default:
                lastWasAgent = false
            }
        }

        let chosen = groups.first(where: { $0.key != "*" && agent.contains($0.key) })?.value ?? groups["*"]
        return RobotsRules(rules: chosen?.rules ?? [], crawlDelay: chosen?.delay ?? 0, sitemaps: sitemaps)
    }

    private static func pattern(_ p: String) -> NSRegularExpression? {
        var body = p
        var anchored = false
        if body.hasSuffix("$") { anchored = true; body.removeLast() }
        let escaped = body.components(separatedBy: "*").map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: ".*")
        return try? NSRegularExpression(pattern: "^" + escaped + (anchored ? "$" : ""))
    }

    func allowed(pathAndQuery path: String) -> Bool {
        var best: Rule?
        let range = NSRange(location: 0, length: (path as NSString).length)
        for r in rules where r.regex.firstMatch(in: path, range: range) != nil {
            if best == nil || r.length > best!.length || (r.length == best!.length && r.allow) { best = r }
        }
        return best?.allow ?? true
    }
}

enum Sitemap {
    static func gunzipIfNeeded(_ d: Data) -> Data {
        guard d.count > 18, d[d.startIndex] == 0x1f, d[d.startIndex + 1] == 0x8b else { return d }
        let b = [UInt8](d)
        var idx = 10
        let flags = b[3]
        if flags & 4 != 0 { idx += 2 + (Int(b[idx]) | (Int(b[idx + 1]) << 8)) }
        if flags & 8 != 0 { while idx < b.count && b[idx] != 0 { idx += 1 }; idx += 1 }
        if flags & 16 != 0 { while idx < b.count && b[idx] != 0 { idx += 1 }; idx += 1 }
        if flags & 2 != 0 { idx += 2 }
        guard idx < b.count - 8 else { return d }
        let payload = Data(b[idx..<(b.count - 8)])
        return (try? (payload as NSData).decompressed(using: .zlib) as Data) ?? d
    }

    /// Собирает URL из sitemap.xml (с вложенными индексами и .gz).
    static func collect(_ roots: [String], net: Net, limit: Int = 50_000) async -> [String] {
        let reLoc = try! NSRegularExpression(pattern: "<loc>\\s*(?:<!\\[CDATA\\[)?\\s*(.*?)\\s*(?:\\]\\]>)?\\s*</loc>", options: [.caseInsensitive, .dotMatchesLineSeparators])
        var queue = roots
        var visited = Set<String>()
        var urls: [String] = []
        var fetched = 0
        while !queue.isEmpty, fetched < 50, urls.count < limit, !Task.isCancelled {
            let u = queue.removeFirst()
            guard visited.insert(u).inserted else { continue }
            fetched += 1
            guard let (data, code) = await net.fetchData(u), code == 200 else { continue }
            let text = String(decoding: gunzipIfNeeded(data), as: UTF8.self)
            let ns = text as NSString
            let locs = reLoc.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
                HTMLParser.decode(ns.substring(with: $0.range(at: 1)))
            }
            if text.lowercased().contains("<sitemapindex") {
                queue.append(contentsOf: locs)
            } else {
                urls.append(contentsOf: locs)
            }
        }
        return Array(urls.prefix(limit))
    }
}
