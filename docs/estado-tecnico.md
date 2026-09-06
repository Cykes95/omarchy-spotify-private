# Estado técnico y bitácora

Actualizado: 2026-09-06

## Arquitectura elegida

El plugin instalado es `quickshell.spotify` (Omarchy-Spotify / QuickshellSpotify).
Su interfaz es QML dentro de Quickshell y el audio local usa el backend Rust
`omarchy-spotify-backend`, supervisado por una unidad de systemd de usuario.

El paquete `spotify` oficial se eliminó. `spotifyd` puede permanecer instalado
como fallback del plugin, pero su servicio está inactivo y no se usa mientras
el backend nativo esté disponible.

Rutas importantes:

| Elemento | Ruta |
| --- | --- |
| Código local del plugin | `~/.config/omarchy/plugins/quickshell.spotify/` |
| Configuración de la barra | `~/.config/omarchy/shell.json` |
| Atajo de Hyprland | `~/.config/hypr/bindings.lua` |
| Backend compilado | `~/.local/lib/omarchy-spotify/omarchy-spotify-backend` |
| Unidad nativa | `~/.config/systemd/user/omarchy-spotify.service` |
| Unidad fallback | `~/.config/systemd/user/omarchy-spotifyd.service` |

## Cambios realizados

### Limpieza e instalación

1. Se eliminó el cliente oficial `spotify` y restos del reproductor anterior.
2. Se instaló y activó `quickshell.spotify` en la zona izquierda de la barra.
3. Se configuró `Super+Shift+M` para abrir el minirreproductor de Quickshell,
   reemplazando el lanzador antiguo de Spotify.
4. Se realizó el login de la API y la autorización independiente del backend
   local. Las credenciales permanecen fuera de este proyecto.
5. Se compiló e instaló el backend Rust nativo porque el fallback `spotifyd`
   sufría lentitud y cambios de pista poco fiables.

### Rendimiento y selección de canciones

Spotify devolvía respuestas HTTP 429 durante cargas concurrentes de la UI. El
planificador local usa ahora hasta tres lecturas en vuelo y mantiene una pausa
mínima entre sus arranques. Si Spotify responde `429`, baja temporalmente a
una sola solicitud y respeta `Retry-After`. Las acciones interactivas tienen
prioridad sobre las precargas; además, el backend local evita que una segunda
selección de canción espere una consulta web pendiente.

Archivos modificados:

- `Api.js`: límite adaptable de tres lecturas y pausa mínima de 1250 ms.
- `SpotifyApi.qml`: cola con prioridades, pausa global y retroceso al recibir
  `429`.
- `Service.qml`: las cargas consecutivas usan el socket del backend nativo y
  programa precargas cancelables.

Nota: la pausa se aplica para evitar el límite de la API; no representa la
latencia de reproducción local.

### Caché de catálogo y navegación (2026-09-06)

El estado persistente del catálogo se guarda fuera del proyecto en
`~/.local/state/omarchy-spotify/catalog-cache.json`. No contiene tokens ni
audio; solo metadatos normalizados, URIs de Spotify y URLs de portada.

- Restaura al inicio las playlists seguidas, Canciones que te gustan, álbumes
  guardados y, cuando ya se cargaron, las secciones de inicio.
- Guarda hasta 50 pistas por playlist y por álbum precargado. Las playlists y
  álbumes se calientan gradualmente mientras el cliente está inactivo.
- Las precargas son de prioridad baja y se cancelan al abrir contenido o
  ejecutar una acción interactiva.
- Los álbumes de la barra lateral abren primero un detalle vacío con
  `Cargando…`; nunca deben reutilizar visualmente la lista anterior.
- La playlist personalizada `DJ` de Spotify se excluye por su identificador,
  porque no es reproducible por este cliente.

Archivos de la instalación local implicados: `Api.js`, `SpotifyApi.qml`,
`Service.qml`, `Panel.qml` y `tests/tst_spotify_api.qml`.

Verificaciones efectuadas:

```bash
omarchy plugin validate ~/.config/omarchy/plugins/quickshell.spotify
/usr/lib/qt6/bin/qmltestrunner \
  -input ~/.config/omarchy/plugins/quickshell.spotify/tests/tst_spotify_api.qml
```

Las pruebas específicas de caché y cancelación de precargas pasan. El conjunto
histórico del transporte conserva fallos de temporización no relacionados que
ya existían antes de esta modificación.

### Apagado completo y arranque bajo demanda

El plugin dispone de:

- Botón **Apagar** en el minirreproductor.
- Botón rojo de apagado en la cabecera del reproductor completo.

Los dos cierran la superficie visible y ejecutan `stopEngine()`. Este método
detiene los temporizadores de activación, elimina las cargas pendientes y para
la unidad de systemd.

Las unidades de backend son `static`: no tienen `WantedBy` ni `RequiredBy`.
Como protección adicional, ambas exigen el marcador temporal:

```text
%t/omarchy-spotify/allow-start
```

`playback-runtime.sh start` crea el marcador inmediatamente antes de iniciar
el backend. `playback-runtime.sh stop` lo borra. Como `%t` corresponde a
`XDG_RUNTIME_DIR`, desaparece en cada inicio de sesión: un arranque restaurado
por Quickshell o systemd no puede reactivar Spotify tras reiniciar el equipo.

El widget de la barra solo es visible si `spotify.daemon.running` es verdadero.
Por tanto, con el backend apagado no aparece el icono de Spotify.

## Estado validado

En la última comprobación:

```text
omarchy-spotify.service: ActiveState=inactive, UnitFileState=static
omarchy-spotifyd.service: inactive, UnitFileState=static
WantedBy= (vacío)
RequiredBy= (vacío)
```

También se validó que un `systemctl --user start omarchy-spotify.service`
directo queda bloqueado por la condición temporal, mientras que el lanzador
`playback-runtime.sh start` puede iniciarlo y `stop` lo deja otra vez inactivo.

## Continuación: traducción privada al español

La traducción se hará solo sobre la copia local del plugin, sin enviar cambios
al repositorio original.

Estado actualizado (2026-09-06): traducida la interfaz visible de la copia
local: minirreproductor, panel completo, navegación, búsqueda contextual,
biblioteca, listas, dispositivos, ajustes, menús, temporizador, avisos de
letras y mensajes propios de conexión y reproducción. También se tradujeron
las rutas de error de autenticación, API y Spotify Connect que se muestran al
usuario.

Se conservan sin traducir deliberadamente los nombres de canciones, álbumes,
artistas, listas y dispositivos que devuelve Spotify, además de los valores
internos de configuración (`On`, `Off`, `Full player`, etc.), ya que forman
parte de la persistencia y no son texto presentado directamente al usuario.

Validación realizada: `omarchy restart shell`, comprobación del journal sin
errores de sintaxis de QML y revisión visual del panel abierto en Biblioteca.

## Reglas de mantenimiento

- No editar `/usr/share/omarchy`.
- No guardar tokens, ficheros OAuth, sockets, caché ni credenciales en Git.
- Antes de actualizar el plugin, guardar o revisar el diff de
  `~/.config/omarchy/plugins/quickshell.spotify`.
- Tras cambios en QML: `omarchy restart shell` y revisar el journal de
  `omarchy-shell` para errores.
- Tras cambios de unidad: `systemctl --user daemon-reload` y comprobar
  `systemctl --user show omarchy-spotify.service -p ActiveState -p WantedBy`.
