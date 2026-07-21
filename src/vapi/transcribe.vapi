/* transcribe.vapi
 *
 * Hand-written Vala binding for the public C API of transcribe.cpp
 * (subprojects/transcribe.cpp, v0.1.2). Bindings cover the subset Kaki
 * needs through Phase 2-4: status, version, logging, model load/free,
 * session init/free, run, single-result accessors, per-row segment /
 * word / token copy-out, capabilities, and the feature probe.
 *
 * Streaming, batch run, family extensions, the backend-device struct,
 * timings, and the convenience one-shot opener are intentionally NOT
 * bound here; they will be added when the phase that needs them lands.
 *
 * The bound names track include/transcribe.h verbatim:
 *   - transcribe_model_load_file   (NOT transcribe_model_load)
 *   - transcribe_session_init      (NOT transcribe_session_new)
 *   - transcribe_run takes const float * pcm, int n_samples
 *
 * ABI note: every caller-owned struct has uint64_t struct_size as
 * field 0 and MUST be initialized via its transcribe_*_init()
 * constructor before use. {0} is rejected with BAD_STRUCT_SIZE.
 */
[CCode (cprefix = "", lower_case_cprefix = "", cheader_filename = "transcribe.h")]
namespace Transcribe {

    /* ----------------------------------------------------------------- */
    /* Status                                                            */
    /* ----------------------------------------------------------------- */

    [CCode (cname = "transcribe_status", cprefix = "TRANSCRIBE_", has_type_id = false)]
    public enum Status {
        OK = 0,
        ERR_INVALID_ARG = 1,
        ERR_NOT_IMPLEMENTED = 2,
        ERR_FILE_NOT_FOUND = 3,
        ERR_GGUF = 4,
        ERR_UNSUPPORTED_ARCH = 5,
        ERR_UNSUPPORTED_VARIANT = 6,
        ERR_OOM = 7,
        ERR_BACKEND = 8,
        ERR_SAMPLE_RATE = 9,
        ERR_UNSUPPORTED_LANGUAGE = 10,
        ERR_UNSUPPORTED_TASK = 11,
        ERR_UNSUPPORTED_TIMESTAMPS = 12,
        ERR_ABORTED = 13,
        ERR_BAD_STRUCT_SIZE = 14,
        ERR_UNSUPPORTED_PNC = 15,
        ERR_UNSUPPORTED_ITN = 16,
        ERR_INPUT_TOO_LONG = 17,
        ERR_OUTPUT_TRUNCATED = 18,
    }

    [CCode (cname = "transcribe_status_string")]
    public unowned string status_string (int status);

    /* ----------------------------------------------------------------- */
    /* Version                                                           */
    /* ----------------------------------------------------------------- */

    [CCode (cname = "transcribe_version")]
    public unowned string version ();
    [CCode (cname = "transcribe_version_commit")]
    public unowned string version_commit ();

    /* ----------------------------------------------------------------- */
    /* Logging                                                           */
    /* ----------------------------------------------------------------- */

    [CCode (cname = "transcribe_log_level", cprefix = "TRANSCRIBE_LOG_LEVEL_", has_type_id = false)]
    public enum LogLevel {
        NONE = 0,
        INFO = 1,
        WARN = 2,
        ERROR = 3,
        DEBUG = 4,
        CONT = 5,
    }

    [CCode (cname = "transcribe_log_callback", instance_pos = -1)]
    public delegate void LogCallback (LogLevel level, string msg);

    [CCode (cname = "transcribe_log_set")]
    public void log_set (LogCallback? cb, void * userdata);

    /* ----------------------------------------------------------------- */
    /* Enums                                                             */
    /* ----------------------------------------------------------------- */

    [CCode (cname = "transcribe_task", cprefix = "TRANSCRIBE_TASK_", has_type_id = false)]
    public enum Task {
        TRANSCRIBE = 0,
        TRANSLATE = 1,
    }

    [CCode (cname = "transcribe_timestamp_kind", cprefix = "TRANSCRIBE_TIMESTAMPS_", has_type_id = false)]
    public enum TimestampKind {
        NONE = 0,
        AUTO = 1,
        SEGMENT = 2,
        WORD = 3,
        TOKEN = 4,
    }

    [CCode (cname = "transcribe_kv_type", cprefix = "TRANSCRIBE_KV_TYPE_", has_type_id = false)]
    public enum KvType {
        AUTO = 0,
        F32 = 1,
        F16 = 2,
    }

    [CCode (cname = "transcribe_pnc_mode", cprefix = "TRANSCRIBE_PNC_MODE_", has_type_id = false)]
    public enum PncMode {
        DEFAULT = 0,
        OFF = 1,
        ON = 2,
    }

    [CCode (cname = "transcribe_itn_mode", cprefix = "TRANSCRIBE_ITN_MODE_", has_type_id = false)]
    public enum ItnMode {
        DEFAULT = 0,
        OFF = 1,
        ON = 2,
    }

    [CCode (cname = "transcribe_backend_request", cprefix = "TRANSCRIBE_BACKEND_", has_type_id = false)]
    public enum BackendRequest {
        AUTO = 0,
        CPU = 1,
        METAL = 2,
        VULKAN = 3,
        CPU_ACCEL = 4,
        CUDA = 5,
    }

    [CCode (cname = "transcribe_feature", cprefix = "TRANSCRIBE_FEATURE_", has_type_id = false)]
    public enum Feature {
        INITIAL_PROMPT = 0,
        TEMPERATURE_FALLBACK = 1,
        LONG_FORM = 2,
        CANCELLATION = 3,
        PNC = 4,
        ITN = 5,
    }

    /* ----------------------------------------------------------------- */
    /* Params                                                            */
    /* ----------------------------------------------------------------- */

    [CCode (cname = "struct transcribe_model_load_params", has_type_id = false)]
    public struct ModelLoadParams {
        public size_t struct_size;
        public BackendRequest backend;
        public int gpu_device;

        [CCode (cname = "transcribe_model_load_params_init")]
        public ModelLoadParams ();
    }

    [CCode (cname = "struct transcribe_session_params", has_type_id = false)]
    public struct SessionParams {
        public size_t struct_size;
        public int n_threads;
        public KvType kv_type;
        public int32 n_ctx;

        [CCode (cname = "transcribe_session_params_init")]
        public SessionParams ();
    }

    [CCode (cname = "struct transcribe_run_params", has_type_id = false)]
    public struct RunParams {
        public size_t                 struct_size;
        public Task                   task;
        public TimestampKind          timestamps;
        public PncMode                 pnc;
        public ItnMode                 itn;
        public unowned string?        language;
        public unowned string?        target_language;
        public bool                    keep_special_tags;
        public void *                  family;        /* const struct transcribe_ext * — opaque, not bound in Phase 1 */
        public int32                   spec_k_drafts;

        [CCode (cname = "transcribe_run_params_init")]
        public RunParams ();
    }

    /* ----------------------------------------------------------------- */
    /* Capabilities                                                      */
    /* ----------------------------------------------------------------- */

    [CCode (cname = "struct transcribe_capabilities", has_type_id = false)]
    public struct Capabilities {
        public size_t          struct_size;
        public int32           native_sample_rate;
        public int             n_languages;
        [CCode (array_length = false, null_terminated = true)]
        public unowned string[] languages;
        public TimestampKind   max_timestamp_kind;
        public bool             supports_language_detect;
        public bool             supports_translate;
        public bool             supports_streaming;
        public bool             supports_spec_decode;
        public int64            max_audio_ms;
        public int              n_translate_target_languages;
        [CCode (array_length = false, null_terminated = true)]
        public unowned string[] translate_target_languages;

        [CCode (cname = "transcribe_capabilities_init")]
        public Capabilities ();
    }

    /* ----------------------------------------------------------------- */
    /* Result rows                                                       */
    /* ----------------------------------------------------------------- */

    [CCode (cname = "struct transcribe_segment", has_type_id = false)]
    public struct Segment {
        public size_t   struct_size;
        public int64    t0_ms;
        public int64    t1_ms;
        public int      first_word;
        public int      n_words;
        public int      first_token;
        public int      n_tokens;
        public unowned string text;

        [CCode (cname = "transcribe_segment_init")]
        public Segment ();
    }

    [CCode (cname = "struct transcribe_word", has_type_id = false)]
    public struct Word {
        public size_t   struct_size;
        public int64    t0_ms;
        public int64    t1_ms;
        public int      seg_index;
        public int      first_token;
        public int      n_tokens;
        public unowned string text;

        [CCode (cname = "transcribe_word_init")]
        public Word ();
    }

    [CCode (cname = "struct transcribe_token", has_type_id = false)]
    public struct Token {
        public size_t   struct_size;
        public int      id;
        public float    p;
        public int64    t0_ms;
        public int64    t1_ms;
        public int      seg_index;
        public int      word_index;
        public unowned string text;

        [CCode (cname = "transcribe_token_init")]
        public Token ();
    }

    /* ----------------------------------------------------------------- */
    /* Handles                                                           */
    /* ----------------------------------------------------------------- */

    [Compact]
    [CCode (cname = "struct transcribe_model", free_function = "transcribe_model_free", has_type_id = false)]
    public class Model {
        [CCode (cname = "transcribe_model_load_file")]
        public static Status load_file (string path, ModelLoadParams? params, out Model? out_model);

        [CCode (cname = "transcribe_model_get_capabilities")]
        public Status get_capabilities (ref Capabilities out_caps);

        [CCode (cname = "transcribe_model_supports")]
        public bool supports (Feature feature);
    }

    [Compact]
    [CCode (cname = "struct transcribe_session", free_function = "transcribe_session_free", has_type_id = false)]
    public class Session {
        [CCode (cname = "transcribe_session_init")]
        public static Status init (Model model, SessionParams? params, out Session? out_session);

        [CCode (cname = "transcribe_run", array_length_pos = 1.5)]
        public Status run (float[] pcm, RunParams? params);

        [CCode (cname = "transcribe_full_text")]
        public unowned string full_text ();

        [CCode (cname = "transcribe_detected_language")]
        public unowned string detected_language ();

        [CCode (cname = "transcribe_was_truncated")]
        public bool was_truncated ();

        [CCode (cname = "transcribe_returned_timestamp_kind")]
        public TimestampKind returned_timestamp_kind ();

        [CCode (cname = "transcribe_n_segments")]
        public int n_segments ();

        [CCode (cname = "transcribe_n_words")]
        public int n_words ();

        [CCode (cname = "transcribe_n_tokens")]
        public int n_tokens ();

        [CCode (cname = "transcribe_get_segment")]
        public Status get_segment (int i, ref Segment out);

        [CCode (cname = "transcribe_get_word")]
        public Status get_word (int i, ref Word out);

        [CCode (cname = "transcribe_get_token")]
        public Status get_token (int i, ref Token out);

        /* Streaming entry points (Phase 2). The `update` slot of
         * feed/finalize is nullable in C; we bind it as an opaque
         * pointer so callers pass null when they don't want the
         * per-call change metadata. */
        [CCode (cname = "transcribe_stream_begin")]
        public Status stream_begin (RunParams? run_params, StreamParams? stream_params);

        [CCode (cname = "transcribe_stream_feed", array_length_pos = 1.5)]
        public Status stream_feed (float[] pcm, void * update = null);

        [CCode (cname = "transcribe_stream_finalize")]
        public Status stream_finalize (void * update = null);

        [CCode (cname = "transcribe_stream_reset")]
        public void stream_reset ();

        [CCode (cname = "transcribe_stream_get_state")]
        public StreamState stream_get_state ();

        [CCode (cname = "transcribe_stream_revision")]
        public int stream_revision ();

        [CCode (cname = "transcribe_stream_last_status")]
        public Status stream_last_status ();

        /*
         * Pull the UI-facing text snapshot. The caller MUST initialize
         * `out_text` via StreamText () before calling (sets struct_size);
         * we use `ref` to honor that contract (vs `out` which would
         * zero the struct and trip BAD_STRUCT_SIZE).
         */
        [CCode (cname = "transcribe_stream_get_text")]
        public Status stream_get_text (ref StreamText out_text);

        /* Cancellation. Abort callback is polled on the run thread; a
         * return of true aborts the in-flight run/stream. */
        [CCode (cname = "transcribe_set_abort_callback")]
        public void set_abort_callback (AbortCallback? cb);

        [CCode (cname = "transcribe_was_aborted")]
        public bool was_aborted ();
    }

    /* ----------------------------------------------------------------- */
    /* Backend bootstrap (no-op for static builds; called once at startup) */
    /* ----------------------------------------------------------------- */

    [CCode (cname = "transcribe_init_backends_default")]
    public Status init_backends_default ();

    [CCode (cname = "transcribe_backend_device_count")]
    public int backend_device_count ();

    [CCode (cname = "transcribe_backend_available")]
    public bool backend_available (BackendRequest kind);

    /* ----------------------------------------------------------------- */
    /* Streaming + cancellation (added in Phase 2)                       */
    /* ----------------------------------------------------------------- */

    [CCode (cname = "transcribe_stream_state", cprefix = "TRANSCRIBE_STREAM_", has_type_id = false)]
    public enum StreamState {
        IDLE     = 0,
        ACTIVE   = 1,
        FINISHED = 2,
        FAILED   = 3,
    }

    [CCode (cname = "transcribe_stream_commit_policy", cprefix = "TRANSCRIBE_STREAM_COMMIT_", has_type_id = false)]
    public enum StreamCommitPolicy {
        AUTO          = 0,
        ON_FINALIZE   = 1,
        STABLE_PREFIX = 2,
    }

    /*
     * Streaming run params. Initialize via transcribe_stream_params_init()
     * before populating; struct_size MUST be set by the init function.
     * `family` is opaque here (Phase 2 uses library defaults → NULL).
     */
    [CCode (cname = "struct transcribe_stream_params", has_type_id = false)]
    public struct StreamParams {
        public size_t                struct_size;
        public void *                family;
        public StreamCommitPolicy    commit_policy;
        public uint32                stable_prefix_agreement_n;

        [CCode (cname = "transcribe_stream_params_init")]
        public StreamParams ();
    }

    /*
     * Per-call change metadata from feed/finalize. Nullable in the C
     * API (callers may pass NULL); we bind the update slot as an
     * opaque pointer so callers can ignore it by passing null.
     */
    [CCode (cname = "struct transcribe_stream_update", has_type_id = false)]
    public struct StreamUpdate {
        public size_t struct_size;
        public bool   result_changed;
        public bool   is_final;
        public int32  revision;
        public int64  input_received_ms;
        public int64  audio_committed_ms;
        public int64  buffered_ms;
        public bool   committed_changed;
        public bool   tentative_changed;

        [CCode (cname = "transcribe_stream_update_init")]
        public StreamUpdate ();
    }

    /*
     * UI-facing stream text snapshot. Borrowed pointers valid until
     * the next stream/feed/finalize/reset/run/free on the session.
     */
    [CCode (cname = "struct transcribe_stream_text", has_type_id = false)]
    public struct StreamText {
        public size_t        struct_size;
        public unowned string full_text;
        public uint64        full_text_bytes;
        public unowned string committed_text;
        public uint64        committed_text_bytes;
        public unowned string tentative_text;
        public uint64        tentative_text_bytes;
        public uint64        raw_tentative_start_bytes;

        [CCode (cname = "transcribe_stream_text_init")]
        public StreamText ();
    }

    /*
     * Abort callback. Has_target=true so Vala packages the delegate
     * target as the C user_data; the binding for
     * transcribe_set_abort_callback drops the explicit user_data arg.
     */
    [CCode (cname = "transcribe_abort_callback", has_target = true)]
    public delegate bool AbortCallback ();
}
