#!/usr/bin/env bash
set -euo pipefail

source_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
bin_dir="${XDG_BIN_HOME:-"$HOME/.local/bin"}"
apps_dir="${XDG_DATA_HOME:-"$HOME/.local/share"}/applications"
icons_base="${XDG_DATA_HOME:-"$HOME/.local/share"}/icons/hicolor"

echo "==> Desinstalando lanzadores de escritorio e iconos..."
rm -f -- "$bin_dir/omarchy-launch-spotify"
rm -f -- "$apps_dir/spotify.desktop"
rm -f -- "$icons_base/128x128/apps/spotify.png" "$icons_base/64x64/apps/spotify.png"

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t "$icons_base" >/dev/null 2>&1 || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$apps_dir" >/dev/null 2>&1 || true
fi

echo "==> Desinstalando plugin y runtime..."
if [[ -f "$source_root/plugin/quickshell.spotify/scripts/uninstall.sh" ]]; then
  "$source_root/plugin/quickshell.spotify/scripts/uninstall.sh"
fi

if command -v omarchy >/dev/null 2>&1; then
  omarchy menu refresh >/dev/null 2>&1 || true
  omarchy restart shell >/dev/null 2>&1 || true
fi

echo "Omarchy Spotify desinstalado correctamente."
