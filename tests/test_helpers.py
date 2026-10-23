import gzip
import http.client
import importlib.machinery
import importlib.util
import io
import json
import os
import stat
import sys
import tempfile
import time
import unittest
import urllib.request
from contextlib import redirect_stdout
from unittest import mock

BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin")
sys.path.insert(0, BIN)

import mta_feed  # noqa: E402

gtfs = mta_feed.gtfs


def load_script(name):
    loader = importlib.machinery.SourceFileLoader(name.replace("-", "_"), os.path.join(BIN, name))
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
    loader.exec_module(module)
    return module


status = load_script("nyc-subway-status")
lines = load_script("nyc-subway-lines")


def trip_feed(trip_id="091400_1..N03R", route_id="1", stops=("127N", "101N"), entities=1, version="1.0", offset=600):
    feed = gtfs.FeedMessage()
    feed.header.gtfs_realtime_version = version
    feed.header.timestamp = int(time.time())
    now = int(time.time())
    for n in range(entities):
        entity = feed.entity.add()
        entity.id = str(n)
        entity.trip_update.trip.trip_id = trip_id
        entity.trip_update.trip.route_id = route_id
        for i, stop_id in enumerate(stops):
            update = entity.trip_update.stop_time_update.add()
            update.stop_id = stop_id
            update.arrival.time = now + offset + i * 60
    return feed


def alerts_feed(header, routes, language="en", period=""):
    feed = gtfs.FeedMessage()
    feed.header.gtfs_realtime_version = "2.0"
    feed.header.timestamp = int(time.time())
    entity = feed.entity.add()
    entity.id = "a"
    entity.alert.header_text.translation.add(text=header, language=language)
    for route in routes:
        entity.alert.informed_entity.add(route_id=route)
    return feed


def length_delimited(field, payload):
    def varint(n):
        out = bytearray()
        while n > 0x7F:
            out.append(n & 0x7F | 0x80)
            n >>= 7
        return bytes(out) + bytes([n])
    return varint(field << 3 | 2) + varint(len(payload)) + payload


def add_mercury(alert, alert_type, period):
    translation = length_delimited(1, period.encode())
    extension = length_delimited(3, alert_type.encode()) + length_delimited(8, length_delimited(1, translation))
    alert.ParseFromString(alert.SerializeToString() + length_delimited(1001, extension))


def capture_stdout(fn):
    out = io.TextIOWrapper(io.BytesIO(), encoding="utf-8")
    with redirect_stdout(out):
        fn()
    out.flush()
    return out.buffer.getvalue().decode("utf-8")


def run_main(module, args):
    stdin = io.TextIOWrapper(io.BytesIO((json.dumps(args) + "\n").encode()))
    with mock.patch.object(sys, "stdin", stdin):
        return capture_stdout(module.main)


class FakeResponse:
    def __init__(self, body, encoding="gzip", length=None):
        self.headers = {"Content-Encoding": encoding}
        if length is not None:
            self.headers["Content-Length"] = str(length)
        self.stream = io.BytesIO(body)

    def read1(self, n):
        return self.stream.read(min(n, 4096))

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class Reset(unittest.TestCase):
    def setUp(self):
        mta_feed.anomalies.clear()
        signal_alarm = mock.patch("signal.alarm")
        signal_alarm.start()
        self.addCleanup(signal_alarm.stop)


class FieldValidation(Reset):
    def test_oversized_trip_id_is_left_out(self):
        feed = mta_feed.check_feed(trip_feed(trip_id="\x01" * (1 << 20)), "test")
        self.assertEqual(len(feed.entity), 0)

    def test_oversized_route_id_is_left_out(self):
        feed = mta_feed.check_feed(trip_feed(route_id="A" * 4096), "test")
        self.assertEqual(len(feed.entity), 0)

    def test_oversized_destination_is_left_out(self):
        feed = mta_feed.check_feed(trip_feed(stops=("127N", "Z" * 100000)), "test")
        self.assertEqual(len(feed.entity), 0)

    def test_repeated_platform_is_left_out(self):
        feed = mta_feed.check_feed(trip_feed(stops=("127N",) * 81 + ("101N",)), "test")
        self.assertEqual(len(feed.entity), 0)

    def test_too_many_stops_is_left_out(self):
        stops = tuple("%03dN" % i for i in range(mta_feed.MAX_STOP_UPDATES + 1))
        feed = mta_feed.check_feed(trip_feed(stops=stops), "test")
        self.assertEqual(len(feed.entity), 0)

    def test_prediction_far_in_future_is_left_out(self):
        feed = mta_feed.check_feed(trip_feed(offset=13 * 3600), "test")
        self.assertEqual(len(feed.entity), 0)

    def test_too_many_entities_is_refused(self):
        with self.assertRaises(mta_feed.FeedRejected):
            mta_feed.check_feed(trip_feed(entities=mta_feed.MAX_ENTITIES + 1), "test")

    def test_unknown_version_is_refused(self):
        with self.assertRaises(mta_feed.FeedRejected):
            mta_feed.check_feed(trip_feed(version="9.9"), "test")

    def test_missing_header_timestamp_is_refused(self):
        feed = trip_feed()
        feed.header.timestamp = 0
        with self.assertRaises(mta_feed.FeedRejected):
            mta_feed.check_feed(feed, "test")

    def test_future_header_is_refused(self):
        feed = trip_feed()
        feed.header.timestamp = int(time.time()) + 3600
        with self.assertRaises(mta_feed.FeedRejected):
            mta_feed.check_feed(feed, "test")

    def test_valid_trip_is_kept(self):
        feed = mta_feed.check_feed(trip_feed(), "test")
        self.assertEqual(len(feed.entity), 1)
        self.assertEqual(mta_feed.anomalies, [])


class Text(Reset):
    def test_long_word_is_linear(self):
        started = time.monotonic()
        mta_feed.clean_text("a" * 1_000_000, "test")
        self.assertLess(time.monotonic() - started, 2)

    def test_text_is_cut(self):
        text = mta_feed.clean_text("x" * 50000, "test")
        self.assertEqual(len(text), mta_feed.MAX_TEXT)

    def test_controls_are_removed(self):
        self.assertEqual(mta_feed.clean_text("De\x01lay‮", "test"), "Delay")

    def test_invisible_characters_are_removed(self):
        tags = "".join(chr(0xE0000 + ord(c)) for c in "ignore")
        text = "De­l؜ay᠎ ⁢￹\x85" + tags + "\ud800"
        self.assertEqual(mta_feed.clean_text(text, "test"), "Delay")

    def test_markup_is_withheld(self):
        self.assertIsNone(mta_feed.clean_text("<img src=http://x/a.png>", "test"))

    def test_offsite_link_is_withheld(self):
        self.assertIsNone(mta_feed.clean_text("Details at https://www.example.com/login", "test"))
        self.assertIsNone(mta_feed.clean_text("Details at example.com", "test"))

    def test_script_uri_is_withheld(self):
        self.assertIsNone(mta_feed.clean_text("javascript:alert(1)", "test"))

    def test_mta_link_is_kept(self):
        self.assertEqual(mta_feed.clean_text("See https://new.mta.info/alerts", "test"), "See https://new.mta.info/alerts")

    def test_html_translation_is_never_used(self):
        feed = alerts_feed("<p>Delays</p>", ["1"], language="en-html")
        self.assertEqual(mta_feed.english_text(feed.entity[0].alert.header_text), "")


class Output(Reset):
    def test_emit_refuses_oversized_output(self):
        out = capture_stdout(lambda: mta_feed.emit({"x": "y" * (2 << 20)}))
        self.assertLess(len(out), 200)
        self.assertEqual(json.loads(out)["error"], "output-too-large")

    def test_emit_leaves_out_optional_sections_before_refusing(self):
        result = {"arrivals": [{"tripId": "T1"}], "outages": [], "alerts": ["😀" * (400 << 10)], "anomalies": mta_feed.anomalies}
        out = capture_stdout(lambda: mta_feed.emit(result, optional=("outages", "alerts")))
        reply = json.loads(out)
        self.assertEqual(reply["arrivals"], [{"tripId": "T1"}])
        self.assertEqual(reply["alerts"], [])
        self.assertEqual(len(reply["anomalies"]), 2)

    def test_emit_counts_bytes_and_writes_utf8(self):
        out = capture_stdout(lambda: mta_feed.emit({"x": "é😀"}))
        self.assertEqual(json.loads(out), {"x": "é😀"})
        self.assertEqual(json.loads(capture_stdout(lambda: mta_feed.emit({"x": "😀" * (100 << 10)})))["error"], "output-too-large")

    def test_status_output_is_bounded_for_oversized_feed(self):
        oversized = trip_feed(trip_id="\x01" * (1 << 20), stops=("127N",) * 81 + ("101N",))
        valid = trip_feed(entities=mta_feed.MAX_ENTITIES)
        for name, raw in (("oversized", oversized), ("full", valid)):
            parsed = mta_feed.parse_feed(raw.SerializeToString(), "1234567S")
            with mock.patch.object(mta_feed, "fetch_feeds", return_value={"1234567S": parsed}), \
                    mock.patch.object(status.mta_schedule, "ensure_index", return_value=None):
                out = run_main(status, ["1234567S", "127", "both", "", "", "", ""])
            self.assertLessEqual(len(out), mta_feed.MAX_OUTPUT_BYTES + 1, name)
            self.assertLessEqual(len(json.loads(out).get("arrivals", [])), status.MAX_ROWS, name)

    def test_lines_output_is_bounded_for_oversized_alert(self):
        raw = alerts_feed("\x01" * (3 << 20), [r for r, _f, _l in lines.LINES]).SerializeToString()
        empty = trip_feed(entities=0)
        with mock.patch.object(mta_feed, "fetch_feeds", return_value={g: empty for g in mta_feed.FEED_PATHS}), \
                mock.patch.object(mta_feed, "cached_bytes", return_value=raw):
            out = run_main(lines, [])
        self.assertLessEqual(len(out), mta_feed.MAX_OUTPUT_BYTES + 1)

    def test_timing_points_are_left_out_of_stops_and_counts(self):
        now = int(time.time())
        feed = trip_feed(trip_id="000100_N..S", route_id="N", stops=("R60S", "R01S", "R60S", "R03S", "R65S"))
        feed.entity[0].trip_update.stop_time_update[2].stop_id = "R65S"
        feed.entity[0].trip_update.stop_time_update[4].stop_id = "R99S"
        vehicle = feed.entity.add(id="v").vehicle
        vehicle.trip.trip_id = "000100_N..S"
        vehicle.stop_id = "R60S"
        rows = status.arrivals_from_feed(feed, "NQRW", {"R01"}, "both", set(), now, None)
        self.assertEqual(len(rows), 1)
        self.assertEqual([s["stopId"] for s in rows[0]["stops"]], ["R01", "R03"])
        self.assertEqual(rows[0]["stopsAway"], 0)
        self.assertEqual(rows[0]["destStopId"], "R03")
        self.assertEqual(rows[0]["posStopId"], "")

    def test_stops_away_counts_from_where_the_train_is(self):
        now = int(time.time())
        feed = trip_feed(trip_id="000100_N..N", route_id="N", stops=("R06N", "R05N", "R04N", "R03N", "R01N"), offset=-20)
        assigned = length_delimited(1001, bytes([2 << 3, 1]))
        trip = feed.entity[0].trip_update.trip
        trip.ParseFromString(trip.SerializeToString() + assigned)
        vehicle = feed.entity.add(id="v").vehicle
        vehicle.trip.trip_id = "000100_N..N"
        vehicle.stop_id = "R05N"
        vehicle.current_status = 1
        rows = status.arrivals_from_feed(feed, "NQRW", {"R03"}, "both", set(), now, None)
        self.assertEqual(rows[0]["stopsAway"], 2)
        self.assertEqual(rows[0]["posStopId"], "R05")
        vehicle.stop_id = "R01N"
        self.assertEqual(status.arrivals_from_feed(feed, "NQRW", {"R03"}, "both", set(), now, None), [])
        del feed.entity[0].trip_update.stop_time_update[0]
        vehicle.stop_id = "R06N"
        self.assertEqual(status.arrivals_from_feed(feed, "NQRW", {"R03"}, "both", set(), now, None)[0]["stopsAway"], 3)

    def test_followed_train_reports_its_path_after_passing_the_station(self):
        feed = trip_feed(trip_id="000100_N..N", route_id="N", stops=("R20N", "R19N", "R18N", "R60N", "R17N"), offset=-90)
        vehicle = feed.entity.add(id="v").vehicle
        vehicle.trip.trip_id = "000100_N..N"
        vehicle.stop_id = "R19N"
        vehicle.current_status = 1
        followed = status.follow_status({"NQRW": feed}, "NQRW|000100_N..N")
        self.assertEqual(followed["posStopId"], "R19")
        self.assertEqual([s["stopId"] for s in followed["stops"]], ["R19", "R18", "R17"])
        self.assertEqual(status.follow_status({"NQRW": feed}, "NQRW|gone")["found"], False)
        self.assertIsNone(status.follow_status({"NQRW": feed}, "malformed"))

    def test_ride_does_not_count_the_station_the_train_is_standing_at(self):
        feed = trip_feed(trip_id="000100_N..S", route_id="N", stops=("R01S", "R03S", "R04S"))
        vehicle = feed.entity.add(id="v").vehicle
        vehicle.trip.trip_id = "000100_N..S"
        vehicle.stop_id = "R01S"
        vehicle.current_status = 1
        ride = status.ride_status({"NQRW": feed}, "NQRW|000100_N..S|R03")
        self.assertEqual(ride["stopsLeft"], 0)
        self.assertEqual(ride["nextStopId"], "R03")
        vehicle.current_status = 2
        self.assertEqual(status.ride_status({"NQRW": feed}, "NQRW|000100_N..S|R03")["stopsLeft"], 1)

    def test_outages_are_capped_and_typed(self):
        equipment = [{"equipmentno": "E%d" % i, "stationcomplexid": "611"} for i in range(250)]
        equipment.append({"equipmentno": ["not", "a", "string"], "stationcomplexid": "611"})
        outages = [{"equipment": "E%d" % i, "equipmenttype": "EL", "serving": ["x"] * 1000, "reason": "Repairs", "ADA": "Y"} for i in range(250)]

        def fake_cached(url, name, max_age):
            return json.dumps(equipment if "equipments" in url else outages).encode()

        with mock.patch.object(mta_feed, "cached_bytes", side_effect=fake_cached):
            result = status.fetch_outages("611")
        self.assertEqual(len(result), status.MAX_OUTAGES)
        self.assertTrue(all(o["serving"] == "" for o in result))


class Limits(Reset):
    def test_too_many_records_is_refused(self):
        with self.assertRaises(mta_feed.FeedRejected):
            mta_feed.load_json_list(json.dumps([{}] * (mta_feed.RECORD_LIMITS["ene-outages"] + 1)), "ene-outages")

    def test_alert_naming_too_many_routes_is_left_out(self):
        feed = mta_feed.check_feed(alerts_feed("Delays", ["1"] * (mta_feed.MAX_INFORMED_ENTITIES + 1)), "subway-alerts")
        self.assertEqual(len(feed.entity), 0)

    def test_too_many_alerts_is_refused(self):
        feed = alerts_feed("Delays", ["1"])
        for _ in range(mta_feed.ENTITY_LIMITS["subway-alerts"]):
            feed.entity.add().CopyFrom(feed.entity[0])
        with self.assertRaises(mta_feed.FeedRejected):
            mta_feed.check_feed(feed, "subway-alerts")

    def test_largest_allowed_status_reply_fits_the_output_cap(self):
        now = int(time.time())
        trips = gtfs.FeedMessage()
        trips.header.gtfs_realtime_version = "1.0"
        trips.header.timestamp = now
        stations = ["127"] + sorted(mta_feed._load_station_ids() - {"127"}, key=lambda s: (-len(s), s))
        for n in range(status.MAX_ROWS):
            entity = trips.entity.add()
            entity.id = str(n)
            entity.trip_update.trip.trip_id = ("T%d_" % n).ljust(34, "X")
            entity.trip_update.trip.route_id = "FX"
            for i in range(mta_feed.MAX_STOP_UPDATES):
                update = entity.trip_update.stop_time_update.add()
                update.stop_id = stations[i] + "N"
                update.arrival.time = now + 600 + i * 60
        alert_feed = gtfs.FeedMessage()
        alert_feed.header.gtfs_realtime_version = "2.0"
        alert_feed.header.timestamp = now
        wide = "😀"
        for n in range(40):
            entity = alert_feed.entity.add()
            entity.id = "a%d" % n
            entity.alert.header_text.translation.add(text=("A%d " % n).ljust(mta_feed.MAX_TEXT, wide), language="en")
            for route in ("1", "2", "3", "4", "5", "6", "7", "A") if n >= 30 else ("1",):
                entity.alert.informed_entity.add(route_id=route)
            add_mercury(entity.alert, ("Planned - Work" if n % 2 else "Delays").ljust(mta_feed.MAX_TYPE_TEXT, wide),
                        wide * mta_feed.MAX_PERIOD_TEXT)
        equipment = [{"equipmentno": "E%d" % i, "stationcomplexid": "611"} for i in range(100)]
        outages = [{"equipment": "E%d" % i, "equipmenttype": "EL", "serving": wide * mta_feed.MAX_SERVING_TEXT,
                    "reason": wide * mta_feed.MAX_OUTAGE_NOTE_TEXT, "estimatedreturntoservice": wide * mta_feed.MAX_OUTAGE_NOTE_TEXT,
                    "ADA": "Y"} for i in range(100)]

        def fake_cached(url, name, max_age):
            if url == mta_feed.ALERTS_URL:
                return alert_feed.SerializeToString()
            return json.dumps(equipment if "equipments" in url else outages).encode()

        parsed = mta_feed.parse_feed(trips.SerializeToString(), "1234567S")
        with mock.patch.object(mta_feed, "fetch_feeds", return_value={"1234567S": parsed}), \
                mock.patch.object(mta_feed, "cached_bytes", side_effect=fake_cached), \
                mock.patch.object(status.mta_schedule, "ensure_index", return_value=None):
            out = run_main(status, ["1234567S", "127", "both", "", "1", "611", ""])
        reply = json.loads(out)
        self.assertNotIn("error", reply)
        self.assertEqual(len(reply["arrivals"]), status.MAX_ROWS)
        self.assertEqual(len(reply["alerts"]), status.MAX_ALERTS + status.MAX_PLANNED)
        self.assertEqual(len(reply["generalAlerts"]), status.MAX_ALERTS)
        self.assertEqual(len(reply["outages"]), status.MAX_OUTAGES)
        self.assertFalse([a for a in reply["anomalies"] if "left out" in a])
        self.assertLessEqual(len(out.encode()), mta_feed.MAX_OUTPUT_BYTES)


class LargestLinesReply(Reset):
    def lines_reply(self, char):
        feed = gtfs.FeedMessage()
        feed.header.gtfs_realtime_version = "2.0"
        feed.header.timestamp = int(time.time())
        for n in range(6):
            entity = feed.entity.add()
            entity.id = "a%d" % n
            entity.alert.header_text.translation.add(text=("A%d " % n) + char * mta_feed.MAX_TEXT, language="en")
            for route, _feed, _label in lines.LINES:
                entity.alert.informed_entity.add(route_id=route)
        empty = trip_feed(entities=0)
        with mock.patch.object(mta_feed, "fetch_feeds", return_value={g: empty for g in mta_feed.FEED_PATHS}), \
                mock.patch.object(mta_feed, "cached_bytes", return_value=feed.SerializeToString()):
            return run_main(lines, [])

    def test_largest_plain_text_lines_reply_fits_the_output_cap(self):
        out = self.lines_reply("w")
        reply = json.loads(out)
        self.assertNotIn("error", reply)
        self.assertTrue(all(len(line["alerts"]) == 6 for line in reply["lines"]))
        self.assertLessEqual(len(out), mta_feed.MAX_OUTPUT_BYTES)

    def test_largest_accented_lines_reply_fits_the_output_cap(self):
        out = self.lines_reply("é")
        reply = json.loads(out)
        self.assertTrue(all(len(line["alerts"]) == 6 for line in reply["lines"]))
        self.assertLessEqual(len(out.encode()), mta_feed.MAX_OUTPUT_BYTES)

    def test_lines_reply_too_large_for_the_cap_keeps_every_line(self):
        out = self.lines_reply("😀")
        reply = json.loads(out)
        self.assertEqual(len(reply["lines"]), len(lines.LINES))
        self.assertTrue(all(len(line["alerts"]) == 2 for line in reply["lines"]))
        self.assertLessEqual(len(out.encode()), mta_feed.MAX_OUTPUT_BYTES)


class BuildBackoff(Reset):
    def setUp(self):
        super().setUp()
        self.root = tempfile.mkdtemp()
        self.addCleanup(lambda: os.system("rm -rf '%s'" % self.root))
        patch = mock.patch.object(status.mta_schedule, "CACHE_DIR", os.path.join(self.root, "omtarchy"))
        patch.start()
        self.addCleanup(patch.stop)
        status.mta_schedule.cache_dir()
        self.schedule = status.mta_schedule

    def age_marker(self, seconds):
        then = time.time() - seconds
        os.utime(self.schedule.failure_path(), (then, then))

    def test_failed_build_backs_off_and_spawns_nothing(self):
        with mock.patch.object(self.schedule, "build", side_effect=mta_feed.FeedRejected("too big")):
            with self.assertRaises(mta_feed.FeedRejected):
                self.schedule.run_build({"127"})
        self.assertEqual(self.schedule.build_failures(), 1)
        self.assertTrue(self.schedule.build_backed_off())
        with mock.patch.object(self.schedule.subprocess, "Popen") as popen:
            self.assertIsNone(self.schedule.ensure_index({"127"}))
        popen.assert_not_called()

    def test_killed_build_still_counts_as_a_failure(self):
        with mock.patch.object(self.schedule, "build", side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                self.schedule.run_build({"127"})
        self.assertEqual(self.schedule.build_failures(), 1)

    def test_wait_doubles_and_is_capped_at_a_day(self):
        mta_feed.write_private(self.schedule.failure_path(), b"1")
        self.age_marker(3700)
        self.assertFalse(self.schedule.build_backed_off())
        mta_feed.write_private(self.schedule.failure_path(), b"2")
        self.age_marker(3700)
        self.assertTrue(self.schedule.build_backed_off())
        mta_feed.write_private(self.schedule.failure_path(), b"50")
        self.age_marker(86400 + 60)
        self.assertFalse(self.schedule.build_backed_off())

    def test_retry_spawns_after_the_wait(self):
        mta_feed.write_private(self.schedule.failure_path(), b"1")
        self.age_marker(3700)
        with mock.patch.object(self.schedule.subprocess, "Popen") as popen:
            self.schedule.ensure_index({"127"})
        popen.assert_called_once()

    def test_success_clears_the_failures(self):
        mta_feed.write_private(self.schedule.failure_path(), b"3")
        with mock.patch.object(self.schedule, "build"):
            self.schedule.run_build({"127"})
        self.assertEqual(self.schedule.build_failures(), 0)
        self.assertFalse(self.schedule.build_backed_off())


class Fetch(Reset):
    def download(self, response):
        with mock.patch.object(mta_feed._opener, "open", return_value=response):
            return mta_feed.fetch_bytes(mta_feed.ALERTS_URL)

    def test_gzip_expanding_past_the_limit_is_refused(self):
        expanding = gzip.compress(b"\0" * (mta_feed.BYTE_LIMITS[mta_feed.ALERTS_URL] + 1024))
        with self.assertRaises(mta_feed.FeedRejected):
            self.download(FakeResponse(expanding))

    def test_trailing_gzip_data_is_refused(self):
        with self.assertRaises(mta_feed.FeedRejected):
            self.download(FakeResponse(gzip.compress(b"ok") + gzip.compress(b"more")))

    def test_stacked_encoding_is_refused(self):
        with self.assertRaises(mta_feed.FeedRejected):
            self.download(FakeResponse(b"", encoding="gzip, gzip"))

    def test_declared_length_over_limit_is_refused(self):
        with self.assertRaises(mta_feed.FeedRejected):
            self.download(FakeResponse(b"", length=mta_feed.BYTE_LIMITS[mta_feed.ALERTS_URL] + 1))

    def test_redirect_is_refused_before_its_body_is_read(self):
        class Unreadable:
            def read(self, *a):
                raise AssertionError("redirect body was read")

            def close(self):
                pass

        handler = mta_feed._NoRedirects()
        request = urllib.request.Request(mta_feed.ALERTS_URL)
        headers = http.client.HTTPMessage()
        headers["Location"] = "https://api-endpoint.mta.info/other"
        with self.assertRaises(mta_feed.FeedRejected):
            handler.http_error_302(request, Unreadable(), 302, "Found", headers)

    def test_off_site_url_is_refused(self):
        with self.assertRaises(mta_feed.FeedRejected):
            mta_feed.check_url("http://api-endpoint.mta.info/x")
        with self.assertRaises(mta_feed.FeedRejected):
            mta_feed.check_url("https://example.com/x")


class Input(Reset):
    def read(self, raw):
        with mock.patch.object(sys, "stdin", io.TextIOWrapper(io.BytesIO(raw))):
            return mta_feed.read_args()

    def test_oversized_input_is_refused(self):
        with self.assertRaises(ValueError):
            self.read(b"[" + b'"a",' * 40000 + b'"a"]\n')

    def test_non_list_input_is_refused(self):
        with self.assertRaises(ValueError):
            self.read(b'{"a": 1}\n')

    def test_non_string_items_are_refused(self):
        with self.assertRaises(ValueError):
            self.read(b'["a", 1]\n')

    def test_list_of_strings_is_read(self):
        self.assertEqual(self.read(b'["1234567S", "127"]\n'), ["1234567S", "127"])


class Cache(Reset):
    def setUp(self):
        super().setUp()
        self.root = tempfile.mkdtemp()
        self.addCleanup(lambda: os.system("rm -rf '%s'" % self.root))

    def test_new_directory_is_private(self):
        path = mta_feed.private_dir(os.path.join(self.root, "c"))
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o700)

    def test_open_directory_is_repaired(self):
        path = os.path.join(self.root, "c")
        os.mkdir(path, 0o755)
        os.chmod(path, 0o755)
        mta_feed.private_dir(path)
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o700)

    def test_open_files_inside_are_repaired(self):
        path = os.path.join(self.root, "c")
        os.mkdir(path, 0o700)
        old = os.path.join(path, "gtfs_subway.zip")
        open(old, "w").close()
        os.chmod(old, 0o644)
        mta_feed.private_dir(path)
        self.assertEqual(stat.S_IMODE(os.stat(old).st_mode), 0o600)

    def test_symlink_is_refused(self):
        target = os.path.join(self.root, "target")
        os.mkdir(target)
        link = os.path.join(self.root, "link")
        os.symlink(target, link)
        self.assertIsNone(mta_feed.private_dir(link))

    def test_file_in_place_is_refused(self):
        path = os.path.join(self.root, "c")
        open(path, "w").close()
        self.assertIsNone(mta_feed.private_dir(path))

    def test_written_files_are_private_and_not_followed(self):
        directory = mta_feed.private_dir(os.path.join(self.root, "c"))
        path = os.path.join(directory, "feed")
        mta_feed.write_private(path, b"data")
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        target = os.path.join(self.root, "target")
        open(target, "w").close()
        os.symlink(target, path + ".%d" % os.getpid())
        mta_feed.write_private(path, b"again")
        self.assertEqual(os.path.getsize(target), 0)

    def test_oversized_cache_copy_is_ignored(self):
        with mock.patch.dict(os.environ, {"XDG_RUNTIME_DIR": self.root}):
            directory = mta_feed.cache_dir()
            with open(os.path.join(directory, "x"), "wb") as f:
                f.truncate(mta_feed.BYTE_LIMITS[mta_feed.ALERTS_URL] + 1)
            with mock.patch.object(mta_feed, "fetch_bytes", return_value=b"fresh") as fetch:
                self.assertEqual(mta_feed.cached_bytes(mta_feed.ALERTS_URL, "x", 3600), b"fresh")
            fetch.assert_called_once()


if __name__ == "__main__":
    unittest.main()
