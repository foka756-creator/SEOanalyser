import Foundation

enum URLTools {
    static func normalize(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var c = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let host = c.host, !host.isEmpty else { return nil }
        c.scheme = scheme
        c.host = host.lowercased()
        c.fragment = nil
        if (scheme == "http" && c.port == 80) || (scheme == "https" && c.port == 443) { c.port = nil }
        if c.path.isEmpty { c.path = "/" }
        return c.string
    }

    static func siteKey(_ host: String?) -> String {
        let h = (host ?? "").lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    static func pathAndQuery(_ s: String) -> String {
        guard let c = URLComponents(string: s) else { return "/" }
        let p = c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath
        if let q = c.percentEncodedQuery { return p + "?" + q }
        return p
    }
}

struct ParsedLink: Sendable {
    var to: String
    var anchor: String
    var kind: String
    var nofollow: Bool
}

struct ParsedPage: Sendable {
    var title = ""
    var description = ""
    var h1s: [String] = []
    var h2Count = 0
    var canonical = ""
    var robots = ""
    var words = 0
    var imgNoAlt = 0
    var links: [ParsedLink] = []
}

enum HTMLParser {
    private static func re(_ p: String, _ o: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: o)
    }

    private static let reComments = re("<!--.*?-->")
    private static let reScript = re("<script\\b.*?</script\\s*>")
    private static let reStyle = re("<style\\b.*?</style\\s*>")
    private static let reTitle = re("<title[^>]*>(.*?)</title\\s*>")
    private static let reMeta = re("<meta\\b[^>]*>")
    private static let reLinkTag = re("<link\\b[^>]*>")
    private static let reBase = re("<base\\b[^>]*>")
    private static let reH1 = re("<h1\\b[^>]*>(.*?)</h1\\s*>")
    private static let reH2 = re("<h2\\b[^>]*>")
    private static let reA = re("<a\\b([^>]*)>(.*?)</a\\s*>")
    private static let reImg = re("<img\\b[^>]*>")
    private static let reBody = re("<body\\b[^>]*>")
    private static let reTag = re("<[^>]+>")
    private static let reNumEntity = re("&#(x?)([0-9a-fA-F]+);")
    private static let reAttr = re("([a-zA-Z_:][-a-zA-Z0-9_:.]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))", [])

    private static let named: [(String, String)] = [
        ("&nbsp;", " "), ("&quot;", "\""), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"),
        ("&laquo;", "«"), ("&raquo;", "»"), ("&mdash;", "—"), ("&ndash;", "–"),
        ("&hellip;", "…"), ("&copy;", "©"), ("&amp;", "&"),
    ]

    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        let ns = out as NSString
        let matches = reNumEntity.matches(in: out, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            let isHex = ns.substring(with: m.range(at: 1)) == "x"
            let digits = ns.substring(with: m.range(at: 2))
            if let code = UInt32(digits, radix: isHex ? 16 : 10), let sc = Unicode.Scalar(code) {
                out = (out as NSString).replacingCharacters(in: m.range, with: String(Character(sc)))
            }
        }
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }

    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func stripTags(_ s: String) -> String {
        let r = reTag.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
        return collapse(decode(r))
    }

    private static func remove(_ r: NSRegularExpression, _ s: String) -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
    }

    private static func attrs(_ tag: String) -> [String: String] {
        var d: [String: String] = [:]
        let ns = tag as NSString
        for m in reAttr.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: m.range(at: 1)).lowercased()
            var val = ""
            for g in 2...4 where m.range(at: g).location != NSNotFound {
                val = ns.substring(with: m.range(at: g))
                break
            }
            if d[key] == nil { d[key] = decode(val) }
        }
        return d
    }

    static func parse(_ raw: String, base: URL) -> ParsedPage {
        var p = ParsedPage()
        var s = remove(reComments, raw)
        s = remove(reScript, s)
        s = remove(reStyle, s)
        let ns = s as NSString
        let full = NSRange(location: 0, length: ns.length)

        if let m = reTitle.firstMatch(in: s, range: full) {
            p.title = stripTags(ns.substring(with: m.range(at: 1)))
        }

        var robots: [String] = []
        for m in reMeta.matches(in: s, range: full) {
            let a = attrs(ns.substring(with: m.range))
            let name = a["name"]?.lowercased() ?? ""
            let content = collapse(a["content"] ?? "")
            if name == "description" { p.description = content }
            if name == "robots" || name == "googlebot" { robots.append(content) }
        }
        p.robots = robots.joined(separator: ", ")

        var effectiveBase = base
        if let m = reBase.firstMatch(in: s, range: full),
           let href = attrs(ns.substring(with: m.range))["href"],
           let b = URL(string: href.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: base) {
            effectiveBase = b.absoluteURL
        }

        for m in reLinkTag.matches(in: s, range: full) {
            let a = attrs(ns.substring(with: m.range))
            if (a["rel"] ?? "").lowercased().split(separator: " ").contains("canonical"),
               let href = a["href"], !href.isEmpty {
                p.canonical = URL(string: href.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: effectiveBase)?.absoluteURL.absoluteString ?? href
            }
        }

        for m in reH1.matches(in: s, range: full) {
            p.h1s.append(stripTags(ns.substring(with: m.range(at: 1))))
        }
        p.h2Count = reH2.numberOfMatches(in: s, range: full)

        if let m = reBody.firstMatch(in: s, range: full) {
            let bodyStart = m.range.location + m.range.length
            let body = ns.substring(from: bodyStart)
            p.words = stripTags(body).split(separator: " ").count
        }

        var seen = Set<String>()
        func add(_ href: String?, anchor: String, kind: String, nofollow: Bool) {
            guard var h = href?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty else { return }
            let low = h.lowercased()
            if h.hasPrefix("#") || low.hasPrefix("javascript:") || low.hasPrefix("mailto:") || low.hasPrefix("tel:")
                || low.hasPrefix("data:") || low.hasPrefix("sms:") || low.hasPrefix("viber:") || low.hasPrefix("whatsapp:") { return }
            if h.hasPrefix("//") { h = (effectiveBase.scheme ?? "https") + ":" + h }
            guard let u = URL(string: h, relativeTo: effectiveBase)?.absoluteURL, let n = URLTools.normalize(u) else { return }
            guard seen.insert(kind + "|" + n).inserted else { return }
            p.links.append(ParsedLink(to: n, anchor: anchor, kind: kind, nofollow: nofollow))
        }

        for m in reA.matches(in: s, range: full) {
            let a = attrs(ns.substring(with: m.range(at: 1)))
            let inner = ns.substring(with: m.range(at: 2))
            var anchor = stripTags(inner)
            if anchor.isEmpty, let im = reImg.firstMatch(in: inner, range: NSRange(location: 0, length: (inner as NSString).length)) {
                let alt = attrs((inner as NSString).substring(with: im.range))["alt"] ?? ""
                anchor = alt.isEmpty ? "[изображение]" : "[img] " + alt
            }
            let nofollow = (a["rel"] ?? "").lowercased().contains("nofollow")
            add(a["href"], anchor: anchor, kind: "a", nofollow: nofollow)
        }

        for m in reImg.matches(in: s, range: full) {
            let a = attrs(ns.substring(with: m.range))
            if a["alt"] == nil { p.imgNoAlt += 1 }
            add(a["src"] ?? a["data-src"], anchor: a["alt"] ?? "", kind: "img", nofollow: false)
        }
        return p
    }

    static func decodeBody(_ data: Data, textEncodingName: String?) -> String {
        var name = textEncodingName
        if name == nil {
            let head = String(decoding: data.prefix(3000), as: UTF8.self)
            if let m = re("charset\\s*=\\s*[\"']?([A-Za-z0-9_-]+)").firstMatch(in: head, range: NSRange(location: 0, length: (head as NSString).length)) {
                name = (head as NSString).substring(with: m.range(at: 1))
            }
        }
        if let n = name {
            let cf = CFStringConvertIANACharSetNameToEncoding(n as CFString)
            if cf != kCFStringEncodingInvalidId {
                let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let s = String(data: data, encoding: enc) { return s }
            }
        }
        return String(decoding: data, as: UTF8.self)
    }
}
