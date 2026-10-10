# ADR 0002: How cores are packaged

- Status: Proposed

## Decision
- M0 spike: Snes9x is compiled as a static library (`Snes9xCore` target) and linked into the app.
- M1+: each core is built as its own dynamic framework embedded and signed inside the app
  bundle, loaded with `dlopen` on demand.

## Why
- Every libretro core exports the same `retro_*` symbols, so two statically linked cores collide.
  Separate frameworks keep symbols isolated and let us unload a core between games.
- iOS only allows executable code that ships signed inside the app bundle. Cores cannot be
  downloaded at runtime, so the core set is fixed per app build (and pinned per build, which
  we want anyway for save-state compatibility).

## Consequences
- Core version is part of every save-state's metadata; a state is only offered on a build
  with a compatible core.
- Build: XcodeGen (`project.yml`) generates the project; each core gets its own target.
