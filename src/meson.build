# Point valac at the hand-written VAPIs in src/vapi/ (transcribe + libei).
add_project_arguments(['--vapidir', meson.current_source_dir() / 'vapi'],
                        language: 'vala')

# Posix namespace (Signal.USR1/USR2, getpid, chmod) used by the Phase 5
# global-shortcut fallback. The posix.vapi ships with valac and is on
# its default search path, so no --vapidir is needed.
add_project_arguments(['--pkg', 'posix'], language: 'vala')

# When libei-1.0 was detected by the top-level meson.build, expose the
# HAVE_LIBEI Vala preprocessor symbol so the libei backend in
# keystroke.vala compiles in. The VAPI and C shim are only linked when
# libei is available; without this gate the Vala references would
# otherwise fail to resolve at link time.
if have_libei
  add_project_arguments(['-D', 'HAVE_LIBEI'], language: 'vala')
endif

kaki_sources = [
  'main.vala',
  'application.vala',
  'window.vala',
  'services/recorder.vala',
  'services/transcriber.vala',
  'services/keystroke.vala',
  'services/model-downloader.vala',
  'services/secret-store.vala',
  'services/global-shortcuts.vala',
  'ui/preferences.vala',
  # Phase 5: portable SIGRTMIN (glibc exposes it as a function-based
  # macro, musl as a constant; posix.vapi has no binding).
  'vapi/signal-shim.c',
]

kaki_deps = [
  config_dep,
  dependency('gtk4'),
  dependency('libadwaita-1', version: '>= 1.4'),
  transcribe_dep,
  valac.find_library('transcribe', dirs: meson.current_source_dir() / 'vapi'),
  dependency('gstreamer-1.0'),
  dependency('gstreamer-base-1.0'),
  dependency('gstreamer-app-1.0'),
  dependency('gstreamer-audio-1.0'),
  # Phase 4: model downloader (libsoup-3.0) + API key storage (libsecret-1).
  dependency('libsoup-3.0'),
  dependency('libsecret-1'),
]

# Optional libei-1.0 backend (dictation mode keystroke injection).
# The pkg-config dep adds `--pkg libei-1.0` to the vala command, which
# resolves to our hand-written src/vapi/libei-1.0.vapi (libei ships no
# upstream VAPI). The C shim wraps the sentinel-terminated variadic
# ei_seat_bind_capabilities call.
if have_libei
  kaki_deps += [ libei_dep ]
  kaki_sources += 'vapi/libei-shim.c'
endif

kaki_sources += gnome.compile_resources('kaki-resources',
  'kaki.gresource.xml',
  c_name: 'kaki'
)

# Include src/vapi/ so the C compiled from keystroke.vala finds
# libei-shim.h (referenced by the VAPI's cheader_filename for the
# Seat shim methods), and so the signal-shim.h prototype is visible to
# application.vala's generated C for the SIGRTMIN call.
kaki_inc = [ config_inc, include_directories('vapi') ]

executable('kaki', kaki_sources,
  dependencies: kaki_deps,
  include_directories: kaki_inc,
       install: true,
)
