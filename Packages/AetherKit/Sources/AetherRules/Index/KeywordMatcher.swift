/// 域名关键字匹配（docs/05 §4.1）：≤ 32 个关键字时线性查找，否则 Aho-Corasick。返回命中关键字中的最小值。
public struct KeywordMatcher: Sendable {
    static let linearLimit = 32

    private enum Storage: Sendable {
        case linear([(keyword: [UInt8], value: Int)])
        case automaton(AhoCorasick)
    }

    private let storage: Storage
    public let count: Int
    /// 原始关键字（写入编译缓存）。
    let keywords: [(keyword: String, value: Int)]

    public init(_ keywords: [(keyword: String, value: Int)]) {
        count = keywords.count
        self.keywords = keywords
        if keywords.count <= Self.linearLimit {
            storage = .linear(keywords.map { (Array($0.keyword.utf8), $0.value) })
        } else {
            storage = .automaton(AhoCorasick(keywords.map { (Array($0.keyword.utf8), $0.value) }))
        }
    }

    public func match(_ text: String) -> Int? {
        switch storage {
        case .linear(let keywords):
            let bytes = Array(text.utf8)
            var best: Int?
            for (keyword, value) in keywords where best.map({ value < $0 }) ?? true {
                if contains(bytes, keyword) { best = value }
            }
            return best
        case .automaton(let automaton):
            return automaton.minimumMatch(in: text.utf8)
        }
    }

    private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        guard needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            var matched = true
            for offset in 0..<needle.count where haystack[start + offset] != needle[offset] {
                matched = false
                break
            }
            if matched { return true }
        }
        return false
    }
}

/// 字节级 Aho-Corasick 自动机。每个状态预先计算沿失败链可达的最小输出值。
struct AhoCorasick: Sendable {
    private var transitions: [[UInt8: Int32]] = [[:]]
    private var fail: [Int32] = [0]
    private var output: [Int32] = [.max]

    init(_ patterns: [(pattern: [UInt8], value: Int)]) {
        for (pattern, value) in patterns {
            var state = 0
            for byte in pattern {
                if let next = transitions[state][byte] {
                    state = Int(next)
                } else {
                    transitions.append([:])
                    fail.append(0)
                    output.append(.max)
                    let next = transitions.count - 1
                    transitions[state][byte] = Int32(next)
                    state = next
                }
            }
            output[state] = min(output[state], Int32(clamping: value))
        }
        // 广度优先构建失败链。
        var queue: [Int] = []
        for (_, next) in transitions[0] {
            queue.append(Int(next))
        }
        var head = 0
        while head < queue.count {
            let state = queue[head]
            head += 1
            for (byte, nextValue) in transitions[state] {
                let next = Int(nextValue)
                queue.append(next)
                var f = Int(fail[state])
                while f != 0, transitions[f][byte] == nil {
                    f = Int(fail[f])
                }
                let target = transitions[f][byte].map(Int.init) ?? 0
                fail[next] = Int32(target == next ? 0 : target)
                output[next] = min(output[next], output[Int(fail[next])])
            }
        }
    }

    func minimumMatch(in bytes: some Sequence<UInt8>) -> Int? {
        var state = 0
        var best = output[0]
        for byte in bytes {
            while state != 0, transitions[state][byte] == nil {
                state = Int(fail[state])
            }
            state = transitions[state][byte].map(Int.init) ?? 0
            best = min(best, output[state])
        }
        return best == .max ? nil : Int(best)
    }
}
