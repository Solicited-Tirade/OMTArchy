"""Shared MTA GTFS-realtime plumbing for bin/nyc-subway-status and
bin/nyc-subway-trip: feed URLs, a gzip-aware fetch, stop_id parsing, and
the route-id translation between the live feeds and Stations.js.

Route ids don't match one-to-one between the live feeds and the static
station data (and so the rest of the UI). The feeds use "GS"/"FS"/"H" for
the 42 St, Franklin Av and Rockaway Park shuttles, "SI" for the Staten
Island Railway, and "6X"/"7X"/"FX" for the diamond express variants;
Stations.js and the signage riders know use "S", "SIR", and plain 6/7/F.
Everything this module hands back to the UI uses the static ("display")
spelling, so a route is spelled the same way everywhere in the UI.
"""
import gzip
import os
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:
    import gtfs_realtime_pb2 as gtfs  # noqa: E402
except Exception as e:  # noqa: BLE001 - missing or too-old python-protobuf
    gtfs = None
    IMPORT_ERROR = e
else:
    IMPORT_ERROR = None

try:
    from google.protobuf import unknown_fields  # noqa: E402
except Exception:  # noqa: BLE001 - only the MTA extensions need this
    unknown_fields = None

import urllib.request  # noqa: E402

FEED_PATHS = {
    "1234567S": "gtfs",
    "ACE": "gtfs-ace",
    "BDFM": "gtfs-bdfm",
    "G": "gtfs-g",
    "JZ": "gtfs-jz",
    "NQRW": "gtfs-nqrw",
    "L": "gtfs-l",
    "SIR": "gtfs-si",
}

FEED_BASE = "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/nyct%2F"
# Subway-only alerts: same data as camsys/all-alerts for our purposes, about
# a third smaller since it leaves out LIRR/Metro-North/bus notices.
ALERTS_URL = "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/camsys%2Fsubway-alerts"
# Elevator/escalator outages, and the equipment list that ties each piece
# of equipment to a station complex. Plain JSON, no API key.
OUTAGES_URL = FEED_BASE + "nyct_ene.json"
EQUIPMENT_URL = FEED_BASE + "nyct_ene_equipments.json"

CACHE_DIR = os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir()

USER_AGENT = "omarchy-nyc-subway-plugin/1.1"

DISPLAY_ROUTE = {"GS": "S", "FS": "S", "H": "S", "SI": "SIR", "6X": "6", "7X": "7", "FX": "F"}
EXPRESS_ROUTES = {"6X", "7X", "FX"}
SHUTTLE_BY_FEED = {"1234567S": "GS", "ACE": "H", "BDFM": "FS"}


def display_route(route_id):
    return DISPLAY_ROUTE.get(route_id, route_id)


def feed_route_ids(display, feed_group):
    """Every live-feed route_id a display route stands for. "S" needs the
    feed group to say which of the three shuttles it means."""
    if display == "S":
        shuttle = SHUTTLE_BY_FEED.get(feed_group)
        return {shuttle} if shuttle else {"GS", "FS", "H"}
    if display == "SIR":
        return {"SI"}
    ids = {display}
    ids.update(raw for raw, disp in DISPLAY_ROUTE.items() if disp == display)
    return ids


def parse_route_list(text, feed_group):
    """'1,2,S' -> the set of live-feed route_ids those display routes cover.
    A token may carry its own feed as 'S@BDFM', which beats feed_group —
    the only way to tell the three "S" shuttles apart across a station
    spanning several feeds."""
    out = set()
    for token in text.split(","):
        token = token.strip()
        if not token:
            continue
        route, _, token_feed = token.partition("@")
        out |= feed_route_ids(route, token_feed or feed_group)
    return out


def parse_stop_tokens(text, default_feed):
    """'127:1234567S,R16:NQRW,631' -> {feed: {stop_id, ...}}. A token with
    no ':feed' suffix belongs to default_feed."""
    by_feed = {}
    for token in text.split(","):
        token = token.strip()
        if not token:
            continue
        stop, _, feed = token.partition(":")
        feed = feed if feed in FEED_PATHS else default_feed
        by_feed.setdefault(feed, set()).add(stop)
    return by_feed


def split_stop_id(sid):
    """'127N' -> ('127', 'N'); '127' -> ('127', '')."""
    if sid and sid[-1] in ("N", "S"):
        return sid[:-1], sid[-1]
    return sid, ""


def stop_time(stop_time_update):
    """The best available time for one stop_time_update, or None."""
    if stop_time_update.HasField("arrival") and stop_time_update.arrival.time:
        return stop_time_update.arrival.time
    if stop_time_update.HasField("departure") and stop_time_update.departure.time:
        return stop_time_update.departure.time
    return None


def fetch_bytes(url, timeout=10):
    # The MTA endpoint gzips on request: ~4-6x less data per poll (the
    # 1234567S feed is ~190 KB raw vs ~45 KB gzipped).
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept-Encoding": "gzip"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
        if resp.headers.get("Content-Encoding") == "gzip":
            raw = gzip.decompress(raw)
    return raw


def parse_feed(raw):
    feed = gtfs.FeedMessage()
    feed.ParseFromString(raw)
    return feed


def fetch_feed(url, timeout=10):
    return parse_feed(fetch_bytes(url, timeout))


def feed_url(feed_group):
    path = FEED_PATHS.get(feed_group)
    return FEED_BASE + path if path else None


def fetch_feeds(feed_groups):
    """{feed_group: FeedMessage or the exception that fetching it raised},
    fetched in parallel — a station spanning four feeds shouldn't take four
    times as long as one."""
    groups = [g for g in feed_groups if g in FEED_PATHS]
    if not groups:
        return {}

    def one(group):
        try:
            return fetch_feed(feed_url(group))
        except Exception as e:  # noqa: BLE001 - reported per feed by the caller
            return e

    with ThreadPoolExecutor(max_workers=len(groups)) as pool:
        return dict(zip(groups, pool.map(one, groups)))


def cached_bytes(url, name, max_age):
    """fetch_bytes, but reusing a copy under CACHE_DIR younger than
    max_age seconds — for the big, slow-changing feeds (alerts, elevator
    data) that don't need refetching on every 30s arrivals poll."""
    path = os.path.join(CACHE_DIR, "omtarchy-" + name)
    try:
        if time.time() - os.path.getmtime(path) < max_age:
            with open(path, "rb") as f:
                return f.read()
    except OSError:
        pass
    raw = fetch_bytes(url)
    try:
        tmp = path + ".%d" % os.getpid()
        with open(tmp, "wb") as f:
            f.write(raw)
        os.replace(tmp, path)
    except OSError:
        pass  # caching is an optimization; an unwritable dir just means refetching
    return raw


# ---- MTA protobuf extensions -------------------------------------------
# The MTA adds its own fields under extension number 1001: NyctTripDescriptor
# on each trip (train_id = 1, is_assigned = 2) and MercuryAlert on each alert
# (alert_type = 3, human_readable_active_period = 8). The bundled
# gtfs_realtime_pb2 doesn't know them, so protobuf keeps them as unknown
# fields; this decodes just those few bytes by hand rather than shipping a
# second generated module pinned to a protobuf version.

def _varint(buf, i):
    result = shift = 0
    while True:
        byte = buf[i]
        i += 1
        result |= (byte & 0x7F) << shift
        shift += 7
        if byte < 0x80:
            return result, i


def decode_fields(buf):
    """Raw protobuf bytes -> {field_number: [values]}: ints for varints,
    bytes for length-delimited fields (strings and nested messages)."""
    out = {}
    i = 0
    try:
        while i < len(buf):
            key, i = _varint(buf, i)
            field, wire = key >> 3, key & 7
            if wire == 0:
                value, i = _varint(buf, i)
            elif wire == 2:
                length, i = _varint(buf, i)
                value = bytes(buf[i:i + length])
                i += length
            elif wire == 1:
                value, i = bytes(buf[i:i + 8]), i + 8
            elif wire == 5:
                value, i = bytes(buf[i:i + 4]), i + 4
            else:
                break  # groups: never used by the MTA extensions
            out.setdefault(field, []).append(value)
    except IndexError:
        pass  # truncated: keep whatever decoded cleanly
    return out


def extension(message, field_number=1001):
    """The decoded fields of one MTA extension on message, or {}."""
    if unknown_fields is None:
        return {}
    try:
        for field in unknown_fields.UnknownFieldSet(message):
            if field.field_number == field_number and isinstance(field.data, (bytes, bytearray)):
                return decode_fields(field.data)
    except Exception:  # noqa: BLE001 - extensions are best-effort extras
        return {}
    return {}


def ext_text(fields, number):
    values = fields.get(number)
    if not values or not isinstance(values[0], bytes):
        return ""
    return values[0].decode("utf-8", "replace")


def ext_translated_text(fields, number):
    """A TranslatedString extension field -> its first translation's text."""
    values = fields.get(number)
    if not values or not isinstance(values[0], bytes):
        return ""
    for translation in decode_fields(values[0]).get(1, []):
        text = ext_text(decode_fields(translation), 1)
        if text:
            return text
    return ""
