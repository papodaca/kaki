# Phase 0 — Fix scaffold and confirm build/run

## Goal

Get the freshly-scaffolded GNOME Vala app into a runnable state, fix
latent bugs in the template, drop flatpak packaging, and establish a
clean baseline commit before pulling in the transcribe.cpp submodule.

## Pre-existing scaffold bugs

- `app.shortcuts` is referenced in the menu (`src/window.ui:42`) but NOT
  registered in the `ActionEntry[]` (`src/application.vala:31`). Clicking
  it does nothing.
- `app.preferences` only calls `message(...)` — no dialog
  (`src/application.vala:62`). Will be fully wired in Phase 4; for now
  we just leave it logging so the menu item doesn't silently fail.
- Repo has no commits yet.

## Files to create/modify

- `src/application.vala` — add `shortcuts` action that presents the
  existing `AdwShortcutsDialog` from `shortcuts-dialog.ui`; add
  `<Control>comma` accelerator for `app.preferences`.
- `src/window.ui` — replace the placeholder `GtkLabel` "Hello, World!"
  with an `AdwStatusPage` empty-state ("No model loaded") that we will
  flesh out in Phase 2. Add `<property name="menu-model">primary_menu</property>`
  consistency check.
- `README.md` — replace "A description of this project." with a short
  description and a build/run snippet.
- Delete: `org.kaki.app.json`, `org.kaki.app.json~` (flatpak manifest,
  dropped per scope decision).
- `docs/plans/README.md` + phase docs (this commit).

## Code sketch — `src/application.vala`

```vala
construct {
    ActionEntry[] action_entries = {
        { "about", this.on_about_action },
        { "preferences", this.on_preferences_action },
        { "shortcuts", this.on_shortcuts_action },
        { "quit", this.quit }
    };
    this.add_action_entries (action_entries, this);

    this.set_accels_for_action ("app.quit",        {"<control>q"});
    this.set_accels_for_action ("app.preferences", {"<control>comma"});
    this.set_accels_for_action ("app.shortcuts",   {"<control>question"});
}

private void on_shortcuts_action () {
    var builder = new Gtk.Builder.from_resource ("/org/kaki/app/shortcuts-dialog.ui");
    var dialog = (Adw.ShortcutsDialog) builder.get_object ("shortcuts_dialog");
    dialog.present (this.active_window);
}

private void on_preferences_action () {
    // Fully wired in Phase 4. Keep the message() so we can see it fire.
    message ("app.preferences action activated");
}
```

## Code sketch — `src/window.ui` (content region only)

```xml
<property name="content">
  <object class="AdwStatusPage" id="empty_state">
    <property name="icon-name">audio-input-microphone-symbolic</property>
    <property name="title" translatable="yes">No Model Loaded</property>
    <property name="description" translatable="yes">Open Preferences to download a model or configure an OpenAI-compatible API.</property>
  </object>
</property>
```

Remove the `GtkLabel` `id="label"` and the corresponding `[GtkChild]` in
`src/window.vala`.

## Verification

```bash
meson setup build
ninja -C build
./build/src/kaki          # window opens, "No Model Loaded" status page shows
meson test -C build       # desktop/appstream/schema validation pass
```

- Clicking the header menu → Keyboard Shortcuts opens the dialog.
- Clicking Preferences prints `app.preferences action activated` on
  stdout (no silent failure).
- `<Control>comma` activates preferences; `<Control>question` opens
  shortcuts; `<Control>q` quits.

## Commit

```
Phase 0: fix scaffold, register shortcuts action, drop flatpak manifest

- Register app.shortcuts and present AdwShortcutsDialog
- Add <Control>comma accelerator for app.preferences
- Replace placeholder GtkLabel with AdwStatusPage empty-state
- Remove flatpak manifest (system builds only)
- Add docs/plans with phase breakdown and design decisions
- Update README
```
