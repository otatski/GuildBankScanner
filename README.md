# GuildBankScanner

A World of Warcraft: Midnight addon that scans your guild bank and exports the full inventory as a CSV. Designed to work alongside the [Guild Bank Scanner web app](https://craftingplanner.com/) for crafting analysis — paste the CSV in, select the recipes you care about, and see exactly how many you can craft from what's in the bank.

---

## Installation

1. Download or clone this repository.
2. Copy the `GuildBankScanner` folder into your addons directory:
   ```
   World of Warcraft/_retail_/Interface/AddOns/GuildBankScanner/
   ```
3. Launch WoW (or reload the UI with `/reload`) and enable the addon on the character selection screen.

You should see `[GuildBankScanner] Loaded.` in your chat when you log in.

---

## Usage

### Slash command

You must be standing at the guild bank for a fresh scan:

| Command | Description |
|---|---|
| `/gbscan` | Scan the guild bank and open the export window |
| `/gbscan export` | Re-open the export window from the last saved scan |
| `/gbscan help` | Print command reference to chat |

`/guildbankscanner` works as an alias for all commands above.

---

## Exporting the Inventory

After a scan completes, an export window opens automatically. It contains the full CSV pre-selected. To copy it:

1. Click **Select All** (or press `Ctrl-A` inside the text box).
2. Press `Ctrl-C` to copy.
3. Paste into the [Guild Bank Scanner web app](https://craftingplanner.com/) on the Import screen.

The last scan is saved to disk (`SavedVariables`) so you can re-open the export window at any time with `/gbscan export` — even after closing the guild bank or logging out.

---

## CSV Format

```
# GuildBankScanner Export
# Guild: <Your Guild Name>
# Scanned: 2026-03-14 20:45
itemID,name,totalCount,tabs
12345,Nocturnal Lotus,240,Reagents|Crafting
67890,Tranquility Bloom,180,Crafting
```

| Column | Description |
|---|---|
| `itemID` | Numeric WoW item ID |
| `name` | Item name (commas escaped as semicolons) |
| `totalCount` | Total quantity across all scanned tabs |
| `tabs` | Pipe-separated list of tab names where the item was found |

---

## Known Limitations

- **You must be physically at the guild bank.** The WoW API only returns item data while the bank window is open — the addon cannot scan remotely.
- **Only accessible tabs are scanned.** Tabs your character doesn't have view permission for are automatically skipped.
- **Button incompatibility.** The Scan Bank button attaches to the default Blizzard guild bank frame. If you use an addon that replaces that frame (e.g. Bagnon), the button won't appear — use `/gbscan` instead.
- **Item names may be cached.** If an item name shows as an item link (`|Hitem:...|h`) in the CSV, it means the item wasn't in the client's cache at scan time. Open the item's tooltip in-game to cache it, then rescan.

---

## File Structure

```
GuildBankScanner/
├── GuildBankScanner.toc   — addon metadata and interface version
└── GuildBankScanner.lua   — all addon logic
```

---

## Compatibility

| Field | Value |
|---|---|
| Expansion | World of Warcraft: Midnight |
| Interface | 120001 |
| Version | 0.0.1 |
