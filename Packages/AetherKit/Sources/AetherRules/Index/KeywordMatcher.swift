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

/// 字节级 Aho-Corasick 自动机，转移以 CSR 形式紧凑存储（每个状态的出边按字节排序，连续存放）。
/// 每个状态预先计算沿失败链可达的最小输出值。内存约为"状态数 × 12 字节 + 边数 × 5 字节"。
struct AhoCorasick: Sendable {
    private var edgeStart: [Int32] = []  // 状态 i 的出边为 [edgeStart[i], edgeStart[i+1])
    private var edgeBytes: [UInt8] = []
    private var edgeTargets: [Int32] = []
    private var fail: [Int32] = []
    private var output: [Int32] = []

    init(_ patterns: [(pattern: [UInt8], value: Int)]) {
        // 先用临时的字典 trie 构建，再压缩为 CSR。
        var trie: [[UInt8: Int32]] = [[:]]
        var out: [Int32] = [.max]
        for (pattern, value) in patterns {
            var state = 0
            for byte in pattern {
                if let next = trie[state][byte] {
                    state = Int(next)
                } else {
                    trie.append([:])
                    out.append(.max)
                    let next = trie.count - 1
                    trie[state][byte] = Int32(next)
                    state = next
                }
            }
            out[state] = min(out[state], Int32(clamping: value))
        }
        edgeStart.reserveCapacity(trie.count + 1)
        for node in trie {
            edgeStart.append(Int32(edgeBytes.count))
            for (byte, target) in node.sorted(by: { $0.key < $1.key }) {
                edgeBytes.append(byte)
                edgeTargets.append(target)
            }
        }
        edgeStart.append(Int32(edgeBytes.count))
        fail = [Int32](repeating: 0, count: trie.count)
        output = out
        // 广度优先构建失败链。
        var queue: [Int] = []
        for edge in Int(edgeStart[0])..<Int(edgeStart[1]) {
            queue.append(Int(edgeTargets[edge]))
        }
        var head = 0
        while head < queue.count {
            let state = queue[head]
            head += 1
            for edge in Int(edgeStart[state])..<Int(edgeStart[state + 1]) {
                let byte = edgeBytes[edge]
                let next = Int(edgeTargets[edge])
                queue.append(next)
                var f = Int(fail[state])
                while f != 0, transition(f, byte) == nil {
                    f = Int(fail[f])
                }
                let target = transition(f, byte) ?? 0
                fail[next] = Int32(target == next ? 0 : target)
                output[next] = min(output[next], output[Int(fail[next])])
            }
        }
    }

    private func transition(_ state: Int, _ byte: UInt8) -> Int? {
        var low = Int(edgeStart[state])
        var high = Int(edgeStart[state + 1]) - 1
        while low <= high {
            let mid = (low + high) / 2
            let value = edgeBytes[mid]
            if value == byte { return Int(edgeTargets[mid]) }
            if value < byte { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }

    func minimumMatch(in bytes: some Sequence<UInt8>) -> Int? {
        var state = 0
        var best = output[0]
        for byte in bytes {
            while state != 0, transition(state, byte) == nil {
                state = Int(fail[state])
            }
            state = transition(state, byte) ?? 0
            best = min(best, output[state])
        }
        return best == .max ? nil : Int(best)
    }
}
