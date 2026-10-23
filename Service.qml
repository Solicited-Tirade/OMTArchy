import QtQuick
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root

  readonly property string pluginId: "tirade.nyc-subway"
  readonly property string helper: Qt.resolvedUrl("bin/nyc-subway-status").toString().replace(/^file:\/\//, "")
  readonly property int helperTimeoutMs: 45000
  readonly property int notifyTimeoutMs: 10000
  readonly property int maxQueuedNotifications: 4
  readonly property int maxAlertNotificationsPerPoll: 2
  readonly property int manualRefreshGapMs: 10000
  readonly property var failureBackoffMs: [60000, 120000, 300000]
  readonly property int failuresBeforeBackoff: 3

  property var request: null
  property var context: ({})
  property string pendingKey: ""
  property int resultSerial: 0

  property var arrivals: []
  property var alerts: []
  property var generalAlerts: []
  property double feedTimestamp: 0
  property var outages: []
  property var failedFeeds: []
  property var anomalies: []
  property string lastError: ""
  property string lastErrorDetail: ""
  property bool loading: false
  property bool pollTimedOut: false
  property double loadingStartedAt: 0
  property double lastPollFinishedAt: 0
  property int consecutiveFailures: 0

  property var ride: null
  property string followToken: ""
  property var followed: null
  property bool followPending: false
  property var leaveAlarm: null
  property var seenAlertHeaders: ({})
  property string seenAlertsFor: ""
  property var notifyQueue: []

  readonly property string rideToken: ride ? ride.feed + "|" + ride.tripId + "|" + ride.alightStopId : ""
  readonly property int pollIntervalMs: request ? request.pollIntervalMs : 30000
  readonly property int effectivePollMs: consecutiveFailures < failuresBeforeBackoff
    ? pollIntervalMs
    : Math.max(pollIntervalMs, failureBackoffMs[Math.min(consecutiveFailures - failuresBeforeBackoff, failureBackoffMs.length - 1)])

  function configure(next, nextContext) {
    root.context = nextContext || ({})
    if (!next || !next.stopId) {
      root.request = null
      root.reset()
      return
    }
    var changed = !root.request || root.request.key !== next.key
    root.request = next
    if (changed) {
      root.reset()
      root.consecutiveFailures = 0
      settleTimer.restart()
    }
  }

  function requestRefresh() {
    if (Date.now() - root.lastPollFinishedAt < root.manualRefreshGapMs) return
    root.refresh()
  }

  function reset() {
    root.arrivals = []
    root.alerts = []
    root.generalAlerts = []
    root.feedTimestamp = 0
    root.outages = []
    root.failedFeeds = []
    root.anomalies = []
    root.lastError = ""
    root.lastErrorDetail = ""
  }

  function refresh() {
    var r = root.request
    if (!r || !r.stopId || pollProc.running) return
    root.followPending = false
    root.pendingKey = r.key
    root.loading = true
    root.pollTimedOut = false
    root.loadingStartedAt = Date.now()
    pollProc.payload = Model.pollInput(r.feedGroup, r.stopId, r.direction, r.routeFilter, r.alertRoutes, r.complexIds, root.rideToken, root.followToken)
    pollProc.command = Model.helperCommand(root.helper)
    pollProc.running = true
  }

  function finishPoll(text) {
    if (!root.request) {
      root.loading = false
      return
    }
    if (root.pendingKey !== root.request.key) {
      Qt.callLater(root.refresh)
      return
    }
    root.loading = false
    root.lastPollFinishedAt = Date.now()
    if (root.pollTimedOut) {
      root.lastError = "helper-timeout"
      root.lastErrorDetail = ""
      root.consecutiveFailures++
      return
    }
    var parsed = Model.parseArrivals(text)
    if (!parsed.ok) {
      root.lastError = parsed.error
      root.lastErrorDetail = parsed.detail || ""
      root.consecutiveFailures++
      return
    }
    root.consecutiveFailures = 0
    root.anomalies = parsed.anomalies
    root.arrivals = parsed.arrivals
    root.alerts = parsed.alerts
    root.generalAlerts = parsed.generalAlerts
    root.feedTimestamp = parsed.feedTimestamp
    root.outages = parsed.outages
    root.failedFeeds = parsed.failedFeeds
    if (parsed.followed && root.followToken.split("|")[1] === parsed.followed.tripId) root.followed = parsed.followed
    root.lastError = ""
    root.syncLeaveAlarm()
    root.updateRide(parsed.ride)
    root.notifyNewAlerts()
    root.resultSerial++
  }

  function notify(title, body, detailTitle, detailBody, urgency) {
    if (root.notifyQueue.length >= root.maxQueuedNotifications) return
    var details = root.context.notificationDetails === true
    root.notifyQueue.push(Model.notificationCommand(details ? detailTitle : title, details ? detailBody : body, urgency, root.pluginId))
    root.pumpNotify()
  }

  function pumpNotify() {
    if (notifyProc.running || root.notifyQueue.length === 0) return
    notifyProc.command = root.notifyQueue.shift()
    notifyProc.running = true
  }

  function notifyNewAlerts() {
    var key = root.request ? root.request.stopId + "|" + root.request.routeFilter : ""
    var fresh = root.seenAlertsFor !== key
    var previous = fresh ? ({}) : root.seenAlertHeaders
    var mode = String(root.context.alertNotify || "commute")
    var wanted = mode === "always" || (mode === "commute" && root.context.onCommuteStation === true)
    var current = {}
    var sent = 0
    for (var i = 0; i < root.alerts.length; i++) {
      var a = root.alerts[i]
      if (a.kind === "planned") continue
      if (!fresh && wanted && a.kind === "delay" && previous["h:" + a.header] !== true && sent < root.maxAlertNotificationsPerPoll) {
        root.notify("Subway service alert", "A new delay affects a line you track.",
          "Service alert" + (a.routes && a.routes.length ? ": " + a.routes.join(" ") : "") + " at " + String(root.context.stationLabel || ""),
          a.header, "normal")
        sent++
      }
      current["h:" + a.header] = true
    }
    root.seenAlertHeaders = current
    root.seenAlertsFor = key
  }

  function alarmIsFor(train) {
    return !!train && !!root.leaveAlarm && root.leaveAlarm.tripId === train.tripId && root.leaveAlarm.dir === train.dir
  }

  function setLeaveAlarm(alarm) {
    if (!alarm || !alarm.tripId) return
    root.leaveAlarm = alarm
    root.checkLeaveAlarm()
  }

  function cancelLeaveAlarm() {
    root.leaveAlarm = null
  }

  function syncLeaveAlarm() {
    if (!root.leaveAlarm) return
    for (var i = 0; i < root.arrivals.length; i++) {
      if (root.alarmIsFor(root.arrivals[i])) {
        var next = {}
        for (var k in root.leaveAlarm) next[k] = root.leaveAlarm[k]
        next.epoch = root.arrivals[i].epoch
        root.leaveAlarm = next
        return
      }
    }
  }

  function checkLeaveAlarm() {
    var alarm = root.leaveAlarm
    if (!alarm) return
    var now = Date.now() / 1000
    if (now > alarm.epoch + 60) { root.leaveAlarm = null; return }
    var walk = Math.max(0, Number(root.context.walkMinutes) || 0)
    if (now < alarm.epoch - (walk > 0 ? walk * 60 : 120)) return
    var mins = Math.max(0, Math.round((alarm.epoch - now) / 60))
    root.notify(walk > 0 ? "Time to leave for your train" : "Your train is almost here", "",
      walk > 0 ? "Time to leave for the " + alarm.route : "The " + alarm.route + " is almost here",
      "To " + alarm.dest + " · reaches " + alarm.station + " " + (mins === 0 ? "now" : "in " + mins + "m")
        + " (" + Model.formatClockTime(alarm.epoch) + ")",
      "critical")
    root.leaveAlarm = null
  }

  function follow(token) {
    if (token === root.followToken) return
    root.followToken = token
    root.followed = null
    if (token === "") return
    if (pollProc.running) root.followPending = true
    else root.refresh()
  }

  function startRide(next) {
    if (!next || !next.tripId || !next.feed) return
    root.ride = next
    root.refresh()
  }

  function endRide() {
    root.ride = null
  }

  function updateRide(info) {
    if (!root.ride || !info) return
    var next = {}
    for (var k in root.ride) next[k] = root.ride[k]
    if (info.found) {
      next.alightEpoch = info.alightEpoch
      next.stopsLeft = info.stopsLeft
      next.misses = 0
      if (info.stopsLeft === 0 && !next.notifiedNext) {
        root.notify("Your stop is next", "",
          "Your stop is next: " + next.alightName,
          "The " + next.route + " gets there at " + Model.formatClockTime(next.alightEpoch), "critical")
        next.notifiedNext = true
      }
    } else {
      next.misses = (next.misses || 0) + 1
      if (next.misses >= 2 || Date.now() / 1000 > next.alightEpoch - 60) { root.endRide(); return }
    }
    root.ride = next
  }

  Timer {
    id: settleTimer
    interval: 250
    onTriggered: root.refresh()
  }

  Timer {
    interval: root.effectivePollMs
    running: !!root.request
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: root.helperTimeoutMs
    running: pollProc.running
    onTriggered: { root.pollTimedOut = true; pollProc.running = false }
  }

  Timer {
    interval: 5000
    running: !!root.leaveAlarm
    repeat: true
    onTriggered: root.checkLeaveAlarm()
  }

  Timer {
    interval: 15000
    running: !!root.ride
    repeat: true
    onTriggered: if (root.ride && Date.now() / 1000 > root.ride.alightEpoch + 180) root.endRide()
  }

  Timer {
    interval: root.notifyTimeoutMs
    running: notifyProc.running
    onTriggered: notifyProc.running = false
  }

  Process {
    id: pollProc
    property string payload: ""
    onRunningChanged: if (!running && root.followPending) Qt.callLater(root.refresh)
    stdinEnabled: true
    onStarted: write(payload)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finishPoll(text)
    }
  }

  Process {
    id: notifyProc
    onRunningChanged: if (!running) Qt.callLater(root.pumpNotify)
  }
}
