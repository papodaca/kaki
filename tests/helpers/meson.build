# CLI helpers that exercise Vala libsoup paths without launching the GTK app.
src_dir = meson.project_source_root() / 'src'

download_cli = executable(
  'kaki-download-cli',
  files('download_cli.vala', src_dir / 'services' / 'model-downloader.vala'),
  dependencies: [
    dependency('glib-2.0'),
    dependency('gobject-2.0'),
    dependency('gio-2.0'),
    dependency('libsoup-3.0'),
  ],
  install: false,
)

remote_cli = executable(
  'kaki-remote-cli',
  files(
    'remote_cli.vala',
    src_dir / 'services' / 'transcription-source.vala',
    src_dir / 'services' / 'remote-openai-source.vala',
  ),
  dependencies: [
    dependency('glib-2.0'),
    dependency('gobject-2.0'),
    dependency('gio-2.0'),
    dependency('libsoup-3.0'),
    dependency('json-glib-1.0'),
  ],
  install: false,
)
