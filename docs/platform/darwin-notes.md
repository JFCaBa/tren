# Darwin (Live Departure Board) — notes for Platform

Recorded 16-11-2026 (Task 0). Moves to the `platform` repo in Task 1.

## Licence (read with the user in RDM, 16-11-2026) — gate PASSED

Product: **Live Departure Board** v1.1, Rail Delivery Group
(`P-d81d6eaf-8060-4467-a339-1c833e50cbbe`). Not the "Staff Version" (CRS codes only).
Subscribed by the user as an individual; active until 16-11-2027, auto-renews yearly,
1 week notice to terminate.

| Term | Value |
|---|---|
| Licence | Open, free, not prepaid |
| Use | "The raw data may be made freely available or otherwise distributed to third parties" |
| Special condition | May not be resold "as is" or substantially unmodified. Commercial use only where the data is materially augmented, integrated with other data sets or enhanced |
| Fair usage limit | No |
| Territory | Global |
| Retention | May retain any data received |
| **Attribution** | **National Rail** |

Platform is free, ad-free, reshapes the data into its own format and combines it with
NaPTAN station locations → allowed. Attribution text shown in the app footer and the
store listings: "Data: National Rail".

## Endpoint

```
GET https://api1.raildata.org.uk/1010-live-departure-board-dep1_2/LDBWS/api/20220120/GetDepartureBoard/{CRS}?numRows=20&timeWindow=120
x-apikey: <consumer key>
```

- Auth: header `x-apikey` = the **Consumer key** (48 chars), not the consumer secret.
  Key lives only in `/opt/platform/.env` (root, 600) as `DARWIN_API_KEY=...`.
- `GetDepartureBoard` (≈11 KB for 20 rows, ~0.15 s from the VPS) has every field we need.
  `GetDepBoardWithDetails` adds calling points (≈43 KB); not used.
- Other params: `filterCrs`, `filterType` (`to`/`from`), `timeOffset`, `timeWindow`.
- Errors seen: unknown CRS (`ZZZ`) → **400**; bad/wrong key → **401**
  `{"fault":{"faultstring":"Invalid ApiKey",...}}`; key for another product → 401
  `InvalidApiKeyForGivenResource`.
- No rate-limit headers in responses; Darwin sends `cache-control: public,no-cache`.

## Response → API contract

| Darwin | Contract | Notes |
|---|---|---|
| `crs` | `crs` | |
| `locationName` | `name` | |
| `generatedAt` | `generatedAt` | e.g. `2026-11-16T14:33:37.6541608+00:00`: 7 fractional digits and an offset. Normalise to `2026-11-16T14:33:37Z` (UTC, seconds) |
| `nrccMessages[].Value` | `nrccMessages[]` | HTML: `&nbsp;`, `<a href=...>text</a>`, `<p>`. Strip, keep links as "text (URL)". Key missing when there are none |
| `trainServices[]` | `services[]` | **Key missing** on an empty board (see `darwin_empty.json`); also `busServices`/`ferryServices` (ignored) |
| `.std` | `std` | `HH:MM` |
| `.etd` | `etd` | Seen: `On time`, `HH:MM`, `Cancelled`, `Delayed` |
| `.platform` | `platform` | **Key missing** when not announced yet (most KGX long-distance rows) → `null` |
| `.destination[].locationName` | `destination` | Can be several (CLJ 14:42 Portsmouth Harbour + Bognor Regis) → join with " & " |
| `.destination[].via` | `via` | e.g. `via Horsham`. Per destination; take unique vias in order, joined with " & " |
| `.operator` | `operator` | e.g. `LNER`, `Great Northern` |
| `.isCancelled` | `cancelled` | |
| `.delayReason` | `delayReason` | Present only when set |
| `.cancelReason` | `cancelReason` | Present only when set |

`platformAvailable` is a board-level flag (true at KGX even with most platforms missing).

## Fixtures (`fixtures/`, no key inside: `grep -ci apikey` = 0)

- `darwin_kgx.json`: King's Cross 14:33 UTC, 20 services, 2 cancelled (with
  `cancelReason`), 1 `Delayed`, delays with `delayReason`, few platforms, 2+ NRCC messages with HTML.
- `darwin_clj.json`: Clapham Junction, platforms on every row, `via`, one service with two destinations.
- `darwin_empty.json`: Berkhamsted with `timeWindow=1`: no `trainServices`, no `nrccMessages`.
