# Security

Churchfront Video runs on the production Mac in a church's booth, on the same network as its
switcher and cameras. This page says what the app exposes, how changes are checked before they
ship, and how to tell us about a problem.

## Reporting a problem

Please don't open a public issue for a security problem. Use **Report a vulnerability** on this
repository's **Security** tab, which reaches Churchfront privately. Tell us what you found, how to
reproduce it, and which version you were running. We'll reply, fix it, and credit you in the
release notes if you'd like.

## What the app exposes

- **Nothing to the internet.** The app opens no ports a church's router would forward, and
  nothing it runs can be found by internet scanners such as Shodan unless the church itself has
  exposed the Mac.
- **One local control port.** `127.0.0.1:9911` lets the Claude connector (`cuevideo-mcp`) drive
  the app. It accepts connections from this Mac only, and every request must carry a random key
  stored in `~/Library/Application Support/CueVideo/control-token`, readable only by the signed-in
  user.
- **Outbound only to your gear.** The app connects out to the ATEM switcher, the PTZ cameras
  (Canon HTTP, VISCA over IP) and NDI sources on the local network. It never accepts connections
  from them.
- **Camera admin login in the Keychain.** The optional Canon admin login is kept in the macOS
  Keychain, never in the app's settings file. Canon's control protocol is plain HTTP, so keep the
  cameras on a production network or VLAN that guests can't join.

## How changes are checked

Every pull request into `main` must pass these checks before it can merge:

| Check | What it does |
| --- | --- |
| **Code** | Builds the app and runs the tests on macOS. |
| **Security** | Scans the PR's commits for passwords and keys (gitleaks); fails if anything new listens on the network outside the reviewed control server, or if that server stops binding to 127.0.0.1; fails if a package from outside Churchfront is added. |
| **Security section** | The PR description's Security checklist is filled in, every line ticked or marked n/a with a reason. |

Some of this code is written with AI assistance. AI-written code gets the same checks and a
person reads the whole diff before it merges; the checklist says so.

GitHub's own secret scanning (with push protection), Dependabot alerts and private vulnerability
reporting are on for this repository.
