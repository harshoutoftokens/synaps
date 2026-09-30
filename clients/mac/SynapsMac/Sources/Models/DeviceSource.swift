import Foundation

public enum SidebarSection: String, CaseIterable, Identifiable {
    case devices = "Devices"
    case macFolders = "Mac Folders"
    case library = "Media Library"
    case system = "NAS System"
    
    public var id: String { rawValue }
}

public struct SidebarItem: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let icon: String
    public let section: SidebarSection
    public let path: String?
    public let sourceId: String
    public let badgeCount: Int?
    public let isPhone: Bool
    public let isNAS: Bool
    
    public init(
        id: String,
        title: String,
        icon: String,
        section: SidebarSection,
        path: String? = nil,
        sourceId: String = "mac_harsh",
        badgeCount: Int? = nil,
        isPhone: Bool = false,
        isNAS: Bool = false
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.section = section
        self.path = path
        self.sourceId = sourceId
        self.badgeCount = badgeCount
        self.isPhone = isPhone
        self.isNAS = isNAS
    }
}
