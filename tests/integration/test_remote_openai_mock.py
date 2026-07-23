"""RemoteOpenAISource against a mock /v1/audio/transcriptions endpoint."""

from __future__ import annotations

import subprocess


def test_remote_openai_parses_json_text(http_server, remote_cli):
    seen = {}

    def assert_post(entry):
        seen["auth"] = entry["headers"].get("Authorization")
        body = entry["body"]
        assert b'name="file"' in body
        assert b"audio/wav" in body
        assert b'name="model"' in body
        assert b'name="response_format"' in body

    http_server.configure(
        post_body=b'{"text":"hello"}',
        post_assert=assert_post,
    )

    endpoint = f"{http_server.url}/v1/audio/transcriptions"
    result = subprocess.run(
        [str(remote_cli), endpoint, "whisper-1", "test-key-123"],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "hello"
    assert seen.get("auth") == "Bearer test-key-123"
