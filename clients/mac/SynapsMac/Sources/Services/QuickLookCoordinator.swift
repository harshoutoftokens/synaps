import Cocoa
import QuickLookUI

public final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    public static let shared = QuickLookCoordinator()
    
    private var currentUrls: [URL] = []
    private var eventMonitor: Any?
    
    override private init() {
        super.init()
        setupEventMonitor()
    }
    
    public func updatePreviewItems(_ urls: [URL]) {
        self.currentUrls = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            if self.currentUrls.isEmpty {
                panel.orderOut(nil)
            } else {
                panel.reloadData()
            }
        }
    }
    
    public func toggleQuickLook(for urls: [URL]? = nil) {
        if let urls = urls {
            self.currentUrls = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        
        guard let panel = QLPreviewPanel.shared() else { return }
        
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            guard !currentUrls.isEmpty else { return }
            panel.dataSource = self
            panel.delegate = self
            panel.reloadData()
            panel.makeKeyAndOrderFront(nil)
        }
    }
    
    public func closeQuickLook() {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        }
    }
    
    private func setupEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            
            // Key code 49 is Spacebar
            if event.keyCode == 49 {
                // If user is actively typing in a text field or search field, allow space
                if let responder = event.window?.firstResponder,
                   responder is NSTextView || responder is NSTextField {
                    return event
                }
                
                // If Quick Look panel is visible, Spacebar closes it
                if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
                    panel.orderOut(nil)
                    return nil
                }
                
                // Toggle Quick Look if we have items
                if !self.currentUrls.isEmpty {
                    self.toggleQuickLook()
                    return nil
                }
            }
            
            return event
        }
    }
    
    // MARK: - QLPreviewPanelDataSource
    
    public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return currentUrls.count
    }
    
    public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard index >= 0 && index < currentUrls.count else { return nil }
        return currentUrls[index] as NSURL
    }
    
    // MARK: - QLPreviewPanelDelegate
    
    public func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        return false
    }
}
