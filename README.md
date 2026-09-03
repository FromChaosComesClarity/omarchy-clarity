# Clarity, Omarchy bar widget and game launcher

Your game library in the Omarchy bar, and one keystroke away: how many games are
installed, what is running right now, and a fuzzy launcher that starts any of them.

**In the bar**

- **Left click**, a menu: the library, the launcher, Couch Mode, Manage Storage, the Control
  Panel, and what is playing when something is
- **Middle click**, straight to Couch Mode, the fullscreen couch face, with no menu in the way
- Bindable to a key too: `omarchy-shell io.github.fromchaoscomesclarity.clarity menu`

**The launcher** (an overlay, bind it to a key, see below)

- Type a few letters of a game's name, press **Enter**, play it
- The game you are pointing at shows its **cover, genre, year, store, hours played and a
  sentence about it**, which is what tells two games with similar names apart
- **Shift+Enter** opens the game's page instead, for the description, the
  achievements, or the Doom a mod should run on
- A game you own but have not installed opens its page too, which is where the
  Install button is
- The app's own command-palette actions are in the same list, so *Control Panel*,
  *Themes* and *Manage Storage* are the same gesture as *Quake*
- With nothing typed it opens on what you played last

## Install

```
omarchy plugin add https://github.com/FromChaosComesClarity/omarchy-clarity
omarchy plugin enable io.github.fromchaoscomesclarity.clarity
```

Nothing to configure: Clarity writes down where it lives and this reads it.

**Do not have Clarity yet?** Open the launcher and it says so, and offers to fetch it ,
about 270 MB, downloaded and started in a terminal you can watch and stop. It never installs
anything in the background.

Bind the launcher to a key in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + CTRL + G", "Game launcher", "omarchy-shell shell toggle io.github.fromchaoscomesclarity.clarity")
```

## How it works

Three facts, gathered very differently:

- **Where the app is** comes from `~/.config/clarity/desktop.json`, which
  Clarity rewrites on every start: which binary to run, where its two
  databases are, and which palette actions this build has. Nothing here derives a
  path or hardcodes one, a second consumer computing its own answer is how the
  library got orphaned once before, and a hardcoded path works on exactly one
  machine. No descriptor means the app is not installed here, and this says so
  rather than guessing.
- **What is playing** comes from Hyprland, not from the app. Clarity
  launches a game and gets out of the way, so it is usually not running while
  you play, asking it would give the wrong answer for the case this widget
  exists to show.
- **What is installed** comes from the app's databases, re-read only when they
  change. Nothing here walks a filesystem. Cover art is read from the path the library
  already stores, resolved against the app's own data directory, nothing is downloaded and
  no second copy of your artwork is made.

Every colour, font and corner radius comes from the Omarchy theme tokens (the same `[menu]`
surface the Omarchy menu uses), so `omarchy theme set` restyles this too. There is no palette
of its own to fall out of step.

Nothing is launched from inside this plugin. Enter spawns Clarity with
`--play=<id>`, and the app does exactly what pressing Play does: the multi-store
picker, the "which engine?" and "which Doom?" dialogs, the install-state check,
the last-played write. A launcher that spawned games itself would be a second
implementation of all of that, correct on the day it was written and wrong by the
next release. The fuzzy scorer is likewise the app's own, character for character,
so the in-app palette and this overlay rank a query identically.

The plugin only watches and pokes. If the bar restarts, the plugin is disabled, or
the QML fails outright, you lose the icon and nothing else, the library, the
launcher and every game keep working exactly as before.

## Requires

A Clarity **newer than 1.10.0**, the descriptor this reads landed after that
release, and older builds do not write one, plus
`sqlite3`, `hyprctl` and `python3`, all present on a stock Omarchy.

## License

GPL-3.0-or-later, matching Clarity itself.
