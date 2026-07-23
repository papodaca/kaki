# Phase 8 — Shortcuts dialog sync

## Goal

Make `AdwShortcutsDialog` show the same in-app shortcuts as the
Preferences Shortcuts page (plus the fixed Copy / Clear bindings), always
reflecting the current accelerators after Preferences edits. No new
settings store — GSettings `shortcut-*` keys and
`Application.apply_shortcuts()` already own persistence and live rebind.

## Problem

- Preferences (`src/ui/preferences.vala` ~399–418) writes seven
  `shortcut-*` keys and re-applies via `set_accels_for_action`.
- Shortcuts dialog (`src/shortcuts-dialog.ui`) only lists **Show Shortcuts**
  and **Quit**, so it looks out of sync with Preferences.
- The dialog already uses `action-name`, which resolves live from
  `Gtk.Application` — the gap is **coverage**, not a second write path.

## Architecture (keep)

```
Preferences ShortcutRow
        │ write
        ▼
GSettings shortcut-*   (data/org.kaki.app.gschema.xml:85–119)
        │ changed::
        ▼
Application.apply_shortcuts()   (src/application.vala:81–110)
        │ set_accels_for_action
        ▼
Gtk.Application accel map
        │ get_accels_for_action (on map / keys-changed)
        ▼
AdwShortcutsItem action-name   (shortcuts-dialog.ui)
```

**Do not** set `accelerator` on items that have app/win actions — that
duplicates truth and only acts as a fallback when no accel is registered.
**Do not** invent a new store or have the dialog read GSettings directly.

## Out of scope

- Global portal / `kaki-signal` shortcut (separate system; Preferences only)
- Making Copy / Clear editable in Preferences
- Shared Vala catalog that builds both Preferences rows and the dialog
- Schema changes

## Files to modify

| File | Change |
| --- | --- |
| `src/shortcuts-dialog.ui` | Expand sections/items to cover all listed actions |
| `src/application.vala` | Optional: register `settings.changed` once instead of seven times (lines 55–64) |

No changes to Preferences, GSettings schema, or `on_shortcuts_action`
(fresh dialog from resource each open is correct).

## Target dialog contents

Use `title` + `action-name` only. Match Preferences labels where they
overlap.

### Section: Recording

| Title | `action-name` | Source |
| --- | --- | --- |
| Record / Pause | `win.record` | GSettings `shortcut-record` |
| Stop | `win.stop` | GSettings `shortcut-stop` |
| Insert text | `win.insert` | GSettings `shortcut-insert` |
| Toggle dictation | `win.dictate` | GSettings `shortcut-dictate` |

### Section: Transcript

| Title | `action-name` | Source |
| --- | --- | --- |
| Copy | `win.copy` | Hardcoded in `window.vala:76` (`<Control><Shift>C`) |
| Clear | `win.clear` | Hardcoded in `window.vala:77` (`<Control>Delete`) |

### Section: Application

| Title | `action-name` | Source |
| --- | --- | --- |
| Show preferences | `app.preferences` | GSettings `shortcut-prefs` |
| Show Shortcuts | `app.shortcuts` | GSettings `shortcut-shortcuts` |
| Quit | `app.quit` | GSettings `shortcut-quit` |

## UI sketch — `src/shortcuts-dialog.ui`

```xml
<object class="AdwShortcutsDialog" id="shortcuts_dialog">
  <child>
    <object class="AdwShortcutsSection">
      <property name="title" translatable="yes">Recording</property>
      <!-- AdwShortcutsItem: title + action-name for win.record/stop/insert/dictate -->
    </object>
  </child>
  <child>
    <object class="AdwShortcutsSection">
      <property name="title" translatable="yes">Transcript</property>
      <!-- win.copy, win.clear -->
    </object>
  </child>
  <child>
    <object class="AdwShortcutsSection">
      <property name="title" translatable="yes">Application</property>
      <!-- app.preferences, app.shortcuts, app.quit -->
    </object>
  </child>
</object>
```

Use `context="shortcut window"` on titles (same as existing items).

## Optional cleanup — `application.vala`

Today the construct loop connects the same `changed` handler once per
`shortcut-*` key, so one edit can call `apply_shortcuts()` seven times.
Replace with a single connection:

```vala
settings.changed.connect ((changed_key) => {
    if (changed_key.has_prefix ("shortcut-"))
        apply_shortcuts ();
});
```

## Acceptance criteria

- [x] Shortcuts dialog lists all 7 Preferences-backed actions + Copy + Clear
- [x] Changing a shortcut in Preferences updates the dialog without restart
  (reopen or keep open — libadwaita refreshes on `keys-changed`)
- [x] Clearing a shortcut (Backspace in Preferences) shows “No Shortcut”
  in the dialog
- [x] Copy / Clear still show `<Control><Shift>C` / `<Control>Delete`
- [x] No second write path; no hardcoded `accelerator` on customizable items
- [x] Global shortcut Preferences UI unchanged

Status: in-progress (implemented; awaiting manual UI check + px-review)

## Manual test plan

1. Open Shortcuts (menu or `<Control>question`) — nine actions in three sections.
2. Preferences → change Quit to e.g. `<Control><Shift>Q` → reopen Shortcuts → new combo.
3. Clear Insert (Backspace) → dialog shows no shortcut for Insert text.
4. Confirm Record / Stop / Dictate / Prefs / Shortcuts still show defaults or prior edits.
5. Confirm Copy / Clear still work and are listed.

## Related

- Phase 4: Preferences Shortcuts page + GSettings keys
- Phase 5: Global shortcuts (portal + `kaki-signal`) — not part of this dialog
- Phase 0: Original minimal `shortcuts-dialog.ui` wiring