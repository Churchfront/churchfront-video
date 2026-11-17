# Windows port: handoff (2026-11-17)

Goal: a Windows version of Churchfront Video (the macOS app in this repo), in C# / .NET 8 WPF.
Scope for v1 ("core first"): ATEM switching, Operator view, PTZ joystick/zoom/shots/exposure
(Canon HTTP + VISCA UDP/TCP), Canon live previews (MJPEG video.cgi), Engineer pages (Setup,
Routing, Full switcher, Status), config.json in %APPDATA%\CueVideo, the 127.0.0.1:9911 control
server and cuevideo-mcp.exe for Claude. Later: NDI previews, auto tracking, stage scan.

## Layout

    windows/
      ChurchfrontVideo.sln
      build.ps1                 release build -> dist\ (two single-file exes + zip). -Test runs the smoke test first.
      NuGet.config              nuget.org (this machine had no package source; self-contained publish needs runtime packs)
      src/CueATEM               engine, plain net8.0: ATEM.cs, PTZ.cs (VISCALink, CanonLink, PTZController),
                                PTZModels.cs, CameraLogin.cs (Windows Credential Manager), SerialQueue.cs
      src/CueVideo.Core         net8.0: Config.cs (CueConfig + ConfigStore), Booth.cs, ControlTools.cs,
                                ControlServer.cs, DeviceFinder.cs (ATEM hello, Canon info.cgi, mDNS), ClaudeConnect.cs, Snapshots.cs
      src/CueVideoMcp           cuevideo-mcp.exe (port of Sources/CueVideoMCP/main.swift)
      src/ChurchfrontVideo      ChurchfrontVideo.exe, WPF in code (no XAML): Theme, Controls (Joystick, ZoomRocker,
                                dialogs, LiveView), OperatorView, EngineerView (+ Routing, Switcher, Status), SetupPage,
                                ExposureWindow, CanonFeed (MJPEG)
      tests/Smoke               55 checks against tools/FakeDevices. dotnet run --project tests/Smoke
      tools/FakeDevices         C# port of Tools/fake_atem.py (no Python on Windows): fake ATEM, VISCA cams that
                                answer inquiries, and a fake Canon on 127.0.0.1:8091 with MJPEG video

## Done and checked (2026-11-17)
- Everything builds; `.\build.ps1` makes dist\ChurchfrontVideo.exe (68 MB) and dist\cuevideo-mcp.exe (34 MB),
  self-contained and compressed, plus a zip.
- Smoke test: all 55 pass (config format both ways incl. Mac files, switching, fades, aux, DSK, macros,
  VISCA + Canon control/presets/exposure/position, shots, and Claude's tools incl. the Live guard).
- Ran the real app against FakeDevices: Operator view (monitors with the Canon picture, source tiles, shots
  grid, joystick, zoom, Fade/Cut/Black, key and route buttons), Full switcher, Setup tabs, Status.
  Keys 1-0, Shift+n, Space, arrows (stop on release, resent stop) and joystick drag all verified in the
  fake's log. Exposure window steps gain on the camera. Broken config.json: error shown, file set aside,
  last good setup kept.
- cuevideo-mcp.exe end to end: initialize, tools/list (cached while the app is closed), tools/call
  (opens the app if closed), camera_snapshots returns MCP image content.

## Not done / not checked
- Not tried against real hardware (ATEM, Canon, PTZOptics). Next step: a rehearsal, never during a service.
- "Connect Claude" (Setup > Claude) writes %APPDATA%\Claude\claude_desktop_config.json (and the MS Store
  package copy if present). Logic is ported but it was not pressed here, to leave this machine's Claude settings alone.
- Camera admin login save/delete preset with a real Canon (Digest/Basic via HttpClientHandler) is untested.
- mDNS in DeviceFinder is a hand-rolled one-shot query; check it finds NDI/PTZOptics devices on a real network.
- Not on Windows yet (tools say so, descriptions mark them): NDI previews (list_ndi_sources, ndi fields kept
  in config), auto tracking (start_tracking, set_tracking_shot; stop_tracking answers "nothing tracking"),
  stage scan. get_framing / set_framing / set_tracking_tuning work and save to the config for the Mac.
- Routing page edits mix names and changes what screens show; screens and route buttons themselves are
  edited in the setup file or by Claude (the Mac's RoutingPatch editor isn't ported).
- No installer or code signing: SmartScreen will warn on first run of the unsigned exe.
- Windows Firewall will ask on first run (UDP to the switcher/cameras); allow on private networks.

## Notes for whoever continues
- Threads: each engine part has a SerialQueue; results reach the UI through MainThread.Post (the app sets it
  to the WPF Dispatcher in Program.cs). PTZController and ConfigStore are used from the main thread only.
- Screens are LiveView subclasses: Build() runs when StructureKey() changes (and never while a TextBox in
  that page has focus); Live(...) registers in-place updates run ~30x a second by MainWindow's timer.
- Buttons whose light changes (T.LitButton) are updated in place, never rebuilt, so clicks aren't lost.
- WPF needs real globalization: Directory.Build.props sets InvariantGlobalization=true for the engine, and
  ChurchfrontVideo.csproj turns it off again.
- Any CUEVIDEO_ environment variable makes the config read-only and skips the control server (self-tests).
  CUEVIDEO_HOST/CUEVIDEO_PORT pick a switcher, CUEVIDEO_FAKECAMS=127.0.0.1 adds three VISCA cams,
  CUEVIDEO_VIEW=engineer:switcher opens a page.
- Manual test: `tools\FakeDevices\bin\Debug\net8.0-windows\FakeDevices.exe 9910 --cams --canon`, then a
  config.json with atemHost 127.0.0.1 and cameras on 127.0.0.1 (Canon port 8091, VISCA 52382/52383).
