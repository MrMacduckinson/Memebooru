import SwiftUI
import MemebooruCore
import MemebooruPlatformApple

/// Devices page: this device's pairing code, nearby devices, paired devices, manual address.
struct SyncView: View {
    @Environment(Library.self) private var library
    @State private var codes: [String: String] = [:]
    @State private var host = ""
    @State private var manualCode = ""

    private var sync: SyncController { library.sync }

    var body: some View {
        PageColumn {
            PageHeader(title: "Sync", subtitle: library.name) {
                if let b = sync.busyWith { MBSpinner(); Text("syncing with \(b)…").zfont(12).foregroundStyle(Theme.muted) }
            }

            card {
                SectionLabel(text: "This device")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Space.l) { deviceLine; Spacer(); codeLine }
                    VStack(alignment: .leading, spacing: Space.s) { deviceLine; codeLine }
                }
                Text("Another device enters this code once; after that, syncing needs no code.").zfont(12).foregroundStyle(Theme.muted)
            }

            card {
                SectionLabel(text: "Nearby")
                if sync.nearby.isEmpty { Text("Nothing found on the local network. Open Memebooru on another device.").zfont(12).foregroundStyle(Theme.muted) }
                ForEach(sync.nearby) { f in
                    let isPaired = sync.paired.contains { $0.name == f.name }
                    let name = HStack(spacing: Space.s) {
                        Image(systemName: "laptopcomputer.and.iphone").foregroundStyle(Theme.muted)
                        Text(f.name).zfont(13, .bold).lineLimit(1)
                    }
                    let controls = HStack(spacing: Space.s) {
                        if !isPaired {
                            SteadyTextField(text: Binding(get: { codes[f.name] ?? "" }, set: { codes[f.name] = $0 }), placeholder: "code", monospacedDigit: true)
                                .fieldChrome().frame(width: 90)
                        }
                        GlassButton(title: isPaired ? "Sync" : "Pair & sync", symbol: "arrow.triangle.2.circlepath", prominent: true) {
                            sync.sync(with: f, code: codes[f.name]) { library.reloadAll() }
                        }.disabled(sync.busyWith != nil)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Space.m) { name; Spacer(); controls }
                        VStack(alignment: .leading, spacing: Space.s) { name; controls }
                    }
                }
            }

            card {
                SectionLabel(text: "Paired devices")
                if sync.paired.isEmpty { Text("None yet.").zfont(12).foregroundStyle(Theme.muted) }
                ForEach(sync.paired) { p in
                    let name = HStack(spacing: Space.s) {
                        Image(systemName: "checkmark.seal").foregroundStyle(Theme.meta)
                        VStack(alignment: .leading, spacing: Space.xs / 2) {
                            Text(p.name).zfont(13, .bold).lineLimit(1)
                            Text(p.lastSync.map { "last sync " + Date(timeIntervalSince1970: Double($0) / 1000).formatted(date: .abbreviated, time: .shortened) } ?? "never synced")
                                .zfont(11).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                    let controls = HStack(spacing: Space.s) {
                        GlassButton(title: "Sync now", symbol: "arrow.triangle.2.circlepath", prominent: true) { sync.sync(peer: p) { library.reloadAll() } }
                            .disabled(sync.busyWith != nil)
                        GlassIconButton(symbol: "trash", tint: Theme.danger) { sync.forget(p) }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Space.m) { name; Spacer(); controls }
                        VStack(alignment: .leading, spacing: Space.s) { name; controls }
                    }
                }
            }

            card {
                SectionLabel(text: "By address (VPS, other network)")
                let hostField = SteadyTextField(text: $host, placeholder: "host:port").fieldChrome().frame(maxWidth: 320)
                let rest = HStack(spacing: Space.s) {
                    SteadyTextField(text: $manualCode, placeholder: "code", monospacedDigit: true).fieldChrome().frame(width: 90)
                    GlassButton(title: "Sync", symbol: "arrow.triangle.2.circlepath", prominent: true) {
                        if let (h, p) = SyncController.hostPort(host) { sync.sync(host: h, port: p, code: manualCode) { library.reloadAll() } }
                    }.disabled(sync.busyWith != nil || SyncController.hostPort(host) == nil)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Space.s) { hostField; rest }
                    VStack(alignment: .leading, spacing: Space.s) { hostField; rest }
                }
            }

            if !sync.log.isEmpty {
                card {
                    SectionLabel(text: "Log")
                    ForEach(sync.log, id: \.self) { Text($0).zfont(11).foregroundStyle(Theme.muted).textSelection(.enabled) }
                }
            }
        }
        .onAppear { sync.refresh() }
    }

    private var deviceLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(library.collection?.deviceName ?? "").dfont(18).lineLimit(1)
            Text("port \(sync.port)").zfont(12).foregroundStyle(Theme.muted).lineLimit(1).fixedSize()
        }
    }
    private var codeLine: some View {
        HStack(spacing: Space.s) {
            Text("pairing code").zfont(12).foregroundStyle(Theme.muted).fixedSize()
            Text(sync.pairingCode).font(.system(size: 26, weight: .bold, design: .monospaced)).foregroundStyle(Theme.link).fixedSize()
        }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Space.m) { content() }
            .card()
    }
}
