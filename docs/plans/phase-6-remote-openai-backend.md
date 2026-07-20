# Phase 6 — OpenAI-compatible remote backend

## Goal

Add a `TranscriptionSource` abstraction so the recorder feeds either
the local transcribe.cpp engine or a remote OpenAI-compatible
`/v1/audio/transcriptions` endpoint, based on the
`transcription-source` setting.

Local source comes from Phase 2. This phase adds the remote source
and the dispatch logic.

## Files to create

### `src/services/transcription-source.vala`

```vala
public interface Kaki.TranscriptionSource : GLib.Object {
    public abstract bool can_stream { get; }

    public signal void partial_text (string text);
    public signal void final_text (string text);
    public signal void error_occurred (string message);

    public abstract async void prepare () throws GLib.Error;
    public abstract async string transcribe_batch (uint8[] samples_f32, int n_samples,
                                                    Cancellable? cancellable = null)
                                                    throws GLib.Error;
    public abstract async void stream_begin  (Cancellable? cancellable = null);
    public abstract async void stream_feed   (uint8[] chunk, Cancellable? cancellable = null);
    public abstract async void stream_finalize (Cancellable? cancellable = null);
}
```

### `src/services/local-source.vala`

Refactor `Kaki.Transcriber` from Phase 2 into `Kaki.LocalSource`
implementing this interface. Keep `Kaki.Transcriber` as a thin alias
or deprecate it.

### `src/services/remote-openai-source.vala`

OpenAI-compatible remote source. Uses `libsoup-3.0` to POST a WAV
encoded from the F32LE samples.

```vala
public class Kaki.RemoteOpenAISource : GLib.Object, TranscriptionSource {
    public bool can_stream { get { return false; } }   // OpenAI doesn't stream audio
    public string endpoint { get; set; }
    public string model    { get; set; }
    public string api_key  { get; set; }
    public string response_format { get; set; }   // "json" | "text" | "verbose_json"
    public double temperature { get; set; }
    public bool translate    { get; set; }

    public async string transcribe_batch (uint8[] samples_f32, int n_samples,
                                          Cancellable? cancellable = null)
                                          throws GLib.Error {
        // 1. Encode samples_f32 → WAV (16 kHz mono F32LE wrapped in RIFF)
        var wav = encode_wav(samples_f32, n_samples, 16000, 1, 32);

        // 2. Build multipart form
        var multipart = new Soup.Multipart (Soup.FORM_MIME_TYPE_MULTIPART);
        multipart.append_form_file ("file", "audio.wav", "audio/wav", new Bytes(wav));
        multipart.append_form_string ("model", model);
        multipart.append_form_string ("response_format", response_format);
        if (temperature > 0) multipart.append_form_string ("temperature", temperature.to_string());
        if (translate)        multipart.append_form_string ("translate", "true");

        // 3. POST
        var msg = new Soup.Message.from_uri ("POST", Uri.parse(endpoint));
        msg.request_headers.append("Authorization", "Bearer " + api_key);
        soup_session_set_request_body_from_multipart(session, msg, multipart);

        var stream = yield session.send_async (msg, cancellable, Priority.DEFAULT);
        // read to end, parse JSON or text per response_format
        // return transcript string
    }
}
```

WAV encoding: write RIFF/WAVE/fmt/data chunks. 60-byte header + raw
F32LE data. Or use GStreamer's `wavenc` via a `appsink → wavenc →
appsink` pipeline — slightly more work, reuses GStreamer. For Phase 6
the manual RIFF writer is simpler and dependency-free.

### `src/ui/window.vala` dispatch update

At startup, read `transcription-source`:

```vala
Kaki.TranscriptionSource source;
if (settings.get_string("transcription-source") == "api") {
    source = new Kaki.RemoteOpenAISource ();
    source.endpoint = settings.get_string("api-endpoint");
    source.model    = settings.get_string("api-model");
    source.api_key  = yield Kaki.SecretStore.get_api_key ();
    // ...
} else {
    source = new Kaki.LocalSource ();
}
source.prepare.begin ();
```

`recorder.chunk_ready` and `win.record`/`win.stop` call `source.*`
instead of `transcriber.*`. Streaming path only triggers when
`source.can_stream` is true; otherwise we run batch on stop.

## GSchema additions

Already added in Phase 4 (`transcription-source`, `api-endpoint`,
`api-model`, `api-response-format`, `api-temperature`, `api-translate`).

## Verification

1. In Preferences → API, set transcription source to "OpenAI-compatible
   API" and ensure API key is in libsecret.
2. Test Connection button (Phase 4) should already POST successfully.
3. Record a 5 s clip → Stop → transcript appears in the text view.
4. Inspect `~/.cache/kaki/last-request.json` (optional debug log) to
   confirm the multipart body has `model`, `file`, `response_format`.
5. Switch back to "Local model" → confirm local transcribe.cpp path
   still works unchanged.
6. Test with a non-OpenAI endpoint (e.g. a local llama.cpp server
   exposing `/v1/audio/transcriptions`) by changing `api-endpoint`.
7. Error path: invalid key → toast shows "401 Unauthorized".

## Commit

```
Phase 6: OpenAI-compatible remote transcription backend

- src/services/transcription-source.vala: interface with batch + streaming
- src/services/local-source.vala: refactored Phase 2 transcriber
- src/services/remote-openai-source.vala: libsoup-3.0 multipart POST to
  /v1/audio/transcriptions with WAV-encoded samples
- src/ui/window.vala: dispatch source based on transcription-source setting
- Supports OpenAI and OpenAI-compatible servers (llama.cpp, etc.)
```
