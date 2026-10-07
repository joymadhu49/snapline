"""Global shortcuts through GNOME's custom keybindings. Each Snapline action gets
one entry that runs the launcher with the matching flag; the running instance
picks the flag up through GApplication."""
import os
import shutil

from gi.repository import Gio, Gtk

from snapline.settings import ACTIONS, ACTION_TITLES, ACTION_FLAGS, settings

MEDIA_KEYS = "org.gnome.settings-daemon.plugins.media-keys"
CUSTOM = "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding"
BASE = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/"


def launcher_path():
    for candidate in (os.path.expanduser("~/.local/bin/snapline"), shutil.which("snapline")):
        if candidate and os.path.exists(candidate):
            return candidate
    return os.path.expanduser("~/.local/bin/snapline")


def _path_for(action):
    return f"{BASE}snapline-{action}/"


def install_all():
    """Writes every configured shortcut into gsettings, removing stale ones."""
    root = Gio.Settings.new(MEDIA_KEYS)
    current = list(root.get_strv("custom-keybindings"))
    ours = {_path_for(a[0]) for a in ACTIONS}
    keep = [p for p in current if p not in ours]
    launcher = launcher_path()
    for action, title, _default, flag in ACTIONS:
        path = _path_for(action)
        accel = settings.shortcut_for(action)
        entry = Gio.Settings.new_with_path(CUSTOM, path)
        if accel:
            entry.set_string("name", f"Snapline: {title}")
            entry.set_string("command", f"{launcher} {flag}")
            entry.set_string("binding", accel)
            keep.append(path)
        else:
            for key in ("name", "command", "binding"):
                entry.reset(key)
    root.set_strv("custom-keybindings", keep)
    Gio.Settings.sync()


def uninstall_all():
    root = Gio.Settings.new(MEDIA_KEYS)
    ours = {_path_for(a[0]) for a in ACTIONS}
    root.set_strv("custom-keybindings", [p for p in root.get_strv("custom-keybindings") if p not in ours])
    for action, *_ in ACTIONS:
        entry = Gio.Settings.new_with_path(CUSTOM, _path_for(action))
        for key in ("name", "command", "binding"):
            entry.reset(key)
    Gio.Settings.sync()


def label_for(accel):
    if not accel:
        return "None"
    key, mods = Gtk.accelerator_parse(accel)
    if key == 0:
        return accel
    return Gtk.accelerator_get_label(key, mods).replace("Mod4", "Super")


def conflict_for(accel, action):
    """Which other Snapline action already uses this combination, if any."""
    for other, existing in (settings.get("shortcuts") or {}).items():
        if existing == accel and other != action:
            return ACTION_TITLES.get(other, other)
    return None
