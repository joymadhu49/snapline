"""Recent capture files, most recent first."""
import os
import subprocess

from gi.repository import GLib

from snapline.settings import settings

CAPACITY = 200
_listeners = []


def on_change(cb):
    _listeners.append(cb)


def _notify():
    for cb in list(_listeners):
        GLib.idle_add(cb)


def add(path):
    paths = [p for p in settings.captureHistory if p != path]
    paths.insert(0, path)
    settings.captureHistory = paths[:CAPACITY]
    _notify()


def items():
    return [p for p in settings.captureHistory if os.path.exists(p)]


def forget(path):
    settings.captureHistory = [p for p in settings.captureHistory if p != path]
    _notify()


def delete(path):
    """Drops the entry and sends the file to the trash, so the history and the
    disk never disagree about what still exists."""
    forget(path)
    try:
        subprocess.run(["gio", "trash", path], check=False, capture_output=True)
    except OSError:
        try:
            os.remove(path)
        except OSError:
            pass


def clear():
    settings.captureHistory = []
    _notify()
