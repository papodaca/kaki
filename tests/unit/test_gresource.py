"""gresource paths baked into the kaki binary (docs/testing.md §9)."""

from __future__ import annotations

import subprocess


EXPECTED_PATHS = [
    "/org/kaki/app/preferences.ui",
    "/org/kaki/app/shortcuts-dialog.ui",
    "/org/kaki/app/test-sample.wav",
    "/org/kaki/app/window.ui",
]


def test_gresource_paths_in_binary(kaki_bin):
    result = subprocess.run(
        ["strings", str(kaki_bin)],
        capture_output=True,
        text=True,
        check=True,
    )
    lines = set(result.stdout.splitlines())
    missing = [p for p in EXPECTED_PATHS if p not in lines]
    assert not missing, f"missing gresource paths in {kaki_bin}: {missing}"
