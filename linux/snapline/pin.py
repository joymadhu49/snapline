"""Pin to screen: floating always on top reference windows. Drag to move, scroll
to change opacity, double click closes."""
import cairo
import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gtk

from snapline import imagewriter
from snapline.util import monitor_at_pointer, monitor_geometry, rounded_rect

_pins = []


class PinWindow(Gtk.Window):
    def __init__(self, pixbuf, path=None):
        super().__init__(type=Gtk.WindowType.POPUP)
        self.path = path
        self.opacity = 1.0
        self.drag = None
        self.set_app_paintable(True)
        self.set_decorated(False)
        self.set_keep_above(True)
        self.set_accept_focus(False)
        self.set_type_hint(Gdk.WindowTypeHint.UTILITY)
        visual = self.get_screen().get_rgba_visual()
        if visual:
            self.set_visual(visual)
        mx, my, mw, mh = monitor_geometry(monitor_at_pointer())
        self.pixbuf = imagewriter.scaled_to_fit(pixbuf, int(mw * 0.45), int(mh * 0.45))
        w, h = self.pixbuf.get_width() + 2, self.pixbuf.get_height() + 2
        self.set_default_size(w, h)
        self.set_size_request(w, h)
        px, py = mx + (mw - w) // 2 + 40 * len(_pins), my + (mh - h) // 2 + 40 * len(_pins)
        self.move(px, py)
        self.area = Gtk.DrawingArea()
        self.add(self.area)
        self.area.add_events(Gdk.EventMask.BUTTON_PRESS_MASK | Gdk.EventMask.BUTTON_RELEASE_MASK
                             | Gdk.EventMask.POINTER_MOTION_MASK | Gdk.EventMask.SCROLL_MASK
                             | Gdk.EventMask.SMOOTH_SCROLL_MASK)
        self.area.connect("draw", self.on_draw)
        self.area.connect("button-press-event", self.on_press)
        self.area.connect("button-release-event", self.on_release)
        self.area.connect("motion-notify-event", self.on_motion)
        self.area.connect("scroll-event", self.on_scroll)
        _pins.append(self)
        self.show_all()

    def on_draw(self, area, cr):
        cr.set_operator(cairo.OPERATOR_SOURCE)
        cr.set_source_rgba(0, 0, 0, 0)
        cr.paint()
        cr.set_operator(cairo.OPERATOR_OVER)
        w, h = area.get_allocated_width(), area.get_allocated_height()
        rounded_rect(cr, 0.5, 0.5, w - 1, h - 1, 6)
        cr.save()
        cr.clip_preserve()
        Gdk.cairo_set_source_pixbuf(cr, self.pixbuf, 1, 1)
        cr.paint()
        cr.restore()
        cr.set_line_width(1)
        cr.set_source_rgba(1, 1, 1, 0.35)
        cr.stroke()

    def on_press(self, _w, event):
        if event.type == Gdk.EventType._2BUTTON_PRESS:
            self.close()
            return True
        if event.button == 1:
            self.drag = (event.x_root, event.y_root, *self.get_position())
        elif event.button == 3:
            menu = Gtk.Menu()
            for title, cb in (("Copy", lambda *_: self.copy()), ("Reset opacity", lambda *_: self.set_alpha(1.0)),
                              ("Close", lambda *_: self.close())):
                item = Gtk.MenuItem(label=title)
                item.connect("activate", cb)
                menu.append(item)
            menu.show_all()
            menu.popup_at_pointer(event)
        return True

    def on_release(self, _w, event):
        self.drag = None
        return True

    def on_motion(self, _w, event):
        if self.drag:
            x0, y0, wx, wy = self.drag
            self.move(int(wx + event.x_root - x0), int(wy + event.y_root - y0))
        return True

    def on_scroll(self, _w, event):
        delta = 0
        if event.direction == Gdk.ScrollDirection.UP:
            delta = 0.1
        elif event.direction == Gdk.ScrollDirection.DOWN:
            delta = -0.1
        elif event.direction == Gdk.ScrollDirection.SMOOTH:
            delta = -event.delta_y * 0.1
        if delta:
            self.set_alpha(self.opacity + delta)
        return True

    def set_alpha(self, value):
        self.opacity = max(0.15, min(1.0, value))
        self.set_opacity(self.opacity)

    def copy(self):
        from snapline import clipboard
        if self.path:
            clipboard.copy_capture(self.path)
        else:
            Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).set_image(self.pixbuf)

    def close(self):
        if self in _pins:
            _pins.remove(self)
        self.destroy()


def pin(pixbuf, path=None):
    return PinWindow(pixbuf, path)
