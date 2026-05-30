# Orkhys REAPER Scripts

A collection of REAPER scripts for live performance, distributed via [ReaPack](https://reapack.com/).

## Installation

1. Install [ReaPack](https://reapack.com/) in REAPER
2. Extensions > ReaPack > Import repositories
3. Paste: `https://github.com/Lanceliogs/reaper-scripts-orkhys/raw/main/index.xml`
4. Extensions > ReaPack > Synchronize packages

## Scripts

### Setlist Manager

Reorderable live setlist manager that decouples show order from timeline layout. Build your setlist from project regions, reorder freely, and let the script handle playback jumps between songs.

**Features:**
- Region-based song discovery (automatically finds named regions)
- Drag-free reordering with persistent setlist
- Linked songs for seamless transitions (medleys, intros)
- Navigation lock while playing (prevents accidental skips)
- JSON export/import for sharing setlists between gigs
- Dockable ReaImGui interface

**Requirements:** REAPER 7.x, ReaImGui extension

## Updating

Hit Extensions > ReaPack > Synchronize packages to get the latest versions.

## License

MIT
