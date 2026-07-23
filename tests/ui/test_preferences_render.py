"""Preferences dialog renders with non-trivial pixel content (docs §4)."""

from __future__ import annotations

import os
import shutil
import subprocess

import pytest

pytestmark = pytest.mark.ui


def test_preferences_render_pixel_sample(
    kaki_bin, schema_dir, xdg_home, xvfb, tmp_path
):
    if shutil.which("import") is None:
        pytest.skip("ImageMagick import not installed")

    try:
        from PIL import Image
    except ImportError:
        pytest.skip("Pillow not installed")

    shot = tmp_path / "preferences.png"
    env = os.environ.copy()
    env["GSETTINGS_SCHEMA_DIR"] = str(schema_dir)
    env["HOME"] = str(xdg_home)
    env["XDG_DATA_HOME"] = str(xdg_home / ".local" / "share")
    env["XDG_CONFIG_HOME"] = str(xdg_home / ".config")
    env["GDK_BACKEND"] = "x11"
    env["GTK_A11Y"] = "none"

    script = f"""
set -e
{kaki_bin} > /dev/null 2>&1 &
APP_PID=$!
sleep 3
xdotool key ctrl+comma
sleep 2
import -window root {shot}
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
    assert shot.is_file(), "screenshot was not written"

    img = Image.open(shot).convert("RGB")
    unique = len(set(img.get_flattened_data()))
    # Main window alone is ~275 colors; preferences open should be richer.
    assert unique >= 100, f"too few unique colors ({unique}); dialog may be blank"

    # Sample a content-area pixel; should not be pure black (uninitialized)
    # or pure white flat fill only — accept any non-extreme mid tone or lit UI.
    w, h = img.size
    px = img.getpixel((w // 2, int(h * 0.4)))
    assert px != (0, 0, 0), f"content pixel is pure black: {px}"