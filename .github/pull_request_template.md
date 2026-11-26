## What changed

<!-- One or two plain sentences anyone on staff would understand: what's different now and who notices. Details after. -->

## How it was checked

<!-- swift build, swift test; tried against Tools/fake_atem.py or real gear (which); what was NOT verified. -->

## Security

<!-- Required: the "Security section" check fails until every line is ticked. Tick a line that doesn't apply and add "n/a: why". See SECURITY.md. -->

- [ ] Nothing new listens on the network, or it binds to 127.0.0.1 only and requires the control key
- [ ] No passwords, keys or tokens in code, logs, config files or commits (logins go in the Keychain)
- [ ] Anything read from the network (ATEM, cameras, NDI, HTTP) is checked for size and shape before it's used, and can't crash the app
- [ ] AI (MCP) tools can't do anything a person couldn't do from the app's own screens, and can't read secrets
- [ ] No new outside packages, or each one is named here with why it's needed
- [ ] A person read the whole diff (AI-written code included) before merging
