from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import json
import ssl
import tempfile
import threading
from dataclasses import dataclass
from datetime import UTC, datetime
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse
from uuid import UUID

from .contracts import ContractCatalog, ContractError


MAXIMUM_PACKAGE_BYTES = 128 * 1024 * 1024


class EvidenceInboxError(ValueError):
    """Raised when a private evidence package cannot be accepted or claimed."""


@dataclass(frozen=True)
class EvidenceInboxReceipt:
    package_id: str
    inserted: bool
    directory: Path
    sha256: str


class EvidenceInboxStore:
    def __init__(self, root: Path) -> None:
        self.root = root.resolve()
        self.root.mkdir(parents=True, exist_ok=True)
        self._mutation_lock = threading.RLock()

    def ingest(
        self,
        package_id: str,
        envelope_bytes: bytes,
        payload: bytes,
        *,
        claimed_content_type: str,
        claimed_sha256: str,
    ) -> EvidenceInboxReceipt:
        try:
            normalized_id = str(UUID(package_id)).lower()
            envelope = json.loads(envelope_bytes)
        except (ValueError, json.JSONDecodeError) as error:
            raise EvidenceInboxError("Package ID or envelope JSON is invalid.") from error
        if not isinstance(envelope, dict):
            raise EvidenceInboxError("Evidence envelope must be a JSON object.")
        try:
            ContractCatalog.load().validate(envelope)
        except ContractError as error:
            raise EvidenceInboxError(str(error)) from error
        digest = hashlib.sha256(payload).hexdigest()
        if (
            envelope["package_id"].lower() != normalized_id
            or envelope["byte_count"] != len(payload)
            or envelope["sha256"] != digest
            or not hmac.compare_digest(claimed_sha256.lower(), digest)
            or envelope["content_type"] != claimed_content_type
        ):
            raise EvidenceInboxError(
                "Package path, byte count, content type, or SHA-256 does not match the envelope."
            )
        if not payload or len(payload) > MAXIMUM_PACKAGE_BYTES:
            raise EvidenceInboxError("Evidence payload is empty or exceeds the bounded limit.")

        destination = self.root / normalized_id
        with self._mutation_lock:
            if destination.exists():
                existing = json.loads(
                    (destination / "envelope.json").read_text(encoding="utf-8")
                )
                if existing.get("sha256") != digest:
                    raise EvidenceInboxError(
                        "Package ID already exists with different evidence bytes."
                    )
                return EvidenceInboxReceipt(normalized_id, False, destination, digest)

            staging = Path(tempfile.mkdtemp(prefix=f".{normalized_id}.", dir=self.root))
            try:
                suffix = ".vhossync" if claimed_content_type.endswith("+zip") else ".json"
                (staging / f"evidence{suffix}").write_bytes(payload)
                (staging / "envelope.json").write_text(
                    json.dumps(envelope, indent=2, sort_keys=True) + "\n", encoding="utf-8"
                )
                (staging / "receipt.json").write_text(
                    json.dumps(
                        {
                            "accepted_at": _timestamp(),
                            "package_id": normalized_id,
                            "sha256": digest,
                            "state": "PENDING",
                        },
                        indent=2,
                        sort_keys=True,
                    )
                    + "\n",
                    encoding="utf-8",
                )
                staging.replace(destination)
            except Exception:
                for child in staging.glob("*"):
                    child.unlink(missing_ok=True)
                staging.rmdir()
                raise
            return EvidenceInboxReceipt(normalized_id, True, destination, digest)

    def list_packages(self, *, pending_only: bool = False) -> list[dict[str, Any]]:
        packages: list[dict[str, Any]] = []
        for directory in sorted(self.root.iterdir()):
            if not directory.is_dir() or directory.name.startswith("."):
                continue
            envelope_path = directory / "envelope.json"
            if not envelope_path.is_file():
                continue
            claimed = (directory / "claim.json").is_file()
            if pending_only and claimed:
                continue
            envelope = json.loads(envelope_path.read_text(encoding="utf-8"))
            packages.append(
                {
                    "package_id": envelope["package_id"],
                    "created_at": envelope["created_at"],
                    "content_type": envelope["content_type"],
                    "byte_count": envelope["byte_count"],
                    "sha256": envelope["sha256"],
                    "state": "CLAIMED" if claimed else "PENDING",
                }
            )
        return packages

    def claim(self, package_id: str, agent_id: str) -> dict[str, Any]:
        normalized_id = str(UUID(package_id)).lower()
        normalized_agent = agent_id.strip()
        if not normalized_agent or len(normalized_agent) > 160:
            raise EvidenceInboxError("A bounded non-empty AI agent identity is required.")
        directory = self.root / normalized_id
        if not (directory / "envelope.json").is_file():
            raise EvidenceInboxError("Evidence package does not exist.")
        claim = {
            "agent_id": normalized_agent,
            "claimed_at": _timestamp(),
            "authority": {
                "may_interpret": True,
                "may_propose_experiment": True,
                "may_activate_experiment": False,
                "may_emit_vehicle_frames": False,
            },
        }
        try:
            with (directory / "claim.json").open("x", encoding="utf-8") as handle:
                json.dump(claim, handle, indent=2, sort_keys=True)
                handle.write("\n")
        except FileExistsError as error:
            raise EvidenceInboxError("Evidence package has already been claimed.") from error
        payloads = sorted(directory.glob("evidence.*"))
        return {
            "package_id": normalized_id,
            "directory": str(directory),
            "payload": str(payloads[0]) if payloads else None,
            "envelope": str(directory / "envelope.json"),
            "claim": claim,
        }


class EvidenceInboxServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address: tuple[str, int], store: EvidenceInboxStore, bearer_token: str):
        self.store = store
        self.bearer_token = bearer_token
        super().__init__(address, EvidenceInboxHandler)


class EvidenceInboxHandler(BaseHTTPRequestHandler):
    server: EvidenceInboxServer

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path)
        if path.path == "/health":
            return self._json(HTTPStatus.OK, {"status": "ok", "service": "vhos-evidence-inbox"})
        if not self._authorized():
            return self._json(HTTPStatus.UNAUTHORIZED, {"error": "unauthorized"})
        if path.path == "/v1/evidence/packages":
            pending_only = path.query == "state=pending"
            return self._json(
                HTTPStatus.OK,
                {"packages": self.server.store.list_packages(pending_only=pending_only)},
            )
        return self._json(HTTPStatus.NOT_FOUND, {"error": "not_found"})

    def do_POST(self) -> None:  # noqa: N802
        if not self._authorized():
            return self._json(HTTPStatus.UNAUTHORIZED, {"error": "unauthorized"})
        path = urlparse(self.path).path
        parts = [part for part in path.split("/") if part]
        if len(parts) not in {4, 5} or parts[:3] != ["v1", "evidence", "packages"]:
            return self._json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
        package_id = parts[3]
        if len(parts) == 5 and parts[4] == "claim":
            try:
                body = self._read_body(16_384)
                document = json.loads(body)
                result = self.server.store.claim(package_id, str(document.get("agent_id", "")))
                return self._json(HTTPStatus.OK, result)
            except (EvidenceInboxError, ValueError, json.JSONDecodeError) as error:
                return self._json(HTTPStatus.CONFLICT, {"error": str(error)})
        if len(parts) != 4:
            return self._json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
        try:
            envelope_header = self.headers.get("X-VHOS-Envelope-Base64", "")
            envelope = base64.b64decode(envelope_header, validate=True)
            payload = self._read_body(MAXIMUM_PACKAGE_BYTES)
            receipt = self.server.store.ingest(
                package_id,
                envelope,
                payload,
                claimed_content_type=self.headers.get("Content-Type", ""),
                claimed_sha256=self.headers.get("X-VHOS-SHA256", ""),
            )
            return self._json(
                HTTPStatus.CREATED if receipt.inserted else HTTPStatus.OK,
                {
                    "accepted": True,
                    "inserted": receipt.inserted,
                    "package_id": receipt.package_id,
                    "sha256": receipt.sha256,
                },
            )
        except (EvidenceInboxError, ValueError, binascii.Error) as error:
            return self._json(HTTPStatus.BAD_REQUEST, {"error": str(error)})

    def _read_body(self, maximum: int) -> bytes:
        try:
            length = int(self.headers.get("Content-Length", "-1"))
        except ValueError as error:
            raise EvidenceInboxError("Content-Length is invalid.") from error
        if length < 1 or length > maximum:
            raise EvidenceInboxError("Request body length is outside the bounded limit.")
        body = self.rfile.read(length)
        if len(body) != length:
            raise EvidenceInboxError("Request body is incomplete.")
        return body

    def _authorized(self) -> bool:
        supplied = self.headers.get("Authorization", "")
        return hmac.compare_digest(supplied, f"Bearer {self.server.bearer_token}")

    def _json(self, status: HTTPStatus, document: dict[str, Any]) -> None:
        body = json.dumps(document, sort_keys=True, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        return


def serve_evidence_inbox(
    *,
    root: Path,
    bind: str,
    port: int,
    bearer_token: str,
    tls_certificate: Path | None,
    tls_private_key: Path | None,
) -> None:
    if len(bearer_token) < 32:
        raise EvidenceInboxError("Evidence inbox bearer token must contain at least 32 characters.")
    if (tls_certificate is None) != (tls_private_key is None):
        raise EvidenceInboxError("TLS certificate and private key must be supplied together.")
    if tls_certificate is None and bind not in {"127.0.0.1", "::1", "localhost"}:
        raise EvidenceInboxError("Non-loopback evidence inboxes require TLS.")
    server = EvidenceInboxServer((bind, port), EvidenceInboxStore(root), bearer_token)
    if tls_certificate is not None and tls_private_key is not None:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(tls_certificate, tls_private_key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    try:
        server.serve_forever(poll_interval=0.25)
    finally:
        server.server_close()


def _timestamp() -> str:
    return datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")
