---
version: 1
slug: "frontend-src-app-page-tsx"
primary_target: "frontend/src/app/page.tsx"
related_targets: []
---

---
version: 1
slug: "frontend-src-app-page-tsx"
primary_target: "frontend/src/app/page.tsx"
related_targets: []
---

# Stats dashboard (web app home, `/`)

Mode: Operate. Audience: the owner only, checking that the NAS is healthy and every device is backing up. Seen on a Mac at a desk, a Mac late at night, an always-on spare screen, and a phone. Data: `/api/system/*` (PR #99). Replaces the photo timeline at `/`; the timeline moves to `/library`. Problems show on the page; no notifications.

## Unresolved

- The owner chose this look for the whole web app. Only `/` is built in it so far; Library, Finder, Search, Trash, Settings and Sync still use the earlier Liquid Glass look (on the new shared ground) and are the next surfaces to move over.
- Temperature has no warning threshold until the NAS's real sensor range is known (phase 4 of #97).

## Direction contract

THESIS: The NAS as a stack of home-screen widgets: each tile answers one question with one big number you can read from across the room. Refuses the admin-template grid of equal stat cards with charts crammed in, and refuses a monitoring console.

OWN-WORLD: Apple widget language. Near-black ground (#0e0f10), raised tiles (#1d1f21) with ~22px continuous corners, no borders or shadows on tiles; system type (SF on Apple devices: the world's own voice, and PRODUCT.md rules out internet fonts) with large semibold figures and 13px semibold labels; tabular numerals. Colour does jobs only: green (#34c759) healthy and data highlight, amber (#ff9f0a) needs attention, red (#ff453a) critical; everything else greyscale. Light theme mirrors it on #f2f2f7 / #ffffff.

STORY: In one glance the owner knows: is anything wrong, how full is the disk, is the machine coping, and has every device backed up recently. Detail (exact values, history, per-device numbers) is a hover or tap away, never in the way.

FIRST VIEWPORT: Sidebar nav (Dashboard, Library, Finder, Search, Trash, Settings) stays the app's shell. Header: "Home Cloud", host name and last-checked time, 24h/7d/30d range control. Grid of widget tiles in three sizes (small 1x1, wide 2x1, large 2x2): large Disk tile with ring and "full in ~N months" at top-left; small CPU, Memory, Temperature, Network, Uptime tiles; a Needs-attention tile that turns amber when something is wrong and reads "All good" otherwise; wide Today tile; large Devices tile (each device, last backup, files, amber when late); large Backed-up-per-day chart; Recent activity list below the fold.

FORM: Glance Widgets (Apple home-screen widgets and the Weather app), my top-ranked grounded candidate, taken as IMPECCABLE'S PICK over the assigned Arrivals Board. seed:a9cce71610a5d2b4. Signature move: tiles reflow by size like a widget stack, and a tile changes state colour as a whole (the Needs-attention tile goes amber) instead of adding badges.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
