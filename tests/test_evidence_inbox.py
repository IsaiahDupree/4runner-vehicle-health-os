from __future__ import annotations

import hashlib
import json
import threading
from concurrent.futures import ThreadPoolExecutor
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from pathlib import Path
from uuid import UUID

import pytest

from vhos.evidence_inbox import EvidenceInboxError, EvidenceInboxServer, EvidenceInboxStore


def _envelope(
    payload: bytes,
    content_type: str = "application/vnd.vhos.evidence-sync+zip",
) -> dict[str, object]:
    return {
        "contract": "evidence.outbox-envelope",
        "contract_version": "1.0.0",
        "package_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
        "created_at": "2026-08-18T12:00:00Z",
        "content_type": content_type,
        "byte_count": len(payload),
        "sha256": hashlib.sha256(payload).hexdigest(),
        "authority": {
            "may_interpret": True,
            "may_propose_experiment": True,
            "may_activate_experiment": False,
            "may_emit_vehicle_frames": False,
        },
        "redaction_policy": "OWNER_PRIVATE_V1",
    }


def test_inbox_is_idempotent_and_claims_once(tmp_path: Path) -> None:
    payload = b"real checksummed evidence bytes"
    envelope = _envelope(payload)
    store = EvidenceInboxStore(tmp_path / "inbox")
    keyword = {
        "claimed_content_type": envelope["content_type"],
        "claimed_sha256": envelope["sha256"],
    }

    first = store.ingest(
        envelope["package_id"], json.dumps(envelope).encode(), payload, **keyword
    )
    second = store.ingest(
        envelope["package_id"], json.dumps(envelope).encode(), payload, **keyword
    )

    assert first.inserted is True
    assert second.inserted is False
    assert store.list_packages(pending_only=True)[0]["state"] == "PENDING"
    claimed = store.claim(envelope["package_id"], "vehicle-evidence-agent-v1")
    assert Path(claimed["payload"]).read_bytes() == payload
    assert store.list_packages()[0]["state"] == "CLAIMED"
    with pytest.raises(EvidenceInboxError, match="already been claimed"):
        store.claim(envelope["package_id"], "second-agent")


def test_inbox_rejects_payload_substitution(tmp_path: Path) -> None:
    payload = b"original"
    envelope = _envelope(payload)
    store = EvidenceInboxStore(tmp_path / "inbox")
    with pytest.raises(EvidenceInboxError, match="does not match"):
        store.ingest(
            str(UUID(envelope["package_id"])),
            json.dumps(envelope).encode(),
            b"substituted",
            claimed_content_type=envelope["content_type"],
            claimed_sha256=hashlib.sha256(b"substituted").hexdigest(),
        )


def test_discovery_draft_evidence_is_accepted_without_vehicle_authority(
    tmp_path: Path,
) -> None:
    payload = b'{"contract":"vhos.discovery-draft-evidence"}'
    envelope = _envelope(
        payload, "application/vnd.vhos.discovery-draft-evidence+json"
    )
    store = EvidenceInboxStore(tmp_path / "inbox")

    result = store.ingest(
        envelope["package_id"],
        json.dumps(envelope).encode(),
        payload,
        claimed_content_type=envelope["content_type"],
        claimed_sha256=envelope["sha256"],
    )

    assert result.inserted is True
    stored = store.list_packages()[0]
    assert stored["content_type"] == envelope["content_type"]
    stored_envelope = json.loads(
        (result.directory / "envelope.json").read_text(encoding="utf-8")
    )
    assert stored_envelope["authority"] == {
        "may_interpret": True,
        "may_propose_experiment": True,
        "may_activate_experiment": False,
        "may_emit_vehicle_frames": False,
    }


def test_concurrent_duplicate_ingest_is_atomic_and_idempotent(tmp_path: Path) -> None:
    payload = b"one immutable evidence package received concurrently"
    envelope = _envelope(payload)
    envelope_bytes = json.dumps(envelope).encode()
    store = EvidenceInboxStore(tmp_path / "inbox")

    def ingest_once() -> bool:
        return store.ingest(
            envelope["package_id"],
            envelope_bytes,
            payload,
            claimed_content_type=envelope["content_type"],
            claimed_sha256=envelope["sha256"],
        ).inserted

    with ThreadPoolExecutor(max_workers=8) as executor:
        inserted = list(executor.map(lambda _: ingest_once(), range(16)))

    assert inserted.count(True) == 1
    assert inserted.count(False) == 15
    assert len(store.list_packages()) == 1


def test_http_inbox_requires_bearer_token_for_package_listing(tmp_path: Path) -> None:
    token = "a-private-test-token-with-more-than-32-characters"
    server = EvidenceInboxServer(
        ("127.0.0.1", 0), EvidenceInboxStore(tmp_path / "inbox"), token
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    endpoint = f"http://127.0.0.1:{server.server_port}/v1/evidence/packages"
    try:
        with pytest.raises(HTTPError) as denied:
            urlopen(endpoint, timeout=2)
        assert denied.value.code == 401

        request = Request(endpoint, headers={"Authorization": f"Bearer {token}"})
        with urlopen(request, timeout=2) as response:
            assert response.status == 200
            assert json.loads(response.read()) == {"packages": []}
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
