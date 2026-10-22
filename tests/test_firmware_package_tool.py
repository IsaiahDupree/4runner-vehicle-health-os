from __future__ import annotations

import base64
from pathlib import Path

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from vhos.firmware_package import build_firmware_package, raw_public_key, verify_firmware_package


def test_real_ed25519_package_round_trip_and_tamper_rejection(tmp_path: Path) -> None:
    private_key = Ed25519PrivateKey.generate()
    private_key_path = tmp_path / "release-key.pem"
    private_key_path.write_bytes(
        private_key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )
    public_key_path = tmp_path / "release-key.raw"
    public_key_path.write_bytes(base64.b64encode(raw_public_key(private_key_path)) + b"\n")
    firmware_path = tmp_path / "firmware.bin"
    firmware_path.write_bytes(bytes([0xE9]) + b"real-integration-firmware-bytes")
    package_path = tmp_path / "firmware.vhosota"

    built = build_firmware_package(
        firmware_path=firmware_path,
        output_path=package_path,
        private_key_path=private_key_path,
        firmware_version="0.1.0-dev.12",
        firmware_build_id="integration-build",
        supported_hardware_revisions=["MrDIY-CAN-SHIELD-v1.3+"],
        minimum_supply_millivolts=11_800,
        created_at="2026-08-17T00:00:00Z",
    )
    verified = verify_firmware_package(package_path, public_key_path)

    assert verified.manifest == built.manifest
    assert verified.firmware == firmware_path.read_bytes()
    assert verified.manifest["required_capabilities"] == [
        "ota.ab",
        "ota.rollback-self-test",
        "ota.signed-image",
    ]

    tampered = bytearray(package_path.read_bytes())
    tampered[-1] ^= 0x01
    tampered_path = tmp_path / "tampered.vhosota"
    tampered_path.write_bytes(tampered)
    with pytest.raises(Exception):
        verify_firmware_package(tampered_path, public_key_path)


def test_bundled_ios_development_key_matches_release_key_source() -> None:
    root = Path(__file__).resolve().parents[1]
    assert (
        root / "keys/mrdiy-v13-development-release-ed25519.base64"
    ).read_bytes() == (
        root / "ios/App/Resources/mrdiy-v13-development-release-ed25519.base64"
    ).read_bytes()
