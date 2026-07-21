# Point valac at the hand-written transcribe VAPI in src/vapi/.
add_project_arguments(['--vapidir', meson.current_source_dir() / 'vapi'],
                       language: 'vala')

kaki_sources = [
  'main.vala',
  'application.vala',
  'window.vala',
]

kaki_deps = [
  config_dep,
  dependency('gtk4'),
  dependency('libadwaita-1', version: '>= 1.4'),
  transcribe_dep,
  valac.find_library('transcribe', dirs: meson.current_source_dir() / 'vapi'),
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
