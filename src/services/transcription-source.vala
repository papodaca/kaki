/* transcription-source.vala
 *
 * Copyright 2026 Ethan
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Abstraction over the transcription backend so the recorder / window
 * can drive either the local transcribe.cpp engine (LocalSource from
 * Phase 2) or a remote OpenAI-compatible /v1/audio/transcriptions
 * endpoint (RemoteOpenAISource from Phase 6), selected by the
 * `transcription-source` GSettings key.
 *
 * Sample representation
 * ---------------------
 * All sample-carrying methods take float[] in the recorder's native
 * F32LE / 16 kHz / mono layout. LocalSource forwards the floats
 * straight to the C runtime; RemoteOpenAISource converts to 16-bit
 * PCM internally when encoding the WAV. Keeping float[] at this
 * boundary avoids a per-chunk Memory.copy on the local hot path.
 *
 * Streaming contract
 * ------------------
 * can_stream is false for the remote source (OpenAI doesn't stream
 * audio). Callers must check can_stream before invoking stream_begin
 * / feed / finalize; the remote implementations throw NOT_SUPPORTED
 * on those methods so a missing check surfaces immediately rather
 * than silently no-op'ing.
 *
 * prepare ()
 * ---------
 * Uniform async initialization called once after construction and
 * property setup. LocalSource reads the user-configured model-path
 * (with a ~/.local/share/kaki/models/ fallback scan) and loads the
 * model; RemoteOpenAISource validates endpoint + model. Throws on
 * failure — the caller switches its UI to an error/empty state.
 *
 * Signals
 * -------
 * partial_text / final_text fire on the GLib main thread for both
 * backends (LocalSource resumes its worker threads via Idle.add,
 * RemoteOpenAISource runs entirely on the main thread). error_occurred
 * is emitted for runtime failures (load_failed was the Phase 2 name;
 * the interface renames it for symmetry across backends).
 */

public interface Kaki.TranscriptionSource : GLib.Object {
    public abstract bool can_stream { get; }

    public signal void partial_text (string text);
    public signal void final_text (string text);
    public signal void error_occurred (string message);

    public abstract async void prepare () throws GLib.Error;
    public abstract async string transcribe_batch (float[] samples,
                                                    Cancellable? cancellable = null)
                                                    throws GLib.Error;
    public abstract async void stream_begin  (Cancellable? cancellable = null)
                                                throws GLib.Error;
    public abstract async void stream_feed   (float[] chunk,
                                                Cancellable? cancellable = null)
                                                throws GLib.Error;
    public abstract async void stream_finalize (Cancellable? cancellable = null)
                                                throws GLib.Error;
}
