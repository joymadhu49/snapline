<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/hero-dark.png">
  <img src="docs/hero-light.png" alt="Snapline. Select it. Snap it. Drop it anywhere. A frozen desktop with a white selection around a photo, its size label at the pointer, and earlier captures waiting in the bottom left corner.">
</picture>

<p align="center">
  Free and open source. For macOS 14 and later.
  <br>
  <a href="../../releases/latest">Download&nbsp;&rsaquo;</a>
  &nbsp;&nbsp;
  <a href="#build-from-source">Build from source&nbsp;&rsaquo;</a>
</p>

<br>

## Select. Snap. Done.

Press the shortcut and the screen freezes under your pointer.
Drag over what you want, let go, and the capture snaps into the corner of your screen.
Drag it straight into whatever you are working on.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/demo-dark.gif">
  <img src="docs/demo-light.gif" alt="Option Shift 4 freezes the screen, the pointer drags a selection over a photo, the capture slides into the bottom left corner, and it is dragged into a chat window where it lands as a message.">
</picture>

<br>
<br>

## A shortcut for everything.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/bento-dark.png">
  <img src="docs/bento-light.png" alt="Freeze the moment. Copy any text. Mark it up. Record the screen. Drop it anywhere. Pin it on top.">
</picture>

<br>
<br>

| | |
|:--|:--|
| <kbd>⌥</kbd>&thinsp;<kbd>⇧</kbd>&thinsp;<kbd>4</kbd> | Capture an area. Return takes the whole screen. |
| <kbd>⌥</kbd>&thinsp;<kbd>⇧</kbd>&thinsp;<kbd>3</kbd> | Capture the display under the pointer. |
| <kbd>⌥</kbd>&thinsp;<kbd>⇧</kbd>&thinsp;<kbd>5</kbd> | Capture a window, with an optional soft shadow. |
| <kbd>⌥</kbd>&thinsp;<kbd>⇧</kbd>&thinsp;<kbd>6</kbd> | Record an area or the full screen. Press again to stop. |
| <kbd>⌥</kbd>&thinsp;<kbd>⇧</kbd>&thinsp;<kbd>7</kbd> | Copy the text inside a selection. |
| <kbd>⌥</kbd>&thinsp;<kbd>⇧</kbd>&thinsp;<kbd>8</kbd> | Capture the previous area again. |
| <kbd>⌥</kbd>&thinsp;<kbd>⇧</kbd>&thinsp;<kbd>9</kbd> | Open the capture history. |

Every shortcut can be changed in Settings, and Snapline tells you when another app already owns one.

<br>

## The exact moment, every time.

Notifications, open menus and playing video hold perfectly still while you drag,
and the image you get is cropped from that same frozen frame.
One white line. One size label. Nothing else in the way.

<br>

## Straight to wherever it goes.

Each capture floats in the corner the moment you take it.
Click to copy. Hover to save, pin or annotate. Drag it out to use it.

A single drag carries the image, the file and its path at once,
so it lands as a picture in Slack, Figma or Mail,
and as a ready to run path in Terminal or an agent prompt.

<br>

## Mark it up without leaving the flow.

Arrows, lines, shapes, freehand, highlighter, text, numbered counters,
pixelate and crop, each on a single key. Add a gradient background,
padding and a shadow when it is going somewhere public.
**Done** writes your edits back, copies the result and floats it on the overlay again.

<br>

## Private by design.

No account. No cloud. No analytics.
Snapline runs entirely on your Mac, and your captures never leave it.
The only request it makes is a daily check for updates, which sends nothing about you.
Everything is filed under `~/Pictures/Snapline` in Screenshots, Recordings and GIFs.

<br>

## Tech Specs

| | |
|:--|:--|
| **Compatibility** | macOS 14 Sonoma or later, on Apple silicon and Intel. |
| **Size** | 8 MB |
| **Built with** | Swift, AppKit, SwiftUI, ScreenCaptureKit and Vision |
| **Formats** | PNG and JPG stills, H.264 MP4 at 30 or 60 fps, GIF |
| **Recording audio** | System audio, plus microphone on macOS 15 and later |
| **Updates** | Automatic, through [Sparkle](https://sparkle-project.org), signed and verified |
| **Network access** | The update check, nothing else |
| **Price** | Free |
| **License** | MIT |

<br>

## Install

Download the disk image from the [latest release](../../releases/latest),
open it and drag Snapline to Applications. It is signed and notarized by Apple,
so it opens without warnings, and it keeps itself up to date from then on.

Snapline needs **Screen Recording** permission. Turn it on under System Settings,
Privacy & Security, Screen & System Audio Recording, then relaunch the app.
**Microphone** access is only asked for if you record your voice.

<br>

## Build from source

```sh
git clone https://github.com/joymadhu49/snapline.git
cd snapline
brew install xcodegen
bash Scripts/build.sh
open build/Snapline.app
```

Requires Xcode 16 or later. The script generates the project, builds a universal app and signs it.
With a Developer ID certificate in your keychain it signs for distribution; without one it signs ad hoc,
so macOS asks again for Screen Recording access after each rebuild.

<details>
<summary>Every feature, in detail</summary>
<br>

- **Capture Area** (default ⌥⇧4): frozen screen selection overlay with crosshair, live pixel dimensions, drag to select, Return for the full screen, Esc or right click to cancel. The crosshair and dim appear on the key press itself, and the screen is frozen underneath them a moment later (Snapline's own windows are excluded from that frame, and a selection released before the frame lands waits for it rather than grabbing the live desktop). Notifications, popovers, and video frames stay frozen while you drag; the saved image is cropped from that same frame. Displays are captured concurrently at native resolution. A pure marquee: it never highlights or grabs windows, that is what Capture Window is for. The overlay also never takes focus. The frontmost app stays active, so an open menu, dropdown, or popover stays on screen and lands in the shot instead of being dismissed; Esc, Return, and space still work because the overlay reads the hardware key state directly rather than waiting for key events it would never receive. The chrome is pure Core Animation: layer paths move and nothing redraws a screen sized bitmap, so the marquee tracks the cursor with no lag, across displays too. The chrome is deliberately minimal, CleanShot style: a dimmed screen, one white hairline around the selection, and a small size label riding next to the pointer. With several displays, every one dims, the hint and the crosshair cursor follow the pointer onto whichever display it is on (the pointer is tracked on the overlay's own clock, since macOS delivers mouse moves to a background app's windows unreliably), and a selection stays on the display it started on. While dragging: hold ⇧ for a square, ⌥ to grow from the start point, and space to move the selection without resizing. An optional pixel magnifier (off by default, Settings > General > Show pixel magnifier) zooms the pixels under the pointer
- **Capture Fullscreen** (⌥⇧3): the display under your cursor
- **Capture Window** (⌥⇧5): the overlay highlights the window under the cursor with its name and size, click grabs it (or drag an area instead); clean capture with optional soft shadow on transparent padding
- **Capture Previous Area** (⌥⇧8): repeats the last selection
- **Timed Capture**: select an area, then a 3/5/10 second countdown
- **Record Screen** (⌥⇧6): drag out the area and it stays up, CleanShot style: drag the round handles to resize, drag inside to move, and a bar underneath shows the size, toggles system audio, microphone, and cursor (saved to Settings), and starts with **Record** (or ⏎). While recording, one click on the menu bar timer stops it (right click still opens the menu). MP4 via ScreenCaptureKit + H.264, area or full screen, 30/60 fps, system audio, microphone (macOS 15+), optional 3 second count in, red border around the recorded region, elapsed timer in the menu bar, GIF export through Homebrew ffmpeg
- **Capture Text** (⌥⇧7): OCR any frozen screen region through Apple Vision, result lands on the clipboard
- **Quick Access Overlay**: after every capture the shot itself floats (the card appears straight away; the file is encoded once and the save and clipboard happen in the background) in the bottom left corner, laid out like CleanShot X's overlay: every card the same size (Settings > General > Overlay size: small, medium, or large) so a stack of them stays tidy; cards slide in from past the screen edge, and closing one shrinks and fades it away before the cards above glide down into the gap; on hover the shot dims, Copy and Save (Show in Finder once saved) sit in the middle, and round buttons in the corners close, pin, and annotate it; a successful drag into another app or Finder dismisses the floating card, while a cancelled or rejected drop keeps it available; an "On clipboard" chip marks which capture is currently on the clipboard, clicking the card copies it again, dragging it carries the file out. With two displays the stack follows the pointer: settle on the other display for a moment and the cards rise into its corner, ready to drag into an app there (it never moves mid drag, so dragging a card across to the other display works). The stack grows to as many cards as fit the screen by default; Settings > General > "Overlay holds" caps it lower
- **Capture History** (⌥⇧9): a compact dock across the top of the screen, only as wide as its captures, that scrolls sideways (mouse wheel too) through every recent capture. Filter tabs with counts (All, Screenshots, Recordings, GIFs; empty kinds hide), each tile captioned with its age and pixel size or running time. Click a thumbnail to copy it, drag it out, or hover for Restore to overlay, Annotate, and Copy, with a trash button in the corner and a right click menu for Pin, Open, and Show in Finder. Works from the keyboard: ← → select, Return copies, E annotates, ⌘⌫ trashes. The ⋯ menu opens the captures folder or clears the history (files stay). Esc or a click elsewhere closes it. Restoring a capture that is already on the overlay pulses the existing card instead of stacking a second copy
- **Drag out anywhere**: every card carries the file URL, a shell escaped path, and the image bytes at once, so one drag works in Finder, Slack, and Figma as well as Terminal or an agent prompt. The clipboard carries the same set, so ⌘V pastes the picture in an editor and the path in a terminal
- **Editor**: arrow, line, rectangle, ellipse, freehand, highlighter, text, numbered counters, pixelate redact, crop, undo/redo, single key tool shortcuts (V A L R O P H T N B C), last tool, colour, and stroke remembered between captures, background beautify (gradient presets, padding, corner radius, shadow). The toolbar sits in the title bar row with the window buttons: tools, inline colour swatches (folded into one button on narrow windows), four stroke weights shown as dots, undo/redo, then Background, Drag, Pin, Copy, Save, and **Done** as the one primary button. The window cannot be minimised; it opens wide enough for the fully labelled toolbar and cannot be resized narrower than the compact one (both widths measured from the toolbar itself), and the toolbar picks whichever of its three layouts fits, so it never overflows. Apply Crop sits in the status bar. A status bar shows the result's pixel size and mark count, what the current tool does, and the zoom level; shots are never shown past their real size. Arrows are tapered, counters carry a white ring, and every mark casts a soft shadow so it reads on any background. The canvas draws marks with the same renderer that writes the file, so the screen and the export always match. **Done** (⌘return) writes the edits over the capture's file, puts the result on the clipboard, and floats it back onto the overlay as a card, so the annotated version is what every later copy, drag, or paste hands out; Save and Save As live in the save menu. The **Drag** chip drops the edited image straight into Finder, Slack, a terminal, or an agent prompt without leaving the editor
- **Pin to screen**: floating always on top reference windows; scroll changes opacity, double click closes; also Pin from Clipboard
- **Custom shortcuts** for every action: menu bar icon > Customize Shortcuts (or Settings > Shortcuts tab); click a field, press the new keys; conflict detection included
- **Organized save location**: everything lands in `~/Pictures/Snapline`, filed into `Screenshots/`, `Recordings/`, and `GIFs/` rather than piling up loose on the Desktop; change the root in Settings > Output
- Extras: hide desktop icons toggle, recent captures menu, retina downscale, PNG/JPG, filename pattern `Snapline yyyy.MM.dd at HH.mm.ss`, launch at login

</details>

<details>
<summary>Inside the app</summary>
<br>

| Folder | Role |
|:--|:--|
| `App/` | Entry point, app delegate, the menu bar item, and `UpdateController` for Sparkle |
| `Core/` | `CaptureEngine` for stills, `RecordingEngine` for video, `CaptureCoordinator` for the flows, `HotkeyCenter`, `SettingsStore`, `ImageWriter`, `GIFExporter`, `OCRService`, `HistoryStore`, `DragOut` |
| `Overlay/` | `SelectionOverlay`, the frozen dim and crosshair on every display, and `HUD` for countdowns and toasts |
| `QuickAccess/` | `QuickAccessPanel`, the floating cards, and `HistoryPanel`, the top dock |
| `Editor/` | `EditorModel`, `EditorCanvas`, `EditorRenderer` for export, `EditorWindow` and its toolbar |
| `Pin/` | `PinWindow` |
| `Settings/` | `SettingsWindow` and `ShortcutRecorder` |

Saved captures go to `~/Pictures/Snapline/<Screenshots|Recordings|GIFs>`. Every capture is
written to a file even when saving is off; those land in
`~/Library/Application Support/Snapline/Captures` so a dragged or pasted path always resolves.

SwiftUI hosting views keep hit testing for everything they draw, so a drag source layered
underneath never sees a mouse down. `DragOut` therefore lets SwiftUI recognise the gesture and
hands the drag to AppKit, which owns the pasteboard flavours.

Coordinate conventions: selection rects travel as global AppKit bottom left origin rects plus their `NSScreen`.
ScreenCaptureKit crops use screen local top left origin points multiplied by `backingScaleFactor`.
Editor annotations live in image pixel space with a top left origin.

**Capture regression tests.** Run `Scripts/test_freeze.sh` from a terminal with Screen Recording access.
It opens a window that changes from red to blue during selection, then checks that both the displayed selection
and its delivered crop keep the red frame. It also checks crop orientation, Retina scaling, offset display
coordinates, cancellation, repeated shortcuts, and live recording, timer and window modes.
Exit code 77 means screen access is unavailable.

**The mark** is the name drawn literally: one line that snaps at right angles into an S, with a square
selection handle on each end, the way a selected path looks in a design tool. `swift Scripts/make_icon.swift`
is the source of truth for the whole identity. It writes `Resources/AppIcon.icns`, the menu bar template
`Resources/MenuBarIcon.pdf`, and the `Brand/` exports.

**The README art** is drawn in HTML under `docs/art/`. `Scripts/make_readme_art.sh` renders the stills
and the demo GIF in light and dark, with headless Chrome and ImageIO.

**Releases** cut themselves. Bump `MARKETING_VERSION` in `project.yml` and push to `main`: the release
workflow builds a universal app, notarizes and staples it, wraps it in a DMG, notarizes that too, signs it
for Sparkle and publishes the GitHub release with its `appcast.xml`. Installed copies pick it up on their
next daily check. Pull requests get a build check and an automated review.

</details>

<details>
<summary>Linux</summary>
<br>

There is an Ubuntu and GNOME port in [`linux/`](linux/README.md): Python and GTK, the XDG portals for
capture and recording, GNOME custom keybindings for the shortcuts, and the same folders and file names.
Run `cd linux && ./install.sh` on the Ubuntu machine.

</details>

<br>

<p align="center">
  <img src="docs/icon.png" width="64" height="64" alt="">
  <br>
  <sub>The code is MIT licensed. See <a href="LICENSE">LICENSE</a>.</sub>
  <br>
  <sub>Designed and built by <a href="https://portfoliojoy-eth.xyz">Joy Madhu</a> in Dhaka.</sub>
</p>
