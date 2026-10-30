/// 有上限的 LRU 缓存（docs/02 §6）。容量满时淘汰最久未使用的条目；不是线程安全的，由持有者负责同步。
///
/// 实现为数组链表 + 字典，`get` / `set` 均摊 O(1)，不为每次访问分配节点。
public struct LRUCache<Key: Hashable, Value> {
    fileprivate struct Node {
        var key: Key
        var value: Value
        var prev: Int
        var next: Int
    }

    public let capacity: Int
    private var nodes: [Node] = []
    private var index: [Key: Int] = [:]
    private var head = -1  // 最近使用
    private var tail = -1  // 最久未使用
    private var free: [Int] = []

    /// - Parameter capacity: 至少为 1。
    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        index.reserveCapacity(min(self.capacity, 4096))
    }

    public var count: Int { index.count }

    /// 读取并标记为最近使用。
    public mutating func get(_ key: Key) -> Value? {
        guard let slot = index[key] else { return nil }
        moveToFront(slot)
        return nodes[slot].value
    }

    /// 读取但不改变顺序。
    public func peek(_ key: Key) -> Value? {
        index[key].map { nodes[$0].value }
    }

    /// 写入；容量满时淘汰最久未使用者。
    /// - Returns: 被淘汰的条目（若有）。
    @discardableResult
    public mutating func set(_ key: Key, _ value: Value) -> (key: Key, value: Value)? {
        if let slot = index[key] {
            nodes[slot].value = value
            moveToFront(slot)
            return nil
        }
        var evicted: (Key, Value)?
        if index.count >= capacity, tail >= 0 {
            let old = tail
            evicted = (nodes[old].key, nodes[old].value)
            unlink(old)
            index[nodes[old].key] = nil
            free.append(old)
        }
        let node = Node(key: key, value: value, prev: -1, next: head)
        let slot: Int
        if let reused = free.popLast() {
            nodes[reused] = node
            slot = reused
        } else {
            nodes.append(node)
            slot = nodes.count - 1
        }
        if head >= 0 { nodes[head].prev = slot }
        head = slot
        if tail < 0 { tail = slot }
        index[key] = slot
        return evicted.map { (key: $0.0, value: $0.1) }
    }

    @discardableResult
    public mutating func remove(_ key: Key) -> Value? {
        guard let slot = index.removeValue(forKey: key) else { return nil }
        unlink(slot)
        free.append(slot)
        return nodes[slot].value
    }

    public mutating func removeAll() {
        nodes.removeAll()
        index.removeAll()
        free.removeAll()
        head = -1
        tail = -1
    }

    /// 移除并返回最久未使用的条目；为空时返回 nil。
    @discardableResult
    public mutating func popLeastRecent() -> (key: Key, value: Value)? {
        guard tail >= 0 else { return nil }
        let old = tail
        unlink(old)
        index[nodes[old].key] = nil
        free.append(old)
        return (nodes[old].key, nodes[old].value)
    }

    /// 只保留最近使用的 `count` 条（内存压力时缩减）。
    public mutating func trim(to count: Int) {
        while index.count > max(0, count), tail >= 0 {
            let old = tail
            unlink(old)
            index[nodes[old].key] = nil
            free.append(old)
        }
    }

    /// 从最近到最久的键。
    public var keysByRecency: [Key] {
        var result: [Key] = []
        var cursor = head
        while cursor >= 0 {
            result.append(nodes[cursor].key)
            cursor = nodes[cursor].next
        }
        return result
    }

    private mutating func unlink(_ slot: Int) {
        let prev = nodes[slot].prev
        let next = nodes[slot].next
        if prev >= 0 { nodes[prev].next = next } else { head = next }
        if next >= 0 { nodes[next].prev = prev } else { tail = prev }
        nodes[slot].prev = -1
        nodes[slot].next = -1
    }

    private mutating func moveToFront(_ slot: Int) {
        guard head != slot else { return }
        unlink(slot)
        nodes[slot].next = head
        if head >= 0 { nodes[head].prev = slot }
        head = slot
        if tail < 0 { tail = slot }
    }
}

extension LRUCache: Sendable where Key: Sendable, Value: Sendable {}
extension LRUCache.Node: Sendable where Key: Sendable, Value: Sendable {}
