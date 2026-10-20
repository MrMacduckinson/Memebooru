/// BK-tree over 64-bit hashes with Hamming metric. Built in memory for a full-collection scan.
public struct BKTree<Payload: Sendable>: Sendable {
    private final class Node: @unchecked Sendable {
        let hash: UInt64
        var payloads: [Payload]
        var children: [Int: Node] = [:]
        init(hash: UInt64, payload: Payload) { self.hash = hash; self.payloads = [payload] }
    }

    private var root: Node?
    public private(set) var count = 0

    public init() {}

    public mutating func insert(_ hash: UInt64, _ payload: Payload) {
        count += 1
        guard let root else { self.root = Node(hash: hash, payload: payload); return }
        var node = root
        while true {
            let d = PerceptualHash.hamming(hash, node.hash)
            if d == 0 { node.payloads.append(payload); return }
            if let child = node.children[d] { node = child } else {
                node.children[d] = Node(hash: hash, payload: payload); return
            }
        }
    }

    /// All entries within `radius` of `hash`, with their distance.
    public func search(_ hash: UInt64, radius: Int) -> [(payload: Payload, distance: Int)] {
        guard let root else { return [] }
        var out: [(Payload, Int)] = []
        var stack = [root]
        while let node = stack.popLast() {
            let d = PerceptualHash.hamming(hash, node.hash)
            if d <= radius { for p in node.payloads { out.append((p, d)) } }
            let lo = max(0, d - radius), hi = d + radius
            for (k, child) in node.children where k >= lo && k <= hi { stack.append(child) }
        }
        return out.map { (payload: $0.0, distance: $0.1) }
    }
}
