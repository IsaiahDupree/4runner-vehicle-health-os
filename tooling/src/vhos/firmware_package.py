from __future__ import annotations

import base64
import hashlib
import json
import struct
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)


MAGIC = b"VHUP"
FORMAT_VERSION = 1
HEADER = struct.Struct(">4sHIIH")
REQUIRED_OTA_CAPABILITIES = sorted(
    ("ota.ab", "ota.rollback-self-test", "ota.signed-image")
)


@dataclass(frozen=True)
class FirmwarePackage:
    manifest: dict[str, object]
    manifest_bytes: bytes
    firmware: bytes
    signature: bytes


def build_firmware_package(
    *,
    firmware_path: Path,
    output_path: Path,
    private_key_path: Path,
    firmware_version: str,
    firmware_build_id: str,
    supported_hardware_revisions: list[str],
    minimum_supply_millivolts: int,
    minimum_bootloader_version: str | None = None,
    release_channel: str = "development",
    package_id: uuid.UUID | None = None,
    created_at: str | None = None,
) -> FirmwarePackage:
    if output_path.exists():
        raise ValueError(f"firmware package output already exists: {output_path}")
    firmware = firmware_path.read_bytes()
    if not firmware or firmware[0] != 0xE9:
        raise ValueError("firmware is not an ESP application image")
    if len(firmware) > 0x180000:
        raise ValueError("firmware exceeds the MrDIY 1.5 MiB OTA slot")
    if minimum_supply_millivolts <= 0:
        raise ValueError("minimum supply must be a positive millivolt value")
    hardware = sorted(set(supported_hardware_revisions))
    if not hardware:
        raise ValueError("at least one exact hardware revision is required")

    private_key = serialization.load_pem_private_key(
        private_key_path.read_bytes(), password=None
    )
    if not isinstance(private_key, Ed25519PrivateKey):
        raise ValueError("package signing key is not an Ed25519 private key")

    timestamp = created_at or (
        datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    )
    manifest: dict[str, object] = {
        "contract": "firmware.manifest",
        "contract_version": "1.0.0",
        "created_at": timestamp,
        "firmware_build_id": firmware_build_id,
        "firmware_sha256": hashlib.sha256(firmware).hexdigest(),
        "firmware_size_bytes": len(firmware),
        "firmware_version": firmware_version,
        "minimum_bootloader_version": minimum_bootloader_version,
        "minimum_supply_millivolts": minimum_supply_millivolts,
        "package_id": str(package_id or uuid.uuid4()).upper(),
        "release_channel": release_channel,
        "required_capabilities": REQUIRED_OTA_CAPABILITIES,
        "supported_hardware_revisions": hardware,
    }
    manifest_bytes = json.dumps(
        manifest, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    digest = hashlib.sha256(manifest_bytes + firmware).digest()
    signature = private_key.sign(digest)
    encoded = (
        HEADER.pack(
            MAGIC,
            FORMAT_VERSION,
            len(manifest_bytes),
            len(firmware),
            len(signature),
        )
        + manifest_bytes
        + firmware
        + signature
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_bytes(encoded)
    return FirmwarePackage(manifest, manifest_bytes, firmware, signature)


def verify_firmware_package(package_path: Path, public_key_path: Path) -> FirmwarePackage:
    encoded = package_path.read_bytes()
    if len(encoded) < HEADER.size:
        raise ValueError("firmware package header is incomplete")
    magic, version, manifest_length, firmware_length, signature_length = HEADER.unpack_from(
        encoded
    )
    if magic != MAGIC or version != FORMAT_VERSION:
        raise ValueError("firmware package magic or version is unsupported")
    expected = HEADER.size + manifest_length + firmware_length + signature_length
    if not manifest_length or not firmware_length or not signature_length or expected != len(encoded):
        raise ValueError("firmware package lengths are invalid")
    manifest_start = HEADER.size
    firmware_start = manifest_start + manifest_length
    signature_start = firmware_start + firmware_length
    manifest_bytes = encoded[manifest_start:firmware_start]
    firmware = encoded[firmware_start:signature_start]
    signature = encoded[signature_start:]
    manifest = json.loads(manifest_bytes)
    if manifest.get("contract") != "firmware.manifest" or manifest.get("contract_version") != "1.0.0":
        raise ValueError("firmware manifest contract is unsupported")
    if manifest.get("firmware_size_bytes") != len(firmware):
        raise ValueError("firmware length does not match its manifest")
    if manifest.get("firmware_sha256") != hashlib.sha256(firmware).hexdigest():
        raise ValueError("firmware hash does not match its manifest")

    public_bytes = public_key_path.read_bytes()
    try:
        if public_bytes.startswith(b"-----BEGIN"):
            public_key = serialization.load_pem_public_key(public_bytes)
        else:
            if len(public_bytes) != 32:
                public_bytes = base64.b64decode(public_bytes.strip(), validate=True)
            public_key = Ed25519PublicKey.from_public_bytes(public_bytes)
    except (TypeError, ValueError) as error:
        raise ValueError("release public key is not a valid Ed25519 key") from error
    if not isinstance(public_key, Ed25519PublicKey):
        raise ValueError("release public key is not an Ed25519 key")
    try:
        public_key.verify(signature, hashlib.sha256(manifest_bytes + firmware).digest())
    except InvalidSignature as error:
        raise ValueError("firmware package signature is invalid") from error
    return FirmwarePackage(manifest, manifest_bytes, firmware, signature)


def raw_public_key(private_key_path: Path) -> bytes:
    private_key = serialization.load_pem_private_key(
        private_key_path.read_bytes(), password=None
    )
    if not isinstance(private_key, Ed25519PrivateKey):
        raise ValueError("package signing key is not an Ed25519 private key")
    return private_key.public_key().public_bytes(
        serialization.Encoding.Raw,
        serialization.PublicFormat.Raw,
    )
