# kaki

Speech-to-text GNOME app built with GTK4 + libadwaita in Vala. Uses
[transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) for
local inference (HIP / Vulkan / CPU) and supports OpenAI-compatible
remote transcription APIs.

## Build & run

```bash
meson setup build
ninja -C build
./build/src/kaki
```

Tests:

```bash
meson test -C build
```
