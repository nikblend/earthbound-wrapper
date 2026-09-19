# Contributing

This is a personal project, but the seams are documented and pull requests are
welcome — especially anything that makes the tactile output better, since that is
the whole point of the app.

## Before you start

You need macOS with Xcode 16 or later. Everything else is fetched or generated.

```sh
make check      # the fast gate: C glue tests + vendored-header check, no Xcode
make simulator  # build both core slices and launch in the iOS Simulator
```

`make check` runs in about a second and covers the parts that fail silently on a
device. Please run it before opening a pull request; CI runs the same thing.

## Things worth knowing

**The Xcode project is generated.** `project.yml` is the source of truth and CI
regenerates it. Do not commit `EarthboundWrapper.xcodeproj` — it is gitignored, and
hand-editing it means the next `xcodegen generate` throws the change away.

**`Sources/Support/EBCoreGlue.c` is the only file that may include `libretro.h`.**
Everything else talks to the core through its flattened C API. If you need a new
core entry point or descriptor, add it there: declare it in `EBCoreGlue.h` with
plain C types, implement it, and assign it to a pointer of the declared type so the
signature check catches a mismatch at build time.

**Adding a constant means adding an assert.** Anything you mirror in
`Sources/Core/LibretroConstants.swift` must be `_Static_assert`ed against the real
header in `EBCoreGlue.c`. The header is pinned, so the assert is cheap and it turns
a silent behavioural bug into a compile error.

**Re-pinning the core is a three-step job**, and CI enforces the first two:

```sh
echo <new-sha> > ThirdParty/libretro/CORE_REVISION
scripts/verify-core-pin.sh --update     # refresh the vendored libretro.h
# then work through whatever the C asserts complain about, and re-extract the
# option table in Sources/Core/Snes9xOptions.swift if the core's options changed
```

**Nothing on a real-time thread may allocate, lock, or block.** That means the
audio render block in `AudioOutput.swift`, and any CoreHaptics call that happens
per frame. The audio ring and the joypad word are lock-free C for this reason; the
Swift `Locked` type is for cold paths only.

## Pull requests

- One change per pull request, with the reasoning in the description. The "why" is
  more useful than the "what" — the diff already shows the what.
- Match the surrounding comment style. This codebase explains decisions rather than
  restating code, and the comments are load-bearing: they record *why* the obvious
  alternative was rejected, which is the thing that gets lost otherwise.
- If you add behaviour that can be tested without Xcode, add the test to
  `tests/glue_test.c`. It is deliberately dependency-free so it runs anywhere.
