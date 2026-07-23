"""Shared fixtures for Kaki pytest suites."""

from __future__ import annotations

import http.server
import os
import shutil
import socketserver
import subprocess
import tempfile
import threading
from pathlib import Path

import pytest

SOURCE_ROOT = Path(
    os.environ.get("KAKI_SOURCE_ROOT", Path(__file__).resolve().parents[1])
)


def pytest_configure(config: pytest.Config) -> None:
    config.addinivalue_line("markers", "network: needs outbound HTTP")
    config.addinivalue_line("markers", "ui: needs Xvfb + xdotool")
    config.addinivalue_line("markers", "secret: needs gnome-keyring + secret-tool")


@pytest.fixture(scope="session")
def source_root() -> Path:
    return SOURCE_ROOT


@pytest.fixture(scope="session")
def kaki_bin() -> Path:
    env = os.environ.get("KAKI_BIN")
    if env:
        path = Path(env)
    else:
        path = SOURCE_ROOT / "build" / "src" / "kaki"
    if not path.is_file():
        pytest.skip(f"kaki binary not found at {path}")
    return path


@pytest.fixture(scope="session")
def download_cli() -> Path:
    env = os.environ.get("KAKI_DOWNLOAD_CLI")
    if env:
        path = Path(env)
    else:
        path = SOURCE_ROOT / "build" / "tests" / "helpers" / "kaki-download-cli"
    if not path.is_file():
        pytest.skip(f"kaki-download-cli not found at {path}")
    return path


@pytest.fixture(scope="session")
def remote_cli() -> Path:
    env = os.environ.get("KAKI_REMOTE_CLI")
    if env:
        path = Path(env)
    else:
        path = SOURCE_ROOT / "build" / "tests" / "helpers" / "kaki-remote-cli"
    if not path.is_file():
        pytest.skip(f"kaki-remote-cli not found at {path}")
    return path


@pytest.fixture
def schema_dir(tmp_path: Path, source_root: Path) -> Path:
    """Compile org.kaki.app.gschema.xml into a throwaway dir."""
    schema_src = source_root / "data" / "org.kaki.app.gschema.xml"
    dest = tmp_path / "schemas"
    dest.mkdir()
    shutil.copy(schema_src, dest / schema_src.name)
    subprocess.run(
        ["glib-compile-schemas", str(dest)],
        check=True,
        capture_output=True,
        text=True,
    )
    return dest


@pytest.fixture
def xdg_home(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Isolate HOME / XDG_* so models and dconf stay out of the real profile."""
    home = tmp_path / "home"
    data = home / ".local" / "share"
    config = home / ".config"
    cache = home / ".cache"
    runtime = tmp_path / "runtime"
    for d in (home, data, config, cache, runtime):
        d.mkdir(parents=True, exist_ok=True)

    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("XDG_DATA_HOME", str(data))
    monkeypatch.setenv("XDG_CONFIG_HOME", str(config))
    monkeypatch.setenv("XDG_CACHE_HOME", str(cache))
    monkeypatch.setenv("XDG_RUNTIME_DIR", str(runtime))
    return home


@pytest.fixture
def http_server():
    """Threaded loopback HTTP server; yields a small control object."""
    request_log: list[dict] = []
    state: dict = {
        "get_body": b"tiny-gguf-payload",
        "get_status": 200,
        "post_status": 200,
        "post_body": b'{"text":"hello"}',
        "post_assert": None,
    }

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            body = state["get_body"]
            request_log.append(
                {
                    "method": "GET",
                    "path": self.path,
                    "headers": dict(self.headers),
                }
            )
            self.send_response(state["get_status"])
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Content-Type", "application/octet-stream")
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):  # noqa: N802
            n = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(n)
            entry = {
                "method": "POST",
                "path": self.path,
                "headers": dict(self.headers),
                "body": body,
            }
            request_log.append(entry)
            assert_fn = state["post_assert"]
            if assert_fn is not None:
                assert_fn(entry)
            out = state["post_body"]
            self.send_response(state["post_status"])
            self.send_header("Content-Length", str(len(out)))
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(out)

        def log_message(self, *_args):
            pass

    httpd = socketserver.TCPServer(("127.0.0.1", 0), Handler)
    httpd.allow_reuse_address = True
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    host, port = httpd.server_address
    base_url = f"http://{host}:{port}"

    class Server:
        url = base_url
        log = request_log

        def configure(self, **kwargs):
            state.update(kwargs)

    try:
        yield Server()
    finally:
        httpd.shutdown()
        httpd.server_close()


@pytest.fixture(scope="session")
def keyring():
    """Start gnome-keyring-daemon in an isolated runtime dir when available."""
    if shutil.which("gnome-keyring-daemon") is None or shutil.which("secret-tool") is None:
        pytest.skip("gnome-keyring-daemon / secret-tool not installed")

    runtime = tempfile.mkdtemp(prefix="kaki-keyring-")
    env = os.environ.copy()
    env["XDG_RUNTIME_DIR"] = runtime
    env["HOME"] = runtime

    # Ensure a session bus exists for the daemon (CI / headless).
    if "DBUS_SESSION_BUS_ADDRESS" not in env and shutil.which("dbus-launch"):
        dbus = subprocess.run(
            ["dbus-launch", "--sh-syntax"],
            capture_output=True,
            text=True,
            check=False,
            env=env,
        )
        if dbus.returncode == 0:
            for line in dbus.stdout.splitlines():
                if "=" not in line:
                    continue
                # DBUS_SESSION_BUS_ADDRESS='…';
                line = line.strip().rstrip(";").removeprefix("export ")
                key, _, val = line.partition("=")
                env[key] = val.strip().strip("'\"")

    start = subprocess.run(
        ["gnome-keyring-daemon", "--start", "--components=secrets"],
        input="password\n",
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )
    if start.returncode != 0:
        shutil.rmtree(runtime, ignore_errors=True)
        pytest.skip(f"could not start gnome-keyring-daemon: {start.stderr or start.stdout}")

    exports = {}
    for line in start.stdout.splitlines():
        line = line.removeprefix("export ").strip().rstrip(";")
        if "=" not in line:
            continue
        key, _, val = line.partition("=")
        exports[key] = val.strip().strip("'\"")

    merged = {**env, **exports}
    yield {"env_updates": exports, "runtime": runtime, "base_env": merged}

    shutil.rmtree(runtime, ignore_errors=True)


@pytest.fixture
def xvfb():
    """Require Xvfb tooling for UI tests."""
    if shutil.which("xvfb-run") is None:
        pytest.skip("xvfb-run not installed")
    if shutil.which("xdotool") is None:
        pytest.skip("xdotool not installed")
    return True
