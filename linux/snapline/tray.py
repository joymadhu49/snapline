"""Menu bar presence through AppIndicator (StatusNotifierItem)."""
import os

import gi

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gtk

from snapline import shortcuts
from snapline.settings import settings

try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator
except (ValueError, ImportError):
    try:
        gi.require_version("AppIndicator3", "0.1")
        from gi.repository import AppIndicator3 as AppIndicator
    except (ValueError, ImportError):
        AppIndicator = None

DATA_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data")


class Tray:
    def __init__(self, app):
        self.app = app
        self.indicator = None
        if AppIndicator is None:
            return
        self.indicator = AppIndicator.Indicator.new_with_path(
            "snapline", "snapline-tray-symbolic", AppIndicator.IndicatorCategory.APPLICATION_STATUS, DATA_DIR)
        self.indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)
        self.indicator.set_title("Snapline")
        self.menu = Gtk.Menu()
        self.indicator.set_menu(self.menu)
        self.rebuild()
        app.coordinator.recorder.on_state(self.recording_changed)

    def recording_changed(self, recording, elapsed):
        if self.indicator is None:
            return
        if recording:
            m, s = divmod(int(elapsed), 60)
            self.indicator.set_label(f"● {m}:{s:02d}", "● 00:00")
            self.indicator.set_icon_full("snapline-tray-recording", "Recording")
        else:
            self.indicator.set_label("", "")
            self.indicator.set_icon_full("snapline-tray-symbolic", "Snapline")
        if getattr(self, "_was_recording", None) != recording:
            self._was_recording = recording
            self.rebuild()

    def item(self, title, callback, action=None):
        entry = Gtk.MenuItem()
        box = Gtk.Box(spacing=24)
        box.pack_start(Gtk.Label(label=title, xalign=0), True, True, 0)
        accel = settings.shortcut_for(action) if action else None
        if accel:
            lab = Gtk.Label(label=shortcuts.label_for(accel))
            lab.get_style_context().add_class("dim-label")
            box.pack_end(lab, False, False, 0)
        entry.add(box)
        entry.connect("activate", lambda *_: callback())
        self.menu.append(entry)
        return entry

    def sep(self):
        self.menu.append(Gtk.SeparatorMenuItem())

    def rebuild(self):
        if self.indicator is None:
            return
        for child in self.menu.get_children():
            self.menu.remove(child)
        c = self.app.coordinator
        if c.recorder.recording:
            self.item("Stop Recording", c.stop_recording, "toggleRecording")
            self.sep()
        self.item("Capture Area", c.capture_area, "captureArea")
        self.item("Capture Fullscreen", c.capture_fullscreen, "captureFullscreen")
        self.item("Capture Window", c.capture_window, "captureWindow")
        self.item("Capture Previous Area", c.capture_previous_area, "capturePreviousArea")
        timed = Gtk.MenuItem(label="Timed Capture")
        sub = Gtk.Menu()
        for secs in (3, 5, 10):
            i = Gtk.MenuItem(label=f"{secs} seconds")
            i.connect("activate", lambda *_, s=secs: c.timed_capture(s))
            sub.append(i)
        timed.set_submenu(sub)
        self.menu.append(timed)
        self.sep()
        if not c.recorder.recording:
            self.item("Record Screen", c.toggle_recording, "toggleRecording")
        self.item("Capture Text", c.capture_text, "captureText")
        self.sep()
        self.item("Pin from Clipboard", c.pin_from_clipboard, "pinFromClipboard")
        self.item("Capture History", c.show_history, "showHistory")
        self.item("Open Captures Folder", c.open_folder)
        self.sep()
        hidden = c.desktop_hidden()
        self.item("Show Desktop Icons" if hidden else "Hide Desktop Icons", lambda: (c.toggle_desktop_icons(), self.rebuild()))
        self.sep()
        self.item("Settings", lambda: self.app.show_settings("general"))
        self.item("Customize Shortcuts", lambda: self.app.show_settings("shortcuts"))
        self.item("Quit Snapline", self.app.quit_app)
        self.menu.show_all()
