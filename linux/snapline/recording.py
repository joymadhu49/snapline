"""Screen recording: ScreenCast portal → PipeWire → GStreamer H.264 MP4, with
system audio and microphone, an area crop, a red border around the recorded
region, and GIF export through ffmpeg."""
import os
import shutil
import subprocess
import threading
import time

import cairo
import gi

gi.require_version("Gst", "1.0")
from gi.repository import Gdk, GLib, Gst, Gtk  # noqa: E402

from snapline import history, imagewriter  # noqa: E402
from snapline.hud import toast  # noqa: E402
from snapline.portal import portal  # noqa: E402
from snapline.settings import settings  # noqa: E402

Gst.init(None)


def _has(element):
    return Gst.ElementFactory.find(element) is not None


def _aac_encoder():
    for name in ("fdkaacenc", "avenc_aac", "voaacenc"):
        if _has(name):
            return name + " ! aacparse"
    return None


class RecordingBorder(Gtk.Window):
    """Click through red frame drawn just outside the recorded area."""

    def __init__(self, x, y, w, h):
        super().__init__(type=Gtk.WindowType.POPUP)
        self.set_app_paintable(True)
        self.set_decorated(False)
        self.set_keep_above(True)
        self.set_accept_focus(False)
        self.set_type_hint(Gdk.WindowTypeHint.NOTIFICATION)
        visual = self.get_screen().get_rgba_visual()
        if visual:
            self.set_visual(visual)
        self.pad = 3
        self.move(x - self.pad, y - self.pad)
        self.set_default_size(w + 2 * self.pad, h + 2 * self.pad)
        self.set_size_request(w + 2 * self.pad, h + 2 * self.pad)
        area = Gtk.DrawingArea()
        self.add(area)
        area.connect("draw", self.on_draw)
        self.connect("realize", lambda w: self.get_window().input_shape_combine_region(cairo.Region(), 0, 0))

    def on_draw(self, area, cr):
        cr.set_operator(cairo.OPERATOR_SOURCE)
        cr.set_source_rgba(0, 0, 0, 0)
        cr.paint()
        cr.set_operator(cairo.OPERATOR_OVER)
        w, h = area.get_allocated_width(), area.get_allocated_height()
        cr.set_line_width(2)
        cr.set_source_rgba(0.95, 0.2, 0.2, 0.95)
        cr.rectangle(1, 1, w - 2, h - 2)
        cr.stroke()


class RecordingEngine:
    def __init__(self, app):
        self.app = app
        self.recording = False
        self.pipeline = None
        self.session = None
        self.path = None
        self.started_at = 0
        self.border = None
        self.listeners = []
        self.timer = None
        self.stopping = False

    def on_state(self, cb):
        self.listeners.append(cb)

    def _notify(self):
        for cb in list(self.listeners):
            cb(self.recording, self.elapsed())

    def elapsed(self):
        return time.monotonic() - self.started_at if self.recording else 0

    # Start

    def start(self, area=None, logical_area=None):
        """area: crop in stream pixels (x, y, w, h) or None for the full
        monitor. logical_area: same rect in screen coordinates for the border."""
        if self.recording:
            return
        toast("Starting recording…")
        portal.screencast_start(lambda r: self._on_stream(r, area, logical_area),
                                cursor=settings.recordShowCursor,
                                restore_token=settings.screencastRestoreToken)

    def _on_stream(self, result, area, logical_area):
        if not result:
            toast("Recording cancelled")
            return
        if result.get("restore_token"):
            settings.screencastRestoreToken = result["restore_token"]
        self.session = result["session"]
        fps = int(settings.recordFPS or 60)
        self.path = imagewriter.unique_path(settings.directory_for("recording"), imagewriter.suggested_filename("mp4"))

        parts = [f"pipewiresrc fd={result['fd']} path={result['node_id']} do-timestamp=true keepalive-time=1000 resend-last=true",
                 "queue max-size-buffers=8 leaky=downstream", "videoconvert", "videorate",
                 f"video/x-raw,framerate={fps}/1"]
        if area:
            sw, sh = (result.get("size") or (None, None))
            px, py = (result.get("position") or (0, 0))
            x, y, w, h = area
            x -= px; y -= py
            if sw and sh:
                x = max(0, min(x, sw - 2)); y = max(0, min(y, sh - 2))
                w = max(2, min(w, sw - x)); h = max(2, min(h, sh - y))
                w -= w % 2; h -= h % 2
                right, bottom = sw - x - w, sh - y - h
                parts.append(f"videocrop left={x} top={y} right={right} bottom={bottom}")
        parts += ["videoconvert", "video/x-raw,format=I420",
                  "x264enc tune=zerolatency speed-preset=veryfast bitrate=14000 key-int-max=%d" % (fps * 2),
                  "h264parse", "queue", "mp4mux name=mux fragment-duration=1000 ! filesink location=\"%s\"" % self.path.replace('"', '\\"')]
        desc = " ! ".join(parts)

        aac = _aac_encoder()
        audio = []
        if aac and _has("pulsesrc"):
            if settings.recordSystemAudio:
                audio.append('pulsesrc device="@DEFAULT_MONITOR@" do-timestamp=true')
            if settings.recordMicrophone:
                audio.append('pulsesrc device="@DEFAULT_SOURCE@" do-timestamp=true')
        if len(audio) == 1:
            desc += f" {audio[0]} ! queue ! audioconvert ! audioresample ! {aac} ! queue ! mux."
        elif len(audio) == 2:
            desc += " audiomixer name=mix ! audioconvert ! audioresample ! %s ! queue ! mux." % aac
            for i, src in enumerate(audio):
                desc += f" {src} ! queue ! audioconvert ! audioresample ! mix."

        try:
            self.pipeline = Gst.parse_launch(desc)
        except GLib.Error as e:
            toast(f"Recording failed: {e.message}")
            portal.screencast_close(self.session)
            return
        bus = self.pipeline.get_bus()
        bus.add_signal_watch()
        bus.connect("message::error", self._on_error)
        bus.connect("message::eos", self._on_eos)
        self.pipeline.set_state(Gst.State.PLAYING)
        self.recording = True
        self.stopping = False
        self.started_at = time.monotonic()
        if logical_area:
            self.border = RecordingBorder(*logical_area)
            self.border.show_all()
        self.timer = GLib.timeout_add(1000, self._tick)
        self._notify()
        toast("Recording  ·  press the shortcut again or use the menu to stop")

    def _tick(self):
        if not self.recording:
            return False
        self._notify()
        return True

    # Stop

    def stop(self):
        if not self.recording or self.stopping:
            return
        self.stopping = True
        toast("Saving recording…")
        self.pipeline.send_event(Gst.Event.new_eos())
        GLib.timeout_add(4000, self._force_finish)

    def _force_finish(self):
        if self.pipeline is not None and self.stopping:
            self._finish()
        return False

    def _on_error(self, bus, msg):
        err, debug = msg.parse_error()
        toast(f"Recording error: {err.message}")
        self._finish(failed=True)

    def _on_eos(self, bus, msg):
        self._finish()

    def _finish(self, failed=False):
        if self.pipeline is None:
            return
        self.pipeline.set_state(Gst.State.NULL)
        self.pipeline = None
        if self.session:
            portal.screencast_close(self.session)
            self.session = None
        if self.border:
            self.border.destroy()
            self.border = None
        if self.timer:
            GLib.source_remove(self.timer)
            self.timer = None
        self.recording = False
        self.stopping = False
        self._notify()
        path = self.path
        self.path = None
        if failed or not path or not os.path.exists(path) or os.path.getsize(path) < 1024:
            if path and os.path.exists(path):
                os.remove(path)
            return
        history.add(path)
        self.app.recording_finished(path)

    # GIF

    def export_gif(self, path, callback):
        if not shutil.which("ffmpeg"):
            toast("ffmpeg is not installed")
            return
        out = imagewriter.unique_path(settings.directory_for("gif"), os.path.splitext(os.path.basename(path))[0] + ".gif")
        toast("Exporting GIF…")

        def work():
            filters = "fps=15,scale='min(960,iw)':-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=192[p];[s1][p]paletteuse=dither=bayer:bayer_scale=4"
            r = subprocess.run(["ffmpeg", "-y", "-i", path, "-vf", filters, "-loop", "0", out],
                               capture_output=True)
            GLib.idle_add(lambda: callback(out if r.returncode == 0 else None))
        threading.Thread(target=work, daemon=True).start()
