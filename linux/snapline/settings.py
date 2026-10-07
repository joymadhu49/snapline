"""JSON backed app settings, mirroring the macOS SettingsStore keys."""
import json
import os
import threading

CONFIG_DIR = os.path.expanduser("~/.config/snapline")
SETTINGS_PATH = os.path.join(CONFIG_DIR, "settings.json")
DATA_DIR = os.path.expanduser("~/.local/share/snapline")

ACTIONS = [
    ("captureArea", "Capture Area", "<Alt><Shift>4", "--capture-area"),
    ("captureFullscreen", "Capture Fullscreen", "<Alt><Shift>3", "--capture-fullscreen"),
    ("captureWindow", "Capture Window", "<Alt><Shift>5", "--capture-window"),
    ("capturePreviousArea", "Capture Previous Area", "<Alt><Shift>8", "--capture-previous-area"),
    ("captureText", "Capture Text", "<Alt><Shift>7", "--capture-text"),
    ("toggleRecording", "Record Screen", "<Alt><Shift>6", "--toggle-recording"),
    ("pinFromClipboard", "Pin from Clipboard", None, "--pin-from-clipboard"),
    ("showHistory", "Capture History", "<Alt><Shift>9", "--show-history"),
]
ACTION_TITLES = {a[0]: a[1] for a in ACTIONS}
ACTION_FLAGS = {a[0]: a[3] for a in ACTIONS}
DEFAULT_SHORTCUTS = {a[0]: a[2] for a in ACTIONS if a[2]}

FOLDER_NAMES = {"screenshot": "Screenshots", "recording": "Recordings", "gif": "GIFs"}

DEFAULTS = {
    "launchAtLogin": False,
    "playSounds": True,
    "showQuickAccess": True,
    "overlayMaxCards": 0,
    "copyAfterCapture": True,
    "saveAfterCapture": True,
    "openEditorAfterCapture": False,
    "saveDirectoryPath": "~/Pictures/Snapline",
    "imageFormat": "png",
    "jpgQuality": 0.9,
    "downscaleHiDPI": False,
    "windowShadow": True,
    "selfTimerSeconds": 5,
    "recordFPS": 60,
    "recordSystemAudio": True,
    "recordMicrophone": False,
    "recordCountIn": True,
    "recordShowCursor": True,
    "shortcuts": dict(DEFAULT_SHORTCUTS),
    "lastArea": None,
    "screencastRestoreToken": None,
    "captureHistory": [],
}


class Settings:
    def __init__(self):
        self._lock = threading.Lock()
        self._data = dict(DEFAULTS)
        self._data["shortcuts"] = dict(DEFAULT_SHORTCUTS)
        self._listeners = []
        self.load()

    def load(self):
        try:
            with open(SETTINGS_PATH) as f:
                stored = json.load(f)
            for k, v in stored.items():
                self._data[k] = v
        except (OSError, ValueError):
            pass

    def save(self):
        os.makedirs(CONFIG_DIR, exist_ok=True)
        tmp = SETTINGS_PATH + ".tmp"
        with self._lock:
            with open(tmp, "w") as f:
                json.dump(self._data, f, indent=2)
            os.replace(tmp, SETTINGS_PATH)

    def get(self, key):
        return self._data.get(key, DEFAULTS.get(key))

    def set(self, key, value):
        self._data[key] = value
        self.save()
        for cb in list(self._listeners):
            cb(key, value)

    def on_change(self, cb):
        self._listeners.append(cb)

    def __getattr__(self, key):
        if key.startswith("_"):
            raise AttributeError(key)
        if key in DEFAULTS:
            return self.get(key)
        raise AttributeError(key)

    def __setattr__(self, key, value):
        if key.startswith("_"):
            object.__setattr__(self, key, value)
        elif key in DEFAULTS:
            self.set(key, value)
        else:
            object.__setattr__(self, key, value)

    # Folders

    @property
    def save_directory(self):
        path = os.path.expanduser(self.get("saveDirectoryPath") or "~/Pictures/Snapline")
        try:
            os.makedirs(path, exist_ok=True)
            return path
        except OSError:
            return os.path.expanduser("~/Pictures")

    def directory_for(self, kind):
        path = os.path.join(self.save_directory, FOLDER_NAMES[kind])
        os.makedirs(path, exist_ok=True)
        return path

    @property
    def captures_directory(self):
        """Every capture is written somewhere, even with saving off, so a
        pasted or dragged path always resolves."""
        path = os.path.join(DATA_DIR, "Captures")
        os.makedirs(path, exist_ok=True)
        return path

    # Shortcuts

    def shortcut_for(self, action):
        return (self.get("shortcuts") or {}).get(action)

    def set_shortcut(self, action, accel):
        shortcuts = dict(self.get("shortcuts") or {})
        if accel:
            for key, existing in list(shortcuts.items()):
                if existing == accel and key != action:
                    del shortcuts[key]
            shortcuts[action] = accel
        else:
            shortcuts.pop(action, None)
        self.set("shortcuts", shortcuts)

    def reset_shortcuts(self):
        self.set("shortcuts", dict(DEFAULT_SHORTCUTS))


settings = Settings()
