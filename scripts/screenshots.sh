#!/bin/bash
# Regenerate the README images with sample data (never real job names or paths).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build.sh" >/dev/null
B="$ROOT/build/JarvisSwitch.app/Contents/MacOS/JarvisSwitch"
D="$ROOT/docs"
mkdir -p "$D"
"$B" --render "$D/hero.png" --hero
"$B" --render "$D/panel-dark.png" --demo --dark
"$B" --render "$D/panel-light.png" --demo
"$B" --render "$D/panel-details-dark.png" --demo --dark --details
"$B" --render "$D/panel-details-light.png" --demo --details
"$B" --render "$D/states-dark.png" --states --dark
"$B" --render "$D/states-light.png" --states
"$B" --render "$D/settings-dark.png" --demo --dark --settings general
"$B" --render "$D/settings-light.png" --demo --settings general
rm -f "$D/panel-details.png" "$D/settings.png"
ls -1 "$D"
