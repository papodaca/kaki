"""Multipart POST contract matching Preferences Test connection (docs §8)."""

from __future__ import annotations

import requests


def test_multipart_fields_and_auth_header(http_server, source_root):
    wav_path = source_root / "src" / "ui" / "test-sample.wav"
    wav = wav_path.read_bytes()

    def assert_post(entry):
        body = entry["body"]
        for needle in (
            b'name="file"',
            b'name="model"',
            b'name="response_format"',
            b'name="temperature"',
            b'filename="sample.wav"',
            b"audio/wav",
        ):
            assert needle in body, f"missing {needle!r} in multipart body"
        assert entry["headers"].get("Authorization") == "Bearer test-key-123"

    http_server.configure(post_assert=assert_post, post_body=b'{"text":"hello"}')

    files = {"file": ("sample.wav", wav, "audio/wav")}
    data = {
        "model": "whisper-1",
        "response_format": "json",
        "temperature": "0.0",
    }
    response = requests.post(
        http_server.url,
        files=files,
        data=data,
        headers={"Authorization": "Bearer test-key-123"},
        timeout=10,
    )
    assert response.status_code == 200
    assert response.content == b'{"text":"hello"}'
    assert any(e["method"] == "POST" for e in http_server.log)
