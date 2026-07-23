"""HuggingFace catalog URLs still resolve (docs/testing.md §5)."""

from __future__ import annotations

import requests
import pytest

pytestmark = pytest.mark.network

HF_URLS = [
    "https://huggingface.co/handy-computer/whisper-tiny.en-gguf/resolve/main/whisper-tiny.en-Q8_0.gguf",
    "https://huggingface.co/handy-computer/whisper-base.en-gguf/resolve/main/whisper-base.en-Q8_0.gguf",
    "https://huggingface.co/handy-computer/whisper-small.en-gguf/resolve/main/whisper-small.en-Q8_0.gguf",
]


@pytest.mark.parametrize("url", HF_URLS)
def test_hf_catalog_url_head_ok(url):
    response = requests.head(url, allow_redirects=True, timeout=30)
    assert response.status_code == 200, f"{url} → {response.status_code}"
