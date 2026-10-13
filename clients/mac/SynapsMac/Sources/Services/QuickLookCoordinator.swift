import Cocoa
import QuickLookUI

@MainActor
public final class QuickLookCoordinator: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    public static let shared = QuickLookCoordinator()
    
    private var currentUrls: [URL] = []
    private var eventMonitor: Any?
    
    override private init() {
        super.init()
        setupEventMonitor()
    }
    
    public func updatePreviewItems(_ urls: [URL]) {
        // Called on every selection change ("Select All" in a big folder): only stat the files when
        // the panel is actually showing; toggleQuickLook filters again before opening it.
        let panelVisible = QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false)
        self.currentUrls = panelVisible ? urls.filter { FileManager.default.fileExists(atPath: $0.path) } : urls
        if panelVisible, let panel = QLPreviewPanel.shared() {
            if self.currentUrls.isEmpty {
                panel.orderOut(nil)
            } else {
                panel.reloadData()
            }
        }
    }
    
    public func toggleQuickLook(for urls: [URL]? = nil) {
        self.currentUrls = (urls ?? currentUrls).filter { FileManager.default.fileExists(atPath: $0.path) }
        
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
            
            // Key code 53 is Escape
            if event.keyCode == 53 {
                if let responder = event.window?.firstResponder,
                   responder is NSTextView || responder is NSTextField {
                    return event
                }
                
                if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
                    panel.orderOut(nil)
                    return nil
                }
                
                NotificationCenter.default.post(name: NSNotification.Name("ClearSelectionNotification"), object: nil)
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
