"""Capture History: a compact dock across the top of the screen that scrolls
sideways through every recent capture."""
import shlex

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gtk, GLib

from snapline import clipboard, history, imagewriter
from snapline.util import monitor_at_pointer, monitor_geometry

DOCK_H = 156
THUMB_W, THUMB_H = 176, 110

CSS = b"""
.snapline-dock { background-color: rgba(18,18,22,0.96); border-bottom: 1px solid rgba(255,255,255,0.08); }
.snapline-dock label { color: #e8e8ec; }
.snapline-dock .title { font-weight: 600; font-size: 13px; color: #9a9aa6; }
.snapline-tile { background-color: rgba(255,255,255,0.04); border-radius: 8px; border: 1px solid rgba(255,255,255,0.07); }
.snapline-tile:hover { background-color: rgba(255,255,255,0.09); border-color: rgba(112,96,246,0.8); }
.snapline-tile button { min-height: 20px; min-width: 20px; padding: 1px 8px; font-size: 11px; border-radius: 5px;
  background-image: none; background-color: rgba(20,20,24,0.92); color: #fff; border: none; box-shadow: none; }
.snapline-tile button:hover { background-color: #6F60F6; }
.snapline-tile .close { padding: 0; border-radius: 10px; }
.snapline-dock .empty { color: #6f6f7a; font-size: 13px; }
"""


class HistoryPanel(Gtk.Window):
    _instance = None

    @classmethod
    def toggle(cls, app):
        if cls._instance is not None:
            cls._instance.close()
        else:
            cls._instance = cls(app)

    def __init__(self, app):
        super().__init__(type=Gtk.WindowType.TOPLEVEL)
        self.app = app
        HistoryPanel._instance = self
        self.set_title("Snapline History")
        self.set_decorated(False)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_keep_above(True)
        self.set_type_hint(Gdk.WindowTypeHint.DOCK)
        mx, my, mw, mh = monitor_geometry(monitor_at_pointer())
        self.set_default_size(mw, DOCK_H)
        self.set_size_request(mw, DOCK_H)
        self.move(mx, my)
        provider = Gtk.CssProvider()
        provider.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(self.get_screen(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        outer.get_style_context().add_class("snapline-dock")
        self.add(outer)
        header = Gtk.Box(spacing=8, margin_start=16, margin_end=16, margin_top=8)
        title = Gtk.Label(label="Capture History")
        title.get_style_context().add_class("title")
        header.pack_start(title, False, False, 0)
        hint = Gtk.Label(label="click to copy · drag out · right click for more · Esc closes")
        hint.get_style_context().add_class("empty")
        header.pack_start(hint, False, False, 0)
        clear = Gtk.Button(label="Clear")
        clear.set_relief(Gtk.ReliefStyle.NONE)
        clear.connect("clicked", lambda *_: (history.clear(), self.rebuild()))
        header.pack_end(clear, False, False, 0)
        outer.pack_start(header, False, False, 0)

        self.scroller = Gtk.ScrolledWindow()
        self.scroller.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.NEVER)
        self.scroller.set_propagate_natural_height(True)
        self.strip = Gtk.Box(spacing=10, margin_start=16, margin_end=16, margin_top=6, margin_bottom=8)
        self.scroller.add(self.strip)
        outer.pack_start(self.scroller, True, True, 0)
        self.scroller.connect("scroll-event", self.on_scroll)

        self.connect("key-press-event", self.on_key)
        self.connect("focus-out-event", lambda *_: GLib.timeout_add(150, self._focus_lost) and False)
        self.connect("delete-event", lambda *_: self.close() or True)
        history.on_change(self._history_changed)
        self.rebuild()
        self.show_all()
        self.present()

    def _history_changed(self):
        if HistoryPanel._instance is self:
            self.rebuild()
        return False

    def _focus_lost(self):
        if HistoryPanel._instance is self and not self.has_toplevel_focus():
            if not any(w.get_visible() and isinstance(w, Gtk.Menu) for w in Gtk.Window.list_toplevels()):
                self.close()
        return False

    def on_scroll(self, _w, event):
        adj = self.scroller.get_hadjustment()
        if event.direction == Gdk.ScrollDirection.UP:
            adj.set_value(adj.get_value() - 120)
        elif event.direction == Gdk.ScrollDirection.DOWN:
            adj.set_value(adj.get_value() + 120)
        elif event.direction == Gdk.ScrollDirection.SMOOTH:
            adj.set_value(adj.get_value() + (event.delta_y + event.delta_x) * 60)
        return True

    def on_key(self, _w, event):
        if event.keyval == Gdk.KEY_Escape:
            self.close()
            return True
        return False

    def close(self):
        HistoryPanel._instance = None
        self.destroy()

    def rebuild(self):
        for child in self.strip.get_children():
            self.strip.remove(child)
        items = history.items()
        if not items:
            label = Gtk.Label(label="No captures yet")
            label.get_style_context().add_class("empty")
            self.strip.pack_start(label, False, False, 0)
        for path in items:
            self.strip.pack_start(self.tile(path), False, False, 0)
        self.strip.show_all()

    def tile(self, path):
        frame = Gtk.EventBox()
        frame.get_style_context().add_class("snapline-tile")
        frame.set_size_request(THUMB_W + 8, THUMB_H + 8)
        overlay = Gtk.Overlay()
        frame.add(overlay)
        pixbuf = None if imagewriter.is_video(path) else imagewriter.load_pixbuf(path)
        if pixbuf is None:
            thumb = self.app.video_thumbnail(path)
            pixbuf = thumb if thumb is not None else None
        image = Gtk.Image()
        if pixbuf is not None:
            image.set_from_pixbuf(imagewriter.scaled_to_fit(pixbuf, THUMB_W, THUMB_H))
        else:
            image.set_from_icon_name("video-x-generic-symbolic", Gtk.IconSize.DIALOG)
        image.set_margin_top(4); image.set_margin_bottom(4); image.set_margin_start(4); image.set_margin_end(4)
        overlay.add(image)

        actions = Gtk.Box(spacing=4, halign=Gtk.Align.CENTER, valign=Gtk.Align.END, margin_bottom=8)
        actions.set_no_show_all(True)
        for title, cb in (("Restore", lambda *_: self.app.restore_to_overlay(path)),
                          ("Edit", lambda *_: self.app.open_editor(path)),
                          ("Copy", lambda *_: self.app.copy_path(path))):
            if title == "Edit" and imagewriter.is_video(path):
                continue
            b = Gtk.Button(label=title)
            b.connect("clicked", cb)
            b.show()
            actions.pack_start(b, False, False, 0)
        overlay.add_overlay(actions)
        close = Gtk.Button()
        close.get_style_context().add_class("close")
        close.set_image(Gtk.Image.new_from_icon_name("window-close-symbolic", Gtk.IconSize.MENU))
        close.set_halign(Gtk.Align.END); close.set_valign(Gtk.Align.START)
        close.set_margin_top(6); close.set_margin_end(6)
        close.set_no_show_all(True)
        close.connect("clicked", lambda *_: (history.delete(path), self.rebuild()))
        overlay.add_overlay(close)

        frame.add_events(Gdk.EventMask.ENTER_NOTIFY_MASK | Gdk.EventMask.LEAVE_NOTIFY_MASK | Gdk.EventMask.BUTTON_PRESS_MASK)
        frame.connect("enter-notify-event", lambda *_: (actions.show(), close.show()) and False)
        frame.connect("leave-notify-event", lambda w, e: (e.detail != Gdk.NotifyType.INFERIOR and (actions.hide(), close.hide())) and False)
        frame.connect("button-press-event", lambda w, e: self.on_tile_press(e, path, pixbuf))
        frame.connect("button-release-event", lambda w, e: self.on_tile_release(e, path, pixbuf))
        targets = Gtk.TargetList.new([])
        targets.add_uri_targets(1); targets.add_text_targets(2); targets.add_image_targets(3, True)
        frame.drag_source_set(Gdk.ModifierType.BUTTON1_MASK, [], Gdk.DragAction.COPY)
        frame.drag_source_set_target_list(targets)
        frame.connect("drag-data-get", lambda w, c, sel, info, t: self.drag_get(sel, info, path, pixbuf))
        frame.connect("drag-begin", lambda w, c: (Gtk.drag_set_icon_pixbuf(c, imagewriter.scaled_to_fit(pixbuf, 160, 100), 80, 50) if pixbuf else None))
        frame.connect("drag-begin", lambda w, c: setattr(self, "_dragged", True))
        frame.set_tooltip_text(path)
        return frame

    def drag_get(self, selection, info, path, pixbuf):
        if info == 1:
            selection.set_uris([GLib.filename_to_uri(path, None)])
        elif info == 2:
            selection.set_text(shlex.quote(path), -1)
        elif info == 3 and pixbuf is not None:
            selection.set_pixbuf(pixbuf)

    def on_tile_press(self, event, path, pixbuf):
        self._dragged = False
        if event.button == 3:
            menu = Gtk.Menu()
            entries = [("Open", lambda *_: self.app.open_path(path)),
                       ("Show in Folder", lambda *_: self.app.show_in_folder(path))]
            if not imagewriter.is_video(path):
                entries.insert(0, ("Pin", lambda *_: self.app.pin_path(path)))
            for title, cb in entries:
                item = Gtk.MenuItem(label=title)
                item.connect("activate", cb)
                menu.append(item)
            menu.show_all()
            menu.popup_at_pointer(event)
            return True
        return False

    def on_tile_release(self, event, path, pixbuf):
        if event.button == 1 and not getattr(self, "_dragged", False):
            self.app.copy_path(path, pixbuf)
        return False
