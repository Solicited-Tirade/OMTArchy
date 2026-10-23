const assert = require("node:assert/strict")
const test = require("node:test")
const Model = require("../Model.js")

const notifyFlags = /^-/

test("notification text never starts with a dash", () => {
  for (const flagLike of ["--app-name=Other App", "--replace-id=7", "--image=/etc/hostname", "--exec", "-u", "--"]) {
    const command = Model.notificationCommand(flagLike, flagLike, "normal", "tirade.nyc-subway")
    const exec = command.indexOf("--exec")
    const positional = command.slice(5, exec)
    assert.ok(positional.length >= 1)
    for (const value of positional) assert.doesNotMatch(value, notifyFlags)
  }
})

test("notification command uses the Omarchy sender and opens the plugin on click", () => {
  const command = Model.notificationCommand("Your stop is next", "", "critical", "tirade.nyc-subway")
  assert.equal(command[0], "omarchy-notification-send")
  assert.deepEqual(command.slice(command.indexOf("--exec")), ["--exec", "omarchy-shell", "shell", "summon", "tirade.nyc-subway", "{}"])
  assert.equal(command.indexOf(""), -1)
})

test("notification body is escaped and bounded", () => {
  const command = Model.notificationCommand("t", "<img src=http://x/a.png>" + "x".repeat(5000), "normal", "p")
  const body = command[6]
  assert.doesNotMatch(body, /</)
  assert.ok(body.length <= 600)
})

test("helper input is one JSON line of strings", () => {
  const line = Model.pollInput("1234567S", "127", "both", "", "1,2", "611", null)
  assert.ok(line.endsWith("\n"))
  assert.deepEqual(JSON.parse(line), ["1234567S", "127", "both", "", "1,2", "611", "", ""])
  assert.deepEqual(Model.helperCommand("/p/bin/nyc-subway-status"), ["python3", "/p/bin/nyc-subway-status"])
})

test("oversized helper output is refused before parsing", () => {
  const huge = JSON.stringify({ arrivals: [{ tripId: "x".repeat(2 << 20) }] })
  assert.equal(Model.parseArrivals(huge).error, "output-too-large")
  assert.equal(Model.parseLines(huge).error, "output-too-large")
  assert.equal(Model.parseTripResult(huge).error, "output-too-large")
  assert.equal(Model.parseArrivals('{"arrivals":[]}').ok, true)
})

test("bar route label is bounded", () => {
  const arrival = { route: "Z".repeat(100000), dir: "N", minutes: 3, assigned: true }
  const text = Model.barText("Times Sq", "127", [arrival], 0, { count: 1 })
  assert.ok(text.length < 60)
  assert.match(text, /\[ZZZZ\]/)
  assert.match(Model.barText("St George", "S31", [{ route: "SIR", dir: "N", minutes: 2 }], 0, { count: 1 }), /\[SIR\]/)
})

test("minutes phrase never reads \"in now\"", () => {
  assert.equal(Model.inMinutesPhrase(0), "now")
  assert.equal(Model.inMinutesPhrase(4.2), "in 4m")
})

test("station names shared across boroughs say which borough", () => {
  const Stations = require("../Stations.js")
  const names = Stations.searchStationGroups("", "R", 80).filter(g => g.name === "36 St").map(Stations.displayName)
  assert.deepEqual(names.sort(), ["36 St (Brooklyn)", "36 St (Queens)"])
  assert.equal(Stations.displayName({ name: "Times Sq-42 St", borough: "M" }), "Times Sq-42 St")
})

test("arriving train reads \"Xm away\", never \"now away\"", () => {
  assert.equal(Model.awayPhrase(1.2), "1m away")
  assert.equal(Model.awayPhrase(0.2), "arriving")
})

test("train position moves between stops by predicted time, bounded by the reported station", () => {
  const path = [1000, 1060, 1180, 1300, 1420]
  const near = (a, b) => assert.ok(Math.abs(a - b) < 1e-9, a + " != " + b)
  near(Model.railPosition(path, 0, 900, 120, 0, "at"), 0)
  near(Model.railPosition(path, 0, 1120, 120, 1, "at"), 1.5)
  near(Model.railPosition(path, 0, 1400, 120, 1, "at"), 1.9)
  near(Model.railPosition(path, 0, 1360, 120, 4, "approaching"), 3.5)
  near(Model.railPosition(path, 0, 1500, 120, 4, "at"), 4)
  near(Model.railPosition(path, 0, 1240, 120, -1, ""), 2.5)
  near(Model.railPosition([0, 0, 1420, 1540], 2, 1360, 120, 2, "approaching"), 1.5)
})
