# Earthbound Wrapper

[![Build IPA](https://github.com/nikblend/earthbound-wrapper/actions/workflows/build-ipa.yml/badge.svg)](https://github.com/nikblend/earthbound-wrapper/actions/workflows/build-ipa.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-iOS%2017%2B-lightgrey)

A Super Nintendo frontend for iOS, built specifically to fix the things that make
EarthBound unpleasant to play on a phone: a picture that uses two thirds of the
screen, a d-pad that fights your thumb, and no physical feedback at all.

It is a **frontend**, not an emulator. The emulation is [snes9x]'s libretro core,
compiled from source and linked straight into the app. Everything you would
actually notice — the controls, the scaling, the haptics — is in this repository.

> **No ROMs.** The app ships with none and cannot obtain any. Bring your own dump
> of a cartridge you own.

---

## What it does differently

**The stick, not a d-pad.** Touch anywhere on the left side of the screen and the
stick is planted there. Your finger moves the nub *freely*, but the direction sent
to the SNES snaps to one of eight sectors — so it feels continuous under your
thumb while the game receives clean, discrete input. Each time it snaps, the
Taptic Engine knocks once. That knock is the entire reason the control reads as a
stick rather than as a slippery dot.

**The picture fills more of the screen.** A SNES frame is 4:3 inside a phone that
is about 2.2:1 in landscape, so an aspect-correct fit leaves two fat pillarboxes.
There are three honest ways out (`Fit`, `Pixel-perfect`, `Fill` with a width
slider) plus a zoom crop. The default is correct; the alternatives exist because
you asked for a bigger picture, and a mild horizontal stretch costs a 2D game
much less than it sounds.

**The haptics are driven by the soundtrack.** There is no game state to hook, so
the mix itself is analysed in three bands — bass, mid and presence — every audio
batch. Bass becomes a continuous rumble whose intensity tracks the music in real
time; onsets in any band become taps. EarthBound's text blip lives in the presence
band, which is why scrolling dialogue feels like something is happening.

---

## How it fits together

```
   ┌──────────────┐   video    ┌──────────────┐  texture  ┌────────────┐
   │ snes9x core  │──────────▶ │  FrameQueue  │─────────▶ │   Metal    │
   │ (static .a,  │            │ 3 buffers    │           │  MTKView   │
   │  pinned SHA) │   audio    ├──────────────┤           └────────────┘
   │              │──────────▶ │  eb_ring_t   │──▶ AVAudioSourceNode
   │  one thread  │            ├──────────────┤
   │  owns it all │   tactile  │ 3-band SVF   │──▶ CHHapticEngine
   └──────┬───────┘            └──────────────┘
          │ input (atomic word)
   ┌──────▼────────────────────────────────────┐
   │  UIKit responder view → TouchControlsModel │
   └───────────────────────────────────────────┘
```

Five decisions are worth knowing about, because they are the difference between a
frontend that works and one that crashes on the device:

| Decision | Why |
|---|---|
| **Static archive, not `dlopen`** | A dynamic core means a nested Mach-O to sign, a copy phase, and a runtime load that can fail on the player's device. Static turns all of that into a link error on the build machine. |
| **One thread owns the core** | The core is not thread-safe. Every `retro_*` call happens on a single dedicated thread; video, audio and input leave through lock-free channels. |
| **Frame pacing is a servo** | Sleeping a fixed 1/60.0988 s drifts against the audio hardware, so the sleep is steered by how full the audio ring is. Audio stays in sync with no resampling. |
| **The core never sees a null option** | snes9x reads options and `strcmp`s the result *without* a null check. Answering "true" with a null value is a crash, so the full 43-key option table is embedded and anything unknown is answered "false". |
| **UIKit owns the touches** | SwiftUI's gesture system arbitrates between views, so holding B while pressing A is a conflict to resolve. One responder view with `isMultipleTouchEnabled` gets every touch and routes it. |
| **The ABI seam is one C file** | `Sources/Support/EBCoreGlue.c` includes `libretro.h` and nothing else does. Every constant Swift mirrors is `_Static_assert`ed against the real header, and every entry point is assigned to a pointer of its declared type — so a signature change in the core fails the build. |

---

## Building

You need macOS with Xcode 16 or later. Nothing else is required — no Apple
Developer account, no certificate.

```sh
make ipa        # build the core, generate the project, build the app, package dist/EarthboundWrapper.ipa
```

Other entry points:

```sh
make help       # list targets
make test       # build and run the C glue tests — needs no Xcode, runs in 0.2s
make check      # make test + make verify: everything checkable without Xcode
make simulator  # build both core slices and launch in the iOS Simulator
make open       # generate and open the Xcode project
make verify     # check the vendored libretro.h against the pinned core revision
```

`make test` covers the parts that fail silently on a device and cannot be
inspected there: the lock-free audio ring (round trip, overflow, wraparound, and a
2 MB concurrent transfer that verifies every byte's position across 512 wraps),
the shared joypad word, the variadic log shim, and the descriptor flattening. It
runs on Linux in a fifth of a second, and CI gates the iOS build on it.

The Xcode project is **generated**, not committed. `project.yml` describes it and
[XcodeGen] turns that into an `.xcodeproj`. Re-pinning the emulator core or adding
a source file never produces a merge conflict on a four-thousand-line `pbxproj`.

### On CI

`.github/workflows/build-ipa.yml` does the whole thing on a `macos-15` runner and
uploads an unsigned `.ipa` artifact. Push to `main`, or run it from the Actions
tab. The built core is cached, keyed on the pinned revision.

### Installing

The `.ipa` is unsigned, because signing needs a certificate that belongs to you.
Hand it to one of these:

- **[Sideloadly]** — installs from a computer over USB, re-signs with your Apple ID
- **[AltStore]** — installs and refreshes on-device, so the seven-day expiry is
  handled for you
- **Xcode** — open the generated project, set a development team in *Signing &
  Capabilities*, and run on a connected device

A free Apple ID gives you a seven-day signature; a paid account gives you a year.

### Getting a ROM in

Three ways, all supported:

1. The **+** button in the library, for a file already in Files or iCloud Drive
2. **AirDrop** the `.sfc` to the device and pick this app
3. Drop it into *On My iPhone → Earthbound Wrapper* in Files; it is picked up on
   launch

`.sfc`, `.smc`, `.fig` and `.swc` are accepted. Imported ROMs are copied into the
app's container, so a file in a temporary AirDrop folder survives the next launch.

---

## Tuning it

Everything that matters is in the in-game settings sheet, reachable from the
button in the top-left corner. It opens *over* the running game, so display changes
can be judged against the actual picture.

### Feel

| Control | What it actually does |
|---|---|
| **Widen** (in `Fill`) | Interpolates the image width from aspect-correct to the screen edges. `0%` is identical to `Fit`; past `~40%` you will notice circles becoming ovals. |
| **Zoom** | Crops in from all four edges. The SNES draws a lot of dead border — with overscan cropping on, this is mostly free magnification. |
| **Vertical** | Shifts the image up or down. Useful together with zoom, since the interesting part of a frame is rarely its centre. |
| **Bass / Treble / Hits** | Which bands reach the rumble, and how hard the detected onsets tap. Bass is the one that carries the weight; Presence is what makes text feel tactile. |
| **Direction ticks** | The knock when the stick snaps. Turn it off if it feels gimmicky; turn `Intensity` up if you cannot feel it through a case. |
| **Allow diagonals** | On, north-east holds Up and Right together — which is what the SNES does, and what you need to walk into a corner. Off gives a strict four-way stick. |

`Feel the current settings` plays a short audition built from the same primitives
the game uses, so it cannot drift away from the real behaviour.

### The emulator core

The core's own options are exposed too, grouped by what they affect. A few are
marked **reload**: snes9x reads those once, when a game loads, so changing one
mid-game does nothing until you restart. The sheet offers the restart and resumes
from your savestate.

Worth knowing about for EarthBound specifically:

- **Audio Interpolation: Gaussian** is the original hardware's warmth. `Cubic` and
  `Sinc` trade that for clarity, which also changes what the haptics latch onto.
- **Reduce Slowdown** helps the busier battles, at the cost of accuracy.
- **Blargg NTSC filter** is the composite-video look, if you want the CRT.

### Adding a feel

The tactile output is deliberately one small file: `Sources/Haptics/`.
`TactileSignal.swift` turns audio into bands and onsets; `HapticConductor.swift`
turns those into CoreHaptics. If you want the menu cursor to thump on its own, or
battle transitions to swell, that is where to add it — and
`Sources/Core/Snes9xOptions.swift` has the pattern for embedding anything from the
core that you would rather key off than infer.

---

## Layout

```
Sources/
  App/         entry point, ROM library, in-game screen, settings, app settings
  Core/        EmulatorSession (threading + pacing), the environment callback,
               constants, and the verified snes9x option table
  Video/       frame handoff, pixel expansion, Metal renderer, shaders, and the
               display-scaling model the renderer reads
  Audio/       AVAudioEngine output pulling from the ring
  Haptics/     band analysis and the CoreHaptics conductor
  Input/       joypad mask, multi-touch capture, the snapping stick
  Support/     EBCoreGlue.{h,c} and the bridging header — the ABI seam
scripts/       build-core, package-ipa, verify-core-pin, make-assets
tests/         glue_test.c (the ring, the input word, the log shim, descriptors)
               plus libretro stubs and a mach shim so it builds off macOS
ThirdParty/    the vendored libretro.h and the pinned revision
```

`Sources/Support/EBCoreGlue.c` is the seam. `libretro.h` is included there and
nowhere else; the Swift side sees plain C scalars and `void *`. Every constant
`Sources/Core/LibretroConstants.swift` mirrors is `_Static_assert`ed against the
real header, and every re-exported entry point is assigned to a pointer of its
declared type, so a signature change in the core is a compile error rather than a
crash on a phone.

---

## Honest limitations

- **The Swift side has no tests.** The C glue is covered, but the Swift pieces that
  deserve tests are not — `DirectionSnapping.direction(forAngle:)` and
  `BlitGeometry.destinationRect` are both free functions with no dependencies, and
  the eight-way snap in particular has boundary cases worth pinning down. A test
  target is the next thing this repo should have.
- **One core per build.** Static linking means adding a second system means a
  second target. That is a deliberate trade for not shipping a loader.
- **The core revision is pinned to a commit**, not a release. `make verify` keeps
  the vendored header honest against it; re-pinning is then a mechanical job.
- **Haptics need a Taptic Engine.** On hardware without one the app runs normally
  and simply does not rumble.
- **The IPA is unsigned.** Sideloading, not the App Store. snes9x's licence is
  non-commercial, which is also why this cannot go on the store.

## Licence

MIT for the frontend — see [LICENSE](LICENSE), which also spells out the two things
that are not covered by it.

In short: the only third-party code committed here is the MIT-licensed libretro API
header. snes9x is **not** in this repository — it is fetched at build time and
carries its own non-commercial licence, which a built binary is subject to. Super
Nintendo and EarthBound are trademarks of Nintendo; this project is unaffiliated
with them and ships neither their code nor their content.

[snes9x]: https://github.com/libretro/snes9x
[XcodeGen]: https://github.com/yonaskolb/XcodeGen
[Sideloadly]: https://sideloadly.io
[AltStore]: https://altstore.io
