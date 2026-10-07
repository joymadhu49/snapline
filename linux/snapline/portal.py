"""XDG desktop portal clients: Screenshot (stills) and ScreenCast (recording).

Everything is asynchronous on the GLib main loop; results arrive through the
portal's Request.Response signal, so the UI never blocks while GNOME grabs a
frame.
"""
import os
import time
import urllib.parse

from gi.repository import Gio, GLib

PORTAL_BUS = "org.freedesktop.portal.Desktop"
PORTAL_PATH = "/org/freedesktop/portal/desktop"
_counter = [0]


class Portal:
    def __init__(self):
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        self.sender = self.bus.get_unique_name()[1:].replace(".", "_")

    def _request(self, iface, method, args, on_response, extra_options=None):
        _counter[0] += 1
        token = f"snapline{int(time.time())}_{_counter[0]}"
        handle = f"/org/freedesktop/portal/desktop/request/{self.sender}/{token}"
        state = {}

        def on_signal(conn, sender, path, sig_iface, signal, params):
            code, results = params.unpack()
            self.bus.signal_unsubscribe(state["sub"])
            on_response(code, results)

        state["sub"] = self.bus.signal_subscribe(
            PORTAL_BUS, "org.freedesktop.portal.Request", "Response", handle, None,
            Gio.DBusSignalFlags.NO_MATCH_RULE, on_signal)
        options = {"handle_token": GLib.Variant("s", token)}
        if extra_options:
            options.update(extra_options)
        variant = GLib.Variant(args[0], args[1] + (options,))
        try:
            self.bus.call_sync(PORTAL_BUS, PORTAL_PATH, iface, method, variant, None,
                               Gio.DBusCallFlags.NONE, -1, None)
        except GLib.Error as e:
            self.bus.signal_unsubscribe(state["sub"])
            on_response(2, {"error": str(e)})

    # Screenshot

    def screenshot(self, callback, interactive=False):
        """callback(path or None). Non interactive shots are silent once the
        permission store says yes; interactive opens GNOME's own picker, which
        is how Capture Window works on Wayland."""
        def done(code, results):
            uri = results.get("uri") if code == 0 else None
            if not uri:
                callback(None)
                return
            path = urllib.parse.unquote(urllib.parse.urlparse(uri).path)
            callback(path)
        self._request("org.freedesktop.portal.Screenshot", "Screenshot", ("(sa{sv})", ("",)), done,
                      {"interactive": GLib.Variant("b", interactive), "modal": GLib.Variant("b", False)})

    # ScreenCast

    def screencast_start(self, callback, cursor=True, restore_token=None):
        """Sets up a monitor screencast. callback(result or None) where result is
        {"fd", "node_id", "restore_token", "size"}."""
        _counter[0] += 1
        session_token = f"snaplinesess{_counter[0]}"
        state = {}

        def on_session(code, results):
            if code != 0:
                callback(None); return
            state["session"] = results["session_handle"]
            opts = {
                "types": GLib.Variant("u", 1),  # monitors
                "multiple": GLib.Variant("b", False),
                "cursor_mode": GLib.Variant("u", 2 if cursor else 1),
                "persist_mode": GLib.Variant("u", 2),
            }
            if restore_token:
                opts["restore_token"] = GLib.Variant("s", restore_token)
            self._request("org.freedesktop.portal.ScreenCast", "SelectSources",
                          ("(oa{sv})", (state["session"],)), on_sources, opts)

        def on_sources(code, results):
            if code != 0:
                callback(None); return
            self._request("org.freedesktop.portal.ScreenCast", "Start",
                          ("(osa{sv})", (state["session"], "")), on_start)

        def on_start(code, results):
            if code != 0:
                callback(None); return
            streams = results.get("streams") or []
            if not streams:
                callback(None); return
            node_id, props = streams[0]
            try:
                reply, fds = self.bus.call_with_unix_fd_list_sync(
                    PORTAL_BUS, PORTAL_PATH, "org.freedesktop.portal.ScreenCast", "OpenPipeWireRemote",
                    GLib.Variant("(oa{sv})", (state["session"], {})), GLib.VariantType("(h)"),
                    Gio.DBusCallFlags.NONE, -1, None, None)
                fd = fds.get(reply.unpack()[0])
            except GLib.Error:
                callback(None); return
            callback({
                "fd": fd,
                "node_id": node_id,
                "session": state["session"],
                "restore_token": results.get("restore_token"),
                "size": props.get("size"),
                "position": props.get("position"),
            })

        self._request("org.freedesktop.portal.ScreenCast", "CreateSession", ("(a{sv})", ()), on_session,
                      {"session_handle_token": GLib.Variant("s", session_token)})

    def screencast_close(self, session):
        try:
            self.bus.call_sync(PORTAL_BUS, session, "org.freedesktop.portal.Session", "Close",
                               None, None, Gio.DBusCallFlags.NONE, -1, None)
        except GLib.Error:
            pass


def grant_screenshot_permission():
    """Pre-approves silent screenshots for host apps so the first capture never
    stalls behind GNOME's consent dialog."""
    try:
        bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        for app in ("", "snapline", "io.snapline.Snapline"):
            bus.call_sync("org.freedesktop.impl.portal.PermissionStore",
                          "/org/freedesktop/impl/portal/PermissionStore",
                          "org.freedesktop.impl.portal.PermissionStore", "SetPermission",
                          GLib.Variant("(sbssas)", ("screenshot", True, "screenshot", app, ["yes"])),
                          None, Gio.DBusCallFlags.NONE, -1, None)
        return True
    except GLib.Error:
        return False


portal = Portal()
