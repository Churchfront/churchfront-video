# CueVideo

A simple ATEM control surface for church booths, with PTZ camera control and live
camera previews. Part of the Cue family (CueStack, CueScreens, CueLights,
CueTracks). Native macOS 14+, SwiftUI.

- `Sources/CueATEM`: the shared engine. `ATEM.swift` speaks the ATEM network
  protocol (UDP 9910) with two-way state; `PTZ.swift` drives Canon cameras over
  Canon's HTTP control and VISCA cameras (VISCA over IP UDP 52381, or VISCA over
  TCP 5678); `CameraLogin.swift` keeps the cameras' admin login in the Keychain.
  Meant to be used by CueScreens (slide actions) and CueStack too.
- `Sources/NDIBridge`: copied from CueScreens; loads the NDI runtime at run time.
- `Sources/CueVideo`: the app.
  - Main window, for volunteers: Next and Live monitors, the source row, then
    exposure, saved shots, the joystick and Fade / Cut / Black / key buttons.
    Camera controls always act on the camera on Next.
  - Setup window (⌘,): switcher, source row, key buttons, cameras and their shots,
    the camera admin login, and a Status tab with a log of every command sent.
  - Full Switcher window (⇧⌘K): keys, DSKs, styles, T-bar, macros and aux.
- `Sources/CueVideoMCP`: the MCP server Claude uses (see below).

Build: `./build.sh` (or `./build.sh debug`) makes `CueVideo.app`.

## Setup file

Everything set up in the app is saved as plain JSON in
`~/Library/Application Support/CueVideo/config.json`: the switcher address, the
M/E volunteers run, the source row, key buttons, cameras and each camera's saved
shots. The app picks up edits to the file within a second, so a person or Claude
can set CueVideo up by editing it. The camera admin login is never in this file.

## Claude (MCP)

`CueVideo.app/Contents/MacOS/cuevideo-mcp` is an MCP server with a tool for every
action in the app (status, Next/Live/Cut/Fade/Black, keys, record and stream,
camera moves, exposure, shots and presets, the full switcher, setup). It passes
calls to the running app over 127.0.0.1:9911, using the key in
`~/Library/Application Support/CueVideo/control-token`, and opens CueVideo if it
isn't running. `.mcp.json` registers it for Claude Code sessions in this folder.
Camera tools refuse a camera that's on Live unless the call says `allow_live: true`.

## Canon cameras take one controller at a time

Only one session controls a Canon camera at a time. If another controller (another
copy of CueVideo or CueStack, a Companion Canon connection, an RC-IP100) keeps
claiming the same cameras, the two trade control and the joystick seems broken.
CueVideo shows "waiting for control" when this happens; close the other one.

## Testing without hardware

`python3 Tools/fake_atem.py 9910 --cams` starts a pretend ATEM and three pretend
VISCA cameras, then
`CUEVIDEO_HOST=127.0.0.1 CUEVIDEO_FAKECAMS=127.0.0.1 CUEVIDEO_SELFTEST=1 CUEVIDEO_SNAPSHOT=<folder> ./CueVideo.app/Contents/MacOS/CueVideo`
runs every command, prints the state after each, and writes screenshots. Self-tests
never write to the setup file. Never run the self-test against a switcher that is
live on a service.

Keys: 1 to 0 put that source-row tile on Next, Shift plus a number cuts it to Live,
Space cuts, Return fades, arrows move the camera on Next.
