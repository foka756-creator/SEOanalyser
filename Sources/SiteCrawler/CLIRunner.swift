import Foundation

@MainActor
enum CLIRunner {
    static func run(url: String, output: String) async {
        let model = CrawlModel()
        model.urlText = url
        model.settings.renderJS = CommandLine.arguments.contains("--js")
        model.start()
        guard model.running else {
            print(model.statusText)
            exit(2)
        }
        while model.running { try? await Task.sleep(nanoseconds: 200_000_000) }
        print(model.statusText)
        for (kind, count) in model.issueCounts { print("\(kind.severity.title)\t\(count)\t\(kind.title)") }
        do {
            try model.xlsxData().write(to: URL(fileURLWithPath: output))
            print("Отчёт: \(output)")
            exit(0)
        } catch {
            print("Не удалось записать отчёт: \(error.localizedDescription)")
            exit(1)
        }
    }
}
