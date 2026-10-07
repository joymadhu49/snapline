import os
import sys

# GNOME Wayland gives clients no say over where their windows go and no global
# hotkeys. The floating cards, pins, history dock, and the frozen selection
# overlay all need exact placement, so the UI runs through Xwayland. Capture and
# recording go through the XDG portals and stay fully Wayland native.
os.environ.setdefault("GDK_BACKEND", "x11")
os.environ.setdefault("GDK_SCALE", "1")

import gi  # noqa: E402

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("GdkPixbuf", "2.0")

from snapline.app import main  # noqa: E402

sys.exit(main(sys.argv))
