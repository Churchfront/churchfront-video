# Handoff (2026-11-10)

Status of CueVideo when it moved from Jake's MacBook Pro to the church booth.

## Built
- ATEM engine (`Sources/CueATEM/ATEM.swift`): connect, full state from the
  switcher, program/preview, cut, auto, T-bar, transition style and rate,
  next-transition keys, upstream keys, DSKs (tie/cut/auto), fade to black,
  aux, macros, stream and record, tally by source.
- PTZ (`Sources/CueATEM/PTZ.swift`): VISCA over IP (UDP 52381) and VISCA over
  TCP (5678): joystick pan/tilt, zoom, focus, home, presets 1 to 8 recall and save.
  "Follow next" selects the camera whose ATEM input is on preview.
- NDI preview monitor (`Sources/CueVideo/NDIMonitor.swift`), meant for the ATEM multiview.
- UI: Simple mode (Live / Next / Cut / Fade / Black) and Full mode.

## Tested
- Every command above against `Tools/fake_atem.py` (fake ATEM plus three fake
  VISCA cameras) through the self-test; screenshots looked right.

- 2026-11-10 on the church's real ATEM 2 M/E Constellation HD (192.168.1.31,
  protocol 2.32): read-only probe (`CUEVIDEO_PROBE=1`) read every input, both
  M/Es, 4 keys, 2 DSKs, 12 aux. `CUEVIDEO_REALTEST=1` ran 25 commands (preview,
  cut, auto, T-bar, style, rate, next transition, key, DSK tie, aux, fade to
  black) and put everything back: 25 of 25 passed, twice.
- Fixed from the real switcher: it resends packets, so each is applied once
  (an old fade update was undoing a newer one); a finished auto can end with a
  program change and no final "not in transition" update; big switchers (12 aux)
  overflowed the panel; Record and Stream now show only on models that have them.
- CueStack's ATEM code (Devices.swift) has the same resend problem; fix it when it moves onto CueATEM.

## Not tested yet
- Real PTZ cameras. The three Canon CR-N cameras (.91, .92, .93) need VISCA
  over IP turned on in each camera's web page first (admin login).
- Live NDI video in the monitor (no multiview NDI source on the network yet).
- Macros (this switcher has none recorded).


## First steps at the booth
1. `./build.sh debug`
2. Read-only first: open the app, connect to the ATEM IP, confirm names, tally
   and state match the hardware panel before pressing anything.
3. Test commands one at a time with someone watching; never while live.
4. Add the PTZ cameras in settings (gear icon) and try the joystick and presets.
5. Turn on the multiview's NDI output in ATEM Setup and pick it from the NDI menu.

## Next after this
- Use `CueATEM` in CueScreens for ATEM actions on slides (its own branch; CueScreens is Matt's repo).
- Move CueStack's send-only ATEM code onto `CueATEM`.
- App icon.
