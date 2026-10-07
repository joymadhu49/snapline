"""Quick Access overlay: after every capture the shot floats in the bottom left
corner as a card. Cards slide in from the left, hover shows actions, a click
copies, a drag carries the file out, closing one lets the stack settle."""
import os
import shlex

import cairo
import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GdkPixbuf, Gtk, GLib

from snapline import clipboard, imagewriter
from snapline.settings import settings
from snapline.util import monitor_geometry, rounded_rect

# Every card is the same size, like the Mac stack: the shot fills a 260×148 box.
THUMB_W, THUMB_H, RADIUS = 260, 148, 10
INSET = 8  # room for the shadow around the box
CARD_W, CARD_H = THUMB_W + INSET * 2, THUMB_H + INSET * 2
MARGIN, GAP = 12, 2
ACTIONS = ["Copy", "Save", "Edit", "Pin"]


class QuickAccessPanel:
    def __init__(self, app):
        self.app = app
        self.cards = []
        clipboard.on_change(lambda _p: self.redraw_all())

    def monitor(self):
        display = Gdk.Display.get_default()
        return display.get_primary_monitor() or display.get_monitor(0)

    def capacity(self):
        x, y, w, h = monitor_geometry(self.monitor())
        fit = max(1, (h - MARGIN * 2 + GAP) // (CARD_H + GAP))
        cap = settings.overlayMaxCards or 0
        return min(fit, cap) if cap > 0 else fit

    def find(self, path):
        for c in self.cards:
            if c.path == path:
                return c
        return None

    def show(self, path, pixbuf=None, kind="screenshot", thumbnail=None):
        existing = self.find(path)
        if existing:
            existing.refresh(pixbuf, thumbnail)
            existing.pulse()
            return existing
        while len(self.cards) >= self.capacity():
            self.cards[-1].close(animated=False)
        card = Card(self, path, pixbuf, kind, thumbnail)
        self.cards.insert(0, card)
        self.layout(animate_new=card)
        return card

    def remove(self, card):
        if card in self.cards:
            self.cards.remove(card)
        self.layout()

    def target_position(self, index):
        mx, my, mw, mh = monitor_geometry(self.monitor())
        x = mx + MARGIN
        y = my + mh - MARGIN - CARD_H - index * (CARD_H + GAP)
        return x, y

    def layout(self, animate_new=None):
        for i, card in enumerate(self.cards):
            x, y = self.target_position(i)
            if card is animate_new:
                card.slide_in(x, y)
            else:
                card.glide_to(x, y)

    def redraw_all(self):
        for c in self.cards:
            c.area.queue_draw()

    def clear(self):
        for c in list(self.cards):
            c.close(animated=False)


class Card(Gtk.Window):
    def __init__(self, panel, path, pixbuf, kind, thumbnail):
        super().__init__(type=Gtk.WindowType.POPUP)
        self.panel = panel
        self.path = path
        self.kind = kind
        self.hover = False
        self.hover_action = None
        self.press = None
        self.dragging = False
        self.anim = None
        self.pulse_phase = 0.0
        self.set_app_paintable(True)
        self.set_decorated(False)
        self.set_keep_above(True)
        self.set_accept_focus(False)
        self.set_type_hint(Gdk.WindowTypeHint.NOTIFICATION)
        visual = self.get_screen().get_rgba_visual()
        if visual:
            self.set_visual(visual)
        self.set_default_size(CARD_W, CARD_H)
        self.set_size_request(CARD_W, CARD_H)
        self.area = Gtk.DrawingArea()
        self.add(self.area)
        self.area.add_events(Gdk.EventMask.POINTER_MOTION_MASK | Gdk.EventMask.BUTTON_PRESS_MASK
                             | Gdk.EventMask.BUTTON_RELEASE_MASK | Gdk.EventMask.ENTER_NOTIFY_MASK
                             | Gdk.EventMask.LEAVE_NOTIFY_MASK)
        self.area.connect("draw", self.on_draw)
        self.area.connect("enter-notify-event", self.on_enter)
        self.area.connect("leave-notify-event", self.on_leave)
        self.area.connect("motion-notify-event", self.on_motion)
        self.area.connect("button-press-event", self.on_press)
        self.area.connect("button-release-event", self.on_release)
        targets = Gtk.TargetList.new([])
        targets.add_uri_targets(1)
        targets.add_text_targets(2)
        targets.add_image_targets(3, True)
        self.area.drag_source_set(Gdk.ModifierType.BUTTON1_MASK, [], Gdk.DragAction.COPY)
        self.area.drag_source_set_target_list(targets)
        self.area.connect("drag-begin", self.on_drag_begin)
        self.area.connect("drag-data-get", self.on_drag_data_get)
        self.area.connect("drag-end", self.on_drag_end)
        self.area.connect("drag-failed", self.on_drag_failed)
        self.refresh(pixbuf, thumbnail)

    def refresh(self, pixbuf=None, thumbnail=None):
        source = thumbnail or pixbuf
        if source is None and not imagewriter.is_video(self.path):
            source = imagewriter.load_pixbuf(self.path)
        self.full_pixbuf = pixbuf if pixbuf is not None else (None if imagewriter.is_video(self.path) else source)
        self.thumb = imagewriter.scaled_to_fill(source, THUMB_W, THUMB_H) if source else None
        self.area.queue_draw()

    # Animation

    def slide_in(self, x, y):
        self.move(x - CARD_W - 20, y)
        self.show_all()
        self.animate(x, y, 200)

    def glide_to(self, x, y):
        if not self.get_visible():
            self.move(x, y)
            self.show_all()
        else:
            self.animate(x, y, 180)

    def animate(self, tx, ty, duration):
        if self.anim:
            GLib.source_remove(self.anim)
        sx, sy = self.get_position()
        start = GLib.get_monotonic_time()

        def step():
            t = min(1.0, (GLib.get_monotonic_time() - start) / (duration * 1000.0))
            e = 1 - (1 - t) ** 3
            self.move(int(round(sx + (tx - sx) * e)), int(round(sy + (ty - sy) * e)))
            if t >= 1.0:
                self.anim = None
                return False
            return True
        self.anim = GLib.timeout_add(16, step)

    def pulse(self):
        start = GLib.get_monotonic_time()

        def step():
            t = min(1.0, (GLib.get_monotonic_time() - start) / 450000.0)
            self.pulse_phase = 1.0 - t
            self.area.queue_draw()
            return t < 1.0
        GLib.timeout_add(16, step)

    def close(self, animated=True):
        if self in self.panel.cards:
            self.panel.cards.remove(self)
        if not animated:
            self.destroy()
            self.panel.layout()
            return
        start = GLib.get_monotonic_time()

        def step():
            t = min(1.0, (GLib.get_monotonic_time() - start) / 160000.0)
            self.set_opacity(1.0 - t)
            if t >= 1.0:
                self.destroy()
                self.panel.layout()
                return False
            return True
        GLib.timeout_add(16, step)

    # Pointer

    def on_enter(self, *_):
        self.hover = True
        self.area.queue_draw()

    def on_leave(self, _w, event):
        if self.dragging:
            return
        self.hover = False
        self.hover_action = None
        self.area.queue_draw()

    def action_rects(self):
        rects = {}
        rects["close"] = (INSET + THUMB_W - 24, INSET + 4, 20, 20)
        names = ACTIONS if self.kind == "screenshot" else ["Copy", "Save"]
        bw, bh, gap = 50, 24, 6
        total = len(names) * bw + (len(names) - 1) * gap
        x = INSET + (THUMB_W - total) / 2
        for n in names:
            rects[n] = (x, INSET + THUMB_H - bh - 10, bw, bh)
            x += bw + gap
        return rects

    def hit(self, x, y):
        for name, (rx, ry, rw, rh) in self.action_rects().items():
            if rx <= x <= rx + rw and ry <= y <= ry + rh:
                return name
        return None

    def on_motion(self, _w, event):
        action = self.hit(event.x, event.y)
        if action != self.hover_action:
            self.hover_action = action
            self.area.queue_draw()
        return False

    def on_press(self, _w, event):
        if event.button == 1:
            self.press = (event.x, event.y, self.hit(event.x, event.y))
        elif event.button == 3:
            self.app_menu(event)
        return False

    def on_release(self, _w, event):
        if event.button != 1 or self.press is None or self.dragging:
            self.press = None
            return False
        _x, _y, action = self.press
        self.press = None
        self.run(action or "copy")
        return False

    def run(self, action):
        app = self.panel.app
        if action == "close":
            self.close()
        elif action in ("copy", "Copy"):
            app.copy_path(self.path, self.full_pixbuf)
        elif action == "Save":
            app.save_as(self.path)
        elif action == "Edit":
            app.open_editor(self.path)
        elif action == "Pin":
            app.pin_path(self.path)

    def app_menu(self, event):
        menu = Gtk.Menu()
        for title, cb in (("Open", lambda *_: self.panel.app.open_path(self.path)),
                          ("Show in Folder", lambda *_: self.panel.app.show_in_folder(self.path)),
                          ("Close", lambda *_: self.close())):
            item = Gtk.MenuItem(label=title)
            item.connect("activate", cb)
            menu.append(item)
        menu.show_all()
        menu.popup_at_pointer(event)

    # Drag out

    def on_drag_begin(self, widget, context):
        self.dragging = True
        if self.thumb:
            icon = imagewriter.scaled_to_fit(self.full_pixbuf, 220, 160) if self.full_pixbuf else self.thumb
            Gtk.drag_set_icon_pixbuf(context, icon, icon.get_width() // 2, icon.get_height() // 2)

    def on_drag_data_get(self, widget, context, selection, info, _time):
        if info == 1:
            selection.set_uris([GLib.filename_to_uri(self.path, None)])
        elif info == 2:
            selection.set_text(shlex.quote(self.path), -1)
        elif info == 3 and self.full_pixbuf is not None:
            selection.set_pixbuf(self.full_pixbuf)

    def on_drag_end(self, widget, context):
        self.dragging = False
        self.press = None
        if getattr(self, "_drag_failed", False):
            self._drag_failed = False
            return
        GLib.timeout_add(120, lambda: (self.close(), False)[1])

    def on_drag_failed(self, widget, context, result):
        self._drag_failed = True
        return True

    # Drawing

    def on_draw(self, area, cr):
        cr.set_operator(cairo.OPERATOR_SOURCE)
        cr.set_source_rgba(0, 0, 0, 0)
        cr.paint()
        cr.set_operator(cairo.OPERATOR_OVER)
        tx, ty, tw, th = INSET, INSET, THUMB_W, THUMB_H
        # Soft shadow
        for i in range(INSET, 0, -1):
            rounded_rect(cr, tx - i, ty - i + 2, tw + 2 * i, th + 2 * i, RADIUS + i)
            cr.set_source_rgba(0, 0, 0, 0.045)
            cr.fill()
        cr.save()
        rounded_rect(cr, tx, ty, tw, th, RADIUS)
        cr.clip()
        if self.thumb is None:
            cr.set_source_rgba(0.1, 0.1, 0.12, 0.95)
            cr.paint()
        else:
            Gdk.cairo_set_source_pixbuf(cr, self.thumb, tx, ty)
            cr.paint()
        if self.kind != "screenshot":
            cr.set_source_rgba(0, 0, 0, 0.25)
            cr.paint()
            cr.set_source_rgba(1, 1, 1, 0.95)
            cx, cy = CARD_W / 2, CARD_H / 2
            cr.move_to(cx - 10, cy - 14); cr.line_to(cx + 14, cy); cr.line_to(cx - 10, cy + 14); cr.close_path()
            cr.fill()
        cr.restore()
        # Hairline edge so a dark shot still reads as a card on a dark desktop.
        cr.set_line_width(1)
        cr.set_source_rgba(1, 1, 1, 0.14)
        rounded_rect(cr, tx + 0.5, ty + 0.5, tw - 1, th - 1, RADIUS)
        cr.stroke()
        if self.pulse_phase > 0:
            cr.set_line_width(3)
            cr.set_source_rgba(0.44, 0.38, 0.96, self.pulse_phase)
            rounded_rect(cr, tx - 1.5, ty - 1.5, tw + 3, th + 3, RADIUS + 1)
            cr.stroke()
        if clipboard.current_path() == self.path:
            self.chip(cr, "On clipboard", tx + 8, ty + 8)
        if self.hover:
            cr.set_source_rgba(0, 0, 0, 0.35)
            rounded_rect(cr, tx, ty, tw, th, RADIUS)
            cr.fill()
            for name, (rx, ry, rw, rh) in self.action_rects().items():
                active = self.hover_action == name
                if name == "close":
                    cr.arc(rx + rw / 2, ry + rh / 2, 10, 0, 6.3)
                    cr.set_source_rgba(0.1, 0.1, 0.12, 0.95 if active else 0.8)
                    cr.fill()
                    cr.set_line_width(1.6)
                    cr.set_source_rgba(1, 1, 1, 1 if active else 0.85)
                    cx, cy = rx + rw / 2, ry + rh / 2
                    cr.move_to(cx - 4, cy - 4); cr.line_to(cx + 4, cy + 4)
                    cr.move_to(cx + 4, cy - 4); cr.line_to(cx - 4, cy + 4)
                    cr.stroke()
                    continue
                rounded_rect(cr, rx, ry, rw, rh, 6)
                cr.set_source_rgba(0.44, 0.38, 0.96, 1) if active else cr.set_source_rgba(0.1, 0.1, 0.12, 0.92)
                cr.fill()
                cr.select_font_face("Inter, Cantarell, sans-serif", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_NORMAL)
                cr.set_font_size(11)
                ext = cr.text_extents(name)
                cr.set_source_rgba(1, 1, 1, 1)
                cr.move_to(rx + rw / 2 - ext.width / 2 - ext.x_bearing, ry + rh / 2 + ext.height / 2 - 0.5)
                cr.show_text(name)

    def chip(self, cr, text, x, y):
        cr.select_font_face("Inter, Cantarell, sans-serif", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)
        cr.set_font_size(9.5)
        ext = cr.text_extents(text)
        w, h = ext.width + 14, 18
        rounded_rect(cr, x, y, w, h, 9)
        cr.set_source_rgba(0.44, 0.38, 0.96, 0.95)
        cr.fill()
        cr.set_source_rgba(1, 1, 1, 1)
        cr.move_to(x + 7 - ext.x_bearing, y + h / 2 + ext.height / 2 - 0.5)
        cr.show_text(text)
