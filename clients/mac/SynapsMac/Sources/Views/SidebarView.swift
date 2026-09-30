import SwiftUI

public struct SidebarView: View {
    @ObservedObject var viewModel: AppViewModel
    
    public var body: some View {
        List {
            // Devices Section
            Section("Devices") {
                if let phone = viewModel.phoneManager.connectedDevice {
                    Button {
                        viewModel.selectPicturesSection()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "iphone.gen3")
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(phone.name)
                                    .fontWeight(.medium)
                                Text("\(phone.totalItems) items • \(phone.transportType)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "cable.connector")
                            .foregroundColor(.secondary)
                        Text("Connect iPhone via USB-C")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            
            // Mac Folders Section
            Section("Mac Folders") {
                folderRow(
                    id: "folder_downloads",
                    title: "Downloads",
                    icon: "arrow.down.circle.fill",
                    color: .blue,
                    path: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
                )
                
                folderRow(
                    id: "folder_documents",
                    title: "Documents",
                    icon: "doc.fill",
                    color: .orange,
                    path: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path
                )
                
                folderRow(
                    id: "folder_desktop",
                    title: "Desktop",
                    icon: "menubar.dock.rectangle",
                    color: .purple,
                    path: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path
                )
                
                Button {
                    viewModel.selectPicturesSection()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .foregroundColor(.pink)
                        Text("Pictures")
                            .foregroundColor(.primary)
                        Spacer()
                        if let phone = viewModel.phoneManager.connectedDevice, !viewModel.phoneManager.isDeviceLocked {
                            Text("\(phone.totalItems)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
            }
            
            // iPhone Albums (if any detected)
            if !viewModel.phoneManager.detectedAlbums.isEmpty {
                Section("iPhone Albums") {
                    ForEach(viewModel.phoneManager.detectedAlbums, id: \.self) { album in
                        HStack {
                            Image(systemName: "rectangle.stack.fill")
                                .foregroundColor(.teal)
                            Text(album)
                            Spacer()
                        }
                    }
                }
            }
            
            // NAS Status Section
            Section("NAS Network") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(viewModel.nasOnline ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.nasOnline ? "homecloud1" : "NAS Offline")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(viewModel.nasBaseUrl)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Button {
                        Task {
                            await viewModel.checkNASStatus()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 220)
    }
    
    private func folderRow(id: String, title: String, icon: String, color: Color, path: String?) -> some View {
        Button {
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
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(color)
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }
}
