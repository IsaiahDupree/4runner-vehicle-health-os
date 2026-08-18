from __future__ import annotations

import hashlib
import json
import os
import shutil
import struct
import time
import uuid
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable, Iterator, Sequence

from .can_discovery import PassiveCANRecord, load_passive_can_ndjson
from .contracts import ContractCatalog


CORPUS_CONTRACT = "can.replay.corpus"
CORPUS_VERSION = "1.0.0"
SOURCE_CLASSIFICATION = "REAL_CAPTURE_REPLAY"
REQUIRED_DISPLAY_LABEL = "HISTORICAL REPLAY • NOT LIVE"
VHOS_MAGIC = b"VHOS"
VHOS_HEADER_BYTES = 36
LIVE_CAN_MESSAGE_TYPE = 2
CAPTURE_LOG_CHUNK_MESSAGE_TYPE = 13
MAXIMUM_PAYLOAD_BYTES = 1_048_576
KNOWN_MESSAGE_TYPES = set(range(1, 14))


class CANReplayError(ValueError):
    """Raised when a real-capture corpus or replay violates its evidence contract."""


@dataclass(frozen=True)
class ValidatedCANReplayCorpus:
    root: Path
    manifest: dict[str, Any]
    records: tuple[PassiveCANRecord, ...]


@dataclass(frozen=True)
class DecodedGatewayFrame:
    message_type: int
    sequence: int
    monotonic_microseconds: int
    payload: bytes


class GatewayFrameStreamDecoder:
    """Incremental VHOS decoder that can recover at the next CRC-valid frame header."""

    def __init__(self, maximum_payload_bytes: int = MAXIMUM_PAYLOAD_BYTES) -> None:
        self.maximum_payload_bytes = maximum_payload_bytes
        self.buffer = bytearray()
        self.discarded_bytes = 0
        self.recoveries = 0
        self.corrupt_candidates = 0
        self.maximum_buffer_bytes = 0

    def append(self, chunk: bytes) -> list[DecodedGatewayFrame]:
        self.buffer.extend(chunk)
        self.maximum_buffer_bytes = max(self.maximum_buffer_bytes, len(self.buffer))
        frames: list[DecodedGatewayFrame] = []
        while True:
            if not self._align_to_magic():
                break
            if len(self.buffer) < VHOS_HEADER_BYTES:
                break
            payload_length = struct.unpack_from("<I", self.buffer, 8)[0]
            if not self._header_is_valid(0, payload_length):
                self.corrupt_candidates += 1
                self._discard_prefix(1)
                continue
            frame_length = VHOS_HEADER_BYTES + payload_length
            if len(self.buffer) < frame_length:
                next_header = self._next_valid_header_offset(len(VHOS_MAGIC))
                if next_header is not None:
                    self.corrupt_candidates += 1
                    self._discard_prefix(next_header)
                    continue
                next_magic = self.buffer.find(VHOS_MAGIC, len(VHOS_MAGIC))
                if next_magic >= 0:
                    self.corrupt_candidates += 1
                    self._discard_prefix(next_magic)
                break
            candidate = bytes(self.buffer[:frame_length])
            expected_payload_crc = struct.unpack_from("<I", candidate, 28)[0]
            payload = candidate[VHOS_HEADER_BYTES:]
            if expected_payload_crc != crc32c(payload):
                self.corrupt_candidates += 1
                next_header = self._next_valid_header_offset(1)
                if next_header is not None:
                    self._discard_prefix(next_header)
                else:
                    next_magic = self.buffer.find(VHOS_MAGIC, 1)
                    if next_magic >= 0:
                        self._discard_prefix(next_magic)
                    else:
                        self._discard_unframed_preserving_magic_prefix()
                    break
                continue
            frames.append(
                DecodedGatewayFrame(
                    message_type=candidate[6],
                    sequence=struct.unpack_from("<Q", candidate, 12)[0],
                    monotonic_microseconds=struct.unpack_from("<Q", candidate, 20)[0],
                    payload=payload,
                )
            )
            del self.buffer[:frame_length]
        return frames

    def reset_buffer(self) -> None:
        """Model a physical disconnect without erasing accumulated quality counters."""
        if self.buffer:
            self.discarded_bytes += len(self.buffer)
            self.recoveries += 1
            self.buffer.clear()

    def _align_to_magic(self) -> bool:
        if not self.buffer:
            return False
        if self.buffer.startswith(VHOS_MAGIC):
            return True
        next_magic = self.buffer.find(VHOS_MAGIC, 1)
        if next_magic >= 0:
            self._discard_prefix(next_magic)
            return True
        self._discard_unframed_preserving_magic_prefix()
        return False

    def _header_is_valid(self, offset: int, payload_length: int | None = None) -> bool:
        if len(self.buffer) - offset < VHOS_HEADER_BYTES:
            return False
        if self.buffer[offset : offset + 4] != VHOS_MAGIC:
            return False
        if self.buffer[offset + 4] != 1 or self.buffer[offset + 6] not in KNOWN_MESSAGE_TYPES:
            return False
        length = payload_length
        if length is None:
            length = struct.unpack_from("<I", self.buffer, offset + 8)[0]
        if length > self.maximum_payload_bytes:
            return False
        expected = struct.unpack_from("<I", self.buffer, offset + 32)[0]
        actual = crc32c(bytes(self.buffer[offset : offset + 32]))
        return expected == actual

    def _next_valid_header_offset(self, start: int) -> int | None:
        candidate = self.buffer.find(VHOS_MAGIC, start)
        while candidate >= 0:
            if len(self.buffer) - candidate < VHOS_HEADER_BYTES:
                return None
            if self._header_is_valid(candidate):
                return candidate
            candidate = self.buffer.find(VHOS_MAGIC, candidate + 1)
        return None

    def _discard_prefix(self, count: int) -> None:
        bounded = min(max(count, 0), len(self.buffer))
        if bounded == 0:
            return
        del self.buffer[:bounded]
        self.discarded_bytes += bounded
        self.recoveries += 1

    def _discard_unframed_preserving_magic_prefix(self) -> None:
        suffix = 0
        for count in range(min(len(VHOS_MAGIC) - 1, len(self.buffer)), 0, -1):
            if bytes(self.buffer[-count:]) == VHOS_MAGIC[:count]:
                suffix = count
                break
        self._discard_prefix(len(self.buffer) - suffix)


def build_can_replay_corpus(
    inputs: Iterable[Path],
    output: Path,
    *,
    corpus_id: str,
) -> dict[str, Any]:
    """Copy immutable real observations into a self-verifying, non-live replay corpus."""
    files = _resolve_inputs(inputs)
    records, _ = load_passive_can_ndjson(files)
    if output.exists():
        raise CANReplayError(f"Replay corpus output already exists: {output}")
    if not corpus_id or any(character not in "abcdefghijklmnopqrstuvwxyz0123456789._-" for character in corpus_id):
        raise CANReplayError("corpus_id must use lowercase letters, digits, dot, underscore, or hyphen.")

    staging = output.parent / f".{output.name}.staging-{uuid.uuid4().hex}"
    staging_sessions = staging / "sessions"
    staging_sessions.mkdir(parents=True)
    try:
        source_files: list[dict[str, Any]] = []
        seen_session_ids: set[int] = set()
        for source in files:
            raw = source.read_bytes()
            source_records, _ = load_passive_can_ndjson([source])
            session_ids = {record.session_id for record in source_records}
            if len(session_ids) != 1:
                raise CANReplayError(f"{source.name} contains more than one capture session.")
            session_id = next(iter(session_ids))
            if session_id in seen_session_ids:
                raise CANReplayError(f"Capture session {session_id} is split across source files.")
            seen_session_ids.add(session_id)
            destination_name = f"{session_id}.ndjson"
            destination = staging_sessions / destination_name
            destination.write_bytes(raw)
            source_files.append(
                {
                    "path": f"sessions/{destination_name}",
                    "sha256": hashlib.sha256(raw).hexdigest(),
                    "byte_count": len(raw),
                    "record_count": len(source_records),
                    "session_id": session_id,
                }
            )
        source_files.sort(key=lambda item: (item["session_id"], item["path"]))
        ordered_records = _ordered_records(records)
        manifest = {
            "contract": CORPUS_CONTRACT,
            "contract_version": CORPUS_VERSION,
            "corpus_id": corpus_id,
            "source_classification": SOURCE_CLASSIFICATION,
            "vehicle_claims_authorized": False,
            "assembled_from_capture_at": max(record.ingested_at for record in ordered_records),
            "gateway_ids": sorted({record.gateway_id for record in ordered_records}),
            "source_files": source_files,
            "statistics": _statistics(ordered_records, source_files),
            "semantic_digest": _semantic_digest(ordered_records),
            "display_policy": {
                "required_label": REQUIRED_DISPLAY_LABEL,
                "provenance": (
                    "Recorded listen-only gateway evidence replayed offline. Timing, identifiers, "
                    "payloads, session IDs, and source sequences are preserved."
                ),
                "prohibited_claims": [
                    "live vehicle state",
                    "accepted CAN signal meaning",
                    "vehicle health conclusion",
                    "control authority",
                ],
            },
        }
        ContractCatalog.load().validate(manifest)
        (staging / "manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        output.parent.mkdir(parents=True, exist_ok=True)
        os.replace(staging, output)
    except Exception:
        if staging.exists():
            shutil.rmtree(staging)
        raise
    load_validated_can_replay_corpus(output)
    return manifest


def load_validated_can_replay_corpus(root: Path) -> ValidatedCANReplayCorpus:
    root = root.resolve()
    manifest_path = root / "manifest.json"
    if not root.is_dir() or not manifest_path.is_file():
        raise CANReplayError(f"Replay corpus manifest is missing: {manifest_path}")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise CANReplayError("Replay corpus manifest is not valid JSON.") from error
    if not isinstance(manifest, dict):
        raise CANReplayError("Replay corpus manifest must be a JSON object.")
    ContractCatalog.load().validate(manifest)

    source_paths: list[Path] = []
    for source in manifest["source_files"]:
        path = (root / source["path"]).resolve()
        if root not in path.parents or not path.is_file():
            raise CANReplayError(f"Replay source escapes the corpus or is missing: {source['path']}")
        raw = path.read_bytes()
        if len(raw) != source["byte_count"]:
            raise CANReplayError(f"Replay source byte count changed: {source['path']}")
        if hashlib.sha256(raw).hexdigest() != source["sha256"]:
            raise CANReplayError(f"Replay source SHA-256 changed: {source['path']}")
        file_records, _ = load_passive_can_ndjson([path])
        if len(file_records) != source["record_count"]:
            raise CANReplayError(f"Replay source record count changed: {source['path']}")
        if {record.session_id for record in file_records} != {source["session_id"]}:
            raise CANReplayError(f"Replay source session identity changed: {source['path']}")
        source_paths.append(path)

    records, _ = load_passive_can_ndjson(source_paths)
    ordered_records = _ordered_records(records)
    if manifest["statistics"] != _statistics(ordered_records, manifest["source_files"]):
        raise CANReplayError("Replay corpus statistics do not match its immutable sources.")
    if manifest["semantic_digest"] != _semantic_digest(ordered_records):
        raise CANReplayError("Replay corpus semantic digest does not match its observations.")
    if manifest["gateway_ids"] != sorted({record.gateway_id for record in ordered_records}):
        raise CANReplayError("Replay corpus gateway inventory does not match its observations.")
    return ValidatedCANReplayCorpus(root, manifest, tuple(ordered_records))


def replay_can_corpus(
    root: Path,
    *,
    mode: str = "live",
    repeat: int = 1,
    fault: str = "clean",
    fault_interval: int = 257,
    fragment_sizes: Sequence[int] = (1, 3, 20, 244, 5, 509, 64, 17, 1024),
) -> dict[str, Any]:
    """Exercise the real observations through the deployed wire format and stream decoder."""
    corpus = load_validated_can_replay_corpus(root)
    if mode not in {"live", "history"}:
        raise CANReplayError("Replay mode must be 'live' or 'history'.")
    if fault not in {"clean", "drop-fragment", "corrupt-payload", "disconnect-mid-frame"}:
        raise CANReplayError("Unsupported replay fault profile.")
    if not 1 <= repeat <= 10_000:
        raise CANReplayError("Replay repeat must be between 1 and 10,000.")
    if fault_interval < 2:
        raise CANReplayError("fault_interval must be at least 2.")
    if not fragment_sizes or any(size <= 0 for size in fragment_sizes):
        raise CANReplayError("Replay fragment sizes must all be positive.")

    units = list(_wire_units(corpus.records, mode=mode, repeat=repeat))
    decoder = GatewayFrameStreamDecoder()
    decoded_frames: list[DecodedGatewayFrame] = []
    expected_records: list[PassiveCANRecord] = []
    faulted_units = 0
    notification_count = 0
    started = time.perf_counter()

    for unit_index, (wire, records) in enumerate(units, start=1):
        fault_this_unit = fault != "clean" and unit_index % fault_interval == 0 and unit_index < len(units)
        if not fault_this_unit:
            expected_records.extend(records)
            for fragment in _fragments(wire, fragment_sizes):
                notification_count += 1
                decoded_frames.extend(decoder.append(fragment))
            continue

        faulted_units += 1
        if fault == "drop-fragment":
            start = min(VHOS_HEADER_BYTES + 5, len(wire) - 2)
            width = min(97, max(1, len(wire) - start - 1))
            damaged = wire[:start] + wire[start + width :]
            for fragment in _fragments(damaged, fragment_sizes):
                notification_count += 1
                decoded_frames.extend(decoder.append(fragment))
        elif fault == "corrupt-payload":
            damaged = bytearray(wire)
            damaged[min(VHOS_HEADER_BYTES + 4, len(damaged) - 1)] ^= 0x80
            for fragment in _fragments(bytes(damaged), fragment_sizes):
                notification_count += 1
                decoded_frames.extend(decoder.append(fragment))
        else:
            split = min(VHOS_HEADER_BYTES + 5, len(wire) - 1)
            for fragment in _fragments(wire[:split], fragment_sizes):
                notification_count += 1
                decoded_frames.extend(decoder.append(fragment))
            decoder.reset_buffer()
            # The remaining bytes belong to the dead physical link and are intentionally lost.

    decoded_records: list[PassiveCANRecord] = []
    for frame in decoded_frames:
        decoded_records.extend(_decode_wire_observations(frame, corpus.records[0].gateway_id))
    elapsed = max(time.perf_counter() - started, 1e-9)
    expected_semantics = [_record_semantic_tuple(record) for record in expected_records]
    actual_semantics = [_record_semantic_tuple(record) for record in decoded_records]
    exact_match = actual_semantics == expected_semantics
    sequences = [frame.sequence for frame in decoded_frames]
    sequence_gaps = sum(
        max(0, current - prior - 1) for prior, current in zip(sequences, sequences[1:])
    )
    result = {
        "contract": "can.replay.result",
        "contract_version": "1.0.0",
        "corpus_id": corpus.manifest["corpus_id"],
        "source_classification": SOURCE_CLASSIFICATION,
        "required_display_label": REQUIRED_DISPLAY_LABEL,
        "mode": mode,
        "fault": fault,
        "repeat": repeat,
        "input_records": len(corpus.records) * repeat,
        "expected_records_after_faults": len(expected_records),
        "decoded_records": len(decoded_records),
        "expected_missing_records": len(corpus.records) * repeat - len(expected_records),
        "unexpected_record_delta": len(decoded_records) - len(expected_records),
        "wire_frames": len(units),
        "decoded_wire_frames": len(decoded_frames),
        "faulted_wire_frames": faulted_units,
        "notification_fragments": notification_count,
        "decoder_recoveries": decoder.recoveries,
        "decoder_corrupt_candidates": decoder.corrupt_candidates,
        "decoder_discarded_bytes": decoder.discarded_bytes,
        "decoder_buffered_bytes": len(decoder.buffer),
        "decoder_maximum_buffer_bytes": decoder.maximum_buffer_bytes,
        "decoded_outer_sequence_gaps": sequence_gaps,
        "elapsed_seconds": round(elapsed, 6),
        "decoded_records_per_second": round(len(decoded_records) / elapsed, 3),
        "exact_record_order_and_payload_match": exact_match,
        "status": "PASS" if exact_match else "FAIL",
        "authority": (
            "This result proves only offline transport/replay behavior for captured raw evidence. "
            "It does not prove a live connection or assign vehicle meanings."
        ),
    }
    if not exact_match:
        raise CANReplayError(
            "Replay changed, reordered, duplicated, or unexpectedly lost real CAN observations."
        )
    return result


def write_can_replay_fixture(
    root: Path,
    output: Path,
    *,
    session_id: int,
    limit: int,
) -> dict[str, Any]:
    """Materialize a deterministic real-record excerpt for cross-language contract tests."""
    if output.exists():
        raise CANReplayError(f"Replay fixture output already exists: {output}")
    if not 1 <= limit <= 10_000:
        raise CANReplayError("Replay fixture limit must be between 1 and 10,000.")
    corpus = load_validated_can_replay_corpus(root)
    selected = [record for record in corpus.records if record.session_id == session_id][:limit]
    if len(selected) != limit:
        raise CANReplayError(
            f"Replay corpus has only {len(selected)} records for session {session_id}; requested {limit}."
        )
    documents = [_record_document(record) for record in selected]
    raw = b"".join(
        json.dumps(document, sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n"
        for document in documents
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(raw)
    return {
        "output": str(output.resolve()),
        "corpus_id": corpus.manifest["corpus_id"],
        "corpus_semantic_digest": corpus.manifest["semantic_digest"],
        "session_id": session_id,
        "records": len(selected),
        "sha256": hashlib.sha256(raw).hexdigest(),
        "required_display_label": REQUIRED_DISPLAY_LABEL,
    }


def _wire_units(
    records: Sequence[PassiveCANRecord], *, mode: str, repeat: int
) -> Iterator[tuple[bytes, list[PassiveCANRecord]]]:
    outer_sequence = 0
    if mode == "live":
        for _ in range(repeat):
            for record in records:
                outer_sequence += 1
                payload = _encode_live_record(record)
                yield _encode_gateway_frame(
                    LIVE_CAN_MESSAGE_TYPE,
                    outer_sequence,
                    outer_sequence * 2_000,
                    payload,
                ), [record]
        return

    sessions: list[tuple[int, list[PassiveCANRecord]]] = []
    for record in records:
        if not sessions or sessions[-1][0] != record.session_id:
            sessions.append((record.session_id, []))
        sessions[-1][1].append(record)
    for _ in range(repeat):
        for session_id, session_records in sessions:
            for offset in range(0, len(session_records), 5):
                chunk_records = session_records[offset : offset + 5]
                outer_sequence += 1
                payload = _encode_capture_log_chunk(
                    session_id,
                    offset,
                    chunk_records,
                    end_of_file=offset + len(chunk_records) == len(session_records),
                )
                yield _encode_gateway_frame(
                    CAPTURE_LOG_CHUNK_MESSAGE_TYPE,
                    outer_sequence,
                    outer_sequence * 2_000,
                    payload,
                ), list(chunk_records)


def _encode_gateway_frame(
    message_type: int, sequence: int, monotonic_microseconds: int, payload: bytes
) -> bytes:
    header = bytearray(VHOS_HEADER_BYTES)
    header[0:4] = VHOS_MAGIC
    header[4] = 1
    header[5] = 0
    header[6] = message_type
    header[7] = 0
    struct.pack_into("<IQQI", header, 8, len(payload), sequence, monotonic_microseconds, crc32c(payload))
    struct.pack_into("<I", header, 32, crc32c(bytes(header[:32])))
    return bytes(header) + payload


def _encode_common_record(record: PassiveCANRecord, *, stored: bool) -> bytearray:
    payload = bytearray(36)
    payload[0] = 1
    payload[1] = (0x01 if record.extended else 0) | (0x02 if record.remote_request else 0) | (
        0x04 if record.listen_only else 0
    )
    payload[2] = record.data_length
    payload[3] = 2 if record.bitrate_bps == 250_000 else 1
    struct.pack_into("<IQQ", payload, 4, record.identifier, record.source_sequence, record.monotonic_microseconds)
    data_offset = 24 if stored else 28
    payload[data_offset : data_offset + 8] = bytes(record.data)
    if stored:
        struct.pack_into("<I", payload, 32, crc32c(bytes(payload[:32])))
    else:
        struct.pack_into("<I", payload, 24, record.session_id)
    return payload


def _encode_live_record(record: PassiveCANRecord) -> bytes:
    return bytes(_encode_common_record(record, stored=False))


def _encode_stored_record(record: PassiveCANRecord) -> bytes:
    return bytes(_encode_common_record(record, stored=True))


def _encode_capture_log_chunk(
    session_id: int,
    record_offset: int,
    records: Sequence[PassiveCANRecord],
    *,
    end_of_file: bool,
) -> bytes:
    payload = bytearray(16)
    payload[0] = 1
    payload[1] = 0
    payload[2] = 1 if end_of_file else 0
    struct.pack_into("<IHHI", payload, 4, record_offset, len(records), 36, session_id)
    return bytes(payload) + b"".join(_encode_stored_record(record) for record in records)


def _decode_wire_observations(
    frame: DecodedGatewayFrame, gateway_id: str
) -> list[PassiveCANRecord]:
    if frame.message_type == LIVE_CAN_MESSAGE_TYPE:
        return [_decode_record(frame.payload, gateway_id=gateway_id, session_id=None, stored=False)]
    if frame.message_type != CAPTURE_LOG_CHUNK_MESSAGE_TYPE:
        return []
    payload = frame.payload
    if len(payload) < 16 or payload[0] != 1:
        raise CANReplayError("Decoded capture-log chunk header is invalid.")
    count, record_bytes, session_id = struct.unpack_from("<HHI", payload, 8)
    if record_bytes != 36 or len(payload) != 16 + count * record_bytes:
        raise CANReplayError("Decoded capture-log chunk shape is invalid.")
    return [
        _decode_record(
            payload[16 + index * 36 : 16 + (index + 1) * 36],
            gateway_id=gateway_id,
            session_id=session_id,
            stored=True,
        )
        for index in range(count)
    ]


def _decode_record(
    payload: bytes, *, gateway_id: str, session_id: int | None, stored: bool
) -> PassiveCANRecord:
    if len(payload) != 36 or payload[0] != 1:
        raise CANReplayError("Decoded CAN record shape is invalid.")
    if stored and struct.unpack_from("<I", payload, 32)[0] != crc32c(payload[:32]):
        raise CANReplayError("Decoded stored CAN record CRC32C is invalid.")
    flags = payload[1]
    bitrate = 250_000 if payload[3] == 2 else 500_000
    actual_session_id = session_id if stored else struct.unpack_from("<I", payload, 24)[0]
    data_offset = 24 if stored else 28
    return PassiveCANRecord(
        gateway_id=gateway_id,
        session_id=int(actual_session_id),
        source_sequence=struct.unpack_from("<Q", payload, 8)[0],
        monotonic_microseconds=struct.unpack_from("<Q", payload, 16)[0],
        bitrate_bps=bitrate,
        identifier=struct.unpack_from("<I", payload, 4)[0],
        extended=bool(flags & 0x01),
        remote_request=bool(flags & 0x02),
        listen_only=bool(flags & 0x04),
        data_length=min(payload[2], 8),
        data=tuple(payload[data_offset : data_offset + 8]),
        evidence_source="gateway-flash",
        ingested_at="1970-01-01T00:00:00Z",
    )


def _resolve_inputs(inputs: Iterable[Path]) -> list[Path]:
    files: set[Path] = set()
    for item in inputs:
        path = item.resolve()
        if path.is_dir():
            files.update(candidate.resolve() for candidate in path.rglob("*.ndjson"))
        elif path.is_file():
            files.add(path)
        else:
            raise CANReplayError(f"Replay input does not exist: {path}")
    if not files:
        raise CANReplayError("No passive CAN NDJSON files were found.")
    return sorted(files)


def _ordered_records(records: Iterable[PassiveCANRecord]) -> list[PassiveCANRecord]:
    return sorted(
        records,
        key=lambda record: (
            record.gateway_id,
            record.session_id,
            record.monotonic_microseconds,
            record.source_sequence,
        ),
    )


def _statistics(
    records: Sequence[PassiveCANRecord], source_files: Sequence[dict[str, Any]]
) -> dict[str, Any]:
    return {
        "records": len(records),
        "sessions": len({(record.gateway_id, record.session_id) for record in records}),
        "unique_identifiers": len({(record.identifier, record.extended) for record in records}),
        "total_source_bytes": sum(int(item["byte_count"]) for item in source_files),
        "listen_only_records": sum(record.listen_only for record in records),
        "bitrates_bps": sorted({record.bitrate_bps for record in records}),
    }


def _semantic_digest(records: Sequence[PassiveCANRecord]) -> str:
    digest = hashlib.sha256()
    for record in records:
        document = asdict(record)
        document["data"] = list(record.data)
        digest.update(json.dumps(document, sort_keys=True, separators=(",", ":")).encode("utf-8"))
        digest.update(b"\n")
    return digest.hexdigest()


def _record_document(record: PassiveCANRecord) -> dict[str, Any]:
    return {
        "contract": "gateway.passive-can-observation",
        "contract_version": "1.0.0",
        "gateway_id": record.gateway_id,
        "session_id": record.session_id,
        "source_sequence": record.source_sequence,
        "monotonic_microseconds": record.monotonic_microseconds,
        "bitrate_bps": record.bitrate_bps,
        "identifier": record.identifier,
        "extended": record.extended,
        "remote_request": record.remote_request,
        "listen_only": record.listen_only,
        "data_length": record.data_length,
        "data": list(record.data),
        "evidence_source": record.evidence_source,
        "ingested_at": record.ingested_at,
    }


def _record_semantic_tuple(record: PassiveCANRecord) -> tuple[Any, ...]:
    # Ingestion time and evidence-source naming are outside the deployed binary record.
    return (
        record.gateway_id,
        record.session_id,
        record.source_sequence,
        record.monotonic_microseconds,
        record.bitrate_bps,
        record.identifier,
        record.extended,
        record.remote_request,
        record.listen_only,
        record.data_length,
        record.data,
    )


def _fragments(wire: bytes, sizes: Sequence[int]) -> Iterator[bytes]:
    offset = 0
    index = 0
    while offset < len(wire):
        count = min(sizes[index % len(sizes)], len(wire) - offset)
        yield wire[offset : offset + count]
        offset += count
        index += 1


_CRC32C_TABLE: tuple[int, ...] | None = None


def crc32c(data: bytes) -> int:
    global _CRC32C_TABLE
    if _CRC32C_TABLE is None:
        table: list[int] = []
        for value in range(256):
            crc = value
            for _ in range(8):
                crc = (crc >> 1) ^ (0x82F63B78 if crc & 1 else 0)
            table.append(crc)
        _CRC32C_TABLE = tuple(table)
    crc = 0xFFFF_FFFF
    for byte in data:
        crc = _CRC32C_TABLE[(crc ^ byte) & 0xFF] ^ (crc >> 8)
    return (~crc) & 0xFFFF_FFFF
