"""libsecret round-trip via secret-tool (docs/testing.md §6)."""

from __future__ import annotations

import os
import subprocess

import pytest

pytestmark = pytest.mark.secret


def _env(keyring) -> dict:
    env = keyring["base_env"].copy()
    env.update(keyring["env_updates"])
    return env


def _run(keyring, *args: str, input_text: str | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        list(args),
        input=input_text,
        capture_output=True,
        text=True,
        env=_env(keyring),
        check=False,
    )


def test_secret_store_lookup_search_clear(keyring):
    # Clear any leftover from a previous run in this keyring.
    _run(keyring, "secret-tool", "clear", "type", "api-key")

    store = _run(
        keyring,
        "secret-tool",
        "store",
        "--label=Kaki test",
        "type",
        "api-key",
        input_text="password123\n",
    )
    assert store.returncode == 0, store.stderr

    lookup = _run(keyring, "secret-tool", "lookup", "type", "api-key")
    assert lookup.returncode == 0, lookup.stderr
    assert lookup.stdout.strip() == "password123"

    search = _run(keyring, "secret-tool", "search", "--all", "type", "api-key")
    assert search.returncode == 0, search.stderr
    assert "password123" in search.stdout or "api-key" in search.stdout

    clear = _run(keyring, "secret-tool", "clear", "type", "api-key")
    assert clear.returncode == 0, clear.stderr

    after = _run(keyring, "secret-tool", "lookup", "type", "api-key")
    # secret-tool exits non-zero or prints empty when nothing matches.
    assert after.stdout.strip() == ""
