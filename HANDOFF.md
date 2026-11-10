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

## Not tested yet
- A real ATEM (field layouts of InPr, RTMS, StRS may differ by firmware).
- Real PTZ cameras (Canon cameras may need their VISCA over IP setting turned on).
- Live NDI video in the monitor (the source found had no frames).

## Church network (192.168.20.0/24), from a quick scan; not yet confirmed
| IP | Hardware maker (MAC prefix) | Likely device |
|---|---|---|
| 192.168.20.31 | Blackmagic Design | ATEM switcher (check) |
| 192.168.20.91, .92, .93 | Canon | PTZ cameras (check) |
| 192.168.20.164 | Allen & Heath | Audio console |
| 192.168.20.206, .254 | Shure | Wireless receivers |
| 192.168.20.1 | Ubiquiti | Gateway |

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
