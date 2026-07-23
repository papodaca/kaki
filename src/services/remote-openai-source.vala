/* remote-openai-source.vala
 *
 * Copyright 2026 Ethan
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Remote TranscriptionSource backed by an OpenAI-compatible
 * /v1/audio/transcriptions endpoint. Uses libsoup-3.0 to POST a
 * 16-bit PCM WAV (encoded from the recorder's F32LE samples) as
 * multipart/form-data, then parses the JSON / text response per the
 * `api-response-format` setting.
 *
 * OpenAI doesn't stream audio, so can_stream is false and the
 * stream_* methods throw NOT_SUPPORTED. The window dispatches to
 * batch-only for this source (record → accumulate → stop →
 * transcribe_batch), matching the existing non-streaming local path.
 *
 * Compatible servers
 * ------------------
 * Defaults to OpenAI (api.openai.com), but the endpoint, model, and
 * api_key are all configurable, so the same code path works against
 * any OpenAI-compatible server — llama.cpp's server, vLLM, etc. The
 * api_key is optional (some local servers don't require it); the
 * Authorization header is only attached when the key is non-empty.
 *
 * 16-bit PCM WAV
 * --------------
 * The recorder hands us 16 kHz mono F32LE. We convert to int16 with
 * clamping to [-1.0, 1.0] and write a standard 44-byte RIFF/WAVE/fmt/
 * data header. 16-bit PCM is universally accepted by OpenAI and
 * every OpenAI-compatible server we've seen; it also matches the
 * gresource-bundled test-sample.wav that the Preferences "Test
 * Connection" button POSTs, so the two code paths exercise the same
 * wire format.
 */

public class Kaki.RemoteOpenAISource : GLib.Object, TranscriptionSource {
    public bool can_stream { get { return false; } }

    // Configured by the window from GSettings before prepare() runs.
    public string endpoint { get; set; }
    public string model { get; set; }
    public string api_key { get; set; }
    public string response_format { get; set; }   // "json" | "text" | "verbose_json"
    public double temperature { get; set; }
    public bool translate { get; set; }

    // Reused across requests. libsoup-3.0 Session is thread-safe for
    // async sends; we only ever call it from the main thread here.
    private Soup.Session _session;

    // signals partial_text / final_text / error_occurred are inherited
    // from the TranscriptionSource interface. The remote backend only
    // ever returns final transcripts, so partial_text is not emitted;
    // error_occurred is reserved for out-of-band failures (none in the
    // current code — HTTP errors surface as throws from transcribe_batch).

    public RemoteOpenAISource () {
        _session = new Soup.Session ();
        _session.set_timeout (30);
    }

    /* ----------------------------------------------------------------- */
    /* prepare — config validation                                        */
    /* ----------------------------------------------------------------- */

    public async void prepare () throws GLib.Error {
        // The endpoint and model are the minimum for a successful POST.
        // api_key is intentionally NOT required: local OpenAI-compatible
        // servers (llama.cpp, vLLM without auth) accept anonymous requests,
        // and forcing a key would block those setups at startup.
        if (endpoint == null || endpoint == "")
            throw new IOError.FAILED (
                "No API endpoint configured. Set one in Preferences → API.");
        if (model == null || model == "")
            throw new IOError.FAILED (
                "No API model configured. Set one in Preferences → API.");
    }

    /* ----------------------------------------------------------------- */
    /* transcribe_batch                                                   */
    /* ----------------------------------------------------------------- */

    public async string transcribe_batch (float[] samples,
                                           Cancellable? cancellable = null)
                                           throws GLib.Error {
        // 1. Encode the recorder's F32LE samples as a 16-bit PCM WAV.
        //    44-byte RIFF/WAVE/fmt/data header + little-endian int16 data.
        GLib.Bytes wav = encode_wav_pcm16 (samples, 16000, 1);

        // 2. Build the multipart/form-data body. Field names mirror the
        //    Preferences "Test Connection" path (preferences.vala::
        //    on_test_connection) so the two stay wire-compatible.
        var multipart = new Soup.Multipart ("multipart/form-data");
        multipart.append_form_file ("file", "audio.wav", "audio/wav", wav);
        multipart.append_form_string ("model", model);
        multipart.append_form_string ("response_format", response_format);
        if (temperature > 0)
            multipart.append_form_string ("temperature", temperature.to_string ());
        if (translate)
            multipart.append_form_string ("translate", "true");

        // 3. POST. Soup.Message.from_multipart wires the Content-Type
        //    header (multipart/form-data + boundary) from the multipart.
        var msg = new Soup.Message.from_multipart (endpoint, multipart);
        if (api_key != null && api_key.length > 0)
            msg.request_headers.append ("Authorization", "Bearer " + api_key);

        GLib.Bytes body = yield _session.send_and_read_async (
            msg, GLib.Priority.DEFAULT, cancellable);

        uint status = (uint) msg.get_status ();
        string reason = msg.get_reason_phrase () ?? "";
        if (status < 200 || status >= 300) {
            string body_text = (string) body.get_data ();
            string preview = body_text.length > 200
                ? body_text.substring (0, 200) : body_text;
            throw new IOError.FAILED (@"$status $reason: $preview");
        }

        // 4. Parse per response_format. OpenAI returns {"text": "..."}
        //    for json, a richer object for verbose_json (we still only
        //    need "text"), and the raw transcript for text.
        string body_text = (string) body.get_data ();
        if (response_format == "json" || response_format == "verbose_json") {
            string? parsed = extract_text_from_json (body_text);
            if (parsed != null)
                return parsed;
            // Malformed JSON or missing "text" — fall back to the raw
            // body so the user still sees something in the text view
            // rather than an empty string.
            warning ("Could not parse 'text' from API response; returning raw body");
            return body_text;
        }
        // response_format == "text" — body is the raw transcript.
        return body_text;
    }

    /* ----------------------------------------------------------------- */
    /* streaming — not supported                                          */
    /* ----------------------------------------------------------------- */

    public async void stream_begin (Cancellable? cancellable = null) throws GLib.Error {
        throw new IOError.NOT_SUPPORTED (
            "Remote OpenAI-compatible source does not support streaming");
    }

    public async void stream_feed (float[] chunk, Cancellable? cancellable = null) throws GLib.Error {
        throw new IOError.NOT_SUPPORTED (
            "Remote OpenAI-compatible source does not support streaming");
    }

    public async void stream_finalize (Cancellable? cancellable = null) throws GLib.Error {
        throw new IOError.NOT_SUPPORTED (
            "Remote OpenAI-compatible source does not support streaming");
    }

    /* ----------------------------------------------------------------- */
    /* WAV encoder — F32LE → 16-bit PCM                                    */
    /* ----------------------------------------------------------------- */

    // Build a 44-byte-header 16-bit PCM WAV from F32LE samples. The
    // recorder guarantees 16 kHz mono F32LE, but sample_rate and
    // channels are parameters so the helper stays self-contained.
    private static GLib.Bytes encode_wav_pcm16 (float[] samples,
                                                  int sample_rate,
                                                  int channels) {
        int n = (int) samples.length;
        int data_size = n * 2;  // 16-bit = 2 bytes per sample
        int total = 44 + data_size;
        var buf = new uint8[total];

        // RIFF chunk descriptor
        buf[0] = 'R'; buf[1] = 'I'; buf[2] = 'F'; buf[3] = 'F';
        write_le_u32 (buf, 4, (uint32) (36 + data_size));
        buf[8] = 'W'; buf[9] = 'A'; buf[10] = 'V'; buf[11] = 'E';

        // fmt subchunk (PCM, 16 bytes)
        buf[12] = 'f'; buf[13] = 'm'; buf[14] = 't'; buf[15] = ' ';
        write_le_u32 (buf, 16, 16);               // fmt chunk size
        write_le_u16 (buf, 20, 1);                // audio format: 1 = PCM
        write_le_u16 (buf, 22, (uint16) channels);
        write_le_u32 (buf, 24, (uint32) sample_rate);
        write_le_u32 (buf, 28, (uint32) (sample_rate * channels * 2));  // byte rate
        write_le_u16 (buf, 32, (uint16) (channels * 2));                // block align
        write_le_u16 (buf, 34, 16);               // bits per sample

        // data subchunk
        buf[36] = 'd'; buf[37] = 'a'; buf[38] = 't'; buf[39] = 'a';
        write_le_u32 (buf, 40, (uint32) data_size);

        // PCM samples: F32LE → int16 LE with clamping to [-1.0, 1.0].
        // Writing the two bytes explicitly (rather than Memory.copy of
        // an int16[]) keeps the byte order portable regardless of host
        // endianness.
        for (int i = 0; i < n; i++) {
            float s = samples[i];
            if (s > 1.0f) s = 1.0f;
            else if (s < -1.0f) s = -1.0f;
            int16 v = (int16) (s * 32767.0f);
            buf[44 + i * 2]     = (uint8) (v & 0xFF);
            buf[44 + i * 2 + 1] = (uint8) ((v >> 8) & 0xFF);
        }

        return new GLib.Bytes (buf);
    }

    private static void write_le_u32 (uint8[] buf, int offset, uint32 val) {
        buf[offset]     = (uint8) (val & 0xFF);
        buf[offset + 1] = (uint8) ((val >> 8) & 0xFF);
        buf[offset + 2] = (uint8) ((val >> 16) & 0xFF);
        buf[offset + 3] = (uint8) ((val >> 24) & 0xFF);
    }

    private static void write_le_u16 (uint8[] buf, int offset, uint16 val) {
        buf[offset]     = (uint8) (val & 0xFF);
        buf[offset + 1] = (uint8) ((val >> 8) & 0xFF);
    }

    /* ----------------------------------------------------------------- */
    /* JSON response parsing                                              */
    /* ----------------------------------------------------------------- */

    // Extract the "text" string from a JSON object. Returns null if the
    // body isn't valid JSON, isn't an object, or lacks a "text" string
    // member — the caller falls back to the raw body in that case.
    private static string? extract_text_from_json (string body) {
        var parser = new Json.Parser ();
        try {
            parser.load_from_data (body, -1);
            unowned Json.Node? root = parser.get_root ();
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT)
                return null;
            unowned Json.Object obj = root.get_object ();
            if (obj == null || !obj.has_member ("text"))
                return null;
            return obj.get_string_member ("text");
        } catch (GLib.Error e) {
            return null;
        }
    }
}
