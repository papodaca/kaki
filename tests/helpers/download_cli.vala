/* download_cli.vala — thin CLI around ModelDownloader for integration tests.
 *
 * Usage: kaki-download-cli URL DEST
 * Exit 0 on completed; non-zero on failed.
 */

int main (string[] args) {
    if (args.length != 3) {
        stderr.printf ("usage: %s URL DEST\n", args[0]);
        return 2;
    }

    var loop = new MainLoop ();
    int exit_code = 1;

    var dl = new Kaki.ModelDownloader ();
    dl.completed.connect ((path) => {
        stdout.printf ("%s\n", path);
        exit_code = 0;
        loop.quit ();
    });
    dl.failed.connect ((message) => {
        stderr.printf ("%s\n", message);
        exit_code = 1;
        loop.quit ();
    });

    dl.download_async.begin (args[1], args[2]);
    loop.run ();
    return exit_code;
}
