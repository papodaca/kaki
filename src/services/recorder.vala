/* recorder.vala
 *
 * Copyright 2026 Ethan
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * GStreamer pipeline that captures microphone audio and emits 16 kHz
 * mono F32LE chunks via the `chunk_ready` signal. Pipeline (B1):
 *
 *   pulsesrc (or pipewiresrc) ! audioconvert ! audioresample !
 *     capsfilter (audio/x-raw, rate=16000, channels=1, format=F32LE) !
 *     appsink (emit-signals=true, sync=false, drop=true, max-buffers=4)
 *
 * `chunk_ready` fires on the GStreamer streaming thread; consumers must
 * only do thread-safe work in their handler (the window pushes the chunk
 * to the TranscriptionSource, which is safe from any thread).
 */

using Gst;

public class Kaki.Recorder : GLib.Object {
    public bool is_recording { get; private set; default = false; }

    public signal void chunk_ready (float[] samples);
    public signal void recording_started ();
    public signal void recording_stopped ();
    public signal void error_occurred (string message);

    // Strong ref: the pipeline must outlive the start() call. A
    // `weak` field here let the local `pipeline` variable in start()
    // drop the only ref on return, disposing the pipeline while it
    // was still in PLAYING (the GStreamer criticals at startup).
    private Pipeline _pipeline;
    private App.Sink _appsink;

    private static bool _gst_inited = false;

    private static void ensure_gst_init () throws GLib.Error {
        if (_gst_inited)
            return;
        unowned string[]? args = null;
        Gst.init_check (ref args);
        _gst_inited = true;
    }

    public void start () throws GLib.Error {
        if (is_recording)
            return;

        ensure_gst_init ();

        var pipeline = new Pipeline ("kaki-recorder");
        _pipeline = pipeline;

        // Source: prefer pulsessrc, fall back to pipewiresrc.
        var src = ElementFactory.make ("pulsesrc", "src");
        if (src == null) {
            src = ElementFactory.make ("pipewiresrc", "src");
        }
        if (src == null) {
            throw new IOError.NOT_FOUND (
                "Neither pulsesrc nor pipewiresrc available; install pipewire-pulse or pulseaudio");
        }
        // 100 ms block hints (microseconds). PA/PW may still deliver
        // smaller buffers; the appsink emits per-buffer regardless.
        src.set_property ("buffer-time", (uint64) 100000);
        src.set_property ("latency-time", (uint64) 100000);

        var convert   = ElementFactory.make ("audioconvert",  "convert");
        var resample  = ElementFactory.make ("audioresample", "resample");
        var caps      = ElementFactory.make ("capsfilter",    "caps");
        caps.set_property ("caps",
            Caps.from_string ("audio/x-raw, rate=16000, channels=1, format=F32LE"));

        var sink = ElementFactory.make ("appsink", "sink");
        if (sink == null) {
            throw new IOError.NOT_FOUND ("appsink element unavailable");
        }
        sink.set_property ("emit-signals", true);
        sink.set_property ("sync", false);
        sink.set_property ("drop", true);
        sink.set_property ("max-buffers", 4);
        _appsink = (App.Sink) sink;
        _appsink.new_sample.connect (on_new_sample);

        pipeline.add_many (src, convert, resample, caps, sink);
        if (!src.link_many (convert, resample, caps, sink)) {
            pipeline.set_state (State.NULL);
            throw new IOError.FAILED ("Failed to link recorder pipeline");
        }

        var bus = pipeline.get_bus ();
        bus.add_watch (GLib.Priority.DEFAULT, on_bus_message);

        var ret = pipeline.set_state (State.PLAYING);
        if (ret == StateChangeReturn.FAILURE) {
            pipeline.set_state (State.NULL);
            throw new IOError.FAILED ("Failed to start recording pipeline");
        }

        is_recording = true;
        recording_started ();
    }

    public void stop () {
        if (!is_recording)
            return;
        // Send EOS; the bus handler transitions to NULL and emits
        // recording_stopped once all buffered chunks have drained.
        _pipeline.send_event (new Event.eos ());
    }

    public void cancel () {
        if (!is_recording)
            return;
        // Hard-stop: discard buffered audio and tear down immediately.
        _appsink.new_sample.disconnect (on_new_sample);
        _pipeline.set_state (State.NULL);
        is_recording = false;
        recording_stopped ();
    }

    public override void dispose () {
        // If a recording is still active when the Recorder (and its
        // owning Window) is destroyed, tear the pipeline down to NULL
        // before the strong ref drops. Otherwise Gst would dispose
        // it in PLAYING/PAUSED and emit the same criticals we saw
        // when the field was weak.
        if (_pipeline != null) {
            if (_appsink != null) {
                _appsink.new_sample.disconnect (on_new_sample);
            }
            _pipeline.set_state (Gst.State.NULL);
            _pipeline = null;
        }
        base.dispose ();
    }

    private FlowReturn on_new_sample (App.Sink sink) {
        var sample = sink.pull_sample ();
        if (sample == null)
            return FlowReturn.OK;

        var buffer = sample.get_buffer ();
        if (buffer == null)
            return FlowReturn.OK;

        MapInfo info;
        if (!buffer.map (out info, MapFlags.READ))
            return FlowReturn.OK;

        size_t n_bytes = info.size;
        int   n_samples = (int) (n_bytes / sizeof (float));
        if (n_samples > 0) {
            // Copy into a freshly-allocated float[] we own. The map
            // is released before emit so the consumer can outlive the
            // GStreamer buffer.
            var samples = new float[n_samples];
            GLib.Memory.copy (samples, info.data, n_bytes);
            buffer.unmap (info);
            chunk_ready (samples);
        } else {
            buffer.unmap (info);
        }

        return FlowReturn.OK;
    }

    private bool on_bus_message (Gst.Bus bus, Gst.Message message) {
        switch (message.type) {
        case Gst.MessageType.ERROR:
            GLib.Error err;
            string debug;
            message.parse_error (out err, out debug);
            is_recording = false;
            if (_appsink != null) {
                _appsink.new_sample.disconnect (on_new_sample);
            }
            _pipeline.set_state (Gst.State.NULL);
            _pipeline = null;
            error_occurred (err.message);
            return false;

        case Gst.MessageType.EOS:
            is_recording = false;
            if (_appsink != null) {
                _appsink.new_sample.disconnect (on_new_sample);
            }
            _pipeline.set_state (Gst.State.NULL);
            _pipeline = null;
            recording_stopped ();
            return false;

        default:
            return true;
        }
    }
}
