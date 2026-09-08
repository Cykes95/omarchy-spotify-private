import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris

import "Api.js" as Api

// Shared state for the bar widget and the lazy full panel. MPRIS supplies local
// playback changes. External Spotify Connect playback is refreshed only while
// a UI is visible (or while a known remote item is actively playing).
Item {
  id: root

  visible: false
  width: 0
  height: 0

  property var shell: null
  property var manifest: null
  property var pluginRegistry: null

  readonly property string pluginId: manifest && manifest.id
    ? String(manifest.id) : "quickshell.spotify"
  readonly property string pluginDir: manifest && manifest.__sourceDir
    ? String(manifest.__sourceDir) : ""
  readonly property string homeDirectory: Quickshell.env("HOME") || ""
  readonly property string stateHome: {
    var explicit = String(Quickshell.env("XDG_STATE_HOME") || "").trim()
    if (explicit) return explicit
    return homeDirectory ? homeDirectory + "/.local/state" : ".local/state"
  }
  readonly property string stateDir: stateHome + "/omarchy-spotify"
  readonly property string sessionPath: stateDir + "/session.json"
  readonly property string catalogCachePath: stateDir + "/catalog-cache.json"

  readonly property var defaultSettingValues: ({
    deviceName: "Omarchy Spotify",
    idleShutdownMinutes: 15,
    showMiniPlayer: "On",
    shortcutPlayer: "Omarchy Music app",
    shortcutHints: "On",
    showTrackTitle: "On",
    showArtistName: "Off",
    showPausedTrack: "On",
    scrollBarText: "Off",
    scrollSpeed: "1",
    maxBarTextWidth: "240",
    audioQuality: "320 kbps"
  })
  property var settings: Api.shallowCopy(defaultSettingValues)

  readonly property string deviceName: String(settings.deviceName || "Omarchy Spotify").trim() || "Omarchy Spotify"
  readonly property int idleShutdownMinutes: Math.max(0, Math.min(1440,
    Math.floor(Number(settings.idleShutdownMinutes) || 0)))
  readonly property bool showMiniPlayer: String(settings.showMiniPlayer || "On") !== "Off"
  readonly property string shortcutPlayer: Api.normalizedShortcutPlayer(
    settings.shortcutPlayer)
  readonly property bool shortcutHintsEnabled: String(settings.shortcutHints || "On") !== "Off"
  readonly property bool showTrackTitle: String(settings.showTrackTitle || "On") !== "Off"
  readonly property bool showArtistName: String(settings.showArtistName || "Off") === "On"
  readonly property bool showPausedTrack: String(settings.showPausedTrack || "On") !== "Off"
  readonly property bool scrollBarText: String(settings.scrollBarText || "Off") === "On"
  readonly property real scrollSpeed: Api.normalizedScrollSpeed(settings.scrollSpeed)
  // Bar label cap in unscaled px; 0 means no cap.
  readonly property real maxBarTextWidth: Api.normalizedMaxBarTextWidth(
    settings.maxBarTextWidth)
  readonly property int bitrateKbps: {
    var quality = String(settings.audioQuality || "320 kbps")
    return quality.indexOf("96") === 0 ? 96
      : (quality.indexOf("160") === 0 ? 160 : 320)
  }
  readonly property string audioQuality: bitrateKbps + " kbps"
  property var searchHistory: []
  property var sessionState: ({})
  property bool sessionFileReady: false
  property bool sessionFileHadData: false
  property bool sessionFileDirty: false
  property bool pluginSessionKeysPendingStrip: false
  property bool catalogCacheReady: false
  property bool catalogCacheDirty: false
  property bool catalogCacheApplied: false
  property var playlistDetails: ({})
  property var albumDetails: ({})
  property var lastPlayedTrack: null
  property string lastPlayedContextUri: ""
  property var lastPlayedContextItems: []
  property string pendingSkipAfterStart: ""
  property var playlistWarmupQueue: []
  property bool playlistWarmupRunning: false
  property var albumWarmupQueue: []
  property bool albumWarmupRunning: false

  readonly property alias auth: authManager
  readonly property alias api: spotifyApi
  readonly property alias daemon: daemonManager
  readonly property alias backend: backendClient
  readonly property bool accountConnected: authManager.loggedIn
  readonly property bool sessionPending: !authManager.sessionChecked
  readonly property bool fullyConnected: daemonManager.playbackReady
    && authManager.loggedIn && daemonManager.credentialsAvailable
  readonly property bool loginBusy: daemonManager.setupBusy
    || authManager.loginBusy
    || authManager.sessionBusy || !authManager.sessionChecked
    || daemonManager.authenticationBusy || daemonManager.credentialsClearBusy
    || !daemonManager.credentialsChecked || !daemonManager.requirementsChecked
  readonly property string loginProgress: loginProgressText()

  readonly property var mprisPlayers: Mpris.players ? Mpris.players.values : []
  readonly property var activePlayer: spotifydPlayer()
  readonly property bool hasLocalPlayer: activePlayer !== null
  property var remotePlayback: null
  property bool remotePlaybackLoading: false
  property var remotePlaybackWaiters: []
  property var rememberedRemoteVolumeDevice: null
  property real rememberedRemoteVolumePercent: -1
  property var pendingRemoteSeek: null
  property var pendingRemoteVolume: null
  property real pendingSliderVolume: -1
  property double pendingSliderUntil: 0
  property bool volumeFlushQueued: false
  property real queuedVolumeSlider: 0
  property bool volumeFlushCooling: false
  property bool volumeLiveActive: false
  property int remoteControlSerial: 0
  readonly property int remoteControlGraceMs: 8000
  property string remoteVolumeProbeKey: ""
  property int playbackPositionTick: 0
  property string remoteControlDiscoveryKey: ""
  readonly property var remoteTrack: remotePlayback ? remotePlayback.item : null
  readonly property var currentArtists: {
    if (remoteTrack && (useRemotePlayback || (currentTrackId !== ""
        && String(remoteTrack.id || "") === currentTrackId)))
      return Api.arrayValues(remoteTrack.artists)
    if (lastPlayedTrack && lastPlayedTrack.artists && lastPlayedTrack.artists.length > 0)
      return Api.arrayValues(lastPlayedTrack.artists)
    return []
  }
  readonly property bool currentArtistContextAvailable: Api.artistContextAvailable(
    useRemotePlayback && remoteTrack ? remoteTrack.type : "",
    currentTrackId, currentArtists)
  readonly property bool currentAlbumContextAvailable: album !== ""
    && currentTrackId !== ""
  readonly property var currentLyricsSong: Api.lyricsSong(currentTrackId,
    title, artist, album, lengthSeconds, artUrl, positionSeconds)
  readonly property bool lyricsAvailable: currentLyricsSong !== null
  readonly property string lyricsPluginId: "stappmus.lyrics"
  readonly property string lyricsPluginUrl: "https://github.com/stappmus/Omasing.git"
  readonly property string lyricsPluginAvailability: {
    var plugins = pluginRegistry && pluginRegistry.installedPlugins
      ? pluginRegistry.installedPlugins : ({})
    var installed = !!plugins[lyricsPluginId]
    var enabled = installed && pluginRegistry
      && typeof pluginRegistry.inBar === "function"
      && pluginRegistry.inBar(lyricsPluginId)
    return Api.optionalPluginState(installed, enabled)
  }
  property bool lyricsPluginBusy: false
  property string lyricsPluginOperation: ""
  property string lyricsPluginError: ""
  property string lyricsPluginRequestSurface: ""
  property var pendingLyricsSong: null
  property int lyricsPluginLaunchAttempts: 0
  property double lyricsPluginInstallStartedAt: 0
  readonly property var currentAlbumItem: remoteTrack
    && (useRemotePlayback || (currentTrackId !== ""
      && String(remoteTrack.id || "") === currentTrackId))
    ? remoteTrack.albumItem : null
  readonly property var remoteDevice: remotePlayback ? remotePlayback.device : null
  readonly property bool remotePlaybackIsLocal: !!remoteDevice
    && Api.isLocalPlaybackDevice(remoteDevice, deviceName,
      localRuntimeDeviceName, localDeviceId)
  readonly property bool useRemotePlayback: !!remotePlayback
    && !!remoteDevice && remoteDevice.active === true
    && !remotePlaybackIsLocal
    && !(hasLocalPlayer && activePlayer.isPlaying)
  readonly property bool hasPlayer: useRemotePlayback || hasLocalPlayer
  readonly property bool hasMedia: useRemotePlayback
    ? !!remoteTrack
    : (hasLocalPlayer && !!(activePlayer.trackTitle || activePlayer.trackArtist))
  readonly property bool playing: useRemotePlayback
    ? remotePlayback.playing === true
    : (hasLocalPlayer && activePlayer.isPlaying)
  readonly property int playbackState: hasPlayer
    ? (useRemotePlayback
      ? (remotePlayback.playing ? MprisPlaybackState.Playing : MprisPlaybackState.Paused)
      : activePlayer.playbackState)
    : MprisPlaybackState.Stopped
  readonly property string title: useRemotePlayback && remoteTrack
    ? String(remoteTrack.name || "")
    : (hasLocalPlayer && (activePlayer.trackTitle || activePlayer.trackArtist)
      ? String(activePlayer.trackTitle || "")
      : (lastPlayedTrack ? String(lastPlayedTrack.name || "") : ""))
  readonly property string artist: useRemotePlayback && remoteTrack
    ? String(remoteTrack.subtitle || "")
    : (hasLocalPlayer && (activePlayer.trackTitle || activePlayer.trackArtist)
      ? String(activePlayer.trackArtist || "")
      : (lastPlayedTrack ? String(lastPlayedTrack.subtitle || "") : ""))
  readonly property string album: useRemotePlayback && remoteTrack
    ? String(remoteTrack.album || "")
    : (hasLocalPlayer && activePlayer.trackAlbum
      ? String(activePlayer.trackAlbum || "")
      : (lastPlayedTrack ? String(lastPlayedTrack.album || "") : ""))
  readonly property string artUrl: useRemotePlayback && remoteTrack
    ? String(remoteTrack.imageUrl || "")
    : (hasLocalPlayer && activePlayer.trackArtUrl
      ? String(activePlayer.trackArtUrl || "")
      : (lastPlayedTrack ? String(lastPlayedTrack.imageUrl || "") : ""))
  readonly property real positionSeconds: {
    playbackPositionTick
    if (!useRemotePlayback) return hasLocalPlayer && activePlayer.positionSupported
      ? Math.max(0, Number(activePlayer.position) || 0) : 0
    var value = Api.displayedRemotePosition(remotePlayback,
      pendingRemoteSeek, Date.now())
    var maximum = remoteTrack ? Math.max(0, Number(remoteTrack.durationMs) || 0) / 1000 : 0
    return maximum > 0 ? Math.min(maximum, value) : value
  }
  readonly property real lengthSeconds: useRemotePlayback && remoteTrack
    ? Math.max(0, Number(remoteTrack.durationMs) || 0) / 1000
    : (hasLocalPlayer && activePlayer.lengthSupported && (activePlayer.trackTitle || activePlayer.trackArtist)
      ? Math.max(0, Number(activePlayer.length) || 0)
      : (lastPlayedTrack ? Math.max(0, Number(lastPlayedTrack.durationMs || 0)) / 1000 : 0))
  readonly property real playbackVolume: useRemotePlayback && remoteDevice
    ? displayedRemoteVolumePercent(remoteDevice) / 100
    : (hasLocalPlayer && activePlayer.volumeSupported
      ? Math.max(0, Math.min(1, Number(activePlayer.volume) || 0)) : 0)
  readonly property real reportedSliderVolume: useRemotePlayback
    ? playbackVolume : Api.spotifydVolumeToSlider(playbackVolume)
  readonly property real volume: pendingSliderVolume >= 0
    ? pendingSliderVolume : reportedSliderVolume
  readonly property bool volumePending: pendingSliderVolume >= 0
  onReportedSliderVolumeChanged: reconcilePendingSliderVolume()
  onUseRemotePlaybackChanged: {
    clearPendingSliderVolume()
    volumeFlushQueued = false
    volumeFlushCooling = false
    volumeLiveActive = false
    if (volumeFlushTimer) volumeFlushTimer.stop()
    if (volumeLiveIdleTimer) volumeLiveIdleTimer.stop()
  }
  readonly property bool shuffle: useRemotePlayback
    ? remotePlayback.shuffle === true
    : (hasLocalPlayer && activePlayer.shuffleSupported
      ? activePlayer.shuffle === true : false)
  readonly property string repeatMode: useRemotePlayback
    ? String(remotePlayback.repeatMode || "off") : mprisRepeatMode()
  readonly property string currentUri: useRemotePlayback && remoteTrack
    ? String(remoteTrack.uri || "") : metadataString("xesam:url")
  readonly property string currentExternalUrl: useRemotePlayback && remoteTrack
    ? String(remoteTrack.externalUrl || spotifyWebUrl(currentUri))
    : (lastPlayedTrack && lastPlayedTrack.externalUrl
      ? String(lastPlayedTrack.externalUrl)
      : spotifyWebUrl(currentUri || (lastPlayedTrack ? lastPlayedTrack.uri : "")))
  readonly property string currentTrackId: {
    // When a remote device owns playback, stale metadata from an idle local
    // spotifyd player must not turn a podcast episode into a song.
    if (useRemotePlayback) {
      if (!remoteTrack || remoteTrack.type !== "track") return ""
      return Api.spotifyTrackId(remoteTrack.uri)
        || String(remoteTrack.id || "").trim()
    }

    var id = Api.spotifyTrackId(currentUri)
    if (id) return id

    // spotifyd exposes the recording as an MPRIS object path such as
    // /spotify/track/<id>, but does not currently publish xesam:url.
    id = Api.spotifyTrackId(metadataString("mpris:trackid"))
    if (id) return id

    if (remoteTrack && remotePlaybackIsLocal && remoteTrack.type === "track")
      return String(remoteTrack.id || "").trim()

    return lastPlayedTrack ? String(lastPlayedTrack.id || "") : ""
  }
  readonly property var currentTrackItem: {
    if (hasMedia) {
      return Api.currentPlaybackTrack(
        currentTrackId, remoteTrack, title, artist, album, artUrl,
        lengthSeconds, currentExternalUrl)
    }
    return lastPlayedTrack || null
  }
  readonly property string currentTrackItemUri: currentTrackItem
    ? String(currentTrackItem.uri || "") : ""
  readonly property bool currentTrackSaved: isSaved(currentTrackItem)
  readonly property bool currentTrackSaveChecking: isSavedChecking(currentTrackItem)
  readonly property bool currentTrackSaveBusy: currentTrackSaveChecking
    || isSavedBusy(currentTrackItem)
  readonly property bool currentTrackSaveAvailable: !!currentTrackItem
    && authManager.loggedIn && !currentTrackSaveBusy
  readonly property bool playbackRestricted: useRemotePlayback
    && remoteDevice && remoteDevice.restricted === true
  readonly property var sonosControlDevice: findSonosControlDevice()
  readonly property bool sonosControlAvailable: useRemotePlayback
    && playbackRestricted && !!sonosControlDevice
  readonly property bool playbackControllable: (hasPlayer || (authManager.loggedIn && !!lastPlayedTrack))
    && (!playbackRestricted || sonosControlAvailable)
  readonly property bool volumeSupported: useRemotePlayback
    ? !!remoteDevice && remoteDevice.supportsVolume === true
      && (!playbackRestricted || sonosControlAvailable)
    : (hasLocalPlayer && activePlayer.volumeSupported)
  readonly property string playbackDeviceName: useRemotePlayback && remoteDevice
    ? Api.playbackDeviceDisplayName(remoteDevice, spotifyConnectManager.devices)
    : (hasLocalPlayer ? deviceName : "")

  property var playlists: []
  property string playlistsNext: ""
  property var savedTracks: []
  property string savedTracksNext: ""
  property var savedAlbums: []
  property string savedAlbumsNext: ""
  property var followedArtists: []
  property string followedArtistsNext: ""
  property var savedShows: []
  property string savedShowsNext: ""
  property var savedEpisodes: []
  property string savedEpisodesNext: ""
  property var savedAudiobooks: []
  property string savedAudiobooksNext: ""
  property var playlistItems: []
  property string playlistItemsNext: ""
  property string playlistItemsError: ""
  property int playlistItemsStatus: 0
  property int playlistItemsSerial: 0
  property int playlistRestoreTargetCount: 0
  property var selectedPlaylist: null
  property string currentUserId: ""
  property string currentUserName: ""
  readonly property string playlistItemsEmptyMessage: Api.playlistItemsEmptyMessage(
    selectedPlaylist, playlistItems.length, playlistItemsError,
    playlistItemsStatus, currentUserId)
  property var queue: []
  property var devices: []
  property var apiDevices: []
  property string pendingDeviceLoadError: ""
  property var deviceLoadWaiters: []
  property bool pendingDeviceDiscover: false
  property string selectedDeviceId: ""
  property bool selectedDeviceExplicit: false
  property string localDeviceId: ""
  property string localRuntimeDeviceName: "Omarchy Spotify"
  property string searchQuery: ""
  property var searchGroups: Api.searchGroups({}, 128)
  property var savedUris: ({})
  property var savedUriCheckedAt: ({})
  property var savedUriOrder: []
  property var savedUrisChecking: ({})
  property var savedUrisBusy: ({})
  // The maps stay stable to avoid full copies; revisions keep QML lookups
  // reactive when individual entries change.
  property int savedUrisRevision: 0
  property int savedUrisCheckingRevision: 0
  property int savedUrisBusyRevision: 0
  readonly property int savedUriCacheLimit: 4096
  readonly property int savedUriFreshnessMs: 300000

  property var recentTracks: []
  property var topTracks: []
  property var topArtists: []
  property bool homeLoaded: false
  property int homeRequestsPending: 0
  readonly property bool homeLoading: homeRequestsPending > 0

  property var discoverPlaylists: []
  property var discoverCandidates: []
  property bool discoverLoaded: false
  property int discoverRequestsPending: 0
  property int discoverRequestsFailed: 0
  property int discoverSerial: 0
  property string discoverMessage: ""
  readonly property bool discoverLoading: discoverRequestsPending > 0

  property var detailItem: null
  property var detailItems: []
  property string detailNext: ""
  property bool detailLoading: false
  property string detailMessage: ""
  property int detailSerial: 0
  property int detailRestoreTargetCount: 0
  property var artistAlbums: []
  property string artistAlbumsNext: ""
  property bool artistAlbumsLoading: false
  property var artistSongs: []
  property string artistSongsNext: ""
  property bool artistSongsLoading: false
  property var artistPlaylists: []
  property string artistPlaylistsNext: ""
  property bool artistPlaylistsLoading: false
  property var artistThisIsPlaylist: null
  property bool artistThisIsLoading: false
  property string artistCatalogQuery: ""
  property int artistCatalogSerial: 0
  readonly property bool artistCatalogLoading: artistAlbumsLoading
    || artistSongsLoading || artistPlaylistsLoading

  property bool playlistActionBusy: false
  property bool playlistConversionBusy: false
  property string pendingPlaylistName: ""

  property string sleepMode: "off"
  property double sleepEndsAt: 0
  property string sleepTrackUri: ""
  readonly property bool sleepActive: sleepMode !== "off"
  property int sleepRemainingSeconds: 0

  property string activeView: "search"
  property bool playlistsLoaded: false
  property bool savedTracksLoaded: false
  property bool savedAlbumsLoaded: false
  property bool followedArtistsLoaded: false
  property bool savedShowsLoaded: false
  property bool savedEpisodesLoaded: false
  property bool savedAudiobooksLoaded: false
  property bool queueLoaded: false
  property bool devicesLoaded: false
  property bool playlistsLoading: false
  property bool savedTracksLoading: false
  property bool savedAlbumsLoading: false
  property bool followedArtistsLoading: false
  property bool savedShowsLoading: false
  property bool savedEpisodesLoading: false
  property bool savedAudiobooksLoading: false
  property bool playlistItemsLoading: false
  property bool queueLoading: false
  property bool devicesLoading: false
  property bool searchLoading: false
  property string lastError: ""
  property string statusMessage: ""

  readonly property bool playlistRestorePending: Api.playlistRestorePending(
    playlistItems.length, playlistRestoreTargetCount, playlistItemsLoading,
    playlistItemsNext)
  readonly property int playlistRememberedItemCount:
    Api.normalizedPlaylistRestoreCount(Math.max(playlistItems.length,
      playlistRestoreTargetCount))
  readonly property bool detailRestorePending: !!detailItem
    && detailItem.type === "playlist" && Api.playlistRestorePending(
      detailItems.length, detailRestoreTargetCount, detailLoading, detailNext)
  readonly property int detailRememberedItemCount: Math.min(cacheLimit,
    Api.normalizedPlaylistRestoreCount(Math.max(detailItems.length,
      detailRestoreTargetCount)))

  property int dataSerial: 0
  property var visibleSurfaces: ({})
  readonly property bool uiVisible: Object.keys(visibleSurfaces).length > 0
  property double lastActivityAt: Date.now()
  property var pendingPlayback: null
  property var pendingPlaybackBody: null
  property string pendingPlaybackMessage: ""
  property var pendingPlaybackRadio: null
  property int pendingPlaybackSerial: 0
  property int radioSerial: 0
  property var lastRadioPlaylist: null
  property bool radioContextSelected: false
  readonly property bool lastRadioPlaying: !!lastRadioPlaylist
    && radioContextSelected && playing
  property bool localActivationRequested: false
  property int deviceProbeAttempts: 0
  property int localSocketWaitAttempts: 0
  property int visibleLocalDeviceRefreshAttempts: 0
  property bool loginFlowActive: false
  property string pendingConnectDeviceId: ""
  property int connectActivationAttempts: 0
  property bool pendingConnectWakeTried: false

  readonly property bool deviceActivationBusy: spotifyConnectManager.activating
    || (!!pendingConnectDeviceId && spotifyConnectManager.controlling)
    || connectAuthManager.loginBusy || connectAuthManager.sessionBusy

  readonly property int cacheLimit: 200

  signal operationFailed(string reason)
  signal radioPlaylistReady(var playlist)
  signal lyricsPluginPromptRequested(string surface, string availability)
  signal lyricsPluginOpened(string surface)

  function loginProgressText() {
    if (daemonManager.setupBusy) return "Preparando la reproducción en este equipo"
    if (daemonManager.credentialsClearBusy) return "Cerrando sesión"
    if (authManager.loginBusy) return "Autoriza el acceso a Spotify en el navegador"
    if (authManager.sessionBusy || !authManager.sessionChecked)
      return "Comprobando la sesión guardada de Spotify"
    if (!daemonManager.requirementsChecked || !daemonManager.credentialsChecked)
      return "Comprobando la reproducción local"
    if (daemonManager.authenticationBusy)
      return "Autoriza la reproducción local en el navegador"
    return fullyConnected ? "Conectado a Spotify" : "Listo para conectar"
  }

  function defaults() {
    var fallback = Api.shallowCopy(defaultSettingValues)
    var source = manifest && manifest.barWidget && manifest.barWidget.defaults
      ? manifest.barWidget.defaults : null
    return source ? Api.assign(fallback, source) : fallback
  }

  function normalizedSettings(values) {
    var next = defaults()
    var source = values || {}
    var keys = ["deviceName", "idleShutdownMinutes", "showMiniPlayer",
      "shortcutPlayer", "shortcutHints", "showTrackTitle", "showArtistName",
      "showPausedTrack", "scrollBarText", "scrollSpeed", "maxBarTextWidth",
      "audioQuality"]
    for (var i = 0; i < keys.length; i++) {
      var key = keys[i]
      if (source[key] !== undefined) next[key] = source[key]
    }
    next.deviceName = String(next.deviceName || "Omarchy Spotify").trim() || "Omarchy Spotify"
    next.idleShutdownMinutes = Math.max(0, Math.min(1440,
      Math.floor(Number(next.idleShutdownMinutes) || 0)))
    next.showMiniPlayer = String(next.showMiniPlayer || "On") === "Off" ? "Off" : "On"
    next.shortcutPlayer = Api.normalizedShortcutPlayer(next.shortcutPlayer)
    next.shortcutHints = Api.normalizedShortcutHints(next.shortcutHints)
    next.showTrackTitle = String(next.showTrackTitle || "On") === "Off" ? "Off" : "On"
    next.showArtistName = String(next.showArtistName || "Off") === "On" ? "On" : "Off"
    next.showPausedTrack = String(next.showPausedTrack || "On") === "Off" ? "Off" : "On"
    next.scrollBarText = String(next.scrollBarText || "Off") === "On" ? "On" : "Off"
    if (!Api.canScrollBarText(next.showTrackTitle === "On", next.showArtistName === "On"))
      next.scrollBarText = "Off"
    next.scrollSpeed = String(Api.normalizedScrollSpeed(next.scrollSpeed))
    next.maxBarTextWidth = String(Api.normalizedMaxBarTextWidth(next.maxBarTextWidth))
    // An uncapped slot always fits its text, so the marquee could never run.
    if (Number(next.maxBarTextWidth) === 0) next.scrollBarText = "Off"
    var quality = String(next.audioQuality || "320 kbps")
    next.audioQuality = quality.indexOf("96") === 0 ? "96 kbps"
      : (quality.indexOf("160") === 0 ? "160 kbps" : "320 kbps")
    return next
  }

  function relabelLocalDevices(source, previousName, nextName) {
    var rows = Array.isArray(source) ? source : []
    var result = []
    for (var i = 0; i < rows.length; i++) {
      var item = rows[i]
      if (!item) continue
      var local = item.local === true || Api.isLocalPlaybackDevice(item,
        previousName, localRuntimeDeviceName, localDeviceId)
      if (!local) {
        result.push(item)
        continue
      }
      var copy = Api.shallowCopy(item)
      copy.name = nextName
      copy.local = true
      result.push(copy)
    }
    return result
  }

  function applySettings(values) {
    var previousDeviceName = deviceName
    var next = normalizedSettings(values)
    if (JSON.stringify(next) !== JSON.stringify(settings)) settings = next
    if (previousDeviceName !== next.deviceName) {
      if (daemonManager.running && !localRuntimeDeviceName)
        localRuntimeDeviceName = previousDeviceName
      apiDevices = relabelLocalDevices(apiDevices, previousDeviceName, next.deviceName)
      devices = relabelLocalDevices(devices, previousDeviceName, next.deviceName)
    }
  }

  function persistSettings(values) {
    var next = normalizedSettings(Api.assign(Api.shallowCopy(settings), values))
    applySettings(next)
    if (shell && typeof shell.updateEntryInline === "function")
      shell.updateEntryInline(pluginId, next)
  }

  function persistSession(values) {
    var next = Api.normalizedSessionState(values || ({}))
    if (JSON.stringify(next) === JSON.stringify(sessionState)) return
    sessionState = next
    scheduleSessionSave()
  }

  function rememberSearch(term) {
    var next = Api.touchHistory(searchHistory, term, 12)
    if (JSON.stringify(next) === JSON.stringify(searchHistory)) return
    searchHistory = next
    scheduleSessionSave()
  }

  function clearSearchHistory() {
    if (searchHistory.length === 0) return
    searchHistory = []
    scheduleSessionSave()
  }

  function currentSessionRecord() {
    return Api.sessionRecord(sessionState, searchHistory)
  }

  function applySessionFile(raw) {
    if (sessionFileReady) return
    var fromFile = Api.parseSessionRecord(raw)
    sessionFileHadData = !Api.sessionRecordIsEmpty(fromFile)
    if (!sessionFileDirty && sessionFileHadData) {
      sessionState = fromFile.sessionState
      searchHistory = fromFile.searchHistory
    }
    sessionFileReady = true
    reconcileSessionPersistence()
    resumeLyricsInstallIntent()
  }

  function scheduleSessionSave() {
    sessionFileDirty = true
    if (sessionFileReady) sessionSaveTimer.restart()
  }

  function flushSessionFile() {
    if (!sessionFileReady) return
    sessionSaveTimer.stop()
    sessionFile.setText(Api.encodeSessionRecord(sessionState, searchHistory))
  }

  function stripPluginSessionKeys() {
    if (!pluginSessionKeysPendingStrip) return
    var entry = configuredEntry()
    if (!entry || !shell || typeof shell.updateEntryInline !== "function") return
    pluginSessionKeysPendingStrip = false
    persistSettings(entry)
  }

  function reconcileSessionPersistence() {
    if (!sessionFileReady) return
    var entry = configuredEntry() || {}
    var pluginHasKeys = Api.pluginSettingsHaveSessionKeys(entry)
    if (pluginHasKeys) {
      if (Api.sessionRecordIsEmpty(currentSessionRecord()) && !sessionFileDirty) {
        var fromPlugin = Api.sessionRecordFromPluginSettings(entry)
        sessionState = fromPlugin.sessionState
        searchHistory = fromPlugin.searchHistory
      }
      pluginSessionKeysPendingStrip = true
    }
    var shouldWrite = sessionFileDirty
      || (pluginHasKeys && !sessionFileHadData
        && !Api.sessionRecordIsEmpty(currentSessionRecord()))
    if (shouldWrite) flushSessionFile()
    else if (pluginHasKeys) stripPluginSessionKeys()
  }

  function currentCatalogCache() {
    return {
      savedAt: Date.now(),
      playlistsLoaded: playlistsLoaded,
      savedTracksLoaded: savedTracksLoaded,
      savedAlbumsLoaded: savedAlbumsLoaded,
      homeLoaded: homeLoaded,
      playlists: playlists,
      savedTracks: savedTracks,
      savedAlbums: savedAlbums,
      recentTracks: recentTracks,
      topTracks: topTracks,
      topArtists: topArtists,
      playlistDetails: playlistDetails,
      albumDetails: albumDetails,
      lastTrack: lastPlayedTrack,
      lastContextUri: lastPlayedContextUri,
      lastContextItems: lastPlayedContextItems
    }
  }

  function applyCatalogCache(raw) {
    if (catalogCacheReady) return
    var cached = Api.parseCatalogCache(raw)
    var cacheNeedsRewrite = false
    if (cached.savedAt > 0) {
      if (cached.playlistsLoaded) {
        playlists = supportedPlaylists(cached.playlists)
        playlistsLoaded = true
        catalogCacheApplied = true
        cacheNeedsRewrite = playlists.length !== cached.playlists.length
      }
      if (cached.savedTracksLoaded) {
        savedTracks = cached.savedTracks
        savedTracksLoaded = true
        catalogCacheApplied = true
      }
      if (cached.savedAlbumsLoaded) {
        savedAlbums = cached.savedAlbums
        savedAlbumsLoaded = true
        catalogCacheApplied = true
      }
      var cachedDetails = ({})
      var detailRows = Api.arrayValues(cached.playlistDetails)
      for (var i = 0; i < detailRows.length; i++) {
        var detail = detailRows[i]
        if (!detail || !detail.item || !detail.item.id) continue
        cachedDetails[String(detail.item.id)] = detail
      }
      playlistDetails = cachedDetails
      var cachedAlbums = ({})
      var albumRows = Api.arrayValues(cached.albumDetails)
      for (var a = 0; a < albumRows.length; a++) {
        var albumDetail = albumRows[a]
        if (albumDetail && albumDetail.item && albumDetail.item.id)
          cachedAlbums[String(albumDetail.item.id)] = albumDetail
      }
      albumDetails = cachedAlbums
      if (cached.homeLoaded) {
        recentTracks = cached.recentTracks
        topTracks = cached.topTracks
        topArtists = cached.topArtists
        homeLoaded = true
        catalogCacheApplied = true
      }
      if (cached.lastTrack && cached.lastTrack.id) {
        lastPlayedTrack = cached.lastTrack
        lastPlayedContextUri = String(cached.lastContextUri || "")
        lastPlayedContextItems = Array.isArray(cached.lastContextItems) ? cached.lastContextItems : []
        catalogCacheApplied = true
      }
    }
    catalogCacheReady = true
    if (cacheNeedsRewrite) scheduleCatalogCacheSave()
  }

  function scheduleCatalogCacheSave() {
    catalogCacheDirty = true
    if (catalogCacheReady) catalogCacheSaveTimer.restart()
  }

  function cachedPlaylistDetail(playlist) {
    if (!playlist || !playlist.id) return null
    return playlistDetails[String(playlist.id)] || null
  }

  function rememberPlaylistDetail(playlist, items) {
    if (!playlist || !playlist.id || !Array.isArray(items) || !items.length) return
    var next = Api.shallowCopy(playlistDetails)
    next[String(playlist.id)] = {
      item: playlist,
      items: items.slice(0, 50)
    }
    playlistDetails = next
    scheduleCatalogCacheSave()
  }

  function cachedAlbumDetail(album) {
    return album && album.id ? albumDetails[String(album.id)] || null : null
  }

  function rememberAlbumDetail(album, items) {
    if (!album || !album.id || !Array.isArray(items) || !items.length) return
    var next = Api.shallowCopy(albumDetails)
    next[String(album.id)] = { item: album, items: items.slice(0, 50) }
    albumDetails = next
    scheduleCatalogCacheSave()
  }

  function recordLastPlayedTrack() {
    if (!hasMedia && !playing) return
    if (!currentTrackItem || !currentTrackId) return
    var item = currentTrackItem
    var context = (remotePlayback && remotePlayback.contextUri)
      ? String(remotePlayback.contextUri)
      : (lastPlayedContextUri || "")
    var cover = String(artUrl || item.imageUrl || (lastPlayedTrack && lastPlayedTrack.id === currentTrackId ? lastPlayedTrack.imageUrl : "") || "")
    var trackArtists = (currentArtists && currentArtists.length)
      ? currentArtists
      : (item.artists && item.artists.length ? item.artists : (lastPlayedTrack && lastPlayedTrack.id === currentTrackId ? lastPlayedTrack.artists : []))
    var duration = (Math.max(0, Number(lengthSeconds) || 0) * 1000)
      || (item.durationMs ? Number(item.durationMs) : 0)
      || (lastPlayedTrack && lastPlayedTrack.id === currentTrackId ? Number(lastPlayedTrack.durationMs) : 0)

    var newTrack = {
      kind: "item",
      type: "track",
      id: currentTrackId,
      uri: currentTrackItemUri || ("spotify:track:" + currentTrackId),
      name: String(title || item.name || "Sin título"),
      subtitle: String(artist || item.subtitle || ""),
      album: String(album || item.album || ""),
      artists: Api.arrayValues(trackArtists),
      imageUrl: cover,
      durationMs: duration,
      externalUrl: String(currentExternalUrl || item.externalUrl || "")
    }

    if (context && context !== lastPlayedContextUri) {
      lastPlayedContextUri = context
      var ctxTracks = contextTracksForUri(context)
      if (ctxTracks && ctxTracks.length) lastPlayedContextItems = ctxTracks.slice(0, 50)
    } else if ((!lastPlayedContextItems || !lastPlayedContextItems.length) && context) {
      var ctxTracks = contextTracksForUri(context)
      if (ctxTracks && ctxTracks.length) lastPlayedContextItems = ctxTracks.slice(0, 50)
    }

    if (lastPlayedTrack
        && lastPlayedTrack.id === newTrack.id
        && lastPlayedTrack.name === newTrack.name
        && lastPlayedTrack.subtitle === newTrack.subtitle
        && lastPlayedTrack.imageUrl === newTrack.imageUrl
        && lastPlayedContextUri === context) {
      return
    }

    lastPlayedTrack = newTrack
    lastPlayedContextUri = context
    scheduleCatalogCacheSave()
  }

  function contextTracksForUri(uri) {
    var raw = String(uri || "")
    if (!raw) return lastPlayedContextItems || []
    var playlistMatch = raw.match(/^spotify:playlist:([a-zA-Z0-9]+)/)
    if (playlistMatch && playlistDetails[playlistMatch[1]]) {
      var plDetail = playlistDetails[playlistMatch[1]]
      if (plDetail && Array.isArray(plDetail.items) && plDetail.items.length)
        return plDetail.items
    }
    var albumMatch = raw.match(/^spotify:album:([a-zA-Z0-9]+)/)
    if (albumMatch && albumDetails[albumMatch[1]]) {
      var albDetail = albumDetails[albumMatch[1]]
      if (albDetail && Array.isArray(albDetail.items) && albDetail.items.length)
        return albDetail.items
    }
    if (raw === "spotify:user:saved" || raw.indexOf(":collection") >= 0) {
      if (Array.isArray(savedTracks) && savedTracks.length) return savedTracks
    }
    if (lastPlayedContextItems && lastPlayedContextItems.length) {
      return lastPlayedContextItems
    }
    return []
  }

  function findAdjacentTrack(direction) {
    if (!lastPlayedTrack || !lastPlayedTrack.id) return null
    var tracks = contextTracksForUri(lastPlayedContextUri)
    if (!Array.isArray(tracks) || !tracks.length) return null
    var currentIdx = -1
    for (var i = 0; i < tracks.length; i++) {
      if (tracks[i] && (String(tracks[i].id) === String(lastPlayedTrack.id)
          || String(tracks[i].uri) === String(lastPlayedTrack.uri))) {
        currentIdx = i
        break
      }
    }
    if (currentIdx < 0) return null
    var targetIdx = currentIdx + direction
    if (targetIdx >= 0 && targetIdx < tracks.length) {
      return { item: tracks[targetIdx], items: tracks }
    }
    if (direction > 0 && targetIdx >= tracks.length && tracks.length > 0) {
      return { item: tracks[0], items: tracks }
    }
    return null
  }

  function scheduleAlbumWarmup() {
    if (!catalogCacheReady || albumWarmupRunning) return
    var pending = []
    for (var i = 0; i < savedAlbums.length; i++)
      if (savedAlbums[i] && !cachedAlbumDetail(savedAlbums[i])) pending.push(savedAlbums[i])
    if (!pending.length) return
    albumWarmupQueue = pending
    albumWarmupTimer.restart()
  }

  function warmNextAlbum() {
    if (albumWarmupRunning || !albumWarmupQueue.length) return
    var album = albumWarmupQueue.shift()
    if (!album || cachedAlbumDetail(album)) { if (albumWarmupQueue.length) albumWarmupTimer.restart(); return }
    albumWarmupRunning = true
    spotifyApi.request("GET", "/albums/" + encodeURIComponent(String(album.id)), null, null,
      function(status, payload, error) {
        root.albumWarmupRunning = false
        if (!error) root.rememberAlbumDetail(album,
          root.detailPageFromPayload(payload, "album", album).items)
        if (root.albumWarmupQueue.length) albumWarmupTimer.restart()
      }, { priority: "background", retryRateLimit: false })
  }

  function schedulePlaylistWarmup() {
    if (!catalogCacheReady || !authManager.loggedIn || playlistWarmupRunning) return
    var pending = []
    for (var i = 0; i < playlists.length; i++)
      if (playlists[i] && playlists[i].id && !cachedPlaylistDetail(playlists[i]))
        pending.push(playlists[i])
    if (!pending.length) return
    playlistWarmupQueue = pending
    playlistWarmupTimer.restart()
  }

  function warmNextPlaylist() {
    if (playlistWarmupRunning || !playlistWarmupQueue.length) return
    var playlist = playlistWarmupQueue.shift()
    if (!playlist || !playlist.id || cachedPlaylistDetail(playlist)) {
      if (playlistWarmupQueue.length) playlistWarmupTimer.restart()
      return
    }
    playlistWarmupRunning = true
    spotifyApi.request("GET", "/playlists/" + encodeURIComponent(String(playlist.id))
      + "/items", { limit: 50 }, null, function(status, payload, error) {
        root.playlistWarmupRunning = false
        if (!error) {
          var position = Math.max(0, Math.floor(Number(payload && payload.offset) || 0))
          var page = Api.normalizePage(payload, function(value) {
            var track = Api.normalizeTrack(value, 96)
            if (track) track.playlistPosition = position++
            return track
          })
          root.rememberPlaylistDetail(playlist, page.items)
        }
        if (root.playlistWarmupQueue.length) playlistWarmupTimer.restart()
      }, { priority: "background", retryRateLimit: false })
  }

  function flushCatalogCache() {
    if (!catalogCacheReady || !catalogCacheDirty) return
    catalogCacheSaveTimer.stop()
    catalogCacheFile.setText(Api.encodeCatalogCache(currentCatalogCache()))
  }

  function configuredEntry() {
    var config = shell && shell.shellConfig ? shell.shellConfig : null
    if (!config) return null
    var layout = config.bar && config.bar.layout ? config.bar.layout : null
    var sections = ["left", "center", "right"]
    if (layout) {
      for (var s = 0; s < sections.length; s++) {
        var rows = Array.isArray(layout[sections[s]]) ? layout[sections[s]] : []
        for (var i = 0; i < rows.length; i++)
          if (rows[i] && String(rows[i].id || "") === pluginId) return rows[i]
      }
    }
    var plugins = Array.isArray(config.plugins) ? config.plugins : []
    for (var p = 0; p < plugins.length; p++)
      if (plugins[p] && String(plugins[p].id || "") === pluginId) return plugins[p]
    return null
  }

  function syncSettings() {
    applySettings(configuredEntry() || {})
    reconcileSessionPersistence()
    resumeLyricsInstallIntent()
  }

  function isSpotifyd(player) {
    if (!player) return false
    var identity = [player.dbusName, player.desktopEntry, player.identity]
      .join(" ").toLowerCase()
    return identity.indexOf("spotifyd") !== -1
      || identity.indexOf("librespot") !== -1
  }

  function spotifydPlayer() {
    var fallback = null
    for (var i = 0; i < mprisPlayers.length; i++) {
      var player = mprisPlayers[i]
      if (!isSpotifyd(player)) continue
      if (player.isPlaying) return player
      if (!fallback) fallback = player
    }
    return fallback
  }

  function metadataString(key) {
    var metadata = activePlayer && activePlayer.metadata ? activePlayer.metadata : null
    return metadata && metadata[key] !== undefined ? String(metadata[key]) : ""
  }

  function spotifyWebUrl(uri) {
    var value = String(uri || "")
    var match = value.match(/^spotify:(track|album|artist|playlist|episode|show|audiobook|chapter):([^:]+)$/)
    return match ? "https://open.spotify.com/" + match[1] + "/" + match[2]
      : (value.indexOf("https://open.spotify.com/") === 0 ? value : "")
  }

  function mprisRepeatMode() {
    if (!hasLocalPlayer || !activePlayer.loopSupported) return "off"
    if (activePlayer.loopState === MprisLoopState.Track) return "track"
    if (activePlayer.loopState === MprisLoopState.Playlist) return "context"
    return "off"
  }

  function safeError(reason) {
    return Api.redact(String(reason || "La operación de Spotify falló"))
  }

  function fail(reason) {
    statusClearTimer.stop()
    lastError = safeError(reason)
    statusMessage = ""
    operationFailed(lastError)
  }

  function succeed(message) {
    lastError = ""
    statusMessage = String(message || "")
    if (statusMessage) statusClearTimer.restart()
    else statusClearTimer.stop()
  }

  function requestLyrics(surface) {
    if (!currentLyricsSong) return "unavailable"
    lyricsPluginRequestSurface = String(surface || "")
    pendingLyricsSong = currentLyricsSong
    lyricsPluginError = ""
    lyricsPluginLaunchAttempts = 0
    if (lyricsPluginAvailability === "ready") {
      launchLyricsPlugin()
      return "opening"
    }
    lyricsPluginPromptRequested(lyricsPluginRequestSurface,
      lyricsPluginAvailability)
    return lyricsPluginAvailability
  }

  function pendingLyricsInstall() {
    var pending = sessionState && sessionState.pendingLyricsInstall
    return pending && typeof pending === "object" ? pending : null
  }

  function persistLyricsInstallIntent() {
    if (!pendingLyricsSong) return
    var state = Api.shallowCopy(sessionState)
    state.pendingLyricsInstall = Api.lyricsInstallIntent(pendingLyricsSong,
      lyricsPluginRequestSurface, Date.now())
    persistSession(state)
  }

  function clearLyricsInstallIntent() {
    if (!pendingLyricsInstall()) return
    persistSession(Api.sessionWithoutLyricsInstall(sessionState))
  }

  function confirmLyricsPlugin(surface) {
    if (lyricsPluginBusy) return false
    if (surface) lyricsPluginRequestSurface = String(surface)
    if (!pendingLyricsSong) pendingLyricsSong = currentLyricsSong
    if (!pendingLyricsSong) {
      lyricsPluginError = "Reproduce una canción primero y vuelve a intentar abrir las letras."
      return false
    }
    lyricsPluginError = ""

    if (lyricsPluginAvailability === "ready") {
      lyricsPluginLaunchAttempts = 0
      launchLyricsPlugin()
      return true
    }

    var command = Api.optionalPluginSetupCommand(lyricsPluginAvailability,
      lyricsPluginId, lyricsPluginUrl)
    if (!command.length) {
      lyricsPluginError = "No se pudo preparar Omasing para su instalación."
      return false
    }
    lyricsPluginOperation = lyricsPluginAvailability
    lyricsPluginBusy = true
    persistLyricsInstallIntent()

    // Adding a plugin writes into ~/.config/omarchy/plugins, which reloads
    // the shell and would kill a child Process before enable finishes.
    // Detach the add and resume from the saved intent after reload.
    if (lyricsPluginAvailability === "missing") {
      lyricsPluginInstallStartedAt = Date.now()
      Quickshell.execDetached(command)
      lyricsPluginInstallPoll.restart()
      return true
    }

    lyricsPluginSetupProcess.command = command
    lyricsPluginSetupProcess.running = true
    return true
  }

  function resumeLyricsInstallIntent() {
    var intent = pendingLyricsInstall()
    if (!intent) return
    if (!Api.lyricsInstallIntentIsFresh(intent, Date.now(), 180000)) {
      clearLyricsInstallIntent()
      return
    }
    if (!pendingLyricsSong) pendingLyricsSong = intent.song
    if (!lyricsPluginRequestSurface)
      lyricsPluginRequestSurface = String(intent.surface || "")

    if (lyricsPluginAvailability === "ready") {
      lyricsPluginInstallPoll.stop()
      lyricsPluginBusy = false
      lyricsPluginError = ""
      lyricsPluginLaunchAttempts = 0
      clearLyricsInstallIntent()
      launchLyricsPlugin()
      return
    }

    if (lyricsPluginBusy || lyricsPluginSetupProcess.running
        || lyricsPluginInstallPoll.running)
      return

    if (lyricsPluginAvailability === "disabled") {
      confirmLyricsPlugin(lyricsPluginRequestSurface)
      return
    }

    lyricsPluginBusy = true
    lyricsPluginOperation = "missing"
    lyricsPluginInstallStartedAt = Number(intent.startedAt) || Date.now()
    lyricsPluginInstallPoll.restart()
  }

  function finishLyricsPluginInstallWatch() {
    if (lyricsPluginAvailability === "ready") {
      lyricsPluginBusy = false
      lyricsPluginError = ""
      lyricsPluginLaunchAttempts = 0
      clearLyricsInstallIntent()
      launchLyricsPlugin()
      return true
    }
    if (lyricsPluginAvailability === "disabled") {
      lyricsPluginBusy = false
      confirmLyricsPlugin(lyricsPluginRequestSurface)
      return true
    }
    if (Date.now() - lyricsPluginInstallStartedAt < 90000) return false
    lyricsPluginBusy = false
    lyricsPluginError = "No se pudo instalar Omasing. Comprueba tu conexión e inténtalo de nuevo."
    clearLyricsInstallIntent()
    lyricsPluginPromptRequested(lyricsPluginRequestSurface,
      lyricsPluginAvailability)
    return true
  }

  function cancelLyricsPlugin(surface) {
    if (lyricsPluginBusy) return
    if (surface && String(surface) !== lyricsPluginRequestSurface) return
    lyricsPluginInstallPoll.stop()
    lyricsPluginRequestSurface = ""
    pendingLyricsSong = null
    lyricsPluginError = ""
    clearLyricsInstallIntent()
  }

  function launchLyricsPlugin() {
    if (!pendingLyricsSong || lyricsPluginLaunchProcess.running) return
    lyricsPluginLaunchAttempts++
    lyricsPluginLaunchProcess.command = ["/usr/bin/omarchy-shell",
      lyricsPluginId, "lyrics", JSON.stringify(pendingLyricsSong)]
    lyricsPluginLaunchProcess.running = true
  }

  function finishLyricsPluginLaunch(exitCode) {
    if (Number(exitCode) === 0) {
      var openedSurface = lyricsPluginRequestSurface
      pendingLyricsSong = null
      lyricsPluginRequestSurface = ""
      lyricsPluginError = ""
      lyricsPluginLaunchAttempts = 0
      lyricsPluginOpened(openedSurface)
      return
    }
    if (lyricsPluginLaunchAttempts < 20) {
      lyricsPluginLaunchRetry.restart()
      return
    }
    var detail = String(lyricsPluginLaunchStderr.text || "").trim()
    lyricsPluginError = safeError(detail
      || "Omasing está instalado, pero no se pudo abrir su ventana de letras.")
    lyricsPluginPromptRequested(lyricsPluginRequestSurface,
      lyricsPluginAvailability)
  }

  function noteActivity() {
    lastActivityAt = Date.now()
  }

  function cancelVisibleLocalDeviceRefresh() {
    visibleLocalDeviceRefreshTimer.stop()
    visibleLocalDeviceRefreshAttempts = 0
  }

  function ensureVisibleLocalReceiver() {
    var action = Api.visibleLocalReceiverAction(uiVisible,
      fullyConnected && daemonManager.credentialsAvailable,
      daemonManager.running, daemonManager.busy)
    if (action === "idle") {
      cancelVisibleLocalDeviceRefresh()
      return
    }
    if (action === "start") daemonManager.start()
    if (action === "refresh") visibleLocalDeviceRefreshAttempts = 0
    visibleLocalDeviceRefreshTimer.restart()
  }

  function refreshVisibleLocalDevice() {
    var action = Api.visibleLocalReceiverAction(uiVisible,
      fullyConnected && daemonManager.credentialsAvailable,
      daemonManager.running, daemonManager.busy)
    if (action === "idle") {
      cancelVisibleLocalDeviceRefresh()
      return
    }
    if (action !== "refresh") {
      if (action === "start") daemonManager.start()
      visibleLocalDeviceRefreshTimer.restart()
      return
    }
    loadDevices(function() {
      if (!root.uiVisible || !root.fullyConnected || root.localDevice()) {
        root.visibleLocalDeviceRefreshAttempts = 0
        return
      }
      root.visibleLocalDeviceRefreshAttempts++
      if (root.visibleLocalDeviceRefreshAttempts < 8)
        visibleLocalDeviceRefreshTimer.restart()
    })
  }

  function setUiVisible(key, value) {
    var name = String(key || "surface")
    var next = ({})
    for (var oldKey in visibleSurfaces)
      if (oldKey !== name && visibleSurfaces[oldKey]) next[oldKey] = true
    if (value) next[name] = true
    visibleSurfaces = next
    if (value) {
      noteActivity()
      // SpotifyApi restores the keyring-backed session when needed. Do this for
      // every opened surface so the mini-player can discover remote Spotify
      // Connect playback without requiring the full panel to be opened first.
      loadPlaybackState()
    }
  }

  function refreshPosition() {
    if (!useRemotePlayback && activePlayer && activePlayer.positionSupported)
      activePlayer.positionChanged()
    else playbackPositionTick++
  }

  function finishRemotePlaybackWaiters(ok) {
    var pending = remotePlaybackWaiters.slice()
    remotePlaybackWaiters = []
    for (var i = 0; i < pending.length; i++) {
      try { pending[i](ok === true) }
      catch (e) { /* callers own callback errors */ }
    }
  }

  function playbackDeviceKey(device) {
    var item = device || {}
    var id = String(item.id || "")
    if (id) return "id:" + id
    return "name:" + String(item.name || item.sourceName || "").trim().toLowerCase()
      + "|" + String(item.type || "").trim().toLowerCase()
  }

  function rememberRemoteVolume(device, value) {
    var volumePercent = Api.normalizeVolumePercent(value)
    if (!device || volumePercent === null) return false
    rememberedRemoteVolumePercent = volumePercent
    rememberedRemoteVolumeDevice = {
      id: String(device.id || ""),
      name: String(device.name || ""),
      sourceName: String(device.sourceName || device.name || ""),
      type: String(device.type || "")
    }
    return true
  }

  function displayedRemoteVolumePercent(device) {
    if (Api.pendingRemoteVolumeShouldHold(device, pendingRemoteVolume,
        Date.now()))
      return Math.max(0, Math.min(100,
        Number(pendingRemoteVolume.volumePercent) || 0))
    if (rememberedRemoteVolumePercent >= 0 && rememberedRemoteVolumeDevice
        && Api.playbackDevicesMatch(rememberedRemoteVolumeDevice, device))
      return rememberedRemoteVolumePercent
    var reported = Api.normalizeVolumePercent((device || {}).volumePercent)
    return reported === null ? 0 : reported
  }

  function rememberDiscoveredReceiverVolume(device) {
    var receiver = findDiscoveredReceiver(device)
    if (!receiver || String(receiver.brand || "").toLowerCase() !== "sonos")
      return false
    return rememberRemoteVolume(device, receiver.volumePercent)
  }

  function remoteControlDeviceSnapshot(device) {
    var item = device || {}
    return {
      id: String(item.id || ""),
      name: String(item.name || ""),
      sourceName: String(item.sourceName || item.name || ""),
      type: String(item.type || "")
    }
  }

  function beginRemoteSeek(value) {
    var serial = ++remoteControlSerial
    pendingRemoteSeek = {
      serial: serial,
      device: remoteControlDeviceSnapshot(remoteDevice),
      uri: String((remoteTrack && remoteTrack.uri) || ""),
      positionSeconds: Math.max(0, Number(value) || 0),
      requestedAt: Date.now(),
      playing: remotePlayback && remotePlayback.playing === true,
      expiresAt: Date.now() + remoteControlGraceMs
    }
    playbackPositionTick++
    return serial
  }

  function beginRemoteVolume(value) {
    var serial = ++remoteControlSerial
    var volumePercent = Math.max(0, Math.min(100, Number(value) || 0))
    pendingRemoteVolume = {
      serial: serial,
      device: remoteControlDeviceSnapshot(remoteDevice),
      volumePercent: volumePercent,
      expiresAt: Date.now() + remoteControlGraceMs
    }
    rememberRemoteVolume(remoteDevice, volumePercent)
    return serial
  }

  function clearPendingRemoteSeek(serial) {
    if (!pendingRemoteSeek
        || (serial && Number(pendingRemoteSeek.serial) !== Number(serial))) return
    pendingRemoteSeek = null
    playbackPositionTick++
  }

  function clearPendingRemoteVolume(serial) {
    if (!pendingRemoteVolume
        || (serial && Number(pendingRemoteVolume.serial) !== Number(serial))) return
    pendingRemoteVolume = null
  }

  function beginPendingSliderVolume(value) {
    pendingSliderVolume = Math.max(0, Math.min(1, Number(value) || 0))
    pendingSliderUntil = Date.now() + remoteControlGraceMs
    if (volumeHoldTimer) volumeHoldTimer.restart()
  }

  function clearPendingSliderVolume() {
    pendingSliderVolume = -1
    pendingSliderUntil = 0
    if (volumeHoldTimer) volumeHoldTimer.stop()
  }

  function reconcilePendingSliderVolume() {
    if (pendingSliderVolume < 0) return
    if (!Api.pendingSliderVolumeShouldHold(reportedSliderVolume, {
      slider: pendingSliderVolume,
      expiresAt: pendingSliderUntil
    }, Date.now()))
      clearPendingSliderVolume()
  }

  function volumeFlushTarget() {
    if (sonosControlAvailable && sonosControlDevice && sonosControlDevice.id)
      return "sonos"
    return useRemotePlayback ? "remote" : "local"
  }

  // Returns false when the backend could not take the command, so the caller
  // keeps it queued and retries. Only Sonos rejects this way.
  function sendVolumeCommand(sliderValue) {
    var localVolume = !useRemotePlayback && hasLocalPlayer
      && activePlayer.volumeSupported
    var normalized = localVolume
      ? Api.sliderToSpotifydVolume(sliderValue) : sliderValue
    var sonos = volumeFlushTarget() === "sonos"
    if (sonos && spotifyConnectManager.controlBusy) return false
    var remoteSerial = 0
    if (!localVolume && useRemotePlayback && remoteDevice) {
      var remotePercent = Math.round(normalized * 100)
      remoteSerial = beginRemoteVolume(remotePercent)
      var receiver = findDiscoveredReceiver(remoteDevice)
      if (receiver) spotifyConnectManager.rememberVolume(receiver.id, remotePercent)
    }
    if (sendSonosControl("volume", String(Math.round(normalized * 100)))) return true
    if (localVolume)
      activePlayer.volume = normalized
    else apiAction("PUT", "/me/player/volume",
      controlQuery({ volume_percent: Math.round(normalized * 100) }),
      null, "", function(ok) {
      if (!ok) {
        root.clearPendingRemoteVolume(remoteSerial)
        root.clearPendingSliderVolume()
      }
      if (!ok || !root.volumeLiveActive) root.loadPlaybackState()
    })
    return true
  }

  function flushVolume() {
    if (!volumeFlushQueued) {
      volumeFlushCooling = false
      return
    }
    var sliderValue = queuedVolumeSlider
    beginPendingSliderVolume(sliderValue)
    if (sendVolumeCommand(sliderValue)) volumeFlushQueued = false
    volumeFlushCooling = true
    if (volumeFlushTimer) volumeFlushTimer.restart()
  }

  function reconcilePendingRemoteControls(state) {
    var now = Date.now()
    if (pendingRemoteSeek
        && !Api.pendingRemoteSeekShouldHold(state, pendingRemoteSeek, now))
      clearPendingRemoteSeek(Number(pendingRemoteSeek.serial) || 0)
    if (pendingRemoteVolume
        && !Api.pendingRemoteVolumeShouldHold(state ? state.device : null,
          pendingRemoteVolume, now))
      clearPendingRemoteVolume(Number(pendingRemoteVolume.serial) || 0)
  }

  function applyPlaybackState(payload) {
    var state = Api.normalizePlaybackState(payload, 192)
    if (state && state.device) {
      var device = state.device
      device.sourceName = device.name
      device.local = Api.isLocalPlaybackDevice(device, deviceName,
        localRuntimeDeviceName, localDeviceId)
      if (device.local && device.id) {
        localDeviceId = device.id
        localRuntimeDeviceName = device.name
      }
      reconcilePendingRemoteControls(state)
      if (!rememberDiscoveredReceiverVolume(device))
        rememberRemoteVolume(device, device.volumePercent)
    }
    remotePlayback = state
    verifyRadioPlaybackContext()
    var discoveryKey = state && state.device && state.device.active
        && String(state.device.type).toLowerCase() === "speaker"
        && (state.device.restricted
          || Api.spotifyDeviceNameNeedsDiscovery(state.device))
      ? playbackDeviceKey(state.device)
      : ""
    if (discoveryKey && discoveryKey !== remoteControlDiscoveryKey) {
      remoteControlDiscoveryKey = discoveryKey
      if (!findDiscoveredReceiver(state.device) && !spotifyConnectManager.loading)
        spotifyConnectManager.refresh()
    } else if (!discoveryKey) {
      remoteControlDiscoveryKey = ""
    }
    if (state && state.device && state.device.active === true
        && lastError === speakerAvailabilityError()) succeed("")
    playbackPositionTick++
    if (devicesLoaded || apiDevices.length
        || (spotifyConnectManager.devices || []).length) mergeConnectDevices()
    if (state && state.device && state.device.active && !state.device.local
        && !state.device.restricted
        && Api.normalizeVolumePercent(state.device.volumePercent) === null
        && !devicesLoading) {
      var probeKey = playbackDeviceKey(state.device)
      if (probeKey && probeKey !== remoteVolumeProbeKey) {
        remoteVolumeProbeKey = probeKey
        loadDevices()
      }
    }
  }

  function loadPlaybackState(callback, reportError) {
    if (typeof callback === "function") {
      var waiters = remotePlaybackWaiters.slice()
      waiters.push(callback)
      remotePlaybackWaiters = waiters
    }
    if (remotePlaybackLoading) return
    var expected = dataSerial
    remotePlaybackLoading = true
    spotifyApi.request("GET", "/me/player", { additional_types: "episode" }, null,
      function(status, payload, error) {
        root.remotePlaybackLoading = false
        if (expected !== root.dataSerial) {
          root.finishRemotePlaybackWaiters(false)
          return
        }
        if (!error) root.applyPlaybackState(payload)
        else if (reportError === true) root.fail(error)
        root.finishRemotePlaybackWaiters(!error)
      })
  }

  function apiAction(method, path, query, body, successText, callback) {
    noteActivity()
    spotifyApi.request(method, path, query, body, function(status, payload, error) {
      if (error) {
        root.fail(error)
        if (typeof callback === "function") callback(false, payload)
        return
      }
      root.succeed(successText)
      if (typeof callback === "function") callback(true, payload)
    })
  }

  function normalizedView(view) {
    var value = String(view || "search")
    return ["home", "discover", "search", "library", "playlists", "detail", "queue", "devices", "setup"].indexOf(value) >= 0
      ? value : "search"
  }

  // Fetch only the dataset represented by the visible page. An empty but
  // successfully loaded list is tracked separately so revisiting it causes no
  // network request; the explicit refresh control can still force one.
  function openView(view, force) {
    activeView = normalizedView(view)
    if (!authManager.loggedIn && !authManager.tokenIsFresh()) return
    if (activeView === "home" && (force || !homeLoaded))
      loadHome()
    else if (activeView === "discover" && (force || !discoverLoaded))
      loadDiscover()
    else if (activeView === "search" && force && searchQuery)
      search(searchQuery)
    else if (activeView === "library" && (force || !savedTracksLoaded))
      loadSavedTracks(false)
    else if (activeView === "playlists" && (force || !playlistsLoaded))
      loadPlaylists(false)
    else if (activeView === "queue" && (force || !queueLoaded))
      loadQueue()
    else if (activeView === "devices") {
      loadDevices(null, undefined, true)
    }
  }

  function refreshView(view) {
    loadPlaybackState()
    openView(view, true)
  }

  function loadSidebarPlaylists() {
    if (!playlistsLoaded && !playlistsLoading) loadPlaylists(false)
  }

  function loadProfile() {
    if (currentUserId) return
    var expected = dataSerial
    spotifyApi.request("GET", "/me", null, null, function(status, payload, error) {
      if (expected !== root.dataSerial || error || !payload) return
      root.currentUserId = String(payload.id || "")
      root.currentUserName = String(payload.display_name || "")
    })
  }

  function playlistById(id) {
    var key = String(id || "")
    for (var i = 0; i < playlists.length; i++)
      if (String(playlists[i].id || "") === key) return playlists[i]
    return null
  }

  function playlistEditable(item) {
    if (!item || item.type !== "playlist") return false
    return item.collaborative === true
      || playlistOwned(item)
  }

  function playlistOwned(item) {
    return !!item && item.type === "playlist"
      && Api.playlistOwnedByUser(item, currentUserId)
  }

  function editablePlaylists() {
    var result = []
    for (var i = 0; i < playlists.length; i++)
      if (playlistEditable(playlists[i])) result.push(playlists[i])
    return result
  }

  function updatePlaylistSnapshot(id, snapshotId) {
    var key = String(id || "")
    var snapshot = String(snapshotId || "")
    if (!key || !snapshot) return
    function updated(item) {
      if (!item || String(item.id || "") !== key) return item
      var copy = Api.shallowCopy(item)
      copy.snapshotId = snapshot
      return copy
    }
    var next = []
    for (var i = 0; i < playlists.length; i++) next.push(updated(playlists[i]))
    playlists = next
    selectedPlaylist = updated(selectedPlaylist)
    if (detailItem && detailItem.type === "playlist") detailItem = updated(detailItem)
  }

  function sidebarPlaylists() {
    return playlists
  }

  function sidebarSavedAlbums() {
    return savedAlbums
  }

  // Spotify's personalised DJ is only playable in Spotify's official client.
  // Keep it out of this client rather than offering an entry which can never
  // work here.
  function isUnsupportedDjPlaylist(item) {
    return !!item && String(item.id || "") === "37i9dQZF1EYkqdzj48dyYq"
  }

  function supportedPlaylists(items) {
    var rows = Api.arrayValues(items)
    var result = []
    for (var i = 0; i < rows.length; i++)
      if (!isUnsupportedDjPlaylist(rows[i])) result.push(rows[i])
    return result
  }

  function validRadioPlaylist(value) {
    return !!value && value.type === "playlist" && !!value.id && !!value.uri
  }

  function sameRadioPlaylist(left, right) {
    if (!validRadioPlaylist(left) || !validRadioPlaylist(right)) return false
    return String(left.id) === String(right.id)
      || String(left.uri) === String(right.uri)
  }

  function restoreLastRadioPlaylist(value) {
    if (!lastRadioPlaylist && validRadioPlaylist(value))
      lastRadioPlaylist = value
  }

  function rememberRadioPlaylist(value) {
    if (!validRadioPlaylist(value)) return
    lastRadioPlaylist = value
    radioContextSelected = false
    var state = Api.shallowCopy(sessionState)
    state.lastRadioPlaylist = value
    persistSession(state)
  }

  function radioPlaylistForPlayback(item, contextUri, explicitRadio) {
    if (validRadioPlaylist(explicitRadio)) return explicitRadio
    if (!validRadioPlaylist(lastRadioPlaylist)) return null
    if (sameRadioPlaylist(item, lastRadioPlaylist)
        || String(contextUri || "") === String(lastRadioPlaylist.uri))
      return lastRadioPlaylist
    return null
  }

  function verifyRadioPlaybackContext() {
    if (!validRadioPlaylist(lastRadioPlaylist)) {
      radioContextSelected = false
      return
    }
    var expectedPlaylist = lastRadioPlaylist
    var contextUri = remotePlayback ? String(remotePlayback.contextUri || "") : ""
    var contextType = remotePlayback ? String(remotePlayback.contextType || "") : ""
    var contextHref = remotePlayback ? String(remotePlayback.contextHref || "") : ""
    radioContextSelected = contextUri === String(expectedPlaylist.uri)
      || (contextType === "playlist"
        && contextHref.indexOf("/playlists/" + expectedPlaylist.id) >= 0)
  }

  // Restore the keyring-backed session only when a Spotify API surface is
  // actually opened. This avoids a network request when the widget is merely
  // sitting on the bar and local MPRIS controls are sufficient.
  function activate(view) {
    activeView = normalizedView(view)
    authManager.withAccessToken(function(token, error) {
      if (token) {
        root.loadPlaybackState()
        root.loadProfile()
        root.verifyRadioPlaybackContext()
        if (root.catalogCacheApplied) {
          root.loadPlaylists(false)
          if (root.activeView === "home") root.loadHome()
          else if (root.activeView === "library") root.loadSavedTracks(false)
          else root.openView(root.activeView, false)
          // Album cards are cheap to restore and useful even when the user
          // normally starts in Songs. Keep this fetch disposable so it cannot
          // delay a subsequent playback command.
        } else {
          root.loadSidebarPlaylists()
          root.openView(root.activeView, false)
        }
        root.loadSavedAlbums(false, null, undefined, {
          priority: "background", retryRateLimit: false
        })
      }
      else if (error && error !== "Log in to Spotify first") root.fail(error)
    })
  }

  function libraryCollectionSpec(kind) {
    var value = String(kind || "tracks")
    if (value === "playlists")
      return {
        items: "playlists", next: "playlistsNext",
        loading: "playlistsLoading", loaded: "playlistsLoaded",
        path: "/me/playlists", query: { limit: 30 },
        mapper: "playlist", cursor: false, checkSaved: true, mergeDiscover: true
      }
    if (value === "albums")
      return {
        items: "savedAlbums", next: "savedAlbumsNext",
        loading: "savedAlbumsLoading", loaded: "savedAlbumsLoaded",
        path: "/me/albums", query: { limit: 30 },
        mapper: "context", cursor: false
      }
    if (value === "artists")
      return {
        items: "followedArtists", next: "followedArtistsNext",
        loading: "followedArtistsLoading", loaded: "followedArtistsLoaded",
        path: "/me/following", query: { type: "artist", limit: 30 },
        mapper: "context", cursor: true
      }
    if (value === "shows")
      return {
        items: "savedShows", next: "savedShowsNext",
        loading: "savedShowsLoading", loaded: "savedShowsLoaded",
        path: "/me/shows", query: { limit: 30 },
        mapper: "context", cursor: false
      }
    if (value === "episodes")
      return {
        items: "savedEpisodes", next: "savedEpisodesNext",
        loading: "savedEpisodesLoading", loaded: "savedEpisodesLoaded",
        path: "/me/episodes", query: { limit: 30 },
        mapper: "track", cursor: false
      }
    if (value === "audiobooks")
      return {
        items: "savedAudiobooks", next: "savedAudiobooksNext",
        loading: "savedAudiobooksLoading", loaded: "savedAudiobooksLoaded",
        path: "/me/audiobooks", query: { limit: 30 },
        mapper: "context", cursor: false
      }
    return {
      items: "savedTracks", next: "savedTracksNext",
      loading: "savedTracksLoading", loaded: "savedTracksLoaded",
      path: "/me/tracks", query: { limit: 30 },
      mapper: "track", cursor: false
    }
  }

  function libraryMapper(kind) {
    if (kind === "playlist")
      return function(value) { return Api.normalizePlaylist(value, 96) }
    if (kind === "track")
      return function(value) { return Api.normalizeTrack(value, 96) }
    return function(value) { return Api.normalizeContext(value, 96) }
  }

  function loadLibraryCollection(kind, append, callback, serial, requestOptions) {
    var spec = libraryCollectionSpec(kind)
    if (root[spec.loading]) {
      if (typeof callback === "function") callback()
      return
    }
    var path = append ? root[spec.next] : spec.path
    if (!path) {
      if (typeof callback === "function") callback()
      return
    }
    var expected = serial === undefined ? dataSerial : serial
    root[spec.loading] = true
    spotifyApi.request("GET", path, append ? null : spec.query, null,
      function(status, payload, error) {
        root[spec.loading] = false
        if (expected !== root.dataSerial) return
        if (error) root.fail(error)
        else {
          var mapper = root.libraryMapper(spec.mapper)
          var page = spec.cursor
            ? Api.normalizeCursorPage(payload && payload.artists, mapper)
            : Api.normalizePage(payload, mapper)
          var items = (append
            ? Api.mergeUnique(root[spec.items], page.items) : page.items)
            .slice(0, root.cacheLimit)
          if (kind === "playlists") items = root.supportedPlaylists(items)
          root[spec.items] = items
          root[spec.next] = items.length >= root.cacheLimit ? "" : page.next
          root[spec.loaded] = true
          if (spec.checkSaved === true) root.checkSavedItems(page.items)
          else root.markItemsSaved(page.items, true)
          if (spec.mergeDiscover === true
              && (root.discoverLoaded || root.discoverLoading))
            root.mergeDiscoverCandidates(page.items)
          if (kind === "playlists" || kind === "tracks" || kind === "albums")
            root.scheduleCatalogCacheSave()
          if (kind === "playlists") root.schedulePlaylistWarmup()
          if (kind === "albums") root.scheduleAlbumWarmup()
        }
        if (typeof callback === "function") callback()
      }, requestOptions)
  }

  function loadPlaylists(append, callback, serial) {
    loadLibraryCollection("playlists", append, callback, serial)
  }

  function loadMorePlaylists() {
    loadPlaylists(true)
  }

  function loadSavedTracks(append, callback, serial) {
    loadLibraryCollection("tracks", append, callback, serial)
  }

  function setSavedState(uri, value) {
    var key = String(uri || "")
    if (!key) return
    rememberSavedStates([key], value === true)
  }

  function rememberSavedStates(uris, values) {
    var rows = Array.isArray(uris) ? uris : []
    var results = Array.isArray(values) ? values : null
    var checkedAt = Date.now()
    var changed = false
    for (var i = 0; i < rows.length; i++) {
      var key = String(rows[i] || "")
      if (!key) continue
      savedUris[key] = results ? results[i] === true : values === true
      savedUriCheckedAt[key] = checkedAt
      var evicted = Api.touchBoundedOrder(savedUriOrder, key,
        savedUriCacheLimit)
      if (evicted) {
        delete savedUris[evicted]
        delete savedUriCheckedAt[evicted]
      }
      changed = true
    }
    if (changed) savedUrisRevision++
  }

  function savedStateIsFresh(uri, now) {
    var key = String(uri || "")
    if (!key || savedUris[key] === undefined) return false
    return Api.timestampIsFresh(savedUriCheckedAt[key], now,
      savedUriFreshnessMs)
  }

  function markSavedUrisChecking(uris, value) {
    var rows = Array.isArray(uris) ? uris : []
    var changed = false
    for (var i = 0; i < rows.length; i++) {
      var key = String(rows[i] || "")
      if (!key) continue
      if (value === true && savedUrisChecking[key] !== true) {
        savedUrisChecking[key] = true
        changed = true
      } else if (value !== true && savedUrisChecking[key] === true) {
        delete savedUrisChecking[key]
        changed = true
      }
    }
    if (changed) savedUrisCheckingRevision++
  }

  function isSavedChecking(item) {
    return savedUrisCheckingRevision >= 0 && !!item && !!item.uri
      && savedUrisChecking[String(item.uri)] === true
  }

  function setSavedBusy(uri, value) {
    var key = String(uri || "")
    if (!key) return
    if (value === true && savedUrisBusy[key] !== true) {
      savedUrisBusy[key] = true
      savedUrisBusyRevision++
    } else if (value !== true && savedUrisBusy[key] === true) {
      delete savedUrisBusy[key]
      savedUrisBusyRevision++
    }
  }

  function isSavedBusy(item) {
    return savedUrisBusyRevision >= 0 && !!item && !!item.uri
      && savedUrisBusy[String(item.uri)] === true
  }

  function markItemsSaved(items, value) {
    var rows = Array.isArray(items) ? items : []
    var uris = []
    for (var i = 0; i < rows.length; i++)
      if (rows[i] && rows[i].uri) uris.push(String(rows[i].uri))
    rememberSavedStates(uris, value !== false)
  }

  function isSaved(item) {
    return savedUrisRevision >= 0 && !!item && !!item.uri
      && savedUris[String(item.uri)] === true
  }

  function checkSavedItems(items, force) {
    var rows = Array.isArray(items) ? items : []
    var uris = []
    var seen = ({})
    var now = Date.now()
    for (var i = 0; i < rows.length; i++) {
      var uri = String((rows[i] && rows[i].uri) || "")
      if (!uri || seen[uri] || savedUrisChecking[uri] === true
          || (force !== true && savedStateIsFresh(uri, now))) continue
      seen[uri] = true
      uris.push(uri)
    }
    var expected = dataSerial
    markSavedUrisChecking(uris, true)
    for (var start = 0; start < uris.length; start += 40)
      requestContains(uris.slice(start, start + 40), expected)
  }

  function requestContains(chunk, expected) {
    spotifyApi.request("GET", "/me/library/contains", { uris: chunk }, null,
      function(status, payload, error) {
        if (expected !== root.dataSerial) return
        root.markSavedUrisChecking(chunk, false)
        if (error || !Array.isArray(payload)) return
        root.rememberSavedStates(chunk, payload)
      })
  }

  function toggleSaved(item) {
    if (!item || !item.uri || item.type === "chapter" || isSavedBusy(item)) return
    var removing = isSaved(item)
    var track = item.type === "track"
    setSavedBusy(item.uri, true)
    apiAction(removing ? "DELETE" : "PUT", "/me/library", { uris: item.uri }, null,
      track
        ? (removing ? "Quitado de Canciones que te gustan" : "Añadido a Canciones que te gustan")
        : (removing ? "Quitado de tu biblioteca" : "Guardado en tu biblioteca"),
      function(ok) {
        root.setSavedBusy(item.uri, false)
        if (!ok) return
        root.setSavedState(item.uri, !removing)
        if (item.type === "track" && root.savedTracksLoaded) root.loadSavedTracks(false)
        else if (item.type === "album" && root.savedAlbumsLoaded) root.loadSavedAlbums(false)
        else if (item.type === "artist" && root.followedArtistsLoaded) root.loadFollowedArtists(false)
        else if (item.type === "show" && root.savedShowsLoaded) root.loadSavedShows(false)
        else if (item.type === "episode" && root.savedEpisodesLoaded)
          root.loadSavedEpisodes(false)
        else if (item.type === "audiobook" && root.savedAudiobooksLoaded)
          root.loadSavedAudiobooks(false)
        if (item.type === "playlist" && root.playlistsLoaded) root.loadPlaylists(false)
      })
  }

  function syncCurrentTrackSaved(force) {
    var item = currentTrackItem
    if (!uiVisible || !authManager.loggedIn || !item) return
    checkSavedItems([item], force === true)
  }

  function toggleCurrentTrackSaved() {
    if (!currentTrackSaveAvailable) return
    toggleSaved(currentTrackItem)
  }

  function loadSavedAlbums(append, callback, serial, requestOptions) {
    loadLibraryCollection("albums", append, callback, serial, requestOptions)
  }

  function loadFollowedArtists(append) {
    loadLibraryCollection("artists", append)
  }

  function loadSavedShows(append) {
    loadLibraryCollection("shows", append)
  }

  function loadSavedEpisodes(append) {
    loadLibraryCollection("episodes", append)
  }

  function loadSavedAudiobooks(append) {
    loadLibraryCollection("audiobooks", append)
  }

  function libraryItems(kind) {
    var value = String(kind || "tracks")
    if (value === "albums") return savedAlbums
    if (value === "artists") return followedArtists
    if (value === "shows") return savedShows
    if (value === "episodes") return savedEpisodes
    if (value === "audiobooks") return savedAudiobooks
    return savedTracks
  }

  function libraryNext(kind) {
    var value = String(kind || "tracks")
    if (value === "albums") return savedAlbumsNext
    if (value === "artists") return followedArtistsNext
    if (value === "shows") return savedShowsNext
    if (value === "episodes") return savedEpisodesNext
    if (value === "audiobooks") return savedAudiobooksNext
    return savedTracksNext
  }

  function libraryLoading(kind) {
    var value = String(kind || "tracks")
    if (value === "albums") return savedAlbumsLoading
    if (value === "artists") return followedArtistsLoading
    if (value === "shows") return savedShowsLoading
    if (value === "episodes") return savedEpisodesLoading
    if (value === "audiobooks") return savedAudiobooksLoading
    return savedTracksLoading
  }

  function libraryLoaded(kind) {
    var value = String(kind || "tracks")
    if (value === "albums") return savedAlbumsLoaded
    if (value === "artists") return followedArtistsLoaded
    if (value === "shows") return savedShowsLoaded
    if (value === "episodes") return savedEpisodesLoaded
    if (value === "audiobooks") return savedAudiobooksLoaded
    return savedTracksLoaded
  }

  function loadLibrary(kind, append, force) {
    var value = String(kind || "tracks")
    if (append !== true && force !== true && libraryLoaded(value)) return
    loadLibraryCollection(value, append === true)
  }

  function openPlaylist(playlist, restoredItemCount) {
    if (!playlist || !playlist.id) return
    succeed("")
    playlistItemsSerial++
    playlistItemsLoading = false
    playlistRestoreTargetCount = Api.normalizedPlaylistRestoreCount(
      restoredItemCount)
    selectedPlaylist = playlist
    var cached = cachedPlaylistDetail(playlist)
    playlistItems = cached ? Api.arrayValues(cached.items) : []
    playlistItemsNext = ""
    playlistItemsError = ""
    playlistItemsStatus = 0
    loadPlaylistItems(false)
  }

  function loadPlaylistItems(append) {
    if (!selectedPlaylist || !selectedPlaylist.id || playlistItemsLoading) return
    var path = append ? playlistItemsNext
      : "/playlists/" + encodeURIComponent(String(selectedPlaylist.id)) + "/items"
    if (!path) return
    var playlistId = String(selectedPlaylist.id)
    var expected = dataSerial
    var requestSerial = playlistItemsSerial
    playlistItemsLoading = true
    spotifyApi.request("GET", path, append ? null : { limit: 50 }, null,
      function(status, payload, error) {
        if (expected !== root.dataSerial) return
        if (requestSerial !== root.playlistItemsSerial) return
        if (!root.selectedPlaylist || String(root.selectedPlaylist.id) !== playlistId) return
        root.playlistItemsLoading = false
        if (error) {
          root.playlistRestoreTargetCount = 0
          var hidden = Api.playlistItemsHiddenByApi(status,
            root.playlistOwned(root.selectedPlaylist),
            root.selectedPlaylist.collaborative === true,
            root.currentUserId !== "")
          if (!append) {
            root.playlistItemsStatus = status
            root.playlistItemsError = hidden ? "" : error
          }
          if (!hidden || append) root.fail(error)
          return
        }
        var fallbackPosition = append && root.playlistItems.length
          ? Api.playlistPositionAt(root.playlistItems,
            root.playlistItems.length - 1) + 1 : 0
        var responseOffset = Number(payload && payload.offset)
        var nextPlaylistPosition = isFinite(responseOffset)
          ? Math.max(0, Math.floor(responseOffset)) : fallbackPosition
        var page = Api.normalizePage(payload, function(value) {
          var position = nextPlaylistPosition++
          var normalized = Api.normalizeTrack(value, 96)
          if (normalized) normalized.playlistPosition = position
          return normalized
        })
        // A playlist can intentionally contain the same track more than
        // once. Preserve every occurrence so visible indexes continue to
        // match the positions accepted by Spotify's reorder endpoint.
        root.playlistItemsError = ""
        root.playlistItemsStatus = status
        var playlistPage = Api.playlistPageState(root.playlistItems, page.items,
          append, page.next)
        root.playlistItems = playlistPage.items
        root.playlistItemsNext = playlistPage.next
        if (!append) root.rememberPlaylistDetail(root.selectedPlaylist,
          root.playlistItems)
        if (Api.playlistRestoreShouldContinue(root.playlistItems.length,
            root.playlistRestoreTargetCount, root.playlistItemsNext))
          root.loadPlaylistItems(true)
        else root.playlistRestoreTargetCount = 0
      })
  }

  function loadMorePlaylistItems() {
    loadPlaylistItems(true)
  }

  function ensurePlaylistItemCount(value) {
    if (!selectedPlaylist || !selectedPlaylist.id) return
    var target = Api.normalizedPlaylistRestoreCount(value)
    if (target <= playlistItems.length) return
    playlistRestoreTargetCount = Math.max(playlistRestoreTargetCount, target)
    if (playlistItemsLoading) return
    if (playlistItems.length === 0) loadPlaylistItems(false)
    else if (playlistItemsNext) loadPlaylistItems(true)
    else playlistRestoreTargetCount = 0
  }

  function createPlaylist(name, callback) {
    var normalized = String(name || "").trim()
    if (!normalized || playlistActionBusy) return
    playlistActionBusy = true
    spotifyApi.request("POST", "/me/playlists", null, {
      name: normalized.slice(0, 100),
      "public": false,
      description: "Created with Omarchy Spotify"
    }, function(status, payload, error) {
      root.playlistActionBusy = false
      if (error) { root.fail(error); return }
      var playlist = Api.normalizePlaylist(payload, 96)
      if (playlist) {
        root.playlists = [playlist].concat(root.playlists)
        root.setSavedState(playlist.uri, true)
        root.succeed("Lista creada")
        if (typeof callback === "function") callback(playlist)
      }
    })
  }

  function addItemToPlaylist(item, playlist) {
    if (!item || ["track", "episode"].indexOf(item.type) < 0 || !item.uri
        || !playlist || !playlist.id
        || playlistActionBusy) return
    playlistActionBusy = true
    spotifyApi.request("POST", "/playlists/" + encodeURIComponent(String(playlist.id)) + "/items",
      null, { uris: [item.uri] }, function(status, payload, error) {
        root.playlistActionBusy = false
        if (error) { root.fail(error); return }
        root.updatePlaylistSnapshot(playlist.id, payload && payload.snapshot_id)
        root.succeed("Añadido a " + String(playlist.name || "la lista"))
        if (root.selectedPlaylist && root.selectedPlaylist.id === playlist.id)
          root.loadPlaylistItems(false)
        if (root.detailItem && root.detailItem.id === playlist.id) root.openDetail(root.detailItem)
      })
  }

  function registerPlaylistCopy(playlist) {
    if (!playlist) return
    var next = [playlist]
    for (var i = 0; i < playlists.length; i++)
      if (String(playlists[i].id || "") !== String(playlist.id || ""))
        next.push(playlists[i])
    playlists = next
    setSavedState(playlist.uri, true)
  }

  function finishPlaylistConversion(error) {
    playlistConversionBusy = false
    playlistActionBusy = false
    statusMessage = ""
    if (error) fail(error)
  }

  function collectPlaylistForCopy(playlist, path, collected, expected, callback) {
    var first = !path
    var requestPath = path || "/playlists/" + encodeURIComponent(String(playlist.id)) + "/items"
    spotifyApi.request("GET", requestPath, first ? { limit: 50 } : null, null,
      function(status, payload, error) {
        if (expected !== root.dataSerial) return
        if (error) { callback([], error); return }
        if (!payload || !Array.isArray(payload.items)) {
          callback([], "Spotify no permite copiar las canciones de esta lista. El original se ha dejado intacto.")
          return
        }
        var page = Api.normalizePage(payload, function(value) {
          return Api.normalizeTrack(value, 96)
        })
        var combined = collected.concat(page.items)
        if (page.next && combined.length < 10000) {
          root.collectPlaylistForCopy(playlist, page.next, combined, expected, callback)
          return
        }
        if (page.next) {
          callback([], "Esta lista es demasiado grande para copiarla con seguridad")
          return
        }
        callback(combined, "")
      })
  }

  function addPlaylistCopyBatches(playlist, uris, offset, expected, callback) {
    if (expected !== dataSerial) return
    if (offset >= uris.length) { callback(""); return }
    var batch = uris.slice(offset, Math.min(offset + 100, uris.length))
    spotifyApi.request("POST", "/playlists/" + encodeURIComponent(String(playlist.id)) + "/items",
      null, { uris: batch }, function(status, payload, error) {
        if (expected !== root.dataSerial) return
        if (error) { callback(error); return }
        root.updatePlaylistSnapshot(playlist.id, payload && payload.snapshot_id)
        root.addPlaylistCopyBatches(playlist, uris, offset + batch.length, expected, callback)
      })
  }

  function removeOriginalAfterCopy(original, copy, expected, callback) {
    spotifyApi.request("DELETE", "/me/library", { uris: original.uri }, null,
      function(status, payload, error) {
        if (expected !== root.dataSerial) return
        if (error) {
          root.finishPlaylistConversion("Tu copia está lista, pero Spotify no pudo quitar el original de tu biblioteca")
          return
        }
        var next = []
        for (var i = 0; i < root.playlists.length; i++) {
          var candidate = root.playlists[i]
          if (String(candidate.id || "") !== String(original.id || "")) next.push(candidate)
        }
        root.playlists = next
        root.setSavedState(original.uri, false)
        root.finishPlaylistConversion("")
        root.succeed("Tu lista está lista")
        if (typeof callback === "function") callback(copy)
      })
  }

  function makePlaylistYourOwn(playlist, callback) {
    if (!playlist || playlist.type !== "playlist" || !playlist.id || !playlist.uri
        || playlistOwned(playlist) || playlistActionBusy || !currentUserId) return
    var expected = dataSerial
    playlistActionBusy = true
    playlistConversionBusy = true
    lastError = ""
    statusClearTimer.stop()
    statusMessage = "Leyendo " + String(playlist.name || "la lista") + "…"
    collectPlaylistForCopy(playlist, "", [], expected, function(items, readError) {
      if (readError) { root.finishPlaylistConversion(readError); return }
      var uris = Api.playlistItemUris(items)
      if (Number(playlist.total || 0) > 0 && uris.length === 0) {
        root.finishPlaylistConversion("Spotify no permite copiar las canciones de esta lista. El original se ha dejado intacto.")
        return
      }
      root.statusMessage = "Creando tu lista…"
      spotifyApi.request("POST", "/me/playlists", null, {
        name: String(playlist.name || "Mi lista").slice(0, 100),
        "public": false,
        description: "Tu copia, creada con Omarchy Spotify"
      }, function(status, payload, createError) {
        if (expected !== root.dataSerial) return
        if (createError) { root.finishPlaylistConversion(createError); return }
        var copy = Api.normalizePlaylist(payload, 96)
        if (!copy) {
          root.finishPlaylistConversion("Spotify creó la lista, pero no se pudo abrir")
          return
        }
        root.registerPlaylistCopy(copy)
        root.statusMessage = "Copiando " + uris.length + (uris.length === 1 ? " elemento…" : " elementos…")
        root.addPlaylistCopyBatches(copy, uris, 0, expected, function(copyError) {
          if (copyError) {
            root.finishPlaylistConversion("La nueva lista se creó, pero Spotify se detuvo antes de copiar todos los elementos. Se conservó el original.")
            return
          }
          root.statusMessage = "Quitando el original de tu biblioteca…"
          root.removeOriginalAfterCopy(playlist, copy, expected, callback)
        })
      })
    })
  }

  function reloadPlaylist(playlist) {
    if (!playlist) return
    var restoredDetailItemCount = detailRememberedItemCount
    if (selectedPlaylist && selectedPlaylist.id === playlist.id) {
      var restoredItemCount = playlistRememberedItemCount
      playlistItemsSerial++
      playlistItemsLoading = false
      playlistRestoreTargetCount = restoredItemCount
      playlistItems = []
      playlistItemsNext = ""
      playlistItemsError = ""
      playlistItemsStatus = 0
      loadPlaylistItems(false)
    }
    if (detailItem && detailItem.type === "playlist" && detailItem.id === playlist.id)
      openDetail(detailItem, "", restoredDetailItemCount)
  }

  function removePlaylistItem(item, index, playlist) {
    var target = playlist || selectedPlaylist
    if (!item || !item.uri || !playlistEditable(target) || playlistActionBusy) return
    playlistActionBusy = true
    var body = { items: [{ uri: item.uri }] }
    if (target.snapshotId) body.snapshot_id = target.snapshotId
    spotifyApi.request("DELETE", "/playlists/" + encodeURIComponent(String(target.id)) + "/items",
      null, body, function(status, payload, error) {
        root.playlistActionBusy = false
        if (error) { root.fail(error); return }
        root.updatePlaylistSnapshot(target.id, payload && payload.snapshot_id)
        root.succeed("Quitado de la lista")
        root.reloadPlaylist(target)
      })
  }

  function requestPlaylistItemReorder(sourceIndex, destinationIndex, playlist, count,
      sourceItems) {
    var target = playlist || selectedPlaylist
    if (!playlistEditable(target) || playlistActionBusy) return
    var length = Math.max(0, Math.floor(Number(count) || playlistItems.length))
    var playlistId = String(target.id || "")
    var selectedMatches = selectedPlaylist
      && String(selectedPlaylist.id || "") === playlistId
    var detailMatches = detailItem && detailItem.type === "playlist"
      && String(detailItem.id || "") === playlistId
    var orderingItems = Array.isArray(sourceItems) ? sourceItems
      : (selectedMatches ? playlistItems : (detailMatches ? detailItems : []))
    var body = orderingItems.length
      ? Api.playlistReorderBodyForItems(orderingItems, sourceIndex,
        destinationIndex, Math.max(length, Number(target.total) || 0),
        target.snapshotId)
      : Api.playlistReorderBody(sourceIndex, destinationIndex, length,
        target ? target.snapshotId : "")
    if (!body) return

    var sourcePosition = orderingItems.length
      ? Api.playlistPositionAt(orderingItems, sourceIndex) : sourceIndex
    var destinationPosition = orderingItems.length
      ? Api.playlistPositionAt(orderingItems, destinationIndex) : destinationIndex
    var previousPlaylistItems = playlistItems
    var previousDetailItems = detailItems
    if (selectedMatches)
      playlistItems = Api.reorderedPlaylistItemsAtPositions(playlistItems,
        sourcePosition, destinationPosition)
    if (detailMatches)
      detailItems = Api.reorderedPlaylistItemsAtPositions(detailItems,
        sourcePosition, destinationPosition)

    playlistActionBusy = true
    spotifyApi.request("PUT", "/playlists/" + encodeURIComponent(String(target.id)) + "/items",
      null, body, function(status, payload, error) {
        root.playlistActionBusy = false
        if (error) {
          if (selectedMatches && root.selectedPlaylist
              && String(root.selectedPlaylist.id || "") === playlistId)
            root.playlistItems = previousPlaylistItems
          if (detailMatches && root.detailItem && root.detailItem.type === "playlist"
              && String(root.detailItem.id || "") === playlistId)
            root.detailItems = previousDetailItems
          root.fail(error)
          return
        }
        root.updatePlaylistSnapshot(target.id, payload && payload.snapshot_id)
        root.succeed("Orden de la lista actualizado")
      })
  }

  function reorderPlaylistItem(sourceIndex, destinationIndex, playlist, count,
      sourceItems) {
    var target = playlist || selectedPlaylist
    if (!playlistOwned(target)) return
    requestPlaylistItemReorder(sourceIndex, destinationIndex, target, count,
      sourceItems)
  }

  function movePlaylistItem(index, delta, playlist, count) {
    var source = Math.max(0, Math.floor(Number(index) || 0))
    var direction = Number(delta || 0) < 0 ? -1 : 1
    requestPlaylistItemReorder(source, source + direction,
      playlist || selectedPlaylist, count)
  }

  function detailPageFromPayload(payload, type, parent) {
    var container = payload || {}
    if (type === "album") container = payload && payload.tracks ? payload.tracks : container
    else if (type === "playlist")
      container = payload && (payload.items || payload.tracks) ? (payload.items || payload.tracks) : container
    else if (type === "show") container = payload && payload.episodes ? payload.episodes : container
    else if (type === "audiobook")
      container = payload && payload.chapters ? payload.chapters : container
    var nextPlaylistPosition = Math.max(0,
      Math.floor(Number(container.offset) || 0))
    return Api.normalizePage(container, function(value) {
      var position = nextPlaylistPosition++
      var normalized = type === "artist" ? Api.normalizeContext(value, 96)
        : Api.normalizeTrack(value, 96, parent)
      if (normalized && type === "playlist")
        normalized.playlistPosition = position
      return normalized
    })
  }

  function openDetail(item, requestedArtistQuery, restoredItemCount) {
    if (!item || !item.id || item.kind !== "context") return
    var type = String(item.type || "")
    if (["artist", "album", "playlist", "show", "audiobook"].indexOf(type) < 0) return
    var serial = ++detailSerial
    detailRestoreTargetCount = type === "playlist" ? Math.min(cacheLimit,
      Api.normalizedPlaylistRestoreCount(restoredItemCount)) : 0
    detailItem = item
    detailItems = []
    detailNext = ""
    detailMessage = ""
    artistCatalogSerial++
    var initialArtistQuery = type === "artist" ? String(requestedArtistQuery || "") : ""
    artistCatalogQuery = initialArtistQuery
    artistAlbums = []
    artistAlbumsNext = ""
    artistAlbumsLoading = false
    artistSongs = []
    artistSongsNext = ""
    artistSongsLoading = false
    artistPlaylists = []
    artistPlaylistsNext = ""
    artistPlaylistsLoading = false
    artistThisIsPlaylist = null
    artistThisIsLoading = false
    detailLoading = true
    activeView = "detail"
    checkSavedItems([item])

    var cachedAlbum = type === "album" ? cachedAlbumDetail(item) : null
    if (cachedAlbum) {
      detailItems = Api.arrayValues(cachedAlbum.items)
      detailLoading = false
      return
    }

    var metadataPath = "/" + (type === "show" ? "shows" : type === "audiobook"
      ? "audiobooks" : type + "s") + "/" + encodeURIComponent(String(item.id))
    spotifyApi.request("GET", metadataPath, null, null, function(status, payload, error) {
      if (serial !== root.detailSerial) return
      if (error) {
        root.detailRestoreTargetCount = 0
        root.detailLoading = false
        root.fail(error)
        return
      }
      var normalized = Api.normalizeContext(payload, 256)
      if (normalized) root.detailItem = normalized
      var parent = root.detailItem || item
      if (type === "artist") {
        root.loadArtistThisIs(serial, parent)
        root.findArtistMusic(initialArtistQuery, serial, parent)
        return
      }
      var page = root.detailPageFromPayload(payload, type, parent)
      root.detailItems = page.items.slice(0, root.cacheLimit)
      root.detailNext = page.next
      root.detailLoading = false
      root.checkSavedItems(root.detailItems)
      if (type === "album") root.rememberAlbumDetail(root.detailItem, root.detailItems)
      if (type === "playlist" && Api.playlistRestoreShouldContinue(
          root.detailItems.length, root.detailRestoreTargetCount,
          root.detailNext)) root.loadMoreDetail()
      else root.detailRestoreTargetCount = 0
      if (type === "playlist" && !payload.items && !payload.tracks)
        root.detailMessage = Api.playlistItemsHiddenMessage()
    }, { priority: "interactive" })
  }

  function loadArtistThisIs(expectedDetail, artist) {
    if (!artist || artist.type !== "artist" || !artist.name) return
    artistThisIsPlaylist = null
    artistThisIsLoading = true
    spotifyApi.request("GET", "/search", {
      q: "This Is " + String(artist.name),
      type: "playlist",
      limit: 10
    }, null, function(status, payload, error) {
      if (expectedDetail !== root.detailSerial) return
      root.artistThisIsLoading = false
      if (error) return
      var page = Api.normalizeSearchPage(payload, "playlist", 128)
      root.artistThisIsPlaylist = Api.findThisIsPlaylist(page.items, artist.name)
      if (root.artistThisIsPlaylist) root.checkSavedItems([root.artistThisIsPlaylist])
    })
  }

  function findArtistMusic(query, serial, artist) {
    var parent = artist || detailItem
    if (!parent || parent.type !== "artist" || !parent.name) return
    var expectedDetail = serial === undefined ? detailSerial : serial
    var expectedCatalog = ++artistCatalogSerial
    artistCatalogQuery = String(query || "").trim()
    artistAlbums = []
    artistAlbumsNext = ""
    artistAlbumsLoading = false
    artistSongs = []
    artistSongsNext = ""
    artistSongsLoading = false
    artistPlaylists = []
    artistPlaylistsNext = ""
    artistPlaylistsLoading = false
    detailMessage = ""
    detailLoading = true
    requestArtistCatalog("album", false, expectedDetail, expectedCatalog, parent)
    if (artistCatalogQuery) {
      requestArtistCatalog("track", false, expectedDetail, expectedCatalog, parent)
      requestArtistCatalog("playlist", false, expectedDetail, expectedCatalog, parent)
    } else requestArtistTopSongs(false, expectedDetail, expectedCatalog, parent, 0)
  }

  function requestArtistCatalog(type, append, expectedDetail, expectedCatalog, artist) {
    var albums = type === "album"
    var playlists = type === "playlist"
    var path = append ? (albums ? artistAlbumsNext
      : (playlists ? artistPlaylistsNext : artistSongsNext)) : "/search"
    if (!path) return
    if (albums) artistAlbumsLoading = true
    else if (playlists) artistPlaylistsLoading = true
    else artistSongsLoading = true
    var query = append ? null : {
      q: playlists
        ? Api.artistPlaylistSearchText(artist.name, artistCatalogQuery)
        : Api.catalogSearchText(artist.name, artistCatalogQuery),
      type: type,
      limit: 10
    }
    spotifyApi.request("GET", path, query, null, function(status, payload, error) {
      if (expectedDetail !== root.detailSerial || expectedCatalog !== root.artistCatalogSerial)
        return
      if (albums) root.artistAlbumsLoading = false
      else if (playlists) root.artistPlaylistsLoading = false
      else root.artistSongsLoading = false
      root.detailLoading = root.artistCatalogLoading
      if (error) { root.fail(error); return }
      root.applyArtistCatalogPage(type, append,
        Api.normalizeSearchPage(payload, type, 96))
    })
  }

  function applyArtistCatalogPage(type, append, page) {
    var existing = type === "album" ? artistAlbums
      : (type === "playlist" ? artistPlaylists : artistSongs)
    var items = (append ? Api.mergeUnique(existing, page.items) : page.items)
      .slice(0, cacheLimit)
    var next = items.length >= cacheLimit ? "" : page.next
    if (type === "album") {
      artistAlbums = items
      artistAlbumsNext = next
    } else if (type === "playlist") {
      artistPlaylists = items
      artistPlaylistsNext = next
    } else {
      artistSongs = items
      artistSongsNext = next
    }
    checkSavedItems(page.items)
  }

  function requestArtistTopSongs(append, expectedDetail, expectedCatalog, artist,
      automaticPage) {
    var path = append ? artistSongsNext : "/search"
    if (!path) return
    var automaticDepth = Math.max(0, Number(automaticPage) || 0)
    artistSongsLoading = true
    var query = append ? null : {
      q: String(artist.name || ""),
      type: "track",
      limit: 10
    }
    spotifyApi.request("GET", path, query, null, function(status, payload, error) {
      if (expectedDetail !== root.detailSerial || expectedCatalog !== root.artistCatalogSerial)
        return
      if (error) {
        root.artistSongsLoading = false
        root.detailLoading = root.artistCatalogLoading
        root.fail(error)
        return
      }
      var page = Api.normalizeSearchPage(payload, "track", 96)
      var matching = Api.tracksForArtist(page.items, artist)
      root.artistSongs = Api.mergeUnique(append ? root.artistSongs : [], matching).slice(0, 10)
      root.checkSavedItems(matching)
      if (root.artistSongs.length < 10 && page.next && automaticDepth < 5) {
        root.artistSongsNext = page.next
        root.requestArtistTopSongs(true, expectedDetail, expectedCatalog,
          artist, automaticDepth + 1)
        return
      }
      root.artistSongsNext = ""
      root.artistSongsLoading = false
      root.detailLoading = root.artistCatalogLoading
    })
  }

  function loadMoreArtistAlbums() {
    if (!artistAlbumsNext || artistAlbumsLoading || !detailItem) return
    requestArtistCatalog("album", true, detailSerial, artistCatalogSerial, detailItem)
  }

  function loadMoreArtistSongs() {
    if (!artistSongsNext || artistSongsLoading || !detailItem) return
    requestArtistCatalog("track", true, detailSerial, artistCatalogSerial, detailItem)
  }

  function loadMoreArtistPlaylists() {
    if (!artistPlaylistsNext || artistPlaylistsLoading || !detailItem) return
    requestArtistCatalog("playlist", true, detailSerial, artistCatalogSerial,
      detailItem)
  }

  function loadMoreDetail() {
    var path = detailNext
    var parent = detailItem
    if (!path || !parent || detailLoading) return
    var serial = detailSerial
    var type = String(parent.type || "")
    if (type === "artist") return
    detailLoading = true
    spotifyApi.request("GET", path, null, null, function(status, payload, error) {
      if (serial !== root.detailSerial) return
      root.detailLoading = false
      if (error) {
        root.detailRestoreTargetCount = 0
        root.fail(error)
        return
      }
      var page = root.detailPageFromPayload(payload, type, parent)
      root.detailItems = (type === "playlist"
        ? root.detailItems.concat(page.items)
        : Api.mergeUnique(root.detailItems, page.items)).slice(0, root.cacheLimit)
      root.detailNext = root.detailItems.length >= root.cacheLimit ? "" : page.next
      root.checkSavedItems(page.items)
      if (type === "playlist" && Api.playlistRestoreShouldContinue(
          root.detailItems.length, root.detailRestoreTargetCount,
          root.detailNext)) root.loadMoreDetail()
      else root.detailRestoreTargetCount = 0
    })
  }

  function ensureDetailItemCount(value) {
    if (!detailItem || detailItem.type !== "playlist") return
    var target = Math.min(cacheLimit, Api.normalizedPlaylistRestoreCount(value))
    if (target <= detailItems.length) return
    detailRestoreTargetCount = Math.max(detailRestoreTargetCount, target)
    if (detailLoading) return
    if (detailNext) loadMoreDetail()
    else detailRestoreTargetCount = 0
  }

  function currentContext(kind, callback) {
    if (typeof callback !== "function") return
    if (kind === "artist" && currentArtists.length) {
      var cachedArtist = currentArtists[0]
      if (cachedArtist.id) callback(cachedArtist)
      else resolveArtist(cachedArtist.name, callback)
      return
    }
    if (kind === "album" && currentAlbumItem && currentAlbumItem.id) {
      callback(currentAlbumItem)
      return
    }
    var id = currentTrackId
    if (!id) {
      if (kind === "artist" && currentArtistContextAvailable)
        resolveArtist(artist, callback)
      return
    }
    spotifyApi.request("GET", "/tracks/" + encodeURIComponent(id), null, null,
      function(status, payload, error) {
        if (error) { root.fail(error); return }
        var track = Api.normalizeTrack(payload, 128)
        if (!track) return
        if (kind === "album" && track.albumItem) callback(track.albumItem)
        else if (kind === "artist" && track.artists.length) callback(track.artists[0])
      })
  }

  function resolveArtist(name, callback) {
    var term = String(name || "").trim()
    if (!term || typeof callback !== "function") return
    spotifyApi.request("GET", "/search", {
      q: term,
      type: "artist",
      limit: 10
    }, null, function(status, payload, error) {
      if (error) { root.fail(error); return }
      var page = Api.normalizeSearchPage(payload, "artist", 128)
      var match = Api.artistForName(page.items, term)
      if (!match) {
        root.fail("Spotify no pudo encontrar ese artista")
        return
      }
      root.checkSavedItems([match])
      callback(match)
    })
  }

  function finishHomeRequest(error) {
    homeRequestsPending = Math.max(0, homeRequestsPending - 1)
    if (error) fail(error)
    if (homeRequestsPending === 0) {
      homeLoaded = true
      checkSavedItems(recentTracks.concat(topTracks).concat(topArtists))
      scheduleCatalogCacheSave()
    }
  }

  function loadHome() {
    if (homeLoading) return
    var expected = dataSerial
    homeLoaded = false
    homeRequestsPending = 3
    spotifyApi.request("GET", "/me/player/recently-played", { limit: 30 }, null,
      function(status, payload, error) {
        if (expected !== root.dataSerial) return
        if (!error) {
          var page = Api.normalizePage(payload, function(value) {
            return Api.normalizeTrack(value, 96)
          })
          root.recentTracks = page.items
        }
        root.finishHomeRequest(error)
      })
    spotifyApi.request("GET", "/me/top/tracks", {
      limit: 30, time_range: "medium_term"
    }, null, function(status, payload, error) {
      if (expected !== root.dataSerial) return
      if (!error) {
        var page = Api.normalizePage(payload, function(value) {
          return Api.normalizeTrack(value, 96)
          })
          root.topTracks = page.items
      }
      root.finishHomeRequest(error)
    })
    spotifyApi.request("GET", "/me/top/artists", {
      limit: 30, time_range: "medium_term"
    }, null, function(status, payload, error) {
      if (expected !== root.dataSerial) return
      if (!error) {
        var page = Api.normalizePage(payload, function(value) {
          return Api.normalizeContext(value, 96)
          })
          root.topArtists = page.items
      }
      root.finishHomeRequest(error)
    })
  }

  function homeItems(kind) {
    var value = String(kind || "recent")
    if (value === "tracks") return topTracks
    if (value === "artists") return topArtists
    return recentTracks
  }

  function mergeDiscoverCandidates(items) {
    discoverCandidates = Api.mergeUnique(discoverCandidates, items)
    discoverPlaylists = Api.discoveryPlaylists(discoverCandidates, 24)
  }

  function finishDiscoverRequest(error) {
    if (error) discoverRequestsFailed++
    discoverRequestsPending = Math.max(0, discoverRequestsPending - 1)
    if (discoverRequestsPending > 0) return
    discoverLoaded = true
    checkSavedItems(discoverPlaylists)
    if (!discoverPlaylists.length) {
      discoverMessage = discoverRequestsFailed >= Api.DISCOVERY_SEARCHES.length
        ? "Spotify no pudo cargar las listas de descubrimiento. Prueba a actualizar."
        : "Spotify aún no ha devuelto listas personales de descubrimiento. Prueba a actualizar más tarde."
    }
  }

  function requestDiscoverPlaylistSearch(term, expectedData, expectedDiscover) {
    spotifyApi.request("GET", "/search", {
      q: String(term || ""),
      type: "playlist",
      limit: 10
    }, null, function(status, payload, error) {
      if (expectedData !== root.dataSerial || expectedDiscover !== root.discoverSerial)
        return
      if (!error) {
        var page = Api.normalizeSearchPage(payload, "playlist", 128)
        root.mergeDiscoverCandidates(page.items)
      }
      root.finishDiscoverRequest(error)
    })
  }

  function loadDiscover() {
    if (discoverLoading) return
    var expectedData = dataSerial
    var expectedDiscover = ++discoverSerial
    discoverLoaded = false
    discoverMessage = ""
    discoverRequestsFailed = 0
    discoverCandidates = playlists.slice()
    discoverPlaylists = Api.discoveryPlaylists(discoverCandidates, 24)
    discoverRequestsPending = Api.DISCOVERY_SEARCHES.length
    if (!discoverRequestsPending) {
      discoverLoaded = true
      return
    }
    for (var i = 0; i < Api.DISCOVERY_SEARCHES.length; i++)
      requestDiscoverPlaylistSearch(Api.DISCOVERY_SEARCHES[i], expectedData, expectedDiscover)
  }

  function findDiscoveredReceiver(playbackDevice) {
    var target = playbackDevice || null
    if (!target) return null
    var receivers = spotifyConnectManager.devices || []
    for (var i = 0; i < receivers.length; i++) {
      var receiver = receivers[i]
      if (receiver && receiver.id && Api.playbackDevicesMatch(receiver, target))
        return receiver
    }
    return null
  }

  function findSonosControlDevice() {
    var receiver = findDiscoveredReceiver(remoteDevice)
    return receiver && String(receiver.brand || "").toLowerCase() === "sonos"
      ? receiver : null
  }

  function normalizeDevice(value) {
    var item = value || {}
    var rawName = String(item.name || "Spotify device")
    var id = String(item.id || "")
    var local = Api.isLocalPlaybackDevice({ id: id, name: rawName },
      deviceName, localRuntimeDeviceName, localDeviceId)
    if (local) {
      if (id) localDeviceId = id
      if (rawName === deviceName || !localRuntimeDeviceName)
        localRuntimeDeviceName = rawName
    }
    return {
      id: id,
      name: local ? deviceName : rawName,
      sourceName: rawName,
      type: String(item.type || "unknown"),
      active: item.is_active === true,
      restricted: item.is_restricted === true,
      volumePercent: Api.normalizeVolumePercent(item.volume_percent),
      supportsVolume: item.supports_volume === true,
      brand: "",
      model: "",
      local: local,
      localDiscovery: false,
      activationRequired: false,
      tokenType: "default",
      description: ""
    }
  }

  function mergeConnectDevices() {
    var local = spotifyConnectManager.devices || []
    var current = remoteDevice && remoteDevice.active === true ? remoteDevice : null
    var currentVolume = Api.normalizeVolumePercent(
      current ? current.volumePercent : null)
    var localVolumePreferred = current
      ? rememberDiscoveredReceiverVolume(current) : false
    if (current && !localVolumePreferred && currentVolume !== null)
      rememberRemoteVolume(current, currentVolume)
    var currentMatched = false
    var localById = ({})
    for (var i = 0; i < local.length; i++) localById[String(local[i].id || "")] = local[i]
    var next = []
    var present = ({})
    for (var j = 0; j < apiDevices.length && next.length < 32; j++) {
      var sourceDevice = apiDevices[j]
      var apiDevice = Api.shallowCopy(sourceDevice)
      var discovered = localById[String(apiDevice.id || "")]
      if (discovered) {
        if (!apiDevice.local) apiDevice.name = discovered.name
        apiDevice.description = discovered.description
        apiDevice.localDiscovery = true
        apiDevice.activationRequired = false
        apiDevice.tokenType = discovered.tokenType
        apiDevice.brand = discovered.brand
        apiDevice.model = discovered.model
        if (String(discovered.brand || "").toLowerCase() === "sonos"
            && Api.normalizeVolumePercent(discovered.volumePercent) !== null)
          apiDevice.volumePercent = discovered.volumePercent
      }
      if (current) {
        var apiCurrentMatch = Api.playbackDevicesMatch(apiDevice, current)
        apiDevice.active = apiCurrentMatch
        if (apiCurrentMatch) {
          currentMatched = true
          // /me/player is the freshest source for the active receiver. The
          // separately cached device list is only a fallback when that value
          // is unknown; otherwise it can undo an accepted volume command.
          if (!localVolumePreferred && currentVolume === null)
            rememberRemoteVolume(current, apiDevice.volumePercent)
          apiDevice.restricted = current.restricted === true
          apiDevice.volumePercent = displayedRemoteVolumePercent(current)
          apiDevice.supportsVolume = current.supportsVolume === true
        }
      }
      present[String(apiDevice.id || "")] = true
      next.push(apiDevice)
    }
    for (var k = 0; k < local.length && next.length < 32; k++) {
      var item = local[k]
      if (present[String(item.id || "")]) continue
      var rawName = String(item.name || "Dispositivo de Spotify Connect")
      var isLocal = Api.isLocalPlaybackDevice({ id: item.id, name: rawName },
        deviceName, localRuntimeDeviceName, localDeviceId)
      if (isLocal) {
        localDeviceId = String(item.id || localDeviceId)
        if (rawName === deviceName || !localRuntimeDeviceName)
          localRuntimeDeviceName = rawName
      }
      var currentMatch = !!current && !currentMatched
        && Api.playbackDevicesMatch(item, current)
      if (currentMatch) currentMatched = true
      next.push({
        id: String(item.id || ""),
        name: isLocal ? deviceName : rawName,
        sourceName: rawName,
        type: String(item.type || "Altavoz"),
        active: currentMatch,
        restricted: currentMatch && current.restricted === true,
        volumePercent: currentMatch ? displayedRemoteVolumePercent(current)
          : (Api.normalizeVolumePercent(item.volumePercent) === null
            ? 0 : item.volumePercent),
        supportsVolume: currentMatch && current.supportsVolume === true,
        local: isLocal,
        localDiscovery: true,
        activationRequired: !currentMatch,
        activeUser: item.activeUser === true || currentMatch,
        tokenType: Api.spotifyConnectTokenType(item.tokenType),
        brand: String(item.brand || ""),
        model: String(item.model || ""),
        description: String(item.description || "")
      })
    }
    if (current && !currentMatched && next.length < 32) {
      next.push({
        id: String(current.id || ""),
        name: String(current.name || "Active Spotify device"),
        sourceName: String(current.name || "Active Spotify device"),
        type: String(current.type || "unknown"),
        active: true,
        restricted: current.restricted === true,
        volumePercent: displayedRemoteVolumePercent(current),
        supportsVolume: current.supportsVolume === true,
        local: remotePlaybackIsLocal,
        localDiscovery: false,
        activationRequired: false,
        activeUser: true,
        tokenType: "default",
        brand: "",
        model: "",
        description: ""
      })
    }
    devices = next
    var explicitActiveReceiver = null
    if (selectedDeviceExplicit) {
      for (var selectedIndex = 0; selectedIndex < next.length; selectedIndex++) {
        var selectedItem = next[selectedIndex]
        if (selectedItem.id === selectedDeviceId && selectedItem.active
            && selectedItem.localDiscovery
            && String(selectedItem.brand || "").toLowerCase() === "sonos") {
          explicitActiveReceiver = selectedItem
          break
        }
      }
    }
    var preferred = explicitActiveReceiver || Api.preferredPlaybackDevice(
      next, selectedDeviceId, selectedDeviceExplicit, current)
    if (selectedDeviceExplicit
        && (!preferred || preferred.id !== selectedDeviceId))
      selectedDeviceExplicit = false
    selectedDeviceId = preferred ? preferred.id : ""
    devicesLoaded = true
  }

  function finishDeviceLoad(callback, error) {
    mergeConnectDevices()
    devicesLoading = false
    if (error) fail(error)
    var waiters = deviceLoadWaiters.slice()
    deviceLoadWaiters = []
    if (typeof callback === "function") waiters.push(callback)
    for (var i = 0; i < waiters.length; i++) {
      try { waiters[i]() }
      catch (e) { /* callers own callback errors */ }
    }
  }

  function loadDevices(callback, serial, discoverLocal) {
    if (typeof callback === "function") {
      var waiters = deviceLoadWaiters.slice()
      waiters.push(callback)
      deviceLoadWaiters = waiters
    }
    if (discoverLocal === true) pendingDeviceDiscover = true
    if (devicesLoading) return
    var expected = serial === undefined ? dataSerial : serial
    var shouldDiscover = pendingDeviceDiscover
    pendingDeviceDiscover = false
    devicesLoading = true
    if (shouldDiscover) loadPlaybackState()
    spotifyApi.request("GET", "/me/player/devices", null, null,
      function(status, payload, error) {
        if (expected !== root.dataSerial) {
          root.devicesLoading = false
          root.deviceLoadWaiters = []
          return
        }
        if (!error) {
          var source = payload && Array.isArray(payload.devices) ? payload.devices : []
          var next = []
          for (var i = 0; i < source.length; i++) next.push(root.normalizeDevice(source[i]))
          root.apiDevices = next.slice(0, 32)
        }
        if (shouldDiscover) {
          root.pendingDeviceLoadError = error || ""
          if (spotifyConnectManager.loading) return
          spotifyConnectManager.refresh()
        } else {
          root.finishDeviceLoad(null, error || "")
        }
      })
  }

  function loadQueue(callback, serial) {
    if (queueLoading) {
      if (typeof callback === "function") callback()
      return
    }
    var expected = serial === undefined ? dataSerial : serial
    queueLoading = true
    spotifyApi.request("GET", "/me/player/queue", null, null,
      function(status, payload, error) {
        root.queueLoading = false
        if (expected !== root.dataSerial) return
        if (error) root.fail(error)
        else {
          var source = payload && Array.isArray(payload.queue) ? payload.queue : []
          var next = []
          for (var i = 0; i < source.length && next.length < 100; i++) {
            var track = Api.normalizeTrack(source[i], 96)
            if (track) next.push(track)
          }
          root.queue = next
          root.queueLoaded = true
        }
        if (typeof callback === "function") callback()
      })
  }

  function search(term) {
    var normalized = String(term || "").trim()
    searchQuery = normalized
    searchLoading = normalized !== ""
    if (!normalized) {
      clearSearch()
      return
    }
    var expected = dataSerial
    spotifyApi.search(normalized, function(groups, error) {
      if (expected !== root.dataSerial) return
      if (root.searchQuery !== normalized) return
      root.searchLoading = false
      if (error) root.fail(error)
      else {
        root.searchGroups = groups
        root.rememberSearch(normalized)
        var allItems = []
        for (var i = 0; i < Api.SEARCH_TYPES.length; i++)
          allItems = allItems.concat(root.searchItems(Api.SEARCH_TYPES[i]))
        root.checkSavedItems(allItems)
      }
    })
  }

  function searchItems(type) {
    var page = searchGroups[String(type || "track")]
    return page && Array.isArray(page.items) ? page.items : []
  }

  function searchNext(type) {
    var page = searchGroups[String(type || "track")]
    return page ? String(page.next || "") : ""
  }

  function loadMoreSearch(type) {
    var value = String(type || "track")
    var path = searchNext(value)
    if (!path || searchLoading) return
    var expected = dataSerial
    searchLoading = true
    spotifyApi.request("GET", path, null, null, function(status, payload, error) {
      if (expected !== root.dataSerial) return
      root.searchLoading = false
      if (error) { root.fail(error); return }
      var incoming = ({})
      incoming[value] = Api.normalizeSearchPage(payload, value, 128)
      var merged = Api.mergeSearchGroups(root.searchGroups, incoming)
      if (merged[value].items.length >= root.cacheLimit) {
        merged[value].items = merged[value].items.slice(0, root.cacheLimit)
        merged[value].next = ""
      }
      root.searchGroups = merged
      root.checkSavedItems(root.searchItems(value))
    })
  }

  function clearSearch() {
    searchLoading = false
    searchQuery = ""
    searchGroups = Api.searchGroups({}, 128)
  }

  function cancelSearch(clearResults) {
    spotifyApi.cancelSearch()
    searchLoading = false
    if (clearResults === true) clearSearch()
  }

  function cancelArtistCatalog() {
    artistCatalogSerial++
    artistAlbumsLoading = false
    artistSongsLoading = false
    artistPlaylistsLoading = false
    detailLoading = false
  }

  function deviceForId(id) {
    var key = String(id || "")
    for (var i = 0; i < devices.length; i++)
      if (String(devices[i].id || "") === key) return devices[i]
    return null
  }

  function localDevice() {
    for (var i = 0; i < devices.length; i++) if (devices[i].local) return devices[i]
    return null
  }

  function chooseDevice() {
    return Api.preferredPlaybackDevice(devices, selectedDeviceId,
      selectedDeviceExplicit, remoteDevice)
  }

  // An active Spotify Connect receiver already represents the user's current
  // target. Otherwise, make the local receiver the visible default as soon as
  // it is available, so the first playback click needs no trip through Devices.
  function autoselectLocalDevice() {
    var current = chooseDevice()
    var local = Api.automaticLocalPlaybackDevice(
      selectedDeviceId, current, localDevice())
    if (!local) return null
    selectedDeviceId = local.id
    selectedDeviceExplicit = false
    return local
  }

  function beginConnectAuthorization(device) {
    if (!device || !device.id || pendingConnectDeviceId !== device.id) return
    pendingConnectWakeTried = false
    if (Api.spotifyConnectTokenType(device.tokenType) !== "default") {
      statusMessage = "Comprobando permiso para " + device.name
      connectAuthManager.withAccessToken(function(token, error) {
        if (root.pendingConnectDeviceId !== device.id) return
        if (token) {
          root.statusMessage = "Conectando con " + device.name
          spotifyConnectManager.activate(device.id, token)
        } else {
          root.statusMessage = "Autoriza el acceso al altavoz en el navegador"
          connectAuthManager.beginLogin()
        }
      })
    } else {
      statusMessage = "Conectando con " + device.name
      spotifyConnectManager.activate(device.id, "")
    }
  }

  function selectDevice(id, transferPlayback) {
    var device = deviceForId(id)
    if (!device) return
    if (!device.id || (device.restricted && !device.activationRequired)) return
    selectedDeviceId = device.id
    selectedDeviceExplicit = true
    noteActivity()
    if (device.activationRequired) {
      if (deviceActivationBusy) return
      pendingConnectDeviceId = device.id
      connectActivationAttempts = 0
      pendingConnectWakeTried = false
      statusClearTimer.stop()
      lastError = ""
      if (String(device.brand || "").toLowerCase() === "sonos") {
        pendingConnectWakeTried = true
        statusMessage = "Activando " + device.name
        spotifyConnectManager.control(device.id, "play", "")
      } else {
        beginConnectAuthorization(device)
      }
      return
    }
    if (device.active) {
      selectedDeviceId = device.restricted ? "" : String(device.id || "")
      selectedDeviceExplicit = false
      succeed("Ya se está reproduciendo en " + device.name)
      loadPlaybackState()
      return
    }
    if (transferPlayback !== false) transferToConnectDevice(device.id)
  }

  function transferToConnectDevice(deviceId) {
    apiAction("PUT", "/me/player", null,
      { device_ids: [deviceId], play: playing }, "Playback device changed",
      function(ok) {
        if (ok) {
          root.loadDevices()
          root.loadPlaybackState()
        }
      })
  }

  function checkActivatedConnectDevice() {
    var requested = pendingConnectDeviceId
    if (!requested) return
    var device = deviceForId(requested)
    if (device && !device.activationRequired) {
      pendingConnectDeviceId = ""
      connectActivationAttempts = 0
      pendingConnectWakeTried = false
      if (device.active) {
        succeed("Reproduciendo en " + device.name)
        loadPlaybackState()
      } else {
        transferToConnectDevice(requested)
      }
      return
    }
    connectActivationAttempts++
    if (pendingConnectWakeTried && connectActivationAttempts >= 4 && device) {
      connectActivationAttempts = 0
      beginConnectAuthorization(device)
    } else if (connectActivationAttempts < 20) {
      connectActivationTimer.restart()
    }
    else {
      pendingConnectDeviceId = ""
      pendingConnectWakeTried = false
      fail(speakerAvailabilityError())
    }
  }

  function speakerAvailabilityError() {
    return "El altavoz se conectó, pero no está disponible. Comprueba que esté activo e inténtalo de nuevo"
  }

  function refreshActivatedConnectDevice() {
    // Sonos is commonly absent from /me/player/devices even after addUser has
    // succeeded. Refresh current playback first so an active null-id Sonos can
    // be matched to its locally discovered receiver by name and type.
    loadPlaybackState(function() {
      root.loadDevices(function() { root.checkActivatedConnectDevice() })
    })
  }

  function clearPendingPlayback(keepActivation) {
    pendingPlayback = null
    pendingPlaybackBody = null
    pendingPlaybackMessage = ""
    pendingPlaybackRadio = null
    pendingPlaybackSerial = 0
    if (keepActivation !== true) localActivationRequested = false
  }

  function dispatchPendingPlayback(playbackSerial) {
    if (playbackSerial !== pendingPlaybackSerial || !pendingPlaybackBody) return
    var target = autoselectLocalDevice() || chooseDevice()
    if (target && !target.local) {
      localActivationRequested = false
      sendPendingPlayback(Api.playbackTargetDeviceId(target, selectedDeviceExplicit))
      return
    }
    if (!daemonManager.credentialsAvailable && (!target || target.local)) {
      fail("Autoriza la reproducción en este equipo desde Ajustes e inténtalo de nuevo")
      clearPendingPlayback()
      return
    }
    if (!daemonManager.usingFallbackRuntime
        && (backendClient.ready || daemonManager.playbackReady)) {
      waitForLocalSocketThenPlay(playbackSerial)
      return
    }
    if (target && target.local && daemonManager.running) {
      localActivationRequested = false
      sendPendingPlayback(Api.playbackTargetDeviceId(target, selectedDeviceExplicit))
      return
    }
    if (!daemonManager.binaryAvailable || !daemonManager.unitAvailable) {
      fail("La reproducción en este equipo debe configurarse desde Ajustes")
      clearPendingPlayback()
      return
    }
    daemonManager.start()
    deviceProbeTimer.restart()
  }

  function waitForLocalSocketThenPlay(playbackSerial) {
    if (playbackSerial !== pendingPlaybackSerial || !pendingPlaybackBody) return
    if (backendClient.ready) {
      sendLocalSocketPlayback(playbackSerial)
      return
    }
    if (!daemonManager.binaryAvailable || !daemonManager.unitAvailable) {
      fail("La reproducción en este equipo debe configurarse desde Ajustes")
      clearPendingPlayback()
      return
    }
    if (!daemonManager.running && !daemonManager.busy) daemonManager.start()
    localSocketWaitAttempts = 0
    localSocketWaitTimer.restart()
  }

  function sendLocalSocketPlayback(playbackSerial) {
    if (playbackSerial !== pendingPlaybackSerial || !pendingPlaybackBody) return
    var body = pendingPlaybackBody
    var successMessage = pendingPlaybackMessage
    var radioPlaylist = pendingPlaybackRadio
    clearPendingPlayback()
    localSocketWaitTimer.stop()
    backendClient.loadPlayback(body, function(ok, result, error) {
      if (ok) {
        if (playbackSerial === root.radioSerial)
          root.radioContextSelected = !!radioPlaylist
        if (successMessage) root.succeed(successMessage)
        root.loadQueue()
        root.loadPlaybackState()
        return
      }
      root.pendingPlaybackBody = body
      root.pendingPlaybackMessage = successMessage
      root.pendingPlaybackRadio = radioPlaylist
      root.pendingPlaybackSerial = playbackSerial
      root.succeed(Api.localSocketFallbackMessage())
      root.sendPendingPlayback(Api.playbackTargetDeviceId(
        root.localDevice() || root.chooseDevice(), root.selectedDeviceExplicit))
    })
  }

  function playItem(item, sourceItems, contextUri, successMessage, explicitRadio) {
    var playbackSerial = ++radioSerial
    var body = Api.playbackBody(item, sourceItems, contextUri)
    if (!body) {
      fail("Este elemento de Spotify no se puede reproducir")
      return
    }
    pendingPlayback = item
    pendingPlaybackBody = body
    pendingPlaybackMessage = String(successMessage || "")
    pendingPlaybackRadio = radioPlaylistForPlayback(item, contextUri, explicitRadio)
    pendingPlaybackSerial = playbackSerial
    localActivationRequested = true
    deviceProbeAttempts = 0
    noteActivity()
    if (contextUri) lastPlayedContextUri = String(contextUri)
    if (Array.isArray(sourceItems) && sourceItems.length) {
      lastPlayedContextItems = sourceItems.slice(0, 50)
    } else if (contextUri) {
      var ctxTracks = contextTracksForUri(contextUri)
      if (ctxTracks && ctxTracks.length) lastPlayedContextItems = ctxTracks.slice(0, 50)
    }
    if (item && item.id) {
      lastPlayedTrack = {
        kind: "item",
        type: String(item.type || "track"),
        id: String(item.id),
        uri: String(item.uri || ("spotify:track:" + item.id)),
        name: String(item.name || ""),
        subtitle: String(item.subtitle || ""),
        album: String(item.album || ""),
        artists: Api.arrayValues(item.artists),
        imageUrl: String(item.imageUrl || ""),
        durationMs: Math.max(0, Number(item.durationMs) || 0),
        externalUrl: String(item.externalUrl || "")
      }
      scheduleCatalogCacheSave()
    }

    // Opening the panel refreshes current playback asynchronously. That wait
    // is only needed for the Web-API fallback: the local backend owns its
    // playback context and can accept consecutive loads immediately. Waiting
    // here while its API refresh is queued makes the first selected song work
    // but leaves following selections stalled behind Spotify's rate limit.
    if (!selectedDeviceExplicit && remotePlaybackLoading
        && (daemonManager.usingFallbackRuntime || !backendClient.ready)) {
      loadPlaybackState(function() {
        root.dispatchPendingPlayback(playbackSerial)
      })
      return
    }
    dispatchPendingPlayback(playbackSerial)
  }

  function probeForLocalDevice() {
    if (!pendingPlayback && !localActivationRequested) return
    loadDevices(function() {
      if (!root.pendingPlayback && !root.localActivationRequested) return
      var target = root.pendingPlayback
        ? (root.autoselectLocalDevice() || root.chooseDevice()) : null
      if (target && !target.local) {
        root.localActivationRequested = false
        root.sendPendingPlayback(Api.playbackTargetDeviceId(
          target, root.selectedDeviceExplicit))
        return
      }
      var local = root.localDevice()
      if (local && local.id && !local.restricted) {
        root.selectedDeviceId = local.id
        root.selectedDeviceExplicit = false
        if (root.pendingPlayback) {
          root.localActivationRequested = false
          root.sendPendingPlayback(Api.playbackTargetDeviceId(local, false))
        } else {
          root.activateLocalDevice(local.id)
        }
        return
      }
      root.deviceProbeAttempts++
      if (root.deviceProbeAttempts < 8) deviceProbeTimer.restart()
      else {
        root.clearPendingPlayback()
        root.fail("La reproducción en este equipo no está disponible. Reconecta Spotify en Ajustes e inténtalo de nuevo")
      }
    })
  }

  function activateLocalDevice(deviceId) {
    var id = String(deviceId || "")
    if (!id) return
    localActivationRequested = false
    apiAction("PUT", "/me/player", null,
      { device_ids: [id], play: false }, "Omarchy Spotify is ready",
      function(ok) {
        if (ok) {
          root.selectedDeviceId = id
          root.selectedDeviceExplicit = false
          root.loadDevices()
        }
      })
  }

  function sendPendingPlayback(deviceId) {
    var body = pendingPlaybackBody
    var successMessage = pendingPlaybackMessage
    var radioPlaylist = pendingPlaybackRadio
    var playbackSerial = pendingPlaybackSerial
    if (!body) return
    clearPendingPlayback(true)
    apiAction("PUT", "/me/player/play", { device_id: deviceId }, body, successMessage,
      function(ok) {
        if (ok) {
          if (playbackSerial === root.radioSerial)
            root.radioContextSelected = !!radioPlaylist
          root.selectedDeviceId = String(deviceId || root.selectedDeviceId)
          root.loadDevices()
          root.loadQueue()
        }
      })
  }

  function startRadio(item) {
    if (!item || item.type !== "track" || !item.id || !item.uri) {
      fail("La radio de canción está disponible para canciones de Spotify")
      return
    }
    var expected = ++radioSerial
    noteActivity()
    succeed("Buscando canciones parecidas…")
    // Development-mode recommendation requests can succeed with no payload.
    // Spotify's generated radio playlists provide a real playback context, so
    // prefer an exact Spotify-owned match and verify its first track is the seed.
    spotifyApi.request("GET", "/search", {
      q: String(item.name || "") + " Radio",
      type: "playlist",
      limit: 10
    }, null, function(status, payload, error) {
      if (expected !== root.radioSerial) return
      if (!error) {
        var page = Api.normalizeSearchPage(payload, "playlist", 96)
        var candidates = Api.trackRadioPlaylists(page.items, item.name)
        if (candidates.length) {
          root.tryRadioPlaylist(item, candidates, 0, expected)
          return
        }
      }
      root.requestRadioRecommendations(item, expected)
    })
  }

  function tryRadioPlaylist(item, candidates, index, expected) {
    if (expected !== radioSerial) return
    if (index >= candidates.length) {
      requestRadioRecommendations(item, expected)
      return
    }
    var candidate = candidates[index]
    spotifyApi.request("GET", "/playlists/"
      + encodeURIComponent(String(candidate.id)) + "/items", { limit: 1 }, null,
      function(status, payload, error) {
        if (expected !== root.radioSerial) return
        var source = payload && Array.isArray(payload.items) ? payload.items : []
        var first = !error && source.length ? Api.normalizeTrack(source[0], 96) : null
        if (first && Api.radioSeedMatches(first, item)) {
          root.rememberRadioPlaylist(candidate)
          root.playItem(candidate, null, "", "Track radio started", candidate)
          root.radioPlaylistReady(candidate)
          return
        }
        root.tryRadioPlaylist(item, candidates, index + 1, expected)
      })
  }

  function requestRadioRecommendations(item, expected) {
    if (expected !== radioSerial) return
    spotifyApi.request("GET", "/recommendations", {
      limit: 49,
      seed_tracks: item.id
    }, null, function(status, payload, error) {
      if (expected !== root.radioSerial) return
      var source = payload && Array.isArray(payload.tracks) ? payload.tracks : []
      var extras = []
      for (var i = 0; i < source.length; i++) {
        var track = Api.normalizeTrack(source[i], 96)
        if (track) extras.push(track)
      }
      var radio = Api.uniqueRadioTracks(item, extras)
      if (!error && radio.length > 1) {
        root.playItem(item, radio, "", "Track radio started")
        return
      }
      root.requestRadioArtistTracks(item, expected)
    })
  }

  function requestRadioArtistTracks(item, expected) {
    if (expected !== radioSerial) return
    var artist = item.artists && item.artists.length ? item.artists[0] : null
    if (!artist || !artist.name) {
      fail("Spotify no pudo encontrar una mezcla de radio para esta canción")
      return
    }
    spotifyApi.request("GET", "/search", {
      q: Api.catalogSearchText(artist.name, ""),
      type: "track",
      limit: 10
    }, null, function(status, payload, error) {
      if (expected !== root.radioSerial) return
      var page = error ? { items: [] }
        : Api.normalizeSearchPage(payload, "track", 96)
      var radio = Api.uniqueRadioTracks(item,
        Api.tracksForArtist(page.items, artist))
      if (radio.length > 1) root.playItem(item, radio, "", "Track radio started")
      else root.fail("Spotify no pudo encontrar una mezcla de radio para esta canción")
    })
  }

  function sendSonosControl(action, value) {
    if (!sonosControlAvailable || !sonosControlDevice.id) return false
    if (!spotifyConnectManager.controlling)
      spotifyConnectManager.control(sonosControlDevice.id, action, value)
    return true
  }

  function sonosPlayMode(nextRepeat, nextShuffle) {
    if (nextRepeat === "track") return "REPEAT_ONE"
    if (nextShuffle) return nextRepeat === "context" ? "SHUFFLE" : "SHUFFLE_NOREPEAT"
    return nextRepeat === "context" ? "REPEAT_ALL" : "NORMAL"
  }

  function applySonosControlResult(action, value) {
    if (!remotePlayback) return
    var nextState = Api.shallowCopy(remotePlayback)
    if (action === "play" || action === "pause") {
      nextState.progressSeconds = positionSeconds
      nextState.receivedAt = Date.now()
      nextState.playing = action === "play"
    } else if (action === "seek") {
      nextState.progressSeconds = Math.max(0, Number(value) || 0)
      nextState.receivedAt = Date.now()
    } else if (action === "volume" && remoteDevice) {
      var nextDevice = Api.shallowCopy(remoteDevice)
      nextDevice.volumePercent = Math.max(0, Math.min(100, Number(value) || 0))
      nextState.device = nextDevice
      rememberRemoteVolume(remoteDevice, nextDevice.volumePercent)
      if (sonosControlDevice)
        spotifyConnectManager.rememberVolume(sonosControlDevice.id,
          nextDevice.volumePercent)
    } else if (action === "mode") {
      var mode = String(value || "").toUpperCase()
      nextState.repeatMode = mode === "REPEAT_ONE" ? "track"
        : (mode === "REPEAT_ALL" || mode === "SHUFFLE" ? "context" : "off")
      nextState.shuffle = mode === "SHUFFLE" || mode === "SHUFFLE_NOREPEAT"
    }
    remotePlayback = nextState
    playbackPositionTick++
  }

  function togglePlayback() {
    noteActivity()
    if (sendSonosControl(playing ? "pause" : "play", "")) return
    if (!playing && !hasMedia && lastPlayedTrack) {
      playItem(lastPlayedTrack, null, lastPlayedContextUri, "")
      return
    }
    if (!useRemotePlayback && hasLocalPlayer && activePlayer.canTogglePlaying
        && activePlayer.playbackState === MprisPlaybackState.Paused) {
      activePlayer.togglePlaying()
      return
    }
    if (!playing && lastPlayedTrack && (!hasLocalPlayer || playbackState === MprisPlaybackState.Stopped)) {
      playItem(lastPlayedTrack, null, lastPlayedContextUri, "")
      return
    }
    if (!useRemotePlayback && hasLocalPlayer && activePlayer.canTogglePlaying) {
      activePlayer.togglePlaying()
      return
    }
    remotePlayerAction("PUT", playing ? "/me/player/pause" : "/me/player/play",
      controlQuery())
  }

  function next() {
    noteActivity()
    if (sendSonosControl("next", "")) return
    if (!playing && (!hasMedia || playbackState === MprisPlaybackState.Stopped || !hasLocalPlayer || !activePlayer.canGoNext) && lastPlayedTrack) {
      var adjacent = findAdjacentTrack(1)
      if (adjacent && adjacent.item) {
        playItem(adjacent.item, adjacent.items, lastPlayedContextUri, "")
        return
      }
      playItem(lastPlayedTrack, null, lastPlayedContextUri, "")
      pendingSkipAfterStart = "next"
      return
    }
    if (!useRemotePlayback && hasLocalPlayer && activePlayer.canGoNext) activePlayer.next()
    else remotePlayerAction("POST", "/me/player/next", controlQuery())
  }

  function previous() {
    noteActivity()
    if (sendSonosControl("previous", "")) return
    if (!playing && (!hasMedia || playbackState === MprisPlaybackState.Stopped || !hasLocalPlayer || !activePlayer.canGoPrevious) && lastPlayedTrack) {
      var adjacent = findAdjacentTrack(-1)
      if (adjacent && adjacent.item) {
        playItem(adjacent.item, adjacent.items, lastPlayedContextUri, "")
        return
      }
      playItem(lastPlayedTrack, null, lastPlayedContextUri, "")
      pendingSkipAfterStart = "previous"
      return
    }
    if (!useRemotePlayback && hasLocalPlayer && activePlayer.canGoPrevious) activePlayer.previous()
    else remotePlayerAction("POST", "/me/player/previous", controlQuery())
  }

  function controlDeviceId() {
    if (useRemotePlayback) return remoteDevice && !remoteDevice.restricted
      ? String(remoteDevice.id || "") : ""
    return String(selectedDeviceId || "")
  }

  function controlQuery(extra) {
    var query = extra ? Api.shallowCopy(extra) : ({})
    var id = controlDeviceId()
    if (id) query.device_id = id
    return Object.keys(query).length ? query : null
  }

  function remotePlayerAction(method, path, query) {
    apiAction(method, path, query, null, "",
      function(ok) { if (ok) root.loadPlaybackState() })
  }

  function seekSeconds(seconds) {
    var value = Math.max(0, Math.min(lengthSeconds || Number.MAX_VALUE,
      Number(seconds) || 0))
    noteActivity()
    var remoteSerial = useRemotePlayback ? beginRemoteSeek(value) : 0
    if (sendSonosControl("seek", String(Math.round(value)))) return
    if (!useRemotePlayback && hasLocalPlayer
        && activePlayer.canSeek && activePlayer.positionSupported)
      activePlayer.position = value
    else apiAction("PUT", "/me/player/seek",
      controlQuery({ position_ms: Math.round(value * 1000) }),
      null, "", function(ok) {
      if (!ok) root.clearPendingRemoteSeek(remoteSerial)
      root.loadPlaybackState()
    })
  }

  function setVolume(value, live) {
    var sliderValue = Math.max(0, Math.min(1, Number(value) || 0))
    noteActivity()
    if (live === true) {
      volumeLiveActive = true
      volumeLiveIdleTimer.restart()
    }
    beginPendingSliderVolume(sliderValue)
    queuedVolumeSlider = sliderValue
    volumeFlushQueued = true
    if (!volumeFlushCooling) flushVolume()
  }

  function setShuffle(value) {
    var enabled = value === true
    noteActivity()
    if (sendSonosControl("mode", sonosPlayMode(repeatMode, enabled))) return
    if (!useRemotePlayback && hasLocalPlayer && activePlayer.shuffleSupported)
      activePlayer.shuffle = enabled
    else remotePlayerAction("PUT", "/me/player/shuffle",
      controlQuery({ state: enabled ? "true" : "false" }))
  }

  function cycleRepeat() {
    var nextMode = repeatMode === "off" ? "context" : (repeatMode === "context" ? "track" : "off")
    noteActivity()
    if (sendSonosControl("mode", sonosPlayMode(nextMode, shuffle))) return
    if (!useRemotePlayback && hasLocalPlayer && activePlayer.loopSupported) {
      activePlayer.loopState = nextMode === "track" ? MprisLoopState.Track
        : (nextMode === "context" ? MprisLoopState.Playlist : MprisLoopState.None)
    } else {
      remotePlayerAction("PUT", "/me/player/repeat",
        controlQuery({ state: nextMode }))
    }
  }

  function setSleepMinutes(minutes) {
    var value = Math.max(1, Math.min(720, Math.floor(Number(minutes) || 0)))
    sleepContextTimer.stop()
    sleepMode = "minutes"
    sleepEndsAt = Date.now() + value * 60000
    sleepRemainingSeconds = value * 60
    sleepTrackUri = ""
    scheduleSleepDeadline()
    succeed("Temporizador configurado para " + value + " minutos")
  }

  function sleepAfterTrack() {
    if (!currentUri || !playing) {
      fail("Reproduce algo antes de configurar un temporizador al final de la pista")
      return
    }
    sleepDeadlineTimer.stop()
    sleepMode = "track"
    sleepTrackUri = currentUri
    sleepEndsAt = 0
    sleepRemainingSeconds = 0
    succeed("La reproducción se pausará después de este elemento")
  }

  function sleepAfterContext() {
    if (!playing) {
      fail("Reproduce algo antes de configurar un temporizador al final del contexto")
      return
    }
    sleepDeadlineTimer.stop()
    sleepMode = "context"
    sleepTrackUri = ""
    sleepEndsAt = 0
    sleepRemainingSeconds = 0
    succeed("La reproducción se pausará después de este álbum o lista")
  }

  function cancelSleepTimer(showStatus) {
    sleepDeadlineTimer.stop()
    sleepMode = "off"
    sleepEndsAt = 0
    sleepTrackUri = ""
    sleepRemainingSeconds = 0
    sleepContextTimer.stop()
    if (showStatus !== false) succeed("Temporizador cancelado")
  }

  function finishSleepTimer() {
    if (!sleepActive) return
    if (playing) togglePlayback()
    cancelSleepTimer(false)
    succeed("Temporizador finalizado")
  }

  function updateSleepCountdown() {
    if (sleepMode !== "minutes") {
      sleepRemainingSeconds = 0
      return
    }
    sleepRemainingSeconds = Api.deadlineRemainingSeconds(sleepEndsAt,
      Date.now())
  }

  function scheduleSleepDeadline() {
    sleepDeadlineTimer.stop()
    if (sleepMode !== "minutes") return
    var remaining = sleepEndsAt - Date.now()
    if (remaining <= 0) {
      updateSleepCountdown()
      finishSleepTimer()
      return
    }
    sleepDeadlineTimer.interval = Math.max(1, Math.ceil(remaining))
    sleepDeadlineTimer.restart()
  }

  function sleepStatusText() {
    if (sleepMode === "minutes") {
      var minutes = Math.floor(sleepRemainingSeconds / 60)
      var seconds = sleepRemainingSeconds % 60
      return "Se apagará en " + minutes + ":" + (seconds < 10 ? "0" : "") + seconds
    }
    if (sleepMode === "track") return "Apagar después de este elemento"
    if (sleepMode === "context") return "Apagar después de este álbum o lista"
    return "Temporizador de apagado"
  }

  function addToQueue(item) {
    if (!item || ["track", "episode"].indexOf(item.type) < 0 || !item.uri) {
      fail("Solo se pueden añadir canciones y episodios a la cola")
      return
    }
    if (!useRemotePlayback && backendClient.ready) {
      backendClient.sendCommand("add_to_queue", { uri: item.uri },
        function(ok, result, error) {
          if (ok) {
            root.succeed("Añadido a la cola")
            root.loadQueue()
          } else root.fail(error || "Could not add that item to the queue")
        })
      return
    }
    apiAction("POST", "/me/player/queue", {
      uri: item.uri,
      device_id: controlDeviceId() || undefined
    }, null, "Added to queue", function(ok) { if (ok) root.loadQueue() })
  }

  function startEngine() {
    noteActivity()
    localActivationRequested = true
    deviceProbeAttempts = 0
    daemonManager.start()
    deviceProbeTimer.restart()
  }

  function stopEngine() {
    clearPendingPlayback()
    localActivationRequested = false
    cancelVisibleLocalDeviceRefresh()
    deviceProbeTimer.stop()
    localSocketWaitTimer.stop()
    localSocketWaitAttempts = 0
    daemonManager.stop()
  }

  function login() {
    if (authManager.loginBusy || authManager.sessionBusy
        || daemonManager.setupBusy || daemonManager.authenticationBusy) return
    noteActivity()
    lastError = ""
    statusClearTimer.stop()
    statusMessage = ""
    loginFlowActive = true
    if (!authManager.loggedIn) {
      authManager.beginLogin()
      return
    }
    continueLocalPlaybackSetup()
  }

  function continueLocalPlaybackSetup() {
    if (!daemonManager.playbackReady) {
      daemonManager.setupPlayback()
      return
    }
    if (!daemonManager.credentialsAvailable) {
      daemonManager.authenticate()
      return
    }
    finishLoginFlow()
  }

  function cancelLogin() {
    loginFlowActive = false
    lastError = ""
    statusMessage = ""
    authManager.cancelLogin()
    connectAuthManager.cancelLogin()
    daemonManager.cancelAuthentication()
  }

  function reconnectAccount() {
    if (loginBusy) return
    noteActivity()
    lastError = ""
    statusClearTimer.stop()
    statusMessage = ""
    loginFlowActive = true
    authManager.beginLogin()
  }

  function finishLoginFlow() {
    loginFlowActive = false
    succeed("Conectado a Spotify")
    loadPlaybackState()
    loadProfile()
    loadSidebarPlaylists()
    openView(activeView, true)
  }

  function logout() {
    if (loginBusy || daemonManager.busy) return
    loginFlowActive = false
    dataSerial++
    clearPendingPlayback()
    deviceProbeTimer.stop()
    spotifyApi.cancelSearch()
    daemonManager.clearCredentials()
    connectAuthManager.logout()
    authManager.logout()
    clearData()
  }

  function clearData() {
    radioSerial++
    playlistItemsSerial++
    clearPendingPlayback()
    radioContextSelected = false
    playlists = []
    playlistsLoaded = false
    playlistsNext = ""
    savedTracks = []
    savedTracksLoaded = false
    savedTracksNext = ""
    savedAlbums = []
    savedAlbumsLoaded = false
    savedAlbumsNext = ""
    followedArtists = []
    followedArtistsLoaded = false
    followedArtistsNext = ""
    savedShows = []
    savedShowsLoaded = false
    savedShowsNext = ""
    savedEpisodes = []
    savedEpisodesLoaded = false
    savedEpisodesNext = ""
    savedAudiobooks = []
    savedAudiobooksLoaded = false
    savedAudiobooksNext = ""
    playlistItems = []
    playlistItemsNext = ""
    playlistItemsError = ""
    playlistItemsStatus = 0
    playlistRestoreTargetCount = 0
    selectedPlaylist = null
    currentUserId = ""
    currentUserName = ""
    queue = []
    queueLoaded = false
    devices = []
    apiDevices = []
    remotePlayback = null
    remotePlaybackLoading = false
    remotePlaybackWaiters = []
    rememberedRemoteVolumeDevice = null
    rememberedRemoteVolumePercent = -1
    pendingRemoteSeek = null
    pendingRemoteVolume = null
    clearPendingSliderVolume()
    volumeFlushQueued = false
    volumeFlushCooling = false
    volumeLiveActive = false
    volumeFlushTimer.stop()
    volumeLiveIdleTimer.stop()
    remoteControlSerial = 0
    remoteVolumeProbeKey = ""
    remoteControlDiscoveryKey = ""
    playbackPositionTick++
    devicesLoaded = false
    selectedDeviceId = ""
    selectedDeviceExplicit = false
    localDeviceId = ""
    localRuntimeDeviceName = deviceName
    pendingConnectDeviceId = ""
    connectActivationAttempts = 0
    pendingConnectWakeTried = false
    connectActivationTimer.stop()
    searchQuery = ""
    searchGroups = Api.searchGroups({}, 128)
    savedUris = ({})
    savedUriCheckedAt = ({})
    savedUriOrder = []
    savedUrisChecking = ({})
    savedUrisBusy = ({})
    savedUrisRevision++
    savedUrisCheckingRevision++
    savedUrisBusyRevision++
    recentTracks = []
    topTracks = []
    topArtists = []
    homeLoaded = false
    homeRequestsPending = 0
    discoverSerial++
    discoverPlaylists = []
    discoverCandidates = []
    discoverLoaded = false
    discoverRequestsPending = 0
    discoverRequestsFailed = 0
    discoverMessage = ""
    detailSerial++
    detailItem = null
    detailItems = []
    detailNext = ""
    detailLoading = false
    detailMessage = ""
    detailRestoreTargetCount = 0
    artistCatalogSerial++
    artistCatalogQuery = ""
    artistAlbums = []
    artistAlbumsNext = ""
    artistAlbumsLoading = false
    artistSongs = []
    artistSongsNext = ""
    artistSongsLoading = false
    artistPlaylists = []
    artistPlaylistsNext = ""
    artistPlaylistsLoading = false
    artistThisIsPlaylist = null
    artistThisIsLoading = false
    playlistsLoading = false
    savedTracksLoading = false
    savedAlbumsLoading = false
    followedArtistsLoading = false
    savedShowsLoading = false
    savedEpisodesLoading = false
    savedAudiobooksLoading = false
    playlistItemsLoading = false
    playlistActionBusy = false
    playlistConversionBusy = false
    queueLoading = false
    devicesLoading = false
    deviceLoadWaiters = []
    pendingDeviceDiscover = false
    searchLoading = false
    localSocketWaitAttempts = 0
    localSocketWaitTimer.stop()
    cancelSleepTimer(false)
    lastPlayedTrack = null
    lastPlayedContextUri = ""
    lastPlayedContextItems = []
    pendingSkipAfterStart = ""
  }

  onPlayingChanged: {
    noteActivity()
    if (playing && currentTrackId) recordLastPlayedTrack()
    if (playing && pendingSkipAfterStart) {
      var skip = pendingSkipAfterStart
      pendingSkipAfterStart = ""
      if (skip === "next") next()
      else if (skip === "previous") previous()
    }
  }
  onPlaybackStateChanged: {
    if ((sleepMode === "context" || sleepMode === "track")
        && playbackState === MprisPlaybackState.Stopped) sleepContextTimer.restart()
    else sleepContextTimer.stop()
  }
  onCurrentUriChanged: {
    if (sleepMode === "track" && sleepTrackUri && currentUri
        && currentUri !== sleepTrackUri) finishSleepTimer()
  }
  onCurrentTrackItemUriChanged: {
    syncCurrentTrackSaved(false)
    if (currentTrackId && (hasMedia || playing)) recordLastPlayedTrack()
  }
  onLyricsPluginAvailabilityChanged: resumeLyricsInstallIntent()
  onShellChanged: settingsSync.restart()
  onUiVisibleChanged: {
    if (uiVisible) {
      ensureVisibleLocalReceiver()
      syncCurrentTrackSaved(true)
      updateSleepCountdown()
    }
    else cancelVisibleLocalDeviceRefresh()
  }
  onFullyConnectedChanged: {
    if (fullyConnected && uiVisible) ensureVisibleLocalReceiver()
    else if (!fullyConnected) cancelVisibleLocalDeviceRefresh()
  }

  Component.onCompleted: {
    ensureStateDir.running = true
    settingsSync.start()
    daemonManager.refreshStatus()
  }

  Connections {
    target: root.shell
    ignoreUnknownSignals: true
    function onShellConfigChanged() { root.syncSettings() }
  }

  Connections {
    target: authManager
    function onLoginSucceeded() {
      root.syncCurrentTrackSaved(true)
      var continueSetup = root.loginFlowActive && (!root.daemon.playbackReady
        || !root.daemon.credentialsAvailable)
      root.finishLoginFlow()
      if (continueSetup) {
        root.loginFlowActive = true
        root.succeed("Spotify conectado · terminando de configurar la reproducción en este equipo")
        root.continueLocalPlaybackSetup()
      }
      if (root.localActivationRequested) deviceProbeTimer.restart()
    }
    function onLoggedOut() { root.clearData() }
    function onSessionUnavailable(reason) {
      root.loginFlowActive = false
      if (reason) root.lastError = root.safeError(reason)
    }
  }

  Connections {
    target: daemonManager
    function onCredentialsAvailableChanged() {
      if (daemonManager.credentialsAvailable && root.uiVisible)
        root.ensureVisibleLocalReceiver()
    }
    function onSetupSucceeded() {
      if (root.loginFlowActive) root.continueLocalPlaybackSetup()
      else root.succeed("La reproducción en este equipo está lista")
    }
    function onSetupFailed(reason) {
      root.loginFlowActive = false
      root.fail(reason)
    }
    function onStarted() {
      root.localRuntimeDeviceName = root.deviceName
      root.localDeviceId = ""
      root.succeed("Reproducción iniciada en este equipo")
      if (root.uiVisible) root.ensureVisibleLocalReceiver()
      if (root.pendingPlayback || root.localActivationRequested) deviceProbeTimer.restart()
    }
    function onStopped() { root.succeed("Reproducción detenida en este equipo") }
    function onAuthenticationSucceeded() {
      if (root.loginFlowActive) root.finishLoginFlow()
      else root.succeed("La reproducción en este equipo está conectada")
      if (root.uiVisible) root.ensureVisibleLocalReceiver()
      if (root.pendingPlayback || root.localActivationRequested) deviceProbeTimer.restart()
    }
    function onAuthenticationFailed(reason) {
      root.loginFlowActive = false
      root.fail(reason)
    }
    function onCredentialsCleared() { root.succeed("Sesión de Spotify cerrada") }
    function onCredentialsClearFailed(reason) { root.fail(reason) }
  }

  Connections {
    target: spotifyConnectManager
    function onRefreshed() {
      var error = root.pendingDeviceLoadError
      root.pendingDeviceLoadError = ""
      root.finishDeviceLoad(null, error)
    }
    function onRefreshFailed(reason) {
      var apiError = root.pendingDeviceLoadError
      root.pendingDeviceLoadError = ""
      root.finishDeviceLoad(null, apiError)
      // Local discovery is supplemental. If Spotify already supplied devices
      // or an active playback target, a transient Avahi failure must not turn
      // a working connection into a user-visible error.
      if (!apiError && !root.remoteDevice && !root.apiDevices.length)
        root.fail(reason)
    }
    function onActivated(deviceId) {
      statusClearTimer.stop()
      root.statusMessage = "Altavoz conectado · esperando a que esté disponible"
      root.connectActivationAttempts = 0
      root.pendingConnectWakeTried = false
      connectActivationTimer.restart()
    }
    function onActivationFailed(reason) {
      root.pendingConnectDeviceId = ""
      root.connectActivationAttempts = 0
      root.pendingConnectWakeTried = false
      root.fail(reason)
    }
    function onControlled(deviceId, action, value) {
      if (root.pendingConnectDeviceId === deviceId && action === "play") {
        root.statusMessage = "Conectando con "
          + String((root.deviceForId(deviceId) || {}).name || "el altavoz")
        root.connectActivationAttempts = 0
        connectActivationTimer.restart()
        return
      }
      root.applySonosControlResult(action, value)
      root.reconcilePendingRemoteControls(root.remotePlayback)
      sonosControlRefreshTimer.restart()
    }
    function onControlFailed(deviceId, reason) {
      if (root.pendingConnectDeviceId === deviceId) {
        var device = root.deviceForId(deviceId)
        if (device) root.beginConnectAuthorization(device)
        else {
          root.pendingConnectDeviceId = ""
          root.pendingConnectWakeTried = false
          root.fail(reason)
        }
        return
      }
      root.clearPendingRemoteSeek(0)
      root.clearPendingRemoteVolume(0)
      root.loadPlaybackState()
      root.fail(reason)
    }
  }

  Connections {
    target: connectAuthManager
    function onLoginSucceeded() {
      var requested = root.pendingConnectDeviceId
      var device = root.deviceForId(requested)
      if (!requested || !device) return
      root.statusMessage = "Conectando con " + device.name
      connectAuthManager.withAccessToken(function(token, error) {
        if (root.pendingConnectDeviceId !== requested) return
        if (token) spotifyConnectManager.activate(requested, token)
        else {
          root.pendingConnectDeviceId = ""
      root.fail(error || "Spotify no pudo autorizar este altavoz")
        }
      })
    }
    function onSessionUnavailable(reason) {
      if (!root.pendingConnectDeviceId) return
      root.pendingConnectDeviceId = ""
      root.connectActivationAttempts = 0
      root.pendingConnectWakeTried = false
      root.fail(reason || "Spotify no pudo autorizar este altavoz")
    }
  }

  Timer {
    id: settingsSync
    interval: 0
    onTriggered: root.syncSettings()
  }

  Timer {
    id: catalogCacheSaveTimer
    interval: 500
    repeat: false
    onTriggered: root.flushCatalogCache()
  }

  Timer {
    id: playlistWarmupTimer
    interval: 1500
    repeat: false
    onTriggered: root.warmNextPlaylist()
  }

  Timer {
    id: albumWarmupTimer
    interval: 2000
    repeat: false
    onTriggered: root.warmNextAlbum()
  }

  // SpotifyApi intentionally does not invoke callbacks for an aborted request.
  // If Play interrupts a warmup, clear its local latch and continue later
  // instead of leaving the cache queue permanently paused.
  Timer {
    id: playlistWarmupWatchdog
    interval: 500
    repeat: true
    running: root.playlistWarmupRunning
    onTriggered: {
      if (spotifyApi.backgroundRequests.length > 0) return
      root.playlistWarmupRunning = false
      stop()
      if (root.playlistWarmupQueue.length) playlistWarmupTimer.restart()
    }
  }

  Timer {
    id: sessionSaveTimer
    interval: 200
    repeat: false
    onTriggered: root.flushSessionFile()
  }

  FileView {
    id: sessionFile
    path: root.sessionPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.applySessionFile(text())
    onLoadFailed: root.applySessionFile("")
    onSaved: {
      root.sessionFileHadData = !Api.sessionRecordIsEmpty(root.currentSessionRecord())
      root.sessionFileDirty = false
      root.stripPluginSessionKeys()
    }
    onSaveFailed: {
      if (!ensureStateDir.running) ensureStateDir.running = true
    }
  }

  FileView {
    id: catalogCacheFile
    path: root.catalogCachePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyCatalogCache(text())
    onLoadFailed: root.applyCatalogCache("")
    onSaved: root.catalogCacheDirty = false
    onSaveFailed: if (!ensureStateDir.running) ensureStateDir.running = true
  }

  Process {
    id: ensureStateDir
    running: false
    command: ["/usr/bin/mkdir", "-p", root.stateDir]
    onExited: {
      if (!root.sessionFileReady) sessionFile.reload()
      else if (root.sessionFileDirty) root.flushSessionFile()
      if (!root.catalogCacheReady) catalogCacheFile.reload()
      else if (root.catalogCacheDirty) root.flushCatalogCache()
    }
  }

  Timer {
    id: lyricsPluginLaunchRetry
    interval: 250
    repeat: false
    onTriggered: root.launchLyricsPlugin()
  }

  Timer {
    id: lyricsPluginInstallPoll
    interval: 400
    repeat: true
    onTriggered: if (root.finishLyricsPluginInstallWatch()) stop()
  }

  Process {
    id: lyricsPluginSetupProcess
    running: false
    command: []
    stdout: StdioCollector { id: lyricsPluginSetupStdout; waitForEnd: true }
    stderr: StdioCollector { id: lyricsPluginSetupStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.lyricsPluginBusy = false
      if (Number(exitCode) === 0) {
        root.lyricsPluginOperation = ""
        root.lyricsPluginError = ""
        root.lyricsPluginLaunchAttempts = 0
        lyricsPluginLaunchRetry.restart()
        return
      }
      var detail = String(lyricsPluginSetupStderr.text
        || lyricsPluginSetupStdout.text || "").trim()
      root.lyricsPluginError = root.safeError(detail
        || "No se pudo instalar Omasing.")
    }
  }

  Process {
    id: lyricsPluginLaunchProcess
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: lyricsPluginLaunchStderr; waitForEnd: true }
    onExited: function(exitCode) { root.finishLyricsPluginLaunch(exitCode) }
  }

  Timer {
    id: statusClearTimer
    interval: 4500
    onTriggered: if (!root.lastError) root.statusMessage = ""
  }

  Timer {
    id: deviceProbeTimer
    interval: 750
    repeat: false
    onTriggered: root.probeForLocalDevice()
  }

  Timer {
    id: visibleLocalDeviceRefreshTimer
    interval: 750
    repeat: false
    onTriggered: root.refreshVisibleLocalDevice()
  }

  Timer {
    id: connectActivationTimer
    interval: 750
    repeat: false
    onTriggered: root.refreshActivatedConnectDevice()
  }

  Timer {
    id: remotePlaybackTimer
    interval: Api.remotePlaybackPollInterval(root.uiVisible,
      root.useRemotePlayback, root.hasLocalPlayer)
    repeat: true
    running: Api.remotePlaybackPollShouldRun(root.auth.loggedIn,
      root.remotePlaybackLoading, root.uiVisible, root.useRemotePlayback,
      root.playing)
    onTriggered: root.loadPlaybackState()
  }

  Timer {
    id: localSocketWaitTimer
    interval: 200
    repeat: true
    onTriggered: {
      if (root.backend.ready && root.pendingPlaybackBody) {
        stop()
        root.localSocketWaitAttempts = 0
        root.sendLocalSocketPlayback(root.pendingPlaybackSerial)
        return
      }
      root.localSocketWaitAttempts++
      if (root.localSocketWaitAttempts >= 25) {
        stop()
        root.localSocketWaitAttempts = 0
        if (root.pendingPlaybackBody) {
          root.succeed(Api.localSocketFallbackMessage())
          deviceProbeTimer.restart()
        }
      }
    }
  }

  Timer {
    id: sonosControlRefreshTimer
    interval: 650
    repeat: false
    onTriggered: root.loadPlaybackState()
  }

  Timer {
    id: volumeFlushTimer
    interval: Api.volumeFlushInterval(root.volumeFlushTarget())
    repeat: false
    onTriggered: root.flushVolume()
  }

  Timer {
    id: volumeLiveIdleTimer
    interval: 400
    repeat: false
    onTriggered: {
      root.volumeLiveActive = false
      // Only the remote path skipped its per-command refetch; a local MPRIS
      // write reports the new volume on its own.
      if (root.useRemotePlayback) root.loadPlaybackState()
    }
  }

  Timer {
    id: volumeHoldTimer
    interval: 200
    repeat: true
    onTriggered: root.reconcilePendingSliderVolume()
  }

  Timer {
    id: idleTimer
    interval: 60000
    repeat: true
    running: Api.idleShutdownShouldRun(root.daemon.running, root.hasMedia,
      root.uiVisible, root.idleShutdownMinutes)
    onTriggered: {
      if (Date.now() - root.lastActivityAt >= root.idleShutdownMinutes * 60000)
        root.stopEngine()
    }
  }

  Timer {
    id: sleepDeadlineTimer
    repeat: false
    onTriggered: {
      root.updateSleepCountdown()
      if (root.sleepRemainingSeconds <= 0) root.finishSleepTimer()
      else root.scheduleSleepDeadline()
    }
  }

  Timer {
    id: sleepCountdown
    interval: 1000
    repeat: true
    running: root.sleepMode === "minutes" && root.uiVisible
    onRunningChanged: if (running) root.updateSleepCountdown()
    onTriggered: {
      root.updateSleepCountdown()
      if (root.sleepRemainingSeconds <= 0) root.finishSleepTimer()
    }
  }

  Timer {
    id: sleepContextTimer
    interval: 1800
    repeat: false
    onTriggered: if ((root.sleepMode === "context" || root.sleepMode === "track")
        && root.playbackState === MprisPlaybackState.Stopped)
      root.finishSleepTimer()
  }

  AuthManager {
    id: authManager
    pluginDir: root.pluginDir
  }

  AuthManager {
    id: connectAuthManager
    pluginDir: root.pluginDir
    clientId: "65b708073fc0480ea92a077233ca87bd"
    oauthPort: 8990
    scopes: ["streaming"]
  }

  SpotifyApi {
    id: spotifyApi
    auth: authManager
  }

  SpotifyConnectManager {
    id: spotifyConnectManager
    pluginDir: root.pluginDir
  }

  DaemonManager {
    id: daemonManager
    pluginDir: root.pluginDir
    deviceName: root.deviceName
    bitrateKbps: root.bitrateKbps
    mprisPresent: root.hasLocalPlayer
  }

  BackendClient {
    id: backendClient
    wanted: daemonManager.running && !daemonManager.usingFallbackRuntime
    onErrorCodeChanged: if (errorCode === "audio_key_unavailable")
      root.fail(errorMessage || "Spotify no pudo reproducir esta canción en este equipo")
  }
}
