---
name: Synaps
description: The owner's control room for a one-family home NAS, read at a glance as a stack of widgets.
colors:
  ground: "#0e0f10"
  ground-light: "#f2f2f7"
  tile: "#1d1f21"
  tile-light: "#ffffff"
  track: "#2c2e31"
  track-light: "#e5e5ea"
  rule: "rgba(255, 255, 255, 0.08)"
  rule-light: "rgba(60, 60, 67, 0.12)"
  text: "#f2f2f7"
  text-light: "rgba(0, 0, 0, 0.88)"
  text-secondary: "#aeaeb2"
  text-secondary-light: "#636366"
  grey-1: "#8e8e93"
  grey-2: "#48484a"
  grey-2-light: "#c7c7cc"
  green-fill: "#34c759"
  green-soft: "#2b5236"
  green-soft-light: "#c9ecd3"
  amber-fill: "#ff9f0a"
  amber-text: "#ffb340"
  amber-text-light: "#b25000"
  amber-tile: "#33260f"
  amber-tile-light: "#fff3e0"
  red-fill: "#ff453a"
  red-fill-light: "#ff3b30"
  red-text: "#ff6961"
  red-text-light: "#c4000f"
  red-tile: "#3a1714"
  red-tile-light: "#ffebe9"
  focus-blue: "#0a84ff"
  link: "#4aa3ff"
  link-light: "#0060d1"
  pop: "#3a3c3f"
  pop-light: "#1d1f21"
  pop-text: "#f2f2f7"
typography:
  figure:
    fontFamily: "ui-rounded, -apple-system, BlinkMacSystemFont, 'SF Pro Rounded', system-ui, sans-serif"
    fontSize: "44px"
    fontWeight: 600
    lineHeight: 1
    letterSpacing: "-0.02em"
    fontFeature: "tnum"
  figure-large:
    fontFamily: "ui-rounded, -apple-system, BlinkMacSystemFont, 'SF Pro Rounded', system-ui, sans-serif"
    fontSize: "54px"
    fontWeight: 600
    lineHeight: 1
    letterSpacing: "-0.02em"
    fontFeature: "tnum"
  unit:
    fontFamily: "ui-rounded, -apple-system, BlinkMacSystemFont, 'SF Pro Rounded', system-ui, sans-serif"
    fontSize: "20px"
    fontWeight: 600
    letterSpacing: "0"
  statement:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', system-ui, sans-serif"
    fontSize: "17px"
    fontWeight: 600
    lineHeight: 1.375
  title:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', system-ui, sans-serif"
    fontSize: "15px"
    fontWeight: 600
  body:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', system-ui, sans-serif"
    fontSize: "14px"
    fontWeight: 400
  label:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 600
  caption:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.35
    fontFeature: "tnum"
  tooltip:
    fontFamily: "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 400
    lineHeight: 1.3
rounded:
  bar: "3px"
  focus: "6px"
  tip: "10px"
  tile: "22px"
  pill: "9999px"
spacing:
  bar-gap: "3px"
  label-gap: "6px"
  grid-gap: "16px"
  tile-y: "16px"
  tile-x: "18px"
  row: "168px"
components:
  tile:
    backgroundColor: "{colors.tile}"
    textColor: "{colors.text}"
    rounded: "{rounded.tile}"
    padding: "16px 18px"
  tile-warn:
    backgroundColor: "{colors.amber-tile}"
    textColor: "{colors.text}"
    rounded: "{rounded.tile}"
    padding: "16px 18px"
  tile-crit:
    backgroundColor: "{colors.red-tile}"
    textColor: "{colors.text}"
    rounded: "{rounded.tile}"
    padding: "16px 18px"
  tile-label:
    textColor: "{colors.text-secondary}"
    typography: "{typography.label}"
  tile-label-warn:
    textColor: "{colors.amber-text}"
    typography: "{typography.label}"
  tile-label-crit:
    textColor: "{colors.red-text}"
    typography: "{typography.label}"
  tooltip:
    backgroundColor: "{colors.pop}"
    textColor: "{colors.pop-text}"
    typography: "{typography.tooltip}"
    rounded: "{rounded.tip}"
    padding: "6px 9px"
  text-link:
    textColor: "{colors.link}"
    typography: "{typography.body}"
---

# Design System: Synaps

## Overview

**Creative North Star: "Glance Widgets"**

The NAS is read like a stack of Apple home-screen widgets. Each raised tile answers one question with one large rounded figure that can be read from across the room, a short label above it and a quiet caption below. Detail (exact values, history, per-device numbers) waits behind a hover, focus or tap; it never sits in the way of the figure.

The world is quiet greyscale on a near-black ground (a light grey ground in the light theme). Colour is not decoration and not category: it says healthy, needs attention or critical, and nothing else. When something is wrong, the place that reports it changes as a whole, the way a widget does, rather than collecting badges.

The system currently covers the dashboard at `/` and the disk indicator in the sidebar. Library, Finder, Search, Trash, Settings and Sync still render in the incumbent "Liquid Glass" shell (translucent blurred panels, Apple Blue accent, `--glass-*` and `--accent*` tokens in `globals.css`), sitting on this world's shared ground. They are the next surfaces to move over; until then the shell's tokens remain in force for them and are not part of this world.

**Key Characteristics:**
- Raised flat tiles in three sizes on a plain ground; no borders, no shadows, no blur.
- One big tabular figure per tile, in the system's rounded face.
- Colour for state only: green, amber, red; everything else greyscale.
- Exactly one tile (Needs attention) changes its whole background with state.
- Missing data is said in words, at a size that cannot pass for a number.
- System fonts only; nothing loads from the internet.

## Colors

A greyscale world with three state colours held in reserve, each in three strengths: a fill for marks, a text tone for labels, and a tile tint for the one tile that changes as a whole. Every colour has a light-theme counterpart (the `-light` keys); keys without one are the same in both themes.

### Primary
- **Healthy Green** (green-fill): the healthy state on marks (disk ring, sidebar disk bar) and the data highlight in the backups chart (today's bar, the hovered bar). **Muted Green** (green-soft) is the resting backups bar and the text-selection tint.

### Secondary
- **Attention Amber** (amber-fill): ring and sidebar bar from 85% disk. **Amber Text** (amber-text) colours a reporting tile's label and a late device's time. **Amber Tile** (amber-tile) is the Needs-attention tile's background in its warning state.

### Tertiary
- **Critical Red** (red-fill): ring and sidebar bar from 95% disk. **Red Text** (red-text) for a critical label; **Red Tile** (red-tile) for Needs attention when the NAS is unreachable or the disk is critical.

### Neutral
- **Night Ground** (ground): the page behind the tiles.
- **Raised Tile** (tile): every widget surface; also the halo around a sparkline's "now" dot.
- **Track** (track): empty part of the ring and the storage bar, zero-file days in the chart.
- **Hairline** (rule): dividers between list rows inside a tile.
- **Text** (text) and **Secondary Text** (text-secondary): figures and values, then labels, units, captions and device icons.
- **Grey 1 / Grey 2** (grey-1, grey-2): sparkline strokes, and the lighter vault-kind segments. Photos take the full text tone, videos Grey 1, other Grey 2.
- **Pop** (pop, pop-text): the tooltip material.

### Interaction
- **Focus Blue** (focus-blue) is the 2px focus outline; **Link Blue** (link) is the one text button ("Show older uploads"). Blue marks what can be operated, never a state. The range control currently renders in the shell's segmented control (Apple Blue indicator), consistent with this rule.

### Named Rules
**The State-Only Rule.** Green, amber and red mean healthy, attention and critical. Categories, series and kinds are told apart in greys (the vault bar is text, Grey 1, Grey 2), never in hues.

**The Grey Line Rule.** Sparklines are drawn in Grey 1 with a soft fade beneath. A metric earns state colour only when it has a threshold; temperature stays grey until the NAS's real sensor range is known.

## Typography

**Figure Font:** ui-rounded (SF Pro Rounded on Apple devices), falling back to the system stack
**Body Font:** the system stack (-apple-system, SF Pro Text, Segoe UI, system-ui)

**Character:** Apple's own voice, rounded for numbers and plain for words. PRODUCT.md rules out internet fonts, and the world's reference (home-screen widgets) uses exactly these faces.

### Hierarchy
- **Figure** (600, 44px, line-height 1, -0.02em, tabular): the one number a small or wide tile exists to show.
- **Figure Large** (600, 54px): the same in a large tile. The Disk tile sets its figure at 40px beside the ring.
- **Unit** (600, 20px, secondary text): directly after a figure, 3px gap ("GB free", "%", "files").
- **Statement** (600, 17px, ~1.375): a sentence that stands in for a figure, as in Needs attention; 15px when two problems share the tile. A missing reading uses 17px regular in secondary text and the plain face.
- **Title** (600, 15px): a row's name in a list tile (device names, last-backup times).
- **Body** (400, 14px): activity rows and the text link.
- **Label** (600, 13px, secondary text): the tile's name, preceded by a 14px line icon at 6px gap. Sentence case, no tracking.
- **Caption** (400, 13px, 1.35, tabular): context under a figure, chart axes, list sub-lines.
- **Tooltip** (400, 12px, 1.3): chart readouts, value in semibold.

### Named Rules
**The Tabular Rule.** Every number that updates (figures, captions, times, sizes) uses tabular numerals so live values do not jitter.

**The Words-Not-Zeros Rule.** A reading that does not exist is said in words ("Unknown", "No data yet", "Not measured on this machine") at the statement size in secondary text, never as a placeholder number.

## Layout

A widget stack. Columns follow the space beside the sidebar (a container query on the widgets area), not the window: 2 columns by default, 4 from 720px, 6 from 1100px. Rows are a fixed 168px with a 16px gap and dense auto-flow. Tiles come in three sizes: small (1x1), wide (2x1, spans two columns) and large (2x2). Tile order is chosen so every column count packs without holes.

Inside a tile the label sits at the top and the figure is pushed to the bottom (`margin-top: auto`), with caption and sparkline beneath, so the eye lands on the same baseline across a row. Page padding is 16px, 24px from the large breakpoint. A list that outgrows the grid (Recent activity) sits below it as one full-width tile with zero padding and hairline-divided rows inset 18px.

On a phone the range control drops to its own centred row under the title so the title keeps its width.

## Elevation & Depth

Flat. Depth is tonal only: a tile is one step lighter than the ground (#1d1f21 on #0e0f10; white on light grey in the light theme). Tiles have no border and no shadow. The only floating thing is the tooltip, which is a solid Pop surface without a shadow. The single ring-like effect is the 2px tile-coloured halo that lifts a sparkline's "now" dot off its line.

### Named Rules
**The Flat Stack Rule.** Tiles never take shadows, borders or backdrop blur. Separation comes from the step between ground and tile, nothing else.

## Shapes

Continuous-feeling 22px corners on every tile, clipped (`overflow: hidden`), so contents never break the silhouette. Smaller radii scale down with the element: 10px tooltips, 6px focus outline, 3px chart bars, fully round dots, storage bar and ring caps. Lines inside tiles are hairlines (rule), never boxes.

## Components

### Tiles (Cards / Containers)
Calm, raised, one question each.
- **Corner Style:** 22px.
- **Background:** Raised Tile; Amber Tile or Red Tile only for the state-changing tile.
- **Shadow Strategy:** none (see Elevation & Depth).
- **Border:** none.
- **Internal Padding:** 16px top and bottom, 18px left and right.
- **Header:** label with icon at left; an optional aside (a caption such as "Last 30 days") at right.
- **State:** `state` changes the whole background and the label (Needs attention only); `accent` changes the label colour only, for tiles that report a state in their own marks (Disk). The background change eases over 0.6s on cubic-bezier(0.16, 1, 0.3, 1), and is instant under reduced motion.

### Disk Ring (signature)
A 136px ring with a 14px stroke and round cap on the Track, filled in the state's fill colour (green under 85%, amber from 85%, red from 95%), with the percentage at its centre. The sidebar's disk bar uses the same thresholds and fills.

### Sparkline
A 2px Grey 1 line over a fixed time window shared by every chart in the range, so charts line up and collection gaps show as gaps. A fade from 32% to 0 sits under the line; a 7px "now" dot marks the latest value. Hover, focus or the arrow keys draw a 1px secondary-text cursor and open a tooltip.

### Day Bars
One bar per day, 3px apart, 3px corners. Days with files are Muted Green, today and the hovered bar are Healthy Green, empty days are a 2px Track stub. Every bar is focusable and opens a tooltip; tips near the tile edges open inward.

### Tooltip
Pop material, 10px corners, 6px by 9px padding, 12px text with the value in semibold, sitting 6px above its mark. Never shadowed.

### Lists inside tiles
10px vertical padding per row, hairline between rows, title on the left with a caption beneath, value on the right. A late item turns its value and caption Amber Text; it does not gain a badge.

### Text Link
14px semibold Link Blue, no underline, 50% opacity when disabled.

### Focus
2px Focus Blue outline, 2px offset, 6px radius, on every focusable element in the dashboard.

## Do's and Don'ts

### Do:
- **Do** give each tile one question and one figure, with the figure at the tile's bottom edge.
- **Do** keep sparklines grey and the vault breakdown in greys; spend green, amber and red only on state.
- **Do** let Needs attention, and only Needs attention, change its whole background (Amber Tile, Red Tile).
- **Do** report state on other tiles through the label (`accent`) and their own marks (the ring, a late device's time).
- **Do** say missing readings in words at 17px in secondary text.
- **Do** use tabular numerals for every live number.
- **Do** keep blue for focus and links only.

### Don't:
- **Don't** add shadows, borders or backdrop blur to tiles.
- **Don't** give a second tile a whole-background state change; that move belongs to Needs attention.
- **Don't** add badges, pills or dots to signal a problem; change the tile, the label or the value's colour.
- **Don't** colour categories or data series with hues.
- **Don't** load fonts from the internet; use the system stack and ui-rounded.
- **Don't** show a placeholder or estimated number where no reading exists.
- **Don't** carry the Liquid Glass shell's glass panels, accent gradients, glows or uppercase tracked section labels into surfaces built in this world.
