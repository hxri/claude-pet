# Claude Pet

A small animated desktop pet for macOS that mirrors what your [Claude Code](https://claude.com/claude-code)
sessions are doing, and that can visit a friend's pet when your laptops are near each other.

- A rabbit (or cat) sits on your desktop. Drag it anywhere.
- It types while Claude works, hops when it's your turn, perks up with a "!" when Claude needs
  you, and naps when nothing is running. The collar tag is the status light.
- Click it for the status card: every session (by its conversation title), its state and last tool, model, context use,
  cost, and your 5-hour / weekly usage.
- Right-click to name it, pick a pet, coat and size, and to send it to a nearby friend's pet.
- Hold **Control + Option** together and it dances (a visiting pet joins in). "Dance!" is in the menu too.

## Install

Requirements: macOS 14 or newer, the Xcode Command Line Tools (`xcode-select --install`),
`jq` (built into macOS 15+, otherwise `brew install jq`), and Claude Code.

```bash
./install.sh
```

That copies the folder to `~/.claude/pet`, builds the app with `swiftc`, adds hooks and a status
line to `~/.claude/settings.json` (a backup is kept next to the app; an existing status line is
preserved and shown as before), installs a login item and starts the pet. Re-running is safe.
Claude Code sessions that were already open start reporting after their next prompt.

On first launch the pet asks for a name. macOS may ask to allow the app to find devices on the
local network; say yes if you want visits to work.

## Visiting a friend

Both laptops need the pet running and either the same Wi-Fi network or Wi-Fi switched on
(discovery also works over Apple's peer-to-peer Wi-Fi, the same mechanism AirDrop uses).

1. Right-click your pet → **Nearby pets** → *Send to \<friend's pet\>*.
2. Your pet poofs away and leaves its bed behind. On your friend's screen the window widens and
   the two pets play: greeting hops, nuzzles with hearts, chasing, zoomies.
3. Your pet keeps showing *your* Claude status while it's away, so your friend can see when you're
   busy. Right-click (or click the bed) → **Call back** brings it home. The host can also send a
   visitor home. If the laptops lose each other, the pet comes home by itself after ~25 seconds.

Everything stays on the local network. Nothing is sent anywhere else, and only the pet's name,
your account's full name, the computer name and the pet's look are shared.

## Make your own pet

Pets are JSON drawings in `pets/` (`rabbit.json` and `cat.json` ship with the app). The easiest
way to get a new one is to ask Claude Code from inside this folder:

```bash
cd ~/.claude/pet
claude "Design me a fox pet with a big bushy tail and a tiny scarf"
```

`CLAUDE.md` in this folder teaches Claude the format; it writes `pets/fox.json`, renders previews
of every state, and you pick the result from the right-click **Pet** menu. A pet's look travels
with it, so your friends see your custom pet when it visits, whatever pets they have.

## Scripting it

The app watches `~/.claude/pet/control/`. Creating a file there triggers an action and the file is
removed: `send` (optional content: part of the friend's pet name), `recall`, `dismiss`, `dance` (content: seconds), `name`
(content: the new name), `pet` (content: a pet id from `pets/`), `snapshot` (writes `snapshot.png`). `net-state.json` lists nearby pets
and the current visit.

## Uninstall

```bash
~/.claude/pet/uninstall.sh          # removes hooks, status line and login item
~/.claude/pet/uninstall.sh --purge  # …and deletes ~/.claude/pet
```

## Hacking

Everything is in `ClaudePet.swift`; `build.sh --restart` rebuilds and relaunches. Preview the pet
offline with `ClaudePet.app/Contents/MacOS/ClaudePet --render <state> out.png [coat] [points] [rabbit|cat]`
and the card with `--render-status out.png [dark]`. `CLAUDEPET_PROFILE=test` runs a second,
independent instance, which is how visits are tested on one machine.
