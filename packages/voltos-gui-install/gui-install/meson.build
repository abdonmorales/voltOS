# gui-install: the OpenSolaris (Caiman) graphical installer, ported to Linux
# for VoltOS.  Builds against GTK 3 (default) or GTK 2 (-Dgtk=2).
project('gui-install', 'c',
  version: '1.0.0',
  license: 'CDDL-1.0 AND MIT',
  default_options: ['warning_level=1', 'c_std=gnu11'])

gtk_version = get_option('gtk')
gtk = dependency(gtk_version == '2' ? 'gtk+-2.0' : 'gtk+-3.0')
gmodule = dependency('gmodule-export-2.0')
cc = meson.get_compiler('c')
m = cc.find_library('m')

pkgdatadir = get_option('prefix') / get_option('datadir') / 'gui-install'
conf = configuration_data()
conf.set('GETTEXT_PACKAGE', 'gui-install')
conf.set('VERSION', meson.project_version())
conf.set('PKGDATADIR', pkgdatadir)
conf.set('LOCALEDIR', get_option('prefix') / get_option('localedir'))
conf.set('DISTRO_NAME', get_option('distro_name'))
conf.set('DISTRO_URL', get_option('distro_url'))
configure_file(input: 'config.h.in', output: 'config.h', configuration: conf)

add_project_arguments('-DHAVE_CONFIG_H',
  '-include', meson.current_source_dir() / 'compat' / 'gtk-compat.h',
  # The original code base predates these warnings; keep the build quiet
  # about them rather than churning the imported sources.
  '-Wno-deprecated-declarations', '-Wno-unused-parameter',
  '-Wno-sign-compare', '-Wno-missing-field-initializers',
  language: 'c')

sources = files(
  'compat/glade-compat.c',
  'compat/orchestrator-linux.c',
  'compat/zoneinfo-linux.c',
  'src/callbacks.c',
  'src/confirmation-screen.c',
  'src/datetimezone-screen.c',
  'src/error-logging.c',
  'src/failure-screen.c',
  'src/finish-screen.c',
  'src/help-dialog.c',
  'src/installation-disk-screen.c',
  'src/installation-screen.c',
  'src/language-screen.c',
  'src/main.c',
  'src/map.c',
  'src/orchestrator-wrappers.c',
  'src/test-mode.c',
  'src/timezone.c',
  'src/users-screen.c',
  'src/welcome-screen.c',
  'src/window-graphics.c',
)

executable('gui-install', sources,
  include_directories: include_directories('.', 'compat', 'src'),
  dependencies: [gtk, gmodule, m],
  install: true)

install_data(
  files('src/confirmation.ui', 'src/date-time-zone.ui', 'src/failure.ui',
    'src/gui-install.ui', 'src/installation.ui', 'src/installationdisk.ui',
    'src/users.ui'),
  install_dir: pkgdatadir)
install_subdir('pixmaps', install_dir: pkgdatadir, strip_directory: true)
install_subdir('help', install_dir: pkgdatadir)
install_subdir('slides', install_dir: pkgdatadir / 'installmessages',
  strip_directory: true)
install_data('help/license', install_dir: pkgdatadir)
