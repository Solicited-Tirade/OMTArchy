# OMTArchy - NYC Subway MTA

An [Omarchy](https://omarchy.org/) bar widget showing live NYC subway arrivals for a station, straight from the MTA's GTFS-realtime feeds — in the bar at a glance, and in a detail popup for the full picture.

*80% hand-coded, 100% human-reviewed.*

![Bar](docs/bar.png)

![Popup](docs/popup.png)

## Features

- **Live arrivals**, both directions, for any subway station or Staten Island Railway stop — no API key needed (MTA's subway realtime feeds have been open since 2019).
- **Whole-station tracking**: pick a multi-line complex (e.g. Grand Central's 4/5/6, 7, and S platforms) and see every line's arrivals on one board, as long as they share a single realtime feed. Pick one specific line's pill instead to narrow to just that line.
- **Search or browse by line** to find a station, with routes grouped by physical MTA service group (1234567S, ACE, BDFM, G, JZ, NQRW, L, SIR) rather than plain alphabetical order.
- **Service alerts** for the station's lines, plus system-wide notices (holiday schedules, etc.) on hover.
- **Trip planner**: direct and one-transfer routes between any two stations, defaulting the origin to whatever station the widget is already tracking.
- **"You are here" context strip**: the two nearest physical stations on each side of the tracked station, so an unfamiliar direction label ("Uptown", "Rockaway Park", ...) has concrete meaning.
- **Per-train detail**: tap an arrival to see that specific train's full remaining stop list with clock times, plus the two stops immediately before it.
- Toggle between a relative countdown ("4m") and an absolute clock time ("4:16 PM") for the whole arrivals list.

## Screenshots

**Whole-station tracking** — pick a multi-line complex and see every platform's arrivals on one board, direction toggle and alert count included.

![Whole-station tracking](docs/Multi-line.png)

**Search or browse by line** — stations grouped by physical MTA service group (1234567S, ACE, BDFM, ...), not plain alphabetical order.

![Browse by line](docs/Search.png)

**Multi-feed complexes are flagged, not guessed** — a station spanning more than one realtime feed calls that out and asks for a specific line, instead of silently tracking just one of them.

![Multi-feed station note](docs/Browse.png)

**Per-train detail** — tap an arrival for that specific train's full remaining stop list, with the two stations immediately before it for context.

![Per-train detail](docs/Routes.png)

**Trip planner** — direct and one-transfer routes between any two stations.

![Trip planner](docs/Trip.png)

## Requirements

- Python 3 with the `protobuf` package (`python-protobuf` on Arch) — used to decode MTA's GTFS-realtime feed.

## Installation

```
omarchy plugin add https://github.com/Solicited-Tirade/OMTArchy.git --enable
```

Then set a station via the widget's settings, or open the popup and use "Change" to search by name or browse by line.

To remove it later:

```
omarchy plugin remove tirade.nyc-subway
```

## Configuration

| Setting | Description |
|---|---|
| Line group | Which MTA GTFS-realtime feed to poll. Set automatically by the station picker. |
| Stop ID | GTFS stop_id for the station (or a comma-separated list, for a whole-complex pick). Set automatically by the station picker; a manual fallback for typing one by hand. |
| Direction | `both` shows an Uptown/Downtown toggle; `N` or `S` locks the popup to just that direction. |
| Routes (optional) | Comma-separated route IDs to fetch (e.g. `1,2,3`). Blank fetches every route serving the stop. |
| Arrivals shown | How many upcoming trains to list per direction/route (1-10). |
| Refresh interval | How often to poll, in milliseconds (MTA feeds update roughly every 30s). |
| Bar label override | Short name shown in the bar; defaults to the stop ID. |

## Data sources

- Live arrivals and service alerts: [MTA GTFS-realtime subway feeds](https://api.mta.info/) (no API key required).
- Station list, physical line groupings, and neighboring-station data: the [MTA Subway Stations](https://data.ny.gov/Transportation/MTA-Subway-Stations-and-Complexes/5f5g-n3cz) public dataset and MTA's static GTFS feed.

## License

MIT — see [LICENSE](LICENSE).
