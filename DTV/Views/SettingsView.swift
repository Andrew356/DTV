import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Source?
    @State private var adding = false
    @State private var confirmDelete: Source?

    var body: some View {
        let settings = model.sync.settings
        NavigationStack {
            List {
                Section("Sources") {
                    ForEach(model.sync.sources) { source in
                        Button { model.select(source) } label: {
                            HStack {
                                Image(systemName: source.id == model.activeSource?.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(source.id == model.activeSource?.id ? Color.green : Color.secondary)
                                VStack(alignment: .leading) {
                                    Text(source.name)
                                    Text(source.kind.label + (source.kind == .xtream && Keychain.get(account: source.keychainAccount) == nil
                                                              ? " · password needed on this Apple TV" : ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .contextMenu {
                            Button("Edit", systemImage: "pencil") { editing = source }
                            Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = source }
                        }
                    }
                    Button { adding = true } label: { Label("Add Source", systemImage: "plus") }
                    Text("Select a source to make it active. Long-press to edit or delete.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Library") {
                    Button {
                        model.refresh()
                    } label: {
                        HStack {
                            Label("Refresh Playlist", systemImage: "arrow.clockwise")
                            Spacer()
                            if let date = model.catalog?.loadedAt {
                                Text(date.formatted(.relative(presentation: .named))).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button {
                        model.refreshEPGIfNeeded(force: true)
                    } label: {
                        HStack {
                            Label("Refresh TV Guide", systemImage: "calendar")
                            Spacer()
                            if model.epgLoading { ProgressView() }
                            else if model.epg.loadedAt > .distantPast {
                                Text("\(model.epg.programmes.count) channels").foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let c = model.catalog {
                        Text("\(c.live.count) channels · \(c.movies.count) movies · \(c.series.count) series")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Playback") {
                    Toggle("Prefer HLS for live TV", isOn: Binding(
                        get: { settings.preferHLS },
                        set: { v in model.sync.updateSettings { $0.preferHLS = v }; model.refresh() }))
                    if PlayerEngineChooser.vlcAvailable {
                        Picker("Player", selection: Binding(
                            get: { settings.playerEngine },
                            set: { v in model.sync.updateSettings { $0.playerEngine = v } })) {
                            ForEach(PlayerEngine.allCases) { Text($0.label).tag($0) }
                        }
                    }
                    Toggle("Show channel numbers", isOn: Binding(
                        get: { settings.showChannelNumbers },
                        set: { v in model.sync.updateSettings { $0.showChannelNumbers = v } }))
                    Picker("TV guide length", selection: Binding(
                        get: { settings.epgHours },
                        set: { v in model.sync.updateSettings { $0.epgHours = v } })) {
                        ForEach([12, 24, 48, 72], id: \.self) { Text("\($0) hours").tag($0) }
                    }
                }

                Section("iCloud Sync") {
                    HStack {
                        Label(model.sync.iCloudAvailable ? "iCloud is on" : "Not signed in to iCloud",
                              systemImage: model.sync.iCloudAvailable ? "icloud.fill" : "icloud.slash")
                        Spacer()
                        if let last = model.sync.lastSync {
                            Text("Synced \(last.formatted(.relative(presentation: .named)))").foregroundStyle(.secondary)
                        }
                    }
                    Button { model.sync.syncNow() } label: { Label("Sync Now", systemImage: "arrow.triangle.2.circlepath.icloud") }
                    Text("Sources, favorites, watch progress and settings sync through iCloud. Xtream passwords sync through iCloud Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Storage") {
                    Button("Clear Cached Playlists & Guide", role: .destructive) {
                        CatalogCache.clear()
                        model.refresh()
                    }
                }
            }
            .navigationTitle("Settings")
        }
        .sheet(isPresented: $adding) { SourceEditorView(existing: nil) }
        .sheet(item: $editing) { SourceEditorView(existing: $0) }
        .alert("Delete \(confirmDelete?.name ?? "source")?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let s = confirmDelete { model.delete(source: s) }
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("This removes it from all your Apple TVs, along with its favorites and watch history.")
        }
    }
}

struct SourceEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let existing: Source?

    @State private var kind: SourceKind = .xtream
    @State private var name = ""
    @State private var m3uURL = ""
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var epgURL = ""
    @State private var testing = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(SourceKind.allCases) { Text($0.label).tag($0) }
                    }
                    TextField("Name (e.g. My IPTV)", text: $name)
                }
                if kind == .m3u {
                    Section("Playlist") {
                        TextField("M3U URL (http://…)", text: $m3uURL)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                } else {
                    Section("Xtream Codes Login") {
                        TextField("Server (http://host:port)", text: $server)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Username", text: $username)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField(existing == nil ? "Password" : "Password (leave blank to keep)", text: $password)
                    }
                }
                Section("TV Guide (optional)") {
                    TextField("XMLTV EPG URL override", text: $epgURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        HStack {
                            Text(existing == nil ? "Add Source" : "Save")
                            if testing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(testing || !isValid)
                    if let message { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle(existing == nil ? "Add Source" : "Edit Source")
        }
        .onAppear(perform: populate)
    }

    private var isValid: Bool {
        switch kind {
        case .m3u: return URL(string: m3uURL.trimmingCharacters(in: .whitespaces))?.scheme != nil
        case .xtream:
            let hasPassword = !password.isEmpty || (existing.map { Keychain.get(account: $0.keychainAccount) != nil } ?? false)
            return !server.isEmpty && !username.isEmpty && hasPassword
        }
    }

    private func populate() {
        guard let s = existing else { return }
        kind = s.kind
        name = s.name
        m3uURL = s.m3uURL ?? ""
        server = s.serverURL ?? ""
        username = s.username ?? ""
        epgURL = s.epgURL ?? ""
    }

    private func save() async {
        message = nil
        testing = true
        defer { testing = false }

        var source = existing ?? Source(name: "", kind: kind)
        source.kind = kind
        source.epgURL = epgURL.isEmpty ? nil : epgURL.trimmingCharacters(in: .whitespaces)

        switch kind {
        case .m3u:
            source.m3uURL = m3uURL.trimmingCharacters(in: .whitespaces)
            source.serverURL = nil; source.username = nil
            source.name = name.isEmpty ? (URL(string: source.m3uURL ?? "")?.host ?? "Playlist") : name
            model.save(source: source, password: nil)
        case .xtream:
            let pw = password.isEmpty ? (existing.flatMap { Keychain.get(account: $0.keychainAccount) } ?? "") : password
            do {
                let client = try XtreamClient(server: server, username: username, password: pw)
                _ = try await client.authenticate()
                source.serverURL = client.server.absoluteString
                source.username = username
                source.m3uURL = nil
                source.name = name.isEmpty ? (client.server.host ?? "Xtream") : name
                model.save(source: source, password: pw)
            } catch {
                message = error.localizedDescription
                return
            }
        }
        dismiss()
    }
}
