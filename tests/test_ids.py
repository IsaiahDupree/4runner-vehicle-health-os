from vhos.ids import deterministic_id, is_domain_id, new_id


def test_deterministic_ids_are_stable_and_typed() -> None:
    first = deterministic_id("obs", "capture:1", timestamp_ms=1_723_827_600_000)
    second = deterministic_id("obs", "capture:1", timestamp_ms=1_723_827_600_000)

    assert first == second
    assert first.startswith("obs_")
    assert is_domain_id(first)


def test_domain_ids_sort_by_timestamp_for_same_prefix() -> None:
    earlier = deterministic_id("calc", "same", timestamp_ms=1_000)
    later = deterministic_id("calc", "same", timestamp_ms=2_000)

    assert earlier < later


def test_new_id_uses_valid_shape() -> None:
    assert is_domain_id(new_id("audit", timestamp_ms=1_723_827_600_000))
