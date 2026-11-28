#!/usr/bin/env bash
# Frame a raw window capture like a launch page: window with rounded corners and a soft shadow, centred on a
# generated gradient card (no third-party art). Deterministic. Output 2560x1600, rounded outer corners.
# Usage: frame-shot.sh <window.png> <models|containers|runners|overview> <out.webp> [light|dark]
set -euo pipefail
in=$1 product=$2 out=$3 mode=${4:-dark}
W=2560 H=1600 M=70 PADX=90 PADY=100 CARDR=64
CW=$((W-2*M)) CH=$((H-2*M)) ICON=170 LIFT=60 OVERLAP=30
# Light windows are white, so the light card is deeper and more saturated for the window edge to read; dark windows sit on
# the softer set.
if [[ $mode == light ]]; then
  case $product in # top, middle, bottom of the vertical blend
    models) c=("#9a7fe8" "#e8709c" "#f2a94a") ;;
    containers) c=("#7288e6" "#3fb8a8" "#eeb55a") ;;
    runners) c=("#7f98e0" "#49b866" "#e8be4a") ;;
    *) c=("#9a7fe8" "#ee7f6c" "#f2a94a") ;;
  esac
else
  case $product in
    models) c=("#b9a6f2" "#f08fae" "#f8bd6a") ;;
    containers) c=("#a3b4f4" "#79d4c6" "#f7cf8a") ;;
    runners) c=("#b3c4ee" "#8ed79e" "#f3d57e") ;;
    *) c=("#b9a6f2" "#f39a8c" "#f8bd6a") ;;
  esac
fi
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
# Window: paint colour traffic lights (the capture is an inactive window, so they come out grey), fit inside the
# padded area, keep the native corners and add a faint top glass sheen.
magick "$in" -alpha set "$t/raw.png"
lights=(); i=0
for col in "#ff5f57" "#febc2e" "#28c840"; do
  cx=$((52 + i*46)); cy=52; r=14; i=$((i+1)) # 2x capture: lights at 26, 49 and 72 pt, 7 pt radius
  lights+=(-fill "$col" -stroke "#00000026" -strokewidth 1 -draw "circle $cx,$cy $cx,$((cy-r))")
done
magick "$t/raw.png" "${lights[@]}" "$t/raw.png"
# Shave the capture's own 2 px rim (its anti-aliased corner pixels leave a pale halo once resized), then cut one clean
# rounded corner at macOS's radius, scaled with the resize.
magick "$t/raw.png" -shave 3x3 +repage "$t/raw.png"
sx2=$(magick identify -format '%w' "$t/raw.png")
magick "$t/raw.png" -resize "$((CW-2*PADX))x$((CH-2*PADY))" "$t/win.png"
read -r ww wh < <(magick identify -format '%w %h\n' "$t/win.png")
winr=$((50*ww/sx2))
magick -size "${ww}x${wh}" xc:black -fill white -draw "roundrectangle 0,0 $((ww-1)),$((wh-1)) $winr,$winr" "$t/mask.png"
# Faint top glass sheen fading over the top 120 px, then the mask.
magick -size "${ww}x120" gradient:"#ffffff22-#ffffff00" -background none -gravity north -extent "${ww}x${wh}" "$t/sheen.png"
magick "$t/win.png" -alpha off "$t/sheen.png" -compose Over -composite "$t/mask.png" -compose CopyOpacity -composite "$t/win.png"
# One hairline on the window edge: dark on a light window, light on a dark one.
if [[ $mode == light ]]; then edge="#00000052"; else edge="#ffffff38"; fi
magick -size "${ww}x${wh}" xc:none -fill none -stroke "$edge" -strokewidth 2 \
  -draw "roundrectangle 1,1 $((ww-2)),$((wh-2)) $winr,$winr" "$t/edge.png"
magick "$t/win.png" "$t/edge.png" -compose Over -composite "$t/win.png"
# Card: smooth 3-stop vertical gradient (upscaled 1x3 strip) with a soft light bloom top-left, inset on a near-black canvas.
magick -size 1x3 "xc:${c[0]}" -fill "${c[1]}" -draw "point 0,1" -fill "${c[2]}" -draw "point 0,2" \
  -filter Triangle -resize "${CW}x${CH}!" "$t/bg.png"
magick "$t/bg.png" \( -size ${CW}x${CH} radial-gradient:"#ffffff55-#ffffff00" \) -compose Over -composite \
  \( -size ${CW}x${CH} radial-gradient:"#ffffff00-#00000026" \) -compose Over -composite "$t/bg.png"
# Two-layer shadow like a macOS window: tight contact + wide soft drop. The window sits a little high so the icon fits below.
magick "$t/win.png" -background black -shadow 55x90+0+60 "$t/sh1.png"
magick "$t/win.png" -background black -shadow 26x12+0+6 "$t/sh2.png"
magick "$t/bg.png" \
  "$t/sh1.png" -gravity center -geometry +0-$LIFT -compose Over -composite \
  "$t/sh2.png" -gravity center -geometry +0-$LIFT -compose Over -composite \
  "$t/win.png" -gravity center -geometry +0-$LIFT -compose Over -composite \
  \( -size ${CW}x${CH} xc:black -fill white -draw "roundrectangle 0,0 $((CW-1)),$((CH-1)) $CARDR,$CARDR" \) \
  -alpha off -compose CopyOpacity -composite "$t/card.png"
# The app icon hangs from the window's bottom edge, centred. It overlaps the window by OVERLAP only, so it covers no text.
icns="$(dirname "$0")/../build/Noodle.app/Contents/Resources/AppIcon.icns"
sips -s format png "$icns" --out "$t/icon-full.png" >/dev/null
magick "$t/icon-full.png" -resize "${ICON}x${ICON}" "$t/icon.png"
magick "$t/icon.png" -background black -shadow 50x24+0+14 "$t/icon-sh.png"
winbottom=$(( (CH + wh) / 2 - LIFT ))
magick -size ${W}x${H} xc:"#0b0b0c" \
  "$t/card.png" -gravity center -compose Over -composite \
  "$t/icon-sh.png" -gravity north -geometry +0+$((M + winbottom - OVERLAP)) -compose Over -composite \
  "$t/icon.png" -gravity north -geometry +0+$((M + winbottom - OVERLAP)) -compose Over -composite "$t/out.png"
cwebp -quiet -q 90 -alpha_q 100 "$t/out.png" -o "$out"
