import SwiftUI

public struct SettingsView: View {
    @StateObject private var settingsVM = SettingsViewModel()
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @ObservedObject private var reconciler = NASReconciler.shared
    @EnvironmentObject private var photosVM: PhotosViewModel
    @State private var showActivityLog = false
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            Form {
                // NAS Connection Section
                Section(header: Text("Synaps NAS Server")) {
                    HStack {
                        Text("NAS URL")
                            .font(.system(size: 15))
                        Spacer()
                        TextField("http://192.168.0.105:8000", text: $settingsVM.config.nasUrl)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .keyboardType(.URL)
                            .onChange(of: settingsVM.config.nasUrl) { _ in
                                settingsVM.saveConfig()
                            }
                    }
                    
                    HStack {
                        Text("API Token")
                            .font(.system(size: 15))
                        Spacer()
                        SecureField("Optional", text: $settingsVM.apiToken)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .onChange(of: settingsVM.apiToken) { _ in
                                settingsVM.saveToken()
                            }
                    }
                    
                    if settingsVM.tokenSaveFailed {
                        Text("Couldn't save the token to the Keychain.")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    
                    HStack {
                        Button {
                            settingsVM.testConnection()
                        } label: {
                            HStack {
                                if settingsVM.isTestingConnection {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("Testing...")
                                } else {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                    Text("Test Connection")
                                }
                            }
                        }
                        .disabled(settingsVM.isTestingConnection)
                        
                        Spacer()
                        
                        if let success = settingsVM.connectionSuccess {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(success ? Color.green : Color.red)
                                    .frame(width: 8, height: 8)
                                Text(success ? "Connected" : "Offline")
                                    .font(.caption)
                                    .foregroundColor(success ? .green : .red)
                            }
                        }
                    }
                    
                    if !settingsVM.connectionStatusMessage.isEmpty {
                        Text(settingsVM.connectionStatusMessage)
                            .font(.caption)
                            .foregroundColor(settingsVM.connectionSuccess == true ? .green : .red)
                    }
                }
                
                // Device Identification
                Section(header: Text("Device Identity")) {
                    HStack {
                        Text("Source ID")
                        Spacer()
                        TextField("iphone_harsh", text: $settingsVM.config.sourceId)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: settingsVM.config.sourceId) { _ in
                                settingsVM.saveConfig()
                            }
                    }
                    
                    HStack {
                        Text("Friendly Name")
                        Spacer()
                        TextField("Harsh's iPhone", text: $settingsVM.config.friendlyName)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: settingsVM.config.friendlyName) { _ in
                                settingsVM.saveConfig()
                            }
                    }
                }
                
                // Wi-Fi & Background Automation
                Section(header: Text("Background Sync & Wi-Fi Automation"), footer: Text("When enabled, Synaps automatically uploads new photos while you're on Wi-Fi (not on cellular, personal hotspots or Low Data Mode). The background worker lets iOS continue while the app is closed. \"Favorites Only\" applies to automatic uploads; manual commits upload whatever you select.")) {
                    Toggle("Auto-Upload on Wi-Fi", isOn: $settingsVM.config.autoSyncOnWifi)
                        .onChange(of: settingsVM.config.autoSyncOnWifi) { _ in
                            settingsVM.automationSettingsChanged()
                        }
                    
                    Toggle("Require Charging / Power", isOn: $settingsVM.config.requireCharging)
                        .onChange(of: settingsVM.config.requireCharging) { _ in
                            settingsVM.automationSettingsChanged()
                        }
                    
                    Toggle("Enable Background Worker", isOn: $settingsVM.config.backgroundTaskEnabled)
                        .onChange(of: settingsVM.config.backgroundTaskEnabled) { _ in
                            settingsVM.automationSettingsChanged()
                        }
                    
                    Toggle("Sync Favorites Only", isOn: $settingsVM.config.syncFavoritesOnly)
                        .onChange(of: settingsVM.config.syncFavoritesOnly) { _ in
                            settingsVM.saveConfig()
                        }
                    
                    LabeledContent("Last Sync", value: settingsVM.lastSyncDescription)
                }
                
                // What gets backed up per photo
                Section(header: Text("Backup Contents"), footer: Text("The unmodified original is always uploaded. Edited versions are saved next to it as IMG_E1234 files.")) {
                    Toggle("Live Photo Videos", isOn: $settingsVM.config.uploadLivePhotoVideos)
                        .onChange(of: settingsVM.config.uploadLivePhotoVideos) { _ in
                            settingsVM.backupContentsChanged()
                        }
                    
                    Toggle("Edited Versions", isOn: $settingsVM.config.uploadEditedVersions)
                        .onChange(of: settingsVM.config.uploadEditedVersions) { _ in
                            settingsVM.backupContentsChanged()
                        }
                }
                
                // Live Network Diagnostics
                Section(header: Text("Network Status")) {
                    LabeledContent("Network Connection", value: networkMonitor.isConnected ? "Active" : "Disconnected")
                    LabeledContent("Interface", value: networkMonitor.isWifi ? "Wi-Fi (High Speed)" : (networkMonitor.isCellular ? "Cellular Data" : "None"))
                    LabeledContent("Metered / Expensive", value: networkMonitor.isExpensive ? "Yes" : "No")
                    LabeledContent("Low Data Mode", value: networkMonitor.isConstrained ? "On" : "Off")
                }
                
                // Photos Library & Vault Statistics
                Section(header: Text("Library Statistics")) {
                    LabeledContent("Total Media Items", value: "\(photosVM.rawItems.count)")
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Committed to NAS")
                        Spacer()
                        Text("\(photosVM.committedCount)")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                        Text("Uncommitted (Pending)")
                        Spacer()
                        Text("\(photosVM.uncommittedCount)")
                            .foregroundColor(.red)
                            .fontWeight(.semibold)
                    }
                }
                
                // Photos that reached the NAS another way (e.g. through the Mac)
                Section(footer: Text("Marks photos and videos the NAS already has, for example ones you uploaded from your Mac, as committed. Matches by file name and size; nothing is uploaded. Runs automatically every few hours.")) {
                    Button {
                        Task { await reconciler.reconcile() }
                    } label: {
                        HStack {
                            Image(systemName: "externaldrive.badge.checkmark")
                                .foregroundColor(.green)
                            Text("Find Photos Already on NAS")
                                .foregroundColor(.primary)
                            Spacer()
                            if reconciler.isRunning {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(reconciler.isRunning)
                    if let result = reconciler.lastResult {
                        Text(result)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                
                // Activity Log Navigation
                Section {
                    Button {
                        showActivityLog = true
                    } label: {
                        HStack {
                            Image(systemName: "list.bullet.rectangle.portrait")
                                .foregroundColor(.blue)
                            Text("View Sync Activity Log")
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                // About
                Section(header: Text("About")) {
                    LabeledContent("App Version", value: settingsVM.appVersion)
                    LabeledContent("Engine", value: "Synaps v2 Atomic Vault")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showActivityLog) {
                ActivityLogSheet(settingsViewModel: settingsVM)
            }
            .onAppear {
                // Pick up fields changed elsewhere (e.g. last sync time) without discarding edits.
                settingsVM.config.lastSyncTimestamp = SynapsConfig.load().lastSyncTimestamp
            }
        }
    }
}
