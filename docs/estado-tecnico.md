# Estado técnico y bitácora

Actualizado: 2026-09-08

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
| Entrada de menú (.desktop) | `~/.local/share/applications/spotify.desktop` |
| Script lanzador | `~/.local/bin/omarchy-launch-spotify` |
| Iconos de aplicación | `~/.local/share/icons/hicolor/{64x64,128x128}/apps/spotify.png` |
| Sobrescritura de menú de Omarchy | `~/.config/omarchy/extensions/omarchy-menu.jsonc` |
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

## Integración en el menú de aplicaciones y lanzador del sistema (2026-09-08)

### Problema abordado
El plugin `quickshell.spotify` funciona como panel/servicio dentro de Quickshell y carecía de un archivo `.desktop` estándar en el sistema. Por ello, al abrir el menú de aplicaciones de Omarchy (`omarchy-menu` o `SUPER+SPACE` / `SUPER+ALT+SPACE`) no figuraba ningún cliente Spotify disponible, y la búsqueda de "spotify" únicamente mostraba la acción predeterminada de instalar el paquete oficial (`install.service.spotify`).

### Componentes y configuración añadidos
1. **Lanzador del plugin**:
   - `~/.local/bin/omarchy-launch-spotify`: invoca `omarchy-shell shell summon quickshell.spotify '{}'`. Abre y enfoca el reproductor completo bajo demanda tanto desde el menú de aplicaciones como desde la terminal o llamadas `omarchy launch spotify`.
2. **Entrada de escritorio (`.desktop`)**:
   - `~/.local/share/applications/spotify.desktop`: registra la aplicación en el menú del sistema y lanzadores XDG con categorías multimedia (`Audio;Music;Player;AudioVideo;`), términos de búsqueda en español e inglés (`spotify`, `music`, `musica`, `reproductor`) y `StartupNotify=false`.
   - Se incluye copia versionada en el repositorio en `desktop/spotify.desktop` y `desktop/omarchy-launch-spotify`.
3. **Iconos**:
   - Se instalaron los iconos de Spotify en `~/.local/share/icons/hicolor/128x128/apps/spotify.png` y `64x64/apps/spotify.png`, y se actualizó la caché de iconos con `gtk-update-icon-cache`.
4. **Desactivación de la opción de instalar el cliente oficial**:
   - En `~/.config/omarchy/extensions/omarchy-menu.jsonc` se añadió `"install.service.spotify": { "when": "false" }`, impidiendo que el menú vuelva a ofrecer la instalación del cliente oficial al buscar Spotify.
5. **Limpieza del paquete oficial**:
   - Se desinstaló completamente el paquete oficial de Spotify y sus dependencias no utilizadas mediante `omarchy pkg drop spotify`, liberando ~372 MiB, y se purgó la caché residual de `~/.cache/spotify`.

### Validación
- `omarchy menu refresh` y `omarchy restart shell` ejecutados correctamente.
- Búsqueda en el menú de Omarchy (`SUPER+SPACE`) muestra "Spotify" abriendo el cliente custom.
- La opción de instalar el cliente oficial ya no aparece.

## Precarga de la última canción y navegación de contexto en frío (2026-09-08)

### Problema abordado
1. Al reiniciar la sesión o abrir el reproductor tras haber estado apagado el backend, la interfaz no mostraba ninguna pista cargada ("No se está reproduciendo nada"), obligando a navegar manualmente a la biblioteca para reanudar la música.
2. Tras implementar la precarga de la última pista, si el usuario abría el reproductor en frío y pulsaba los botones **Siguiente** o **Anterior** antes de darle a **Play**, las acciones no tenían efecto (`POST /me/player/next` fallaba porque aún no existía ningún dispositivo activo en Spotify).

### Solución implementada
1. **Persistencia de la última pista y su contexto en caché**:
   - En `Api.js` y `Service.qml`, se extendió el registro de `catalog-cache.json` (`~/.local/state/omarchy-spotify/catalog-cache.json`) para almacenar:
     - `lastTrack`: ID, URI, título, artista/subtítulo, álbum, artistas estructurados, carátula (`imageUrl`), duración y URL externa.
     - `lastContextUri`: URI de Spotify del contexto de procedencia (`spotify:album:...` o `spotify:playlist:...`).
     - `lastContextItems`: lista de hasta 50 pistas del contexto activo, preservando el orden de la lista.
   - `recordLastPlayedTrack()` sincroniza y guarda automáticamente esta información ante cambios de canción (`onCurrentTrackItemUriChanged`) o al activarse la reproducción (`onPlayingChanged`).
   - `clearData()` limpia los valores ante un cierre de sesión.

2. **Precarga reactiva en la interfaz**:
   - `lastPlayedTrack` se restaura al inicio en `applyCatalogCache(raw)`.
   - Propiedades del servicio (`title`, `artist`, `album`, `artUrl`, `lengthSeconds`, `currentTrackItem`, `currentTrackId`) hacen fallback a `lastPlayedTrack` si el reproductor local está detenido y no hay reproducción remota activa.
   - La propiedad `playbackControllable` permanece activa (`true`) si la sesión está iniciada y existe una pista precargada, habilitando los botones de la interfaz.

3. **Reanudación y navegación directa en frío**:
   - `togglePlayback()`: al pulsar Play sin reproducción activa, lanza `playItem(lastPlayedTrack, null, lastPlayedContextUri, "")`, arrancando el daemon e iniciando la canción dentro de su contexto original.
   - `next()` y `previous()`: cuando el reproductor está detenido o en frío, invocan `findAdjacentTrack(direction)`, el cual localiza la canción adyacente dentro de `contextTracksForUri()` (álbum o playlist en caché, o lista previa).
   - Inmediatamente actualizan la UI con los datos de la nueva pista y llaman a `playItem(...)` con el offset correspondiente, arrancando la reproducción directamente en esa pista sin requerir pulsar Play primero.
   - Como salvaguarda adicional, si la pista no estuviera en la lista local, encolan un salto (`pendingSkipAfterStart`) que se ejecuta de forma inmediata en cuanto el backend arranca y conecta la sesión.

### Archivos implicados
- `plugin/quickshell.spotify/Api.js`: serialización y parseo de `lastTrack`, `lastContextUri` y `lastContextItems`.
- `plugin/quickshell.spotify/Service.qml`: precarga, fallbacks de propiedades, `recordLastPlayedTrack`, `contextTracksForUri`, `findAdjacentTrack`, `next`, `previous`, `playItem` y `clearData`.
- `plugin/quickshell.spotify/tests/tst_spotify_api.qml`: pruebas unitarias de persistencia en caché de `lastTrack`, `lastContextUri` y `lastContextItems`.

### Validación
- `qmllint` ejecutado sobre `Service.qml` y `Api.js`: 0 errores.
- `omarchy plugin validate` ejecutado correctamente.
- Sincronizado a `~/.config/omarchy/plugins/quickshell.spotify/` y recargado mediante `omarchy restart shell`.
- Comprobado que en frío se muestra la pista previa y los botones Siguiente/Anterior cambian de pista e inician la reproducción en el contexto del álbum/playlist.

## Reglas de mantenimiento

- No editar `/usr/share/omarchy`.
- No guardar tokens, ficheros OAuth, sockets, caché ni credenciales en Git.
- Antes de actualizar el plugin, guardar o revisar el diff de
  `~/.config/omarchy/plugins/quickshell.spotify`.
- Tras cambios en QML: `omarchy restart shell` y revisar el journal de
  `omarchy-shell` para errores.
- Tras cambios de unidad: `systemctl --user daemon-reload` y comprobar
  `systemctl --user show omarchy-spotify.service -p ActiveState -p WantedBy`.
