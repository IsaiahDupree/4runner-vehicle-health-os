# SAE J1979, synchronized Toyota validation, and private evidence outbox

Date: 2026-08-18

## Delivered state

| Workstream | Implemented | Current authority boundary |
| --- | --- | --- |
| Supported-PID enumeration | Per-ECU Mode 01 `00/20/40/...` bitmap decoder in Python, iOS, and Android | A chain is complete only when every advertised continuation bitmap has been observed from the same ECU |
| Standard OBD values | Pinned read-only definitions for PIDs `04`–`11` and `1F`; iPhone and Android populate values automatically from valid evidence | A value remains unavailable until its ECU's complete bitmap chain proves support |
| ESP32 acquisition | Dev30 passively recognizes single-frame positive Mode 01 responses and preserves ECU, capture session, source sequence, and monotonic time | TWAI remains listen-only; active queries are not executed |
| Toyota correlation | iPhone records Techstream values on the gateway monotonic timeline; CLI ranks raw fields for `0x2C4`, `0x025`, and `0x2C1` | Results are `VALIDATION_CANDIDATE`, with `promotion_allowed=false` |
| Private AI outbox | iPhone stages checksummed `.vhossync` packages, retries HTTPS uploads, and retains attempt/receipt state; authenticated receiver validates and stores atomically | AI may interpret and propose, but may not activate experiments or emit vehicle frames |

This is an implemented development slice, not a claim that a physical 2005 4Runner has already
completed the new J1979/Techstream matrix. The exact in-vehicle gates are listed below.

## Why supported-PID enumeration comes first

SAE J1979 Mode 01 defines current-powertrain data. Availability requests begin at PID `00` and
continue at `20`, `40`, and later boundaries only when the prior bitmap advertises the continuation
PID. CARB material explicitly identifies Service/Mode 01 PID `00`, `20`, and `40` as supported-PID
bitmaps. The implementation therefore does not infer “unsupported” from a missing sample and does
not substitute numeric zero for unavailable evidence.

The decoder groups bitmap evidence by ECU response address. A response from `0x7E8` cannot complete
the chain for `0x7E9`. Standard value decoding is allowed only when:

1. the record is a positive Mode 01 response (`0x41`);
2. the response PID echoes the request PID;
3. the same ECU has a complete availability chain;
4. that chain marks the value PID as supported;
5. the response has enough data bytes for the pinned definition.

The authoritative standard remains the applicable licensed SAE J1979 revision. The checked-in
definition registry is an attributed, pinned implementation reference from OBDb/SAEJ1979 revision
`d3259214a9e0340c4a6cff9ec5f8ff5953eee6f2`, licensed CC-BY-SA-4.0. Its provenance is serialized
with every Python-decoded sample; it is not presented as SAE's licensed text.

Primary references:

- [SAE J1979_201009 — E/E Diagnostic Test Modes](https://saemobilus.sae.org/standards/j1979_201009-e-e-diagnostic-test-modes)
- [CARB OBD II Attachment B](https://ww2.arb.ca.gov/sites/default/files/barcu/regact/obdii06/obdattachb.pdf)
- [Pinned OBDb SAEJ1979 source](https://github.com/OBDb/SAEJ1979/tree/d3259214a9e0340c4a6cff9ec5f8ff5953eee6f2)

## Acquisition architecture

```text
Techstream / approved OBD reader issues Mode 01 query
                      |
                      v
vehicle CAN response 0x7E8..0x7EF
                      |
        +-------------+----------------+
        |                              |
        v                              v
passive CAN flight recorder       dev30 J1979 observer
(durable raw evidence)            (bounded nonblocking queue)
                                       |
                                       v
                            VHOS message type 3 + CRC32C
                                       |
                             +---------+---------+
                             |                   |
                             v                   v
                         iPhone             Android head unit
                    raw frame persisted   raw frame persisted
                    before decoding       before decoding
                             |                   |
                             +---------+---------+
                                       v
                           per-ECU supported-PID state
                                       |
                                       v
                         pinned standard value projection
```

Firmware dev30 accepts only standard 11-bit ISO-TP single-frame responses on `0x7E8`–`0x7EF` whose
application payload begins with `0x41`. It does not discard the original CAN observation. It sends
a separate fixed 36-byte diagnostic evidence record containing the original source sequence,
gateway monotonic microseconds, capture session, transport, ECU address, and response bytes.

The observer cannot stall the CAN receive/capture task. A depth-16 queue records saturation as a
gateway fault counter/log; BLE serialization happens on a separate worker.

## Active request safety boundary

Dev30 contains a pure planner for one fixed functional request:

```text
ID 0x7DF: 02 01 <00|20|40|60|80|A0|C0|E0> 00 00 00 00 00
```

The planner requires a verified signed plan, deterministic `PARKED`, idle capture, and confirmed
protocol. It does not transmit. The production firmware has no caller capable of satisfying that
context, no arbitrary request API, and no CAN transmit executor; TWAI remains
`TWAI_MODE_LISTEN_ONLY`.

Consequently, the current automatic population path operates when an approved external client such
as Techstream is producing the requests. Originating the same queries from VHOS is a later safety
milestone, not a hidden side effect of this build.

## Offline J1979 decoder

Each NDJSON input line must validate as `obd.j1979-response` v1. One run is constrained to one
gateway/capture identity.

```bash
.venv/bin/vhos decode-j1979 path/to/j1979-responses.ndjson \
  --supported-output build/j1979-supported.json \
  --samples-output build/j1979-standard-samples.ndjson
```

Outputs:

- `obd.j1979-supported-pids`: exact per-ECU/transport bitmaps, queried bases, supported PIDs,
  completeness, and the raw response evidence used;
- `obd.j1979-standard-sample`: raw bytes, decoded value/unit, gateway/capture identity, monotonic
  time, original CAN source sequence, quality, support proof, and pinned definition provenance.

The mobile accumulators reset their availability and decoded-value state whenever gateway,
capture, or transport identity changes. A later capture therefore cannot inherit PID support from
an earlier one. The terminal `0xE0` bitmap is bounded at PID `0xFF`; a set bit beyond that boundary
is ignored rather than wrapped.

## One synchronized Techstream/OBD validation run

Toyota Techstream is the official Toyota/Lexus/Scion scantool environment and exposes vehicle Data
Lists. The project uses it as an independent reference source, not as permission to copy a mapping
from another Toyota model.

Primary Toyota references:

- [Toyota Techstream scantool information](https://techinfo.toyota.com/techInfoPortal/appmanager/t3/ti?_nfpb=true&_pageLabel=ti_vehicle_reprog)
- [Toyota Technical Information System](https://www.techinfo.toyota.com/techInfoPortal/appmanager/t3/ti?_nfpb=true&_pageLabel=ti_whats_tis)
- [Toyota Techstream known behavior, including Data List CSV](https://techinfo.toyota.com/techInfoPortal/staticcontent/en/techinfo/html/prelogin/tsrss/ts_known_bugs.html)

The iPhone Evidence screen now provides three presets:

| Independent reference | Candidate CAN family to test | Stored signal ID |
| --- | --- | --- |
| Engine speed | `0x2C4` | `reference.engine.speed` |
| Steering angle | `0x025` | `reference.steering.angle` |
| Accelerator position | `0x2C1` | `reference.accelerator.position` |

Procedure:

1. Start passive capture and verify the gateway remains listen-only.
2. Open the corresponding Techstream Data List.
3. Keep the vehicle stationary for the idle/steering/pedal segments required by the approved plan.
4. Vary one input at a time.
5. At each stable point, enter the displayed Techstream value and tap **Record at current gateway
   CAN time**. The app binds it to the latest CAN observation's monotonic time and source sequence.
6. Capture at least five varied samples for each reference; more points across the usable range are
   preferred.
7. Export `synchronized-reference-samples.csv` and the matching passive CAN NDJSON.
8. Run:

```bash
.venv/bin/vhos correlate-can-reference \
  --can path/to/passive-can.ndjson \
  --reference path/to/synchronized-reference-samples.csv \
  --output build/can-reference-candidates.json
```

The analyzer evaluates each byte plus overlapping big- and little-endian 16-bit words, pairs each
reference to the nearest CAN sample inside a bounded time window, and reports sample count,
maximum time delta, Pearson correlation, linear scale/offset, and RMSE. It hashes every input.

A high correlation is useful discovery evidence, but cannot by itself establish semantics,
signedness, scale, applicability, or causation. Promotion requires repeatability, controlled
variation, independent comparison, and a reviewed Vehicle Signal Pack change.

## Private evidence outbox

### iPhone behavior

The app stores each package under Application Support before making a network request. The record
contains a UUID, content type, byte count, SHA-256, creation time, bounded attempt history, and the
authority contract. Exact payload hashes deduplicate. A completed capture-log synchronization
automatically queues the current checksummed `.vhossync` bundle; a five-second worker uploads up to
eight pending packages per cycle when automatic upload is enabled.

Successful upload first commits a checksummed identity-and-payload acknowledgement to a
full-synchronous SQLite catalog and only then removes the live package. The acknowledgement retains
deduplication identity without retaining the multi-megabyte payload, so uploaded packages do not
consume the 512-pending-package limit forever. Startup finishes either crash window: an old live
package with no acknowledgement remains pending, while an acknowledged live package left behind by
a crash is safely pruned. This makes the capacity a bound on undelivered work rather than a lifetime
upload ceiling.

Planner deduplication trusts only a validated live payload or a catalogued upload acknowledgement.
Missing, malformed, hash-mismatched, or directory-mismatched package metadata/payload is moved to a
bounded quarantine and the immutable source is eligible for regeneration on the next cycle.
Interrupted hidden staging directories are scavenged at startup. Import provenance receipts use a
16 MiB payload ceiling so the complete 20,000-record receipt remains queueable alongside its
independently bounded 18 MiB source archive.

The content-type allowlist is semantic rather than a generic JSON escape hatch. It admits
checksummed evidence-sync ZIPs, agent-evidence JSON,
`application/vnd.vhos.discovery-draft-evidence+json`, and the dedicated
`application/vnd.vhos.import-provenance-receipt+json` lineage artifact. The shared envelope schema
validates the Discovery content type at both sender and receiver. Its versioned payload contract
keeps the same explicit authority boundary: interpretation and experiment proposals are allowed;
vehicle activation and frame emission are denied. Every outbox timestamp uses the shared
fail-closed RFC 3339 validator, including rejection of leap-second spellings.

Discovery evidence is not collapsed into one lifetime-sized JSON document. Capture bindings,
append-only test-run snapshots, and markers are each partitioned into immutable 500-primary-record
segments. Every segment declares its kind, ordinal, total segment count, primary-record offset and
count, total ledger count, and SHA-256 over the exact canonical primary-record NDJSON. Marker
segments also carry the capture/run lineage needed to interpret those markers; repeated lineage is
context, not a second primary record. Artifact identity includes the segment cursor and final
payload SHA-256, so an unchanged ledger page deduplicates across automatic cycles while a later
append produces a new immutable cursor or revision. Automatic handoff queues at most two missing
segments per cycle and manual sharing prepares at most eight. The UI clearly reports when more
segments remain, and every record allowed by the bounded ledgers is eventually exportable without
constructing a monolithic payload.

The endpoint is saved in app preferences. The bearer token is stored in Keychain. The app accepts
only HTTPS, refuses HTTP redirects so a bearer token cannot be forwarded to another origin, and
revalidates payload SHA-256 immediately before upload. A failed upload stays queued and records the
error; it is never marked delivered optimistically.

### Receiver behavior

The repository includes a real authenticated receiver and append-only filesystem inbox. Package
creation is serialized inside the threaded server, so concurrent retries of the same package ID
produce exactly one insertion and idempotent receipts:

```bash
export VHOS_EVIDENCE_TOKEN='<at-least-32-random-characters>'
.venv/bin/vhos evidence-inbox serve \
  --root /private/path/vhos-evidence-inbox \
  --bind 127.0.0.1 \
  --port 8787
```

Loopback HTTP is permitted for local development. A receiver reachable by the iPhone must use TLS:

```bash
.venv/bin/vhos evidence-inbox serve \
  --root /private/path/vhos-evidence-inbox \
  --bind 0.0.0.0 \
  --port 8787 \
  --tls-certificate /private/path/fullchain.pem \
  --tls-private-key /private/path/privkey.pem
```

Configure the iPhone endpoint as:

```text
https://private-host.example/v1/evidence/packages
```

The server rejects an invalid token, schema, UUID, byte count, content type, SHA-256, oversized
body, or same-ID/different-content retry. It stages metadata and evidence in a private temporary
directory, then atomically renames that directory into the inbox. Same-ID/same-hash retries are
idempotent.

An evidence-analysis agent can poll and atomically claim work:

```bash
.venv/bin/vhos evidence-inbox list \
  --root /private/path/vhos-evidence-inbox \
  --pending-only

.venv/bin/vhos evidence-inbox claim \
  --root /private/path/vhos-evidence-inbox \
  --package-id <uuid> \
  --agent-id vehicle-analysis-agent/v1
```

The claim records that the agent may interpret evidence and propose an experiment. It may not
activate an experiment or emit vehicle frames. This receiver is implemented but not automatically
deployed to a public host by this change; production needs an owner-controlled private HTTPS
endpoint, secret provisioning, retention policy, and backup policy.

## Versioned contracts and files

- `contracts/jsonschema/v1/j1979-response.schema.json`
- `contracts/jsonschema/v1/j1979-supported-pids.schema.json`
- `contracts/jsonschema/v1/j1979-standard-sample.schema.json`
- `contracts/jsonschema/v1/can-reference-correlation-report.schema.json`
- `contracts/jsonschema/v1/evidence-outbox-envelope.schema.json`
- `vehicle-signal-packs/standards/j1979-mode01-obdb-d3259214.v1.json`
- `tooling/src/vhos/j1979.py`
- `tooling/src/vhos/reference_correlation.py`
- `tooling/src/vhos/evidence_inbox.py`

## Acceptance evidence completed

- JSON Schema catalog: 19 schemas valid.
- Python: 34 tests passed, including corruption, identity, terminal-bitmap bounds, provenance,
  correlation, authenticated and concurrent-idempotent inbox handling, claim, replay, and existing
  safety cases.
- Swift core: 42 tests passed, including wire decoding, capture-bound supported-PID gating,
  synchronized CSV, terminal-bitmap bounds, and outbox payload-substitution rejection.
- iOS simulator and signed generic iPhone builds: passed.
- Android protocol/transport/app targeted compilation and tests: passed; full repository gate is
  recorded with the Android commit.
- ESP-IDF 5.5.3 dev30 build: passed; physical vehicle response capture remains pending.

## Remaining physical and deployment gates

- run the synchronized 0x2C4/0x025/0x2C1 Techstream capture in the actual 2005 4Runner;
- observe and decode a complete supported-PID chain from every responding ECU;
- verify iPhone and Android render identical standard values from identical raw evidence;
- deploy the private TLS inbox, configure the iPhone token, and prove queue → upload → claim with a
  real `.vhossync` package;
- validate retention/redaction policy before uploading owner location or VIN-bearing evidence;
- separately approve any firmware transition from passive listen-only to allowlisted requests.
