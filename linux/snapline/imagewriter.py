"""Saving pixbufs with Snapline's naming scheme and folder layout."""
import os
import time

from gi.repository import GdkPixbuf

from snapline.settings import settings


def suggested_filename(ext, when=None):
    t = time.localtime(when)
    return time.strftime("Snapline %Y.%m.%d at %H.%M.%S", t) + "." + ext


def unique_path(directory, filename):
    path = os.path.join(directory, filename)
    base, ext = os.path.splitext(filename)
    n = 2
    while os.path.exists(path):
        path = os.path.join(directory, f"{base} {n}{ext}")
        n += 1
    return path


def save_pixbuf(pixbuf, path, fmt=None, quality=None):
    fmt = fmt or ("jpg" if path.lower().endswith((".jpg", ".jpeg")) else "png")
    if fmt == "jpg":
        if pixbuf.get_has_alpha():
            pixbuf = flatten(pixbuf)
        q = int(round((quality if quality is not None else settings.jpgQuality) * 100))
        pixbuf.savev(path, "jpeg", ["quality"], [str(max(1, min(100, q)))])
    else:
        pixbuf.savev(path, "png", ["compression"], ["6"])
    return path


def flatten(pixbuf, rgb=0xFFFFFFFF):
    return pixbuf.composite_color_simple(
        pixbuf.get_width(), pixbuf.get_height(), GdkPixbuf.InterpType.NEAREST, 255, 8, rgb, rgb
    )


def save_capture(pixbuf, kind="screenshot", to_library=None):
    """Writes a capture to the library (or the hidden captures folder when saving
    after capture is off) and returns the path."""
    fmt = settings.imageFormat if settings.imageFormat in ("png", "jpg") else "png"
    if to_library is None:
        to_library = settings.saveAfterCapture
    directory = settings.directory_for(kind) if to_library else settings.captures_directory
    path = unique_path(directory, suggested_filename(fmt))
    return save_pixbuf(pixbuf, path, fmt)


def load_pixbuf(path):
    try:
        return GdkPixbuf.Pixbuf.new_from_file(path)
    except Exception:
        return None


def crop(pixbuf, x, y, w, h):
    x = max(0, int(x)); y = max(0, int(y))
    w = max(1, min(int(w), pixbuf.get_width() - x))
    h = max(1, min(int(h), pixbuf.get_height() - y))
    return pixbuf.new_subpixbuf(x, y, w, h).copy()


def scaled_to_fit(pixbuf, max_w, max_h):
    w, h = pixbuf.get_width(), pixbuf.get_height()
    if w <= 0 or h <= 0:
        return pixbuf
    s = min(max_w / w, max_h / h, 1.0)
    nw, nh = max(1, int(w * s)), max(1, int(h * s))
    if (nw, nh) == (w, h):
        return pixbuf
    return pixbuf.scale_simple(nw, nh, GdkPixbuf.InterpType.BILINEAR)


def is_video(path):
    return path.lower().endswith((".mp4", ".mov", ".webm", ".mkv"))


def is_gif(path):
    return path.lower().endswith(".gif")


def scaled_to_fill(pixbuf, box_w, box_h):
    """Scales to cover the box, then centre crops, so every card is the same
    size whatever the capture's aspect ratio."""
    w, h = pixbuf.get_width(), pixbuf.get_height()
    if w <= 0 or h <= 0:
        return pixbuf
    s = max(box_w / w, box_h / h)
    sw, sh = max(box_w, int(round(w * s))), max(box_h, int(round(h * s)))
    scaled = pixbuf.scale_simple(sw, sh, GdkPixbuf.InterpType.BILINEAR)
    x, y = (sw - box_w) // 2, (sh - box_h) // 2
    return scaled.new_subpixbuf(x, y, box_w, box_h).copy()
