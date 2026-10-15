import Foundation
import WebKit

/// Рендер страниц через WKWebView (для сайтов на JS). Страницы обрабатываются по одной.
@MainActor
final class JSRenderer: NSObject, WKNavigationDelegate {
    static let shared = JSRenderer()

    private var web: WKWebView?
    private var cont: CheckedContinuation<Bool, Never>?
    private var timer: Task<Void, Never>?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    func render(url: URL, userAgent: String, timeout: Int) async -> String? {
        await acquire()
        defer { release() }
        let wv: WKWebView
        if let w = web { wv = w } else {
            wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: WKWebViewConfiguration())
            wv.navigationDelegate = self
            web = wv
        }
        wv.customUserAgent = userAgent
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            cont = c
            timer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
                self?.finish(false)
            }
            wv.load(URLRequest(url: url))
        }
        guard ok else { return nil }
        try? await Task.sleep(nanoseconds: 800_000_000)   // дать скриптам дорисовать DOM
        return try? await wv.evaluateJavaScript("document.documentElement.outerHTML") as? String
    }

    private func finish(_ ok: Bool) {
        timer?.cancel()
        timer = nil
        if let c = cont {
            cont = nil
            if !ok { web?.stopLoading() }
            c.resume(returning: ok)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
}
