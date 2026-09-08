pragma ComponentBehavior: Bound

import QtQuick
import QtTest

import ".." as Plugin
import "../Api.js" as Api

TestCase {
  id: testCase
  name: "SpotifyApiTransport"

  property var requests: []
  property double clock: 1000
  property int tokenInvalidations: 0
  property string accessToken: "mock-token"
  property string accessTokenError: ""
  property bool failFactory: false
  property bool failOpen: false
  property bool failSend: false

  QtObject {
    id: fakeAuth

    function withAccessToken(callback) {
      callback(testCase.accessToken, testCase.accessTokenError)
    }
    function invalidateAccessToken() { testCase.tokenInvalidations++ }
  }

  Component {
    id: apiComponent

    Plugin.SpotifyApi {
      auth: fakeAuth
      now: function() { return testCase.clock }
      xhrFactory: function() {
        if (testCase.failFactory) throw new Error("factory failed")
        return testCase.newRequest()
      }
    }
  }

  function newRequest() {
    var xhr = {
      readyState: XMLHttpRequest.UNSENT,
      status: 0,
      responseText: "",
      url: "",
      method: "",
      aborted: false,
      onreadystatechange: null,
      open: function(method, url) {
        if (testCase.failOpen) throw new Error("open failed")
        this.method = method
        this.url = url
        this.readyState = XMLHttpRequest.OPENED
      },
      setRequestHeader: function() {},
      getResponseHeader: function(name) {
        return String(name).toLowerCase() === "retry-after" ? "1" : ""
      },
      send: function() {
        if (testCase.failSend) throw new Error("send failed")
      },
      abort: function() { this.aborted = true }
    }
    requests.push(xhr)
    return xhr
  }

  function complete(xhr, status, body) {
    xhr.status = status
    xhr.responseText = body || "{}"
    xhr.readyState = XMLHttpRequest.DONE
    xhr.onreadystatechange()
  }

  function init() {
    requests = []
    clock = 1000
    tokenInvalidations = 0
    accessToken = "mock-token"
    accessTokenError = ""
    failFactory = false
    failOpen = false
    failSend = false
  }

  function test_priorityStartsMutationsThenInteractiveReads() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    api.request("GET", "/me", null, null, function() {})
    api.request("GET", "/me/player", null, null, function() {})
    api.request("GET", "/me/albums", null, null, function() {})
    api.request("GET", "/search", null, null, function() {},
      { priority: "interactive" })
    api.request("PUT", "/me/player/play", null, null, function() {})
    compare(requests.length, 2)

    complete(requests[0], 200)
    compare(requests.length, 3)
    compare(requests[2].method, "PUT")

    complete(requests[1], 200)
    compare(requests.length, 4)
    verify(requests[3].url.indexOf("/search") >= 0)
  }

  function test_searchKeepsTheExistingAllTypesRequest() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var callbacks = 0
    api.search("miles davis", function(groups, error) {
      callbacks++
      compare(error, "")
    })
    compare(requests.length, 1)
    verify(decodeURIComponent(requests[0].url).indexOf(
      "type=track,artist,album,playlist,show,episode,audiobook") >= 0)
    complete(requests[0], 200, "{\"tracks\":{\"items\":[]}}")
    compare(callbacks, 1)
  }

  function test_catalogCacheKeepsOnlyTheStartupCollections() {
    var rows = []
    for (var i = 0; i < 35; i++) rows.push({ id: String(i) })
    var lastTrackSample = {
      id: "track1",
      uri: "spotify:track:track1",
      name: "Track One",
      subtitle: "Artist One",
      album: "Album One",
      imageUrl: "https://example.com/cover.jpg",
      durationMs: 180000
    }
    var cache = Api.catalogCacheRecord({
      savedAt: 1234,
      playlistsLoaded: true,
      savedTracksLoaded: true,
      savedAlbumsLoaded: true,
      homeLoaded: true,
      playlists: rows,
      savedTracks: rows,
      savedAlbums: rows,
      recentTracks: rows,
      topTracks: rows,
      topArtists: rows,
      lastTrack: lastTrackSample,
      lastContextUri: "spotify:playlist:pl1",
      lastContextItems: [lastTrackSample],
      playlistDetails: {
        one: { item: { id: "one", type: "playlist" }, items: rows },
        invalid: { item: { id: "invalid", type: "album" }, items: rows }
      },
      albumDetails: {
        album: { item: { id: "album", type: "album" }, items: rows }
      },
      secret: "must not persist"
    })
    compare(cache.savedAt, 1234)
    compare(cache.playlists.length, 30)
    compare(cache.savedTracks.length, 30)
    compare(cache.savedAlbums.length, 30)
    compare(cache.playlistDetails.length, 1)
    compare(cache.playlistDetails[0].items.length, 35)
    compare(cache.albumDetails.length, 1)
    compare(cache.lastTrack.id, "track1")
    compare(cache.lastTrack.name, "Track One")
    compare(cache.lastContextUri, "spotify:playlist:pl1")
    compare(cache.lastContextItems.length, 1)
    compare(cache.lastContextItems[0].id, "track1")
    verify(cache.homeLoaded)
    verify(cache.secret === undefined)
    var parsed = Api.parseCatalogCache(Api.encodeCatalogCache(cache))
    compare(parsed.topArtists.length, 30)
    compare(parsed.playlistDetails[0].items.length, 35)
    compare(parsed.albumDetails[0].items.length, 35)
    compare(parsed.lastTrack.id, "track1")
    compare(parsed.lastTrack.name, "Track One")
    compare(parsed.lastContextUri, "spotify:playlist:pl1")
    compare(parsed.lastContextItems.length, 1)
    compare(parsed.lastContextItems[0].id, "track1")
    compare(Api.parseCatalogCache("not json").savedAt, 0)
  }

  function test_normalRequestCancelsActiveBackgroundWarmup() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    api.request("GET", "/playlists/cache/items", null, null, function() {},
      { priority: "background", retryRateLimit: false })
    compare(requests.length, 1)
    verify(!requests[0].aborted)
    clock = 3000
    api.request("PUT", "/me/player/play", null, { uris: [] }, function() {})
    compare(requests.length, 2)
    verify(requests[0].aborted)
    compare(requests[1].method, "PUT")
  }

  function test_searchTimeoutAbortsAndReleasesSlotOnce() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var callbacks = 0
    var error = ""
    api.search("stalled", function(groups, reason) {
      callbacks++
      error = reason
    })
    compare(api.requestsInFlight, 1)
    clock = 9000
    api.expireTimedOutRequests(clock)
    verify(requests[0].aborted)
    verify(error.indexOf("too long") >= 0)
    compare(callbacks, 1)
    compare(api.requestsInFlight, 0)
    compare(api.timedJobs.length, 0)

    complete(requests[0], 0)
    compare(callbacks, 1)
    compare(api.requestsInFlight, 0)
  }

  function test_queuedSearchTimesOutBeforeARequestSlotOpens() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    api.request("GET", "/me", null, null, function() {})
    api.request("GET", "/me/player", null, null, function() {})
    compare(api.requestsInFlight, 2)
    var error = ""
    api.search("queued", function(groups, reason) { error = reason })
    compare(requests.length, 2)
    compare(api.requestQueue.length, 1)
    clock = 9000
    api.expireTimedOutRequests(clock)
    verify(error.indexOf("too long") >= 0)
    compare(api.requestQueue.length, 0)
    compare(api.requestsInFlight, 2)
  }

  function test_search429ReturnsWithoutSilentRetry() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var callbacks = 0
    var error = ""
    api.search("busy", function(groups, reason) {
      callbacks++
      error = reason
    })
    complete(requests[0], 429, "{\"error\":{\"message\":\"Too many requests\"}}")
    compare(callbacks, 1)
    verify(error.indexOf("Spotify is busy") >= 0)
    compare(api.requestQueue.length, 0)
    compare(api.requestsInFlight, 0)
    verify(api.rateLimitedUntil > clock)
  }

  function test_default429StillRetriesAfterCooldown() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var callbacks = 0
    api.request("GET", "/me", null, null, function() { callbacks++ })
    complete(requests[0], 429)
    compare(callbacks, 0)
    compare(api.requestQueue.length, 1)
    clock = api.rateLimitedUntil
    api.pumpRequests()
    compare(requests.length, 2)
    complete(requests[1], 200)
    compare(callbacks, 1)
  }

  function test_401RetriesWithOneTokenInvalidation() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var callbacks = 0
    api.request("GET", "/me", null, null, function() { callbacks++ })
    var firstRequest = requests[0]
    complete(requests[0], 401)
    compare(tokenInvalidations, 1)
    compare(callbacks, 0)
    compare(requests.length, 2)
    complete(firstRequest, 200)
    compare(callbacks, 0)
    complete(requests[1], 200)
    compare(callbacks, 1)
  }

  function test_newSearchCancelsStaleActiveRequest() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var staleCalls = 0
    var currentCalls = 0
    api.search("old", function() { staleCalls++ })
    var oldRequest = requests[0]
    api.search("new", function() { currentCalls++ })
    verify(oldRequest.aborted)
    compare(requests.length, 2)
    complete(oldRequest, 200, "{\"tracks\":{\"items\":[]}}")
    complete(requests[1], 200, "{\"tracks\":{\"items\":[]}}")
    compare(staleCalls, 0)
    compare(currentCalls, 1)
    compare(api.requestsInFlight, 0)
  }

  function test_cancelledQueuedRequestNeverStarts() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    api.request("GET", "/me", null, null, function() {})
    api.request("GET", "/me/player", null, null, function() {})
    var callbacks = 0
    var handle = api.request("GET", "/search", null, null,
      function() { callbacks++ }, {
        priority: "interactive",
        timeoutMs: 8000
      })
    compare(api.requestQueue.length, 1)
    api.abortRequest(handle)
    compare(api.requestQueue.length, 0)
    complete(requests[0], 200)
    compare(requests.length, 2)
    compare(callbacks, 0)
    compare(api.timedJobs.length, 0)
  }

  function test_timeoutUsesInclusiveDeadlineBoundary() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var callbacks = 0
    api.request("GET", "/search", null, null, function() { callbacks++ },
      { timeoutMs: 1000 })
    api.expireTimedOutRequests(1999)
    compare(callbacks, 0)
    verify(!requests[0].aborted)
    clock = 2000
    api.expireTimedOutRequests(clock)
    compare(callbacks, 1)
    verify(requests[0].aborted)
  }

  function test_queuedRateLimitRetryCanTimeOutDuringCooldown() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var callbacks = 0
    var error = ""
    api.request("GET", "/me", null, null, function(status, payload, reason) {
      callbacks++
      error = reason
    }, { timeoutMs: 2000 })
    complete(requests[0], 429)
    compare(api.requestQueue.length, 1)
    clock = 3000
    api.expireTimedOutRequests(clock)
    compare(callbacks, 1)
    verify(error.indexOf("too long") >= 0)
    compare(api.requestQueue.length, 0)
  }

  function test_invalidUrlAndTokenFailureReleaseSlots() {
    var api = createTemporaryObject(apiComponent, testCase)
    verify(api)
    var errors = 0
    api.request("GET", "https://example.com/not-spotify", null, null,
      function(status, payload, error) { if (error) errors++ })
    compare(errors, 1)
    compare(api.requestsInFlight, 0)

    accessToken = ""
    accessTokenError = "Session unavailable"
    api.request("GET", "/me", null, null,
      function(status, payload, error) { if (error) errors++ })
    compare(errors, 2)
    compare(api.requestsInFlight, 0)
  }

  function test_xhrSetupFailuresReleaseSlots() {
    var modes = ["factory", "open", "send"]
    for (var i = 0; i < modes.length; i++) {
      failFactory = modes[i] === "factory"
      failOpen = modes[i] === "open"
      failSend = modes[i] === "send"
      var api = createTemporaryObject(apiComponent, testCase)
      verify(api)
      var callbacks = 0
      api.request("GET", "/me", null, null,
        function(status, payload, error) {
          callbacks++
          verify(error !== "")
        })
      compare(callbacks, 1)
      compare(api.requestsInFlight, 0)
      api.destroy()
    }
  }
}
