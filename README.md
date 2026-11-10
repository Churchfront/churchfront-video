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

## Video routing

**Window → Video Routing** (⇧⌘R) shows how pictures reach the screens:

- **Mixes:** what each M/E is for (M/E 1 the live stream, M/E 2 the side screens), what's on it, and quick buttons to switch the mix the volunteer doesn't run.
- **Screens and outputs:** every aux output, as picture → aux → the screen it feeds and how it's wired. Pick a new picture from the menu and it changes right away. Linked auxes (such as a pair of lobby TVs) switch together. Outputs that feed encoders, recorders or the patch bay can be hidden from volunteers.
- **Volunteer routing buttons:** route the screens the way you want, then save that as a button. The buttons sit in the bottom right of the main window, work like macros (one press can change several screens), and light up while the screens match them. Below them, a short summary says what each volunteer-facing screen is showing.

In the config file, this is `mixNames`, `screens` and `routes`. Claude can use `get_routing`, `route_screen` and `run_route_button`. `route_screen` refuses hidden outputs, such as the stream encoder, unless the call says `allow_hidden: true`.

## Graphics and lower thirds previews (NDI)

Tiles and the Next and Live monitors can show any NDI source, typically a CueScreens screen with an NDI output added. In Setup, under Volunteer source row, pick the NDI picture for a non-camera source such as Graphics. Under Key buttons, pick an NDI source with alpha (such as CueScreens' lower thirds sent with alpha). It is laid over the Next and Live pictures when the key is on them: on Live when it's on air, and on Next when it will be on air after the next Cut or Fade (a tied DSK or a key selected in the next transition).

Previews use NDI's low-bandwidth preview stream, so they cost little network or processor time. They need the NDI runtime on this Mac (NDI Tools). In the config file, it's the `ndi` field on a source or key, with the exact name from Setup or Claude's `list_ndi_sources`. The preview shows what CueScreens is drawing, not the switcher's actual output.

## Auto tracking

**Track** (under the joystick) makes the Canon camera on Next follow the person nearest the middle of its shot. Click a person on the Next picture to follow them instead. CueVideo finds people and their body landmarks (eyes, shoulders, hips, ankles) in the camera's preview picture with Apple's Vision framework. It works out whether the shot is **shoulders up**, **waist up** or **full length**, and frames it the way a broadcast operator would:

- Eyes near the upper third line, with headroom to suit the shot size.
- Frame edges between joints: mid-chest, just below the waist, or a little room under the feet.
- Lead room on the side the person faces or walks toward.
- A dead zone, so the camera doesn't chase small moves, with eased starts and stops.
- Slow zooms that hold the shot size as the person comes nearer or moves away.

The Close / Waist / Full buttons under Track reframe the shot. Zooming by hand keeps tracking going and holds the new size. Moving the joystick, recalling a shot or preset, or clicking the badge on a monitor stops tracking. The person being followed is outlined on every picture of that camera, and tracking carries on when the camera goes Live.

The preview runs slightly behind real time, so tracking suits someone walking the stage, not running. Follow speed (0.5 to 2), tilt on/off and zoom-to-hold-size are in Setup and the config file (`trackSpeed`, `trackTilt`, `trackZoom`). The framing numbers live in `ShotSize` in `Tracker.swift`. Claude can use `start_tracking`, `set_tracking_shot` and `stop_tracking`.

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
