"""Shared MTA GTFS-realtime plumbing for bin/nyc-subway-status and
bin/nyc-subway-trip: feed URLs, a size-limited gzip-aware fetch, sanity
checks on what comes back, stop_id parsing, and the route-id translation
between the live feeds and Stations.js.

Route ids don't match one-to-one between the live feeds and the static
station data (and so the rest of the UI). The feeds use "GS"/"FS"/"H" for
the 42 St, Franklin Av and Rockaway Park shuttles, "SI" for the Staten
Island Railway, and "6X"/"7X"/"FX" for the diamond express variants;
Stations.js and the signage riders know use "S", "SIR", and plain 6/7/F.
Everything this module hands back to the UI uses the static ("display")
spelling, so a route is spelled the same way everywhere in the UI.
"""
import json
import os
import re
import sys
import tempfile
import time
import zlib
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

import urllib.parse  # noqa: E402
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


# ---- Fetch limits ------------------------------------------------------
# Baseline from a live pull of every endpoint (2026-10-20): the biggest
# decoded body is the elevator equipment list at ~645 KB (alerts ~440 KB,
# the 1234567S trip feed ~180 KB), all served gzipped from these two hosts
# in well under a second with no redirects. The limits leave 20x+ headroom
# so a busy day never trips them, while a gzip bomb, an endless body or a
# trickling server is cut off long before it threatens the helper's memory
# or holds up the board.
MAX_FEED_BYTES = 16 << 20
ALLOWED_HOSTS = {"api-endpoint.mta.info", "rrgtfsfeeds.s3.amazonaws.com"}
READ_CHUNK = 64 * 1024
# Helper processes never need more than ~155 MB of heap (measured: the
# Lines view parsing all eight feeds at once); this is a backstop for a
# parser bug or a hostile response the size checks above didn't catch.
# RLIMIT_DATA rather than RLIMIT_AS: glibc reserves ~64 MB of address space
# per thread arena, so eight fetch threads already reach ~740 MB virtual
# while using a fraction of that.
MEMORY_LIMIT = 1 << 30
# Whole-run ceiling for the Panel's helpers, just under its 45 s watchdog
# (Panel.qml helperTimeoutMs) so a stuck helper ends itself first.
HELPER_SECONDS = 40


class FeedRejected(ValueError):
    """A response refused before parsing: too big, wrongly encoded, too
    slow, or served from somewhere other than the MTA's own hosts."""


def limit_memory(limit=MEMORY_LIMIT):
    """Cap this process's heap so a runaway allocation fails with
    MemoryError instead of exhausting the session. Children inherit it."""
    try:
        import resource
        soft, hard = resource.getrlimit(resource.RLIMIT_DATA)
        if hard != resource.RLIM_INFINITY:
            limit = min(limit, hard)
        if soft == resource.RLIM_INFINITY or soft > limit:
            resource.setrlimit(resource.RLIMIT_DATA, (limit, hard))
    except (ImportError, ValueError, OSError):
        pass  # best-effort: the size limits in fetch_bytes still apply


def limit_runtime(seconds):
    """Kill this process (SIGALRM's default action) after seconds, however
    it's stuck: the one bound that also covers a server trickling its
    response headers, which no socket timeout does."""
    try:
        import signal
        signal.alarm(seconds)
    except (ImportError, AttributeError, ValueError):
        pass


def check_url(url):
    parts = urllib.parse.urlsplit(url)
    if parts.scheme != "https" or parts.hostname not in ALLOWED_HOSTS:
        raise FeedRejected("refusing non-MTA URL: %s://%s" % (parts.scheme, parts.hostname))


class _MtaOnlyRedirects(urllib.request.HTTPRedirectHandler):
    """Follow a redirect only to another https MTA host, never off-site or
    down to plain http."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        check_url(urllib.parse.urljoin(req.full_url, newurl))
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_opener = urllib.request.build_opener(_MtaOnlyRedirects)


def fetch_bytes(url, timeout=10, limit=MAX_FEED_BYTES):
    """_download, flagging a refused response so the reason reaches the
    UI even where the caller treats the fetch as best-effort."""
    try:
        return _download(url, timeout, limit)
    except FeedRejected as e:
        flag("%s: refused, %s" % (_label(url), e))
        raise


def _download(url, timeout, limit):
    """The decoded body of url, at most limit bytes. timeout bounds the
    whole download, not just each socket read: one stalled read can overrun
    it by at most another timeout, and the Panel's watchdog covers the rest."""
    check_url(url)
    deadline = time.monotonic() + timeout
    # The MTA endpoint gzips on request: ~4-6x less data per poll (the
    # 1234567S feed is ~180 KB raw vs ~40 KB gzipped).
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept-Encoding": "gzip"})
    with _opener.open(req, timeout=timeout) as resp:
        encoding = (resp.headers.get("Content-Encoding") or "identity").strip().lower()
        if encoding not in ("gzip", "identity"):
            raise FeedRejected("unexpected Content-Encoding: " + encoding[:40])
        length = resp.headers.get("Content-Length") or ""
        if length.isdigit() and int(length) > limit:
            raise FeedRejected("response of %s bytes is over the %d-byte limit" % (length, limit))
        # Inflated chunk by chunk with max_length, so a compact gzip bomb
        # stops one byte past the limit instead of expanding in full.
        inflater = zlib.decompressobj(16 + zlib.MAX_WBITS) if encoding == "gzip" else None
        out = bytearray()
        received = 0
        trailing = False
        while True:
            if time.monotonic() > deadline:
                raise FeedRejected("download took longer than %ds" % timeout)
            # read1: return whatever one socket read brings, rather than
            # blocking until a whole chunk has trickled in.
            chunk = resp.read1(READ_CHUNK)
            if not chunk:
                break
            received += len(chunk)
            if received > limit:
                raise FeedRejected("response is over the %d-byte limit" % limit)
            if inflater is not None:
                if inflater.eof:
                    trailing = True
                    continue
                chunk = inflater.decompress(chunk, limit - len(out) + 1)
            out += chunk
            if len(out) > limit:
                raise FeedRejected("decoded response is over the %d-byte limit" % limit)
        if inflater is not None:
            out += inflater.flush()
            if not inflater.eof:
                raise FeedRejected("truncated gzip stream")
            if len(out) > limit:
                raise FeedRejected("decoded response is over the %d-byte limit" % limit)
            if trailing or inflater.unused_data:
                flag("%s: extra bytes after the gzip stream" % _label(url))
    # A quarter of the hard limit is still several times anything seen
    # (the realtime feeds' biggest is 645 KB of 16 MB; the GTFS zip 5.6 MB
    # of 64 MB), so getting near it is worth a mention.
    if len(out) > limit // 4:
        flag("%s: %d KB, far bigger than usual" % (_label(url), len(out) // 1024))
    return bytes(out)


def error_reason(e):
    """A helper's error code for an exception from fetching or parsing."""
    if isinstance(e, FeedRejected):
        return "feed-rejected"
    if isinstance(e, OSError):  # URLError, timeouts, connection resets
        return "fetch-failed"
    return "parse-failed"


def parse_feed(raw, label=None):
    """A FeedMessage from raw bytes; with a label, also checked against
    what the MTA's feeds normally look like (see check_feed)."""
    feed = gtfs.FeedMessage()
    feed.ParseFromString(raw)
    if label:
        check_feed(feed, label)
    return feed


def fetch_feed(url, timeout=10):
    return parse_feed(fetch_bytes(url, timeout), _label(url))


# ---- Expectations ------------------------------------------------------
# What the MTA's feeds normally look like, set from the same live pull as
# the fetch limits and deliberately loose: real feeds vary a lot (a
# disruption can double the alerts, the overnight feeds shrink to a handful
# of trains), so each bound sits several times past anything observed. A
# miss is never fatal — the data is still shown — but it's flagged, because
# a feed that suddenly looks nothing like itself may not be the MTA's.
#
# Observed: gtfs_realtime_version "1.0" (trip feeds) / "2.0" (alerts);
# header timestamps 0-150 s old; at most 389 entities and 49 stop updates
# per trip; predictions from 4 h past to 2.6 h ahead; route ids like "7X"
# and stop ids like "R16N"; alert text under 300 chars with no markup,
# links or control characters.
KNOWN_VERSIONS = {"1.0", "2.0"}
MAX_CLOCK_AHEAD = 15 * 60
MAX_HEADER_AGE = 24 * 3600
MAX_ENTITIES = 5000
MAX_STOP_UPDATES = 250
PREDICTION_WINDOW = (-24 * 3600, 12 * 3600)
MAX_TEXT = 2000
MAX_ANOMALIES = 20
ROUTE_ID_RE = re.compile(r"[A-Z0-9]{1,4}\Z")
STOP_ID_RE = re.compile(r"[A-Z0-9]{1,6}[NS]?\Z")
# Markup a notification server would render, links, and control or
# bidi-override characters (the latter can make text read differently
# from what it says).
MARKUP_RE = re.compile(r"<\s*[A-Za-z/!?]")
LINK_RE = re.compile(r"(?:[a-z][a-z0-9+.-]*://|www\.)([^\s/<>\"'?#]*)", re.I)
# A bare "example.com/login" with no scheme. Lowercase only, against a
# short list of TLDs, so "Jamaica Ctr.Parsons" or "St.George" can't match.
BARE_LINK_RE = re.compile(r"(?<![\w@/.-])((?:[a-z0-9-]+\.)+(?:com|net|org|io|co|info|xyz|app|link|site|online|top|me|ly|gl|ru|cn))\b(?!\.\w)")
SCRIPT_URI_RE = re.compile(r"\b(?:javascript|vbscript):|\bdata:[a-z]+/", re.I)
# Zero-width joiner (U+200D) is left out: it's how emoji sequences are built.
CONTROL_RE = re.compile("[\x00-\x08\x0b\x0c\x0e-\x1f\x7f\u200b\u200c\u200e\u200f\u202a-\u202e\u2060\u2066-\u2069\ufeff]")
TRUSTED_LINK_DOMAINS = ("mta.info", "ny.gov", "nyc.gov")

# Everything flagged during this run, in the order found. A helper reports
# them in its JSON output; each is also written to stderr as it's found.
anomalies = []


def flag(message):
    if message in anomalies or len(anomalies) >= MAX_ANOMALIES:
        return
    anomalies.append(message)
    print("omtarchy: feed check: " + message, file=sys.stderr)


def _label(url):
    """'…/nyct%2Fgtfs-ace' -> 'gtfs-ace': a short name for messages."""
    tail = urllib.parse.unquote(urllib.parse.urlsplit(url).path).rsplit("/", 1)[-1]
    return tail or url


def _trusted_link(host):
    host = host.lower().rstrip(".").split(":")[0]
    return any(host == d or host.endswith("." + d) for d in TRUSTED_LINK_DOMAINS)


def check_text(text, where):
    """Flag rider-facing text that doesn't look like an MTA notice."""
    if not text:
        return
    if len(text) > MAX_TEXT:
        flag("%s: %d-character text" % (where, len(text)))
    if CONTROL_RE.search(text):
        flag("%s: control characters in text" % where)
    if MARKUP_RE.search(text):
        flag("%s: markup in text" % where)
    if SCRIPT_URI_RE.search(text):
        flag("%s: script or data URI in text" % where)
    for host in LINK_RE.findall(text) + BARE_LINK_RE.findall(text):
        if not _trusted_link(host):
            flag("%s: link to %s" % (where, host[:60] or "an unknown site"))


def check_feed(feed, label, now=None):
    """Compare one parsed GTFS-realtime feed against the expectations
    above, flagging whatever falls outside them."""
    now = now or time.time()
    header = feed.header
    if header.gtfs_realtime_version not in KNOWN_VERSIONS:
        flag("%s: unknown GTFS-realtime version %r" % (label, header.gtfs_realtime_version[:20]))
    if header.timestamp > now + MAX_CLOCK_AHEAD:
        flag("%s: timestamp %d min in the future" % (label, (header.timestamp - now) // 60))
    elif header.timestamp and header.timestamp < now - MAX_HEADER_AGE:
        flag("%s: timestamp over a day old" % label)
    if len(feed.entity) > MAX_ENTITIES:
        flag("%s: %d entities, far more than usual" % (label, len(feed.entity)))

    bad_routes, bad_stops, long_trips, odd_times = set(), 0, 0, 0
    earliest, latest = now + PREDICTION_WINDOW[0], now + PREDICTION_WINDOW[1]
    for entity in feed.entity:
        if not entity.HasField("trip_update"):
            continue
        trip_update = entity.trip_update
        route_id = trip_update.trip.route_id
        if route_id and not ROUTE_ID_RE.match(route_id):
            bad_routes.add(route_id[:12])
        updates = trip_update.stop_time_update
        if len(updates) > MAX_STOP_UPDATES:
            long_trips += 1
        for update in updates:
            if update.stop_id and not STOP_ID_RE.match(update.stop_id):
                bad_stops += 1
            when = stop_time(update)
            if when is not None and not earliest <= when <= latest:
                odd_times += 1
    if bad_routes:
        flag("%s: malformed route ids %s" % (label, ", ".join(repr(r) for r in sorted(bad_routes)[:3])))
    if bad_stops:
        flag("%s: %d malformed stop ids" % (label, bad_stops))
    if long_trips:
        flag("%s: %d trips with over %d stops" % (label, long_trips, MAX_STOP_UPDATES))
    if odd_times:
        flag("%s: %d predictions outside -24h..+12h" % (label, odd_times))


def load_json_list(raw, label):
    """The MTA's elevator/outage JSON: a list of flat records. Anything
    else can't be used at all, so it's refused rather than flagged."""
    data = json.loads(raw)
    if not isinstance(data, list) or not all(isinstance(item, dict) for item in data):
        raise FeedRejected("%s: expected a list of records" % label)
    if len(data) > MAX_ENTITIES * 4:
        flag("%s: %d records, far more than usual" % (label, len(data)))
    return data


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
        # A protobuf varint is at most 10 bytes. Without this cap a hostile
        # megabyte-long one builds a huge integer one quadratic shift at a
        # time (measured: 69 s of CPU for 1 MB); treated as truncation.
        if shift >= 70:
            raise IndexError("varint too long")
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
        if not isinstance(translation, bytes):
            continue  # malformed: a varint where a message belongs
        text = ext_text(decode_fields(translation), 1)
        if text:
            return text
    return ""
