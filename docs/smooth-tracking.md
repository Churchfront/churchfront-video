# Smooth tracking (branch smooth-tracking)

Auto tracking on VISCA cameras (PTZOptics, OBSBOT) now drives the camera from a steady
control loop instead of once per analyzed picture. Canon cameras are unchanged unless
`smoothTracking` is set to true on them.

## What changed

- **Smooth drive.** The picture (10 to 20 times a second) decides where the camera should
  head. A loop running 30 times a second eases the camera's speed toward that: every start,
  stop and change of speed is an S-curve (acceleration builds up and dies away), and it lands
  on the new speed without going past it. Between pictures it works out where the person is
  now from their own motion and the camera's.
- **Stopping.** When someone stops walking, they slide back against the pan. A quarter of a
  second of that ends the walk follow at once, instead of the camera coasting on.
- **Back to the middle.** After a walk, the lead room eases out over a couple of seconds, so
  the camera drifts them back toward the middle rather than swinging there.
- **Stops always land (VISCA).** A VISCA camera keeps moving until it's told to stop. Every
  stop now goes out twice (0.3 s apart), and a speed change or stop the camera refuses is sent
  again (twice at most). Neither happens if anything else, such as a shot recall, has been
  asked of the camera since, so a recall is never cut short.
- **Speed table.** Tracking picks the nearest of the camera's 24 pan and 20 tilt speed steps
  and knows how fast that step really turns. Until a camera is measured it uses the standard
  table, which sends exactly the steps 0.1.3 did. A speed that comes out as the step already
  running isn't sent again.

## On site

1. Measure each PTZOptics (takes about ten minutes; the camera moves and comes back exactly
   where it was, so make sure it isn't on Live):

   ```
   CUEVIDEO_SPEEDTEST=192.168.2.154 "/Applications/Churchfront Video.app/Contents/MacOS/CueVideo"
   ```

   Add `CUEVIDEO_SPEEDPROTO=udp` for a camera on VISCA over IP (52381, the OBSBOT Tail 2).
   `CUEVIDEO_SPEEDLEVELS=1,2,4,8,12,16,20,24` measures fewer steps and fills in between.
2. It prints `"viscaPanSpeeds": [...]` and `"viscaTiltSpeeds": [...]`. Put both on that
   camera in config.json (or ask Claude to, with update_config).
3. Walk test: walk a few feet and stop, a long walk and stop, and stand and gesture. The
   tracking log (`tracking.csv`) shows what the camera was asked against what it did.

## Settings (per camera, config.json)

- `smoothTracking`: true or false. Left out: on for VISCA, off for Canon.
- `viscaPanSpeeds` (24 numbers), `viscaTiltSpeeds` (20): degrees a second per speed step.

## Tested

- `swift test`: 63 tests, including the stop repeat, the refused drive resent (and not after a
  recall), the standard table matching 0.1.3's steps at every speed, and the S-curve ramp
  (no overshoot, no reversal, acceleration capped, no jumps).
- The speed test against a pretend PTZOptics with known, uneven speeds: within about 1 to 3%
  of the truth on every step measured.
- Not yet: smooth drive on a real camera with a person walking. Not tried on a Canon.
