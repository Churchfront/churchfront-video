# CueVideo

A simple ATEM control surface for church booths, with PTZ camera control and an
NDI preview monitor (usually the ATEM multiview). Part of the Cue family
(CueStack, CueScreens, CueLights, CueTracks). Native macOS 14+, SwiftUI.

- `Sources/CueATEM`: the shared engine. `ATEM.swift` speaks the ATEM network
  protocol (UDP 9910) with two-way state; `PTZ.swift` drives VISCA cameras
  (VISCA over IP UDP 52381, or VISCA over TCP 5678). Meant to be used by
  CueScreens (slide actions) and CueStack too.
- `Sources/NDIBridge`: copied from CueScreens; loads the NDI runtime at run time.
- `Sources/CueVideo`: the app. Simple mode (Live / Next / Cut / Fade / Black)
  for volunteers, Full mode adds keys, DSKs, styles, T-bar, macros and aux.

Build: `./build.sh` (or `./build.sh debug`) makes `CueVideo.app`.

Test without hardware: `python3 Tools/fake_atem.py 9910 --cams` starts a pretend
ATEM and three pretend VISCA cameras, then
`CUEVIDEO_HOST=127.0.0.1 CUEVIDEO_FAKECAMS=127.0.0.1 CUEVIDEO_SELFTEST=1 CUEVIDEO_SNAPSHOT=<folder> ./CueVideo.app/Contents/MacOS/CueVideo`
runs every command, prints the state after each, and writes screenshots.
Never run the self-test against a switcher that is live on a service.

Keys: 1 to 0 put a camera on Next, Shift plus a number cuts it to Live, Space
cuts, Return runs the transition, arrows move the selected PTZ camera.
