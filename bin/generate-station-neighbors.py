#!/usr/bin/env python3
"""Dev-time data generator: bakes prevNorth/prevSouth (the 2 nearest
physical neighbor stations on each side, for the direction-tab context
strip) into every entry of Stations.js's STATIONS array, and the static
GTFS transfers.txt walking times into its TRANSFER_SECONDS table (used by
the trip planner instead of a flat transfer buffer).

NOT run by the plugin itself — this is a one-off/occasional tool, run by
hand whenever the physical station list needs refreshing. Requires network
access to fetch MTA's static GTFS feed (or pass --zip to reuse an already
downloaded copy).

Why "nearest by geographic distance" rather than "most common predecessor":
a naive most-common-immediate-predecessor-in-stop_times approach breaks on
any express-served platform. E.g. at Grand Central-42 St (stop_id 631,
served by local 6 and express 4/5), the single most common immediate
predecessor in the raw GTFS-realtime stop_times data going uptown is
14 St-Union Sq (635, via 4/5 express trips skipping several local stops) —
NOT 33 St (632), which is what's physically adjacent and what a rider
actually expects here. Instead, among ALL distinct stops that ever appear
as an immediate predecessor for a given (stop, direction) — express skips
included — this script picks the geographically NEAREST one. An express
"skip" edge necessarily jumps to a stop farther away than the true local
neighbor, so nearest-by-distance recovers the correct physical adjacency
regardless of how the express/local trip mix skews raw frequency. Verified
against real data: Grand Central (631) -> nearest predecessor 632 (33 St)
-> nearest predecessor 633 (28 St), matching the real physical line order.

Usage:
  bin/generate-station-neighbors.py [--zip PATH] [--dry-run] [--station ID]
                                    [--transfers-only]

  --zip PATH     Use an already-downloaded gtfs_subway.zip instead of
                 fetching it fresh.
  --dry-run      Print a summary instead of writing Stations.js.
  --station ID   Dry-run detail for one specific stop_id (e.g. 631), to
                 spot-check a result before trusting the full run.
  --transfers-only  Only rewrite TRANSFER_SECONDS, leaving STATIONS as is.
"""
import argparse
import csv
import io
import json
import math
import os
import re
import sys
import urllib.request
import zipfile
from collections import Counter, defaultdict

# web.mta.info/developers/data/nyct/subway/google_transit.zip now just
# 301-redirects here.
GTFS_URL = "https://rrgtfsfeeds.s3.amazonaws.com/gtfs_subway.zip"
STATIONS_JS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Stations.js")

# Any candidate predecessor edge seen fewer than this many times across the
# whole schedule is treated as noise (a one-off reroute/GO artifact) rather
# than a real, regularly-served physical adjacency.
MIN_EDGE_COUNT = 2


def fetch_gtfs_zip(url):
    req = urllib.request.Request(url, headers={"User-Agent": "omarchy-nyc-subway-plugin/1.0"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read()


def find_matching_bracket(s, start):
    """Index of the ']' that closes the '[' at s[start], respecting quoted
    strings (so a ']' or '[' inside a station name doesn't confuse depth
    tracking — none currently occur, but this is correct either way)."""
    assert s[start] == "["
    depth = 0
    in_str = False
    esc = False
    for i in range(start, len(s)):
        c = s[i]
        if in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
        else:
            if c == '"':
                in_str = True
            elif c == "[":
                depth += 1
            elif c == "]":
                depth -= 1
                if depth == 0:
                    return i
    raise ValueError("no matching ']' found")


def load_stations_js(path):
    src = open(path, encoding="utf-8").read()
    marker = "var STATIONS = "
    start = src.index(marker) + len(marker)
    end = find_matching_bracket(src, start)
    stations = json.loads(src[start:end + 1])
    return src, start, end, stations


def compute_predecessor_edges(zf):
    """predecessor[direction][stop_id] -> Counter(prevStopId -> count), for
    every immediate consecutive pair within a single trip's stop_sequence.
    stop_times.txt rows are contiguous per trip_id (verified against the
    actual feed), so this is a single streaming pass."""
    predecessor = {"N": defaultdict(Counter), "S": defaultdict(Counter)}
    with zf.open("stop_times.txt") as f:
        reader = csv.DictReader(io.TextIOWrapper(f, encoding="utf-8"))
        current_trip = None
        prev_parent = None
        prev_dir = None
        for row in reader:
            trip_id = row["trip_id"]
            stop_id = row["stop_id"]
            if not stop_id or stop_id[-1] not in ("N", "S"):
                current_trip = trip_id
                prev_parent = None
                continue
            direction = stop_id[-1]
            parent = stop_id[:-1]
            if trip_id != current_trip or direction != prev_dir:
                current_trip = trip_id
                prev_parent = parent
                prev_dir = direction
                continue
            predecessor[direction][parent][prev_parent] += 1
            prev_parent = parent
            prev_dir = direction
    return predecessor


def load_stop_positions_and_names(zf):
    positions = {}
    names = {}
    with zf.open("stops.txt") as f:
        for row in csv.DictReader(io.TextIOWrapper(f, encoding="utf-8")):
            if row["location_type"] == "1":  # parent stops only
                positions[row["stop_id"]] = (float(row["stop_lat"]), float(row["stop_lon"]))
                names[row["stop_id"]] = row["stop_name"]
    return positions, names


def load_transfer_seconds(zf):
    """transfers.txt -> {"fromStop>toStop": min_transfer_time}. Same-stop
    rows are kept too: they're the cost of switching trains on one
    platform (0 for a cross-platform express/local swap)."""
    out = {}
    with zf.open("transfers.txt") as f:
        for row in csv.DictReader(io.TextIOWrapper(f, encoding="utf-8")):
            try:
                out[row["from_stop_id"] + ">" + row["to_stop_id"]] = int(row["min_transfer_time"] or 0)
            except ValueError:
                continue
    return out


def write_transfer_seconds(src, transfers):
    line = "var TRANSFER_SECONDS = " + json.dumps(transfers, separators=(",", ":"), sort_keys=True)
    pattern = re.compile(r"^var TRANSFER_SECONDS = .*$", re.M)
    if pattern.search(src):
        return pattern.sub(lambda _m: line, src)
    marker = "\n// Which MTA GTFS-realtime feed"
    comment = ("\n// Minimum walking time (seconds) between two stop_ids, from the static\n"
               "// GTFS transfers.txt — generated by bin/generate-station-neighbors.py.\n")
    return src.replace(marker, comment + line + "\n" + marker, 1)


def make_distance_fn(positions):
    def distance(a, b):
        la, loa = positions[a]
        lb, lob = positions[b]
        lat_scale = math.cos(math.radians((la + lb) / 2))
        dx = (loa - lob) * lat_scale
        dy = la - lb
        return math.hypot(dx, dy)
    return distance


def nearest_predecessor(predecessor, direction, stop_id, positions, distance):
    if stop_id not in positions:
        return None
    candidates = [
        sid for sid, count in predecessor[direction].get(stop_id, {}).items()
        if count >= MIN_EDGE_COUNT and sid in positions
    ]
    if not candidates:
        return None
    return min(candidates, key=lambda sid: distance(stop_id, sid))


def neighbor_chain(predecessor, direction, stop_id, positions, distance):
    """Farthest-first 2-hop chain: [2 hops away, 1 hop away]."""
    first = nearest_predecessor(predecessor, direction, stop_id, positions, distance)
    if not first:
        return []
    second = nearest_predecessor(predecessor, direction, first, positions, distance)
    return [second, first] if second else [first]


def resolve_name(stop_id, stations_by_id, gtfs_names):
    if stop_id in stations_by_id:
        return stations_by_id[stop_id]["name"]
    return gtfs_names.get(stop_id, stop_id)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--zip", dest="zip_path", help="Use a local gtfs_subway.zip instead of fetching")
    parser.add_argument("--dry-run", action="store_true", help="Print a summary, don't write Stations.js")
    parser.add_argument("--station", help="Print chain detail for one stop_id and exit")
    parser.add_argument("--transfers-only", action="store_true", help="Only rewrite TRANSFER_SECONDS")
    args = parser.parse_args()

    if args.zip_path:
        with open(args.zip_path, "rb") as f:
            raw = f.read()
    else:
        print("Fetching %s ..." % GTFS_URL, file=sys.stderr)
        raw = fetch_gtfs_zip(GTFS_URL)

    with zipfile.ZipFile(io.BytesIO(raw)) as zf:
        predecessor = compute_predecessor_edges(zf)
        positions, gtfs_names = load_stop_positions_and_names(zf)
        transfers = load_transfer_seconds(zf)

    distance = make_distance_fn(positions)

    src, start, end, stations = load_stations_js(STATIONS_JS)
    stations_by_id = {s["id"]: s for s in stations}

    if args.transfers_only:
        with open(STATIONS_JS, "w", encoding="utf-8") as f:
            f.write(write_transfer_seconds(src, transfers))
        print("Wrote %d transfer times to %s" % (len(transfers), STATIONS_JS), file=sys.stderr)
        return

    if args.station:
        sid = args.station
        south = neighbor_chain(predecessor, "N", sid, positions, distance)
        north = neighbor_chain(predecessor, "S", sid, positions, distance)
        print("stop_id %s (%s):" % (sid, resolve_name(sid, stations_by_id, gtfs_names)))
        print("  prevSouth (approach for Uptown/N):", [(i, resolve_name(i, stations_by_id, gtfs_names)) for i in south])
        print("  prevNorth (approach for Downtown/S):", [(i, resolve_name(i, stations_by_id, gtfs_names)) for i in north])
        return

    missing_both = 0
    for s in stations:
        south_ids = neighbor_chain(predecessor, "N", s["id"], positions, distance)
        north_ids = neighbor_chain(predecessor, "S", s["id"], positions, distance)
        s["prevSouth"] = [{"id": i, "name": resolve_name(i, stations_by_id, gtfs_names)} for i in south_ids]
        s["prevNorth"] = [{"id": i, "name": resolve_name(i, stations_by_id, gtfs_names)} for i in north_ids]
        if not south_ids and not north_ids:
            missing_both += 1

    print("Computed neighbors for %d stations (%d have no neighbors on either side — expected only for true line termini)." % (len(stations), missing_both), file=sys.stderr)

    if args.dry_run:
        for s in stations[:5]:
            print(s["id"], s["name"], "south=", s["prevSouth"], "north=", s["prevNorth"])
        return

    new_array = "[" + ",".join(json.dumps(s, separators=(",", ":")) for s in stations) + "]"
    new_src = write_transfer_seconds(src[:start] + new_array + src[end + 1:], transfers)
    with open(STATIONS_JS, "w", encoding="utf-8") as f:
        f.write(new_src)
    print("Wrote %s" % STATIONS_JS, file=sys.stderr)


if __name__ == "__main__":
    main()
