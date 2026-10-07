"""CaptureCoordinator: every capture flow from shortcut to delivered file."""
import hashlib
import os
import shutil
import subprocess
import threading

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import GLib, Gtk

from snapline import clipboard, history, imagewriter, ocr, util
from snapline.hud import Countdown, toast
from snapline.overlay import SelectionSession
from snapline.pin import pin
from snapline.portal import portal
from snapline.quickaccess import QuickAccessPanel
from snapline.recording import RecordingEngine
from snapline.settings import DATA_DIR, settings


class Coordinator:
    def __init__(self):
        self.quick = QuickAccessPanel(self)
        self.recorder = RecordingEngine(self)
        self.session = None
        self.busy = False
        self.editors = []

    # Frozen frame

    def freeze(self, callback):
        """Grabs the screen before any overlay exists, so notifications,
        popovers, and video frames stay exactly as they were."""
        if self.busy:
            return
        self.busy = True

        def loaded(path):
            self.busy = False
            if not path:
                toast("Screen capture is not available. Check Settings > Privacy > Screenshots.")
                return
            pixbuf = imagewriter.load_pixbuf(path)
            try:
                os.remove(path)
            except OSError:
                pass
            if pixbuf is None:
                toast("Could not read the captured frame")
                return
            callback(pixbuf)
        portal.screenshot(loaded)

    def scale_for(self, pixbuf):
        _x, _y, w, _h = util.screen_bounds()
        return pixbuf.get_width() / w if w else 1.0

    def select(self, pixbuf, mode, callback):
        if self.session and not self.session.finished:
            self.session.finish(None)
        self.session = SelectionSession(pixbuf, mode, callback, self.scale_for(pixbuf))

    # Flows

    def capture_area(self):
        def on_frame(pixbuf):
            def on_result(result):
                if not result:
                    return
                _kind, rect = result
                settings.lastArea = list(rect)
                self.deliver(imagewriter.crop(pixbuf, *rect))
            self.select(pixbuf, "area", on_result)
        self.freeze(on_frame)

    def capture_fullscreen(self):
        monitor = util.monitor_at_pointer()
        mx, my, mw, mh = util.monitor_geometry(monitor)

        def on_frame(pixbuf):
            s = self.scale_for(pixbuf)
            self.deliver(imagewriter.crop(pixbuf, mx * s, my * s, mw * s, mh * s))
        self.freeze(on_frame)

    def capture_window(self):
        """Wayland never tells clients where other windows are, so this opens
        GNOME's own picker in window mode; its shots keep the soft shadow."""
        if self.busy:
            return
        self.busy = True

        def loaded(path):
            self.busy = False
            if not path:
                return
            pixbuf = imagewriter.load_pixbuf(path)
            try:
                os.remove(path)
            except OSError:
                pass
            if pixbuf is not None:
                self.deliver(pixbuf)
        portal.screenshot(loaded, interactive=True)

    def capture_previous_area(self):
        rect = settings.lastArea
        if not rect:
            self.capture_area()
            return

        def on_frame(pixbuf):
            self.deliver(imagewriter.crop(pixbuf, *rect))
        self.freeze(on_frame)

    def timed_capture(self, seconds=None):
        seconds = seconds or settings.selfTimerSeconds or 5

        def on_frame(pixbuf):
            def on_result(result):
                if not result:
                    return
                _kind, rect = result
                settings.lastArea = list(rect)

                def fire():
                    self.freeze(lambda fresh: self.deliver(imagewriter.crop(fresh, *rect)))
                Countdown(seconds, fire)
            self.select(pixbuf, "timed", on_result)
        self.freeze(on_frame)

    def capture_text(self):
        if not ocr.available():
            toast("Install tesseract-ocr to capture text")
            return

        def on_frame(pixbuf):
            def on_result(result):
                if not result:
                    return
                crop = imagewriter.crop(pixbuf, *result[1])

                def work():
                    text = ocr.recognize(crop)
                    GLib.idle_add(lambda: (self._ocr_done(text), False)[1])
                threading.Thread(target=work, daemon=True).start()
            self.select(pixbuf, "text", on_result)
        self.freeze(on_frame)

    def _ocr_done(self, text):
        if not text:
            toast("No text found")
            return
        clipboard.copy_text(text)
        lines = text.count("\n") + 1
        toast(f"Copied {lines} line{'s' if lines != 1 else ''} of text")

    def toggle_recording(self):
        if self.recorder.recording:
            self.recorder.stop()
            return
        if self.busy:
            return

        def on_frame(pixbuf):
            s = self.scale_for(pixbuf)

            def on_result(result):
                if not result:
                    return
                kind, rect = result
                area = None if kind == "full" else rect
                logical = tuple(int(v / s) for v in rect)
                mon = util.monitor_at_pointer()

                def go():
                    self.recorder.start(area, logical)
                if settings.recordCountIn:
                    Countdown(3, go, monitor=mon)
                else:
                    go()
            self.select(pixbuf, "record", on_result)
        self.freeze(on_frame)

    def stop_recording(self):
        if self.recorder.recording:
            self.recorder.stop()

    def recording_finished(self, path):
        util.play_sound("complete")
        thumb = self.video_thumbnail(path)
        if settings.copyAfterCapture:
            clipboard.copy_capture(path, None)
        if settings.showQuickAccess:
            self.quick.show(path, None, kind="recording", thumbnail=thumb)
        toast("Recording saved")

    def export_gif(self, path):
        def done(out):
            if not out:
                toast("GIF export failed")
                return
            history.add(out)
            self.quick.show(out, imagewriter.load_pixbuf(out), kind="gif")
            toast("GIF saved")
        self.recorder.export_gif(path, done)

    # Delivery

    def deliver(self, pixbuf, kind="screenshot"):
        if settings.downscaleHiDPI:
            s = self.scale_for(pixbuf) if kind == "screenshot" else 1.0
            if s > 1.01:
                pixbuf = pixbuf.scale_simple(int(pixbuf.get_width() / s), int(pixbuf.get_height() / s), 2)
        path = imagewriter.save_capture(pixbuf, kind)
        history.add(path)
        if settings.copyAfterCapture:
            clipboard.copy_capture(path, pixbuf)
        util.play_sound("capture")
        if settings.showQuickAccess:
            self.quick.show(path, pixbuf, kind)
        else:
            toast("Captured" + ("  ·  copied" if settings.copyAfterCapture else ""))
        if settings.openEditorAfterCapture:
            self.open_editor(path, pixbuf)
        return path

    # Actions used by cards, history, editor, tray

    def copy_path(self, path, pixbuf=None):
        clipboard.copy_capture(path, pixbuf)
        toast("Copied")

    def save_as(self, path):
        dialog = Gtk.FileChooserDialog(title="Save As", action=Gtk.FileChooserAction.SAVE)
        dialog.add_buttons(Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL, Gtk.STOCK_SAVE, Gtk.ResponseType.OK)
        dialog.set_do_overwrite_confirmation(True)
        dialog.set_current_folder(settings.save_directory)
        dialog.set_current_name(os.path.basename(path))
        dialog.set_keep_above(True)
        if dialog.run() == Gtk.ResponseType.OK:
            target = dialog.get_filename()
            if target != path:
                shutil.copy2(path, target)
                history.add(target)
                toast("Saved")
        dialog.destroy()

    def open_editor(self, path, pixbuf=None):
        if imagewriter.is_video(path):
            self.open_path(path)
            return
        from snapline.editor import EditorWindow
        win = EditorWindow(self, path, pixbuf)
        self.editors.append(win)
        win.connect("destroy", lambda w: w in self.editors and self.editors.remove(w))

    def editor_saved(self, path, pixbuf, float_card=True):
        history.add(path)
        clipboard.copy_capture(path, pixbuf)
        if float_card and settings.showQuickAccess:
            card = self.quick.find(path)
            if card:
                card.refresh(pixbuf)
                card.pulse()
            else:
                self.quick.show(path, pixbuf)
        toast("Saved and copied")

    def pin_path(self, path):
        pixbuf = imagewriter.load_pixbuf(path)
        if pixbuf is None:
            toast("Only images can be pinned")
            return
        pin(pixbuf, path)

    def pin_from_clipboard(self):
        pixbuf = clipboard.get_image()
        if pixbuf is None:
            toast("No image on the clipboard")
            return
        pin(pixbuf)

    def show_history(self):
        from snapline.historypanel import HistoryPanel
        HistoryPanel.toggle(self)

    def restore_to_overlay(self, path):
        if imagewriter.is_video(path):
            self.quick.show(path, None, kind="recording", thumbnail=self.video_thumbnail(path))
        else:
            self.quick.show(path, imagewriter.load_pixbuf(path))

    def open_path(self, path):
        util.open_path(path)

    def show_in_folder(self, path):
        util.show_in_folder(path)

    def open_folder(self):
        util.open_path(settings.save_directory)

    def video_thumbnail(self, path):
        if not shutil.which("ffmpeg"):
            return None
        thumbs = os.path.join(DATA_DIR, "Thumbnails")
        os.makedirs(thumbs, exist_ok=True)
        key = hashlib.sha1((path + str(os.path.getmtime(path) if os.path.exists(path) else 0)).encode()).hexdigest()[:16]
        out = os.path.join(thumbs, key + ".png")
        if not os.path.exists(out):
            subprocess.run(["ffmpeg", "-y", "-ss", "0.5", "-i", path, "-frames:v", "1", "-vf", "scale=640:-1", out],
                           capture_output=True)
        return imagewriter.load_pixbuf(out) if os.path.exists(out) else None

    # Desktop icons (Ubuntu's desktop icons extension)

    DING = "ding@rastersoft.com"

    def desktop_hidden(self):
        try:
            out = subprocess.run(["gnome-extensions", "info", self.DING], capture_output=True, text=True).stdout
            return "Enabled: No" in out
        except OSError:
            return False

    def toggle_desktop_icons(self):
        cmd = "enable" if self.desktop_hidden() else "disable"
        subprocess.run(["gnome-extensions", cmd, self.DING], capture_output=True)
