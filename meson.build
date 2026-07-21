project('kaki', ['c', 'vala'],
          version: '0.1.0',
    meson_version: '>= 1.0.0',
  default_options: [ 'warning_level=2', 'werror=false', ],
)

# C++ is required to link the transcribe.cpp static lib (C++17). Use
# required: false so the error message names the missing toolchain
# only when the transcribe subproject is actually built.
add_languages('cpp', required: false)

i18n = import('i18n')
gnome = import('gnome')
valac = meson.get_compiler('vala')
cc    = meson.get_compiler('c')


srcdir = meson.project_source_root() / 'src'

config_h = configuration_data()
config_h.set_quoted('PACKAGE_VERSION', meson.project_version ())
config_h.set_quoted('GETTEXT_PACKAGE', 'kaki')
config_h.set_quoted('LOCALEDIR', get_option('prefix') / get_option('localedir'))
configure_file(output: 'config.h', configuration: config_h)

config_dep = valac.find_library ('config', dirs: srcdir)
config_inc = include_directories('.')

add_project_arguments('-DGETTEXT_PACKAGE="' + meson.project_name () + '"', language: 'c')

# --------------------------------------------------------------------------- #
# transcribe.cpp sidecar build                                                #
# --------------------------------------------------------------------------- #
#
# We invoke transcribe.cpp's CMake build directly rather than via
# meson's cmake.subproject() wrapper. As of meson 1.11.2 the wrapper
# has two gaps that block GPU backends:
#   - Vulkan: mishandles $<CONFIG> in ExternalProject_Add BUILD_COMMAND
#     (cmake receives `--config ';;;'` from meson's `;;;` subcommand sep).
#   - HIP: doesn't model the HIP language; sees .cu sources and demands nvcc.
# A direct cmake invocation sidesteps both. The custom_target below runs
# `cmake -S ... -B ...` then `cmake --build --target transcribe`; the
# resulting static archives are wrapped in a declare_dependency and
# consumed by src/meson.build like any other dep.

gpu_backend = get_option('gpu_backend')

transcribe_src      = meson.project_source_root() / 'subprojects' / 'transcribe.cpp'
transcribe_builddir = meson.current_build_dir() / 'subprojects' / 'transcribe.cpp'
transcribe_inc      = include_directories('subprojects' / 'transcribe.cpp' / 'include')

# CMake args common to all backends. We only build the `transcribe` target
# (libtranscribe.a + the ggml archives the selected backend pulls in); the
# standalone CLI, tests, tools, and install rules are all OFF.
cmake_args = [
  '-S', transcribe_src,
  '-B', transcribe_builddir,
  '-DCMAKE_BUILD_TYPE=Release',
  '-DTRANSCRIBE_BUILD_SHARED=OFF',
  '-DTRANSCRIBE_BUILD_TESTS=OFF',
  '-DTRANSCRIBE_BUILD_EXAMPLES=OFF',
  '-DTRANSCRIBE_BUILD_TOOLS=OFF',
  '-DTRANSCRIBE_INSTALL=OFF',
]

# Public defines propagated to kaki's C compile so transcribe.h sees the
# static-contract decoration. Backend-specific GGML_USE_* are also added
# so any GGML headers kaki touches pick the right backend guards.
transcribe_compile_defs = ['-DTRANSCRIBE_STATIC']
extra_archives = []           # backend-specific ggml archive, appended to link_args
path_prefix = ''              # HIP prepends /opt/rocm/bin here; empty for others

rocminfo  = find_program('rocminfo',  required: false)
hipcc     = find_program('hipcc',     required: false)
hipconfig = find_program('hipconfig', required: false)

if gpu_backend == 'auto'
  if hipcc.found() and hipconfig.found()
    gpu_backend = 'hip'
  elif dependency('vulkan', required: false).found()
    gpu_backend = 'vulkan'
  else
    gpu_backend = 'cpu'
  endif
  message('Auto-detected GPU backend: @0@'.format(gpu_backend))
endif

if gpu_backend == 'hip'
  amd_targets = get_option('amd_targets')
  if amd_targets == ''
    if not rocminfo.found()
      error('gpu_backend=hip requires rocminfo to autodetect AMD target. Install rocminfo or pass -Damd_targets=gfxXXXX.')
    endif
    r = run_command(rocminfo, '--show-product-name', check: true)
    foreach line : r.stdout().split('\n')
      if line.contains('gfx')
        amd_targets = line.strip().split(' ')[-1]
        break
      endif
    endforeach
    if amd_targets == ''
      error('Could not autodetect AMD GPU target. Pass -Damd_targets=gfxXXXX.')
    endif
    message('Auto-detected AMD target: @0@'.format(amd_targets))
  endif
  cmake_args += [
    '-DGGML_HIP=ON',
    '-DAMDGPU_TARGETS=' + amd_targets,
    '-DCMAKE_HIP_ARCHITECTURES=' + amd_targets,
  ]
  # CMake's enable_language(HIP) needs to find hipcc and clang on PATH
  # (CMAKE_HIP_COMPILER rejects the hipcc wrapper — it wants clang
  # directly). On Arch, /opt/rocm/bin is not on PATH by default even
  # when hip-runtime-amd is installed. We prepend it to PATH for the
  # sidecar subprocess only, leaving the user's session alone.
  if hipcc.found()
    rocm_bindir = hipcc.path().split('/hipcc')[0]
    path_prefix = 'PATH=' + rocm_bindir + ':$PATH '
  else
    path_prefix = ''
  endif
  transcribe_compile_defs += ['-DGGML_USE_HIP', '-DGGML_USE_CUDA']
  extra_archives += transcribe_builddir / 'ggml' / 'src' / 'ggml-hip' / 'libggml-hip.a'
elif gpu_backend == 'vulkan'
  cmake_args += ['-DTRANSCRIBE_VULKAN=ON']
  transcribe_compile_defs += ['-DGGML_USE_VULKAN']
  extra_archives += transcribe_builddir / 'ggml' / 'src' / 'ggml-vulkan' / 'libggml-vulkan.a'
elif gpu_backend == 'cpu'
  transcribe_compile_defs += ['-DGGML_USE_CPU']
else
  error('Unknown GPU backend: @0@'.format(gpu_backend))
endif

# BLAS link fix: Arch splits BLAS into separate `blas` (Fortran iface,
# libblas.so) and `cblas` (C iface, libcblas.so) packages. transcribe's
# cblas_sgemm calls land in the C interface, but CMake's find_package(BLAS)
# returns only libblas.so. We add libcblas (and libblas as a fallback)
# explicitly at the kaki link step so symbols resolve once Phase 2
# starts calling transcribe_run.
transcribe_link_libs = []
cblas_lib = cc.find_library('cblas', required: false)
blas_lib  = cc.find_library('blas',  required: false)
if cblas_lib.found()
  transcribe_link_libs += cblas_lib
endif
if blas_lib.found()
  transcribe_link_libs += blas_lib
endif

# The custom_target produces a stamp file as its meson-visible output;
# the real archives are side-effects at the known paths below. The
# stamp is added to transcribe_dep via `sources:` so any consumer of
# transcribe_dep builds the archives first. `cmake --build --target
# transcribe` is itself incremental, so re-running ninja is cheap when
# nothing changed.
configure_cmd = ' '.join(['cmake'] + cmake_args)
build_cmd     = ' '.join(['cmake', '--build', transcribe_builddir, '--target', 'transcribe', '--parallel'])
touch_cmd     = ' '.join(['cmake', '-E', 'touch', '@OUTPUT@'])
# path_prefix is empty for non-HIP backends; HIP prepends /opt/rocm/bin
# (or wherever hipcc was found) to PATH so cmake's enable_language(HIP)
# can locate hipcc + clang without polluting the user's session.
sidecar_script = path_prefix + configure_cmd + ' && ' + build_cmd + ' && ' + touch_cmd

transcribe_build = custom_target(
  'transcribe-build',
  output: 'kaki-transcribe-stamp',
  command: [find_program('sh'), '-c', sidecar_script],
  build_by_default: true,
  console: true,
)

# Absolute paths to the archives cmake writes into transcribe_builddir.
libtranscribe_a = transcribe_builddir / 'src'        / 'libtranscribe.a'
libggml_a        = transcribe_builddir / 'ggml' / 'src' / 'libggml.a'
libggml_base_a   = transcribe_builddir / 'ggml' / 'src' / 'libggml-base.a'
libggml_cpu_a    = transcribe_builddir / 'ggml' / 'src' / 'libggml-cpu.a'

transcribe_dep = declare_dependency(
  sources: transcribe_build,
  include_directories: transcribe_inc,
  compile_args: transcribe_compile_defs,
  link_args: [libtranscribe_a, libggml_a, libggml_base_a, libggml_cpu_a] + extra_archives,
  dependencies: transcribe_link_libs,
)


subdir('data')
subdir('src')
subdir('po')

gnome.post_install(
     glib_compile_schemas: true,
    gtk_update_icon_cache: true,
  update_desktop_database: true,
)
