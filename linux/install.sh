#!/usr/bin/env bash
# Installs Snapline for Linux for the current user on Ubuntu / GNOME.
set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
APP_DIR="$HOME/.local/share/snapline/app"
BIN="$HOME/.local/bin/snapline"
ICONS="$HOME/.local/share/icons/hicolor"
APPS="$HOME/.local/share/applications"

echo "→ System packages"
PKGS=(python3-gi python3-gi-cairo gir1.2-gtk-3.0 gir1.2-gdkpixbuf-2.0 gir1.2-ayatanaappindicator3-0.1
      gir1.2-gstreamer-1.0 gstreamer1.0-pipewire gstreamer1.0-plugins-good gstreamer1.0-plugins-bad
      gstreamer1.0-plugins-ugly gstreamer1.0-libav gstreamer1.0-pulseaudio
      xdg-desktop-portal xdg-desktop-portal-gnome ffmpeg tesseract-ocr tesseract-ocr-eng wl-clipboard)
MISSING=()
for p in "${PKGS[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || MISSING+=("$p"); done
if [ ${#MISSING[@]} -gt 0 ]; then
  echo "  installing: ${MISSING[*]}"
  sudo apt-get install -y --no-install-recommends "${MISSING[@]}"
else
  echo "  all present"
fi

echo "→ App files → $APP_DIR"
mkdir -p "$APP_DIR" "$HOME/.local/bin" "$ICONS/scalable/apps" "$APPS"
rsync -a --delete --exclude '__pycache__' "$HERE/snapline" "$HERE/data" "$HERE/bin" "$APP_DIR/"
install -m 755 "$HERE/bin/snapline" "$BIN"
install -m 644 "$HERE/data/snapline.svg" "$ICONS/scalable/apps/snapline.svg"
install -m 644 "$HERE/data/snapline-tray-symbolic.svg" "$ICONS/scalable/apps/snapline-tray-symbolic.svg"
install -m 644 "$HERE/data/snapline-tray-recording.svg" "$ICONS/scalable/apps/snapline-tray-recording.svg"
sed "s|^Exec=snapline|Exec=$BIN|" "$HERE/data/snapline.desktop" > "$APPS/snapline.desktop"
gtk-update-icon-cache -q -t "$ICONS" 2>/dev/null || true
update-desktop-database "$APPS" 2>/dev/null || true

echo "→ GNOME integration"
gnome-extensions enable ubuntu-appindicators@ubuntu.com 2>/dev/null || echo "  (AppIndicator extension not available; the tray icon needs it)"
"$BIN" --install-shortcuts
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "  note: add ~/.local/bin to PATH to run 'snapline' from a shell";; esac

if [ "${1:-}" = "--autostart" ]; then
  mkdir -p "$HOME/.config/autostart"
  printf '[Desktop Entry]\nType=Application\nName=Snapline\nExec=%s\nIcon=snapline\nX-GNOME-Autostart-enabled=true\nNoDisplay=true\n' "$BIN" > "$HOME/.config/autostart/snapline.desktop"
  echo "→ Autostart enabled"
fi

echo "→ Starting Snapline"
if pgrep -u "$USER" -f "python3 -m snapline" >/dev/null; then
  "$BIN" --quit || true
  sleep 1
fi
setsid -f "$BIN" >/tmp/snapline.log 2>&1
sleep 2
echo "Done. Snapline is in the top bar. Alt+Shift+4 captures an area, Alt+Shift+3 the screen, Alt+Shift+6 records."
