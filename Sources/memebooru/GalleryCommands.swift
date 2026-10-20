import ArgumentParser
import Foundation
import MemebooruCore

/// A deliberately explicit publication list. No collection paths, device identities or sync state.
struct GalleryCatalogue: Codable {
    var source: String
    var items: [GalleryItem]
}
struct GalleryItem: Codable {
    var url: String
    var sourcePage: String
    var title: String
    var category: String
    var file: String
    var sha256: String
    var bytes: Int64
    var width: Int
    var height: Int
    var tags: [String]
    var thumb: String?
}

struct Gallery: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Import an explicitly listed image catalogue and publish a read-only web gallery.",
        subcommands: [ImportCatalogue.self, Publish.self])

    static func load(_ path: String) throws -> (GalleryCatalogue, URL) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let catalogue = try JSONDecoder().decode(GalleryCatalogue.self, from: Data(contentsOf: url))
        guard !catalogue.items.isEmpty else { throw ValidationError("empty catalogue") }
        for item in catalogue.items {
            guard item.sha256.count == 64, item.sha256.allSatisfy({ "0123456789abcdef".contains($0) }),
                  item.width > 0, item.height > 0, item.bytes > 0,
                  !item.tags.isEmpty, item.tags.count <= 100,
                  [item.url, item.sourcePage].allSatisfy({
                      guard let url = URL(string: $0) else { return false }
                      return url.scheme == "https" && url.host == "frutigeraeroarchive.org" && url.user == nil && url.password == nil
                  }) else {
                throw ValidationError("invalid catalogue entry: \(item.title)")
            }
            _ = try sourceFile(item, root: url.deletingLastPathComponent())
        }
        return (catalogue, url.deletingLastPathComponent())
    }

    static func sourceFile(_ item: GalleryItem, root: URL) throws -> URL {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let file = base.appendingPathComponent(item.file).resolvingSymlinksInPath().standardizedFileURL
        guard !item.file.hasPrefix("/"), file.path.hasPrefix(base.path + "/"),
              ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff", "avif"].contains(file.pathExtension.lowercased()) else {
            throw ValidationError("image path escapes the catalogue or is unsupported")
        }
        return file
    }

    struct ImportCatalogue: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "import", abstract: "Verify and import catalogue images into Staging. Never commits automatically.")
        @OptionGroup var collection: CollectionOption
        @Argument var manifest: String
        func run() throws {
            let (catalogue, root) = try Gallery.load(manifest)
            // Validate every original before making the first change.
            for item in catalogue.items {
                let file = try Gallery.sourceFile(item, root: root)
                guard try MediaStore.sha256(of: file) == item.sha256 else { throw ValidationError("checksum mismatch: \(item.file)") }
            }
            let c = try collection.open(), staging = Host.staging(c)
            var known = Set(try staging.list().map(\.sha256))
            var count = 0
            for item in catalogue.items {
                if known.contains(item.sha256) { continue }
                if !(try c.memes.memes(withSHA256: item.sha256)).isEmpty { continue }
                let same = catalogue.items.filter { $0.sha256 == item.sha256 }
                var staged = try staging.add(file: Gallery.sourceFile(item, root: root), source: item.url,
                                             originalName: URL(string: item.url)?.lastPathComponent,
                                             context: item.title + "\n" + item.sourcePage)
                staged.userTags = Array(Set(same.flatMap(\.tags))).sorted()
                staged.convert = false // preserve the downloaded original byte for byte
                // Import time is not the artwork's creation year.
                staged.suggestedTags.removeAll { $0 == String(Calendar.current.component(.year, from: Date())) }
                try staging.update(staged)
                known.insert(item.sha256); count += 1
                if count.isMultiple(of: 100) { Host.printer()("Staged \(count)") }
            }
            print("Staged \(count) images. Review, then explicitly run stage commit all.")
        }
    }

    struct Publish: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Publish ONLY catalogue-listed, committed images. Output must be a new directory.")
        @OptionGroup var collection: CollectionOption
        @Argument var manifest: String
        @Option(name: .long) var output: String
        @Option(name: .long, help: "Directory containing the web UI.") var web: String = "Web"
        func run() throws {
            let (catalogue, _) = try Gallery.load(manifest)
            let c = try collection.open(), fm = FileManager.default
            let dest = URL(fileURLWithPath: output).standardizedFileURL
            guard !fm.fileExists(atPath: dest.path) else { throw ValidationError("output already exists; publish into a new directory") }
            let webRoot = URL(fileURLWithPath: web)
            let files = ["index.html", "app.js", "style.css"]
            for file in files {
                guard fm.fileExists(atPath: webRoot.appendingPathComponent(file).path) else { throw ValidationError("missing web UI: \(file)") }
            }
            // Build next to the destination; an error never leaves a half-published gallery.
            let tmp = dest.deletingLastPathComponent().appendingPathComponent(".gallery-\(UUID().uuidString)")
            try fm.createDirectory(at: tmp.appendingPathComponent("media"), withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: tmp) }
            try fm.createDirectory(at: tmp.appendingPathComponent("thumbs"), withIntermediateDirectories: true)
            let analyzer = MediaAnalyzer(platform: Host.platform())
            var published: [GalleryItem] = [], seen = Set<String>()
            for var item in catalogue.items {
                guard seen.insert(item.sha256).inserted else { continue }
                let ids = try c.memes.memes(withSHA256: item.sha256)
                guard let id = ids.first, let asset = try c.memes.primaryAsset(of: id), asset.sha256 == item.sha256 else {
                    throw ValidationError("image must be committed before publication: \(item.title)")
                }
                let original = c.media.url(sha256: asset.sha256, ext: asset.ext)
                guard try MediaStore.sha256(of: original) == item.sha256 else { throw ValidationError("stored checksum mismatch") }
                item.file = "media/\(item.sha256).\(asset.ext)"
                item.thumb = "thumbs/\(item.sha256).jpg"
                try fm.copyItem(at: original, to: tmp.appendingPathComponent(item.file))
                guard let thumbnail = try analyzer.thumbnail(original, kind: .image) else { throw ValidationError("cannot make preview: \(item.title)") }
                try thumbnail.write(to: tmp.appendingPathComponent(item.thumb!))
                // Tags and titles come exclusively from the public manifest, never private collection metadata.
                item.tags = Array(Set(catalogue.items.filter { $0.sha256 == item.sha256 }.flatMap(\.tags))).sorted()
                published.append(item)
            }
            for file in files { try fm.copyItem(at: webRoot.appendingPathComponent(file), to: tmp.appendingPathComponent(file)) }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(GalleryCatalogue(source: catalogue.source, items: published)).write(to: tmp.appendingPathComponent("catalogue.json"))
            try fm.moveItem(at: tmp, to: dest)
            print("Published \(published.count) images to \(dest.path). No database, staging, credentials or device metadata exported.")
        }
    }
}
