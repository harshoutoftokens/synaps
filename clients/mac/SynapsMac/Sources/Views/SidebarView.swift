import SwiftUI

public struct SidebarView: View {
    @ObservedObject var viewModel: AppViewModel
    
    public var body: some View {
        List {
            // Devices Section
            Section("Devices") {
                if let phone = viewModel.phoneManager.connectedDevice {
                    let isSelected = viewModel.isPicturesSection
                    Button {
                        viewModel.selectPicturesSection()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "iphone.gen3")
                                .font(.system(size: 15))
                                .foregroundColor(isSelected ? .accentColor : .secondary)
                                .frame(width: 20, alignment: .center)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(phone.name)
                                    .fontWeight(isSelected ? .semibold : .medium)
                                    .foregroundColor(isSelected ? .accentColor : .primary)
                                Text("\(phone.totalItems) items • \(phone.transportType)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                    )
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "cable.connector")
                            .font(.system(size: 15))
                            .foregroundColor(.secondary)
                            .frame(width: 20, alignment: .center)
                        Text("Connect iPhone via USB-C")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                }
            }
            
            // Mac Folders Section
            Section("Mac Folders") {
                folderRow(
                    id: "folder_downloads",
                    title: "Downloads",
                    icon: "arrow.down.circle",
                    path: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
                )
                
                folderRow(
                    id: "folder_documents",
                    title: "Documents",
                    icon: "doc",
                    path: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path
                )
                
                folderRow(
                    id: "folder_desktop",
                    title: "Desktop",
                    icon: "menubar.dock.rectangle",
                    path: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path
                )
                
                picturesRow
            }
            
            // iPhone Albums (if any detected)
            if !viewModel.phoneManager.detectedAlbums.isEmpty {
                Section("iPhone Albums") {
                    ForEach(viewModel.phoneManager.detectedAlbums, id: \.self) { album in
                        HStack(spacing: 10) {
                            Image(systemName: "rectangle.stack")
                                .font(.system(size: 15))
                                .foregroundColor(.secondary)
                                .frame(width: 20, alignment: .center)
                            Text(album)
                                .foregroundColor(.primary)
                            Spacer()
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 6)
                    }
                }
            }
            
            // NAS Status Section
            Section("NAS Network") {
                let isSelected = viewModel.selectedSidebarItem?.id == "section_nas"
                HStack(spacing: 8) {
                    Button {
                        let item = SidebarItem(
                            id: "section_nas",
                            title: "Home Cloud",
                            icon: "server.rack",
                            section: .devices,
                            path: "",
                            sourceId: "nas_homecloud",
                            isNAS: true
                        )
                        viewModel.selectSidebarItem(item)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "server.rack")
                                .font(.system(size: 15))
                                .foregroundColor(isSelected ? .accentColor : .secondary)
                                .frame(width: 20, alignment: .center)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(viewModel.nasOnline ? Color.green : Color.red)
                                        .frame(width: 6, height: 6)
                                    Text(viewModel.nasOnline ? "Home Cloud (homecloud1)" : "Home Cloud (Offline)")
                                        .font(.subheadline)
                                        .fontWeight(isSelected ? .bold : .medium)
                                        .foregroundColor(isSelected ? .accentColor : .primary)
                                }
                                Text(viewModel.nasBaseUrl)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
                    )
                    
                    Button {
                        Task {
                            await viewModel.checkNASStatus()
                            if viewModel.selectedSidebarItem?.isNAS == true {
                                viewModel.loadNASFolder(path: viewModel.currentNASRelativePath)
                            }
                        }
                    } label: {
                        SpinningRefreshIcon(isSpinning: viewModel.isCheckingNAS)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isCheckingNAS)
                    .help(viewModel.isCheckingNAS ? "Checking NAS connection..." : "Refresh NAS connection")
                    .accessibilityLabel(viewModel.isCheckingNAS ? "Checking NAS connection" : "Refresh NAS connection")
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 220)
    }
    
    private var picturesRow: some View {
        let isSelected = viewModel.isPicturesSection
        return Button {
            viewModel.selectPicturesSection()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 15))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .frame(width: 20, alignment: .center)
                Text("Pictures")
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundColor(isSelected ? .accentColor : .primary)
                Spacer()
                if let phone = viewModel.phoneManager.connectedDevice, !viewModel.phoneManager.isDeviceLocked {
                    Text("\(phone.totalItems)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
    }
    
    private func folderRow(id: String, title: String, icon: String, path: String?) -> some View {
        let isSelected = viewModel.selectedSidebarItem?.id == id
        return Button {
            guard let path = path else { return }
            let item = SidebarItem(
                id: id,
                title: title,
                icon: icon,
                section: .macFolders,
                path: path,
                sourceId: "mac_harsh"
            )
            viewModel.selectSidebarItem(item)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .frame(width: 20, alignment: .center)
                Text(title)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundColor(isSelected ? .accentColor : .primary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
    }
}

public struct SpinningRefreshIcon: View {
    let isSpinning: Bool
    @State private var isAnimating: Bool = false
    
    public init(isSpinning: Bool) {
        self.isSpinning = isSpinning
    }
    
    public var body: some View {
        Image(systemName: "arrow.clockwise")
            .font(.caption)
            .rotationEffect(.degrees(isAnimating ? 360 : 0))
            .animation(
                isAnimating
                    ? Animation.linear(duration: 0.8).repeatForever(autoreverses: false)
                    : Animation.easeOut(duration: 0.2),
                value: isAnimating
            )
            .onAppear {
                isAnimating = isSpinning
            }
            .onChange(of: isSpinning) { _, newValue in
                isAnimating = newValue
            }
    }
}
