"""Bundled test-sample.wav shape (docs/testing.md §7)."""

from __future__ import annotations

import wave


def test_test_sample_wav_is_silent_16khz_mono(source_root):
    path = source_root / "src" / "ui" / "test-sample.wav"
    with wave.open(str(path), "rb") as wf:
        assert wf.getnchannels() == 1
        assert wf.getframerate() == 16000
        assert wf.getnframes() == 1600
        assert wf.getsampwidth() * 8 == 16
        frames = wf.readframes(wf.getnframes())
    assert sum(1 for b in frames if b != 0) == 0
