"""Countdown and toast windows: transparent, click through, never focused."""
import math

import cairo
import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gtk, GLib

from snapline.util import monitor_at_pointer, monitor_geometry, rounded_rect


class _FloatingWindow(Gtk.Window):
    def __init__(self, w, h):
        super().__init__(type=Gtk.WindowType.POPUP)
        self.set_app_paintable(True)
        self.set_decorated(False)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_keep_above(True)
        self.set_accept_focus(False)
        self.set_focus_on_map(False)
        self.set_type_hint(Gdk.WindowTypeHint.NOTIFICATION)
        visual = self.get_screen().get_rgba_visual()
        if visual:
            self.set_visual(visual)
        self.set_default_size(w, h)
        self.set_size_request(w, h)
        self.area = Gtk.DrawingArea()
        self.add(self.area)
        self.area.connect("draw", self.on_draw)
        self.connect("realize", self._click_through)

    def _click_through(self, _w):
        self.get_window().input_shape_combine_region(cairo.Region(), 0, 0)

    def on_draw(self, area, cr):
        cr.set_operator(cairo.OPERATOR_SOURCE)
        cr.set_source_rgba(0, 0, 0, 0)
        cr.paint()
        cr.set_operator(cairo.OPERATOR_OVER)
        self.paint(cr, area.get_allocated_width(), area.get_allocated_height())

    def paint(self, cr, w, h):
        pass


class Countdown(_FloatingWindow):
    SIZE = 180

    def __init__(self, seconds, on_done, monitor=None):
        super().__init__(self.SIZE, self.SIZE)
        self.remaining = seconds
        self.on_done = on_done
        m = monitor or monitor_at_pointer()
        x, y, w, h = monitor_geometry(m)
        self.move(x + (w - self.SIZE) // 2, y + (h - self.SIZE) // 2)
        self.show_all()
        self.timer = GLib.timeout_add(1000, self.tick)

    def tick(self):
        self.remaining -= 1
        if self.remaining <= 0:
            self.hide()
            self.destroy()
            GLib.idle_add(self.on_done)
            return False
        self.area.queue_draw()
        return True

    def cancel(self):
        GLib.source_remove(self.timer)
        self.destroy()

    def paint(self, cr, w, h):
        cx, cy, r = w / 2, h / 2, w / 2 - 6
        cr.arc(cx, cy, r, 0, 2 * math.pi)
        cr.set_source_rgba(0.08, 0.08, 0.1, 0.82)
        cr.fill()
        cr.set_line_width(4)
        cr.set_source_rgba(0.44, 0.38, 0.96, 1)
        cr.arc(cx, cy, r - 2, -math.pi / 2, -math.pi / 2 + 2 * math.pi)
        cr.stroke()
        text = str(self.remaining)
        cr.select_font_face("Inter, Cantarell, sans-serif", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)
        cr.set_font_size(84)
        ext = cr.text_extents(text)
        cr.set_source_rgba(1, 1, 1, 1)
        cr.move_to(cx - ext.width / 2 - ext.x_bearing, cy + ext.height / 2)
        cr.show_text(text)


class Toast(_FloatingWindow):
    _current = None

    def __init__(self, text, duration=1800, monitor=None):
        cr = cairo.Context(cairo.ImageSurface(cairo.FORMAT_ARGB32, 1, 1))
        cr.select_font_face("Inter, Cantarell, sans-serif", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL)
        cr.set_font_size(14)
        ext = cr.text_extents(text)
        width, height = int(ext.width + 40), 40
        super().__init__(width, height)
        self.text = text
        m = monitor or monitor_at_pointer()
        x, y, w, h = monitor_geometry(m)
        self.move(x + (w - width) // 2, y + h - height - 72)
        if Toast._current is not None:
            try:
                Toast._current.destroy()
            except Exception:
                pass
        Toast._current = self
        self.show_all()
        GLib.timeout_add(duration, self._done)

    def _done(self):
        if Toast._current is self:
            Toast._current = None
        self.destroy()
        return False

    def paint(self, cr, w, h):
        rounded_rect(cr, 0, 0, w, h, h / 2)
        cr.set_source_rgba(0.08, 0.08, 0.1, 0.92)
        cr.fill()
        cr.select_font_face("Inter, Cantarell, sans-serif", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL)
        cr.set_font_size(14)
        ext = cr.text_extents(self.text)
        cr.set_source_rgba(1, 1, 1, 0.95)
        cr.move_to(20 - ext.x_bearing, h / 2 + ext.height / 2 - 1)
        cr.show_text(self.text)


def toast(text, **kw):
    GLib.idle_add(lambda: (Toast(text, **kw), False)[1])
