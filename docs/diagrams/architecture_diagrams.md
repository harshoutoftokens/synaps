# Synaps Architecture Diagrams

This file contains all major architecture and flow diagrams for the Synaps project.

---

## 1. Full System Architecture

```mermaid
graph TB
    subgraph "Your Mac / Dev Machine"
        DEV[Developer Machine\nCode Editor]
        GIT[Git Repository\nGitHub/GitLab]
    end

    subgraph "NAS Server (Ubuntu/Linux)"
        subgraph "Process 1: Node.js"
            FE[Next.js Frontend\nPort 3000]
        end
        subgraph "Process 2: Python"
            BE[FastAPI Backend\nPort 8000]
        end
        subgraph "Storage"
            DB[(SQLite\nsynaps.db)]
            THUMB[Thumbnail Cache\nbackend/thumbnails/]
            TRASH[Trash Folder\nbackend/trash/]
            NAS[NAS Storage\n/storage/Vault/...]
        end
    end

    subgraph "Client Devices"
        BROWSER[Browser\n any device on local WiFi]
        IPHONE[iPhone\nfor uploads]
    end

    DEV -->|merge PR, CI passes| GIT
    GIT -->|synaps-update.timer pulls| NAS

    BROWSER -->|HTTP :3000| FE
    IPHONE -->|HTTP :3000| FE
    FE -->|Proxy rewrites /api/*| BE
    BE -->|SQLAlchemy| DB
    BE -->|File I/O| THUMB
    BE -->|File I/O| TRASH
    BE -->|os.walk, os.stat| NAS
```

---

## 2. Request Lifecycle

```mermaid
sequenceDiagram
    participant B as Browser
    participant N as Next.js (Port 3000)
    participant F as FastAPI (Port 8000)
    participant DB as SQLite
    participant FS as Filesystem

    B->>N: GET / (Timeline page)
    N->>B: HTML + JS bundle

    Note over B: React hydrates and boots

    B->>N: GET /api/media/timeline?page=1
    N->>F: Proxy: GET /api/media/timeline?page=1
    F->>DB: SELECT * FROM media_files ORDER BY date_taken DESC LIMIT 80
    DB-->>F: 80 MediaFile rows
    F->>F: Group by month/year
    F-->>N: JSON {groups: [...]}
    N-->>B: JSON {groups: [...]}

    B->>B: Render MediaGrid
    B->>N: GET /api/media/thumbnail/{id} (for each item)
    N->>F: Proxy: GET /api/media/thumbnail/{id}
    F->>FS: Check thumbnail cache
    alt Cache hit
        FS-->>F: .webp file
    else Cache miss
        F->>FS: Read original file
        F->>F: Generate WebP thumbnail
        F->>FS: Write .webp to cache
    end
    F-->>B: WebP image binary
    B->>B: Display thumbnail
```

---

## 3. Backend Module Dependency Graph

```mermaid
graph TD
    MAIN[main.py\nEntry Point] --> CONFIG[config.py\nConfiguration]
    MAIN --> DATABASE[database.py\nDB Session]
    MAIN --> SCANNER[scanner.py\nFilesystem Indexer]
    MAIN --> ROUTER_M[routers/media.py\nTimeline API]
    MAIN --> ROUTER_F[routers/finder.py\nFile Browser API]
    MAIN --> ROUTER_S[routers/sync.py\nUpload API]
    MAIN --> ROUTER_SE[routers/search.py\nSearch API]
    MAIN --> ROUTER_T[routers/trash.py\nTrash API]
    MAIN --> ROUTER_ST[routers/settings.py\nSettings API]

    DATABASE --> CONFIG
    DATABASE --> MODELS[models.py\nDB Tables]

    SCANNER --> CONFIG
    SCANNER --> MODELS

    ROUTER_M --> DATABASE
    ROUTER_M --> MODELS
    ROUTER_M --> THUMBNAILS[thumbnails.py\nThumbnail Engine]

    ROUTER_F --> CONFIG
    ROUTER_S --> DATABASE
    ROUTER_S --> MODELS
    ROUTER_S --> CONFIG
    ROUTER_S --> SCANNER

    ROUTER_SE --> DATABASE
    ROUTER_SE --> MODELS
    ROUTER_T --> DATABASE
    ROUTER_T --> MODELS
    ROUTER_T --> CONFIG
    ROUTER_ST --> DATABASE
    ROUTER_ST --> MODELS
    ROUTER_ST --> CONFIG

    THUMBNAILS --> CONFIG
```

---

## 4. Frontend Component Tree

```mermaid
graph TD
    LAYOUT[layout.tsx\nRoot Layout\nServer Component] --> APPSHELL[AppShell.tsx\nClient Component]
    APPSHELL --> SIDEBAR[Sidebar.tsx\nNavigation]
    APPSHELL --> VIEWER[MediaViewer.tsx\nFullscreen Viewer]
    APPSHELL --> MAIN[main element\nPage Content]

    MAIN --> PAGE_HOME[page.tsx\nTimeline /]
    MAIN --> PAGE_FINDER[finder/page.tsx\n/finder]
    MAIN --> PAGE_SEARCH[search/page.tsx\n/search]
    MAIN --> PAGE_SYNC[sync/page.tsx\n/sync]
    MAIN --> PAGE_TRASH[trash/page.tsx\n/trash]
    MAIN --> PAGE_SETTINGS[settings/page.tsx\n/settings]

    PAGE_HOME --> TOPBAR[TopBar.tsx]
    PAGE_HOME --> MEDIAGRID[MediaGrid.tsx]
    MEDIAGRID --> MEDIATHUMB[MediaThumbnail\nper item]

    SIDEBAR --> STORE[store.ts\nZustand Store]
    VIEWER --> STORE
    APPSHELL --> STORE
    PAGE_HOME --> STORE

    PAGE_HOME --> API[lib/api.ts\nAPI Client]
    PAGE_FINDER --> API
    PAGE_SEARCH --> API
    PAGE_SYNC --> API
    PAGE_TRASH --> API
    PAGE_SETTINGS --> API
```

---

## 5. Scanner Flow

```mermaid
flowchart TD
    START([scan_directory called]) --> LOAD[Load all existing paths\nfrom media_files into Set]
    LOAD --> LOOP_PATHS[For each path in ALLOWED_SCAN_PATHS]
    LOOP_PATHS --> EXISTS{Path exists\non disk?}
    EXISTS -- No --> WARN[Log warning\nSkip path]
    EXISTS -- Yes --> WALK[os.walk - recursive]
    
    WALK --> FILTER_DIRS[Filter dirs:\nSkip hidden, venv, thumbnails, trash]
    FILTER_DIRS --> LOOP_FILES[For each file in directory]
    
    LOOP_FILES --> HIDDEN{Hidden file?}
    HIDDEN -- Yes --> SKIP1[Skip]
    HIDDEN -- No --> EXT{Extension in\nALL_MEDIA_EXTENSIONS?}
    EXT -- No --> SKIP1
    EXT -- Yes --> COUNT[stats.scanned++]
    
    COUNT --> INDB{In existing_paths?}
    INDB -- Yes --> SKIP2[stats.skipped++\nContinue]
    INDB -- No --> STAT[os.stat - size, timestamps]
    
    STAT --> CLASSIFY[classify_media\ntype, screenshot, raw]
    CLASSIFY --> DATE[get_best_date\nEXIF → filename → filesystem]
    DATE --> HASH[compute_file_hash\nMD5 of first 64KB]
    HASH --> MIME[mimetypes.guess_type]
    MIME --> CREATE[Create MediaFile object]
    CREATE --> BATCH[Add to batch]
    
    BATCH --> FULL{batch >= 100?}
    FULL -- Yes --> COMMIT[db.add_all + db.commit\nClear batch]
    FULL -- No --> LOOP_FILES
    COMMIT --> LOOP_FILES
    
    LOOP_FILES --> END_DIR{More dirs?}
    END_DIR -- Yes --> FILTER_DIRS
    END_DIR -- No --> COMMIT_FINAL[Commit remaining batch]
    COMMIT_FINAL --> LOOP_PATHS
    
    LOOP_PATHS --> RETURN([Return stats dict])
```

---

## 6. Thumbnail Generation Pipeline

```mermaid
flowchart TD
    REQ["GET /api/media/thumbnail/{id}"] --> LOOKUP[DB lookup by ID]
    LOOKUP --> HASH["get_thumbnail_path(path)\nMD5(filepath) → .webp"]
    HASH --> CACHED{.webp exists\non disk?}
    
    CACHED -- Yes --> SERVE_CACHED[FileResponse\nCache hit ← instant]
    
    CACHED -- No --> EXT{File extension?}
    EXT -- Video .mp4/.mov etc --> FFMPEG["generate_video_thumbnail()\nffmpeg subprocess\n-ss 0.5 -vframes 1"]
    EXT -- .pdf --> POPPLER["generate_pdf_thumbnail()\npdftoppm subprocess\nPage 1 → PNG → WebP"]
    EXT -- Image .jpg/.heic etc --> PILLOW["generate_image_thumbnail()\nPillow.open()\n.thumbnail(320,320)\n.save(.webp, quality=75)"]
    
    FFMPEG --> SUCCESS{Generation\nsucceeded?}
    POPPLER --> SUCCESS
    PILLOW --> SUCCESS
    
    SUCCESS -- Yes --> UPDATE_DB[Update DB:\nhas_thumbnail=True\nthumbnail_path=...]
    UPDATE_DB --> SERVE_NEW[FileResponse\nnew thumbnail]
    
    SUCCESS -- No --> FALLBACK{Is it\nan image?}
    FALLBACK -- Yes --> SERVE_ORIG[FileResponse\noriginal file]
    FALLBACK -- No --> HTTP404[HTTP 404]
```

---

## 7. Upload/Sync Flow

```mermaid
flowchart TD
    SELECT[User selects files\nin browser] --> QUEUE[Files added to\nUploadItem queue\nstatus: pending]
    QUEUE --> UPLOAD_BTN[User clicks Upload]
    UPLOAD_BTN --> LOOP[Loop: for each pending file]
    
    LOOP --> SET_UPLOADING[Set status: uploading]
    SET_UPLOADING --> POST["POST /api/sync/upload\nmultipart/form-data"]
    
    POST --> READ[await file.read()\nAll content into RAM]
    READ --> HASH_FULL[MD5 of entire file\nhashlib.md5 content]
    HASH_FULL --> CHECK_SYNC{In sync_records?}
    
    CHECK_SYNC -- Yes --> RETURN_DUP1[Return: duplicate]
    CHECK_SYNC -- No --> CHECK_MEDIA{In media_files?}
    
    CHECK_MEDIA -- Yes --> RETURN_DUP2[Return: duplicate]
    CHECK_MEDIA -- No --> MKDIR[makedirs YEAR/MONTH/]
    
    MKDIR --> COLLISION{Filename\nexists?}
    COLLISION -- Yes --> RENAME[Add _1 _2 suffix]
    COLLISION -- No --> WRITE[Write file to disk]
    RENAME --> WRITE
    
    WRITE --> RECORD[INSERT sync_records]
    RECORD --> RETURN_OK[Return: success]
    
    RETURN_DUP1 --> UI_UPDATE[Update UI status]
    RETURN_DUP2 --> UI_UPDATE
    RETURN_OK --> UI_UPDATE
    
    UI_UPDATE --> LOOP
    LOOP --> DONE[All files processed]
    DONE --> NOTE[Note: New files\nNOT in timeline yet\nRequires rescan]
```

---

## 8. State Management Flow

```mermaid
graph LR
    subgraph "Zustand Store (store.ts)"
        SIDEBAR_STATE[sidebarOpen: boolean]
        VIEWER_STATE[viewerOpen: boolean\nviewerMediaId: string|null]
        FILTER_STATE[activeFilter: string|null]
    end

    subgraph "Components That Write"
        TOPBAR_W[TopBar\ntogglesidebar click]
        SIDEBAR_W[Sidebar\nsidebarOpen close\nsetFilter click]
        MEDIATHUMB_W[MediaThumbnail\nopenViewer on click]
        VIEWER_W[MediaViewer\ncloseViewer on X/Escape]
    end

    subgraph "Components That Read"
        APPSHELL_R[AppShell\n← sidebarOpen\nfor ml-260px]
        SIDEBAR_R[Sidebar\n← sidebarOpen\nfor AnimatePresence\n← activeFilter\nfor active style]
        VIEWER_R[MediaViewer\n← viewerOpen\n← viewerMediaId]
        TIMELINE_R[page.tsx\n← activeFilter\nfor API filter param]
    end

    TOPBAR_W --> SIDEBAR_STATE
    SIDEBAR_W --> SIDEBAR_STATE
    SIDEBAR_W --> FILTER_STATE
    MEDIATHUMB_W --> VIEWER_STATE
    VIEWER_W --> VIEWER_STATE

    SIDEBAR_STATE --> APPSHELL_R
    SIDEBAR_STATE --> SIDEBAR_R
    FILTER_STATE --> SIDEBAR_R
    FILTER_STATE --> TIMELINE_R
    VIEWER_STATE --> VIEWER_R
```

---

## 9. Deployment Flow

```mermaid
sequenceDiagram
    participant DEV as Developer (Mac)
    participant GIT as Git Remote
    participant NAS as NAS Server

    DEV->>DEV: Edit code + ./synaps test
    DEV->>GIT: push branch, open PR, merge after CI passes
    loop every 5 min (synaps-update.timer)
        NAS->>GIT: git fetch + read CI check-runs
    end
    NAS->>NAS: back up DB, pip install / npm build only if changed
    NAS->>NAS: systemctl restart synaps-backend + health check
    NAS->>NAS: roll back automatically on failure
    Note over NAS: Frontend serves new build
```

---

## 10. Database Entity Relationship Diagram

```mermaid
erDiagram
    media_files {
        string id PK
        string filename
        string path UK
        string relative_path
        string directory
        string extension
        string mime_type
        integer file_size
        integer width
        integer height
        float duration
        string media_type
        boolean is_screenshot
        boolean is_screen_recording
        boolean is_raw
        boolean is_favorite
        datetime date_taken
        datetime date_created
        datetime date_modified
        datetime date_indexed
        string camera_make
        string camera_model
        float gps_lat
        float gps_lon
        boolean has_thumbnail
        string thumbnail_path
        string file_hash
    }

    trash_items {
        string id PK
        string original_path
        string trash_path
        string filename
        integer file_size
        string media_type
        datetime deleted_at
        datetime auto_delete_at
    }

    sync_records {
        string id PK
        string filename
        string file_hash
        integer file_size
        string destination_path
        datetime synced_at
        string source_device
    }

    settings {
        string key PK
        string value
        datetime updated_at
    }
```

---

## 11. Data Flow When Filter Changes

```mermaid
sequenceDiagram
    participant User
    participant Sidebar as Sidebar.tsx
    participant Store as Zustand Store
    participant Timeline as page.tsx
    participant API as FastAPI

    User->>Sidebar: Click "Photos" filter
    Sidebar->>Store: setFilter('image')
    Store->>Store: activeFilter = 'image'
    Store->>Timeline: Re-render triggered (activeFilter changed)

    Timeline->>Timeline: useEffect fires [activeFilter changed]
    Timeline->>Timeline: setPage(1), setGroups([]), setHasMore(true)
    Timeline->>Timeline: fetchPage(1, reset=true)
    Timeline->>Timeline: loadedIdsRef.current = new Set()

    Timeline->>API: GET /api/media/timeline?page=1&per_page=80&media_type=image
    API->>API: query.filter(MediaFile.media_type == 'image')
    API->>API: ORDER BY date_taken DESC LIMIT 80
    API-->>Timeline: {groups: [...photos only...], total: 280}

    Timeline->>Timeline: setGroups(dedupedGroups)
    Timeline->>Timeline: setHasMore(true if more pages)
    Timeline->>Timeline: setLoading(false)
    Timeline->>User: Renders: only photos shown
```
