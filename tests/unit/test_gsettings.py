"""GSettings schema: keys exist and round-trip (docs/testing.md §1)."""

from __future__ import annotations

import os
import shutil
import subprocess
import textwrap

EXPECTED_DEFAULTS = {
    "gpu-backend": "'auto'",
    "shortcut-record": "'<Control>R'",
    "api-temperature": "0.0",
    "transcription-source": "'local'",
    "api-model": "'whisper-1'",
    "api-response-format": "'json'",
    "use-streaming": "true",
    "language": "'auto'",
    "cpu-threads": "4",
}


def _gsettings_env(schema_dir) -> dict:
    """Isolate from the real user dconf DB."""
    home = schema_dir / "home"
    config = schema_dir / "config"
    data = schema_dir / "data"
    for d in (home, config / "dconf", data):
        d.mkdir(parents=True, exist_ok=True)

    profile = schema_dir / "dconf-profile"
    if not profile.exists():
        profile.write_text("user-db:user\n")

    env = os.environ.copy()
    env["GSETTINGS_SCHEMA_DIR"] = str(schema_dir)
    env["HOME"] = str(home)
    env["XDG_CONFIG_HOME"] = str(config)
    env["XDG_DATA_HOME"] = str(data)
    env["DCONF_PROFILE"] = str(profile)
    env.pop("DBUS_SESSION_BUS_ADDRESS", None)
    return env


def _run_isolated(schema_dir, script: str) -> str:
    """Run a shell script on a private session bus + throwaway dconf."""
    env = _gsettings_env(schema_dir)
    cmd = ["bash", "-c", script]
    if shutil.which("dbus-run-session"):
        cmd = ["dbus-run-session", "--", *cmd]
    result = subprocess.run(
        cmd,
        env=env,
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout.strip()


def test_list_recursively_contains_expected_keys(schema_dir):
    out = _run_isolated(schema_dir, "gsettings list-recursively org.kaki.app")
    lines = {line for line in out.splitlines() if line.strip()}
    for key, default in EXPECTED_DEFAULTS.items():
        needle = f"org.kaki.app {key} {default}"
        assert any(line == needle for line in lines), (
            f"missing or wrong default for {key}: expected {needle!r} in:\n{out}"
        )


def test_shortcut_record_round_trip(schema_dir):
    # set / get / reset must share one dconf session (one dbus-run-session).
    script = textwrap.dedent(
        """\
        set -e
        gsettings set org.kaki.app shortcut-record '<Control><Shift>R'
        echo -n "after-set="
        gsettings get org.kaki.app shortcut-record
        gsettings reset org.kaki.app shortcut-record
        echo -n "after-reset="
        gsettings get org.kaki.app shortcut-record
        """
    )
    out = _run_isolated(schema_dir, script)
    assert "after-set='<Control><Shift>R'" in out, out
    assert "after-reset='<Control>R'" in out, out
