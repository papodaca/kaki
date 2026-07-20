# Phase 1 — Add transcribe.cpp submodule + ROCm/HIP/Vulkan build + VAPI

## Goal

Pull [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp)
in as a git submodule at `subprojects/transcribe.cpp`, build it as a
cmake subproject from meson, expose a user-selectable GPU backend
(`hip | vulkan | cpu | auto`), and hand-write a VAPI binding for the
subset of the C API we need.

## Submodule

```bash
git submodule add https://github.com/handy-computer/transcribe.cpp \
  subprojects/transcribe.cpp
cd subprojects/transcribe.cpp && git checkout v0.1.2 && cd -
git add subprojects/transcribe.cpp .gitmodules
```

Pin to the latest tag at the time of writing (`v0.1.2`). Update by
checking out a newer tag and committing the new SHA.

transcribe.cpp is MIT; Kaki is GPL-3. Submodule license is preserved
in its own tree; we only link against the public C API.

## Meson options (`meson.build`)

Add near the top, after `project()`:

```meson
option('gpu_backend', type: 'combo', choices: ['auto', 'hip', 'vulkan', 'cpu'], value: 'auto',
       description: 'GPU backend for the transcribe.cpp ggml runtime')
option('amd_targets', type: 'string', value: '',
       description: 'AMD GPU targets (e.g. gfx1100). Empty = autodetect via rocminfo')
```

Wait — `meson_options.txt` is the right file. Create:

```
# meson_options.txt
option('gpu_backend', type: 'combo', choices: ['auto', 'hip', 'vulkan', 'cpu'], value: 'auto')
option('amd_targets', type: 'string', value: '')
```

## Backend selection logic (`meson.build`)

```meson
gpu_backend = get_option('gpu_backend')

rocminfo = find_program('rocminfo', required: false)
hipconfig = find_program('hipconfig', required: false)

if gpu_backend == 'auto'
  if rocminfo.found() and hipconfig.found()
    gpu_backend = 'hip'
  elif dependency('vulkan', required: false).found()
    gpu_backend = 'vulkan'
  else
    gpu_backend = 'cpu'
  endif
  message('Auto-detected GPU backend: @0@'.format(gpu_backend))
endif

cmake = import('cmake')

transcribe_opts = cmake.subproject_options()
transcribe_opts.add_cmake_defines({'BUILD_SHARED_LIBS': 'OFF'})
transcribe_opts.set_install(false)

if gpu_backend == 'hip'
  amd_targets = get_option('amd_targets')
  if amd_targets == ''
    r = run_command(rocminfo, '--show-product-name', check: true)
    amd_targets = ''
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
  transcribe_opts.add_cmake_defines({
    'GGML_HIP': 'ON',
    'AMDGPU_TARGETS': amd_targets,
  })
elif gpu_backend == 'vulkan'
  transcribe_opts.add_cmake_defines({'TRANSCRIBE_VULKAN': 'ON'})
elif gpu_backend == 'cpu'
  # nothing extra — defaults to CPU + tinyBLAS
else
  error('Unknown GPU backend: @0@'.format(gpu_backend))
endif

transcribe_proj = cmake.subproject('transcribe.cpp', options: transcribe_opts)
transcribe_dep = transcribe_proj.get_variable('transcribe_dep')
```

> The exact target name (`transcribe_dep`) depends on what the cmake
> project exports. Verify by running `meson introspect --targetlist
> build` after first configure and adjust the `get_variable` name to
> match the cmake target (`transcribe`, `transcribe::transcribe`, or
> `transcribe_static`). The cmake subproject wrapper exposes cmake
> targets under their cmake name.

## VAPI binding (`src/vapi/transcribe.vapi`)

Hand-written against `include/transcribe.h` (and
`include/transcribe/extensions.h` if we use family extensions later).
Initial subset:

```vala
[CCode (cprefix = "", lower_case_cprefix = "", cheader_filename = "transcribe.h")]
namespace Transcribe {
    // Status codes — mirror enum from transcribe.h
    [CCode (cprefix = "TRANSCRIBE_", has_type_id = false)]
    public enum Status {
        OK,
        ERR_INPUT_TOO_LONG,
        ERR_OUTPUT_TRUNCATED,
        ERR_MODEL,
        ERR_AUDIO,
        ERR_INTERNAL,
    }

    [CCode (cname = "struct transcribe_capabilities", has_type_id = false)]
    public struct Capabilities {
        public int max_audio_ms;
        // ... other fields we need; expand as required
    }

    [Compact]
    [CCode (cname = "struct transcribe_model", free_function = "transcribe_model_free", has_type_id = false)]
    public class Model {
        [CCode (cname = "transcribe_model_load")]
        public static Model? load (string path);
    }

    [Compact]
    [CCode (cname = "struct transcribe_session", free_function = "transcribe_session_free", has_type_id = false)]
    public class Session {
        [CCode (cname = "transcribe_session_new")]
        public Session (Model model);
        [CCode (cname = "transcribe_run")]
        public Status run (uint8[] samples_f32, int n_samples);
        [CCode (cname = "transcribe_full_text")]
        public unowned string full_text ();
        [CCode (cname = "transcribe_detected_language")]
        public unowned string detected_language ();
        [CCode (cname = "transcribe_was_truncated")]
        public bool was_truncated ();
    }

    [CCode (cname = "transcribe_capabilities_init")]
    public void capabilities_init (out Capabilities caps);
    [CCode (cname = "transcribe_model_get_capabilities")]
    public void model_get_capabilities (Model model, out Capabilities caps);
}
```

> **Caveat**: the exact struct/function names need to be confirmed
> against `subprojects/transcribe.cpp/include/transcribe.h` once we
> pull the submodule. The VAPI is the single source of truth for the
> Vala side and is easy to extend.

## Glue file (`src/vapi/transcribe-shim.c`)

Only add a shim if an accessor needs Vala-friendly marshalling (e.g.,
converting a borrowed `const char *` segment list to a
`null-terminated array of owned strings`). Phase 1 starts with just
`transcribe_full_text`/`transcribe_detected_language` — no shim
needed yet.

## `src/meson.build` changes

```meson
add_project_arguments(['--vapidir', meson.current_source_dir() / 'vapi'],
                       language: 'vala')

kaki_deps = [
  config_dep,
  dependency('gtk4'),
  dependency('libadwaita-1', version: '>= 1.4'),
  transcribe_dep,
  meson.get_compiler('vala').find_library('transcribe', dirs: meson.current_source_dir() / 'vapi'),
]

# Need C++ linker for the transcribe.cpp static lib:
link_args = ['-lstdc++']   # or use add_languages('cpp') at top level
```

Add `add_languages('cpp', required: false)` to the top-level `meson.build`
so meson can link the C++ runtime the cmake-built static lib needs.

## Verification

Three configure/run cycles:

```bash
# ROCm/HIP — requires rocminfo + hipconfig on PATH, AMD GPU present
meson setup build_hip -Dgpu_backend=hip -Damd_targets=gfx1100
ninja -C build_hip

# Vulkan — libvulkan-dev installed
meson setup build_vulkan -Dgpu_backend=vulkan
ninja -C build_vulkan

# CPU only
meson setup build_cpu -Dgpu_backend=cpu
ninja -C build_cpu
```

All three should produce `build_*/src/kaki`. The binary should start
and show the empty-state window from Phase 0 (no model loaded yet).

Smoke test (manual debug action, added in Phase 2): load
`whisper-tiny.en` GGUF, transcribe `samples/jfk.wav`. For Phase 1 we
only verify the lib links and symbols resolve.

```bash
nm build_hip/src/kaki | grep transcribe_model_load
# expect: U transcribe_model_load
```

## Commit

```
Phase 1: add transcribe.cpp submodule and HIP/Vulkan/CPU build

- Submodule subprojects/transcribe.cpp pinned at v0.1.2
- meson_options.txt: gpu_backend (auto|hip|vulkan|cpu), amd_targets
- cmake.subproject with backend-specific defines (GGML_HIP / TRANSCRIBE_VULKAN)
- Auto-detect AMD GPU target via rocminfo when -Damd_targets is empty
- Hand-written src/vapi/transcribe.vapi covering model/session/run/results
- Add C++ linker language to consume cmake static lib
```
