"""Single instance GApplication. Every shortcut and menu launch runs the
launcher with a flag; GApplication forwards it to the running instance."""
import sys

from gi.repository import Gio, GLib, Gtk

from snapline import APP_ID, __version__

FLAGS = {
    "--capture-area": "capture_area",
    "--capture-fullscreen": "capture_fullscreen",
    "--capture-window": "capture_window",
    "--capture-previous-area": "capture_previous_area",
    "--capture-text": "capture_text",
    "--toggle-recording": "toggle_recording",
    "--stop-recording": "stop_recording",
    "--timed-capture": "timed_capture",
    "--pin-from-clipboard": "pin_from_clipboard",
    "--show-history": "show_history",
    "--open-folder": "open_folder",
}

HELP = """Snapline for Linux %s

Usage: snapline [flag]

  (no flag)                 start Snapline in the tray, or bring it forward
  --capture-area            frozen screen selection
  --capture-fullscreen      the display under the cursor
  --capture-window          GNOME's window picker
  --capture-previous-area   repeat the last selection
  --capture-text            OCR a region to the clipboard
  --toggle-recording        start or stop a screen recording
  --stop-recording
  --timed-capture           select an area, then count down
  --pin-from-clipboard
  --show-history
  --open-folder
  --settings                open Settings
  --shortcuts               open the Shortcuts tab
  --install-shortcuts       (re)register the GNOME keybindings and exit
  --uninstall-shortcuts     remove them and exit
  --quit                    stop the running instance
""" % __version__


class SnaplineApp(Gtk.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.HANDLES_COMMAND_LINE)
        self.coordinator = None
        self.tray = None

    def do_startup(self):
        Gtk.Application.do_startup(self)
        Gtk.Settings.get_default().set_property("gtk-application-prefer-dark-theme", True)
        from snapline import shortcuts
        from snapline.capture import Coordinator
        from snapline.portal import grant_screenshot_permission
        from snapline.tray import Tray
        grant_screenshot_permission()
        self.coordinator = Coordinator()
        self.tray = Tray(self)
        try:
            shortcuts.install_all()
        except Exception as e:  # gsettings schema missing outside GNOME
            print("shortcuts:", e, file=sys.stderr)
        self.hold()

    def do_activate(self):
        pass

    def do_command_line(self, command_line):
        args = command_line.get_arguments()[1:]
        if not args:
            if command_line.get_is_remote():
                from snapline.hud import toast
                toast("Snapline is running in the top bar")
            return 0
        flag = args[0]
        if flag in ("-h", "--help"):
            command_line.print_literal(HELP)
            return 0
        if flag == "--quit":
            self.quit_app()
            return 0
        if flag in ("--settings", "--shortcuts"):
            self.show_settings("shortcuts" if flag == "--shortcuts" else "general")
            return 0
        method = FLAGS.get(flag)
        if method is None:
            command_line.print_literal(f"Unknown flag {flag}\n{HELP}")
            return 1
        GLib.idle_add(lambda: (getattr(self.coordinator, method)(), False)[1])
        return 0

    def show_settings(self, page="general"):
        from snapline.settingswindow import SettingsWindow
        SettingsWindow.show_page(self, page)

    def quit_app(self):
        if self.coordinator and self.coordinator.recorder.recording:
            self.coordinator.recorder.stop()
            GLib.timeout_add(1500, self.quit)
        else:
            self.quit()


def main(argv):
    if len(argv) > 1 and argv[1] in ("--install-shortcuts", "--uninstall-shortcuts"):
        from snapline import shortcuts
        if argv[1] == "--install-shortcuts":
            shortcuts.install_all()
            print("Snapline shortcuts registered with GNOME")
        else:
            shortcuts.uninstall_all()
            print("Snapline shortcuts removed")
        return 0
    if len(argv) > 1 and argv[1] in ("-h", "--help"):
        print(HELP)
        return 0
    if len(argv) > 1 and argv[1] == "--version":
        print(__version__)
        return 0
    app = SnaplineApp()
    return app.run(argv)
