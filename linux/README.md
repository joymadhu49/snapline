# Snapline for Linux

The Ubuntu / GNOME port of Snapline. Same flows, same folders, same file names as the Mac app:
frozen screen selection, fullscreen and window capture, timed capture, screen recording to MP4,
GIF export, OCR, the Quick Access card stack, the Capture History dock, pins, the annotation
editor, and a settings window with a shortcut recorder. No cloud, no accounts, no analytics.

Verified on Ubuntu 26.04 LTS, GNOME Shell 50, Wayland, single 3440×1440 display.

## Install

```bash
cd ~/Projects/Snapline/linux
./install.sh              # add --autostart to launch at login
```

The installer pulls the system packages it needs (PyGObject, GTK 3, GStreamer with the
PipeWire, x264 and libav plugins, ffmpeg, tesseract, wl-clipboard), copies the app to
`~/.local/share/snapline/app`, puts a `snapline` launcher in `~/.local/bin`, installs the
icons and the `.desktop` entry, enables Ubuntu's AppIndicator extension for the top bar
icon, pre-approves silent portal screenshots, registers the shortcuts as GNOME custom
keybindings, and starts the app.

## Shortcuts

| Action | Default |
| --- | --- |
| Capture Area | Alt+Shift+4 |
| Capture Fullscreen | Alt+Shift+3 |
| Capture Window | Alt+Shift+5 |
| Capture Previous Area | Alt+Shift+8 |
| Record Screen (start / stop) | Alt+Shift+6 |
| Capture Text (OCR) | Alt+Shift+7 |
| Capture History | Alt+Shift+9 |
| Pin from Clipboard | none |

Change them in the top bar menu > Customize Shortcuts. They are written to
`org.gnome.settings-daemon.plugins.media-keys` custom keybindings, so they work everywhere on
Wayland, including over fullscreen apps. Each keybinding runs `snapline --<flag>`; the running
instance picks the flag up through GApplication, so nothing is spawned twice.

## Command line

```
snapline                      start in the top bar
snapline --capture-area       (every shortcut has a flag; snapline --help lists them)
snapline --settings
snapline --install-shortcuts  re-register the GNOME keybindings
snapline --quit
```

## How it works on Wayland

- **Stills** go through `org.freedesktop.portal.Screenshot`. The frame is grabbed before any
  overlay window exists, so menus, popovers, notifications, and video frames stay frozen while
  you drag, and the saved image is cropped from that same frame. About half a second from
  shortcut to overlay on GNOME 50.
- **Capture Window** opens GNOME's own picker (the portal's interactive mode) because Wayland
  never tells clients where other windows are. GNOME's window shots keep the soft shadow.
- **Recording** uses `org.freedesktop.portal.ScreenCast` → PipeWire → GStreamer
  (`x264enc` + AAC into MP4). GNOME asks which screen to share the first time; the answer is
  remembered through the portal's restore token. Area recordings crop the stream and draw a red
  border just outside the region. GIF export runs ffmpeg with a generated palette.
- **Clipboard** carries `image/png`, `text/uri-list`, `x-special/gnome-copied-files`, and the
  shell escaped path as text at once: paste the picture in an editor, the file in Nautilus, the
  path in a terminal.
- **Window placement.** GNOME Wayland gives apps no way to place their own windows, keep them
  on top, or make them click through. The floating cards, pins, the history dock, the countdown,
  and the toasts need all three, so the UI runs through Xwayland (`GDK_BACKEND=x11`). Capture
  and recording stay native. On a scaled display Xwayland windows may look softer; captures are
  unaffected.
- **Hide Desktop Icons** toggles Ubuntu's desktop icons extension.

## Layout

```
snapline/
  app.py            single instance GApplication, flag dispatch
  capture.py        CaptureCoordinator: every flow from shortcut to delivered file
  portal.py         Screenshot and ScreenCast portal clients
  overlay.py        frozen frame selection overlay (crosshair, marquee, ⇧ square, ⌥ centre, space move)
  hud.py            countdown and toasts
  recording.py      ScreenCast → GStreamer MP4, red border, GIF export
  quickaccess.py    floating card stack, drag out, On clipboard chip
  historypanel.py   top dock
  pin.py            always on top reference windows
  editor.py         annotations, crop, undo/redo, background beautify, Done / Save / Drag
  settingswindow.py General, Output, Recording, Shortcuts
  shortcuts.py      GNOME custom keybindings
  clipboard.py      multi target clipboard owner
  tray.py           AppIndicator menu
  settings.py       ~/.config/snapline/settings.json
data/               icons and .desktop entry
bin/snapline        launcher
install.sh
```

Captures land in `~/Pictures/Snapline/{Screenshots,Recordings,GIFs}`. With "Save after capture"
off they go to `~/.local/share/snapline/Captures` so a dragged or pasted path always resolves.
