.PHONY: install verify simulate clean-build

VENV := .venv
PYTHON := $(VENV)/bin/python
VHOS := $(VENV)/bin/vhos

install:
	python3 -m venv $(VENV)
	$(PYTHON) -m pip install -e './tooling[test]'

verify:
	$(VHOS) contracts check
	$(PYTHON) -m pytest

simulate:
	$(VHOS) simulate --scenario cold-start-idle --output build/captures/cold-start-idle --replace
	$(VHOS) validate-bundle build/captures/cold-start-idle
	$(VHOS) replay build/captures/cold-start-idle --output build/captures/cold-start-idle/replay/signals.ndjson

clean-build:
	python3 -c 'from pathlib import Path; import shutil; target=Path("build").resolve(); assert target.name == "build"; shutil.rmtree(target, ignore_errors=True)'
