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

Consulta [docs/estado-tecnico.md](docs/estado-tecnico.md) para el inventario
de cambios, las verificaciones y el plan de continuación.

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
