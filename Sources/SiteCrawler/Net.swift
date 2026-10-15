import Foundation

struct FetchResult: Sendable {
    var status = 0
    var contentType = ""
    var location = ""
    var xRobots = ""
    var textEncoding: String?
    var body: Data?
    var ms = 0
    var bytes = 0
    var error = ""
}

/// HTTP-клиент: `noRedirect` отдаёт 3xx как есть (для учёта редиректов), `follow` идёт по редиректам.
final class Net: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private var noRedirect: URLSession!
    private var follow: URLSession!
    private let ua: String

    init(userAgent: String, timeout: Int, connections: Int) {
        ua = userAgent
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = TimeInterval(timeout)
        cfg.timeoutIntervalForResource = TimeInterval(timeout * 3)
        cfg.httpMaximumConnectionsPerHost = max(connections, 4)
        cfg.httpAdditionalHeaders = ["Accept-Language": "ru,en;q=0.8"]
        noRedirect = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        follow = URLSession(configuration: cfg)
    }

    deinit {
        noRedirect?.invalidateAndCancel()
        follow?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    private func request(_ url: URL, method: String = "GET") -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue(ua, forHTTPHeaderField: "User-Agent")
        r.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        return r
    }

    static func describe(_ error: Error) -> String {
        guard let e = error as? URLError else { return error.localizedDescription }
        switch e.code {
        case .timedOut: return "Таймаут"
        case .cannotFindHost: return "Домен не найден"
        case .cannotConnectToHost: return "Нет соединения с хостом"
        case .networkConnectionLost: return "Соединение прервано"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected: return "Ошибка SSL"
        case .notConnectedToInternet: return "Нет интернета"
        default: return e.localizedDescription
        }
    }

    /// Загружает страницу; тело читает только для успешных HTML-ответов.
    func fetchPage(_ url: URL, maxBytes: Int = 5_000_000) async -> FetchResult {
        var r = FetchResult()
        let start = Date()
        do {
            let (bytes, resp) = try await noRedirect.bytes(for: request(url))
            r.ms = Int(Date().timeIntervalSince(start) * 1000)
            guard let http = resp as? HTTPURLResponse else { r.error = "Не HTTP-ответ"; return r }
            r.status = http.statusCode
            r.contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            r.location = http.value(forHTTPHeaderField: "Location") ?? ""
            r.xRobots = http.value(forHTTPHeaderField: "X-Robots-Tag") ?? ""
            r.textEncoding = http.textEncodingName
            if (200..<300).contains(r.status), r.contentType.lowercased().contains("html") {
                var data = Data()
                for try await b in bytes {
                    data.append(b)
                    if data.count >= maxBytes { break }
                }
                r.body = data
                r.bytes = data.count
            } else {
                r.bytes = Int(http.expectedContentLength > 0 ? http.expectedContentLength : 0)
                bytes.task.cancel()
            }
        } catch {
            r.ms = Int(Date().timeIntervalSince(start) * 1000)
            r.error = Net.describe(error)
        }
        return r
    }

    /// Для robots.txt и sitemap: с редиректами, возвращает тело и код.
    func fetchData(_ s: String) async -> (Data, Int)? {
        guard let url = URL(string: s) else { return nil }
        guard let (data, resp) = try? await follow.data(for: request(url)),
              let http = resp as? HTTPURLResponse else { return nil }
        return (data, http.statusCode)
    }

    /// Проверка ссылки: HEAD, при ошибке — GET. 0 = запрос не удался.
    func check(_ s: String) async -> Int {
        guard let url = URL(string: s) else { return 0 }
        if let (_, resp) = try? await follow.data(for: request(url, method: "HEAD")),
           let http = resp as? HTTPURLResponse, http.statusCode < 400 {
            return http.statusCode
        }
        if Task.isCancelled { return 0 }
        do {
            let (bytes, resp) = try await follow.bytes(for: request(url))
            bytes.task.cancel()
            return (resp as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            return 0
        }
    }
}
