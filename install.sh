#!/usr/bin/env bash
set -euo pipefail

source_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
section="left"
link_mode=0
setup_args=()

usage() {
  cat <<'HELP'
Uso: ./install.sh [OPCIONES]

Instalador integral de Omarchy Spotify (versión privada personalizada).

Opciones:
  --section SECCION     Posición del widget en la barra (left, center, right). Por defecto: left
  --link                Crea un enlace simbólico en lugar de copiar los archivos del plugin.
  --install-spotifyd    Instala spotifyd como demonio fallback si está disponible en pacman.
  --skip-backend-build  Omite la compilación del backend Rust (usa binario preexistente).
  -h, --help            Muestra esta ayuda.

HELP
}

while (( $# > 0 )); do
  case $1 in
    --section)
      [[ $# -ge 2 ]] || { echo "install.sh: --section requiere un valor" >&2; exit 2; }
      section=$2
      shift 2
      ;;
    --link)
      link_mode=1
      shift
      ;;
    --install-spotifyd)
      setup_args+=(--install-spotifyd)
      shift
      ;;
    --skip-backend-build)
      setup_args+=(--skip-backend-build)
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "install.sh: opción desconocida: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ $section =~ ^(left|center|right)$ ]] || {
  echo "install.sh: la sección debe ser left, center o right" >&2
  exit 2
}

command -v omarchy >/dev/null 2>&1 || {
  echo "install.sh: se requiere Omarchy instalado en el sistema." >&2
  exit 1
}

echo "==> Validando plugin..."
omarchy plugin validate "$source_root/plugin/quickshell.spotify"

echo "==> Configurando backend de reproducción y servicios systemd..."
"$source_root/plugin/quickshell.spotify/scripts/setup.sh" "${setup_args[@]}"

config_root="${XDG_CONFIG_HOME:-"$HOME/.config"}"
plugins_root="$config_root/omarchy/plugins"
target_plugin="$plugins_root/quickshell.spotify"
install -d -m 700 -- "$plugins_root"

echo "==> Instalando plugin en $target_plugin..."
if (( link_mode )); then
  if [[ -L $target_plugin && $(readlink -f -- "$target_plugin") == "$source_root/plugin/quickshell.spotify" ]]; then
    echo "    El enlace simbólico ya apunta a este repositorio."
  else
    rm -rf -- "$target_plugin"
    ln -s -- "$source_root/plugin/quickshell.spotify" "$target_plugin"
    echo "    Enlazado: $target_plugin -> $source_root/plugin/quickshell.spotify"
  fi
else
  if [[ -L $target_plugin ]]; then
    rm -f -- "$target_plugin"
  fi
  install -d -m 755 -- "$target_plugin"
  cp -aT "$source_root/plugin/quickshell.spotify" "$target_plugin"
  echo "    Archivos copiados a $target_plugin"
fi

echo "==> Instalando lanzador de escritorio e integración en el menú..."
bin_dir="${XDG_BIN_HOME:-"$HOME/.local/bin"}"
apps_dir="${XDG_DATA_HOME:-"$HOME/.local/share"}/applications"
icons_base="${XDG_DATA_HOME:-"$HOME/.local/share"}/icons/hicolor"

install -d -m 755 -- "$bin_dir"
install -d -m 755 -- "$apps_dir"

install -m 755 -- "$source_root/desktop/omarchy-launch-spotify" "$bin_dir/omarchy-launch-spotify"

# Instalar .desktop adaptando la ruta absoluta del binario por si ~/.local/bin no estuviera en PATH del entorno gráfico
sed "s|^Exec=.*|Exec=$bin_dir/omarchy-launch-spotify|" "$source_root/desktop/spotify.desktop" > "$apps_dir/spotify.desktop"
chmod 644 "$apps_dir/spotify.desktop"

# Instalar iconos
install -d -m 755 -- "$icons_base/128x128/apps" "$icons_base/64x64/apps"
if [[ -f "$source_root/desktop/icons/128x128/spotify.png" ]]; then
  install -m 644 -- "$source_root/desktop/icons/128x128/spotify.png" "$icons_base/128x128/apps/spotify.png"
fi
if [[ -f "$source_root/desktop/icons/64x64/spotify.png" ]]; then
  install -m 644 -- "$source_root/desktop/icons/64x64/spotify.png" "$icons_base/64x64/apps/spotify.png"
fi

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t "$icons_base" >/dev/null 2>&1 || true
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$apps_dir" >/dev/null 2>&1 || true
fi

echo "==> Desactivando sugerencia de instalación del cliente oficial en el menú de Omarchy..."
menu_ext_dir="$config_root/omarchy/extensions"
menu_ext_file="$menu_ext_dir/omarchy-menu.jsonc"
install -d -m 755 -- "$menu_ext_dir"

if [[ ! -f "$menu_ext_file" ]]; then
  cat <<'JSONC' > "$menu_ext_file"
{
  "install.service.spotify": {
    "when": "false"
  }
}
JSONC
else
  if ! grep -q '"install\.service\.spotify"' "$menu_ext_file"; then
    python3 -c "
import sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()
last_brace = content.rfind('}')
if last_brace != -1:
    snippet = '  \"install.service.spotify\": {\n    \"when\": \"false\"\n  },\n'
    new_content = content[:last_brace] + snippet + content[last_brace:]
    with open(path, 'w', encoding='utf-8') as f:
        f.write(new_content)
" "$menu_ext_file" 2>/dev/null || true
  fi
fi

echo "==> Registrando y activando plugin en Omarchy..."
omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

discovered=0
for (( attempt = 0; attempt < 40; attempt++ )); do
  if omarchy plugin list --json 2>/dev/null | jq -e 'any(.[]; .id == "quickshell.spotify")' >/dev/null 2>&1; then
    discovered=1
    break
  fi
  sleep 0.05
done

if (( discovered )); then
  omarchy plugin enable quickshell.spotify --section "$section" >/dev/null 2>&1 || true
  echo "    Plugin activado en sección '$section'."
else
  echo "    Aviso: Omarchy aún no detectó quickshell.spotify. Reinicia el shell para cargar." >&2
fi

if command -v omarchy >/dev/null 2>&1; then
  omarchy menu refresh >/dev/null 2>&1 || true
  omarchy restart shell >/dev/null 2>&1 || true
fi

echo ""
echo "================================================================"
echo "  Omarchy Spotify instalado y listo para usar."
echo "================================================================"
echo "  - Abre el reproductor desde el menú de apps ('Spotify') o con Super+Shift+M."
echo "  - La última canción escuchada se precarga al iniciar y se puede reanudar con Play."
echo "  - En frío puedes saltar directamente con Siguiente o Anterior."
echo "================================================================"
