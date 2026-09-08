// Pure data-shaping helpers for the NYC Subway widget. No QML dependency so
// this can be unit tested with plain node/jest if desired.

function shQuote(value) {
  return "'" + String(value == null ? "" : value).replace(/'/g, "'\\''") + "'"
}

// Builds the bash -lc command line that runs the bundled helper script.
// scriptPath is the absolute path to bin/nyc-subway-status (already resolved
// from Qt.resolvedUrl by the caller). alertRoutes is typically every route
// serving this stop — passing "" skips the alerts fetch entirely.
function pollScript(scriptPath, feedGroup, stopId, direction, routeFilter, alertRoutes) {
  return "python3 " + shQuote(scriptPath) + " "
    + shQuote(feedGroup) + " "
    + shQuote(stopId) + " "
    + shQuote(direction) + " "
    + shQuote(routeFilter) + " "
    + shQuote(alertRoutes)
}

// Parses the helper script's stdout. Returns
// { ok: true, arrivals, alerts, generalAlerts } or { ok: false, error, detail }.
// Never throws. `alerts` are specific to this station's routes; `generalAlerts`
// are system-wide notices (holiday/weekend schedule, etc.) that name too many
// routes to be about this particular stop — the caller decides where those
// belong instead of the per-station alert list.
function parseArrivals(raw) {
  var text = String(raw || "").replace(/^\s+|\s+$/g, "")
  if (text === "") return { ok: false, error: "empty", detail: "" }

  var data
  try {
    data = JSON.parse(text)
  } catch (e) {
    return { ok: false, error: "bad-json", detail: text.slice(0, 200) }
  }

  if (data && data.error) {
    return { ok: false, error: data.error, detail: data.detail || "" }
  }
  if (!data || !Array.isArray(data.arrivals)) return { ok: false, error: "bad-json", detail: "" }

  return {
    ok: true,
    arrivals: data.arrivals,
    alerts: Array.isArray(data.alerts) ? data.alerts : [],
    generalAlerts: Array.isArray(data.generalAlerts) ? data.generalAlerts : []
  }
}

// Builds the bash -lc command line for bin/nyc-subway-trip. originPairs and
// destPairs are already-joined "stopId:feedGroup,..." strings (one entry per
// line grouping at that station complex); transferPairs is an already-joined
// "entryStop:entryFeed:exitStop:exitFeed,..." string of candidate one-
// transfer bridge points — both built by the caller from
// Stations.searchStationGroups / Stations.transferCandidates.
function tripPollScript(scriptPath, originPairs, destPairs, transferPairs) {
  return "python3 " + shQuote(scriptPath) + " "
    + shQuote(originPairs) + " "
    + shQuote(destPairs) + " "
    + shQuote(transferPairs)
}

// Parses bin/nyc-subway-trip's stdout. Returns { ok: true, direct, transfers }
// (either list may be empty — empty-both means no direct-or-one-transfer
// route was found) or { ok: false, error, detail }. Never throws.
function parseTripResult(raw) {
  var text = String(raw || "").replace(/^\s+|\s+$/g, "")
  if (text === "") return { ok: false, error: "empty", detail: "" }

  var data
  try {
    data = JSON.parse(text)
  } catch (e) {
    return { ok: false, error: "bad-json", detail: text.slice(0, 200) }
  }

  if (data && data.error) {
    return { ok: false, error: data.error, detail: data.detail || "" }
  }
  if (!data || !Array.isArray(data.direct) || !Array.isArray(data.transfers)) {
    return { ok: false, error: "bad-json", detail: "" }
  }

  return { ok: true, direct: data.direct, transfers: data.transfers }
}

function formatMinutes(minutes) {
  var m = Math.max(0, Math.round(Number(minutes) || 0))
  return m === 0 ? "now" : (m + "m")
}

// Sentence-fragment wrappers around formatMinutes for the trip planner,
// which interpolates it into "depart in <x>"/"Arrive in <x>" phrasing —
// "depart in now" reads wrong, so the zero-minute case gets its own phrase.
function departPhrase(minutes) {
  var m = Math.max(0, Math.round(Number(minutes) || 0))
  return m === 0 ? "departing now" : ("depart in " + formatMinutes(minutes))
}
function arrivePhrase(minutes) {
  var m = Math.max(0, Math.round(Number(minutes) || 0))
  return m === 0 ? "Arriving now" : ("Arrive in " + formatMinutes(minutes))
}

// "route 4, arriving now" / "route 4, arriving in 6m" — spells out in full
// sentence form what the bar's compact "[4] now" abbreviates, for the bar
// tooltip (see Panel.qml's tooltipText).
function nextArrivalPhrase(route, minutes) {
  var m = Math.max(0, Math.round(Number(minutes) || 0))
  return "route " + route + ", arriving " + (m === 0 ? "now" : "in " + formatMinutes(minutes))
}

// "1:21 PM" style clock time, for a per-stop list stretching far enough out
// that a relative countdown (formatMinutes) stops being the useful framing —
// matches the reference app's own choice for its per-train stop list.
function formatClockTime(epochSeconds) {
  var d = new Date(Number(epochSeconds) * 1000)
  if (isNaN(d.getTime())) return "—"
  var hours = d.getHours()
  var minutes = d.getMinutes()
  var suffix = hours >= 12 ? "PM" : "AM"
  var hour12 = hours % 12
  if (hour12 === 0) hour12 = 12
  var minuteStr = (minutes < 10 ? "0" : "") + minutes
  return hour12 + ":" + minuteStr + " " + suffix
}

// Short tab label for the direction toggle.
function directionTabLabel(dir) {
  return dir === "S" ? "Downtown" : "Uptown"
}

// Official-ish MTA bullet colors, by route id. Falls back to a neutral grey
// for anything unlisted (express variants like "5X" share their base color).
var ROUTE_COLORS = {
  "1": "#EE352E", "2": "#EE352E", "3": "#EE352E",
  "4": "#00933C", "5": "#00933C", "6": "#00933C", "6X": "#00933C",
  "7": "#B933AD", "7X": "#B933AD",
  "A": "#0039A6", "C": "#0039A6", "E": "#0039A6",
  "B": "#FF6319", "D": "#FF6319", "F": "#FF6319", "FX": "#FF6319", "M": "#FF6319",
  "G": "#6CBE45",
  "J": "#996633", "Z": "#996633",
  "L": "#A7A9AC",
  "N": "#FCCC0A", "Q": "#FCCC0A", "R": "#FCCC0A", "W": "#FCCC0A",
  "GS": "#808183", "FS": "#808183", "H": "#808183", "S": "#808183",
  "SI": "#0039A6"
}

// Bullets on a light background (the yellow N/Q/R/W group) read better with
// dark text than the white used everywhere else.
var DARK_TEXT_ROUTES = { "N": true, "Q": true, "R": true, "W": true }

function routeColor(route) {
  return ROUTE_COLORS[String(route || "").toUpperCase()] || "#5A6268"
}

function routeTextColor(route) {
  return DARK_TEXT_ROUTES[String(route || "").toUpperCase()] ? "#1A1A1A" : "#FFFFFF"
}

// Typical terminal for a route + direction, used as a stand-in destination
// label since the realtime feed doesn't carry a per-trip headsign. This is
// the usual end of the line, not the live trip's actual destination — a
// short-turning or rerouted train may end elsewhere.
var ROUTE_TERMINI = {
  "1": { N: "Van Cortlandt Park-242 St", S: "South Ferry" },
  "2": { N: "Wakefield-241 St", S: "Flatbush Av-Brooklyn College" },
  "3": { N: "Harlem-148 St", S: "New Lots Av" },
  "4": { N: "Woodlawn", S: "Crown Hts-Utica Av" },
  "5": { N: "Eastchester-Dyre Av", S: "Flatbush Av-Brooklyn College" },
  "6": { N: "Pelham Bay Park", S: "Brooklyn Bridge-City Hall" },
  "6X": { N: "Pelham Bay Park", S: "Brooklyn Bridge-City Hall" },
  "7": { N: "Flushing-Main St", S: "34 St-Hudson Yards" },
  "7X": { N: "Flushing-Main St", S: "34 St-Hudson Yards" },
  "A": { N: "Inwood-207 St", S: "Far Rockaway-Mott Av" },
  "C": { N: "168 St", S: "Euclid Av" },
  "E": { N: "Jamaica Center-Parsons/Archer", S: "World Trade Center" },
  "B": { N: "Bedford Park Blvd", S: "Brighton Beach" },
  "D": { N: "Norwood-205 St", S: "Coney Island-Stillwell Av" },
  "F": { N: "Jamaica-179 St", S: "Coney Island-Stillwell Av" },
  "M": { N: "Forest Hills-71 Av", S: "Middle Village-Metropolitan Av" },
  "G": { N: "Court Sq", S: "Church Av" },
  "J": { N: "Jamaica Center-Parsons/Archer", S: "Broad St" },
  "Z": { N: "Jamaica Center-Parsons/Archer", S: "Broad St" },
  "L": { N: "8 Av", S: "Canarsie-Rockaway Pkwy" },
  "N": { N: "Astoria-Ditmars Blvd", S: "Coney Island-Stillwell Av" },
  "Q": { N: "96 St", S: "Coney Island-Stillwell Av" },
  "R": { N: "Forest Hills-71 Av", S: "Bay Ridge-95 St" },
  "W": { N: "Astoria-Ditmars Blvd", S: "Whitehall St-South Ferry" },
  "GS": { N: "Times Sq-42 St", S: "Grand Central-42 St" },
  "FS": { N: "Franklin Av", S: "Prospect Park" },
  "H": { N: "Rockaway Park-Beach 116 St", S: "Broad Channel" },
  "SI": { N: "St George", S: "Tottenville" }
}

function destinationFor(route, dir) {
  var termini = ROUTE_TERMINI[String(route || "").toUpperCase()]
  if (!termini) return dir === "S" ? "Downtown" : "Uptown"
  return (dir === "S" ? termini.S : termini.N) || (dir === "S" ? "Downtown" : "Uptown")
}

// Distinct routes present in arrivals. Default sort is numbers-before-letters
// natural order; pass compareRoutes (e.g. Stations.makeRouteComparator) to
// order by MTA physical service group instead.
function distinctRoutes(arrivals, compareRoutes) {
  var seen = {}
  var out = []
  for (var i = 0; i < (arrivals || []).length; i++) {
    var r = arrivals[i].route
    if (!seen[r]) { seen[r] = true; out.push(r) }
  }
  out.sort(compareRoutes || function(a, b) {
    var an = /^\d/.test(a), bn = /^\d/.test(b)
    if (an !== bn) return an ? -1 : 1
    return a < b ? -1 : (a > b ? 1 : 0)
  })
  return out
}

// Arrivals for one direction (+ optional single-route filter), capped to
// maxResults. Input is assumed already sorted soonest-first.
function arrivalsFor(arrivals, direction, routeFilter, maxResults) {
  var cap = Math.max(1, parseInt(maxResults, 10) || 5)
  var out = []
  for (var i = 0; i < (arrivals || []).length && out.length < cap; i++) {
    var a = arrivals[i]
    if (a.dir !== direction) continue
    if (routeFilter && a.route !== routeFilter) continue
    out.push(a)
  }
  return out
}

// Single-character route id -> its Unicode "circled" glyph, the closest a
// plain-text bar (no rich text, no child shapes — see barText) can get to
// the popup's actual colored circular route bullets. Both digits and
// letters get a bold, filled "negative circled" glyph for maximum
// contrast at small bar sizes: digits use the Dingbats block (❶,
// U+2776+), letters use the Enclosed Alphanumeric Supplement (🅐,
// U+1F150+) — the latter is outside the BMP (needs a surrogate pair,
// which String.fromCodePoint handles) and less universally supported than
// the thinner Ⓐ-style (U+24B6+) circled letters, but confirmed rendering
// correctly on this system's bar font; if it ever shows as a missing-glyph
// box on some other font, fall back to 0x24B6 instead. Only covers exactly
// one character — there's no circled glyph for a multi-character code like
// "SIR" — callers should fall back to bracket notation when this returns
// null.
function circledGlyph(route) {
  var c = String(route || "").toUpperCase()
  if (c.length !== 1) return null
  if (c >= "1" && c <= "9") return String.fromCodePoint(0x2776 + (c.charCodeAt(0) - "1".charCodeAt(0)))
  if (c >= "A" && c <= "Z") return String.fromCodePoint(0x1F150 + (c.charCodeAt(0) - "A".charCodeAt(0)))
  return null
}

// Compact text for the bar pill: "<name> · ⚠3 · ⬆❻ · <minutes>" (the
// "⚠<count> ·" segment only when alertCount > 0), or "⬆[SIR]" for the one
// multi-character route code, which has no circled-glyph equivalent.
// Every segment uses the same minimal " · " separator — including between
// the route glyph and the countdown, and between the name and the alert
// marker — so a route glyph directly against a countdown with no
// separator (a bare "4 now") doesn't read as one unrelated pair of tokens.
// The count sits directly against the glyph with no space
// (matching the direction-arrow + route-glyph grouping, "⬆❻") so it reads
// as one "how many alerts" unit rather than a second, disconnected number.
// The alert marker sits right after the name (left side) rather than
// trailing at the end, so it reads as "this station has N alerts" before
// the specific train info, not as an afterthought tacked onto the
// countdown. The circled glyph is what stands in for the popup's actual
// colored route bullets here — no rich text/child shapes are possible in
// this plain-text bar, so this is as close as a single character gets.
// The heavy arrow is the same up/down direction concept as the
// direction-tab arrow in the popup's context strip — ⬆ for uptown (N), ⬇
// for downtown (S), chosen over the thinner ▲/▼ triangle for visibility
// at small bar sizes. Empty string (widget hides itself) when there is
// nothing to show yet.
// Bar-pill max name length before truncating with an ellipsis. Plenty of
// real station names run past this — "Atlantic Av-Barclays Ctr" (25),
// "Van Cortlandt Park-242 St" (26) — and left alone they'd balloon the
// pill and crowd out every other bar widget. This is plain-string
// truncation for the bar's single Text.PlainText label, which has no
// elide mechanism of its own (unlike the popup header's title, which
// elides via its own Text width/elide binding instead).
var BAR_NAME_MAX_LENGTH = 18

function truncateName(name, maxLength) {
  var n = String(name || "")
  if (n.length <= maxLength) return n
  return n.slice(0, maxLength - 1) + "…"
}

function barText(stationLabel, stopId, arrivals, alertCount) {
  var name = truncateName(String(stationLabel || "").replace(/^\s+|\s+$/g, "") || String(stopId || ""), BAR_NAME_MAX_LENGTH)
  var count = Math.max(0, Number(alertCount) || 0)
  var prefix = name + (count > 0 ? " · ⚠" + count : "")
  if (!arrivals || arrivals.length === 0) return prefix + " · —"
  var next = arrivals[0]
  var dirGlyph = next.dir === "S" ? "⬇" : "⬆"
  var routeLabel = circledGlyph(next.route) || ("[" + next.route + "]")
  return prefix + " · " + dirGlyph + routeLabel + " · " + formatMinutes(next.minutes)
}

function errorText(error) {
  switch (error) {
    case "no-stop-id": return "Set a Stop ID in this widget's settings"
    case "fetch-failed": return "Couldn't reach the MTA feed"
    case "parse-failed": return "Unexpected feed format"
    case "bad-json": return "Helper script output was not valid JSON"
    case "empty": return "No response from the helper script"
    default: return "No data yet"
  }
}

// Same errors as errorText, but for the trip planner's own context (its
// "no-stop-id" means "pick both a From and To station", not a widget
// setting).
function tripErrorText(error) {
  if (error === "no-stop-id") return "Pick a From and a To station"
  return errorText(error)
}

if (typeof module !== "undefined") {
  module.exports = {
    shQuote: shQuote,
    pollScript: pollScript,
    parseArrivals: parseArrivals,
    tripPollScript: tripPollScript,
    parseTripResult: parseTripResult,
    formatMinutes: formatMinutes,
    circledGlyph: circledGlyph,
    truncateName: truncateName,
    departPhrase: departPhrase,
    nextArrivalPhrase: nextArrivalPhrase,
    arrivePhrase: arrivePhrase,
    formatClockTime: formatClockTime,
    directionTabLabel: directionTabLabel,
    routeColor: routeColor,
    routeTextColor: routeTextColor,
    destinationFor: destinationFor,
    distinctRoutes: distinctRoutes,
    arrivalsFor: arrivalsFor,
    barText: barText,
    errorText: errorText,
    tripErrorText: tripErrorText
  }
}
