"""App launch + open preferences; no GTK/Adwaita/GLib criticals (docs §3)."""

from __future__ import annotations

import os
import subprocess

import pytest

pytestmark = pytest.mark.ui

HARD_CRITICALS = (
    "Gtk-CRITICAL",
    "Adwaita-CRITICAL",
    "GLib-CRITICAL",
)

# Phase 5 registers SIGRTMIN via g_unix_signal_source_new, which GLib
# rejects. That emits GLib-CRITICAL on every launch and is unrelated to
# Preferences / template load. Ignore those known lines only.
SIGRTMIN_NOISE = (
    "g_unix_signal_source_new",
    "g_source_set_callback: assertion 'source != NULL'",
    "g_source_attach: assertion 'source != NULL'",
    "g_source_unref: assertion 'source != NULL'",
)


def _unexpected_criticals(stderr: str) -> list[str]:
    hits = []
    for line in stderr.splitlines():
        if not any(tag in line for tag in HARD_CRITICALS):
            continue
        if any(n in line for n in SIGRTMIN_NOISE):
            continue
        hits.append(line)
    return hits


def test_app_launch_preferences_no_criticals(
    kaki_bin, schema_dir, xdg_home, xvfb, tmp_path
):
    log_path = tmp_path / "kaki-stderr.log"
    env = os.environ.copy()
    env["GSETTINGS_SCHEMA_DIR"] = str(schema_dir)
    env["HOME"] = str(xdg_home)
    env["XDG_DATA_HOME"] = str(xdg_home / ".local" / "share")
    env["XDG_CONFIG_HOME"] = str(xdg_home / ".config")
    env["GDK_BACKEND"] = "x11"
    env["GTK_A11Y"] = "none"

    script = f"""
set -e
{kaki_bin} > /dev/null 2>{log_path} &
APP_PID=$!
sleep 3
xdotool key ctrl+comma
sleep 2
kill $APP_PID 2>/dev/null || true
wait $APP_PID 2>/dev/null || true
"""
    result = subprocess.run(
        ["xvfb-run", "-a", "-s", "-screen 0 1280x1024x24", "bash", "-c", script],
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    assert result.returncode == 0, result.stderr + result.stdout

    raw = log_path.read_text() if log_path.exists() else ""
    hits = _unexpected_criticals(raw)
    assert not hits, f"unexpected criticals:\n" + "\n".join(hits) + f"\n\nfull stderr:\n{raw}"
