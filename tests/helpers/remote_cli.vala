/* remote_cli.vala — drive RemoteOpenAISource against a mock endpoint.
 *
 * Usage: kaki-remote-cli ENDPOINT MODEL [API_KEY]
 * POSTs 100 ms of silent F32LE audio; prints the parsed transcript.
 * Exit 0 on success; non-zero on error.
 */

int main (string[] args) {
    if (args.length < 3 || args.length > 4) {
        stderr.printf ("usage: %s ENDPOINT MODEL [API_KEY]\n", args[0]);
        return 2;
    }

    var src = new Kaki.RemoteOpenAISource ();
    src.endpoint = args[1];
    src.model = args[2];
    src.api_key = args.length > 3 ? args[3] : "";
    src.response_format = "json";
    src.temperature = 0.0;
    src.translate = false;

    // 100 ms of silence at 16 kHz mono — same duration as test-sample.wav.
    float[] samples = new float[1600];

    var loop = new MainLoop ();
    int exit_code = 1;

    src.prepare.begin ((obj, res) => {
        try {
            src.prepare.end (res);
        } catch (GLib.Error e) {
            stderr.printf ("prepare: %s\n", e.message);
            loop.quit ();
            return;
        }

        src.transcribe_batch.begin (samples, null, (obj2, res2) => {
            try {
                string text = src.transcribe_batch.end (res2);
                stdout.printf ("%s\n", text);
                exit_code = 0;
            } catch (GLib.Error e) {
                stderr.printf ("%s\n", e.message);
                exit_code = 1;
            }
            loop.quit ();
        });
    });

    loop.run ();
    return exit_code;
}
