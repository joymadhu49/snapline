"""Settings: General, Output, Recording, Shortcuts."""
import os

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gtk

from snapline import shortcuts
from snapline.settings import ACTIONS, settings

AUTOSTART = os.path.expanduser("~/.config/autostart/snapline.desktop")


class ShortcutButton(Gtk.Button):
    def __init__(self, action, window):
        super().__init__()
        self.action = action
        self.window = window
        self.recording = False
        self.set_size_request(150, -1)
        self.refresh()
        self.connect("clicked", self.begin)
        self.connect("key-press-event", self.on_key)
        self.connect("focus-out-event", lambda *_: self.end())

    def refresh(self):
        accel = settings.shortcut_for(self.action)
        self.set_label("Press keys…" if self.recording else shortcuts.label_for(accel))
        ctx = self.get_style_context()
        ctx.remove_class("suggested-action")
        if self.recording:
            ctx.add_class("suggested-action")

    def begin(self, *_):
        self.recording = True
        self.refresh()
        self.grab_focus()

    def end(self):
        self.recording = False
        self.refresh()

    def on_key(self, _w, event):
        if not self.recording:
            return False
        key = event.keyval
        if key == Gdk.KEY_Escape:
            self.end()
            return True
        if key in (Gdk.KEY_BackSpace, Gdk.KEY_Delete):
            self.window.apply_shortcut(self.action, None)
            self.end()
            return True
        mods = event.state & Gtk.accelerator_get_default_mod_mask()
        if key in (Gdk.KEY_Shift_L, Gdk.KEY_Shift_R, Gdk.KEY_Control_L, Gdk.KEY_Control_R, Gdk.KEY_Alt_L, Gdk.KEY_Alt_R,
                   Gdk.KEY_Super_L, Gdk.KEY_Super_R, Gdk.KEY_Meta_L, Gdk.KEY_Meta_R):
            return True
        if not mods & (Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.MOD1_MASK | Gdk.ModifierType.SUPER_MASK):
            self.window.flash("Use at least Ctrl, Alt, or Super with the key")
            return True
        lower = Gdk.keyval_to_lower(key)
        accel = Gtk.accelerator_name(lower, mods)
        conflict = shortcuts.conflict_for(accel, self.action)
        if conflict:
            self.window.flash(f"{shortcuts.label_for(accel)} was moved here from {conflict}")
        self.window.apply_shortcut(self.action, accel)
        self.end()
        return True


class SettingsWindow(Gtk.Window):
    _instance = None

    @classmethod
    def show_page(cls, app, page="general"):
        if cls._instance is None:
            cls._instance = cls(app)
        cls._instance.stack.set_visible_child_name(page)
        cls._instance.present()

    def __init__(self, app):
        super().__init__(title="Snapline Settings")
        self.app = app
        self.set_default_size(560, 520)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.connect("destroy", lambda *_: setattr(SettingsWindow, "_instance", None))
        hb = Gtk.HeaderBar(); hb.set_show_close_button(True); hb.props.title = "Snapline"
        self.set_titlebar(hb)
        self.stack = Gtk.Stack(); self.stack.set_transition_type(Gtk.StackTransitionType.CROSSFADE)
        switcher = Gtk.StackSwitcher(); switcher.set_stack(self.stack)
        hb.set_custom_title(switcher)
        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.add(outer)
        outer.pack_start(self.stack, True, True, 0)
        self.status = Gtk.Label(label="", xalign=0, margin=8)
        self.status.get_style_context().add_class("dim-label")
        outer.pack_end(self.status, False, False, 0)
        self.stack.add_titled(self.general_page(), "general", "General")
        self.stack.add_titled(self.output_page(), "output", "Output")
        self.stack.add_titled(self.recording_page(), "recording", "Recording")
        self.stack.add_titled(self.shortcuts_page(), "shortcuts", "Shortcuts")
        self.show_all()

    def flash(self, text):
        self.status.set_text(text)

    # Helpers

    def page(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6, margin=20)
        listbox = Gtk.ListBox(); listbox.set_selection_mode(Gtk.SelectionMode.NONE)
        listbox.get_style_context().add_class("frame")
        box.pack_start(listbox, False, False, 0)
        return box, listbox

    def row(self, listbox, title, widget, subtitle=None):
        r = Gtk.ListBoxRow(); r.set_activatable(False)
        h = Gtk.Box(spacing=12, margin=10)
        labels = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        labels.pack_start(Gtk.Label(label=title, xalign=0), False, False, 0)
        if subtitle:
            s = Gtk.Label(label=subtitle, xalign=0); s.get_style_context().add_class("dim-label")
            s.set_line_wrap(True); labels.pack_start(s, False, False, 0)
        h.pack_start(labels, True, True, 0)
        widget.set_valign(Gtk.Align.CENTER)
        h.pack_end(widget, False, False, 0)
        r.add(h); listbox.add(r)
        return widget

    def switch(self, key, on_change=None):
        sw = Gtk.Switch(); sw.set_active(bool(settings.get(key)))

        def changed(s, _p):
            settings.set(key, s.get_active())
            if on_change:
                on_change(s.get_active())
        sw.connect("notify::active", changed)
        return sw

    def combo(self, key, options, cast=None):
        c = Gtk.ComboBoxText()
        for value, label in options:
            c.append(str(value), label)
        c.set_active_id(str(settings.get(key)))
        c.connect("changed", lambda w: settings.set(key, cast(w.get_active_id()) if cast else w.get_active_id()))
        return c

    # Pages

    def general_page(self):
        box, lb = self.page()
        self.row(lb, "Launch at login", self.switch("launchAtLogin", self.apply_autostart))
        self.row(lb, "Play sounds", self.switch("playSounds"))
        self.row(lb, "Quick Access overlay", self.switch("showQuickAccess"), "Float every capture in the bottom left corner")
        spin = Gtk.SpinButton.new_with_range(0, 12, 1); spin.set_value(settings.overlayMaxCards or 0)
        spin.connect("value-changed", lambda s: settings.set("overlayMaxCards", int(s.get_value())))
        self.row(lb, "Overlay holds", spin, "Cards stacked at once. 0 keeps as many as fit the screen")
        self.row(lb, "Copy to clipboard after capture", self.switch("copyAfterCapture"))
        self.row(lb, "Save after capture", self.switch("saveAfterCapture"), "Off keeps captures in a hidden folder so paths still resolve")
        self.row(lb, "Open editor after capture", self.switch("openEditorAfterCapture"))
        return box

    def output_page(self):
        box, lb = self.page()
        chooser = Gtk.FileChooserButton(title="Choose the capture folder", action=Gtk.FileChooserAction.SELECT_FOLDER)
        chooser.set_filename(settings.save_directory)
        chooser.connect("file-set", lambda c: settings.set("saveDirectoryPath", c.get_filename()))
        self.row(lb, "Save location", chooser, "Screenshots/, Recordings/, and GIFs/ are created inside")
        self.row(lb, "Image format", self.combo("imageFormat", [("png", "PNG"), ("jpg", "JPG")]))
        scale = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0.3, 1.0, 0.05)
        scale.set_value(settings.jpgQuality); scale.set_size_request(160, -1); scale.set_draw_value(True)
        scale.connect("value-changed", lambda s: settings.set("jpgQuality", round(s.get_value(), 2)))
        self.row(lb, "JPG quality", scale)
        self.row(lb, "Downscale HiDPI captures", self.switch("downscaleHiDPI"), "Save at logical size on scaled displays")
        self.row(lb, "Window shadow", self.switch("windowShadow"), "Window captures use GNOME's picker, which keeps the shadow")
        self.row(lb, "Timed capture delay", self.combo("selfTimerSeconds", [(3, "3 seconds"), (5, "5 seconds"), (10, "10 seconds")], int))
        return box

    def recording_page(self):
        box, lb = self.page()
        self.row(lb, "Frame rate", self.combo("recordFPS", [(30, "30 fps"), (60, "60 fps")], int))
        self.row(lb, "Record system audio", self.switch("recordSystemAudio"))
        self.row(lb, "Record microphone", self.switch("recordMicrophone"))
        self.row(lb, "3 second count in", self.switch("recordCountIn"))
        self.row(lb, "Show cursor", self.switch("recordShowCursor"))
        note = Gtk.Label(xalign=0, margin_top=12, wrap=True)
        note.get_style_context().add_class("dim-label")
        note.set_markup("Recordings are MP4 (H.264 + AAC) through the ScreenCast portal. GNOME asks which screen to share the first time; the choice is remembered.")
        box.pack_start(note, False, False, 0)
        return box

    def shortcuts_page(self):
        box, lb = self.page()
        self.shortcut_buttons = {}
        for action, title, _default, _flag in ACTIONS:
            b = ShortcutButton(action, self)
            self.shortcut_buttons[action] = b
            self.row(lb, title, b)
        hint = Gtk.Label(xalign=0, margin_top=12, wrap=True)
        hint.get_style_context().add_class("dim-label")
        hint.set_text("Click a field and press the new keys. Backspace clears. Shortcuts are registered as GNOME custom keybindings, so they work on Wayland everywhere.")
        box.pack_start(hint, False, False, 0)
        reset = Gtk.Button(label="Reset to Defaults", halign=Gtk.Align.END, margin_top=8)
        reset.connect("clicked", lambda *_: self.reset_shortcuts())
        box.pack_start(reset, False, False, 0)
        return box

    def apply_shortcut(self, action, accel):
        settings.set_shortcut(action, accel)
        shortcuts.install_all()
        for b in self.shortcut_buttons.values():
            b.refresh()
        self.app.tray.rebuild()

    def reset_shortcuts(self):
        settings.reset_shortcuts()
        shortcuts.install_all()
        for b in self.shortcut_buttons.values():
            b.refresh()
        self.app.tray.rebuild()
        self.flash("Shortcuts reset")

    def apply_autostart(self, enabled):
        os.makedirs(os.path.dirname(AUTOSTART), exist_ok=True)
        if enabled:
            with open(AUTOSTART, "w") as f:
                f.write("[Desktop Entry]\nType=Application\nName=Snapline\nExec=%s\nIcon=snapline\n"
                        "X-GNOME-Autostart-enabled=true\nNoDisplay=true\n" % shortcuts.launcher_path())
        elif os.path.exists(AUTOSTART):
            os.remove(AUTOSTART)
