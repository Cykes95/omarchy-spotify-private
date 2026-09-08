# Omarchy Spotify — privado

Proyecto local para mantener y personalizar el cliente de Spotify integrado en
la barra de Omarchy. No contiene credenciales, tokens ni datos de sesión.

## Estado actual

- Plugin instalado localmente: `~/.config/omarchy/plugins/quickshell.spotify`.
- El cliente oficial de Spotify está desinstalado.
- El backend nativo `omarchy-spotify-backend` sustituye al fallback `spotifyd`.
- `Super+Shift+M` abre el minirreproductor.
- El backend solo puede arrancar bajo demanda y queda inactivo tras apagarlo.
- El icono de la barra se oculta mientras el backend está apagado.
- Hay controles **Apagar** en el minirreproductor y en el reproductor completo.
- El catálogo se conserva localmente para que la biblioteca y las listas
  habituales aparezcan al instante al reabrir el cliente.
- Precarga al iniciar la última canción reproducida, su carátula, álbum y lista de contexto,
  permitiendo reanudar la reproducción con solo pulsar Play sin arrancar previamente el daemon.
- Navegación en frío: los botones Siguiente y Anterior cambian de pista y arrancan la reproducción
  directamente en la posición correspondiente del contexto guardado, sin requerir reproducir antes.
- El transporte de Spotify admite hasta tres lecturas simultáneas y reduce
  temporalmente a una cuando Spotify aplica rate limiting.
- Integrado en el menú de aplicaciones del sistema (`~/.local/share/applications/spotify.desktop`)
  mediante el lanzador `omarchy-launch-spotify` (`omarchy-shell shell summon quickshell.spotify '{}'`).
- La sugerencia de instalar el cliente oficial en el menú de Omarchy está desactivada
  en `~/.config/omarchy/extensions/omarchy-menu.jsonc`.

Consulta [docs/estado-tecnico.md](docs/estado-tecnico.md) para el inventario
de cambios, las verificaciones y el plan de continuación. El código activo se
mantiene en `~/.config/omarchy/plugins/quickshell.spotify/`; este proyecto
documenta la personalización privada y no replica credenciales ni cachés.

## Alcance

Este repositorio es de uso personal y privado. Documenta cambios locales sin
incluir credenciales, datos de sesión ni información de la cuenta de Spotify.
El objetivo siguiente es mantener la traducción al español solo en la copia
local del plugin.

## Inicio rápido

```bash
# Abrir el minirreproductor
Super+Shift+M

# Verificar que el backend está apagado
systemctl --user is-active omarchy-spotify.service

# Revisar cambios locales del plugin
git -C ~/.config/omarchy/plugins/quickshell.spotify diff
```
