"""Annotation editor: arrow, line, rectangle, ellipse, freehand, highlighter,
text, numbered counters, pixelate redact, crop, undo/redo, and background
beautify. Done writes the edits over the capture's file and floats it back onto
the overlay, so the annotated version is what every later copy hands out."""
import copy
import math
import os
import shlex

import cairo
import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GdkPixbuf, Gtk, GLib

from snapline import imagewriter
from snapline.util import pixbuf_to_surface, rounded_rect, surface_to_pixbuf

TOOLS = [
    ("select", "Select", "cursor-arrow", "V"),
    ("arrow", "Arrow", "go-up-symbolic", "A"),
    ("line", "Line", "list-remove-symbolic", "L"),
    ("rect", "Rectangle", "checkbox-symbolic", "R"),
    ("ellipse", "Ellipse", "media-record-symbolic", "O"),
    ("freehand", "Freehand", "edit-symbolic", "P"),
    ("highlight", "Highlighter", "format-text-underline-symbolic", "H"),
    ("text", "Text", "font-x-generic-symbolic", "T"),
    ("counter", "Counter", "view-list-ordered-symbolic", "N"),
    ("redact", "Pixelate", "view-grid-symbolic", "X"),
    ("crop", "Crop", "edit-cut-symbolic", "C"),
]

PRESETS = [
    ("None", None),
    ("Violet", ((0.44, 0.38, 0.96), (0.22, 0.65, 0.94))),
    ("Sunset", ((0.98, 0.45, 0.35), (0.98, 0.72, 0.30))),
    ("Ocean", ((0.10, 0.30, 0.55), (0.10, 0.70, 0.75))),
    ("Forest", ((0.10, 0.45, 0.30), (0.55, 0.80, 0.40))),
    ("Graphite", ((0.12, 0.12, 0.14), (0.30, 0.30, 0.34))),
    ("Snow", ((0.96, 0.96, 0.97), (0.86, 0.87, 0.90))),
]

CSS = b"""
.snapline-editor headerbar { padding: 2px 6px; }
.snapline-editor .tool { padding: 4px 6px; min-width: 24px; }
.snapline-editor .done { background-image: none; background-color: #6F60F6; color: white; border: none; font-weight: 600; }
.snapline-editor .done:hover { background-color: #7d6ff7; }
.snapline-editor .drag-chip { border-radius: 14px; padding: 2px 10px; }
"""


class Annotation:
    def __init__(self, kind, color, width, points=None, text=None, number=None):
        self.kind = kind
        self.color = color
        self.width = width
        self.points = points or []
        self.text = text
        self.number = number

    def bounds(self):
        xs = [p[0] for p in self.points]
        ys = [p[1] for p in self.points]
        if not xs:
            return (0, 0, 0, 0)
        pad = self.width * 2 + (16 if self.kind == "counter" else 0)
        if self.kind == "text":
            return (xs[0] - 4, ys[0] - self.width * 3 - 4, max(60, len(self.text or "") * self.width * 1.6), self.width * 3 + 8)
        return (min(xs) - pad, min(ys) - pad, max(xs) - min(xs) + pad * 2, max(ys) - min(ys) + pad * 2)

    def rect(self):
        (x0, y0), (x1, y1) = self.points[0], self.points[-1]
        return (min(x0, x1), min(y0, y1), abs(x1 - x0), abs(y1 - y0))

    def move(self, dx, dy):
        self.points = [(x + dx, y + dy) for x, y in self.points]


class Model:
    def __init__(self, pixbuf):
        self.base = pixbuf
        self.surface = pixbuf_to_surface(pixbuf)
        self.annotations = []
        self.undo_stack = []
        self.redo_stack = []
        self.preset = 0
        self.padding = 48
        self.radius = 14
        self.shadow = True
        self.counter = 0

    def snapshot(self):
        self.undo_stack.append((copy.deepcopy(self.annotations), self.base, self.counter))
        self.redo_stack.clear()
        if len(self.undo_stack) > 60:
            self.undo_stack.pop(0)

    def _restore(self, state):
        self.annotations, self.base, self.counter = copy.deepcopy(state[0]), state[1], state[2]
        self.surface = pixbuf_to_surface(self.base)

    def undo(self):
        if not self.undo_stack:
            return
        self.redo_stack.append((copy.deepcopy(self.annotations), self.base, self.counter))
        self._restore(self.undo_stack.pop())

    def redo(self):
        if not self.redo_stack:
            return
        self.undo_stack.append((copy.deepcopy(self.annotations), self.base, self.counter))
        self._restore(self.redo_stack.pop())

    def crop(self, x, y, w, h):
        self.snapshot()
        self.base = imagewriter.crop(self.base, x, y, w, h)
        self.surface = pixbuf_to_surface(self.base)
        for a in self.annotations:
            a.move(-x, -y)

    # Rendering

    def output_size(self):
        w, h = self.base.get_width(), self.base.get_height()
        if self.preset:
            return w + 2 * self.padding, h + 2 * self.padding
        return w, h

    def render(self, cr, scale=1.0):
        """Draws the full result at the origin of cr; used by the canvas and the
        exporter alike so both agree pixel for pixel."""
        w, h = self.base.get_width(), self.base.get_height()
        off = 0
        if self.preset:
            off = self.padding
            ow, oh = self.output_size()
            c0, c1 = PRESETS[self.preset][1]
            grad = cairo.LinearGradient(0, 0, ow, oh)
            grad.add_color_stop_rgb(0, *c0)
            grad.add_color_stop_rgb(1, *c1)
            cr.set_source(grad)
            cr.rectangle(0, 0, ow, oh)
            cr.fill()
            if self.shadow:
                for i in range(18, 0, -1):
                    rounded_rect(cr, off - i * 0.6, off + i * 0.9, w + i * 1.2, h + i * 0.6, self.radius + i * 0.5)
                    cr.set_source_rgba(0, 0, 0, 0.022)
                    cr.fill()
            cr.save()
            rounded_rect(cr, off, off, w, h, self.radius)
            cr.clip()
        cr.save()
        cr.translate(off, off)
        cr.set_source_surface(self.surface, 0, 0)
        cr.paint()
        for a in self.annotations:
            self.draw_annotation(cr, a)
        cr.restore()
        if self.preset:
            cr.restore()

    def draw_annotation(self, cr, a):
        r, g, b, alpha = a.color
        cr.set_source_rgba(r, g, b, alpha)
        cr.set_line_width(a.width)
        cr.set_line_cap(cairo.LINE_CAP_ROUND)
        cr.set_line_join(cairo.LINE_JOIN_ROUND)
        if a.kind in ("line", "arrow"):
            (x0, y0), (x1, y1) = a.points[0], a.points[-1]
            cr.move_to(x0, y0); cr.line_to(x1, y1); cr.stroke()
            if a.kind == "arrow":
                ang = math.atan2(y1 - y0, x1 - x0)
                size = max(10, a.width * 4)
                cr.move_to(x1, y1)
                cr.line_to(x1 - size * math.cos(ang - 0.5), y1 - size * math.sin(ang - 0.5))
                cr.line_to(x1 - size * math.cos(ang + 0.5), y1 - size * math.sin(ang + 0.5))
                cr.close_path(); cr.fill()
        elif a.kind == "rect":
            x, y, w, h = a.rect()
            rounded_rect(cr, x, y, w, h, min(6, a.width))
            cr.stroke()
        elif a.kind == "ellipse":
            x, y, w, h = a.rect()
            if w > 0 and h > 0:
                cr.save(); cr.translate(x + w / 2, y + h / 2); cr.scale(w / 2, h / 2)
                cr.arc(0, 0, 1, 0, 2 * math.pi); cr.restore(); cr.stroke()
        elif a.kind == "freehand":
            if len(a.points) > 1:
                cr.move_to(*a.points[0])
                for p in a.points[1:]:
                    cr.line_to(*p)
                cr.stroke()
        elif a.kind == "highlight":
            x, y, w, h = a.rect()
            cr.set_source_rgba(r, g, b, 0.38)
            cr.rectangle(x, y, w, h); cr.fill()
        elif a.kind == "text":
            cr.select_font_face("Inter, Cantarell, sans-serif", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)
            cr.set_font_size(a.width * 3 + 8)
            x, y = a.points[0]
            cr.move_to(x, y)
            cr.text_path(a.text or "")
            cr.set_source_rgba(0, 0, 0, 0.55)
            cr.set_line_width(max(2, a.width * 0.6))
            cr.stroke_preserve()
            cr.set_source_rgba(r, g, b, alpha)
            cr.fill()
        elif a.kind == "counter":
            x, y = a.points[0]
            rad = a.width * 3 + 8
            cr.arc(x, y, rad, 0, 2 * math.pi); cr.fill()
            cr.set_source_rgba(1, 1, 1, 1)
            cr.select_font_face("Inter, Cantarell, sans-serif", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)
            cr.set_font_size(rad * 1.1)
            t = str(a.number)
            ext = cr.text_extents(t)
            cr.move_to(x - ext.width / 2 - ext.x_bearing, y + ext.height / 2)
            cr.show_text(t)
        elif a.kind == "redact":
            x, y, w, h = a.rect()
            if w >= 2 and h >= 2:
                block = max(6, int(min(w, h) / 10))
                sw, sh = max(1, int(w / block)), max(1, int(h / block))
                small = cairo.ImageSurface(cairo.FORMAT_ARGB32, sw, sh)
                scr = cairo.Context(small)
                scr.scale(sw / w, sh / h)
                scr.set_source_surface(self.surface, -x, -y)
                scr.get_source().set_filter(cairo.FILTER_GOOD)
                scr.paint()
                cr.save()
                cr.rectangle(x, y, w, h); cr.clip()
                cr.translate(x, y); cr.scale(w / sw, h / sh)
                cr.set_source_surface(small, 0, 0)
                cr.get_source().set_filter(cairo.FILTER_NEAREST)
                cr.paint()
                cr.restore()

    def export_pixbuf(self):
        ow, oh = self.output_size()
        surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, ow, oh)
        cr = cairo.Context(surface)
        self.render(cr)
        surface.flush()
        return surface_to_pixbuf(surface)


class EditorWindow(Gtk.Window):
    def __init__(self, app, path, pixbuf=None):
        super().__init__(title=f"Snapline — {os.path.basename(path)}")
        self.app = app
        self.path = path
        pixbuf = pixbuf or imagewriter.load_pixbuf(path)
        self.model = Model(pixbuf)
        self.tool = "arrow"
        self.color = (0.95, 0.25, 0.25, 1.0)
        self.stroke = 4
        self.current = None
        self.selected = None
        self.drag_last = None
        self.zoom = 1.0
        self.get_style_context().add_class("snapline-editor")
        provider = Gtk.CssProvider()
        provider.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(self.get_screen(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        w, h = pixbuf.get_width(), pixbuf.get_height()
        display = Gdk.Display.get_default()
        geo = display.get_primary_monitor().get_geometry() if display.get_primary_monitor() else display.get_monitor(0).get_geometry()
        self.set_default_size(min(geo.width - 120, w + 80), min(geo.height - 140, h + 120))
        self.build_header()
        self.scroller = Gtk.ScrolledWindow()
        self.canvas = Gtk.DrawingArea()
        self.canvas.add_events(Gdk.EventMask.BUTTON_PRESS_MASK | Gdk.EventMask.BUTTON_RELEASE_MASK
                               | Gdk.EventMask.POINTER_MOTION_MASK | Gdk.EventMask.SCROLL_MASK)
        self.canvas.connect("draw", self.on_draw)
        self.canvas.connect("button-press-event", self.on_press)
        self.canvas.connect("button-release-event", self.on_release)
        self.canvas.connect("motion-notify-event", self.on_motion)
        self.scroller.add(self.canvas)
        self.add(self.scroller)
        self.connect("key-press-event", self.on_key)
        self.connect("size-allocate", lambda *_: self.fit_zoom())
        self.show_all()
        self.present()

    # Header

    def build_header(self):
        hb = Gtk.HeaderBar()
        hb.set_show_close_button(True)
        hb.props.title = os.path.basename(self.path)
        self.set_titlebar(hb)
        tools = Gtk.Box(spacing=0)
        tools.get_style_context().add_class("linked")
        self.tool_buttons = {}
        group = None
        for key, title, icon, accel in TOOLS:
            b = Gtk.RadioButton.new_from_widget(group) if group else Gtk.RadioButton()
            group = group or b
            b.set_mode(False)
            b.get_style_context().add_class("tool")
            b.set_image(Gtk.Image.new_from_icon_name(icon, Gtk.IconSize.MENU))
            b.set_always_show_image(True)
            b.set_label(title if key in ("select",) else "")
            b.set_tooltip_text(f"{title} ({accel})")
            b.connect("toggled", lambda btn, k=key: btn.get_active() and self.set_tool(k))
            tools.pack_start(b, False, False, 0)
            self.tool_buttons[key] = b
        self.tool_buttons["arrow"].set_active(True)
        hb.pack_start(tools)

        self.color_button = Gtk.ColorButton()
        rgba = Gdk.RGBA(*self.color)
        self.color_button.set_rgba(rgba)
        self.color_button.set_tooltip_text("Color")
        self.color_button.connect("color-set", self.on_color)
        hb.pack_start(self.color_button)
        self.stroke_spin = Gtk.SpinButton.new_with_range(1, 24, 1)
        self.stroke_spin.set_value(self.stroke)
        self.stroke_spin.set_tooltip_text("Stroke width / text size")
        self.stroke_spin.connect("value-changed", lambda s: setattr(self, "stroke", int(s.get_value())))
        hb.pack_start(self.stroke_spin)

        undo = Gtk.Button.new_from_icon_name("edit-undo-symbolic", Gtk.IconSize.MENU)
        undo.set_tooltip_text("Undo (Ctrl+Z)")
        undo.connect("clicked", lambda *_: self.undo())
        redo = Gtk.Button.new_from_icon_name("edit-redo-symbolic", Gtk.IconSize.MENU)
        redo.set_tooltip_text("Redo (Ctrl+Shift+Z)")
        redo.connect("clicked", lambda *_: self.redo())
        ur = Gtk.Box(); ur.get_style_context().add_class("linked")
        ur.pack_start(undo, False, False, 0); ur.pack_start(redo, False, False, 0)
        hb.pack_start(ur)

        beautify = Gtk.MenuButton()
        beautify.set_label("Background")
        beautify.set_popover(self.build_beautify())
        hb.pack_start(beautify)

        done_box = Gtk.Box(); done_box.get_style_context().add_class("linked")
        done = Gtk.Button(label="Done")
        done.get_style_context().add_class("done")
        done.set_tooltip_text("Write the edits over the capture, copy it, and float it on the overlay (Ctrl+Return)")
        done.connect("clicked", lambda *_: self.done())
        more = Gtk.MenuButton()
        more.get_style_context().add_class("done")
        menu = Gtk.Menu()
        for title, cb in (("Save", self.save), ("Save As…", self.save_as)):
            item = Gtk.MenuItem(label=title)
            item.connect("activate", lambda *_, c=cb: c())
            menu.append(item)
        menu.show_all()
        more.set_popup(menu)
        done_box.pack_start(done, False, False, 0); done_box.pack_start(more, False, False, 0)
        hb.pack_end(done_box)

        drag = Gtk.Button(label="Drag")
        drag.get_style_context().add_class("drag-chip")
        drag.set_image(Gtk.Image.new_from_icon_name("insert-image-symbolic", Gtk.IconSize.MENU))
        drag.set_always_show_image(True)
        drag.set_tooltip_text("Drag the edited image into Finder, Slack, a terminal, or an agent prompt")
        targets = Gtk.TargetList.new([])
        targets.add_uri_targets(1); targets.add_text_targets(2); targets.add_image_targets(3, True)
        drag.drag_source_set(Gdk.ModifierType.BUTTON1_MASK, [], Gdk.DragAction.COPY)
        drag.drag_source_set_target_list(targets)
        drag.connect("drag-begin", self.on_drag_begin)
        drag.connect("drag-data-get", self.on_drag_data_get)
        hb.pack_end(drag)

    def build_beautify(self):
        pop = Gtk.Popover()
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, margin=12)
        grid = Gtk.FlowBox()
        grid.set_max_children_per_line(4)
        grid.set_selection_mode(Gtk.SelectionMode.NONE)
        for i, (name, colors) in enumerate(PRESETS):
            b = Gtk.Button(label=name)
            b.connect("clicked", lambda _b, idx=i: self.set_preset(idx))
            grid.add(b)
        box.pack_start(grid, False, False, 0)
        for label, attr, lo, hi in (("Padding", "padding", 0, 200), ("Corner radius", "radius", 0, 60)):
            row = Gtk.Box(spacing=8)
            row.pack_start(Gtk.Label(label=label, xalign=0), False, False, 0)
            scale = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, lo, hi, 1)
            scale.set_value(getattr(self.model, attr))
            scale.set_size_request(180, -1)
            scale.set_draw_value(False)
            scale.connect("value-changed", lambda s, a=attr: (setattr(self.model, a, int(s.get_value())), self.refresh()))
            row.pack_start(scale, True, True, 0)
            box.pack_start(row, False, False, 0)
        row = Gtk.Box(spacing=8)
        row.pack_start(Gtk.Label(label="Shadow", xalign=0), True, True, 0)
        sw = Gtk.Switch(); sw.set_active(self.model.shadow)
        sw.connect("notify::active", lambda s, _p: (setattr(self.model, "shadow", s.get_active()), self.refresh()))
        row.pack_end(sw, False, False, 0)
        box.pack_start(row, False, False, 0)
        box.show_all()
        pop.add(box)
        return pop

    def set_preset(self, idx):
        self.model.preset = idx
        self.refresh()

    def set_tool(self, key):
        self.tool = key
        self.selected = None
        cursor = {"select": "default", "text": "text", "crop": "crosshair"}.get(key, "crosshair")
        canvas = getattr(self, "canvas", None)
        if canvas is not None and canvas.get_window():
            canvas.get_window().set_cursor(Gdk.Cursor.new_from_name(self.get_display(), cursor))

    def on_color(self, button):
        c = button.get_rgba()
        self.color = (c.red, c.green, c.blue, c.alpha)

    # Geometry

    def fit_zoom(self):
        ow, oh = self.model.output_size()
        aw = self.scroller.get_allocated_width() - 24
        ah = self.scroller.get_allocated_height() - 24
        if aw <= 0 or ah <= 0:
            return
        self.zoom = min(1.0, aw / ow, ah / oh)
        self.canvas.set_size_request(int(ow * self.zoom) + 24, int(oh * self.zoom) + 24)

    def refresh(self):
        self.fit_zoom()
        self.canvas.queue_draw()

    def origin(self):
        ow, oh = self.model.output_size()
        aw, ah = self.canvas.get_allocated_width(), self.canvas.get_allocated_height()
        return max(12, (aw - ow * self.zoom) / 2), max(12, (ah - oh * self.zoom) / 2)

    def to_image(self, x, y):
        ox, oy = self.origin()
        off = self.model.padding if self.model.preset else 0
        return ((x - ox) / self.zoom - off, (y - oy) / self.zoom - off)

    # Drawing

    def on_draw(self, area, cr):
        cr.set_source_rgb(0.11, 0.11, 0.13)
        cr.paint()
        ox, oy = self.origin()
        cr.save()
        cr.translate(ox, oy)
        cr.scale(self.zoom, self.zoom)
        self.model.render(cr)
        off = self.model.padding if self.model.preset else 0
        cr.translate(off, off)
        if self.current:
            self.model.draw_annotation(cr, self.current)
        if self.crop_rect:
            x, y, w, h = self.crop_rect
            cr.set_source_rgba(0, 0, 0, 0.4)
            cr.set_fill_rule(cairo.FILL_RULE_EVEN_ODD)
            bw, bh = self.model.base.get_width(), self.model.base.get_height()
            cr.rectangle(0, 0, bw, bh); cr.rectangle(x, y, w, h); cr.fill()
            cr.set_fill_rule(cairo.FILL_RULE_WINDING)
            cr.set_source_rgba(1, 1, 1, 0.9); cr.set_line_width(1 / self.zoom)
            cr.rectangle(x, y, w, h); cr.stroke()
        if self.selected is not None:
            x, y, w, h = self.selected.bounds()
            cr.set_source_rgba(0.44, 0.38, 0.96, 0.9)
            cr.set_line_width(1.5 / self.zoom)
            cr.set_dash([4 / self.zoom, 3 / self.zoom])
            cr.rectangle(x, y, w, h); cr.stroke()
        cr.restore()

    crop_rect = None

    # Input

    def on_press(self, _w, event):
        if event.button != 1:
            return False
        x, y = self.to_image(event.x, event.y)
        t = self.tool
        if t == "select":
            self.selected = self.hit(x, y)
            self.drag_last = (x, y)
            if self.selected:
                self.model.snapshot()
        elif t == "text":
            self.prompt_text(x, y, event)
        elif t == "counter":
            self.model.snapshot()
            self.model.counter += 1
            self.model.annotations.append(Annotation("counter", self.color, self.stroke, [(x, y)], number=self.model.counter))
        elif t == "crop":
            self.crop_rect = (x, y, 0, 0)
            self.drag_last = (x, y)
        else:
            self.current = Annotation(t, self.color if t != "highlight" else (1.0, 0.9, 0.2, 1.0), self.stroke, [(x, y), (x, y)])
        self.canvas.queue_draw()
        return True

    def on_motion(self, _w, event):
        if not (event.state & Gdk.ModifierType.BUTTON1_MASK):
            return False
        x, y = self.to_image(event.x, event.y)
        if self.current:
            if self.current.kind == "freehand":
                self.current.points.append((x, y))
            else:
                if event.state & Gdk.ModifierType.SHIFT_MASK and self.current.kind in ("rect", "ellipse", "highlight", "redact"):
                    x0, y0 = self.current.points[0]
                    side = max(abs(x - x0), abs(y - y0))
                    x, y = x0 + math.copysign(side, x - x0), y0 + math.copysign(side, y - y0)
                self.current.points[-1] = (x, y)
        elif self.tool == "select" and self.selected and self.drag_last:
            self.selected.move(x - self.drag_last[0], y - self.drag_last[1])
            self.drag_last = (x, y)
        elif self.tool == "crop" and self.crop_rect and self.drag_last:
            x0, y0 = self.drag_last
            self.crop_rect = (min(x0, x), min(y0, y), abs(x - x0), abs(y - y0))
        self.canvas.queue_draw()
        return True

    def on_release(self, _w, event):
        if event.button != 1:
            return False
        if self.current:
            a = self.current
            self.current = None
            (x0, y0), (x1, y1) = a.points[0], a.points[-1]
            if a.kind == "freehand" or abs(x1 - x0) > 2 or abs(y1 - y0) > 2:
                self.model.snapshot()
                self.model.annotations.append(a)
        elif self.tool == "crop" and self.crop_rect:
            x, y, w, h = self.crop_rect
            self.crop_rect = None
            bw, bh = self.model.base.get_width(), self.model.base.get_height()
            x, y = max(0, x), max(0, y)
            w, h = min(w, bw - x), min(h, bh - y)
            if w > 4 and h > 4:
                self.model.crop(int(x), int(y), int(w), int(h))
                self.fit_zoom()
        self.drag_last = None
        self.canvas.queue_draw()
        return True

    def hit(self, x, y):
        for a in reversed(self.model.annotations):
            bx, by, bw, bh = a.bounds()
            if bx <= x <= bx + bw and by <= y <= by + bh:
                return a
        return None

    def prompt_text(self, x, y, event):
        pop = Gtk.Popover.new(self.canvas)
        rect = Gdk.Rectangle(); rect.x, rect.y, rect.width, rect.height = int(event.x), int(event.y), 1, 1
        pop.set_pointing_to(rect)
        entry = Gtk.Entry(margin=8, width_chars=28)
        entry.set_placeholder_text("Type text, press Return")

        def commit(*_):
            text = entry.get_text().strip()
            if text:
                self.model.snapshot()
                self.model.annotations.append(Annotation("text", self.color, self.stroke, [(x, y)], text=text))
                self.canvas.queue_draw()
            pop.popdown()
        entry.connect("activate", commit)
        pop.add(entry)
        entry.show()
        pop.popup()
        entry.grab_focus()

    def on_key(self, _w, event):
        ctrl = event.state & Gdk.ModifierType.CONTROL_MASK
        shift = event.state & Gdk.ModifierType.SHIFT_MASK
        key = Gdk.keyval_to_lower(event.keyval)
        if ctrl and key == Gdk.KEY_z:
            self.redo() if shift else self.undo()
        elif ctrl and key == Gdk.KEY_y:
            self.redo()
        elif ctrl and key in (Gdk.KEY_Return, Gdk.KEY_KP_Enter):
            self.done()
        elif ctrl and key == Gdk.KEY_s:
            self.save_as() if shift else self.save()
        elif key in (Gdk.KEY_Delete, Gdk.KEY_BackSpace) and self.selected is not None:
            self.model.snapshot()
            self.model.annotations.remove(self.selected)
            self.selected = None
            self.canvas.queue_draw()
        elif key == Gdk.KEY_Escape:
            if self.selected is not None:
                self.selected = None
                self.canvas.queue_draw()
            else:
                self.close()
        elif not ctrl and self.get_focus() is None or isinstance(self.get_focus(), (Gtk.DrawingArea, Gtk.RadioButton, Gtk.Button)):
            for k, _t, _i, accel in TOOLS:
                if key == Gdk.keyval_from_name(accel.lower()):
                    self.tool_buttons[k].set_active(True)
                    return True
            return False
        return True

    def undo(self):
        self.model.undo(); self.selected = None; self.refresh()

    def redo(self):
        self.model.redo(); self.selected = None; self.refresh()

    # Output

    def write(self, path):
        pixbuf = self.model.export_pixbuf()
        imagewriter.save_pixbuf(pixbuf, path)
        return pixbuf

    def save(self):
        pixbuf = self.write(self.path)
        self.app.editor_saved(self.path, pixbuf, float_card=False)

    def save_as(self):
        dialog = Gtk.FileChooserDialog(title="Save As", parent=self, action=Gtk.FileChooserAction.SAVE)
        dialog.add_buttons(Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL, Gtk.STOCK_SAVE, Gtk.ResponseType.OK)
        dialog.set_do_overwrite_confirmation(True)
        dialog.set_current_folder(os.path.dirname(self.path))
        dialog.set_current_name(os.path.basename(self.path))
        if dialog.run() == Gtk.ResponseType.OK:
            target = dialog.get_filename()
            pixbuf = self.write(target)
            self.app.editor_saved(target, pixbuf, float_card=True)
        dialog.destroy()

    def done(self):
        pixbuf = self.write(self.path)
        self.app.editor_saved(self.path, pixbuf, float_card=True)
        self.close()

    def on_drag_begin(self, widget, context):
        self._drag_pixbuf = self.write(self.path)
        Gtk.drag_set_icon_pixbuf(context, imagewriter.scaled_to_fit(self._drag_pixbuf, 200, 140), 100, 70)

    def on_drag_data_get(self, widget, context, selection, info, _time):
        if info == 1:
            selection.set_uris([GLib.filename_to_uri(self.path, None)])
        elif info == 2:
            selection.set_text(shlex.quote(self.path), -1)
        elif info == 3:
            selection.set_pixbuf(self._drag_pixbuf)
