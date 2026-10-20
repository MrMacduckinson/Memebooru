public enum TagSimilarity {
    /// Jaccard index over tag id sets. 1 = identical.
    public static func jaccard(_ a: Set<Int64>, _ b: Set<Int64>) -> Double {
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return Double(a.intersection(b).count) / Double(union)
    }
}
