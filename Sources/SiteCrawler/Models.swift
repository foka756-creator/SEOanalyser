import Foundation

enum Severity: Int, Comparable, Sendable {
    case info = 0, warning = 1, error = 2

    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .info: "Инфо"
        case .warning: "Предупреждение"
        case .error: "Ошибка"
        }
    }
}

enum IssueKind: String, CaseIterable, Sendable {
    // ошибки
    case http4xx, http5xx, requestFailed, missingTitle, brokenLinks, sitemapBadStatus
    // предупреждения
    case redirect, missingDescription, missingH1, multipleH1
    case titleTooLong, titleTooShort, descriptionTooLong, descriptionTooShort
    case duplicateTitle, duplicateDescription, duplicateH1
    case imagesNoAlt, slowResponse, canonicalOther, noindexInSitemap
    // информация
    case noindex, blockedByRobots, thinContent, deepPage, orphan, missingCanonical

    var severity: Severity {
        switch self {
        case .http4xx, .http5xx, .requestFailed, .missingTitle, .brokenLinks, .sitemapBadStatus:
            return .error
        case .redirect, .missingDescription, .missingH1, .multipleH1,
             .titleTooLong, .titleTooShort, .descriptionTooLong, .descriptionTooShort,
             .duplicateTitle, .duplicateDescription, .duplicateH1,
             .imagesNoAlt, .slowResponse, .canonicalOther, .noindexInSitemap:
            return .warning
        case .noindex, .blockedByRobots, .thinContent, .deepPage, .orphan, .missingCanonical:
            return .info
        }
    }

    var title: String {
        switch self {
        case .http4xx: "Ошибка 4xx (страница недоступна)"
        case .http5xx: "Ошибка сервера 5xx"
        case .requestFailed: "Страница не загрузилась"
        case .missingTitle: "Нет Title"
        case .brokenLinks: "Битые ссылки на странице"
        case .sitemapBadStatus: "URL из sitemap отдаёт не 200"
        case .redirect: "Редирект"
        case .missingDescription: "Нет Description"
        case .missingH1: "Нет H1"
        case .multipleH1: "Несколько H1"
        case .titleTooLong: "Title длиннее 60 символов"
        case .titleTooShort: "Title короче 20 символов"
        case .descriptionTooLong: "Description длиннее 160 символов"
        case .descriptionTooShort: "Description короче 50 символов"
        case .duplicateTitle: "Дубль Title"
        case .duplicateDescription: "Дубль Description"
        case .duplicateH1: "Дубль H1"
        case .imagesNoAlt: "Изображения без alt"
        case .slowResponse: "Медленный ответ (больше 2 с)"
        case .canonicalOther: "Canonical указывает на другой URL"
        case .noindexInSitemap: "noindex, но URL есть в sitemap"
        case .noindex: "Закрыта от индексации (noindex)"
        case .blockedByRobots: "Запрещена в robots.txt"
        case .thinContent: "Мало текста (меньше 150 слов)"
        case .deepPage: "Глубокая вложенность (больше 5)"
        case .orphan: "Нет входящих ссылок (только sitemap)"
        case .missingCanonical: "Нет canonical"
        }
    }
}

struct Issue: Hashable, Sendable {
    var kind: IssueKind
    var detail: String = ""

    var message: String { detail.isEmpty ? kind.title : "\(kind.title): \(detail)" }
}

struct PageRecord: Identifiable, Sendable {
    var url: String
    var id: String { url }
    var status = 0
    var contentType = ""
    var depth = 0
    var title = ""
    var description = ""
    var h1 = ""
    var h1Count = 0
    var h2Count = 0
    var canonical = ""
    var robotsMeta = ""
    var words = 0
    var ms = 0
    var bytes = 0
    var inlinks = 0
    var redirectTo = ""
    var error = ""
    var blockedByRobots = false
    var inSitemap = false
    var imgNoAlt = 0
    var issues: [Issue] = []

    var isHTML: Bool { contentType.lowercased().contains("html") }
    var isOK: Bool { (200..<300).contains(status) }
    var titleLength: Int { title.count }
    var descriptionLength: Int { description.count }

    /// 0 — нет проблем, 1 — инфо, 2 — предупреждения, 3 — ошибки
    var worst: Int { (issues.map { $0.kind.severity.rawValue }.max() ?? -1) + 1 }
    var errorCount: Int { issues.filter { $0.kind.severity == .error }.count }
    var warningCount: Int { issues.filter { $0.kind.severity == .warning }.count }

    var statusLabel: String {
        if blockedByRobots { return "robots" }
        return status == 0 ? "ошибка" : String(status)
    }

    func severity(of kinds: Set<IssueKind>) -> Severity? {
        issues.filter { kinds.contains($0.kind) }.map { $0.kind.severity }.max()
    }
}

struct LinkRecord: Identifiable, Sendable {
    var id: Int
    var from: String
    var to: String
    var anchor: String
    var kind: String          // "a" или "img"
    var isInternal: Bool
    var nofollow: Bool
    /// -2 не проверена, -1 закрыта robots.txt, 0 ошибка запроса, иначе HTTP-код
    var status = -2

    var isBroken: Bool { status == 0 || status >= 400 }
    var statusLabel: String {
        switch status {
        case -2: "не проверена"
        case -1: "robots"
        case 0: "ошибка"
        default: String(status)
        }
    }
    var kindLabel: String { kind == "img" ? "Картинка" : "Ссылка" }
    var scopeLabel: String { isInternal ? "Внутренняя" : "Внешняя" }
}

struct CrawlSettings: Sendable {
    var maxPages = 500
    var maxDepth = 10
    var threads = 5
    var delayMs = 0
    var timeout = 20
    var respectRobots = true
    var useSitemap = true
    var renderJS = false
    var checkExternal = true
    var userAgent = "SiteCrawler/1.0 (macOS)"
}

struct CrawlOutput: Sendable {
    var pages: [PageRecord]
    var links: [LinkRecord]
    var cancelled: Bool
}
