# Synaps iOS — Private Photos Vault & Background Sync

An authentic, native Apple Photos client for **Synaps NAS** on iOS 16+.

Synaps iOS brings the elegance and speed of Apple Photos together with your private Synaps self-hosted NAS vault. It automatically backs up your camera roll and imported media over Wi-Fi, provides instant visual feedback for commit statuses, and gives you manual selection and synchronization control matching the Synaps Mac desktop experience.

---

## ✨ Key Features

### 1. 🟢 Green Tick & 🔴 Red Cross Indicators
- **Green Tick (`checkmark.circle.fill`)**: Verified and committed to the Synaps NAS vault. Physical objects are deduplicated and immutably indexed.
- **Red Cross (`xmark.circle.fill`)**: Newly captured photo or video on your iPhone that has not yet been committed to the NAS.
- **Blue Spinner (`ProgressView`)**: Active streaming upload / hash verification in progress.
- **Orange Warning (`exclamationmark.circle.fill`)**: Upload failed or retry needed.

### 2. ⚡ Automatic Background Worker on Wi-Fi
- **Wi-Fi Detection (`NWPathMonitor`)**: Automatically detects when you connect to your home Wi-Fi network and kicks off background synchronization without using mobile cellular data.
- **Background Tasks (`BGTaskScheduler`)**: Registers `BGAppRefreshTask` (`com.synaps.ios.backgroundsync`) and `BGProcessingTask` (`com.synaps.ios.photoprocessing`) to quietly sync photos while charging or in the background.
- **Live Camera Roll Observation (`PHPhotoLibraryChangeObserver`)**: When you snap a new photo or record a video with your iPhone camera, Synaps detects it immediately, badges it with a red cross, and enqueues it for Wi-Fi upload.

### 3. 🎯 Manual Selection & Synchronization (Matching Mac App)
- **Select Mode**: Tap "Select" in the top bar to select individual photos, tap "Select All", or tap a date group.
- **Floating Action Bar**: Glassmorphism bottom action bar shows selected count and provides a prominent **"Sync Selected to NAS"** button.
- **Instant Deduplication Pre-Check**: Communicates with `POST /api/v2/ingest/check`. If a photo's SHA-256 already exists on your NAS, it is committed instantly with **zero bytes uploaded**!

### 4. 🗂️ Uncommitted Staging Tab
- A dedicated staging view showing all pending photos awaiting NAS commit.
- Total size calculation (e.g. `14 photos • 62.4 MB to transfer`).
- One-tap **"Commit All to NAS"** floating button with live progress tracking and cancel option.

### 5. ☁️ NAS Vault Explorer
- Browse your remote NAS folders and stored photos directly on your iPhone.
- Thumbnail previews and search filter.
- Mirrors the NAS Vault browsing experience of the Synaps Mac app.

### 6. 🔍 Full Screen Inspector & Metadata
- Pinch-to-zoom photo viewer and video playback.
- Slide-up metadata sheet: original filename, dimensions, megapixel count, file size, creation date, SHA-256 hash (with one-tap copy), and NAS object reference.

### 7. 📝 Activity Audit Log
- Audit sheet recording timestamps of uploads, instant deduplication links, and transfer statuses.

---

## 🏗️ Architecture

```
clients/ios/SynapsiOS/
├── Package.swift                             # Swift Package configuration
├── SynapsiOS.xcodeproj/                      # Xcode project (double-click to open)
│   └── project.pbxproj
├── Resources/
│   ├── Info.plist                            # Photos, Local Network & Background permissions
│   └── SynapsiOS.entitlements                # Wi-Fi network entitlements
└── Sources/
    ├── SynapsiOSApp.swift                    # App lifecycle & BGTask scheduler registration
    ├── Models/
    │   ├── Config.swift                      # NAS URL, device ID, Wi-Fi auto-sync settings
    │   ├── SyncStatus.swift                  # Committed (green), Uncommitted (red), Syncing, Failed
    │   ├── SynapsMediaItem.swift             # PHAsset representation, metadata, SHA-256, status
    │   ├── SyncActivityItem.swift            # Audit log entry model
    │   └── NASBrowseItem.swift               # NAS directory items & files
    ├── Services/
    │   ├── PhotoLibraryService.swift         # PhotoKit bridge & PHPhotoLibraryChangeObserver
    │   ├── HashEngine.swift                  # Low-RAM streaming SHA-256 hashing
    │   ├── LocalCacheStore.swift             # High-speed SQLite state store (synaps_ios_state.db)
    │   ├── NASClient.swift                   # Pre-check dedup, streaming upload, health check
    │   ├── NetworkMonitor.swift              # NWPathMonitor Wi-Fi vs Cellular watcher
    │   ├── BackgroundSyncWorker.swift        # BackgroundTasks scheduler & Wi-Fi auto-sync handler
    │   └── SyncManager.swift                 # Synchronization pipeline coordinator
    ├── ViewModels/
    │   ├── PhotosViewModel.swift             # Grid grouping, date sections, selection, filters
    │   ├── NASVaultViewModel.swift           # Remote NAS file and folder browser
    │   └── SettingsViewModel.swift           # Server configuration & diagnostics
    └── Views/
        ├── MainTabView.swift                 # Tab controller: Photos, Uncommitted, NAS Vault, Settings
        ├── Photos/
        │   ├── PhotosGridView.swift          # Primary Apple Photos-style grid
        │   ├── MediaThumbnailCell.swift      # Thumbnail cell with status badge & duration
        │   ├── MediaBadgeView.swift          # Green tick / Red cross indicator
        │   ├── DateSectionHeader.swift       # Sticky date section header
        │   ├── SelectionActionBar.swift      # Floating bottom selection toolbar
        │   └── PhotoDetailView.swift         # Full screen viewer & EXIF/hash inspector
        ├── Uncommitted/
        │   └── UncommittedStagingView.swift  # Dedicated staging tab for uncommitted photos
        ├── NASVault/
        │   └── NASVaultView.swift            # Synaps remote NAS directory explorer
        └── Settings/
            ├── SettingsView.swift            # NAS URL, ping test, Wi-Fi toggles, statistics
            └── ActivityLogSheet.swift        # Audit logs of synced & deduped media
```

---

## 🚀 Getting Started

### Open in Xcode
Simply open the Xcode project file:
```bash
open clients/ios/SynapsiOS/SynapsiOS.xcodeproj
```

Select your iPhone or a Simulator as the run target, and press **Cmd + R** to build and run.

### Connecting to your NAS
1. In the app, switch to the **Settings** tab.
2. Enter your Synaps NAS URL (default: `http://192.168.0.105:8000`).
3. Tap **"Test Connection"**. The status indicator will turn 🟢 **Connected**.
4. Grant Photo Library access when prompted on first launch.
5. All your photos will display with their status:
   - 🔴 **Red cross** for uncommitted photos.
   - 🟢 **Green tick** for photos that already exist in the NAS vault.
