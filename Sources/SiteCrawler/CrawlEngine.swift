import Foundation

struct QueueItem: Sendable {
    var url: String
    var depth: Int
}

enum Take: Sendable {
    case item(QueueItem)
    case wait
    case done
}

actor Store {
    private var queue: [QueueItem] = []
    private var head = 0
    private(set) var seen = Set<String>()
    private var active = 0
    private var started = 0
    private var finished = 0
    private let maxPages: Int
    private(set) var pages: [String: PageRecord] = [:]
    private(set) var links: [LinkRecord] = []

    init(maxPages: Int) { self.maxPages = maxPages }

    func insertIfNew(_ url: String) -> Bool { seen.insert(url).inserted }
    func push(_ item: QueueItem) { queue.append(item) }

    func take() -> Take {
        if head < queue.count, started < maxPages {
            let it = queue[head]
            head += 1
            started += 1
            active += 1
            return .item(it)
        }
        return active == 0 ? .done : .wait
    }

    func finish() {
        active -= 1
        finished += 1
    }

    func counts() -> (done: Int, queued: Int) { (finished, max(0, min(queue.count - head, maxPages - started))) }

    func addPage(_ p: PageRecord) { pages[p.url] = p }
    func addLinks(_ l: [LinkRecord]) { links.append(contentsOf: l) }
}

final class Scope: @unchecked Sendable {
    let key: String
    let port: Int?
    init(url: URL?) { key = URLTools.siteKey(url?.host); port = url?.port }
    func isInternal(_ s: String) -> Bool {
        let u = URL(string: s)
        return URLTools.siteKey(u?.host) == key && u?.port == port
    }
}

final class CrawlEngine: @unchecked Sendable {
    private let settings: CrawlSettings
    private var startURL: String
    private let schemeGuessed: Bool
    private weak var model: CrawlModel?
    private let net: Net
    private let scope: Scope
    private let store: Store
    private var robots = RobotsRules.allowAll
    private var sitemapSet = Set<String>()
    private var delayMs: Int

    init(settings: CrawlSettings, startURL: String, schemeGuessed: Bool, model: CrawlModel) {
        self.settings = settings
        self.startURL = startURL
        self.schemeGuessed = schemeGuessed
        self.model = model
        self.net = Net(userAgent: settings.userAgent, timeout: settings.timeout, connections: settings.threads * 2)
        self.scope = Scope(url: URL(string: startURL))
        self.store = Store(maxPages: settings.maxPages)
        self.delayMs = settings.delayMs
    }

    private func status(_ s: String) async { await model?.setStatus(s) }

    func run() async -> CrawlOutput {
        // адрес введён без схемы: если https не отвечает, а http отвечает — работаем по http
        if schemeGuessed, startURL.hasPrefix("https://"), await net.check(startURL) == 0 {
            let http = "http://" + startURL.dropFirst("https://".count)
            if await net.check(http) != 0 {
                startURL = http
                await model?.setStartURL(http)
            }
        }
        let start = URL(string: startURL)!
        var origin = "\(start.scheme ?? "https")://\(start.host ?? "")"
        if let port = start.port { origin += ":\(port)" }

        if settings.respectRobots || settings.useSitemap {
            await status("Загрузка robots.txt…")
            if let (data, code) = await net.fetchData(origin + "/robots.txt"), code == 200 {
                robots = RobotsRules.parse(String(decoding: data, as: UTF8.self), agent: "sitecrawler")
            }
            if settings.respectRobots, robots.crawlDelay > 0 {
                delayMs = max(delayMs, Int(min(robots.crawlDelay, 10) * 1000))
            }
        }

        await consider(startURL, depth: 0)

        if settings.useSitemap, !Task.isCancelled {
            await status("Чтение sitemap.xml…")
            let roots = robots.sitemaps.isEmpty ? [origin + "/sitemap.xml"] : robots.sitemaps
            let urls = await Sitemap.collect(roots, net: net)
            for u in urls {
                guard let url = URL(string: u), let n = URLTools.normalize(url), scope.isInternal(n) else { continue }
                sitemapSet.insert(n)
                await consider(n, depth: 1)
            }
        }

        await status("Сканирование…")
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<max(1, settings.threads) {
                group.addTask { await self.worker() }
            }
        }

        let cancelled = Task.isCancelled
        var pages = await store.pages
        var links = await store.links
        var checked: [String: Int] = [:]

        if !cancelled {
            let seen = await store.seen
            var targets: [String] = []
            var uniq = Set<String>()
            for l in links where !seen.contains(l.to) && (l.isInternal || settings.checkExternal) {
                if uniq.insert(l.to).inserted { targets.append(l.to) }
            }
            checked = await checkAll(targets)
        }

        await status("Анализ…")
        let result = Analyzer.analyze(pages: &pages, links: &links, checked: checked, sitemap: sitemapSet,
                                      startURL: startURL, maxDepth: settings.maxDepth)
        return CrawlOutput(pages: result, links: links, cancelled: Task.isCancelled)
    }

    private func checkAll(_ targets: [String]) async -> [String: Int] {
        guard !targets.isEmpty else { return [:] }
        var results: [String: Int] = [:]
        let limit = min(max(settings.threads * 2, 4), 16)
        await withTaskGroup(of: (String, Int).self) { group in
            var it = targets.makeIterator()
            var running = 0
            while running < limit, let t = it.next() {
                group.addTask { (t, await self.net.check(t)) }
                running += 1
            }
            for await (t, s) in group {
                results[t] = s
                await status("Проверка ссылок: \(results.count) из \(targets.count)")
                if Task.isCancelled { group.cancelAll(); continue }
                if let n = it.next() { group.addTask { (n, await self.net.check(n)) } }
            }
        }
        return results
    }

    /// Ставит внутренний URL в очередь; закрытые robots.txt записывает как заблокированные.
    private func consider(_ s: String, depth: Int) async {
        guard scope.isInternal(s) else { return }
        guard await store.insertIfNew(s) else { return }
        if settings.respectRobots, !robots.allowed(pathAndQuery: URLTools.pathAndQuery(s)) {
            var rec = PageRecord(url: s)
            rec.depth = depth
            rec.blockedByRobots = true
            rec.issues = [Issue(kind: .blockedByRobots)]
            await store.addPage(rec)
            await model?.pageAdded(rec)
            return
        }
        await store.push(QueueItem(url: s, depth: depth))
    }

    private func worker() async {
        while !Task.isCancelled {
            switch await store.take() {
            case .item(let it):
                await process(it)
                await store.finish()
                let c = await store.counts()
                await model?.progress(done: c.done, queued: c.queued)
                if delayMs > 0 { try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000) }
            case .wait:
                try? await Task.sleep(nanoseconds: 40_000_000)
            case .done:
                return
            }
        }
    }

    private func process(_ item: QueueItem) async {
        guard let url = URL(string: item.url) else { return }
        let r = await net.fetchPage(url)
        if Task.isCancelled { return }

        var rec = PageRecord(url: item.url)
        rec.depth = item.depth
        rec.status = r.status
        rec.contentType = r.contentType.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        rec.ms = r.ms
        rec.bytes = r.bytes
        rec.error = r.error
        rec.inSitemap = sitemapSet.contains(item.url)

        if (300..<400).contains(r.status), !r.location.isEmpty,
           let t = URL(string: r.location, relativeTo: url)?.absoluteURL, let n = URLTools.normalize(t) {
            rec.redirectTo = n
            if item.depth < settings.maxDepth { await consider(n, depth: item.depth + 1) }
        }

        if let body = r.body {
            var html = HTMLParser.decodeBody(body, textEncodingName: r.textEncoding)
            if settings.renderJS,
               let rendered = await JSRenderer.shared.render(url: url, userAgent: settings.userAgent, timeout: settings.timeout) {
                html = rendered
            }
            let parsed = HTMLParser.parse(html, base: url)
            rec.title = parsed.title
            rec.description = parsed.description
            rec.h1 = parsed.h1s.first ?? ""
            rec.h1Count = parsed.h1s.count
            rec.h2Count = parsed.h2Count
            rec.canonical = parsed.canonical
            rec.robotsMeta = [parsed.robots, r.xRobots].filter { !$0.isEmpty }.joined(separator: ", ")
            rec.words = parsed.words
            rec.imgNoAlt = parsed.imgNoAlt

            var out: [LinkRecord] = []
            for l in parsed.links {
                let internalLink = scope.isInternal(l.to)
                out.append(LinkRecord(id: 0, from: item.url, to: l.to, anchor: l.anchor, kind: l.kind,
                                      isInternal: internalLink, nofollow: l.nofollow))
                if l.kind == "a", internalLink, !l.nofollow, item.depth < settings.maxDepth {
                    await consider(l.to, depth: item.depth + 1)
                }
            }
            await store.addLinks(out)
        }

        // мгновенная подсветка ошибок во время обхода; полный анализ — в конце
        if rec.status == 0 { rec.issues.append(Issue(kind: .requestFailed, detail: rec.error)) }
        else if rec.status >= 500 { rec.issues.append(Issue(kind: .http5xx, detail: String(rec.status))) }
        else if rec.status >= 400 { rec.issues.append(Issue(kind: .http4xx, detail: String(rec.status))) }

        await store.addPage(rec)
        await model?.pageAdded(rec)
    }
}
