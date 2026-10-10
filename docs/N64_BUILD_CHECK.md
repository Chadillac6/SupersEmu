# N64 build check (iOS)

**Question:** can Mupen64Plus-Next build for iPhone/iPad under the no-JIT rule?

## What was run
`scripts/build-n64-ios.sh` (upstream commit `12edd2c`, `make platform=ios-arm64`, iOS 26.5 SDK, Xcode 26.6).

## Result: builds, after two local fixes
- Output: `mupen64plus_next_libretro_ios.dylib`, Mach-O arm64, about 6.8 MB, exporting the standard `retro_*` API.
- **No dynarec.** The upstream `ios-arm64` target sets `WITH_DYNAREC=` (empty), so the CPU runs in the
  interpreter that iOS allows without JIT. No dynarec flags appear in the build log.
- **Graphics need GPU rendering.** It's built with `HAVE_OPENGL`, `GLES3` and `HAVE_PARALLEL_RDP` and links
  `OpenGLES.framework`. Our host only handles software frames today, so N64 needs libretro
  hardware rendering (`RETRO_ENVIRONMENT_SET_HW_RENDER`) with a GLES3 context. ParaLLEl-RDP needs Vulkan,
  which means MoltenVK.
- Fixes (both in the script): a shim `<fp.h>` for vendored libpng, and zlib's `TARGET_OS_MAC` branch disabled
  so `fdopen` isn't redefined.

## Not yet known
- Speed. The interpreter's speed on a real iPhone/iPad is the main open question, and only Chad's
  devices can answer it. The simulator runs on the Mac's CPU and proves nothing about phone speed.
- Whether OpenGL ES (deprecated by Apple but still shipping) or MoltenVK is the better long-term video path.

## Next steps
1. Add hardware-render support (GLES3 first) to `SELibretroHost`.
2. Build an iOS simulator/macOS variant and confirm a homebrew N64 ROM draws frames.
3. Measure FPS on Chad's iPhone and iPad once signing is set up.
