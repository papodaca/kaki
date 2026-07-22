/* secret-store.vala
 *
 * Copyright 2026 Ethan
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Thin wrapper over libsecret for the OpenAI-compatible transcription
 * API key. The schema is "org.kaki.app" with a single STRING attribute
 * "type" pinned to "api-key", so `secret-tool search --all 'type=api-key'`
 * surfaces it under that schema (per Phase 4 verification step 6).
 *
 * The three async calls accept a Cancellable (passed straight through)
 * and surface libsecret failures to the caller via throws.
 */

public class Kaki.SecretStore : GLib.Object {
    // Single shared schema instance. Schema is reference-counted in
    // libsecret; holding one static ref for the process lifetime is
    // simpler than ref/unref around every call.
    private static Secret.Schema? _schema;

    construct {
        if (_schema == null) {
            // The variadic Schema ctor pairs (name, type) terminators
            // are NOT used by Vala's binding — pass via newv + HashTable
            // so the attribute list is unambiguous and language-level.
            var attrs = new GLib.HashTable<string, Secret.SchemaAttributeType> (str_hash, str_equal);
            attrs.insert ("type", Secret.SchemaAttributeType.STRING);
            _schema = new Secret.Schema.newv ("org.kaki.app",
                                               Secret.SchemaFlags.NONE,
                                               (owned) attrs);
        }
    }

    public async string? get_api_key (Cancellable? cancellable = null)
        throws GLib.Error {
        var attrs = new GLib.HashTable<string, string> (str_hash, str_equal);
        attrs.insert ("type", "api-key");
        // password_lookupv returns "" (empty) when nothing is found;
        // normalize to null so callers can treat missing as "not set".
        string? result = yield Secret.password_lookupv (_schema,
                                                         (owned) attrs,
                                                         cancellable);
        if (result != null && result.length == 0)
            return null;
        return result;
    }

    public async void set_api_key (string? key, Cancellable? cancellable = null)
        throws GLib.Error {
        if (key == null || key.length == 0) {
            yield clear_api_key (cancellable);
            return;
        }
        var attrs = new GLib.HashTable<string, string> (str_hash, str_equal);
        attrs.insert ("type", "api-key");
        yield Secret.password_storev (_schema,
                                       (owned) attrs,
                                       null, // default collection
                                       "Kaki API key",
                                       key,
                                       cancellable);
    }

    public async void clear_api_key (Cancellable? cancellable = null)
        throws GLib.Error {
        var attrs = new GLib.HashTable<string, string> (str_hash, str_equal);
        attrs.insert ("type", "api-key");
        // password_clearv returns false (no error) when no matching
        // secret exists — treat as success.
        yield Secret.password_clearv (_schema, (owned) attrs, cancellable);
    }
}
