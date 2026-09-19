## What and why

<!-- The reasoning matters more than the diff. What was wrong, or what was missing,
     and why is this the right shape of fix? If you considered an obvious
     alternative and rejected it, say so — that is the thing a future reader
     cannot recover from the code. -->

## Checks

- [ ] `make check` passes (C glue tests + vendored-header check)
- [ ] `make device` builds — or CI is green, which runs the same thing
- [ ] If a core constant or entry point moved, it is asserted in `EBCoreGlue.c`
- [ ] If the change is testable without Xcode, there is a test in `tests/glue_test.c`

## Tested on

<!-- Device and iOS version for anything input, audio, haptics or rendering related.
     The simulator does not exercise Taptic Engine paths at all. -->

- Build:
- Device:

## Anything a reviewer should be suspicious of

<!-- Optional, and often the most useful part. Known gaps, a tuning constant you
     guessed at, a path you could not test. -->
