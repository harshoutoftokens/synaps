import SwiftUI

public struct SettingsView: View {
    @StateObject private var settingsVM = SettingsViewModel()
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @StateObject private var photosVM = PhotosViewModel()
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
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .keyboardType(.URL)
                            .onChange(of: settingsVM.config.nasUrl) { _ in
                                settingsVM.saveConfig()
                            }
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
                Section(header: Text("Background Sync & Wi-Fi Automation"), footer: Text("When enabled, Synaps automatically discovers new photos taken on your iPhone and syncs them to your NAS when connected to Wi-Fi.")) {
                    Toggle("Auto-Upload on Wi-Fi", isOn: $settingsVM.config.autoSyncOnWifi)
                        .onChange(of: settingsVM.config.autoSyncOnWifi) { _ in
                            settingsVM.saveConfig()
                        }
                    
                    Toggle("Require Charging / Power", isOn: $settingsVM.config.requireCharging)
                        .onChange(of: settingsVM.config.requireCharging) { _ in
                            settingsVM.saveConfig()
                        }
                    
                    Toggle("Enable Background Worker", isOn: $settingsVM.config.backgroundTaskEnabled)
                        .onChange(of: settingsVM.config.backgroundTaskEnabled) { _ in
                            settingsVM.saveConfig()
                        }
                    
                    Toggle("Sync Favorites Only", isOn: $settingsVM.config.syncFavoritesOnly)
                        .onChange(of: settingsVM.config.syncFavoritesOnly) { _ in
                            settingsVM.saveConfig()
                        }
                }
                
                // Live Network Diagnostics
                Section(header: Text("Network Status")) {
                    LabeledContent("Network Connection", value: networkMonitor.isConnected ? "Active" : "Disconnected")
                    LabeledContent("Interface", value: networkMonitor.isWifi ? "Wi-Fi (High Speed)" : (networkMonitor.isCellular ? "Cellular Data" : "None"))
                    LabeledContent("Metered / Expensive", value: networkMonitor.isExpensive ? "Yes" : "No")
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
                    LabeledContent("App Version", value: "1.0.0 (Synaps iOS)")
                    LabeledContent("Engine", value: "Synaps v2 Atomic Vault")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showActivityLog) {
                ActivityLogSheet(settingsViewModel: settingsVM)
            }
        }
    }
}
