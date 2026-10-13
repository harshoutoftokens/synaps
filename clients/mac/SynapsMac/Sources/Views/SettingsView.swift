import SwiftUI

/// Settings window (Synaps ▸ Settings…, ⌘,): NAS address, optional API token, network and
/// notification preferences. Saved to ~/.config/synaps/mac_app_config.json, readable only by you.
public struct SettingsView: View {
    @State private var nasUrl: String = ""
    @State private var apiToken: String = ""
    @State private var revealToken = false
    @State private var autoDiscoverNas = true
    @State private var notificationsEnabled = true
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var isTesting = false
    @State private var isSearching = false
    @State private var discovered: [String] = []
    @State private var loaded = false
    
    public init() {}
    
    public var body: some View {
        Form {
            Section("Home Cloud") {
                TextField("NAS address", text: $nasUrl, prompt: Text("http://192.168.0.105:8000"))
                
                HStack(spacing: 6) {
                    if revealToken {
                        TextField("API token", text: $apiToken, prompt: Text("Optional"))
                    } else {
                        SecureField("API token", text: $apiToken, prompt: Text("Optional"))
                    }
                    Button {
                        revealToken.toggle()
                    } label: {
                        Image(systemName: revealToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(revealToken ? "Hide token" : "Show token")
                }
                
                Text("Only needed when the NAS backend runs with SYNAPS_API_TOKEN. Stored in ~/.config/synaps/mac_app_config.json, readable only by your user account.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Section("Network") {
                Toggle("Suggest another address when Home Cloud can't be reached", isOn: $autoDiscoverNas)
                
                HStack(spacing: 8) {
                    Button("Find Home Cloud on Network") {
                        search()
                    }
                    .disabled(isSearching)
                    if isSearching {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                
                ForEach(discovered, id: \.self) { url in
                    HStack {
                        Text(url)
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Button("Use") {
                            nasUrl = url
                        }
                    }
                }
            }
            
            Section("Notifications") {
                Toggle("Notify when a sync or iPhone import finishes", isOn: $notificationsEnabled)
            }
            
            HStack(spacing: 8) {
                if let statusMessage = statusMessage {
                    Label(statusMessage, systemImage: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(statusIsError ? .orange : .green)
                        .lineLimit(2)
                }
                Spacer()
                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Test Connection") {
                    testConnection()
                }
                .disabled(isTesting)
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .onAppear {
            load()
        }
    }
    
    private func load() {
        guard !loaded else { return }
        loaded = true
        let config = SynapsConfig.load()
        nasUrl = config.nasUrl
        apiToken = config.apiToken
        autoDiscoverNas = config.autoDiscoverNas
        notificationsEnabled = config.notificationsEnabled
    }
    
    private func save() {
        let url = SynapsConfig.normalizedURLString(nasUrl)
        guard let parsed = URL(string: url), parsed.host != nil else {
            statusMessage = "Enter an address like http://192.168.0.105:8000"
            statusIsError = true
            return
        }
        var config = SynapsConfig.load()
        config.nasUrl = url
        config.apiToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        config.autoDiscoverNas = autoDiscoverNas
        config.notificationsEnabled = notificationsEnabled
        guard config.save() else {
            statusMessage = "Could not write \(SynapsConfig.configFile.path)"
            statusIsError = true
            return
        }
        nasUrl = url
        apiToken = config.apiToken
        statusMessage = "Saved"
        statusIsError = false
        NotificationCenter.default.post(name: SynapsConfig.didChangeNotification, object: config)
    }
    
    /// Checks the entered (not yet saved) address and token with a throwaway client.
    private func testConnection() {
        let url = SynapsConfig.normalizedURLString(nasUrl)
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        isTesting = true
        statusMessage = nil
        Task {
            let client = NASClient(baseUrl: url, apiToken: token, reportsAuthFailures: false)
            defer { client.invalidate() }
            let message: String
            let isError: Bool
            if await client.checkHealth() {
                switch await client.verifyAuth() {
                case .some(true):
                    message = token.isEmpty ? "Connected (this NAS doesn't require a token)" : "Connected, API token accepted"
                    isError = false
                case .some(false):
                    message = token.isEmpty ? "Connected, but this NAS requires an API token" : "Connected, but the API token was rejected"
                    isError = true
                case .none:
                    message = "Reachable, but the authenticated request failed"
                    isError = true
                }
            } else {
                message = "No Synaps backend answered at \(url)"
                isError = true
            }
            statusMessage = message
            statusIsError = isError
            isTesting = false
        }
    }
    
    /// Lists other addresses that answer; nothing changes until the user picks one and saves.
    private func search() {
        isSearching = true
        discovered = []
        let url = SynapsConfig.normalizedURLString(nasUrl)
        Task {
            let client = NASClient(baseUrl: url, apiToken: "", reportsAuthFailures: false)
            defer { client.invalidate() }
            let found = await client.discoverNAS()
            discovered = found
            isSearching = false
            if found.isEmpty {
                statusMessage = "No other Synaps backend answered at the usual addresses"
                statusIsError = true
            }
        }
    }
}
