# Claude Pet — guide for Claude (pet authoring)

This folder is the Claude Pet desktop app (README.md). **Pets are data, not code**: each pet is a
JSON file in `pets/` that the app renders and animates. When the user asks you to create, change
or tweak a pet, write or edit a spec file and preview it. Do not touch `ClaudePet.swift` for that.

## Workflow

1. Read `pets/rabbit.json` and `pets/cat.json`; they are complete, polished examples.
2. Write `pets/<id>.json` (`id`: lowercase letters/digits, e.g. `fox`). Keep `name` short.
3. Check and preview it. The app binary renders PNGs offline, one per state:
   ```bash
   ClaudePet.app/Contents/MacOS/ClaudePet --check pets/fox.json
   for s in ready working waiting attention sleeping; do
     ClaudePet.app/Contents/MacOS/ClaudePet --render $s /tmp/fox-$s.png - 220 pets/fox.json
   done
   ```
   Look at the PNGs with the Read tool and iterate until all five states look right.
   (Arguments: state, output, coat index or `-` for the pet's own colours, size in points, pet file.)
4. Activate it: `echo fox > control/pet` (or right-click the pet → Pet). The running app also
   reloads the active pet whenever its file changes, so edits show up live.
5. If the app is not built yet: `./build.sh`. If it is not running: `./install.sh`.

## Canvas and conventions

- Canvas is **180 × 190 points, origin bottom-left, y up**. The pet stands on `layout.groundY`
  (18–20) centred at **x = 84**. Keep every part inside x 16…172 and y 0…176: the pet hops up to
  14 pt and the speech bubble sits at `layout.bubble`.
- Parts draw in array order (first = behind). Put the tail, back legs and far ears first.
- The whole pet automatically breathes, hops, wiggles, flips to face left/right, and gets a ground
  shadow of `shadowRX`; you only draw the standing pose.

### Top-level fields

| field | meaning |
|---|---|
| `format` | always `1` |
| `id`, `name` | file id and display name |
| `palette` | named colours, `"#RRGGBB"` / `"#RRGGBBAA"` or `null` |
| `layout` | `groundY`, `head` `[x, y, r]` (click target), `bubble` `[x, y]` (44×26 box, bottom-left corner), `zzz` `[x, y]`, `badge` `[x, y]`, `shadowRX` |
| `parts` | the drawing |

**Palette keys**: `fur`, `furLight`, `furDark`, `belly`, `ear`, `nose`, `blush`, `eye`, `pupil`
(`null` = solid dark eyes; a colour gives an iris with a dark pupil), `collar`, `stripe` (`null` =
parts filled with `stripe` are skipped). Use these keys for the main colours so the Coat menu can
recolour the pet; raw hex is fine for accents. Anything referenced must exist.

### Part types

Common fields on every part: `type`, `show` (visibility condition), `mirror` (also draw mirrored
across x = 84; channel names ending in `L`/`R` swap, so one ear definition makes both ears),
`anim` (transforms, below), `alpha`.

| type | fields |
|---|---|
| `ellipse` | `cx cy rx ry` (ry defaults to rx) + `fill` or `gradient [top, bottom]`, `stroke`, `width` |
| `rect` | `x y w h radius` + fill/gradient/stroke/width |
| `path` | `d` SVG path (`M L H V C Q Z`, absolute or relative) + fill/gradient/stroke/width; `outline` + `outlineWidth` draws a wider stroke underneath (use for stroked tails) |
| `arc` | `cx cy r start end` degrees (counter-clockwise, 0 = +x) + `stroke`, `width` — collars |
| `lines` | `lines: [[x1,y1,x2,y2], …]` + `stroke`, `width`, `alpha` — whiskers, toes |
| `eye` | `cx cy size` — a complete eye that blinks, looks around, goes ^ ^ when happy and closes asleep |
| `tag` | `cx cy r` — the status light; **every pet needs exactly one** (usually hanging from a collar arc) |
| `group` | `parts: [...]` — share one transform |

The sticker look used by the built-in pets: `gradient ["furLight","fur"]` + `stroke "furDark"`
`width 1.6`, a lighter `belly`, two `blush` ellipses, eyes about 24 pt apart.

### Animation

`anim` is an ordered list of transforms, each driven by a channel value:

- `{"rotate": "<channel>", "pivot": [x, y], "deg": k}` rotates by channel × k degrees, or
  `{"rotate": "<channel>", "pivot": [x, y], "range": [atMinus1, atZero, atPlusOne]}` maps the
  channel through three key angles (asymmetric ranges, e.g. rabbit ears `[70, 12, 0]`).
- `{"translate": "<channel>", "dx": kx, "dy": ky}` moves by channel × (kx, ky).
- `{"scale": "<channel>", "sx": kx, "sy": ky, "pivot": [x, y]}` scales by 1 + channel × k.

Positive rotation is counter-clockwise; on a mirrored copy it appears clockwise, so left/right
parts stay symmetric automatically.

| channel | range | meaning |
|---|---|---|
| `tail` | −1…1 | sway: slow when idle, fast when working, frantic when alarmed |
| `earL`, `earR` | −1…1 | −1 flattened/drooped (asleep, carried), 0 neutral, +1 perked (alarmed, hovered); small flicks while idle |
| `pawL`, `pawR` | 0…1 | alternate lifts while working ("typing") |
| `feet` | 0…1 | 1 while the pet is dragged |
| `nose`, `noseUp` | −1…1 / 0…1 | short twitch bursts |
| `headTilt` | 0…1 | 1 while asleep |
| `breath` | −1…1 | slow sine (the body already uses it) |
| `bob`, `bobFast` | −1…1 | 2 Hz and 5 Hz sines for anything extra: wings, antennae, a bouncing hat |
| `hop` | 0…1 | current hop height (ears can trail it) |
| `one` | 1 | constant |

`show` conditions: `smile` / `open` (mouth), `awake` / `asleep`, `dragging`, `working`,
`attention`, `waiting`, `ready`. Use `smile`/`open` pairs for the mouth: `open` is used when the
pet is alarmed or carried.

## Design tips

- Chibi proportions read best at 130–170 pt: head ≈ 40 % of the height, big eyes, small body.
- Give every pet something that moves: ears or antennae on `earL`/`earR`, a tail on `tail`, front
  paws on `pawL`/`pawR`, wings on `bobFast` (they flap while working), a nose on `nose`.
- Check all five states; `sleeping` folds ears to −1 and closes the eyes, `attention` perks them
  to +1 with wide eyes and an open mouth, so make sure those extremes still look good.
- A `tag` on a collar arc at the neck keeps the status light visible in every pose.
