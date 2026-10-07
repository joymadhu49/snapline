#!/bin/zsh
# Renders the README art in docs/ from the HTML sources in docs/art/.
#
#   hero-{light,dark}.png    hero.html, at 2x on a transparent background
#   bento-{light,dark}.png   bento.html, at 2x on a transparent background
#   demo-{light,dark}.gif    hero.html#demo, one frame per render(t), on GitHub's page colour
#   Brand/dmg-background.tiff  dmg.html, the installer window background, 1x and 2x
#
# Needs Google Chrome and Node 22 or later. The GIF is joined by ImageIO, so no ffmpeg.
set -euo pipefail
cd "${0:A:h}/.."
FRAMES="$(mktemp -d)"
trap 'rm -rf "$FRAMES"' EXIT

render() { # name width height
  for scheme in light dark; do
    TRANSPARENT=1 SCALE=2 COLOR_SCHEME=$scheme \
      node Scripts/readme_shot.mjs "file://$PWD/docs/art/$1.html" "docs/$1-$scheme.png" $2 $3 &
  done
}

render hero 1200 640
# The installer background: light only (Finder labels are dark), 1x and 2x joined into one TIFF.
COLOR_SCHEME=light SCALE=1 node Scripts/readme_shot.mjs "file://$PWD/docs/art/dmg.html" "$FRAMES/dmg.png" 640 400 &
COLOR_SCHEME=light SCALE=2 node Scripts/readme_shot.mjs "file://$PWD/docs/art/dmg.html" "$FRAMES/dmg@2x.png" 640 400 &
render bento 1200 1000
for scheme in light dark; do
  node Scripts/readme_frames.mjs "file://$PWD/docs/art/hero.html#demo" "$FRAMES/$scheme" 960 310 20 $scheme &
done
wait
for scheme in light dark; do
  swift Scripts/make_gif.swift "$FRAMES/$scheme" "docs/demo-$scheme.gif" 20
done

tiffutil -cathidpicheck "$FRAMES/dmg.png" "$FRAMES/dmg@2x.png" -out Brand/dmg-background.tiff
rm -f docs/*.png.json
cp Brand/snapline-icon-512.png docs/icon.png
ls -lh docs/*.png docs/*.gif
