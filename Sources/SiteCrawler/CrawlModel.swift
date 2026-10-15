import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class CrawlModel {
    var urlText = ""
    var settings = CrawlSettings()
    var pages: [PageRecord] = []
    var links: [LinkRecord] = []
    var running = false
    var finished = false
    var statusText = "Введите адрес сайта и нажмите «Старт»"
    var processed = 0
    var queued = 0
    var siteHost = ""

    private var task: Task<Void, Never>?
    private var pendingPages: [PageRecord] = []
    private var flushScheduled = false

    // MARK: управление

    static func hasScheme(_ text: String) -> Bool { text.contains("://") }

    static func normalizeInput(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if !t.contains("://") { t = "https://" + t }
        guard let u = URL(string: t), let n = URLTools.normalize(u) else { return nil }
        return n
    }

    func start() {
        guard !running else { return }
        guard let s = Self.normalizeInput(urlText) else {
            statusText = "Некорректный адрес сайта"
            return
        }
        let guessed = !Self.hasScheme(urlText)
        urlText = s
        siteHost = URL(string: s)?.host ?? s
        pages = []
        links = []
        pendingPages = []
        processed = 0
        queued = 0
        finished = false
        running = true
        statusText = "Запуск…"
        let engine = CrawlEngine(settings: settings, startURL: s, schemeGuessed: guessed, model: self)
        task = Task {
            let out = await engine.run()
            self.complete(out)
        }
    }

    func stop() {
        guard running else { return }
        statusText = "Остановка…"
        task?.cancel()
    }

    private func complete(_ out: CrawlOutput) {
        pages = out.pages
        links = out.links
        pendingPages = []
        running = false
        finished = true
        let broken = links.filter(\.isBroken).count
        let errors = pages.filter { $0.worst == 3 }.count
        statusText = (out.cancelled ? "Остановлено. " : "Готово. ")
            + "Страниц: \(pages.count), с ошибками: \(errors), битых ссылок: \(broken)"
    }

    // MARK: вызовы из движка

    func setStartURL(_ s: String) { urlText = s }

    func setStatus(_ s: String) { if running { statusText = s } }

    func progress(done: Int, queued: Int) {
        processed = done
        self.queued = queued
        if running { statusText = "Сканирование… обработано \(done), в очереди \(queued)" }
    }

    /// Пачками обновляем таблицу, чтобы UI не перерисовывался на каждую страницу.
    func pageAdded(_ p: PageRecord) {
        pendingPages.append(p)
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self?.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        guard running, !pendingPages.isEmpty else { return }
        pages.append(contentsOf: pendingPages)
        pendingPages = []
    }

    // MARK: сводка

    var issueCounts: [(IssueKind, Int)] {
        var d: [IssueKind: Int] = [:]
        for p in pages { for k in Set(p.issues.map(\.kind)) { d[k, default: 0] += 1 } }
        return d.map { ($0.key, $0.value) }.sorted {
            ($0.0.severity, $0.1) > ($1.0.severity, $1.1)
        }
    }

    var averageMs: Int {
        let v = pages.filter { $0.isOK }.map(\.ms)
        return v.isEmpty ? 0 : v.reduce(0, +) / v.count
    }

    // MARK: экспорт

    private func defaultName(_ ext: String, _ part: String = "") -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "sitecrawler-\(siteHost)\(part)-\(f.string(from: Date())).\(ext)"
    }

    private func save(_ data: Data, name: String, type: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            statusText = "Не удалось сохранить: \(error.localizedDescription)"
        }
    }

    func xlsxData() -> Data {
        XLSXWriter.build([Report.summary(self), Report.pages(pages), Report.issues(pages), Report.links(links)])
    }

    func exportXLSX() {
        let data = xlsxData()
        let xlsx = UTType(filenameExtension: "xlsx") ?? .data
        save(data, name: defaultName("xlsx"), type: xlsx)
    }

    func exportCSV(_ which: String) {
        let table: ReportTable
        switch which {
        case "issues": table = Report.issues(pages)
        case "links": table = Report.links(links)
        default: table = Report.pages(pages)
        }
        save(CSVWriter.data(table), name: defaultName("csv", "-" + which), type: .commaSeparatedText)
    }
}
