#!/bin/zsh
# Renders the README art in docs/ from the HTML sources in docs/art/.
# Each piece is drawn once and captured twice, light and dark, at 2x on a transparent background,
# so it sits cleanly on GitHub's page in either theme. Needs Google Chrome and Node 22 or later.
set -euo pipefail
cd "${0:A:h}/.."

render() { # name width height
  for scheme in light dark; do
    TRANSPARENT=1 SCALE=2 COLOR_SCHEME=$scheme \
      node Scripts/readme_shot.mjs "file://$PWD/docs/art/$1.html" "docs/$1-$scheme.png" $2 $3 &
  done
}

render hero 1600 1080
render bento 1600 1458
wait
rm -f docs/*.png.json
cp Brand/snapline-icon-512.png docs/icon.png
ls -lh docs/*.png
