# Point valac at the hand-written VAPIs in src/vapi/ (transcribe + libei).
add_project_arguments(['--vapidir', meson.current_source_dir() / 'vapi'],
                       language: 'vala')

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
# Seat shim methods). Only needed when libei is enabled.
kaki_inc = [ config_inc ]
if have_libei
  kaki_inc += include_directories('vapi')
endif

executable('kaki', kaki_sources,
  dependencies: kaki_deps,
  include_directories: kaki_inc,
       install: true,
)
