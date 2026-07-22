desktop_file = i18n.merge_file(
        input: 'org.kaki.app.desktop.in',
       output: 'org.kaki.app.desktop',
         type: 'desktop',
       po_dir: '../po',
      install: true,
  install_dir: get_option('datadir') / 'applications'
)

desktop_utils = find_program('desktop-file-validate', required: false)
if desktop_utils.found()
  test('Validate desktop file', desktop_utils, args: [desktop_file])
endif

appstream_file = i18n.merge_file(
        input: 'org.kaki.app.metainfo.xml.in',
       output: 'org.kaki.app.metainfo.xml',
       po_dir: '../po',
      install: true,
  install_dir: get_option('datadir') / 'metainfo'
)

appstreamcli = find_program('appstreamcli', required: false, disabler: true)
test('Validate appstream file', appstreamcli,
     args: ['validate', '--no-net', '--explain', appstream_file])

install_data('org.kaki.app.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas'
)

compile_schemas = find_program('glib-compile-schemas', required: false, disabler: true)
test('Validate schema file',
     compile_schemas,
     args: ['--strict', '--dry-run', meson.current_source_dir()])


service_conf = configuration_data()
service_conf.set('bindir', get_option('prefix') / get_option('bindir'))
configure_file(
  input: 'org.kaki.app.service.in',
  output: 'org.kaki.app.service',
  configuration: service_conf,
  install_dir: get_option('datadir') / 'dbus-1' / 'services'
)

# Phase 5: fallback global-shortcut helper. Installed next to the kaki
# executable so users on portal-less desktops can bind `kaki-signal
# toggle` as a GNOME custom shortcut. The Preferences Shortcuts page
# offers to copy the same script to ~/.local/bin for uninstalled builds.
install_data('kaki-signal.sh',
  install_dir: get_option('bindir'),
  install_mode: 'rwxr-xr-x',
  rename: 'kaki-signal'
)

subdir('icons')
