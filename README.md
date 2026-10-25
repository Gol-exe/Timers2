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
- Condensing looks at every row before `bufflimit` trims the sections, so a shared buff is condensed even when one member's own list would have been cut before reaching it.

### Threshold setting

The threshold is not yet exposed as a command — edit it directly in the saved settings file:

```xml
<condense_party_threshold>3</condense_party_threshold>
```

## Naturalist's Roll

[Naturalist's Roll](https://www.bg-wiki.com/ffxi/Naturalist%27s_Roll) lengthens Enhancing Magic its holders receive, by an amount that depends on the roll number and the Corsair's gear. Neither is visible to us, so the addon **measures** it:

1. While you hold the roll, cast an Enhancing spell on yourself (Haste, Protect, Refresh, ...). An AOE that includes you counts too (Accession, Diffusion): it keeps a single AOE row, and your own copy is still read from your buff list for the measurement.
2. The server reports how long the buff really lasts. Its difference from the addon's own estimate (which leaves the roll out) is the roll's potency. The roll adds to the gear-listed enhancing duration percentage, as bg-wiki's formula puts it, and the measurement accounts for that.
3. Enhancing spells you then cast on party members who **also** hold the roll (seen in the party buff list) assume the same potency. An AOE row is lengthened only when everyone it covers holds the roll; otherwise it keeps the plain time, the soonest any of them runs out.

Details:

- Recasting a buff you still have: a buff list that shows the copy from before the cast is skipped, and the measurement waits for the one showing the new copy. (A recast within about 2 seconds of the old copy's time can't be told apart and isn't measured.)
- A party member buffed while holding the roll **before** you have measured it is corrected as soon as your measurement comes in, provided it is still the same roll.
- The measurement is forgotten when the roll leaves your buff list, or when its remaining time jumps up (it was rolled again, so the number may have changed). A later self-cast measures again; the latest measurement wins.
- No measurement is taken when something else would distort it: Embolden on you, a Rune Fencer main whose job points the client does not show (its gifts would be measured as roll), a duration cap (Composure's 30 minutes, Aquaveil's cap), a spell whose base duration is random (Sneak, Invisible and Deodorize last a random 7.5 to 10 minutes), or a spell too short to tell rolls apart (one second of server rounding must move the result by 2% or less).

## Rune Fencer gifts

A Rune Fencer main at level 99 receives Enhancing Magic for longer: +10% at 100 job points spent and another +10% at 1200 ([bg-wiki](https://www.bg-wiki.com/ffxi/Rune_Fencer)), a separate multiplier after the duration augments.

- **You as a Rune Fencer:** your own job points are known, so your own buffs include the exact gifts.
- **A Rune Fencer in your party:** their job points are hidden, but a mastered job (2100 spent) holds both gifts, so a mastered Rune Fencer gets +20% on Enhancing spells you cast on them. Mastery is recognised by the **job mastery stars** over their head, or by a **master level above 0**, which only a mastered job can earn. Once seen, the stars count until that member changes job, so hiding them afterwards does not undo it.
- A Rune Fencer showing neither might have no gift, one or both; their timer keeps the plain estimate, the soonest they could run out. The same holds below level 99 (gifts are off when level-synced).
- An AOE row gets the gifts only when everyone it covers is a mastered Rune Fencer.

### Embolden

A Rune Fencer's [Embolden](https://www.bg-wiki.com/ffxi/Embolden) makes the next Enhancing spell they receive stronger but **halves its duration**, and is used up by it.

- An Enhancing spell you cast on a party member whose buff list shows Embolden is estimated at half. The buff is treated as used straight away, so a second spell sent before their buff list updates is not halved again. Songs and Blue Magic neither use it nor are halved.
- It combines with the rest: a mastered Rune Fencer with Embolden gets Haste at 180 x 1.2 x 0.5 = 108s.
- An AOE row takes the soonest any target runs out, so one Emboldened target halves the row.
- As an Emboldened Rune Fencer casting on yourself, your own copy is halved too. Embolden still blocks a Naturalist's Roll measurement.
- Evasionist's Cape augments change Embolden; that gear is the Rune Fencer's, which the addon cannot see.

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
| `recastlimit / bufflimit / customlimit <N>` | Cap rows per section (0 = no limit); `bufflimit` applies to each buff section, including the condensed party one |
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

Hiding a recast section also resets its bars: a recast seen again after being hidden is drawn against the time it had when it reappeared.

### Theme Settings (classic)

Applied with `//ti2 classic <setting> <values>`. `//ti2 classic` on its own lists the settings and what each takes.

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
| `font NAME [SIZE]` | string + points | Font family and size — see [Available Fonts](#available-fonts) (reloads pool) |
| `bold` | toggle | Bold row labels and times (reloads pool) |
| `spacing N` | pixels | Extra vertical gap between rows |
| `slim` | toggle | Hide all text — show bars and icons only |
| `extend` | toggle | Position time counter outside the bar (to the right) |

### Theme Settings (slim)

Applied with `//ti2 slim <setting> <values>`. `//ti2 slim` on its own lists the settings and what each takes.

| Setting | Values | Description |
|---|---|---|
| `flash <sec> [R G B]` | seconds | Flash buff rows with `! ` when remaining ≤ this *(default off; set 0 to disable; buffs only)* |
| `textcolor A R G B` | 0–255 each | Display text color |
| `font NAME [SIZE]` | string + points | Font family and size — see [Available Fonts](#available-fonts) (reloads display) |
| `bold` | toggle | Bold text (reloads display) |

### Filters

Named filters let you save a specific combination of category, sort, and whitelist settings and switch between them on demand. Only one filter is active at a time.

| Command | Description |
|---|---|
| `filter list` | List all filters (built-in and user-created) |
| `filter select <name\|none>` | Activate a filter, or clear the active one |
| `filter create <name>` | Create a new user filter |
| `filter delete <name>` | Delete a user filter |
| `filter sort <name> <duration\|name\|player\|creation>` | Set the sort order for a filter |
| `filter category <name> <add\|remove> <ability\|spell\|buff\|custom>` | Restrict a filter to specific categories |
| `filter whitelist <name> <add\|remove> <entry>` | Restrict a filter to named entries |

`//ti2 filter` on its own lists the subcommands. Filter names are case-insensitive. Multi-word names do not need quotes: `//ti2 filter whitelist myfilter add Haste II`.

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
| `help` | Print command reference in chat (generated from the same table the commands run from) |

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
  Timers2.lua          Main addon — settings and event wiring
  tracker.lua          Packet handling — turns casts, buff lists and messages into timers
  commands.lua         Chat commands, usage text and help, from one command table
  data.lua             Data layer — state, timer collection, grouping/sorting
  formatting.lua       Time strings and row labels shared by the themes
  naturalist.lua       Measures Naturalist's Roll on our own buffs for party estimates
  buff_duration.lua    Duration estimates for buffs cast on others (gear, merits, job points)
  buff_gear.lua        Gear whose description states no number
  themes/
    classic.lua        Bar + icon display theme (and its default settings)
    slim.lua           Plain text display theme (and its default settings)
  icons/
    abilities/         Ability icon PNGs named by recast ID (e.g. 00036.png);
                       the shared SP abilities add the job id: 00000.16.png is
                       Blue Mage's one-hour ability, 00254.16.png its second SP ability
    spells/            Spell icon PNGs named by spell ID (e.g. 00004.png)
```

A row whose icon file is missing shows the coloured category dot instead. These
one-hour ability icons do not exist yet: `00000.01.png` (Warrior), `00000.16.png`
(Blue Mage), `00000.21.png` (Geomancer) and `00000.22.png` (Rune Fencer). Add a 32x32
PNG with that name and the addon picks it up.

## Installation

Place the `Timers2` folder in your `Windower/addons/` directory and load with:

```
//lua load Timers2
```

Or add it to your profile's autoload list.

## Testing

These commands are for checking the duration estimates and may change without notice.

| Command | Description |
|---|---|
| `gear` | List the duration gear and augments detected on what you are wearing |
| `last` | Show step by step how the last buff duration was calculated, with the current Naturalist's Roll measurement and its inputs |
| `calibrate` | Toggle a chat line comparing our estimate with the server's time for buffs on yourself |
