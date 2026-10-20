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
            PageHeader(title: "Синхронизация", subtitle: library.name) {
                if let b = sync.busyWith { MBSpinner(); Text("Синхронизация с \(b)…").zfont(12).foregroundStyle(Theme.muted) }
            }

            card {
                SectionLabel(text: "Это устройство")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Space.l) { deviceLine; Spacer(); codeLine }
                    VStack(alignment: .leading, spacing: Space.s) { deviceLine; codeLine }
                }
                Text("Введите этот код на другом устройстве один раз. При следующей синхронизации он не понадобится.").zfont(12).foregroundStyle(Theme.muted)
            }

            card {
                SectionLabel(text: "Рядом")
                if sync.nearby.isEmpty { Text("В локальной сети ничего не найдено. Откройте Memebooru на другом устройстве.").zfont(12).foregroundStyle(Theme.muted) }
                ForEach(sync.nearby) { f in
                    let isPaired = sync.paired.contains { $0.name == f.name }
                    let name = HStack(spacing: Space.s) {
                        Image(systemName: "laptopcomputer.and.iphone").foregroundStyle(Theme.muted)
                        Text(f.name).zfont(13, .bold).lineLimit(1)
                    }
                    let controls = HStack(spacing: Space.s) {
                        if !isPaired {
                            SteadyTextField(text: Binding(get: { codes[f.name] ?? "" }, set: { codes[f.name] = $0 }), placeholder: "код", monospacedDigit: true)
                                .fieldChrome().frame(width: 90)
                        }
                        GlassButton(title: isPaired ? "Синхронизация" : "Подключить и синхронизировать", symbol: "arrow.triangle.2.circlepath", prominent: true) {
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
                SectionLabel(text: "Подключённые устройства")
                if sync.paired.isEmpty { Text("Пока нет.").zfont(12).foregroundStyle(Theme.muted) }
                ForEach(sync.paired) { p in
                    let name = HStack(spacing: Space.s) {
                        Image(systemName: "checkmark.seal").foregroundStyle(Theme.meta)
                        VStack(alignment: .leading, spacing: Space.xs / 2) {
                            Text(p.name).zfont(13, .bold).lineLimit(1)
                            Text(p.lastSync.map { "последняя синхронизация " + Date(timeIntervalSince1970: Double($0) / 1000).formatted(date: .abbreviated, time: .shortened) } ?? "ещё не синхронизировано")
                                .zfont(11).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                    let controls = HStack(spacing: Space.s) {
                        GlassButton(title: "Синхронизировать", symbol: "arrow.triangle.2.circlepath", prominent: true) { sync.sync(peer: p) { library.reloadAll() } }
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
                SectionLabel(text: "По адресу (VPS или другая сеть)")
                let hostField = SteadyTextField(text: $host, placeholder: "адрес:порт").fieldChrome().frame(maxWidth: 320)
                let rest = HStack(spacing: Space.s) {
                    SteadyTextField(text: $manualCode, placeholder: "код", monospacedDigit: true).fieldChrome().frame(width: 90)
                    GlassButton(title: "Синхронизация", symbol: "arrow.triangle.2.circlepath", prominent: true) {
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
                    SectionLabel(text: "Журнал")
                    ForEach(sync.log, id: \.self) { Text($0).zfont(11).foregroundStyle(Theme.muted).textSelection(.enabled) }
                }
            }
        }
        .onAppear { sync.refresh() }
    }

    private var deviceLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Text(library.collection?.deviceName ?? "").dfont(18).lineLimit(1)
            Text("порт \(sync.port)").zfont(12).foregroundStyle(Theme.muted).lineLimit(1).fixedSize()
        }
    }
    private var codeLine: some View {
        HStack(spacing: Space.s) {
            Text("код подключения").zfont(12).foregroundStyle(Theme.muted).fixedSize()
            Text(sync.pairingCode).font(.system(size: 26, weight: .bold, design: .monospaced)).foregroundStyle(Theme.link).fixedSize()
        }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Space.m) { content() }
            .card()
    }
}
