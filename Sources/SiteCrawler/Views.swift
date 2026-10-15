import SwiftUI

@main
struct SiteCrawlerApp: App {
    @State private var model = CrawlModel()

    init() {
        // Режим без окна: SiteCrawler --cli https://site.ru отчёт.xlsx
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--cli"), a.count > i + 2 {
            Task { @MainActor in await CLIRunner.run(url: a[i + 1], output: a[i + 2]) }
        }
    }

    var body: some Scene {
        WindowGroup("SiteCrawler") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1280, height: 780)
    }
}

enum Tone {
    case none, ok, info, warning, error

    var color: Color {
        switch self {
        case .none: .clear
        case .ok: Color.green.opacity(0.18)
        case .info: Color.blue.opacity(0.14)
        case .warning: Color.orange.opacity(0.28)
        case .error: Color.red.opacity(0.28)
        }
    }

    init(_ s: Severity?) {
        switch s {
        case .error?: self = .error
        case .warning?: self = .warning
        case .info?: self = .info
        case nil: self = .none
        }
    }
}

struct TCell: View {
    let text: String
    var tone: Tone = .none
    var body: some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tone.color)
    }
}

enum Tab: String, CaseIterable, Identifiable {
    case summary = "Сводка", pages = "Страницы", issues = "Проблемы", links = "Ссылки"
    var id: String { rawValue }
}

struct ContentView: View {
    @Environment(CrawlModel.self) private var model
    @State private var tab: Tab = .summary
    @State private var showSettings = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("https://example.com", text: $model.urlText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.start() }
                    .disabled(model.running)
                if model.running {
                    Button("Стоп") { model.stop() }
                        .keyboardShortcut(".", modifiers: .command)
                } else {
                    Button("Старт") { model.start() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent)
                }
                Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                    .help("Настройки обхода")
                    .sheet(isPresented: $showSettings) { SettingsView() }
                    .disabled(model.running)
                Menu {
                    Button("Полный отчёт XLSX (с подсветкой)") { model.exportXLSX() }
                    Divider()
                    Button("CSV: страницы") { model.exportCSV("pages") }
                    Button("CSV: проблемы") { model.exportCSV("issues") }
                    Button("CSV: ссылки") { model.exportCSV("links") }
                } label: { Label("Экспорт", systemImage: "square.and.arrow.up") }
                    .disabled(model.pages.isEmpty || model.running)
                    .fixedSize()
            }
            .padding(10)

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            Divider()
            Group {
                switch tab {
                case .summary: SummaryView()
                case .pages: PagesView()
                case .issues: IssuesView()
                case .links: LinksView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                if model.running { ProgressView().controlSize(.small) }
                Text(model.statusText).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text("Страниц: \(model.pages.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}

struct SettingsView: View {
    @Environment(CrawlModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        Form {
            Stepper("Максимум страниц: \(model.settings.maxPages)", value: $model.settings.maxPages, in: 1...100_000, step: 100)
            Stepper("Максимальная глубина: \(model.settings.maxDepth)", value: $model.settings.maxDepth, in: 1...50)
            Stepper("Потоков: \(model.settings.threads)", value: $model.settings.threads, in: 1...20)
            Stepper("Пауза между запросами: \(model.settings.delayMs) мс", value: $model.settings.delayMs, in: 0...5000, step: 100)
            Stepper("Таймаут: \(model.settings.timeout) с", value: $model.settings.timeout, in: 5...120, step: 5)
            Divider()
            Toggle("Учитывать robots.txt", isOn: $model.settings.respectRobots)
            Toggle("Использовать sitemap.xml", isOn: $model.settings.useSitemap)
            Toggle("Проверять внешние ссылки", isOn: $model.settings.checkExternal)
            Toggle("Рендерить JavaScript (медленнее)", isOn: $model.settings.renderJS)
            TextField("User-Agent", text: $model.settings.userAgent)
            HStack {
                Spacer()
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - Сводка

struct SummaryView: View {
    @Environment(CrawlModel.self) private var model

    var body: some View {
        if model.pages.isEmpty {
            ContentUnavailableView("Нет данных", systemImage: "globe",
                                   description: Text("Введите адрес сайта и нажмите «Старт»."))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        stat("Страниц", "\(model.pages.count)", .none)
                        stat("С ошибками", "\(model.pages.filter { $0.worst == 3 }.count)", .error)
                        stat("С предупреждениями", "\(model.pages.filter { $0.worst == 2 }.count)", .warning)
                        stat("Битых ссылок", "\(model.links.filter(\.isBroken).count)", .error)
                        stat("Ответ, мс", "\(model.averageMs)", .none)
                    }
                    if model.finished {
                        Text("Проблемы по типам").font(.headline)
                        if model.issueCounts.isEmpty {
                            Text("Проблем не найдено").foregroundStyle(.secondary)
                        }
                        VStack(spacing: 2) {
                            ForEach(model.issueCounts, id: \.0) { kind, count in
                                HStack {
                                    Text(kind.severity.title).frame(width: 130, alignment: .leading)
                                    Text(kind.title).frame(maxWidth: .infinity, alignment: .leading)
                                    Text("\(count)").monospacedDigit().frame(width: 70, alignment: .trailing)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Tone(kind.severity).color, in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                    } else {
                        Text("Полный анализ проблем появится после завершения обхода.").foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
        }
    }

    private func stat(_ title: String, _ value: String, _ tone: Tone) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 28, weight: .semibold)).monospacedDigit()
            Text(title).font(.callout).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.color.opacity(tone == .none ? 0 : 1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }
}

// MARK: - Страницы

struct PagesView: View {
    @Environment(CrawlModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\PageRecord.depth)]
    @State private var selection: String?
    @State private var search = ""
    @State private var filter = 0   // 0 все, 1 с проблемами, 2 только ошибки

    private var rows: [PageRecord] {
        var r = model.pages
        if filter == 1 { r = r.filter { $0.worst >= 2 } }
        if filter == 2 { r = r.filter { $0.worst == 3 } }
        if !search.isEmpty {
            r = r.filter { $0.url.localizedCaseInsensitiveContains(search) || $0.title.localizedCaseInsensitiveContains(search) }
        }
        return r.sorted(using: sortOrder)
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            HStack {
                TextField("Поиск по URL и Title", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Picker("", selection: $filter) {
                    Text("Все").tag(0)
                    Text("С предупреждениями и ошибками").tag(1)
                    Text("Только ошибки").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Text("Показано: \(rows.count)").foregroundStyle(.secondary)
            }
            .padding(8)

            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Код", value: \.status) { p in
                    TCell(text: p.statusLabel, tone: statusTone(p))
                }.width(min: 50, ideal: 55, max: 70)
                TableColumn("URL", value: \.url) { p in
                    TCell(text: p.url, tone: Tone(p.worst == 0 ? nil : Severity(rawValue: p.worst - 1)))
                }.width(min: 160, ideal: 260)
                TableColumn("Title", value: \.title) { p in
                    TCell(text: p.title, tone: Tone(p.severity(of: [.missingTitle, .titleTooLong, .titleTooShort, .duplicateTitle])))
                }.width(min: 100, ideal: 170)
                TableColumn("Description", value: \.description) { p in
                    TCell(text: p.description, tone: Tone(p.severity(of: [.missingDescription, .descriptionTooLong, .descriptionTooShort, .duplicateDescription])))
                }.width(min: 90, ideal: 150)
                TableColumn("H1", value: \.h1) { p in
                    TCell(text: p.h1, tone: Tone(p.severity(of: [.missingH1, .multipleH1, .duplicateH1])))
                }.width(min: 70, ideal: 110)
                TableColumn("Слов", value: \.words) { p in
                    TCell(text: "\(p.words)", tone: Tone(p.severity(of: [.thinContent])))
                }.width(min: 45, ideal: 50, max: 70)
                TableColumn("мс", value: \.ms) { p in
                    TCell(text: "\(p.ms)", tone: Tone(p.severity(of: [.slowResponse])))
                }.width(min: 45, ideal: 50, max: 70)
                TableColumn("Гл.", value: \.depth) { p in
                    TCell(text: "\(p.depth)", tone: Tone(p.severity(of: [.deepPage])))
                }.width(min: 32, ideal: 38, max: 50)
                TableColumn("Вх.", value: \.inlinks) { p in
                    TCell(text: "\(p.inlinks)", tone: Tone(p.severity(of: [.orphan])))
                }.width(min: 32, ideal: 38, max: 50)
                TableColumn("Пробл.", value: \.worst) { p in
                    TCell(text: p.issues.isEmpty ? "" : "\(p.errorCount) / \(p.warningCount) / \(p.issues.count - p.errorCount - p.warningCount)",
                          tone: Tone(p.worst == 0 ? nil : Severity(rawValue: p.worst - 1)))
                }.width(min: 70, ideal: 75, max: 100)
            }

            if let sel = selection, let p = model.pages.first(where: { $0.id == sel }) {
                Divider()
                PageDetail(page: p)
            }
        }
    }

    private func statusTone(_ p: PageRecord) -> Tone {
        if p.blockedByRobots { return .info }
        if p.status == 0 || p.status >= 400 { return .error }
        if p.status >= 300 { return .warning }
        return .ok
    }
}

struct PageDetail: View {
    let page: PageRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text(page.url).font(.headline).textSelection(.enabled)
                if !page.title.isEmpty { Text("Title: \(page.title)").textSelection(.enabled) }
                if !page.description.isEmpty { Text("Description: \(page.description)").textSelection(.enabled) }
                if !page.redirectTo.isEmpty { Text("Редирект на: \(page.redirectTo)").textSelection(.enabled) }
                if !page.canonical.isEmpty { Text("Canonical: \(page.canonical)").textSelection(.enabled) }
                if page.issues.isEmpty {
                    Text("Проблем не найдено").foregroundStyle(.secondary)
                }
                ForEach(Array(page.issues.enumerated()), id: \.offset) { _, i in
                    Text("\(i.kind.severity.title): \(i.message)")
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Tone(i.kind.severity).color, in: RoundedRectangle(cornerRadius: 4))
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 170)
    }
}

// MARK: - Проблемы

struct IssueRow: Identifiable {
    var id: Int
    var severity: Severity
    var kind: IssueKind
    var title: String
    var detail: String
    var url: String
    var rank: Int { severity.rawValue }
}

struct IssuesView: View {
    @Environment(CrawlModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\IssueRow.rank, order: .reverse)]
    @State private var search = ""
    @State private var minSeverity = 0   // 0 все, 1 предупр.+, 2 ошибки

    private var rows: [IssueRow] {
        var out: [IssueRow] = []
        var n = 0
        for p in model.pages {
            for i in p.issues where i.kind.severity.rawValue >= minSeverity {
                out.append(IssueRow(id: n, severity: i.kind.severity, kind: i.kind, title: i.kind.title, detail: i.detail, url: p.url))
                n += 1
            }
        }
        if !search.isEmpty {
            out = out.filter { $0.url.localizedCaseInsensitiveContains(search) || $0.title.localizedCaseInsensitiveContains(search) || $0.detail.localizedCaseInsensitiveContains(search) }
        }
        return out.sorted(using: sortOrder)
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            HStack {
                TextField("Поиск", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Picker("", selection: $minSeverity) {
                    Text("Все").tag(0)
                    Text("Предупреждения и ошибки").tag(1)
                    Text("Только ошибки").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Text("Показано: \(rows.count)").foregroundStyle(.secondary)
            }
            .padding(8)

            Table(rows, sortOrder: $sortOrder) {
                TableColumn("Важность", value: \.rank) { r in
                    TCell(text: r.severity.title, tone: Tone(r.severity))
                }.width(min: 90, ideal: 120, max: 140)
                TableColumn("Проблема", value: \.title) { r in
                    TCell(text: r.title, tone: Tone(r.severity))
                }.width(min: 200, ideal: 260)
                TableColumn("Детали", value: \.detail) { r in
                    TCell(text: r.detail, tone: Tone(r.severity))
                }.width(min: 120, ideal: 240)
                TableColumn("URL", value: \.url) { r in
                    TCell(text: r.url, tone: Tone(r.severity))
                }.width(min: 200, ideal: 400)
            }
        }
    }
}

// MARK: - Ссылки

struct LinksView: View {
    @Environment(CrawlModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\LinkRecord.status)]
    @State private var search = ""
    @State private var filter = 1   // 0 все, 1 битые, 2 внешние, 3 внутренние

    private var rows: [LinkRecord] {
        var r = model.links
        switch filter {
        case 1: r = r.filter(\.isBroken)
        case 2: r = r.filter { !$0.isInternal }
        case 3: r = r.filter(\.isInternal)
        default: break
        }
        if !search.isEmpty {
            r = r.filter { $0.to.localizedCaseInsensitiveContains(search) || $0.from.localizedCaseInsensitiveContains(search) || $0.anchor.localizedCaseInsensitiveContains(search) }
        }
        return r.sorted(using: sortOrder)
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            HStack {
                TextField("Поиск", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Picker("", selection: $filter) {
                    Text("Все").tag(0)
                    Text("Битые").tag(1)
                    Text("Внешние").tag(2)
                    Text("Внутренние").tag(3)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Text("Показано: \(rows.count) из \(model.links.count)").foregroundStyle(.secondary)
            }
            .padding(8)

            Table(rows, sortOrder: $sortOrder) {
                TableColumn("Код", value: \.status) { l in
                    TCell(text: l.statusLabel, tone: tone(l))
                }.width(min: 70, ideal: 90, max: 110)
                TableColumn("Куда", value: \.to) { l in
                    TCell(text: l.to, tone: l.isBroken ? .error : .none)
                }.width(min: 200, ideal: 360)
                TableColumn("Откуда", value: \.from) { l in
                    TCell(text: l.from)
                }.width(min: 200, ideal: 320)
                TableColumn("Анкор", value: \.anchor) { l in
                    TCell(text: l.anchor)
                }.width(min: 100, ideal: 180)
                TableColumn("Тип", value: \.kind) { l in
                    TCell(text: "\(l.kindLabel), \(l.scopeLabel.lowercased())")
                }.width(min: 120, ideal: 160)
            }
        }
    }

    private func tone(_ l: LinkRecord) -> Tone {
        if l.isBroken { return .error }
        switch l.status {
        case -2: return .none
        case -1: return .info
        case 300..<400: return .warning
        default: return .ok
        }
    }
}
