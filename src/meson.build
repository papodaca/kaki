# Point valac at the hand-written transcribe VAPI in src/vapi/.
add_project_arguments(['--vapidir', meson.current_source_dir() / 'vapi'],
                       language: 'vala')

kaki_sources = [
  'main.vala',
  'application.vala',
  'window.vala',
  'services/recorder.vala',
  'services/transcriber.vala',
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

kaki_sources += gnome.compile_resources('kaki-resources',
  'kaki.gresource.xml',
  c_name: 'kaki'
)

executable('kaki', kaki_sources,
  dependencies: kaki_deps,
  include_directories: config_inc,
       install: true,
)
