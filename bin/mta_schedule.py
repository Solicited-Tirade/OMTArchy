"""Static-schedule lookups for "how late is this train", used by
bin/nyc-subway-status.

The realtime feed only says when a train is predicted to arrive; lateness
needs the timetable too, which lives in the MTA's static GTFS zip (~6 MB,
~565k stop_times rows). That's far too much to parse on every 30s poll, so
for the stations being tracked it's boiled down once per service day into a
small JSON index under ~/.cache/omtarchy:

    {"today": {"<tripKey>": {"<stopId+dir>": seconds}}, "yesterday": {...},
     "midnight": <epoch>, ...}

The index is built in a background process (see ensure_index), so the board
never waits on it — the first poll for a new station just has no lateness.

Realtime and static trip_ids name the same trip differently: realtime
"062900_1..S15R" vs static "ASP26GEN-1038-Weekday-00_062900_1..S03R". The
origin time (hundredths of a minute after midnight), route and direction
match; the trailing route-pattern code doesn't. trip_key() keeps just the
parts that match. A key shared by two trips in one day's service is
ambiguous and dropped rather than guessed.

Usage (internal): python3 mta_schedule.py build, reading <stopId,stopId,...>
from one line of stdin.
"""
import csv
import datetime
import hashlib
import io
import json
import os
import subprocess
import sys
import time
import zipfile

import mta_feed

GTFS_URL = "https://rrgtfsfeeds.s3.amazonaws.com/gtfs_subway.zip"
# The MTA republishes the static feed every few weeks; a week-old copy is
# close enough for lateness and saves re-downloading 6 MB.
GTFS_MAX_AGE = 7 * 24 * 3600
# The zip was 5.6 MB (43 MB unpacked, stop_times.txt 36 MB of it) on
# 2026-10-20. Ceilings at twice that, so an unexpectedly large zip can't fill
# the disk or memory during a build.
GTFS_MAX_ZIP_BYTES = 11 << 20
GTFS_MAX_UNPACKED_BYTES = 84 << 20
GTFS_DOWNLOAD_SECONDS = 90
MAX_INDEX_BYTES = 215 << 10
# A build that hasn't finished in this long is assumed dead.
BUILD_LOCK_SECONDS = 180
BUILD_RETRY_SECONDS = 3600
BUILD_RETRY_MAX_SECONDS = 86400

CACHE_DIR = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"), "omtarchy")


def trip_key(trip_id):
    """Static or realtime trip_id -> '062900_1..S' (origin time, route,
    direction)."""
    if "_" not in trip_id:
        return None
    head, tail = trip_id.split("_", 1)
    if "-" in head:  # static: "<service prefix>_<origin>_<route>..<dir><pattern>"
        if "_" not in tail:
            return None
        origin, rest = tail.split("_", 1)
    else:  # realtime: "<origin>_<route>..<dir><pattern>"
        origin, rest = head, tail
    route, sep, pattern = rest.partition("..")
    if not sep or not pattern:
        return None
    return origin + "_" + route + ".." + pattern[0]


def service_day(now=None):
    """The service day's date and local-midnight epoch. Trips past midnight
    belong to the previous day's service ("25:10:00"), so they're looked up
    in that day's 'yesterday' table."""
    today = datetime.date.fromtimestamp(now or time.time())
    midnight = datetime.datetime.combine(today, datetime.time()).timestamp()
    return today, midnight


def index_path(stop_ids, day):
    digest = hashlib.sha1(",".join(sorted(stop_ids)).encode()).hexdigest()[:12]
    return os.path.join(CACHE_DIR, "schedule-%s-%s.json" % (day.strftime("%Y%m%d"), digest))


def cache_dir():
    try:
        os.makedirs(os.path.dirname(CACHE_DIR), exist_ok=True)
    except OSError:
        return None
    return mta_feed.private_dir(CACHE_DIR)


def load_index(stop_ids):
    """The index for today and these stops, or None if it isn't built yet."""
    day, _midnight = service_day()
    try:
        with open(index_path(stop_ids, day), "rb") as f:
            raw = f.read(MAX_INDEX_BYTES + 1)
        index = json.loads(raw) if len(raw) <= MAX_INDEX_BYTES else None
    except (OSError, ValueError):
        return None
    if not isinstance(index, dict) or not isinstance(index.get("midnight"), (int, float)):
        return None
    if not all(isinstance(index.get(table, {}), dict) for table in ("today", "yesterday")):
        return None
    return index


def failure_path():
    return os.path.join(CACHE_DIR, "build-failures")


def build_failures():
    try:
        with open(failure_path(), "rb") as f:
            return max(0, int(f.read(16) or b"0"))
    except (OSError, ValueError):
        return 0


def build_backed_off():
    failures = build_failures()
    if not failures:
        return False
    wait = min(BUILD_RETRY_SECONDS * 2 ** min(failures - 1, 10), BUILD_RETRY_MAX_SECONDS)
    try:
        return time.time() - os.path.getmtime(failure_path()) < wait
    except OSError:
        return False


def run_build(stop_ids):
    mta_feed.write_private(failure_path(), str(build_failures() + 1).encode())
    build(stop_ids)
    os.remove(failure_path())


def ensure_index(stop_ids):
    """load_index, starting a background build when it's missing."""
    if not stop_ids or cache_dir() is None:
        return None
    index = load_index(stop_ids)
    if index is not None:
        return index
    if build_backed_off():
        return None
    day, _midnight = service_day()
    lock = index_path(stop_ids, day) + ".building"
    try:
        if time.time() - os.path.getmtime(lock) < BUILD_LOCK_SECONDS:
            return None  # already being built
    except OSError:
        pass
    try:
        mta_feed.write_private(lock, b"")
        builder = subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "build"],
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        builder.stdin.write((",".join(sorted(stop_ids)) + "\n").encode())
        builder.stdin.close()
    except OSError:
        pass
    return None


def delay_minutes(index, realtime_trip_id, stop_id, epoch):
    """Minutes late (negative = early) for one predicted stop time, or None
    when the trip or stop isn't in the timetable (reroutes, extra trains)."""
    if not index:
        return None
    key = trip_key(realtime_trip_id)
    if key is None:
        return None
    for table, base in (("today", index["midnight"]), ("yesterday", index["midnight"] - 86400)):
        entry = index.get(table, {}).get(key)
        secs = entry.get(stop_id) if isinstance(entry, dict) else None
        if isinstance(secs, int):
            return round((epoch - (base + secs)) / 60)
    return None


# ---- building ---------------------------------------------------------------

def gtfs_zip_path():
    path = os.path.join(CACHE_DIR, "gtfs_subway.zip")
    try:
        if time.time() - os.path.getmtime(path) < GTFS_MAX_AGE:
            return path
    except OSError:
        pass
    raw = mta_feed.fetch_bytes(GTFS_URL, GTFS_DOWNLOAD_SECONDS, GTFS_MAX_ZIP_BYTES)
    mta_feed.write_private(path, raw)
    return path


def active_services(zf, day):
    ds = day.strftime("%Y%m%d")
    weekday = day.strftime("%A").lower()
    active = set()
    with zf.open("calendar.txt") as f:
        for row in csv.DictReader(io.TextIOWrapper(f, encoding="utf-8")):
            if row[weekday] == "1" and row["start_date"] <= ds <= row["end_date"]:
                active.add(row["service_id"])
    with zf.open("calendar_dates.txt") as f:
        for row in csv.DictReader(io.TextIOWrapper(f, encoding="utf-8")):
            if row["date"] == ds:
                if row["exception_type"] == "1":
                    active.add(row["service_id"])
                else:
                    active.discard(row["service_id"])
    return active


def build(stop_ids):
    day, midnight = service_day()
    yesterday = day - datetime.timedelta(days=1)
    with zipfile.ZipFile(gtfs_zip_path()) as zf:
        # Sizes as the zip declares them; zipfile itself stops reading a
        # member that inflates past its declared size.
        unpacked = sum(info.file_size for info in zf.infolist())
        if unpacked > GTFS_MAX_UNPACKED_BYTES:
            raise mta_feed.FeedRejected("GTFS zip unpacks to %d bytes" % unpacked)
        services = {"today": active_services(zf, day), "yesterday": active_services(zf, yesterday)}
        trip_table = {}  # static trip_id -> (table, key)
        key_counts = {"today": {}, "yesterday": {}}
        with zf.open("trips.txt") as f:
            for row in csv.DictReader(io.TextIOWrapper(f, encoding="utf-8")):
                key = trip_key(row["trip_id"])
                if key is None:
                    continue
                for table, active in services.items():
                    if row["service_id"] in active:
                        trip_table.setdefault(row["trip_id"], []).append((table, key))
                        key_counts[table][key] = key_counts[table].get(key, 0) + 1

        tables = {"today": {}, "yesterday": {}}
        with zf.open("stop_times.txt") as f:
            reader = csv.reader(io.TextIOWrapper(f, encoding="utf-8"))
            header = next(reader)
            col = {name: i for i, name in enumerate(header)}
            for row in reader:
                entries = trip_table.get(row[col["trip_id"]])
                if not entries:
                    continue
                stop = row[col["stop_id"]]
                if stop[:-1] not in stop_ids:
                    continue
                h, m, s = (int(x) for x in (row[col["arrival_time"]] or row[col["departure_time"]]).split(":"))
                secs = h * 3600 + m * 60 + s
                for table, key in entries:
                    if key_counts[table][key] != 1:
                        continue  # ambiguous: two trips share this key today
                    # Only yesterday's after-midnight trips are still running today.
                    if table == "yesterday" and secs < 86400:
                        continue
                    tables[table].setdefault(key, {})[stop] = secs

    index = {"midnight": midnight, "today": tables["today"], "yesterday": tables["yesterday"]}
    mta_feed.write_private(index_path(stop_ids, day), json.dumps(index, separators=(",", ":")).encode())

    # Yesterday's indexes are dead weight now.
    for name in os.listdir(CACHE_DIR):
        if name.startswith("schedule-") and name.endswith(".json") and not name.startswith("schedule-" + day.strftime("%Y%m%d")):
            try:
                os.remove(os.path.join(CACHE_DIR, name))
            except OSError:
                pass


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "build":
        mta_feed.limit_memory()
        # Die before the lock goes stale: otherwise a build stuck on an
        # unresponsive server outlives it, and every later poll spawns another.
        mta_feed.limit_runtime(BUILD_LOCK_SECONDS - 10)
        line = sys.stdin.buffer.readline(mta_feed.MAX_INPUT_BYTES + 1)
        ids = {s for s in line.decode("utf-8", "replace").strip().split(",") if s}
        try:
            if ids and len(line) <= mta_feed.MAX_INPUT_BYTES and cache_dir() is not None:
                run_build(ids)
        finally:
            try:
                os.remove(index_path(ids, service_day()[0]) + ".building")
            except OSError:
                pass
