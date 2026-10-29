import AetherFoundation

/// 编辑操作（docs/04 §15.2）：表单编辑通过这些操作完成，只改动目标行；新增行使用规范格式与文档的换行风格。
extension ProfileDocument {
    public enum EditError: Error, Equatable, Sendable {
        case lineNotFound(LineID)
        case notAnEntry(LineID)
        case differentSection
        case invalidRaw(String)
    }

    /// 更新条目的值，保留行首缩进与 `键 =` 部分的原样书写。
    public mutating func updateEntry(id: LineID, newValue: String) throws {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { throw EditError.lineNotFound(id) }
        guard case .entry(let entry) = lines[index].kind else { throw EditError.notAnEntry(id) }
        let scalars = Array(lines[index].raw.unicodeScalars)
        let prefixLength = max(0, min(entry.valueColumn - 1, scalars.count))
        let prefix = String(String.UnicodeScalarView(scalars[..<prefixLength]))
        try replaceLine(at: index, raw: prefix + newValue)
    }

    /// 用新的原文替换一行（必须仍是同一节内的条目）。
    public mutating func replaceEntry(id: LineID, raw: String) throws {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { throw EditError.lineNotFound(id) }
        guard case .entry = lines[index].kind else { throw EditError.notAnEntry(id) }
        try replaceLine(at: index, raw: raw)
    }

    /// 在节内插入一条条目。
    /// - Parameters:
    ///   - section: 目标节；不存在时在文末追加节标题。
    ///   - after: 插在该行之后；为 nil 时插在该节最后一行内容之后。
    ///   - raw: 条目原文，键值节用 `键 = 值`。
    /// - Returns: 新行的 ID。
    @discardableResult
    public mutating func insertEntry(in section: ProfileSection, after: LineID? = nil, raw: String) throws -> LineID {
        guard !raw.contains("\n"), !raw.contains("\r") else { throw EditError.invalidRaw(raw) }
        let kind = classifyForEdit(raw, section: section.rawValue)
        guard case .entry = kind else { throw EditError.invalidRaw(raw) }
        var anchor: Int?
        if let after {
            guard let index = lines.firstIndex(where: { $0.id == after }) else { throw EditError.lineNotFound(after) }
            guard lines[index].sectionName == section.rawValue else { throw EditError.differentSection }
            anchor = index
        }
        let id = LineID(nextLineID)
        nextLineID += 1
        let ending = lineEnding.rawValue
        preservingFinalNewline { document in
            let position: Int
            if let anchor {
                position = anchor + 1
            } else if let last = document.lastContentIndex(of: section) {
                position = last + 1
            } else {
                document.appendSectionHeader(section)
                position = document.lines.count
            }
            document.lines.insert(
                ProfileLine(
                    id: id, raw: raw, terminator: ending, kind: kind, sectionName: section.rawValue, lineNumber: 0),
                at: position)
        }
        return id
    }

    /// 删除一条条目。
    public mutating func removeEntry(id: LineID) throws {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { throw EditError.lineNotFound(id) }
        guard case .entry = lines[index].kind else { throw EditError.notAnEntry(id) }
        preservingFinalNewline { document in
            document.lines.remove(at: index)
        }
    }

    /// 在同一节内移动条目：放到 `after` 之后；`after` 为 nil 时放到该节第一条条目之前。
    public mutating func moveEntry(id: LineID, after: LineID?) throws {
        guard let from = lines.firstIndex(where: { $0.id == id }) else { throw EditError.lineNotFound(id) }
        guard case .entry = lines[from].kind else { throw EditError.notAnEntry(id) }
        let section = lines[from].sectionName
        if let after {
            guard let anchor = lines.firstIndex(where: { $0.id == after }) else { throw EditError.lineNotFound(after) }
            guard lines[anchor].sectionName == section, after != id else { throw EditError.differentSection }
        }
        preservingFinalNewline { document in
            let line = document.lines.remove(at: from)
            let target: Int
            if let after, let anchor = document.lines.firstIndex(where: { $0.id == after }) {
                target = anchor + 1
            } else {
                target =
                    document.lines.firstIndex {
                        guard case .entry = $0.kind else { return false }
                        return $0.sectionName == section
                    } ?? from
            }
            document.lines.insert(line, at: min(target, document.lines.count))
        }
    }

    /// 执行结构性编辑，并保持"文档是否以换行结尾"不变：编辑期间所有行都带换行符，结束后按原状态处理最后一行。
    private mutating func preservingFinalNewline(_ edit: (inout ProfileDocument) -> Void) {
        let endsWithoutNewline = lines.last?.terminator.isEmpty ?? false
        if endsWithoutNewline, let last = lines.indices.last {
            lines[last].terminator = lineEnding.rawValue
        }
        edit(&self)
        if endsWithoutNewline, let last = lines.indices.last {
            lines[last].terminator = ""
        }
        renumber()
    }

    // MARK: - 内部

    private mutating func replaceLine(at index: Int, raw: String) throws {
        guard !raw.contains("\n"), !raw.contains("\r") else { throw EditError.invalidRaw(raw) }
        let kind = classifyForEdit(raw, section: lines[index].sectionName)
        guard case .entry = kind else { throw EditError.invalidRaw(raw) }
        lines[index].raw = raw
        lines[index].kind = kind
    }

    private func classifyForEdit(_ raw: String, section: String?) -> ProfileLineKind {
        ProfileDocument.classify(raw, section: section, seenContent: true, file: fileName, line: 0).0
    }

    /// 该节（同名节合并）最后一行非空内容的下标。
    private func lastContentIndex(of section: ProfileSection) -> Int? {
        lines.lastIndex {
            guard $0.sectionName == section.rawValue else { return false }
            switch $0.kind {
            case .entry, .comment, .invalid, .sectionHeader: return true
            default: return false
            }
        }
    }

    private mutating func appendSectionHeader(_ section: ProfileSection) {
        let name = Self.canonicalSectionName(section)
        let id = LineID(nextLineID)
        nextLineID += 1
        if let last = lines.last, last.kind != .blank {
            lines.append(
                ProfileLine(
                    id: LineID(nextLineID), raw: "", terminator: lineEnding.rawValue, kind: .blank,
                    sectionName: last.sectionName, lineNumber: 0))
            nextLineID += 1
        }
        lines.append(
            ProfileLine(
                id: id, raw: "[\(name)]", terminator: lineEnding.rawValue, kind: .sectionHeader(name: name),
                sectionName: section.rawValue, lineNumber: 0))
    }

    private mutating func renumber() {
        for index in lines.indices {
            lines[index].lineNumber = index + 1
        }
    }

    static func canonicalSectionName(_ section: ProfileSection) -> String {
        switch section {
        case .general: return "General"
        case .proxy: return "Proxy"
        case .proxyGroup: return "Proxy Group"
        case .rule: return "Rule"
        case .host: return "Host"
        case .urlRewrite: return "URL Rewrite"
        case .headerRewrite: return "Header Rewrite"
        case .bodyRewrite: return "Body Rewrite"
        case .mapLocal: return "Map Local"
        case .script: return "Script"
        case .mitm: return "MITM"
        }
    }
}
