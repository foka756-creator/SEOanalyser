import Foundation

enum Analyzer {
    static func analyze(pages: inout [String: PageRecord], links: inout [LinkRecord], checked: [String: Int],
                        sitemap: Set<String>, startURL: String, maxDepth: Int) -> [PageRecord] {
        // 1. статусы ссылок и входящие
        var inlinks: [String: Int] = [:]
        var brokenByPage: [String: [String]] = [:]
        for i in links.indices {
            links[i].id = i
            let to = links[i].to
            if let p = pages[to] {
                links[i].status = p.blockedByRobots ? -1 : p.status
            } else if let s = checked[to] {
                links[i].status = s
            } else {
                links[i].status = -2
            }
            if links[i].kind == "a", links[i].isInternal, links[i].from != to { inlinks[to, default: 0] += 1 }
            if links[i].isBroken { brokenByPage[links[i].from, default: []].append(to) }
        }

        // 2. дубли среди индексируемых HTML-страниц
        func key(_ s: String) -> String { s.lowercased() }
        var titles: [String: Int] = [:], descs: [String: Int] = [:], h1s: [String: Int] = [:]
        for p in pages.values where p.isOK && p.isHTML {
            if !p.title.isEmpty { titles[key(p.title), default: 0] += 1 }
            if !p.description.isEmpty { descs[key(p.description), default: 0] += 1 }
            if !p.h1.isEmpty { h1s[key(p.h1), default: 0] += 1 }
        }

        // 3. проблемы по страницам
        for url in Array(pages.keys) {
            var p = pages[url]!
            p.inlinks = inlinks[url] ?? 0
            p.issues = []
            func add(_ k: IssueKind, _ d: String = "") { p.issues.append(Issue(kind: k, detail: d)) }

            if p.blockedByRobots {
                add(.blockedByRobots)
                pages[url] = p
                continue
            }
            if p.status == 0 { add(.requestFailed, p.error) }
            else if p.status >= 500 { add(.http5xx, String(p.status)) }
            else if p.status >= 400 { add(.http4xx, String(p.status)) }
            else if p.status >= 300 { add(.redirect, "\(p.status) → \(p.redirectTo)") }

            if p.inSitemap, p.status != 200 {
                add(.sitemapBadStatus, p.status == 0 ? p.error : String(p.status))
            }

            if let broken = brokenByPage[url] {
                let sample = broken.prefix(3).joined(separator: ", ")
                add(.brokenLinks, "\(broken.count) шт.: \(sample)\(broken.count > 3 ? "…" : "")")
            }

            if p.isOK, p.isHTML {
                let robots = p.robotsMeta.lowercased()
                let noindex = robots.contains("noindex")

                if p.title.isEmpty { add(.missingTitle) }
                else {
                    if p.titleLength > 60 { add(.titleTooLong, "\(p.titleLength)") }
                    if p.titleLength < 20 { add(.titleTooShort, "\(p.titleLength)") }
                    if titles[key(p.title), default: 0] > 1 { add(.duplicateTitle, "\(titles[key(p.title)]!) стр.") }
                }
                if p.description.isEmpty { add(.missingDescription) }
                else {
                    if p.descriptionLength > 160 { add(.descriptionTooLong, "\(p.descriptionLength)") }
                    if p.descriptionLength < 50 { add(.descriptionTooShort, "\(p.descriptionLength)") }
                    if descs[key(p.description), default: 0] > 1 { add(.duplicateDescription, "\(descs[key(p.description)]!) стр.") }
                }
                if p.h1Count == 0 { add(.missingH1) }
                else {
                    if p.h1Count > 1 { add(.multipleH1, "\(p.h1Count)") }
                    if !p.h1.isEmpty, h1s[key(p.h1), default: 0] > 1 { add(.duplicateH1, "\(h1s[key(p.h1)]!) стр.") }
                }
                if p.imgNoAlt > 0 { add(.imagesNoAlt, "\(p.imgNoAlt)") }
                if p.ms > 2000 { add(.slowResponse, "\(p.ms) мс") }

                if p.canonical.isEmpty { add(.missingCanonical) }
                else if let u = URL(string: p.canonical), let n = URLTools.normalize(u), n != url {
                    add(.canonicalOther, p.canonical)
                }

                if noindex {
                    add(.noindex)
                    if p.inSitemap { add(.noindexInSitemap) }
                } else if p.words < 150 {
                    add(.thinContent, "\(p.words) слов")
                }
            }

            if p.depth > 5 { add(.deepPage, "уровень \(p.depth)") }
            if p.inSitemap, p.inlinks == 0, url != startURL, p.isOK { add(.orphan) }
            pages[url] = p
        }

        return pages.values.sorted { ($0.depth, $0.url) < ($1.depth, $1.url) }
    }
}
