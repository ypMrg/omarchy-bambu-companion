# Bambu Companion for Omarchy Quattro

<p align="center">
  <img src="preview.png" alt="Bambu Companion dashboard with live telemetry, G-code preview and chamber camera" width="900">
</p>

Monitor a Bambu Lab printer from the Omarchy Quattro bar: live telemetry, the
slicer's 2D plate preview, a G-code wireframe, and chamber camera stills.

The plugin talks to the printer on your LAN. It does not use Bambu Cloud or
Bambu Connect. Monitoring only — no pause, resume, stop, upload or speed
commands.

> [!IMPORTANT]
> **FTPS transfers are slow** on P1 and A1 printers. That is a hardware limit
> in the printer's Wi-Fi module and SD card, not the plugin.

## Install

```bash
omarchy plugin add https://github.com/ypMrg/omarchy-bambu-companion.git --enable
```

Ruby gems install into an isolated user-data directory on first launch. System
gems are never modified.

```bash
omarchy plugin update io.github.ypmrg.bambu-companion --yes
omarchy restart shell

omarchy plugin remove io.github.ypmrg.bambu-companion
```

The in-plugin download icon runs that update, then restarts the shell. A plugin
reload alone can keep compiled QML from the previous version. If the widget is
enabled but missing from the bar:

```bash
omarchy plugin enable io.github.ypmrg.bambu-companion --section right
omarchy restart shell
```

## Setup

Open the bar widget to configure a printer. The panel stays closed across
plugin reloads and when other plugins are added. A connection loader remains
until the first fresh status report is received; only then does the live
dashboard appear. Settings and the dashboard reflow at narrow widths so every
control stays inside the panel margins.

**Try demo** on first launch explores the dashboard with a bundled OMARCHY
logo. It does not read the keyring or contact a printer. **Exit demo** returns
to configuration. The bar stays `SETUP` during the demo.

1. Enable local network access on the printer. Note its serial number and LAN
   access code. On firmware that offers **Developer Mode**, enable it so MQTT
   and FTPS are exposed to third-party clients.
2. Open the widget and enter the printer address, serial number and LAN access
   code.
3. Select **Save & Connect** to check the printer certificate. No LAN code is
   sent during this check.
4. Review the SHA-256 identity shown for MQTT and FTPS, then **Trust & Connect**.

Use a trusted local network for this first approval. Existing installations
without saved certificate identities must approve their printer once after
updating. Later connections are automatic while those identities stay the same.
If a certificate changes, the plugin blocks reconnecting until you review the
new identity.

[Bambu's third-party note](https://blog.bambulab.com/updates-and-third-party-integration-with-bambu-connect/)
covers Developer Mode. LAN Only Mode is a separate setting. Menu names vary by
model and firmware.

Leave the LAN code blank to keep a stored code, enter another to replace it, or
use **Forget code**. **Disconnect printer** asks for confirmation, then removes
address, serial, certificates and code while preserving visual preferences.

**Open app** (next to Settings) tiles the dashboard as a normal Wayland window.
The window and bar share one printer session.

| Setting | Default |
| --- | --- |
| MQTT TLS port | `8883` |
| FTPS port | `990` |
| Username | `bblp` |
| Wireframe segment limit | `500000` |
| Explode factor | `100` |
| Auto-rotate / bar summary | enabled |

**Bar summary** applies immediately. Everything else needs **Save & Connect**.
The bar icon is green during the temporary `FINISH` state, red on fail or
error, otherwise the theme default.

## What you get

- Bar icon with optional status, progress and temperatures.
- Dashboard: telemetry on the left, preview on the right.
- Route / Camera / Image views, plus a tiled window from **Open app**.
- Event timeline for print activity, HMS notices and print errors.
- Automatic reconnect. `OFFLINE` keeps the dashboard usable.
- After a print, `FINISH` holds for 60 seconds, then `READY`.

An unread fatal/serious HMS or print-error turns the bar icon red and the
optional bar summary to `ERROR`. Orange notices stay on the Events button.
The newest 200 events stay in memory for the shell session only.

Route and Image stay selectable with no print loaded. Camera is enabled when a
LAN camera is usable. Drag to orbit, wheel to zoom, **Explode** to space
G-code layers. Printed paths use the theme accent. If the GPU route view is
building, it shows `COMPILING ROUTE RENDERER` and the 2D preview still works.
The GPU item is `GcodeRoute`.

Previews need the print file over FTPS. On some H2/P2 firmware, enable
**Store Sent Files on External Storage** or Image and Route stay empty while
MQTT telemetry continues.

## Chamber camera

Stills, not live video. About 1 Hz while Camera is actually on screen. RTSP
families keep one ffmpeg session open instead of reconnecting for every still.
Leaving the view, or opening Settings or Events, stops the session and deletes
the still. A pinned loopback TLS gateway handles the printer's RTSP
Basic/Digest challenge; ffmpeg receives only a localhost URL, never the LAN
access code.

| Family | Transport | Needs |
| --- | --- | --- |
| P1 / A1 / A2 | JPEG TLS, port 6000 | nothing extra |
| X1 / X2 / H2 / P2 | Encrypted RTSP, port 322 | `ffmpeg` |

Some H2 firmware also needs **LAN Mode Liveview**.

## Compatibility

Live-tested on an A1 Mini and an X2D. Other rows are protocol expectations,
not a guarantee. Firmware can change these undocumented interfaces at any
time.

| Family | Support | Notes |
| --- | --- | --- |
| A1 Mini | Live-tested | JPEG camera on port 6000 |
| A1 / P1P / P1S | Expected | JPEG camera on port 6000 |
| X1 / X1C / X1E | Expected | RTSP camera on 322, needs `ffmpeg` |
| A2L / P2S / H2S | Experimental | A2 JPEG; P2/H2 RTSP |
| H2D / H2C | Experimental | Dual-nozzle telemetry and combined dual-tool route; enable **LAN Mode Liveview** |
| X2D | Live-tested | USB archive/plate selection, persistent RTSPS camera, dual-nozzle temperatures and combined dual-tool route; internal eMMC fallback is protocol-tested and still needs live hardware validation |

Not shown: AMS, chamber heating, door/fan extras, laser or cutting jobs. X2D
shows both nozzle temperatures and marks the active nozzle. Its route parser
keeps absolute extrusion state separate for both hotends; the route is combined
rather than color-coded per tool. Bed size is taken from the active G-code.

The moving point in Route is a path animation, not live XY telemetry from the
printer. X2D firmware does not publish a usable live XY position in the status
payload currently handled by the plugin.

For X2D jobs whose `/data/Metadata/plate_N.gcode` archive is not present on the
USB volume, the plugin falls back to the printer's read-only CTRL storage API
over pinned TLS on port 6000. It lists the logical `internal` model view first,
then the `emmc` model view for firmware compatibility, downloads only the
matching active archive and verifies its reported size, offsets and MD5 before
publishing it. It never uploads, deletes or renames printer files.

## Security

- The plugin does not overwrite user configuration without **Save & Connect**,
  **Trust & Connect**, confirmed **Disconnect printer**, or the bar-summary
  toggle.
- The LAN access code is never stored in settings, the repo, process arguments
  or normal logs. It goes to the backend and GNOME Keyring on stdin.
  `secret-tool` keeps it in GNOME Keyring when available.
- Print files are private temp files and are deleted after parse. Camera stills
  are one `snapshot.jpg` (`0600`), wiped when the view closes, rejected above
  1 MiB or 4 megapixels. ffmpeg gets a loopback RTSP URL with no LAN code.
- MQTT and FTPS pin their SHA-256 leaves from **Trust & Connect**. Camera TLS
  and the read-only internal-storage client accept only those explicitly
  approved device leaves and add no implicit trust exception.

## Requirements

- Omarchy Quattro v4, same trusted LAN as the printer, LAN access code.
- `ruby`, `gem`, `flock`, GNU `readlink`.
- `secret-tool` / GNOME Keyring recommended.
- `cmake` and `g++` for the G-code route view; the rest works without them.
- `ffmpeg` only for X1 / X2 / H2 / P2 camera stills.

## Troubleshooting

**Widget missing**

```bash
omarchy plugin enable io.github.ypmrg.bambu-companion --section right
omarchy restart shell
```

**Printer offline.** Check address, serial, ports, LAN code, Developer Mode,
and that TCP `8883` / `990` are open. Camera also needs `6000` or `322`.

**No preview.** Wait for heating/calibration, confirm a `.gcode` / `.3mf` is
on the printer, then **Reload preview**. Telemetry still works without it.
On X2D the plugin recognizes `/data/Metadata/plate_N.gcode` as the selected
entry inside the active `.gcode.3mf` and uses the external archive with the
matching print name. If FTPS does not expose it, the plugin tries the read-only
internal-storage route described above. Until that fallback is live-validated
on your firmware, sending the job to external storage remains the proven route.

**No camera.** Printer must be online. JPEG families use port `6000`; RTSP
families use `322` and `ffmpeg`. X2/H2 firmware may need **LAN Mode Liveview**.
An `auth_failed` event means the RTSP server rejected the configured LAN access
code; `certificate_changed` requires reviewing and approving the printer leaf
again.

```bash
journalctl -t omarchy-shell -b --no-pager \
  | grep -Ei 'bambu|plugin widget|failed|error'
```

## Development

```bash
bin/test
omarchy plugin validate "$PWD"
```

`minitest`, `rubocop`, `shellcheck`, `qmllint` and Node.js are development only.
QML linting uses `$OMARCHY_PATH/shell` (or `/usr/share/omarchy/shell`).

Unpublished checkout in a disposable Quattro VM:

```bash
plugin_target="$HOME/.config/omarchy/plugins/io.github.ypmrg.bambu-companion"
test ! -e "$plugin_target"
mkdir -p "$plugin_target"
cp -a -- "$PWD/." "$plugin_target/"
omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.ypmrg.bambu-companion --section right
omarchy restart shell
```

One printer per install. MQTT for telemetry, FTPS for the print file, JPEG
port 6000 or RTSP port 322 for stills.

## License

[MIT](LICENSE) — Copyright (c) 2026 Matthieu G.C.

Bambu Lab names and trademarks belong to their respective owners. This project
is independent and is not affiliated with or endorsed by Bambu Lab.
