# Timers2

A Windower 4 Lua addon that tracks job ability recasts, spell recasts, and buff durations for spells and abilities you cast.

Only timers the addon witnesses are tracked — buffs active before the addon loads are intentionally ignored.

## Display

Two default themes are available, switchable at any time with `//ti2 theme <name>`.

### classic (default)

Each row shows a category icon (or coloured dot), spell name, and time remaining overlaid on a progress bar.

- **Orange dot** — Job ability recasts
- **Blue dot** — Spell recasts
- **Green dot** — Buff durations
- **Yellow dot** — Custom timers

Icon PNGs are loaded automatically from `icons/abilities/` and `icons/spells/` when present.

### slim

A minimal plain-text display — no graphics, just `SpellName: M:SS` per line.

## Party Buff Condensing

When the same buff is cast on multiple party members individually (e.g. a Red Mage casting Shell V on six people in succession), the addon collapses those rows into a single entry rather than displaying six near-identical 6-hour timers.

The condensed row shows the spell name with a count suffix — `Shell V [6]` — and tracks the **earliest** expiry among all affected members, so you know exactly when the first one needs to be recast.

### How it works

- Any buff shared by **2 or more** party members is condensed by default.
- The threshold is controlled by the `condense_party_threshold` setting in `data/char/Timers2.xml` (default: `2`; set to `0` to disable).
- The condensed row appears in its own section alongside AOE buffs:
  - `start` mode → **BUFFS - PARTY**
  - `character` mode → **PARTY**
  - `none` mode → inline in the flat list
- If a buff is on fewer members than the threshold, each member's timer is still shown individually in their own player section as before.

### Threshold setting

The threshold is not yet exposed as a command — edit it directly in the saved settings file:

```xml
<condense_party_threshold>3</condense_party_threshold>
```

---

## Grouping and Sorting

### Group type

Controls how timers are bucketed into sections. Recast timers always appear in the left column; buff timers appear in the right column.

| Mode | Behaviour |
|---|---|
| `start` | Right column: BUFFS-SELF / BUFFS-AOE / BUFFS-PARTY / [player] *(default)* |
| `character` | Right column: SELF (self-buffs only) / AOE / PARTY / [player] |
| `none` | Right column: single flat list; party buff rows show `[CharacterName]` or `[N]` count |

### Sort order

Controls the order of rows within each section:

| Mode | Behaviour |
|---|---|
| `duration` | By time remaining *(default)* |
| `name` | Alphabetical |
| `player` | By target name, then duration |
| `creation` | By cast order — oldest first when direction is `asc` |

Sort direction can be set independently per column:

| Command | Default | Effect |
|---|---|---|
| `recastdir asc\|desc` | `asc` | Soonest ready first |
| `buffdir asc\|desc` | `desc` | Longest remaining first |
| `customdir asc\|desc` | `desc` | Longest remaining first |

## Commands

All commands use `//timers2` or `//ti2`.

### Display

| Command | Description |
|---|---|
| `theme <classic\|slim>` | Switch display theme |
| `group <start\|character\|none>` | Set grouping mode |
| `sort <duration\|name\|player\|creation>` | Set sort order |
| `direction <up\|down>` | `down` shows time remaining *(default)*; `up` shows time elapsed |
| `recastdir / buffdir / customdir <asc\|desc>` | Per-column sort direction |
| `recastlimit / bufflimit / customlimit <N>` | Cap rows per section (0 = no limit) |
| `pos <x> <y>` | Set main panel position |
| `custompos <x> <y>` | Set custom timer panel position |
| `interval <seconds>` | Refresh rate (default: 0.5) |
| `tenths` | Toggle sub-second display when < 10s remaining |
| `1hourname` | Toggle hiding the time counter for SP abilities (the "1-hour" abilities that share a recast ID per job) |

### Visibility

| Command | Description |
|---|---|
| `abilities` | Toggle ability recast display |
| `spells` | Toggle spell recast display |
| `buffs` | Toggle buff duration display |

### Theme Settings (classic)

Applied with `//ti2 classic <setting> <values>`.

| Setting | Values | Description |
|---|---|---|
| `highcolor R G B` | 0–255 each | Bar fill when remaining > med threshold *(default green)* |
| `medpercent 0-1` | fraction | Threshold below which mid color activates *(default 0.5)* |
| `medcolor R G B` | 0–255 each | Bar fill in mid range *(default yellow)* |
| `lowpercent 0-1` | fraction | Threshold below which low color activates *(default 0.25)* |
| `lowcolor R G B` | 0–255 each | Bar fill in low range *(default red)* |
| `flash <sec> [R G B]` | seconds + color | Flash buff bars when remaining ≤ this *(default off; set 0 to disable; buffs only)* |
| `bgcolor A R G B` | 0–255 each | Bar background color |
| `textcolor A R G B` | 0–255 each | Row label and time text color |
| `font NAME SIZE` | string + points | Font family and size — see [Available Fonts](#available-fonts) (reloads pool) |
| `spacing N` | pixels | Extra vertical gap between rows |
| `slim` | toggle | Hide all text — show bars and icons only |
| `extend` | toggle | Position time counter outside the bar (to the right) |

### Theme Settings (slim)

Applied with `//ti2 slim <setting> <values>`.

| Setting | Values | Description |
|---|---|---|
| `flash <sec> [R G B]` | seconds | Flash buff rows with `! ` when remaining ≤ this *(default off; set 0 to disable; buffs only)* |
| `textcolor A R G B` | 0–255 each | Display text color |
| `font NAME SIZE` | string + points | Font family and size — see [Available Fonts](#available-fonts) (reloads display) |

### Filters

Named filters let you save a specific combination of category, sort, and whitelist settings and switch between them on demand. Only one filter is active at a time.

| Command | Description |
|---|---|
| `filter list` | List all filters (built-in and user-created) |
| `filter select <name\|none>` | Activate a filter, or clear the active one |
| `filter create <name>` | Create a new user filter |
| `filter delete <name>` | Delete a user filter |
| `filter sort <name> <mode>` | Set the sort order for a filter |
| `filter category <name> <add\|remove> <ability\|spell\|buff\|custom>` | Restrict a filter to specific categories |
| `filter whitelist <name> <add\|remove> <entry>` | Restrict a filter to named entries |

Filter names are case-insensitive. Multi-word names do not need quotes: `//ti2 filter whitelist myfilter add Haste II`.

#### Built-in filters

Built-in filters are always available for selection. They cannot be created, modified, or deleted by the user.

| Name | Description |
|---|---|
| `trust magic` | Hides recast timers for Trust (Alter Ego) summoning spells, including Unity Concord trusts |

### Whitelists and Blacklists

| Command | Description |
|---|---|
| `whitelist abilities add\|remove <name>` | Show only whitelisted abilities (empty = show all) |
| `whitelist spells add\|remove <name>` | Show only whitelisted spells (empty = show all) |
| `blacklist add\|remove <buff name>` | Hide a specific buff from all buff sections |

### Custom Timers

Custom timers render at a separate position (`custompos`) independent of the main panel.

| Command | Description |
|---|---|
| `create <name> <duration>` | Create a custom timer (duration in seconds) |
| `delete <name>` | Remove a custom timer |

Display direction (elapsed vs remaining) is controlled by the global `direction` setting and applies to all timer categories.

### Misc

| Command | Description |
|---|---|
| `help` | Print command reference in chat |

## Available Fonts

The font name passed to `classic font` or `slim font` is any font installed on the Windows system running FFXI. Any valid Windows font name works; the following are included with all modern Windows installations.

**Monospace** (recommended — numbers stay aligned in timer columns):

| Name | Notes |
|---|---|
| `Consolas` | Default. Clean modern monospace, excellent at small sizes |
| `Courier New` | Classic monospace, slightly wider |
| `Lucida Console` | Legible monospace, taller x-height |
| `OCR A Extended` | Technical/retro look |

**Proportional** (letters are narrower/wider based on character):

| Name | Notes |
|---|---|
| `Arial` | Neutral sans-serif, very readable |
| `Arial Narrow` | Compact sans-serif, fits more text per row |
| `Calibri` | Modern sans-serif, slightly rounded |
| `Segoe UI` | Windows system UI font |
| `Tahoma` | Compact, high legibility at small sizes |
| `Verdana` | Wide letterforms, designed for screen |
| `Trebuchet MS` | Humanist sans-serif |
| `Georgia` | Serif, better at larger sizes |
| `Impact` | Condensed heavy weight |

Font names are case-insensitive and must match the Windows font family name exactly (e.g. `Courier New`, not `CourierNew`). If the specified font is not found, Windows substitutes a default.

## Examples

```
//ti2 theme slim
//ti2 group character
//ti2 sort name
//ti2 pos 800 100

//ti2 create Bolster 180
//ti2 delete Bolster
//ti2 direction up

//ti2 whitelist abilities add Meditate
//ti2 blacklist add Protect

//ti2 filter create meleeBuffs
//ti2 filter category meleeBuffs add buff
//ti2 filter sort meleeBuffs duration
//ti2 filter select meleeBuffs

//ti2 filter select trust magic
//ti2 filter select none
```

## File Structure

```
Timers2/
  Timers2.lua          Main addon — event handling and commands
  data.lua             Data layer — state, timer collection, grouping/sorting
  themes/
    classic.lua           Bar + icon display theme
    slim.lua           Plain text display theme
  icons/
    abilities/         Ability icon PNGs named by recast ID (e.g. 00036.png)
    spells/            Spell icon PNGs named by spell ID (e.g. 00004.png)
```

## Installation

Place the `Timers2` folder in your `Windower/addons/` directory and load with:

```
//lua load Timers2
```

Or add it to your profile's autoload list.