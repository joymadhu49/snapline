"""Clipboard that carries the picture, the file, and the path at once, so ⌃V
pastes an image in an editor and a path in a terminal.

Uses the classic GTK selection API on an invisible widget: it is the same
machinery GtkClipboard uses internally, handles INCR transfers for multi
megabyte PNGs, and (unlike set_with_data) is reachable from Python.
"""
import shlex

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GdkPixbuf, Gtk, GLib

_current = {"path": None}
_listeners = []
_owner = None
_payload = {}

INFO_PNG, INFO_URIS, INFO_GNOME, INFO_TEXT = 1, 2, 3, 4


def on_change(cb):
    _listeners.append(cb)


def current_path():
    return _current["path"]


def _notify():
    for cb in list(_listeners):
        cb(_current["path"])


def _ensure_owner():
    global _owner
    if _owner is None:
        _owner = Gtk.Invisible()
        _owner.realize()
        _owner.connect("selection-get", _on_selection_get)
        _owner.connect("selection-clear-event", _on_selection_clear)
    return _owner


def _on_selection_get(widget, selection, info, _time):
    if info == INFO_PNG and _payload.get("pixbuf") is not None:
        selection.set_pixbuf(_payload["pixbuf"])
    elif info == INFO_URIS:
        selection.set_uris([_payload["uri"]])
    elif info == INFO_GNOME:
        selection.set(Gdk.Atom.intern("x-special/gnome-copied-files", False), 8,
                      ("copy\n" + _payload["uri"]).encode())
    else:
        selection.set_text(_payload["text"], -1)


def _on_selection_clear(widget, event):
    if _current["path"] is not None:
        _current["path"] = None
        _notify()
    return True


def copy_capture(path, pixbuf=None):
    """Puts the capture on the clipboard: image/png for editors, text/uri-list
    for file managers and chat apps, the shell escaped path for terminals."""
    if pixbuf is None:
        try:
            pixbuf = GdkPixbuf.Pixbuf.new_from_file(path)
        except Exception:
            pixbuf = None
    _payload.clear()
    _payload.update(pixbuf=pixbuf, uri=GLib.filename_to_uri(path, None), text=shlex.quote(path))
    owner = _ensure_owner()
    Gtk.selection_clear_targets(owner, Gdk.SELECTION_CLIPBOARD)
    targets = []
    if pixbuf is not None:
        targets.append(Gtk.TargetEntry.new("image/png", 0, INFO_PNG))
    targets += [
        Gtk.TargetEntry.new("text/uri-list", 0, INFO_URIS),
        Gtk.TargetEntry.new("x-special/gnome-copied-files", 0, INFO_GNOME),
        Gtk.TargetEntry.new("UTF8_STRING", 0, INFO_TEXT),
        Gtk.TargetEntry.new("text/plain;charset=utf-8", 0, INFO_TEXT),
        Gtk.TargetEntry.new("text/plain", 0, INFO_TEXT),
        Gtk.TargetEntry.new("STRING", 0, INFO_TEXT),
        Gtk.TargetEntry.new("TEXT", 0, INFO_TEXT),
    ]
    Gtk.selection_add_targets(owner, Gdk.SELECTION_CLIPBOARD, targets)
    ok = Gtk.selection_owner_set(owner, Gdk.SELECTION_CLIPBOARD, Gdk.CURRENT_TIME)
    _current["path"] = path if ok else None
    _notify()
    return ok


def copy_text(text):
    Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).set_text(text, -1)
    _current["path"] = None
    _notify()


def get_image():
    clipboard = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
    pb = clipboard.wait_for_image()
    if pb is not None:
        return pb
    uris = clipboard.wait_for_uris()
    if uris:
        try:
            return GdkPixbuf.Pixbuf.new_from_file(GLib.filename_from_uri(uris[0])[0])
        except Exception:
            return None
    text = clipboard.wait_for_text()
    if text:
        try:
            return GdkPixbuf.Pixbuf.new_from_file(text.strip().strip("'\""))
        except Exception:
            return None
    return None
