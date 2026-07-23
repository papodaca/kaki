"""ModelDownloader via kaki-download-cli: .part → rename, size match."""

from __future__ import annotations

from pathlib import Path


def test_model_downloader_atomic_rename(http_server, download_cli, tmp_path):
    payload = b"tiny-gguf-payload-for-kaki"
    http_server.configure(get_body=payload)

    dest = tmp_path / "model.gguf"
    part = Path(str(dest) + ".part")

    import subprocess

    result = subprocess.run(
        [str(download_cli), f"{http_server.url}/whisper-tiny.gguf", str(dest)],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert dest.is_file()
    assert dest.read_bytes() == payload
    assert not part.exists(), f"leftover .part file: {part}"
    assert any(e["method"] == "GET" for e in http_server.log)
