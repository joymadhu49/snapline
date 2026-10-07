import os
import shutil
import subprocess

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib

from snapline.settings import settings

SOUNDS = {
    "capture": "/usr/share/sounds/freedesktop/stereo/camera-shutter.oga",
    "complete": "/usr/share/sounds/freedesktop/stereo/complete.oga",
}


def play_sound(name):
    if not settings.playSounds:
        return
    path = SOUNDS.get(name)
    if not path or not os.path.exists(path):
        return
    for cmd in (["paplay", path], ["pw-play", path], ["canberra-gtk-play", "-f", path]):
        if shutil.which(cmd[0]):
            try:
                subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except OSError:
                pass
            return


def open_path(path):
    subprocess.Popen(["xdg-open", path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def show_in_folder(path):
    try:
        subprocess.Popen(["dbus-send", "--session", "--dest=org.freedesktop.FileManager1", "--type=method_call",
                          "/org/freedesktop/FileManager1", "org.freedesktop.FileManager1.ShowItems",
                          f"array:string:{GLib.filename_to_uri(path, None)}", "string:"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        open_path(os.path.dirname(path))


def pointer_position():
    display = Gdk.Display.get_default()
    seat = display.get_default_seat()
    _screen, x, y = seat.get_pointer().get_position()
    return x, y


def monitor_at_pointer():
    display = Gdk.Display.get_default()
    x, y = pointer_position()
    return display.get_monitor_at_point(x, y)


def monitor_geometry(monitor):
    g = monitor.get_geometry()
    return g.x, g.y, g.width, g.height


def screen_bounds():
    display = Gdk.Display.get_default()
    x0 = y0 = 10 ** 9
    x1 = y1 = -10 ** 9
    for i in range(display.get_n_monitors()):
        x, y, w, h = monitor_geometry(display.get_monitor(i))
        x0, y0, x1, y1 = min(x0, x), min(y0, y), max(x1, x + w), max(y1, y + h)
    return x0, y0, x1 - x0, y1 - y0


def rgba(hexstr, alpha=1.0):
    c = Gdk.RGBA()
    c.parse(hexstr)
    c.alpha = alpha
    return c


def rounded_rect(cr, x, y, w, h, r):
    import math
    r = max(0, min(r, w / 2, h / 2))
    cr.new_sub_path()
    cr.arc(x + w - r, y + r, r, -math.pi / 2, 0)
    cr.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
    cr.arc(x + r, y + h - r, r, math.pi / 2, math.pi)
    cr.arc(x + r, y + r, r, math.pi, 3 * math.pi / 2)
    cr.close_path()


def pixbuf_to_surface(pixbuf):
    import cairo
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, pixbuf.get_width(), pixbuf.get_height())
    cr = cairo.Context(surface)
    Gdk.cairo_set_source_pixbuf(cr, pixbuf, 0, 0)
    cr.paint()
    return surface


def surface_to_pixbuf(surface):
    return Gdk.pixbuf_get_from_surface(surface, 0, 0, surface.get_width(), surface.get_height())
