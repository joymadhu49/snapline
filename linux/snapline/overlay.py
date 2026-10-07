"""Frozen screen selection overlay.

The frame is grabbed through the portal before any window appears, then every
monitor gets a fullscreen window showing its slice of that frame. Dragging
draws a marquee with live pixel dimensions; nothing on the real screen changes
under the user's hands.
"""
import math

import cairo
import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gtk, GLib

from snapline.util import monitor_geometry, pixbuf_to_surface, rounded_rect

ACCENT = (0.44, 0.38, 0.96)
HINTS = {
    "area": "Drag to select  ·  Return for full screen  ·  Esc to cancel",
    "record": "Drag the area to record  ·  Return for full screen  ·  Esc to cancel",
    "text": "Drag over the text to copy  ·  Esc to cancel",
    "timed": "Drag to select, the countdown starts after  ·  Esc to cancel",
    "window": "Click a window  ·  or drag an area  ·  Esc to cancel",
}


class SelectionSession:
    """One selection across every monitor; finishes once, closes everything."""

    def __init__(self, pixbuf, mode, callback, scale=1.0):
        self.pixbuf = pixbuf
        self.surface = pixbuf_to_surface(pixbuf)
        self.mode = mode
        self.callback = callback
        self.scale = scale
        self.windows = []
        self.finished = False
        display = Gdk.Display.get_default()
        for i in range(display.get_n_monitors()):
            m = display.get_monitor(i)
            self.windows.append(OverlayWindow(self, m, i))
        for w in self.windows:
            w.show_all()
        pointer = display.get_default_seat().get_pointer()
        _s, px, py = pointer.get_position()
        for w in self.windows:
            x, y, mw, mh = w.geometry
            if x <= px < x + mw and y <= py < y + mh:
                w.present()
                w.pointer_moved(px - x, py - y)

    def finish(self, result):
        if self.finished:
            return
        self.finished = True
        for w in self.windows:
            w.hide()
        for w in self.windows:
            w.destroy()
        self.windows = []
        # Let the compositor drop the overlay before the result is acted on.
        GLib.timeout_add(40, lambda: (self.callback(result), False)[1])

    def image_rect(self, window, x, y, w, h):
        gx, gy = window.geometry[0] + x, window.geometry[1] + y
        s = self.scale
        return (int(round(gx * s)), int(round(gy * s)), max(1, int(round(w * s))), max(1, int(round(h * s))))


class OverlayWindow(Gtk.Window):
    def __init__(self, session, monitor, index):
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.session = session
        self.monitor = monitor
        self.geometry = monitor_geometry(monitor)
        x, y, w, h = self.geometry
        self.set_title("Snapline Selection")
        self.set_decorated(False)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_keep_above(True)
        self.set_resizable(False)
        self.set_type_hint(Gdk.WindowTypeHint.NORMAL)
        self.move(x, y)
        self.set_default_size(w, h)
        self.set_size_request(w, h)
        self.fullscreen_on_monitor(self.get_screen(), index)

        self.cursor = None
        self.anchor = None
        self.rect = None
        self.dragging = False
        self.moving = None
        self.space = False
        self.mods = 0

        self.area = Gtk.DrawingArea()
        self.area.set_size_request(w, h)
        self.add(self.area)
        self.area.connect("draw", self.on_draw)
        self.add_events(Gdk.EventMask.POINTER_MOTION_MASK | Gdk.EventMask.BUTTON_PRESS_MASK
                        | Gdk.EventMask.BUTTON_RELEASE_MASK | Gdk.EventMask.KEY_PRESS_MASK
                        | Gdk.EventMask.KEY_RELEASE_MASK | Gdk.EventMask.LEAVE_NOTIFY_MASK)
        self.connect("motion-notify-event", self.on_motion)
        self.connect("button-press-event", self.on_press)
        self.connect("button-release-event", self.on_release)
        self.connect("key-press-event", self.on_key)
        self.connect("key-release-event", self.on_key_release)
        self.connect("leave-notify-event", self.on_leave)
        self.connect("realize", self.on_realize)
        self.connect("delete-event", lambda *_: self.session.finish(None) or True)

    def on_realize(self, _w):
        gdk_window = self.get_window()
        gdk_window.set_cursor(Gdk.Cursor.new_from_name(self.get_display(), "none"))

    # Pointer

    def pointer_moved(self, x, y):
        self.cursor = (x, y)
        self.area.queue_draw()

    def on_leave(self, _w, event):
        if not self.dragging:
            self.cursor = None
            self.area.queue_draw()

    def on_motion(self, _w, event):
        self.mods = event.state
        self.cursor = (event.x, event.y)
        if self.dragging and self.anchor is not None:
            if self.space and self.rect:
                if self.moving is None:
                    self.moving = (event.x, event.y)
                dx, dy = event.x - self.moving[0], event.y - self.moving[1]
                self.moving = (event.x, event.y)
                ax, ay = self.anchor
                self.anchor = (ax + dx, ay + dy)
                rx, ry, rw, rh = self.rect
                self.rect = (rx + dx, ry + dy, rw, rh)
            else:
                self.rect = self.compute_rect(event.x, event.y, event.state)
        self.area.queue_draw()
        return True

    def compute_rect(self, x, y, state):
        ax, ay = self.anchor
        dx, dy = x - ax, y - ay
        if state & Gdk.ModifierType.SHIFT_MASK:
            side = max(abs(dx), abs(dy))
            dx = math.copysign(side, dx) if dx else side
            dy = math.copysign(side, dy) if dy else side
        if state & Gdk.ModifierType.MOD1_MASK:
            return (ax - abs(dx), ay - abs(dy), abs(dx) * 2, abs(dy) * 2)
        return (min(ax, ax + dx), min(ay, ay + dy), abs(dx), abs(dy))

    def on_press(self, _w, event):
        if event.button == 3:
            self.session.finish(None)
            return True
        if event.button == 1:
            self.anchor = (event.x, event.y)
            self.dragging = True
            self.rect = (event.x, event.y, 0, 0)
            self.moving = None
            self.area.queue_draw()
        return True

    def on_release(self, _w, event):
        if event.button != 1 or not self.dragging:
            return True
        self.dragging = False
        rect = self.rect
        self.rect = None
        if rect and rect[2] >= 3 and rect[3] >= 3:
            x, y, w, h = self.clamp(rect)
            self.session.finish(("rect", self.session.image_rect(self, x, y, w, h)))
        elif self.session.mode == "window":
            self.session.finish(("click", self.session.image_rect(self, event.x, event.y, 1, 1)))
        else:
            self.area.queue_draw()
        return True

    def clamp(self, rect):
        x, y, w, h = rect
        mw, mh = self.geometry[2], self.geometry[3]
        x0, y0 = max(0, x), max(0, y)
        x1, y1 = min(mw, x + w), min(mh, y + h)
        return (int(round(x0)), int(round(y0)), max(1, int(round(x1 - x0))), max(1, int(round(y1 - y0))))

    # Keys

    def on_key(self, _w, event):
        key = event.keyval
        if key == Gdk.KEY_Escape:
            self.session.finish(None)
        elif key in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
            x, y, w, h = self.geometry
            self.session.finish(("full", self.session.image_rect(self, 0, 0, w, h)))
        elif key == Gdk.KEY_space:
            self.space = True
            self.moving = None
        elif key in (Gdk.KEY_Shift_L, Gdk.KEY_Shift_R, Gdk.KEY_Alt_L, Gdk.KEY_Alt_R):
            if self.dragging and self.cursor and not self.space:
                state = event.state | (Gdk.ModifierType.SHIFT_MASK if key in (Gdk.KEY_Shift_L, Gdk.KEY_Shift_R) else Gdk.ModifierType.MOD1_MASK)
                self.rect = self.compute_rect(self.cursor[0], self.cursor[1], state)
                self.area.queue_draw()
        return True

    def on_key_release(self, _w, event):
        key = event.keyval
        if key == Gdk.KEY_space:
            self.space = False
            self.moving = None
            if self.dragging and self.rect and self.cursor:
                # Re-anchor so the rectangle keeps its place and size.
                rx, ry, rw, rh = self.rect
                cx, cy = self.cursor
                self.anchor = (rx if abs(cx - rx) > abs(cx - (rx + rw)) else rx + rw,
                               ry if abs(cy - ry) > abs(cy - (ry + rh)) else ry + rh)
        elif key in (Gdk.KEY_Shift_L, Gdk.KEY_Shift_R, Gdk.KEY_Alt_L, Gdk.KEY_Alt_R):
            if self.dragging and self.cursor and not self.space:
                mask = Gdk.ModifierType.SHIFT_MASK if key in (Gdk.KEY_Shift_L, Gdk.KEY_Shift_R) else Gdk.ModifierType.MOD1_MASK
                self.rect = self.compute_rect(self.cursor[0], self.cursor[1], event.state & ~mask)
                self.area.queue_draw()
        return True

    # Drawing

    def on_draw(self, _area, cr):
        mx, my, mw, mh = self.geometry
        s = self.session.scale
        cr.save()
        cr.scale(1 / s, 1 / s)
        cr.set_source_surface(self.session.surface, -mx * s, -my * s)
        cr.get_source().set_filter(cairo.FILTER_NEAREST if s == 1 else cairo.FILTER_GOOD)
        cr.paint()
        cr.restore()

        rect = self.rect if self.dragging and self.rect else None

        # Dim everything except the selection.
        cr.set_source_rgba(0, 0, 0, 0.32)
        if rect:
            x, y, w, h = rect
            cr.set_fill_rule(cairo.FILL_RULE_EVEN_ODD)
            cr.rectangle(0, 0, mw, mh)
            cr.rectangle(x, y, w, h)
            cr.fill()
            cr.set_fill_rule(cairo.FILL_RULE_WINDING)
        else:
            cr.rectangle(0, 0, mw, mh)
            cr.fill()

        if rect:
            self.draw_marquee(cr, rect)
        elif self.cursor:
            self.draw_crosshair(cr, self.cursor)
        self.draw_hint(cr, mw)

    def draw_crosshair(self, cr, cursor):
        x, y = cursor
        mw, mh = self.geometry[2], self.geometry[3]
        cr.set_line_width(1)
        for color in ((0, 0, 0, 0.45), (1, 1, 1, 0.85)):
            cr.set_source_rgba(*color)
            off = 0.5 if color[0] else 1.5
            cr.move_to(0, int(y) + off); cr.line_to(mw, int(y) + off)
            cr.move_to(int(x) + off, 0); cr.line_to(int(x) + off, mh)
            cr.stroke()
        self.draw_label(cr, f"{int(x)}, {int(y)}", x + 14, y + 14)

    def draw_marquee(self, cr, rect):
        x, y, w, h = rect
        cr.set_line_width(1)
        cr.set_source_rgba(0, 0, 0, 0.5)
        cr.rectangle(x - 0.5, y - 0.5, w + 1, h + 1)
        cr.stroke()
        cr.set_source_rgba(1, 1, 1, 0.95)
        cr.rectangle(x + 0.5, y + 0.5, max(0, w - 1), max(0, h - 1))
        cr.stroke()
        if w > 40 and h > 40:
            cr.set_source_rgba(1, 1, 1, 0.28)
            for i in (1, 2):
                cr.move_to(x + w * i / 3 + 0.5, y); cr.line_to(x + w * i / 3 + 0.5, y + h)
                cr.move_to(x, y + h * i / 3 + 0.5); cr.line_to(x + w, y + h * i / 3 + 0.5)
            cr.stroke()
        for hx, hy in ((x, y), (x + w, y), (x, y + h), (x + w, y + h)):
            cr.arc(hx, hy, 4, 0, 2 * math.pi)
            cr.set_source_rgba(1, 1, 1, 1)
            cr.fill_preserve()
            cr.set_source_rgba(0, 0, 0, 0.5)
            cr.stroke()
        s = self.session.scale
        label = f"{int(round(w * s))} × {int(round(h * s))}"
        lx, ly = x + w + 10, y + h + 10
        mw, mh = self.geometry[2], self.geometry[3]
        if lx + 90 > mw:
            lx = x - 90
        if ly + 30 > mh:
            ly = y - 34
        self.draw_label(cr, label, lx, ly)

    def draw_label(self, cr, text, x, y):
        cr.select_font_face("Inter, Cantarell, sans-serif", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL)
        cr.set_font_size(12)
        ext = cr.text_extents(text)
        pw, ph = ext.width + 16, 22
        rounded_rect(cr, x, y, pw, ph, 6)
        cr.set_source_rgba(0.08, 0.08, 0.1, 0.9)
        cr.fill()
        cr.set_source_rgba(1, 1, 1, 0.95)
        cr.move_to(x + 8 - ext.x_bearing, y + ph / 2 + ext.height / 2 - 1)
        cr.show_text(text)

    def draw_hint(self, cr, mw):
        text = HINTS.get(self.session.mode, HINTS["area"])
        cr.select_font_face("Inter, Cantarell, sans-serif", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL)
        cr.set_font_size(13)
        ext = cr.text_extents(text)
        pw, ph = ext.width + 28, 30
        x, y = (mw - pw) / 2, 22
        rounded_rect(cr, x, y, pw, ph, 15)
        cr.set_source_rgba(0.08, 0.08, 0.1, 0.82)
        cr.fill()
        cr.set_source_rgba(1, 1, 1, 0.8)
        cr.move_to(x + 14 - ext.x_bearing, y + ph / 2 + ext.height / 2 - 1)
        cr.show_text(text)
