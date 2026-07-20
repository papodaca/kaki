kaki_sources = [
  'main.vala',
  'application.vala',
  'window.vala',
]

kaki_deps = [
  config_dep,
  dependency('gtk4'),
  dependency('libadwaita-1', version: '>= 1.4'),
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
