import Foundation

public struct ImportReport: Sendable {
    public var staged: [StagedItem] = []
    public var skipped: [(URL, String)] = []
    public init() {}
}

/// Drag a folder in: every supported file goes to staging with `source_unknown` + year.
public struct FolderImporter: Sendable {
    public let staging: StagingArea
    public init(staging: StagingArea) { self.staging = staging }

    public func importFiles(_ urls: [URL], source: String = "folder", progress: ((URL) -> Void)? = nil) throws -> ImportReport {
        var report = ImportReport()
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                report.skipped.append((url, "not found")); continue
            }
            let files = isDir.boolValue ? Self.walk(url) : [url]
            for f in files {
                guard MediaType.detect(url: f) != nil else { report.skipped.append((f, "unsupported")); continue }
                progress?(f)
                do {
                    report.staged.append(try staging.add(file: f, source: source, extraTags: ["source_unknown"]))
                } catch { report.skipped.append((f, "\(error)")) }
            }
        }
        return report
    }

    static func walk(_ dir: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { out.append(u) }
        return out.sorted { $0.path < $1.path }
    }
}
