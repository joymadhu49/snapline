"""OCR through tesseract; result lands on the clipboard."""
import shutil
import subprocess
import tempfile
import os


def available():
    return shutil.which("tesseract") is not None


def recognize(pixbuf):
    if not available():
        return None
    fd, path = tempfile.mkstemp(prefix="snapline-ocr-", suffix=".png")
    os.close(fd)
    try:
        # Upscale small crops: tesseract wants roughly 30px tall glyphs.
        w, h = pixbuf.get_width(), pixbuf.get_height()
        if h < 400:
            from gi.repository import GdkPixbuf
            s = min(3, max(1, 400 // max(1, h)))
            if s > 1:
                pixbuf = pixbuf.scale_simple(w * s, h * s, GdkPixbuf.InterpType.BILINEAR)
        pixbuf.savev(path, "png", [], [])
        out = subprocess.run(["tesseract", path, "stdout", "--psm", "6"], capture_output=True, text=True)
        text = out.stdout.strip()
        return text or None
    finally:
        try:
            os.remove(path)
        except OSError:
            pass
