import Foundation

// MARK: - Таблицы отчёта

struct RCell {
    var text: String
    var style: Int = 0          // 0 обычная, 1 заголовок, 2 ошибка, 3 предупреждение, 4 инфо, 5 ок
    var num: Double? = nil
}

struct ReportTable {
    var name: String
    var headers: [String]
    var widths: [Double]
    var rows: [[RCell]]
    var filter = true
}

enum Report {
    static func style(_ s: Severity?) -> Int {
        switch s {
        case .error?: 2
        case .warning?: 3
        case .info?: 4
        case nil: 0
        }
    }

    static func statusStyle(_ p: PageRecord) -> Int {
        if p.blockedByRobots { return 4 }
        if p.status == 0 || p.status >= 400 { return 2 }
        if p.status >= 300 { return 3 }
        return 5
    }

    static func pages(_ pages: [PageRecord]) -> ReportTable {
        let titleKinds: Set<IssueKind> = [.missingTitle, .titleTooLong, .titleTooShort, .duplicateTitle]
        let descKinds: Set<IssueKind> = [.missingDescription, .descriptionTooLong, .descriptionTooShort, .duplicateDescription]
        let h1Kinds: Set<IssueKind> = [.missingH1, .multipleH1, .duplicateH1]
        let rows: [[RCell]] = pages.map { p in
            let worst: Severity? = p.worst == 0 ? nil : Severity(rawValue: p.worst - 1)
            return [
                RCell(text: p.url, style: style(worst)),
                RCell(text: p.statusLabel, style: statusStyle(p), num: p.status > 0 && !p.blockedByRobots ? Double(p.status) : nil),
                RCell(text: p.contentType),
                RCell(text: "\(p.depth)", num: Double(p.depth)),
                RCell(text: p.title, style: style(p.severity(of: titleKinds))),
                RCell(text: "\(p.titleLength)", num: Double(p.titleLength)),
                RCell(text: p.description, style: style(p.severity(of: descKinds))),
                RCell(text: "\(p.descriptionLength)", num: Double(p.descriptionLength)),
                RCell(text: p.h1, style: style(p.severity(of: h1Kinds))),
                RCell(text: "\(p.h1Count)", num: Double(p.h1Count)),
                RCell(text: "\(p.h2Count)", num: Double(p.h2Count)),
                RCell(text: p.canonical, style: style(p.severity(of: [.canonicalOther]))),
                RCell(text: p.robotsMeta, style: style(p.severity(of: [.noindex]))),
                RCell(text: "\(p.words)", num: Double(p.words)),
                RCell(text: "\(p.ms)", style: style(p.severity(of: [.slowResponse])), num: Double(p.ms)),
                RCell(text: "\(p.bytes)", num: Double(p.bytes)),
                RCell(text: "\(p.inlinks)", num: Double(p.inlinks)),
                RCell(text: p.inSitemap ? "да" : "нет"),
                RCell(text: p.redirectTo),
                RCell(text: "\(p.errorCount)", style: p.errorCount > 0 ? 2 : 0, num: Double(p.errorCount)),
                RCell(text: "\(p.warningCount)", style: p.warningCount > 0 ? 3 : 0, num: Double(p.warningCount)),
                RCell(text: p.issues.map(\.message).joined(separator: "; "), style: style(worst)),
            ]
        }
        return ReportTable(
            name: "Страницы",
            headers: ["URL", "Код", "Тип", "Глубина", "Title", "Длина Title", "Description", "Длина Desc", "H1", "Кол-во H1",
                      "H2", "Canonical", "Robots meta", "Слов", "Ответ, мс", "Размер, Б", "Входящих", "В sitemap",
                      "Редирект на", "Ошибок", "Предупр.", "Проблемы"],
            widths: [50, 8, 16, 9, 40, 11, 40, 11, 30, 10, 6, 30, 14, 8, 10, 10, 10, 10, 30, 8, 9, 60],
            rows: rows)
    }

    static func issues(_ pages: [PageRecord]) -> ReportTable {
        var rows: [[RCell]] = []
        let all = pages.flatMap { p in p.issues.map { (p, $0) } }
            .sorted { ($0.1.kind.severity, $0.1.kind.rawValue) > ($1.1.kind.severity, $1.1.kind.rawValue) }
        for (p, i) in all {
            let st = style(i.kind.severity)
            rows.append([RCell(text: i.kind.severity.title, style: st), RCell(text: i.kind.title, style: st),
                         RCell(text: i.detail, style: st), RCell(text: p.url, style: st)])
        }
        return ReportTable(name: "Проблемы", headers: ["Важность", "Проблема", "Детали", "URL"],
                           widths: [16, 40, 50, 60], rows: rows)
    }

    static func links(_ links: [LinkRecord]) -> ReportTable {
        let rows: [[RCell]] = links.map { l in
            let st = l.isBroken ? 2 : (l.status == -2 ? 0 : (l.status == -1 ? 4 : (l.status >= 300 ? 3 : 5)))
            return [RCell(text: l.from), RCell(text: l.to, style: l.isBroken ? 2 : 0), RCell(text: l.anchor),
                    RCell(text: l.kindLabel), RCell(text: l.scopeLabel), RCell(text: l.nofollow ? "nofollow" : ""),
                    RCell(text: l.statusLabel, style: st, num: l.status > 0 ? Double(l.status) : nil)]
        }
        return ReportTable(name: "Ссылки", headers: ["Откуда", "Куда", "Анкор", "Тип", "Область", "Атрибут", "Код"],
                           widths: [50, 60, 30, 11, 12, 10, 12], rows: rows)
    }

    @MainActor
    static func summary(_ m: CrawlModel) -> ReportTable {
        var rows: [[RCell]] = []
        func row(_ a: String, _ b: String, _ s: Int = 0) { rows.append([RCell(text: a, style: s), RCell(text: b, style: s), RCell(text: "")]) }
        row("Сайт", m.siteHost)
        row("Страниц проверено", "\(m.pages.count)")
        row("Страниц с ошибками", "\(m.pages.filter { $0.worst == 3 }.count)", 2)
        row("Страниц с предупреждениями", "\(m.pages.filter { $0.worst == 2 }.count)", 3)
        row("Битых ссылок", "\(m.links.filter(\.isBroken).count)", 2)
        row("Всего ссылок", "\(m.links.count)")
        row("Среднее время ответа, мс", "\(m.averageMs)")
        rows.append([RCell(text: ""), RCell(text: ""), RCell(text: "")])
        rows.append([RCell(text: "Проблема", style: 1), RCell(text: "Важность", style: 1), RCell(text: "Страниц", style: 1)])
        for (kind, count) in m.issueCounts {
            let st = style(kind.severity)
            rows.append([RCell(text: kind.title, style: st), RCell(text: kind.severity.title, style: st),
                         RCell(text: "\(count)", style: st, num: Double(count))])
        }
        return ReportTable(name: "Сводка", headers: ["Показатель", "Значение", ""], widths: [45, 40, 12], rows: rows, filter: false)
    }
}

// MARK: - CSV

enum CSVWriter {
    static func data(_ t: ReportTable) -> Data {
        func esc(_ s: String) -> String {
            s.contains(where: { $0 == ";" || $0 == "\"" || $0 == "\n" || $0 == "\r" })
                ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        var out = "\u{FEFF}" + t.headers.map(esc).joined(separator: ";") + "\r\n"
        for r in t.rows { out += r.map { esc($0.text) }.joined(separator: ";") + "\r\n" }
        return Data(out.utf8)
    }
}

// MARK: - XLSX (минимальный writer без внешних зависимостей)

private extension Data {
    mutating func u16(_ v: UInt16) { append(UInt8(v & 0xff)); append(UInt8(v >> 8)) }
    mutating func u32(_ v: UInt32) { u16(UInt16(v & 0xffff)); u16(UInt16(v >> 16)) }
}

private enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in d { c = table[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

private struct ZipWriter {
    var out = Data()
    var central = Data()
    var count: UInt16 = 0

    mutating func add(_ name: String, _ text: String) {
        let data = Data(text.utf8)
        let nameData = Data(name.utf8)
        let crc = CRC32.checksum(data)
        let offset = UInt32(out.count)
        out.u32(0x04034b50); out.u16(20); out.u16(0x0800); out.u16(0); out.u16(0); out.u16(0x21)
        out.u32(crc); out.u32(UInt32(data.count)); out.u32(UInt32(data.count))
        out.u16(UInt16(nameData.count)); out.u16(0)
        out.append(nameData); out.append(data)

        central.u32(0x02014b50); central.u16(20); central.u16(20); central.u16(0x0800); central.u16(0)
        central.u16(0); central.u16(0x21)
        central.u32(crc); central.u32(UInt32(data.count)); central.u32(UInt32(data.count))
        central.u16(UInt16(nameData.count)); central.u16(0); central.u16(0); central.u16(0); central.u16(0)
        central.u32(0); central.u32(offset)
        central.append(nameData)
        count += 1
    }

    mutating func finish() -> Data {
        let cdOffset = UInt32(out.count)
        out.append(central)
        out.u32(0x06054b50); out.u16(0); out.u16(0); out.u16(count); out.u16(count)
        out.u32(UInt32(central.count)); out.u32(cdOffset); out.u16(0)
        return out
    }
}

enum XLSXWriter {
    private static func esc(_ s: String) -> String {
        var r = ""
        r.reserveCapacity(s.count)
        for u in s.unicodeScalars {
            switch u {
            case "&": r += "&amp;"
            case "<": r += "&lt;"
            case ">": r += "&gt;"
            case "\"": r += "&quot;"
            default:
                if u.value >= 0x20 || u == "\t" || u == "\n" || u == "\r" { r.unicodeScalars.append(u) }
            }
        }
        return r
    }

    private static func col(_ i: Int) -> String {
        var n = i + 1
        var s = ""
        while n > 0 { n -= 1; s = String(UnicodeScalar(UInt8(65 + n % 26))) + s; n /= 26 }
        return s
    }

    private static func sheetXML(_ t: ReportTable) -> String {
        var x = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
        x += "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews><cols>"
        for (i, w) in t.widths.enumerated() { x += "<col min=\"\(i + 1)\" max=\"\(i + 1)\" width=\"\(w)\" customWidth=\"1\"/>" }
        x += "</cols><sheetData>"
        func put(_ c: RCell, _ r: Int, _ ci: Int) {
            let ref = "\(col(ci))\(r)"
            if let n = c.num { x += "<c r=\"\(ref)\" s=\"\(c.style)\"><v>\(n)</v></c>" }
            else if c.text.isEmpty { x += "<c r=\"\(ref)\" s=\"\(c.style)\"/>" }
            else { x += "<c r=\"\(ref)\" s=\"\(c.style)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(esc(c.text))</t></is></c>" }
        }
        x += "<row r=\"1\">"
        for (i, h) in t.headers.enumerated() { put(RCell(text: h, style: 1), 1, i) }
        x += "</row>"
        for (ri, row) in t.rows.enumerated() {
            x += "<row r=\"\(ri + 2)\">"
            for (ci, c) in row.enumerated() { put(c, ri + 2, ci) }
            x += "</row>"
        }
        x += "</sheetData>"
        if t.filter, !t.rows.isEmpty { x += "<autoFilter ref=\"A1:\(col(t.headers.count - 1))\(t.rows.count + 1)\"/>" }
        return x + "</worksheet>"
    }

    private static let styles: String = {
        func fill(_ rgb: String) -> String { "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"FF\(rgb)\"/><bgColor indexed=\"64\"/></patternFill></fill>" }
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
        s += "<fonts count=\"2\"><font><sz val=\"11\"/><name val=\"Calibri\"/></font><font><b/><sz val=\"11\"/><color rgb=\"FFFFFFFF\"/><name val=\"Calibri\"/></font></fonts>"
        s += "<fills count=\"7\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill>"
        s += fill("305496") + fill("FFC7CE") + fill("FFEB9C") + fill("DDEBF7") + fill("C6EFCE") + "</fills>"
        s += "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"
        s += "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs><cellXfs count=\"6\">"
        s += "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>"
        s += "<xf numFmtId=\"0\" fontId=\"1\" fillId=\"2\" borderId=\"0\" xfId=\"0\" applyFont=\"1\" applyFill=\"1\"/>"
        for f in 3...6 { s += "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"\(f)\" borderId=\"0\" xfId=\"0\" applyFill=\"1\"/>" }
        s += "</cellXfs><cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles></styleSheet>"
        return s
    }()

    static func build(_ sheets: [ReportTable]) -> Data {
        var z = ZipWriter()
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let decl = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"

        var ct = decl + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        ct += "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
        ct += "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        for i in sheets.indices { ct += "<Override PartName=\"/xl/worksheets/sheet\(i + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>" }
        z.add("[Content_Types].xml", ct + "</Types>")

        z.add("_rels/.rels", decl + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(rel)/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>")

        var wb = decl + "<workbook xmlns=\"\(main)\" xmlns:r=\"\(rel)\"><sheets>"
        var wbRels = decl + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        for (i, s) in sheets.enumerated() {
            wb += "<sheet name=\"\(esc(s.name))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
            wbRels += "<Relationship Id=\"rId\(i + 1)\" Type=\"\(rel)/worksheet\" Target=\"worksheets/sheet\(i + 1).xml\"/>"
        }
        wbRels += "<Relationship Id=\"rId\(sheets.count + 1)\" Type=\"\(rel)/styles\" Target=\"styles.xml\"/></Relationships>"
        z.add("xl/workbook.xml", wb + "</sheets></workbook>")
        z.add("xl/_rels/workbook.xml.rels", wbRels)
        z.add("xl/styles.xml", styles)
        for (i, s) in sheets.enumerated() { z.add("xl/worksheets/sheet\(i + 1).xml", sheetXML(s)) }
        return z.finish()
    }
}
