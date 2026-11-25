# Churchfront Video 0.1.3: RTSP camera pictures

Churchfront Video can now show a camera's live picture over RTSP. That's the way in for River Run's PTZOptics cameras, whose NDI|HX licenses are inactive (NDI stopped selling camera upgrades on Dec 31, 2025). RTSP needs no license and nothing extra installed.

## What changed

- **A picture source for each camera.** Setup, Cameras now has a Picture row under each camera: None, NDI or RTSP (and Canon preview for Canon cameras). Cameras set up before this release keep working exactly as they did.
- **RTSP, built in.** Churchfront Video speaks RTSP itself and decodes H.264 and H.265 on the Mac's hardware decoder (VideoToolbox). There is no FFmpeg or VLC inside, so nothing extra to bundle, sign or license.
- **Main and sub streams.** Each RTSP camera has a main and a sub address, defaulting to `rtsp://<camera ip>:554/1` and `/2`, and both can be edited. Tiles, auto tracking and snapshots use the sub stream. The Next and Live monitors use the main stream. Either can be switched per camera.
- **Low latency.** Video comes over the RTSP connection itself (TCP), with no buffering. Each picture goes to the decoder the moment its last packet arrives and shows on the next screen refresh. Decoding takes 4 to 7 ms a picture.
- **Reconnects on its own.** After a dropped cable or a camera reboot, the tile shows Offline with the reason, then retries after 2 seconds, backing off to 10. Other tiles keep running. A broken stream can't freeze the window.
- **Status on every tile.** Connecting, Live (size and frame rate, such as "640×360 · 30 fps"), or Offline with the last error. Status (Engineer, ⌘2) and Claude's `get_status` show each stream's address, state and decoder.
- **Saved with the camera.** The settings live in each camera's entry in `config.json` (`video`, `rtspMain`, `rtspSub`, `rtspTiles`, `rtspMonitors`), next to its VISCA settings. Claude's `update_config` knows the fields.
- **Kept apart from control.** Each stream runs on its own thread, away from the main thread, the ATEM connection and VISCA.

## Stream paths confirmed at River Run (2026-11-25, ffprobe over TCP)

| Camera | Main `/1` | Sub `/2` |
|---|---|---|
| Cam 2, PTZOptics `192.168.2.154` | H.264 High, 1280×720, 60 fps | H.264, 640×360, 30 fps |
| Cam 3, PTZOptics `192.168.2.172` | H.264 High, 1920×1080, 30 fps | H.264, 640×360, 30 fps |
| Cam 4, PTZOptics `192.168.2.181` | H.264 Baseline, 1920×1080, 30 fps | H.264, 640×360, 30 fps |

None of the three asks for a login. The OBSBOT Tail 2 (`.153`) answers on port 554, but `rtsp://192.168.2.153:554/` returned 400 Bad Request. Its path still needs finding in the OBSBOT app (optional for this release).

Cam 2's main stream is set to 720p60 while Cams 3 and 4 send 1080p30. That's worth matching in the cameras' own settings if the monitors should look alike.

## Tested

- All six streams open at once in the release build: every one decoded in hardware, first picture within about a second, 26% of one processor core in total.
- Pulled cable (simulated with a relay that goes silent): Offline, "No video for 5 seconds", retried with backoff, then Live again on its own. The other camera kept running.
- 48 unit tests pass, including 11 new ones for the RTSP parts (SDP, RTP reassembly, lost packets, Digest login, old config files).
- `CUEVIDEO_RTSPTEST=url,url` runs the stream check headlessly. It only watches video, so it's safe during a service.

## Still to test on site

- Glass-to-glass latency (wave a hand in front of the lens).
- A real cable pull on one camera.
- VISCA and ATEM control while all streams run.
- Quit and relaunch to confirm the settings were kept.
