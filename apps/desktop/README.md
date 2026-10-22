# Chief Observatory desktop

This Tauri 2 application packages the portfolio dashboard and the read-only `chiefd` sidecar for
macOS and Linux. It provides a menu-bar/system-tray status item, launch-at-login, manual refresh,
and local notifications when observed work changes state.

```sh
npm install
npm run check
npm run dev
npm run build
```

`dev` and `build` first invoke `scripts/build_sidecar.py`, which requires PyInstaller in the active
Python build environment. The packaged service reads its generated snapshot from:

- macOS: `~/Library/Application Support/Chief Observatory/snapshot.json`
- Linux: `${XDG_DATA_HOME:-~/.local/share}/chief-observatory/snapshot.json`

On first launch it creates `portfolio.json` beside that snapshot, using `~/Development` as the
workspace and the standard local Claude Code, Codex, Chief, Rosetta, and tracker locations. Edit
that private configuration to add or remove sources. The sidecar collects immediately, every 30
seconds, and when Refresh is selected.

The dashboard connects only to `127.0.0.1:4174`. Closing its window hides it; Quit from the tray
terminates both the desktop process and its sidecar.
