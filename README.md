# Cafe Neurotico — Omarchy bar widget

Your game library in the Omarchy bar: how many games are installed, and what is
running right now.

- **Left click** — open Cafe Neurotico (the Manager)
- **Middle click** — open CREMA, the fullscreen couch face

## Install

```
omarchy plugin add https://github.com/FromChaosComesClarity/omarchy-cafeneurotico
omarchy plugin enable io.github.fromchaoscomesclarity.cafeneurotico
```

Then set the AppImage path in the widget's settings if yours is not at
`~/Games/CNGM/CafeNeurotico.AppImage`.

## How it works

Two facts, gathered very differently:

- **What is playing** comes from Hyprland, not from the app. Cafe Neurotico
  launches a game and gets out of the way, so it is usually not running while
  you play — asking it would give the wrong answer for the case this widget
  exists to show.
- **What is installed** comes from `grinder.db`, re-read only when the file
  changes. Nothing here walks a filesystem.

The database path is a setting, never derived. Cafe Neurotico resolves it
through its own platform layer, and a second consumer computing its own path is
how the library got orphaned once before.

The widget only watches and pokes. If the bar restarts, the plugin is disabled,
or the QML fails outright, you lose the icon and nothing else.

## Requires

`sqlite3`, `hyprctl`, `python3` — all present on a stock Omarchy.

## License

GPL-3.0-or-later, matching Cafe Neurotico itself.
