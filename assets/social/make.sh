#!/bin/sh
# Remakes the PNGs (white on transparent, 64x64) from src/*.svg; run from this folder.
for f in src/*.svg; do magick -background none -density 600 "$f" -resize 64x64 "$(basename "$f" .svg).png"; done
