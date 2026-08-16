from __future__ import annotations

import hashlib
import re
import secrets
import time

CROCKFORD_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
PREFIX_PATTERN = re.compile(r"^[a-z][a-z0-9]*$")
DOMAIN_ID_PATTERN = re.compile(
    r"^[a-z][a-z0-9]*_[0-9A-HJKMNP-TV-Z]{26}$"
)


def _encode_ulid(timestamp_ms: int, entropy: bytes) -> str:
    if not 0 <= timestamp_ms < 2**48:
        raise ValueError("timestamp_ms must fit in 48 bits")
    if len(entropy) != 10:
        raise ValueError("ULID entropy must be exactly 10 bytes")

    value = (timestamp_ms << 80) | int.from_bytes(entropy, "big")
    encoded = ["0"] * 26
    for index in range(25, -1, -1):
        encoded[index] = CROCKFORD_ALPHABET[value & 0x1F]
        value >>= 5
    return "".join(encoded)


def _validate_prefix(prefix: str) -> None:
    if not PREFIX_PATTERN.fullmatch(prefix):
        raise ValueError(
            "ID prefix must start with a lowercase letter and contain only lowercase letters or digits"
        )


def new_id(prefix: str, *, timestamp_ms: int | None = None) -> str:
    """Create a typed, time-sortable domain ID."""
    _validate_prefix(prefix)
    resolved_time = int(time.time() * 1000) if timestamp_ms is None else timestamp_ms
    return f"{prefix}_{_encode_ulid(resolved_time, secrets.token_bytes(10))}"


def deterministic_id(prefix: str, seed: str, *, timestamp_ms: int) -> str:
    """Create a stable typed ID for deterministic simulator/replay fixtures."""
    _validate_prefix(prefix)
    entropy = hashlib.sha256(f"{prefix}\0{seed}".encode("utf-8")).digest()[:10]
    return f"{prefix}_{_encode_ulid(timestamp_ms, entropy)}"


def is_domain_id(value: str) -> bool:
    return DOMAIN_ID_PATTERN.fullmatch(value) is not None
