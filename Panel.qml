import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "Stations.js" as Stations

Panel {
  id: root
  moduleName: "tirade.nyc-subway"
  ipcTarget: "tirade.nyc-subway"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string helper: Qt.resolvedUrl("bin/nyc-subway-status").toString().replace(/^file:\/\//, "")
  readonly property string tripHelper: Qt.resolvedUrl("bin/nyc-subway-trip").toString().replace(/^file:\/\//, "")
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string feedGroup: String(setting("feedGroup", "1234567S"))
  readonly property string stopId: String(setting("stopId", "127")).replace(/^\s+|\s+$/g, "")
  readonly property string direction: String(setting("direction", "both"))
  readonly property string routeFilter: String(setting("routeFilter", ""))
  readonly property int maxResults: Math.max(1, parseInt(setting("maxResults", 5), 10) || 5)
  readonly property int pollIntervalMs: Math.max(10000, parseInt(setting("pollIntervalMs", 30000), 10) || 30000)
  readonly property string labelOverride: String(setting("label", ""))

  // The bundled MTA station dataset, keyed by this exact stop_id, if the
  // configured stop came from (or matches) that dataset. A hand-typed stop_id
  // that isn't in the dataset still works for arrivals — it just falls back
  // to generic "Uptown"/"Downtown" tab labels instead of the station's real
  // direction signage. stopId can be a comma-joined list for a whole-complex
  // pick (see pickStation below) — direction labels and the context strip
  // are inherently about one physical platform, so this keys off just the
  // primary (first) stop_id even then.
  readonly property var selectedStation: Stations.stationById(Stations.primaryStopId(root.stopId))
  readonly property string upLabel: selectedStation ? selectedStation.north : "Uptown"
  readonly property string downLabel: selectedStation ? selectedStation.south : "Downtown"

  // "You are here" context strip data — a fixed physical property of the
  // station, independent of which direction tab is selected (unlike the
  // trip detail view's approach-side context, which is specific to one
  // train's direction). North goes ABOVE the station and south BELOW,
  // matching the "uptown is up" mental model the spanning arrow points
  // at — contextAbove reads top-to-bottom as farthest-to-nearest (so the
  // nearest northern neighbor sits right above the station), contextBelow
  // is reversed to nearest-to-farthest (so the nearest southern neighbor
  // sits right below it) — the station stays visually centered with
  // neighbors radiating outward either way. Only populated for stations
  // baked into Stations.js (see bin/generate-station-neighbors.py); a
  // hand-typed stop_id outside that dataset just shows no strip at all
  // (not even collapsed).
  readonly property var contextAbove: root.selectedStation ? (root.selectedStation.prevNorth || []) : []
  readonly property var contextBelow: root.selectedStation ? (root.selectedStation.prevSouth ? root.selectedStation.prevSouth.slice().reverse() : []) : []

  // Collapsed by default: header alone (see the header's own MouseArea
  // and chevron), no body content at all — showing the station name a
  // second time down here with nothing else would just be noise. Expanded
  // reveals the 2+2 flanking rows; resets whenever the tracked station
  // changes (see resetForNewStation below).
  property bool approachExpanded: false

  readonly property string stationLabel: labelOverride !== "" ? labelOverride : stopId

  property var arrivals: []
  // Alerts specific to this station's routes. System-wide notices (holiday
  // schedules, systemwide advisories) are split out into generalAlerts by
  // the helper script — they aren't about this stop, so they don't belong
  // in the same list; see tooltipText for where they surface instead.
  property var alerts: []
  property var generalAlerts: []
  property string lastError: ""
  property string lastErrorDetail: ""
  property bool loading: false
  property double loadingStartedAt: 0
  property int loadingElapsedSeconds: 0

  // True only for a "cold" load — switching stations, or the very first
  // fetch — where there's nothing on screen yet to show instead. A
  // background refresh of an already-populated board stays quiet (small
  // spinner near the header) rather than yanking the list away every
  // pollIntervalMs.
  readonly property bool coldLoading: root.loading && root.arrivals.length === 0 && root.lastError === ""

  Timer {
    interval: 1000
    running: root.loading
    repeat: true
    onTriggered: root.loadingElapsedSeconds = Math.max(0, Math.round((Date.now() - root.loadingStartedAt) / 1000))
  }

  // More than 2 station alerts is enough to bury the arrivals list a
  // commuter actually opened this for, so beyond that they start collapsed
  // behind a count badge instead of full-size banners.
  readonly property bool alertsNeedCollapse: alerts.length > 2
  property bool alertsExpanded: false

  // Routes with live arrivals right now, vs. every route that's actually
  // part of this station regardless of whether it's currently running.
  // A line with no service today (skip-stop, reroute, suspended) is still
  // part of the system here — it shouldn't just vanish from the badges as
  // if it never served this stop; see notRunningRoutes below.
  readonly property var availableRoutes: Model.distinctRoutes(arrivals, Stations.makeRouteComparator(root.feedGroup))
  // Union of routes across every stop_id in a (possibly multi-id, for a
  // whole-complex pick) stopId — falls back to availableRoutes for a
  // hand-typed stop_id outside the bundled dataset, same as before.
  readonly property var allStationRoutes: {
    var routes = Stations.routesForStopId(root.stopId)
    return routes.length > 0 ? routes : root.availableRoutes
  }

  // Slow on/off blink driving the not-currently-running badges below,
  // toggling each between its route letter and a warning glyph. Only runs
  // while the popup is open — no reason to tick a timer against a hidden UI.
  property bool blinkPhase: false
  Timer {
    interval: 1400
    running: root.opened
    repeat: true
    onTriggered: root.blinkPhase = !root.blinkPhase
  }

  // Routes to check for active service alerts: the station's real route
  // set when it's a known stop, else whatever the live feed is actually
  // showing. A delay/reroute is often exactly why a route isn't showing up
  // in arrivals at all, so this intentionally isn't limited to availableRoutes.
  readonly property string alertRoutes: (selectedStation ? selectedStation.routes : root.availableRoutes).join(",")

  // The direction toggle only makes sense when the feed actually carries
  // both directions; a station configured for one direction only shows that
  // direction with no tabs.
  readonly property bool bothDirections: root.direction === "both"
  property string selectedDirection: root.direction === "S" ? "S" : "N"

  // Arrivals-list time format: relative countdown ("4m") by default, or an
  // absolute clock time ("4:16 PM") when toggled via the stopwatch icon
  // next to the direction tabs. A relative countdown is more useful for
  // "should I leave now", but it keeps decaying as time passes and the
  // list re-polls — some riders would rather see a fixed departure time
  // they can compare against a clock instead of doing that math themselves.
  property bool showClockTime: false

  readonly property var visibleArrivals: Model.arrivalsFor(root.arrivals, root.selectedDirection, "", root.maxResults)

  // visibleArrivals, not the raw arrivals list — the bar's "next train"
  // must match whatever the popup would actually show if opened right now
  // (the currently-selected direction tab, and routeFilter if set).
  // Otherwise the bar can advertise a train (e.g. a soonest-overall
  // downtown arrival) that never appears in the list once you open it,
  // because you're looking at the Uptown tab.
  readonly property string barLabel: stopId === "" ? "" : (" " + Model.barText(labelOverride, stopId, visibleArrivals, alerts.length))
  // System-wide notices live here rather than in the popup body: a
  // "subways on a holiday schedule" banner isn't about this station, so it
  // gets a mention on hover instead of competing with the arrivals list
  // for space every time you open the popup.
  readonly property string tooltipText: stopId === ""
    ? "OMTArchy - NYC Subway MTA · set a Stop ID in this widget's settings"
    : "OMTArchy - NYC Subway MTA · " + stationLabel
      + (visibleArrivals.length > 0 ? " · Next: " + Model.nextArrivalPhrase(visibleArrivals[0].route, visibleArrivals[0].minutes) : "")
      + (lastError !== "" ? " · " + Model.errorText(lastError) : "")
      + (alerts.length > 0 ? " · " + alerts.length + " service alert" + (alerts.length > 1 ? "s" : "") : "")
      + (generalAlerts.length > 0 ? " · " + generalAlerts[0].header : "")

  // ---- Legend: a static explainer for the UI language that's accumulated
  // (route bullet colors, the blinking "not running" badge, the alert count
  // badge, the direction tabs) — for a first-time user, not a filter or a
  // control. Toggled the same way pickerOpen/alertsExpanded are.
  property bool showLegend: false

  // ---- Station picker: search by name and/or browse by line, replacing the
  // popup's normal content while open. Two purposes share this one picker:
  // "station" (the default) picks a specific line's stop_id and persists it
  // as this widget's tracked station (see persistSettings/pickStation);
  // "tripOrigin"/"tripDestination" pick a whole station complex for the
  // trip planner below instead — those don't persist anything, they just
  // feed an ephemeral query.
  property bool pickerOpen: false
  property string pickerPurpose: "station"
  property string pickerQuery: ""
  property string pickerRouteFilter: ""
  readonly property var pickerResults: Stations.searchStationGroups(root.pickerQuery, root.pickerRouteFilter, 25)
  readonly property var pickerRoutes: Stations.allRoutes()

  function openPicker(purpose) {
    root.pickerPurpose = purpose || "station"
    root.pickerQuery = ""
    root.pickerRouteFilter = ""
    root.pickerOpen = true
    Qt.callLater(function() { if (searchField) { searchField.text = ""; searchField.forceActiveFocus() } })
  }

  function closePicker() {
    root.pickerOpen = false
  }

  // A trip-mode pick selects the whole complex (every line at that station),
  // not one platform — the trip planner needs to try all of them, since any
  // of the complex's lines could be the one with a live connection.
  function selectTripStation(group) {
    if (!group) return
    if (root.pickerPurpose === "tripOrigin") root.tripOrigin = group
    else if (root.pickerPurpose === "tripDestination") root.tripDestination = group
    root.closePicker()
  }

  // Same mechanism the built-in clock widget uses to persist a value a user
  // picked interactively: merge into this widget's existing shell.json entry
  // and write the whole entry back. There's no separate per-plugin state
  // file for a bar-widget's settings, only this inline layout entry — which
  // is also why this widget stays single-instance (allowMultiple: false):
  // updateEntryInline matches by plugin id, so a second instance would
  // clobber the first one's station on every pick.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function pickStation(station) {
    if (!station) return
    persistSettings({ stopId: station.id, feedGroup: station.feedGroup, label: station.name })
    root.closePicker()
  }

  // ---- Trip planner: an on-demand "how do I get from A to B" lookup. This
  // is entirely ephemeral — nothing here is persisted via persistSettings,
  // so it never touches what the bar pill tracks. Station-to-station only:
  // it finds a live subway connection, never walking/driving directions.
  property bool tripPlannerOpen: false
  property var tripOrigin: null
  property var tripDestination: null
  property var tripResult: null
  property bool tripLoading: false
  property string tripError: ""
  property string tripErrorDetail: ""

  // Same staleness-guard idea as the arrivals fetch: a query in flight when
  // the user changes From/To (or closes the planner) shouldn't get to apply
  // its (by-then-stale) result.
  readonly property string tripRequestKey: (tripOrigin ? tripOrigin.key : "") + ">" + (tripDestination ? tripDestination.key : "")
  property string tripPendingKey: ""

  function openTripPlanner() {
    // Defaults the origin to whatever station this widget is currently
    // tracking — you're almost always planning a trip FROM here — without
    // ever clobbering an in-progress pick (only sets it when there isn't
    // one already).
    if (!root.tripOrigin && root.stopId !== "") {
      var group = Stations.stationGroupForStopId(root.stopId)
      if (group) root.tripOrigin = group
    }
    root.tripPlannerOpen = true
  }

  function closeTripPlanner() {
    root.tripPlannerOpen = false
  }

  function swapTripStations() {
    var a = root.tripOrigin
    root.tripOrigin = root.tripDestination
    root.tripDestination = a
  }

  // ---- Train detail: tapping a specific upcoming train in the arrivals
  // list shows every stop *that exact train* makes from here on, each with
  // an ETA — "board here, then these are the next stops," matching the
  // reference app. A snapshot of the tapped arrival (with its embedded
  // stops list, already fetched as part of the normal arrivals poll — no
  // extra request), not re-synced against later polls; reopening gets a
  // fresh one.
  property var selectedTrain: null
  property bool trainDetailOpen: false

  function openTrainDetail(train) {
    if (!train) return
    root.selectedTrain = train
    root.trainDetailOpen = true
  }

  function closeTrainDetail() {
    root.trainDetailOpen = false
  }

  // The 2 physical neighbor stations immediately before the boarding
  // station, on the approach side of this specific train's direction (same
  // prevNorth/prevSouth data as the arrivals-list context strip) — shown
  // above the boarding row so the trip detail isn't forward-only anymore.
  readonly property var tripApproachNeighbors: (root.selectedStation && root.selectedTrain)
    ? ((root.selectedTrain.dir === "S" ? root.selectedStation.prevNorth : root.selectedStation.prevSouth) || [])
    : []

  // Combined display list for the trip detail Repeater: static "before"
  // context rows (no live time — they're not part of this trip's actual
  // stop_time_updates), then this train's full fetched stop list starting
  // with the boarding station at index 0.
  readonly property var tripStopsDisplay: {
    if (!root.selectedTrain) return []
    var before = root.tripApproachNeighbors.map(function(n) {
      return { stopId: n.id, name: n.name, epoch: 0, isContext: true, isBoard: false }
    })
    var forward = root.selectedTrain.stops || []
    var forwardRows = forward.map(function(s, i) {
      return { stopId: s.stopId, epoch: s.epoch, isContext: false, isBoard: i === 0 }
    })
    return before.concat(forwardRows)
  }

  // Swaps to the opposite direction without leaving the trip detail panel:
  // if this same route currently has a live train the other way, jump
  // straight to its detail; otherwise fall back to closing back out to the
  // (now-flipped) arrivals list, since there's nothing to show in-panel.
  function swapTrainDirection() {
    if (!root.selectedTrain) return
    var newDir = root.selectedTrain.dir === "S" ? "N" : "S"
    root.selectedDirection = newDir
    var match = null
    for (var i = 0; i < root.arrivals.length; i++) {
      var a = root.arrivals[i]
      if (a.dir === newDir && a.route === root.selectedTrain.route) { match = a; break }
    }
    if (match) {
      root.selectedTrain = match
    } else {
      root.closeTrainDetail()
    }
  }

  // Deduped "stopId:feedGroup,..." for every line grouping at a complex.
  function joinPairs(pills) {
    var seen = {}
    var out = []
    for (var i = 0; i < pills.length; i++) {
      var key = pills[i].stopId + ":" + pills[i].feedGroup
      if (seen[key]) continue
      seen[key] = true
      out.push(key)
    }
    return out.join(",")
  }

  function distinctRoutesOf(pills) {
    var seen = {}
    var out = []
    for (var i = 0; i < pills.length; i++) {
      if (seen[pills[i].route]) continue
      seen[pills[i].route] = true
      out.push(pills[i].route)
    }
    return out
  }

  function runTripQuery() {
    if (!root.tripOrigin || !root.tripDestination || tripProc.running) return
    var originRoutes = root.distinctRoutesOf(root.tripOrigin.pills)
    var destRoutes = root.distinctRoutesOf(root.tripDestination.pills)
    var candidates = Stations.transferCandidates(originRoutes, destRoutes, [root.tripOrigin.key, root.tripDestination.key])
    var transferPairs = candidates.slice(0, 12).map(function(c) {
      return c.entryPill.stopId + ":" + c.entryPill.feedGroup + ":" + c.exitPill.stopId + ":" + c.exitPill.feedGroup
    }).join(",")

    root.tripPendingKey = root.tripRequestKey
    root.tripLoading = true
    tripProc.command = ["bash", "-lc", Model.tripPollScript(
      root.tripHelper,
      root.joinPairs(root.tripOrigin.pills),
      root.joinPairs(root.tripDestination.pills),
      transferPairs
    )]
    tripProc.running = true
  }

  onTripOriginChanged: { root.tripResult = null; root.tripError = ""; if (root.tripOrigin && root.tripDestination) root.runTripQuery() }
  onTripDestinationChanged: { root.tripResult = null; root.tripError = ""; if (root.tripOrigin && root.tripDestination) root.runTripQuery() }

  function open() {
    root.controller.show()
    root.refresh()
  }

  function openFromHotkey() {
    root.controller.show()
    root.refresh()
  }

  function close() {
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  // Identifies what a request was actually asking for, so a response that
  // arrives after the user has already moved on can be told apart from one
  // that's still current.
  readonly property string requestKey: root.feedGroup + "|" + root.stopId + "|" + root.direction + "|" + root.routeFilter
  property string pendingRequestKey: ""

  function refresh() {
    if (root.stopId === "") return
    if (pollProc.running) {
      // A fetch is already in flight for whatever was configured when it
      // started — by the time it finishes that may no longer be current
      // (the user switched stations again in the meantime). Stopping and
      // immediately restarting the same Process back-to-back is flaky (it
      // can come back with no output at all), so instead: let it finish
      // naturally, and onStreamFinished below re-checks requestKey and
      // calls refresh() again right away if it's gone stale. Worst case
      // that's one extra fetch's worth of delay (under a second, typically)
      // instead of silently waiting for the next pollIntervalMs tick.
      return
    }
    root.pendingRequestKey = root.requestKey
    root.loading = true
    root.loadingStartedAt = Date.now()
    root.loadingElapsedSeconds = 0
    pollProc.command = ["bash", "-lc", Model.pollScript(root.helper, root.feedGroup, root.stopId, root.direction, root.routeFilter, root.alertRoutes)]
    pollProc.running = true
  }

  // A fresh station means stale data too: without this, the previous
  // stop's arrivals stay on screen — looking current — for however long the
  // new fetch takes, which is actively misleading rather than just slow.
  function resetForNewStation() {
    root.arrivals = []
    root.alerts = []
    root.generalAlerts = []
    root.lastError = ""
    root.lastErrorDetail = ""
    root.alertsExpanded = false
    root.approachExpanded = false
  }

  onStopIdChanged: { resetForNewStation(); refresh() }
  onFeedGroupChanged: { resetForNewStation(); refresh() }
  onDirectionChanged: { selectedDirection = root.direction === "S" ? "S" : "N"; refresh() }
  onRouteFilterChanged: refresh()
  onOpenedChanged: if (opened) refresh()
  Component.onCompleted: refresh()

  Process {
    id: pollProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // This result was for whatever was configured when the fetch
        // started; the user may have switched stations again while it was
        // in flight. If so it's stale — don't let it overwrite (or get
        // mistaken for) data about the station actually on screen now.
        // refresh() immediately re-fetches for whatever is current instead
        // of leaving the board stuck until the next pollIntervalMs tick.
        if (root.pendingRequestKey !== root.requestKey) {
          Qt.callLater(root.refresh)
          return
        }

        var parsed = Model.parseArrivals(text)
        root.loading = false
        if (parsed.ok) {
          root.arrivals = parsed.arrivals
          root.alerts = parsed.alerts
          root.generalAlerts = parsed.generalAlerts
          root.lastError = ""
        } else {
          root.lastError = parsed.error
          root.lastErrorDetail = parsed.detail || ""
        }
      }
    }
  }

  Timer {
    interval: root.pollIntervalMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Process {
    id: tripProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // Same staleness guard as pollProc above: a query answers whatever
        // From/To was set when it started, which may not be current by the
        // time it finishes.
        if (root.tripPendingKey !== root.tripRequestKey) {
          Qt.callLater(root.runTripQuery)
          return
        }

        var parsed = Model.parseTripResult(text)
        root.tripLoading = false
        if (parsed.ok) {
          root.tripResult = { direct: parsed.direct, transfers: parsed.transfers }
          root.tripError = ""
          root.tripErrorDetail = ""
        } else {
          root.tripResult = null
          root.tripError = parsed.error
          root.tripErrorDetail = parsed.detail || ""
        }
      }
    }
  }

  // Refreshes the trip result periodically while the planner is open with
  // both stations picked — the same "keep it current while you're looking
  // at it" spirit as the arrivals poll timer above.
  Timer {
    interval: root.pollIntervalMs
    running: root.tripPlannerOpen && !!root.tripOrigin && !!root.tripDestination
    repeat: true
    onTriggered: root.runTripQuery()
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  // KeyboardPanel, not PopupCard: PopupCard renders inside the bar's own
  // surface, which never requests real Wayland keyboard focus, so a
  // TextField inside one can be clicked but never actually typed into.
  // KeyboardPanel is its own layer-shell surface with an explicit
  // Exclusive-then-OnDemand focus grab — the same reason weather's location
  // search uses it instead of PopupCard.
  KeyboardPanel {
    id: popup
    anchorItem: root.anchorItem
    bar: root.bar
    owner: root.barIdentity
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(320))
    contentHeight: popup.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Let the search field receive plain letters normally instead of
      // PanelKeyCatcher's vim-style j/k/h/l/x navigation intercepting them.
      blocked: searchField.activeFocus
      onCloseRequested: root.pickerOpen ? root.closePicker() : root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

    Flickable {
      id: scroll
      anchors.fill: parent
      contentWidth: width
      contentHeight: content.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height

      Column {
        id: content
        width: scroll.width
        spacing: Style.space(14)

        // ================= Arrivals view =================
        Column {
          id: arrivalsView
          visible: !root.pickerOpen && !root.tripPlannerOpen && !root.trainDetailOpen
          width: parent.width
          spacing: Style.space(14)

          Item {
            width: parent.width
            height: Math.max(headerIcon.implicitHeight, headerTextColumn.implicitHeight)

            // Doubles as the "you are here" context strip's expand/collapse
            // trigger (see the contextRegion block below) -- declared first
            // so it sits behind the "Change"/"Plan a Trip" links' own
            // MouseAreas and never steals their clicks. Only live when
            // there's real neighbor data to show.
            MouseArea {
              anchors.fill: parent
              enabled: !!root.selectedStation
              cursorShape: Qt.PointingHandCursor
              onClicked: root.approachExpanded = !root.approachExpanded
            }

            Text {
              id: headerIcon
              textFormat: Text.PlainText
              text: ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.top: parent.top
            }

            Column {
              id: headerTextColumn
              anchors.left: headerIcon.right
              anchors.leftMargin: Style.space(10)
              // Yields to the stopwatch icon (and the loading spinner
              // behind it) — without this, a long station name plus its
              // own trailing expand/collapse chevron would run right into
              // them instead of eliding before it. The help link used to
              // live up here too (see subtitleRow below for where it
              // moved) and left even less room for the chevron.
              anchors.right: clockToggleIcon.left
              anchors.rightMargin: Style.space(8)
              anchors.top: parent.top
              spacing: Style.space(2)
              Text {
                textFormat: Text.PlainText
                width: parent.width
                elide: Text.ElideRight
                text: (root.stationLabel !== "" ? root.stationLabel : "OMTArchy - NYC Subway MTA")
                  + (root.selectedStation ? (root.approachExpanded ? "  ⌃" : "  ⌄") : "")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Row {
                id: subtitleRow
                spacing: Style.space(8)

                Text {
                  textFormat: Text.PlainText
                  text: root.stopId === "" ? "No stop configured" : ("Stop " + root.stopId)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Text {
                  textFormat: Text.PlainText
                  text: "|"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                TextLink {
                  text: "Change"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  onActivated: root.openPicker()
                }
                Text {
                  textFormat: Text.PlainText
                  text: "|"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                TextLink {
                  text: "Plan a Trip"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  onActivated: root.openTripPlanner()
                }
                Text {
                  textFormat: Text.PlainText
                  text: "|"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                // Was a bordered circular "?" badge pinned to the header's
                // top-right corner — moved down here so the top row has
                // room for the title's trailing expand/collapse chevron
                // next to the stopwatch icon, instead of the two competing
                // for space.
                TextLink {
                  text: "Help"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  onActivated: root.showLegend = !root.showLegend
                }
              }
            }

            // Time-format toggle for the arrivals list below: flips every
            // row between a relative countdown ("4m") and an absolute
            // clock time ("4:16 PM"). Lives here in the header's icon
            // cluster rather than as its own line further down -- it's a
            // small, infrequently-used control, not worth a permanent gap
            // in the layout -- and staying here keeps it available even
            // when the direction-tab row is hidden (a single-direction
            // station never shows tabs, but the arrivals list -- and so
            // this toggle -- still applies).
            IconTapText {
              id: clockToggleIcon
              visible: root.stopId !== "" && root.visibleArrivals.length > 0
              text: "⏱"
              color: root.showClockTime ? Color.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              anchors.right: parent.right
              anchors.top: parent.top
              onActivated: root.showClockTime = !root.showClockTime
            }

            Text {
              textFormat: Text.PlainText
              visible: root.loading
              // A circular-notch glyph, not an arrow: rotating an
              // asymmetric arrow (↻) flips it upside down every half-turn,
              // which reads as broken rather than as a spinner.
              text: ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              anchors.right: clockToggleIcon.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: clockToggleIcon.verticalCenter

              RotationAnimator on rotation {
                running: root.loading
                from: 0; to: 360
                duration: 900
                loops: Animation.Infinite
              }
            }
          }

          // ---- Legend: static, non-interactive explainer for a first-time
          // user. Nothing here reacts to live data.
          Rectangle {
            visible: root.showLegend
            width: parent.width
            height: legendColumn.implicitHeight + Style.space(16)
            radius: Style.cornerRadius
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
            border.width: 1
            border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.16)

            Column {
              id: legendColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(8)
              spacing: Style.space(8)

              Row {
                width: parent.width
                Text {
                  textFormat: Text.PlainText
                  text: "HOW TO READ THIS"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                  font.bold: true
                }
              }

              Repeater {
                model: [
                  { sample: "6", color: "#00933C", note: "A colored circle is a subway line. Each row's circle shows which line that train is on." },
                  { sample: "⚠", color: "#5A6268", note: "A dim, blinking badge means that line isn't running right now — it's still part of the station, just not in service." },
                  { sample: "3", color: "#E8A33D", note: "The number next to \"Service Alerts\" is how many are active for this station's lines. Tap it to show or hide them." },
                  { sample: "⇄", color: "#5A6268", note: "\"Uptown\"/\"Downtown\" (or a station's real signage, like \"Queens\"/\"Manhattan\") picks which direction's trains are listed." }
                ]
                delegate: Row {
                  required property var modelData
                  width: legendColumn.width
                  spacing: Style.space(10)

                  Rectangle {
                    width: Style.space(22)
                    height: Style.space(22)
                    radius: width / 2
                    color: modelData.color
                    anchors.top: parent.top
                    Text {
                      textFormat: Text.PlainText
                      anchors.centerIn: parent
                      text: modelData.sample
                      color: "#FFFFFF"
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }

                  Text {
                    textFormat: Text.PlainText
                    width: legendColumn.width - Style.space(32)
                    wrapMode: Text.WordWrap
                    text: modelData.note
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }
            }
          }

          // ---- "You are here" context strip. Fully collapsed by default —
          // no body content at all, since the header above already carries
          // the station name and its own expand/collapse trigger; repeating
          // the name down here with nothing else would just be noise.
          // Expanded, this whole region (all 5 rows, not just one of them)
          // is one big tap target to collapse back — no hunting for a
          // specific row. A spanning arrow on the left points up the
          // uptown direction, since the list's order is fixed regardless
          // of which direction tab is selected (north above, south below).
          Item {
            id: contextRegion
            visible: root.stopId !== "" && !!root.selectedStation && root.approachExpanded
            width: parent.width
            height: contextRows.implicitHeight

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.approachExpanded = false
            }

            Item {
              id: contextArrow
              width: Style.space(18)
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.bottom: parent.bottom

              Text {
                id: contextArrowHead
                textFormat: Text.PlainText
                text: "▲"
                color: root.dim
                font.pixelSize: Style.font.caption
                anchors.top: parent.top
                anchors.horizontalCenter: parent.horizontalCenter
              }

              Rectangle {
                width: Style.space(2)
                color: root.dim
                anchors.top: contextArrowHead.bottom
                anchors.bottom: parent.bottom
                anchors.horizontalCenter: parent.horizontalCenter
              }
            }

            Column {
              id: contextRows
              anchors.left: contextArrow.right
              anchors.leftMargin: Style.space(6)
              anchors.right: parent.right
              spacing: 0

              Repeater {
                model: root.contextAbove
                delegate: ContextStopRow {
                  required property var modelData
                  width: contextRows.width
                  label: modelData.name
                  dotColor: root.dim
                  textColor: root.dim
                  fontFamily: root.fontFamily
                }
              }

              Item {
                width: contextRows.width
                height: Style.space(32)

                Row {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Rectangle {
                    width: Style.space(10)
                    height: Style.space(10)
                    radius: width / 2
                    color: Color.accent
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: root.selectedStation ? root.selectedStation.name : ""
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                }
              }

              Repeater {
                model: root.contextBelow
                delegate: ContextStopRow {
                  required property var modelData
                  width: contextRows.width
                  label: modelData.name
                  dotColor: root.dim
                  textColor: root.dim
                  fontFamily: root.fontFamily
                }
              }
            }
          }


          // ---- Service alerts: currently-active delays/reroutes/schedule
          // changes for this stop's routes. The single most important thing
          // a commuter needs at a glance beyond "when's my train" — a train
          // that's "due" doesn't help if the whole line is skipping stops.
          // A count badge always summarizes them; past 2, the full banners
          // stay collapsed behind it rather than burying the arrivals list.
          Column {
            visible: root.alerts.length > 0
            width: parent.width
            spacing: Style.space(8)

            Item {
              width: alertSummaryRow.implicitWidth
              height: alertSummaryRow.implicitHeight

              Row {
                id: alertSummaryRow
                spacing: Style.space(8)

                Rectangle {
                  width: Math.max(height, alertCountText.implicitWidth + Style.space(10))
                  height: Style.space(20)
                  radius: height / 2
                  color: "#E8A33D"
                  anchors.verticalCenter: parent.verticalCenter

                  Text {
                    id: alertCountText
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    text: String(root.alerts.length)
                    color: "#1A1A1A"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  text: "Service Alerts"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  textFormat: Text.PlainText
                  visible: root.alertsNeedCollapse
                  text: root.alertsExpanded ? "▲ Hide" : "▼ Show"
                  color: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(4)
                enabled: root.alertsNeedCollapse
                cursorShape: root.alertsNeedCollapse ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: root.alertsExpanded = !root.alertsExpanded
              }
            }

            Repeater {
              model: (!root.alertsNeedCollapse || root.alertsExpanded) ? root.alerts : []
              delegate: Rectangle {
                required property var modelData
                width: arrivalsView.width
                height: alertText.implicitHeight + Style.space(16)
                radius: Style.cornerRadius
                color: Qt.rgba(0.9, 0.55, 0.1, 0.14)
                border.width: 1
                border.color: Qt.rgba(0.9, 0.55, 0.1, 0.4)

                Row {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.margins: Style.space(8)
                  spacing: Style.space(8)

                  Text {
                    textFormat: Text.PlainText
                    text: "⚠"
                    color: "#E8A33D"
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    id: alertText
                    textFormat: Text.PlainText
                    width: parent.width - Style.space(30)
                    wrapMode: Text.WordWrap
                    text: modelData.header
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }
            }
          }

          // ---- Error callout: shown the moment a fetch fails, not just
          // silently left blank — a commuter needs to know right away that
          // the board might be wrong, not guess from an empty screen.
          Rectangle {
            visible: root.stopId !== "" && root.lastError !== ""
            width: parent.width
            height: errorColumn.implicitHeight + Style.space(16)
            radius: Style.cornerRadius
            color: Qt.rgba(0.85, 0.25, 0.2, 0.14)
            border.width: 1
            border.color: Qt.rgba(0.85, 0.25, 0.2, 0.45)

            Column {
              id: errorColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(8)
              spacing: Style.space(4)

              Row {
                spacing: Style.space(8)
                Text {
                  textFormat: Text.PlainText
                  text: "⚠"
                  color: "#E8604D"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  textFormat: Text.PlainText
                  width: errorColumn.width - Style.space(60)
                  wrapMode: Text.WordWrap
                  text: Model.errorText(root.lastError)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                TextLink {
                  text: "Retry"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  hitMargin: Style.space(6)
                  onActivated: root.refresh()
                }
              }

              Text {
                textFormat: Text.PlainText
                visible: root.lastErrorDetail !== ""
                width: errorColumn.width
                wrapMode: Text.WordWrap
                text: root.lastErrorDetail
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---- Cold-load indicator: this station has nothing on screen
          // yet, so say so plainly instead of leaving a blank gap — with a
          // spinner and a running seconds counter so a slow fetch still
          // reads as "working" rather than "stuck."
          Row {
            visible: root.coldLoading
            spacing: Style.space(10)

            Text {
              textFormat: Text.PlainText
              text: ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              anchors.verticalCenter: parent.verticalCenter

              RotationAnimator on rotation {
                running: root.coldLoading
                from: 0; to: 360
                duration: 900
                loops: Animation.Infinite
              }
            }

            Text {
              textFormat: Text.PlainText
              text: "Loading arrivals" + (root.loadingElapsedSeconds > 0 ? " (" + root.loadingElapsedSeconds + "s)" : "…")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.stopId === ""
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Tap \"Change\" above to search for a station or browse by line."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // ---- Route badges: every line that's actually part of this
          // station, for context only — not a filter. A commuter picks a
          // station and a direction; which line a given train runs on is
          // what each row's own bullet is for, not something worth
          // narrowing the whole list down to first. A line with no live
          // arrivals right now (skip-stop, reroute, suspended) stays on the
          // board — it's still part of the system here — but blinks between
          // its letter and a warning glyph so it reads as "not running now"
          // rather than silently disappearing as if it never served this stop.
          Flow {
            visible: root.stopId !== "" && root.allStationRoutes.length > 0
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.allStationRoutes
              delegate: RoutePill {
                required property string modelData
                route: modelData
                diameter: Style.space(24)
                labelFontFamily: root.fontFamily
                labelPixelSize: Style.font.caption
                // Neutral (not flagged as "not running") while the very
                // first fetch for this station is still in flight — there's
                // no live data yet to say otherwise, so don't blink every
                // badge red just because nothing has loaded.
                running: root.coldLoading || root.availableRoutes.indexOf(modelData) !== -1
                blinkPhase: root.blinkPhase
              }
            }
          }

          // ---- Direction toggle, only when the feed carries both. Labels
          // come from the station's real signage when it's a known station
          // (e.g. "Manhattan"/"Queens" for the 7 at Court Sq), else a
          // generic Uptown/Downtown fallback.
          Row {
            // 1px inset on both sides: this Row would otherwise sit exactly
            // flush against the enclosing Flickable's own clip:true bounds
            // (the KeyboardPanel's card padding insets the Flickable itself
            // from the popup's border, but nothing insets this Row from the
            // Flickable's own edge) — a Rectangle border drawn exactly on
            // that boundary loses its outer stroke to subpixel/clip
            // rounding on the left tab specifically. The tiny margin here
            // keeps both tabs' borders fully inside the clip region.
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 1
            anchors.rightMargin: 1
            visible: root.stopId !== "" && root.bothDirections
            spacing: Style.space(6)

            Repeater {
              model: ["N", "S"]
              delegate: Rectangle {
                id: dirTab
                required property string modelData
                readonly property bool selected: root.selectedDirection === modelData
                readonly property bool hovered: dirArea.containsMouse
                width: Math.floor((parent.width - Style.space(6)) / 2)
                height: Style.space(34)
                radius: Style.cornerRadius
                antialiasing: true
                color: selected
                  ? Style.selectedFillFor(root.foreground, Color.accent)
                  : (hovered ? Style.hoverFillFor(root.foreground, Color.accent) : Style.normalFillFor(root.foreground, Color.accent))
                border.width: selected ? 1 : (hovered ? 1 : 0)
                border.color: Color.accent

                Behavior on color { ColorAnimation { duration: 100 } }

                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: dirTab.modelData === "S" ? root.downLabel : root.upLabel
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: dirTab.selected
                }

                MouseArea {
                  id: dirArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.selectedDirection = dirTab.modelData
                }
              }
            }
          }

          // ---- Arrivals list for the selected direction (+ route, if picked).
          Column {
            visible: root.stopId !== "" && root.visibleArrivals.length > 0
            width: parent.width
            spacing: 0

            Repeater {
              model: root.visibleArrivals
              delegate: Item {
                id: arrivalRow
                required property var modelData
                readonly property bool hovered: arrivalRowArea.containsMouse
                width: arrivalsView.width
                height: Style.space(44)

                Rectangle {
                  anchors.fill: parent
                  color: arrivalRow.hovered ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
                }

                Row {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(10)

                  RoutePill {
                    route: modelData.route
                    diameter: Style.space(26)
                    labelFontFamily: root.fontFamily
                    labelPixelSize: Style.font.bodySmall
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    textFormat: Text.PlainText
                    // "4:16 PM" needs more room than "27m"/"now" — widen
                    // the reserved time-column space to match whichever
                    // format is currently showing so it never gets clipped.
                    width: parent.width - Style.space(26 + (root.showClockTime ? 85 : 60) + 30)
                    anchors.verticalCenter: parent.verticalCenter
                    text: Model.destinationFor(modelData.route, modelData.dir)
                    elide: Text.ElideRight
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.showClockTime ? Model.formatClockTime(modelData.epoch) : Model.formatMinutes(modelData.minutes)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: ">"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Rectangle {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  height: Style.spacing.hairline
                  color: root.foreground
                  opacity: 0.1
                }

                MouseArea {
                  id: arrivalRowArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openTrainDetail(arrivalRow.modelData)
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.stopId !== "" && root.lastError === "" && !root.loading && root.arrivals.length > 0 && root.visibleArrivals.length === 0
            width: parent.width
            text: "No " + (root.selectedDirection === "S" ? root.downLabel : root.upLabel).toLowerCase() + " trains reported right now."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            textFormat: Text.PlainText
            visible: root.stopId !== "" && root.lastError === "" && root.arrivals.length === 0 && !root.loading
            width: parent.width
            text: "No trains reported for this stop right now."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ================= Train detail view =================
        // "Board here, then these are the next stops" for one specific
        // upcoming train — what tapping an arrivals-list row opens.
        Column {
          id: trainDetailView
          visible: root.trainDetailOpen && !!root.selectedTrain
          width: parent.width
          spacing: Style.space(12)

          Item {
            width: parent.width
            height: Math.max(trainDetailBadge.height, trainDetailTextColumn.implicitHeight)

            RoutePill {
              id: trainDetailBadge
              route: root.selectedTrain ? root.selectedTrain.route : ""
              emptyColor: root.dim
              diameter: Style.space(32)
              labelFontFamily: root.fontFamily
              labelPixelSize: Style.font.body
              anchors.left: parent.left
              anchors.top: parent.top
            }

            Column {
              id: trainDetailTextColumn
              anchors.left: trainDetailBadge.right
              anchors.leftMargin: Style.space(10)
              anchors.right: trainDetailSwap.left
              anchors.rightMargin: Style.space(8)
              anchors.top: parent.top
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                width: parent.width
                elide: Text.ElideRight
                text: root.selectedTrain ? ("To " + Model.destinationFor(root.selectedTrain.route, root.selectedTrain.dir)) : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }
              Text {
                textFormat: Text.PlainText
                text: root.selectedTrain ? Model.directionTabLabel(root.selectedTrain.dir) : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            // Swaps this trip to the opposite direction without backing out
            // of the detail panel — jumps straight to a live train the
            // other way if one's currently running, else falls back to
            // closing back out to the (now-flipped) arrivals list.
            IconTapText {
              id: trainDetailSwap
              text: "⇅"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              anchors.right: trainDetailClose.left
              anchors.rightMargin: Style.space(12)
              anchors.top: parent.top
              onActivated: root.swapTrainDirection()
            }

            IconTapText {
              id: trainDetailClose
              text: "✕"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              anchors.right: parent.right
              anchors.top: parent.top
              onActivated: root.closeTrainDetail()
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: !root.selectedTrain || root.selectedTrain.stops.length === 0
            width: parent.width
            text: "No stop details available for this train."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Column {
            width: parent.width
            spacing: 0

            // 2 physical-neighbor context rows (no live time) above the
            // boarding station (bold, accent dot), then this trip's
            // complete fetched stop list — always fully shown, no
            // collapse/expand here (that lives on the arrivals-list
            // context strip instead; see approachExpanded below).
            Repeater {
              model: root.tripStopsDisplay
              delegate: Item {
                id: stopRow
                required property var modelData
                required property int index
                width: trainDetailView.width
                height: Style.space(40)

                Text {
                  id: boardMarker
                  visible: stopRow.modelData.isBoard
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: "●"
                  color: Color.accent
                  font.pixelSize: Style.font.body
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.left: boardMarker.visible ? boardMarker.right : parent.left
                  anchors.leftMargin: boardMarker.visible ? Style.space(8) : 0
                  anchors.right: stopTimeText.left
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                  elide: Text.ElideRight
                  text: {
                    var name = stopRow.modelData.name
                    if (!name) {
                      var station = Stations.stationById(stopRow.modelData.stopId)
                      name = station ? station.name : stopRow.modelData.stopId
                    }
                    return name
                  }
                  color: stopRow.modelData.isContext ? root.dim : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: stopRow.modelData.isContext ? Style.font.bodySmall : Style.font.body
                  font.bold: stopRow.modelData.isBoard
                }

                Text {
                  id: stopTimeText
                  textFormat: Text.PlainText
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  visible: !stopRow.modelData.isContext
                  text: Model.formatClockTime(stopRow.modelData.epoch)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Rectangle {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  height: Style.spacing.hairline
                  color: root.foreground
                  opacity: 0.1
                }
              }
            }
          }
        }

        // ================= Trip planner view =================
        Column {
          id: tripPlannerView
          visible: root.tripPlannerOpen && !root.pickerOpen
          width: parent.width
          spacing: Style.space(12)

          Item {
            width: parent.width
            height: tripTitle.implicitHeight

            Text {
              id: tripTitle
              textFormat: Text.PlainText
              text: "Plan a Trip"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }
            IconTapText {
              text: "✕"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onActivated: root.closeTripPlanner()
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Station to station only — not walking or driving directions."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // ---- From field
          Rectangle {
            width: parent.width
            height: Style.space(50)
            radius: Style.cornerRadius
            color: Style.normalFillFor(root.foreground, Color.accent)
            border.width: 1
            border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

            Column {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(10)
              spacing: Style.space(2)
              Text {
                textFormat: Text.PlainText
                text: "FROM"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }
              Text {
                textFormat: Text.PlainText
                text: root.tripOrigin ? root.tripOrigin.name : "Choose a station"
                color: root.tripOrigin ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: !!root.tripOrigin
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openPicker("tripOrigin")
            }
          }

          // ---- Swap
          Item {
            width: parent.width
            height: Style.space(26)
            IconTapText {
              anchors.centerIn: parent
              text: "⇅"
              color: (root.tripOrigin || root.tripDestination) ? Color.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              hitMargin: Style.space(8)
              onActivated: root.swapTripStations()
            }
          }

          // ---- To field
          Rectangle {
            width: parent.width
            height: Style.space(50)
            radius: Style.cornerRadius
            color: Style.normalFillFor(root.foreground, Color.accent)
            border.width: 1
            border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

            Column {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(10)
              spacing: Style.space(2)
              Text {
                textFormat: Text.PlainText
                text: "TO"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
              }
              Text {
                textFormat: Text.PlainText
                text: root.tripDestination ? root.tripDestination.name : "Choose a station"
                color: root.tripDestination ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: !!root.tripDestination
              }
            }

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openPicker("tripDestination")
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: !root.tripOrigin || !root.tripDestination
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Pick a From and a To station to see the best way there."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Row {
            visible: root.tripLoading
            spacing: Style.space(10)
            Text {
              textFormat: Text.PlainText
              text: ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              anchors.verticalCenter: parent.verticalCenter
              RotationAnimator on rotation {
                running: root.tripLoading
                from: 0; to: 360
                duration: 900
                loops: Animation.Infinite
              }
            }
            Text {
              textFormat: Text.PlainText
              text: "Finding your route…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Rectangle {
            visible: root.tripError !== ""
            width: parent.width
            height: tripErrorColumn.implicitHeight + Style.space(16)
            radius: Style.cornerRadius
            color: Qt.rgba(0.85, 0.25, 0.2, 0.14)
            border.width: 1
            border.color: Qt.rgba(0.85, 0.25, 0.2, 0.45)

            Column {
              id: tripErrorColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(8)
              spacing: Style.space(4)

              Row {
                spacing: Style.space(8)
                Text {
                  textFormat: Text.PlainText
                  text: "⚠"
                  color: "#E8604D"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  textFormat: Text.PlainText
                  width: tripErrorColumn.width - Style.space(60)
                  wrapMode: Text.WordWrap
                  text: Model.tripErrorText(root.tripError)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                TextLink {
                  text: "Retry"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  hitMargin: Style.space(6)
                  onActivated: root.runTripQuery()
                }
              }

              Text {
                textFormat: Text.PlainText
                visible: root.tripErrorDetail !== ""
                width: tripErrorColumn.width
                wrapMode: Text.WordWrap
                text: root.tripErrorDetail
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---- Direct route result
          Column {
            visible: !!root.tripResult && root.tripResult.direct.length > 0
            width: parent.width
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              text: "DIRECT — NO TRANSFER NEEDED"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }

            Repeater {
              model: root.tripResult ? root.tripResult.direct.slice(0, 3) : []
              delegate: TripLegRow {
                required property var modelData
                width: tripPlannerView.width
                route: modelData.route
                primaryText: Model.directionTabLabel(modelData.dir) + " · " + Model.departPhrase(modelData.departMinutes)
                secondaryText: Model.arrivePhrase(modelData.arriveMinutes)
                foreground: root.foreground
                dim: root.dim
                fontFamily: root.fontFamily
              }
            }
          }

          // ---- One-transfer route result
          Column {
            visible: !!root.tripResult && root.tripResult.direct.length === 0 && root.tripResult.transfers.length > 0
            width: parent.width
            spacing: Style.space(10)

            Text {
              textFormat: Text.PlainText
              text: "ONE TRANSFER"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }

            Repeater {
              model: root.tripResult ? root.tripResult.transfers.slice(0, 1) : []
              delegate: Column {
                required property var modelData
                width: tripPlannerView.width
                spacing: Style.space(8)

                TripLegRow {
                  width: tripPlannerView.width
                  route: modelData.leg1.route
                  primaryText: Model.directionTabLabel(modelData.leg1.dir) + " · " + Model.departPhrase(modelData.leg1.departMinutes)
                  secondaryText: "Transfer at " + (Stations.stationById(modelData.transferStopId) ? Stations.stationById(modelData.transferStopId).name : "—")
                  foreground: root.foreground
                  dim: root.dim
                  fontFamily: root.fontFamily
                }

                TripLegRow {
                  width: tripPlannerView.width
                  route: modelData.leg2.route
                  primaryText: Model.directionTabLabel(modelData.leg2.dir) + " · " + Model.departPhrase(modelData.leg2.departMinutes)
                  secondaryText: Model.arrivePhrase(modelData.totalMinutes)
                  foreground: root.foreground
                  dim: root.dim
                  fontFamily: root.fontFamily
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: !!root.tripResult && root.tripResult.direct.length === 0 && root.tripResult.transfers.length === 0
            width: parent.width
            wrapMode: Text.WordWrap
            text: "No direct or one-transfer route found between these stations right now."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ================= Station picker view =================
        Column {
          id: pickerView
          // 2px inset on both sides — same fix as the direction-toggle Row
          // elsewhere in this file: this Column would otherwise sit
          // exactly flush against the enclosing Flickable's own clip:true
          // bounds, and the route pills inside it (browsePill, resultPill
          // below) scale up on hover/highlight, pushing their ring border
          // past that boundary and losing its left edge to the clip.
          visible: root.pickerOpen
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.leftMargin: Style.space(2)
          anchors.rightMargin: Style.space(2)
          spacing: Style.space(12)

          Item {
            width: parent.width
            height: pickerTitle.implicitHeight

            Text {
              id: pickerTitle
              textFormat: Text.PlainText
              text: root.pickerPurpose === "tripOrigin" ? "Choose Origin Station"
                : root.pickerPurpose === "tripDestination" ? "Choose Destination Station"
                : "Change Station"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }
            IconTapText {
              text: "✕"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              onActivated: root.closePicker()
            }
          }

          TextField {
            id: searchField
            width: parent.width
            placeholderText: "Search stations by name…"
            foreground: root.foreground
            accent: Color.accent
            font.family: root.fontFamily
            // One-directional: this field is the source of truth for what's
            // typed. A live `text: root.pickerQuery` binding here would fight
            // every keystroke — the edit breaks the binding, but reassigning
            // pickerQuery below immediately re-establishes and reapplies it,
            // stomping the cursor position on every character.
            onTextChanged: root.pickerQuery = text
          }

          Text {
            textFormat: Text.PlainText
            text: "OR BROWSE BY LINE"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
          }

          Flow {
            width: parent.width
            spacing: Style.space(8)

            Repeater {
              model: root.pickerRoutes
              delegate: Rectangle {
                id: browsePill
                required property string modelData
                readonly property bool selected: root.pickerRouteFilter === modelData
                readonly property bool hovered: browsePillArea.containsMouse
                width: Style.space(30)
                height: Style.space(30)
                radius: width / 2
                antialiasing: true
                color: hovered ? Qt.lighter(Model.routeColor(modelData), 1.25) : Model.routeColor(modelData)
                border.width: selected ? 3 : (hovered ? 2 : 0)
                border.color: selected ? root.foreground : Qt.lighter(root.foreground, 1.4)
                scale: hovered ? 1.12 : 1.0

                Behavior on scale { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }
                Behavior on color { ColorAnimation { duration: 100 } }

                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: browsePill.modelData
                  color: Model.routeTextColor(browsePill.modelData)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }

                MouseArea {
                  id: browsePillArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.pickerRouteFilter = (root.pickerRouteFilter === browsePill.modelData ? "" : browsePill.modelData)
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.pickerQuery === "" && root.pickerRouteFilter === ""
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Start typing a station name, or tap a line above to list every station it serves."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            textFormat: Text.PlainText
            visible: (root.pickerQuery !== "" || root.pickerRouteFilter !== "") && root.pickerResults.length === 0
            width: parent.width
            text: "No stations match."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Column {
            width: parent.width
            spacing: 0

            Repeater {
              model: root.pickerResults
              // One row per station NAME, not per stop_id: a complex like
              // 14 St-Union Sq has a separate stop_id per line grouping
              // (4/5/6, L, N/Q/R/W). All of that name's pills sit on one
              // row to save space; each pill is its own tap target and
              // picks that specific line's stop_id, independent of the
              // others on the row.
              delegate: Item {
                id: stationRow
                required property var modelData
                // Pills sharing a stop_id are the same physical platform —
                // picking any one of them (e.g. N/Q/R/W at Union Sq) has the
                // identical effect, so hovering one highlights all of them
                // together rather than just the pill under the cursor.
                property string hoveredStopId: ""
                // True for a row like Penn Station (1/2/3 on one feed, A/C/E
                // on another) where no single whole-row pick could ever
                // cover every line — picking "the dominant feed" here would
                // silently drop the other feed's lines with no indication,
                // which is exactly the crossover confusion this avoids: for
                // these rows, only a specific pill tap is allowed to track
                // a station (the note below explains why).
                readonly property bool multiFeed: Stations.pillsSpanMultipleFeeds(modelData.pills)
                width: pickerView.width
                height: resultRow.implicitHeight + Style.space(16)

                // Whole-row background click, declared BEFORE the pills
                // Column below so the pills (which paint on top) always win
                // a click landed directly on one of them. "station" purpose:
                // picking anywhere else on the row tracks every line sharing
                // the row's dominant feed (all of Grand Central's 4/5/6, 7,
                // and S, since they're all one feed) rather than requiring a
                // specific pill tap — see Stations.dominantFeedGroupStopIds —
                // except when multiFeed is true, where there's no single
                // "whole row" pick that wouldn't silently drop lines, so
                // this is a no-op and a pill tap is required instead.
                // Trip-planner purposes: unchanged, selects the whole
                // complex since any of its lines could be the one with a
                // live connection (transfer routing only needs to know
                // every route the complex serves, not to poll it live).
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    if (root.pickerPurpose === "station") {
                      var pills = stationRow.modelData.pills
                      if (pills && pills.length > 0 && !stationRow.multiFeed) {
                        var group = Stations.dominantFeedGroupStopIds(pills)
                        root.pickStation({ id: group.stopIds.join(","), feedGroup: group.feedGroup, name: stationRow.modelData.name })
                      }
                    } else {
                      root.selectTripStation(stationRow.modelData)
                    }
                  }
                }

                Column {
                  id: resultRow
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.name
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }

                  Text {
                    textFormat: Text.PlainText
                    visible: root.pickerPurpose === "station" && stationRow.multiFeed
                    width: resultRow.width
                    wrapMode: Text.WordWrap
                    text: "Spans multiple feeds — tap a specific line below"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Flow {
                    width: resultRow.width
                    spacing: Style.space(6)

                    Repeater {
                      model: modelData.pills
                      delegate: Rectangle {
                        id: resultPill
                        required property var modelData
                        readonly property bool hovered: stationRow.hoveredStopId === modelData.stopId
                        width: Style.space(26)
                        height: Style.space(26)
                        radius: width / 2
                        antialiasing: true
                        color: hovered ? Qt.lighter(Model.routeColor(modelData.route), 1.25) : Model.routeColor(modelData.route)
                        border.width: hovered ? 2 : 0
                        border.color: Qt.lighter(root.foreground, 1.4)
                        scale: hovered ? 1.15 : 1.0

                        Behavior on scale { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }
                        Behavior on color { ColorAnimation { duration: 100 } }

                        Text {
                          textFormat: Text.PlainText
                          anchors.centerIn: parent
                          text: resultPill.modelData.route
                          color: Model.routeTextColor(resultPill.modelData.route)
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                          font.bold: true
                        }

                        MouseArea {
                          id: resultPillArea
                          anchors.fill: parent
                          // Only the "change tracked station" purpose cares
                          // which specific line's pill was tapped — disabled
                          // here, clicks fall through to the whole-row
                          // MouseArea declared above (it paints underneath,
                          // so a specific pill still wins whenever this is
                          // enabled), since trip planning wants the entire
                          // complex regardless of which pill was hit.
                          enabled: root.pickerPurpose === "station"
                          hoverEnabled: true
                          cursorShape: Qt.PointingHandCursor
                          onEntered: stationRow.hoveredStopId = resultPill.modelData.stopId
                          onExited: if (stationRow.hoveredStopId === resultPill.modelData.stopId) stationRow.hoveredStopId = ""
                          onClicked: root.pickStation({
                            id: resultPill.modelData.stopId,
                            feedGroup: resultPill.modelData.feedGroup,
                            name: stationRow.modelData.name
                          })
                        }
                      }
                    }
                  }
                }

                Rectangle {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  height: Style.spacing.hairline
                  color: root.foreground
                  opacity: 0.1
                }
              }
            }
          }
        }
      }
    }
    }
  }
}
