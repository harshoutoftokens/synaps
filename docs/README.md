# Synaps documentation

These guides explain how Synaps works under the hood, from the code as it is today. Each one starts with a short summary, then goes into detail with links to the source files.

## Where to start

- **New to the project or coming back after a while?** Read the [overview](01-overview.md), then [storage and ingest](03-storage-and-ingest.md). Those two explain the core idea: every file is stored once on the NAS, identified by its hash.
- **Working on an app?** Read the [Mac app](08-mac-app.md) or [iPhone app](09-iphone-app.md) guide, and keep the [API reference](10-api-reference.md) open.
- **Something broke on the NAS?** Go straight to [operations](12-operations.md), which has a troubleshooting table.
- **Want to follow one action through the whole system?** The [code walkthroughs](13-code-walkthroughs.md) trace real flows step by step.

## Guides

| # | Guide | What you'll learn |
|---|---|---|
| 01 | [Overview](01-overview.md) | The components, how data flows between them, repository map, glossary |
| 02 | [Backend](02-backend.md) | How the FastAPI server is put together: startup, settings, auth, routers, background jobs |
| 03 | [Storage and ingest](03-storage-and-ingest.md) | The vault layout, content addressing and dedup, the upload pipeline from hash check to mirror |
| 04 | [Database](04-database.md) | Every table, why SQLite runs in WAL mode, migrations, backups |
| 05 | [Scanner and timeline](05-scanner-and-timeline.md) | How the filesystem scanner builds the catalog behind the web timeline |
| 06 | [Thumbnails and media](06-thumbnails-and-media.md) | Thumbnail generation, HEIC and video, previews, downloads and caching |
| 07 | [Web dashboard](07-web-dashboard.md) | The Next.js app: pages, API layer, state, uploads, static export |
| 08 | [Mac app](08-mac-app.md) | SynapsMac: local scanning, green ticks, sync, NAS browser, iPhone import |
| 09 | [iPhone app](09-iphone-app.md) | SynapsiOS: photo library indexing, background sync, matching, Lock Screen progress |
| 10 | [API reference](10-api-reference.md) | Every endpoint with parameters, responses and status codes |
| 11 | [Deployment](11-deployment.md) | `./synaps`, systemd units, CI and the self-updating NAS |
| 12 | [Operations](12-operations.md) | Health checks, logs, backups, maintenance scripts, performance, troubleshooting |
| 13 | [Code walkthroughs](13-code-walkthroughs.md) | End-to-end traces: an iPhone photo backup, a Mac green tick, a thumbnail, a deploy |

## Project notes

- [Roadmap and known issues](project/roadmap.md): open problems first, then planned work
- [History](project/history.md): how the project evolved, phase by phase
- [Versioning](project/versioning.md): version scheme, branch and commit conventions
- [Changelog](../CHANGELOG.md): what shipped in each release

## Keeping the docs current

The docs describe the code, so update the relevant guide in the same pull request as the change. Settings live in [`backend/.env.example`](../backend/.env.example) and [`backend/config.py`](../backend/config.py), and endpoints live in [`backend/routers/`](../backend/routers/): when those change, update the [backend](02-backend.md) and [API reference](10-api-reference.md) guides too.
