# Versioning Strategy — Synaps

This document defines the versioning scheme for Synaps, explains when to increment each version component, and maps the project's historical milestones to version numbers.

---

## Version History

| Version | Name | Status |
|---------|------|--------|
| `v0.1` | First Working Build | ✅ Complete |
| `v0.2` | Scanner & NAS Hardening | ✅ Complete |
| `v0.3` | Import Manager | ✅ Complete |
| `v0.4` | Media Browser & Source Filters | ✅ Complete |
| `v0.5` | Apple Photos UI (web) | ✅ Complete |
| `v2.0` | Native Mac App & Home Cloud Vault | ✅ Complete |
| `v2.1` | Native iPhone App | ✅ Complete |
| `v2.2` | Reliability, Security & Continuous Deployment | ✅ Complete |

The web-only milestones planned as `v0.6`–`v1.0` were never tagged: when the native apps and the content-addressed vault arrived (September 2026), the project moved straight to `v2.0`. Open work is tracked in the [roadmap](roadmap.md) and shipped work in the [changelog](../../CHANGELOG.md).

---------|------|--------|
| `v0.1` | First Working Build | ✅ Complete |
| `v0.2` | Scanner & NAS Hardening | ✅ Complete |
| `v0.3` | Import Manager | ✅ Complete |
| `v0.4` | Media Browser & Source Filters | ✅ Complete |
| `v0.5` | Apple Photos UI | 🔄 In Progress |
| `v0.6` | Stability & Bug Fixes | 📋 Planned |
| `v0.7` | Richer Media Info | 📋 Planned |
| `v0.8` | Search & Discovery | 📋 Planned |
| `v0.9` | Albums | 📋 Planned |
| `v1.0` | Stable NAS Release | 📋 Planned |

---

## Versioning Scheme

Synaps uses **Semantic Versioning** (`MAJOR.MINOR.PATCH`), adapted for a personal project in active development.

```
v MAJOR . MINOR . PATCH
  └─────   └──────  └──── Bug fixes, hotfixes
           └──────── New features, significant improvements
  └──────────────── Breaking changes, full rewrites, paradigm shifts
```

---

## When to Increment

### PATCH — Bug Fixes & Hotfixes (`v0.5.0` → `v0.5.1`)

Increment PATCH when you fix a bug without adding new functionality.

**Examples:**
- Fixing a crash or exception
- Correcting incorrect behavior (wrong date, wrong count, broken link)
- Fixing a deployment script
- Correcting a migration script
- Fixing a styling regression

**Rule of thumb:** If you can describe the change as "this was broken and now it works," it's a patch.

**Commit convention:** Prefix with `fix:` (e.g., `fix: HEIC date extraction returning epoch`)

---

### MINOR — New Features (`v0.5.x` → `v0.6.0`)

Increment MINOR when you add a meaningful new capability that doesn't break anything existing.

**Examples:**
- A new page or view (Gallery View, Old Photos archive)
- A new API endpoint
- A new configuration option
- A new component (GlassButton, GlassSegmentedControl)
- A new background process (Import Manager, preview job)
- A significant UI improvement that adds new user-facing controls

**Rule of thumb:** If you can describe the change as "you can now do something you couldn't do before," it's a minor version.

**Commit convention:** Prefix with `feat:` (e.g., `feat: Add Synaps Import Manager V1`)

**When to create a branch:** Every minor feature should live on a feature branch (`feature/albums`, `feature/video-scrubbing`) and be merged via PR into `main` once complete.

---

### MAJOR — Breaking Changes or Paradigm Shifts (`v0.x` → `v1.0`)

Increment MAJOR for:

1. **Breaking changes** — Changes that require the user to do something before upgrading (manual migration, config changes, schema changes that can't be migrated automatically).
2. **Paradigm shifts** — The application works fundamentally differently (e.g., switching from SQLite to PostgreSQL, replacing the frontend framework).
3. **Stability milestones** — For Synaps, `v1.0` represents the point where the application is considered stable enough for long-term daily use on the NAS without expecting breaking changes between updates.

**`v0.x` Convention:** While the major version is 0, breaking changes are acceptable between minor versions. `v0.5` to `v0.6` can have migration scripts. `v1.0` signals that the API, database schema, and deployment process are stable and future updates will be backward compatible.

---

## Tagging Releases

Use annotated Git tags for each release:

```bash
# Tag a release
git tag -a v0.5.0 -m "v0.5.0 — Apple Photos UI"
git push origin v0.5.0

# Tag a hotfix
git tag -a v0.5.1 -m "v0.5.1 — Fix sticky header scroll bug"
git push origin v0.5.1

# List all tags
git tag -l
```

**Tagging policy:**
- Tag `main` only (not feature branches)
- Always merge feature branch → `main` → then tag
- Tag at the end of a working session, not mid-feature

---

## Branch Naming Conventions

| Branch Type | Pattern | Example |
|-------------|---------|---------|
| Feature | `feature/<name>` | `feature/albums` |
| Bug fix | `fix/<name>` | `fix/heic-date-extraction` |
| UI work | `ui/<name>` | `ui/timeline-sticky-headers` |
| Experiment | `experiment/<name>` | `experiment/websocket-realtime` |
| Release prep | `release/vX.Y.Z` | `release/v1.0.0` |

**Retire branches after merging.** Once a feature branch is merged and tagged, delete it:

```bash
# Delete local branch
git branch -d feature/albums

# Delete remote branch
git push origin --delete feature/albums
```

---

## Commit Message Conventions

Use this format consistently:

```
<type>: <short description>

[optional body]
```

| Type | Use for |
|------|---------|
| `feat:` | New feature |
| `fix:` | Bug fix |
| `chore:` | Maintenance (deps, scripts, config) |
| `docs:` | Documentation only |
| `refactor:` | Code restructure with no behavior change |
| `perf:` | Performance improvement |
| `style:` | CSS/visual changes only |
| `test:` | Test additions or fixes |

**Examples:**
```
feat: Add content-based duplicate detection using SHA-256
fix: Correct IMPORT_SOURCE_DIR case sensitivity for Linux NAS
chore: Remove backend/.env from git tracking
docs: Add CHANGELOG.md and ROADMAP.md
perf: Switch thumbnail queue to LIFO for visible-first ordering
```

---

## Definition of a stable release

The next release considered "stable for long-term use" should meet all of these:

- [ ] The database schema has been stable for at least one minor version without breaking migrations
- [ ] `./synaps update` (the auto-update timer) reliably updates the NAS without manual intervention
- [ ] The application runs for 30+ days on the NAS without crashing or needing a restart
- [ ] Background scans complete successfully and the timeline stays up to date
- [ ] The Import Manager has been used for at least 3 full import cycles without data loss
- [ ] Light and Dark themes are both polished and complete
- [ ] A `CONTRIBUTING.md` exists (if this ever becomes open-source)
- [ ] The known issues at the top of the [roadmap](roadmap.md) are resolved

---

*See the [changelog](../../CHANGELOG.md) for what has shipped and the [roadmap](roadmap.md) for what is planned.*
