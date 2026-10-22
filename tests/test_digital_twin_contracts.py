from __future__ import annotations

from copy import deepcopy
from uuid import UUID

import pytest

from vhos.contracts import ContractCatalog, ContractError


def _profile() -> dict:
    return {
        "contract": "vehicle.configuration-profile",
        "contract_version": "1.0.0",
        "revision_id": "57e18cbf-7c79-4e16-bd2a-b42ddce2df04",
        "supersedes_revision_id": None,
        "created_at": "2026-08-18T12:00:00Z",
        "vehicle_pack_id": "toyota.4runner.2005",
        "vehicle_pack_version": "0.1.0",
        "model_year": 2005,
        "make": "Toyota",
        "model": "4Runner",
        "vin": "JTEBU14R750012345",
        "engine": "V6_4_0L_1GR_FE",
        "timing_drive": "TIMING_CHAIN",
        "drivetrain": "FOUR_WHEEL_DRIVE",
        "rear_suspension": "CONVENTIONAL",
        "trim": "SR5",
        "build_date": "2005-03",
        "tire_configuration": "265/65R17",
        "severe_use": "UNKNOWN",
        "modification_state": "STOCK",
        "modifications": [],
        "current_mileage": 154000,
        "mileage_observed_at": "2026-08-18T12:00:00Z",
        "mileage_source": "MANUAL_ODOMETER",
    }


def test_v6_profile_requires_timing_chain() -> None:
    catalog = ContractCatalog.load()
    profile = _profile()
    catalog.validate(profile)

    profile["timing_drive"] = "TIMING_BELT"
    with pytest.raises(ContractError, match="timing_drive"):
        catalog.validate(profile)


def test_v8_profile_requires_timing_belt() -> None:
    catalog = ContractCatalog.load()
    profile = _profile()
    profile["engine"] = "V8_4_7L_2UZ_FE"
    profile["timing_drive"] = "TIMING_BELT"
    catalog.validate(profile)


def test_unknown_health_cannot_claim_an_evidence_basis() -> None:
    catalog = ContractCatalog.load()
    assessment = {
        "contract": "vehicle.health-assessment",
        "contract_version": "1.0.0",
        "assessment_id": "4b922523-c988-4023-9194-a44deffea24b",
        "supersedes_assessment_id": None,
        "profile_revision_id": None,
        "system_id": "BRAKES",
        "state": "UNKNOWN",
        "basis": "UNKNOWN",
        "recorded_at": "2026-08-18T12:00:00Z",
        "summary": "No qualifying brake evidence has been recorded.",
        "evidence_refs": [],
        "equation_definition_id": None,
        "equation_version": None,
        "confidence": None,
    }
    catalog.validate(assessment)

    invalid = deepcopy(assessment)
    invalid["basis"] = "INSPECTION"
    with pytest.raises(ContractError, match="basis"):
        catalog.validate(invalid)


def test_non_unknown_health_requires_evidence() -> None:
    catalog = ContractCatalog.load()
    assessment = {
        "contract": "vehicle.health-assessment",
        "contract_version": "1.0.0",
        "assessment_id": "1c4ff4dd-a137-4ca0-bc90-1c08bc94a481",
        "supersedes_assessment_id": None,
        "profile_revision_id": None,
        "system_id": "WHEELS_AND_TIRES",
        "state": "OK",
        "basis": "INSPECTION",
        "recorded_at": "2026-08-18T12:00:00Z",
        "summary": "Tread depth was measured at all four wheels.",
        "evidence_refs": [],
        "equation_definition_id": None,
        "equation_version": None,
        "confidence": 1.0,
    }
    with pytest.raises(ContractError, match="evidence_refs"):
        catalog.validate(assessment)


def test_complete_whole_vehicle_snapshot_validates_all_contract_refs() -> None:
    catalog = ContractCatalog.load()
    systems = [
        "ENGINE", "ENGINE_COOLING", "ENGINE_LUBRICATION", "FUEL_AND_INDUCTION",
        "IGNITION_EMISSIONS_EXHAUST", "TRANSMISSION", "TRANSFER_CASE",
        "FRONT_DIFFERENTIAL", "REAR_DIFFERENTIAL", "DRIVESHAFT_AND_AXLES",
        "STARTING_CHARGING_BATTERY", "HVAC_AND_AC", "BRAKES", "STEERING",
        "FRONT_SUSPENSION", "REAR_SUSPENSION", "WHEELS_AND_TIRES",
        "BODY_FRAME_AND_CORROSION", "LIGHTING_AND_VISIBILITY", "SAFETY_RESTRAINTS",
        "CABIN_CONTROLS_AND_ACCESSORIES", "FLUIDS_HOSES_BELTS_AND_LEAKS",
    ]
    snapshot = {
        "contract": "vehicle.digital-twin.snapshot",
        "contract_version": "1.0.0",
        "snapshot_id": "fd1fc553-c713-4d69-81ca-a0f871fb9d18",
        "exported_at": "2026-08-18T12:00:00Z",
        "database_version": 2,
        "head_unit_inventory": {
            "contract": "platform.head-unit-inventory",
            "contract_version": "1.0.0",
            "inventory_id": "ee6c1f0a-e718-4931-8510-c6f0c37ef6a8",
            "captured_at": "2026-08-18T12:00:00Z",
            "application": {
                "package_id": "dev.vhos.headunit",
                "version_name": "0.1.0-dev.7",
                "version_code": 7,
                "installer_package": None,
            },
            "hardware": {
                "manufacturer": "unknown-manufacturer",
                "model": "Q91-A4-CPL",
                "device": "head-unit",
                "product": "head-unit",
                "board": "unknown-board",
                "hardware": "unknown-hardware",
                "cpu_descriptor": None,
                "supported_abis": ["armeabi-v7a"],
                "logical_cpu_count": 4,
                "total_ram_bytes": 2_147_483_648,
                "available_ram_bytes": 1_073_741_824,
                "total_internal_storage_bytes": 32_000_000_000,
                "free_internal_storage_bytes": 16_000_000_000,
                "low_ram_device": False,
            },
            "android": {
                "release": "13",
                "api_level": 33,
                "security_patch": "2020-02-01",
                "build_fingerprint": "vendor/product/device:13/build:user/release-keys",
            },
            "display": {
                "width_pixels": 1024,
                "height_pixels": 600,
                "density_dpi": 160,
                "width_dp": 1024,
                "height_dp": 600,
            },
            "capabilities": {
                "ble_feature": True,
                "bluetooth_scan_permission": "GRANTED",
                "bluetooth_connect_permission": "GRANTED",
                "notification_permission": "GRANTED",
                "unknown_source_install": "ALLOWED",
                "battery_optimization_exempt": False,
            },
        },
        "vehicle_profile": _profile(),
        "health_assessments": [
            {
                "contract": "vehicle.health-assessment",
                "contract_version": "1.0.0",
                "assessment_id": str(UUID(int=index + 1)),
                "supersedes_assessment_id": None,
                "profile_revision_id": _profile()["revision_id"],
                "system_id": system,
                "state": "UNKNOWN",
                "basis": "UNKNOWN",
                "recorded_at": "2026-08-18T12:00:00Z",
                "summary": f"No qualifying evidence has established {system.lower()} condition.",
                "evidence_refs": [],
                "equation_definition_id": None,
                "equation_version": None,
                "confidence": None,
            }
            for index, system in enumerate(systems)
        ],
    }

    catalog.validate(snapshot)
