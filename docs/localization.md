# Languages

Churchfront Video is in English and German. It follows the Mac's language; Setup > Switcher >
Language can override it for this app (System, English, Deutsch), from the next start.
That choice is kept in this Mac's preferences, not in the setup file.

## Where the words are

| Catalog | What's in it |
| --- | --- |
| `Sources/CueVideo/Resources/Localizable.xcstrings` | Everything the app shows |
| `Sources/CueATEM/Resources/Localizable.xcstrings` | Engine messages people see: camera and switcher problems, white balance names |

Both are String Catalogs, keyed by the English text. `swift build` compiles them into
`.lproj` folders, and `build.sh` copies them into the app: the app's into
`Contents/Resources`, the engine's as `Contents/Resources/CueVideo_CueATEM.bundle`.

These stay in English on purpose:

- **Claude's tools.** Tool descriptions and tool results in `ControlTools.swift` and `CueVideoMCP` stay English. Claude reads them, and replies in the person's language anyway.
- **Logs and reports.** The command log, the Status report (Copy report), the self-test output and the logs stay English. They get pasted to Claude, the system owner or upstream developers.
- **What people typed or the hardware reports.** Source, camera, shot, screen and NDI names come from the setup or the hardware.
- **Panel keys.** The keys on the Full switcher page (CUT, AUTO, MIX, KEY 1, FTB …) use the hardware's own words.

## Writing texts in code

- **Views.** A literal passed to `Text`, `Button`, `Label`, `.help`, `.alert` and the like is translated. So is a literal passed to the app's own views, which take a `LocalizedStringKey`: `LabelText`, `PillButton`, `PanelButton`, `Badge`, `Card`, `PageHeader`, `HelpButton`, `Tag`, `Fold`, `Col`, `IconButton`, `MenuField`, `Segments`.
- **Text outside views.** Use `String(localized: "…")`. Status words, alerts, and messages built in models all go this way. In CueATEM, use `String(localized: "…", bundle: .cueATEM)`.
- **Names.** Pass them as `.verbatim(name)` to the app's views, or as a `String` to `Text`, so nothing tries to translate them.
- **Values.** Put them in with interpolation: `String(localized: "\(camera.name) is on Live. Move it anyway?")`. The key becomes `%@ is on Live. Move it anyway?`. A translation can reorder the values with `%1$@`, `%2$@`.
- **Counts.** Write them in the plural, `"\(n) cameras will move."`. Then give the key plural forms in the catalog, in English too. Don't pick singular or plural in code.
- **Ternaries.** A ternary of two literals is safest as `cond ? String(localized: "A") : String(localized: "B")`.

## After changing what the app says

```sh
Tools/update-strings.sh
```

The script builds, and the compiler lists every localizable text. It then adds new texts to
the catalogs and marks removed ones as stale. Opening `Package.swift` in Xcode and building
does the same, and Xcode's catalog editor is the easiest way to translate.

Then translate the new texts. `swift test` fails until every text has a finished German
translation that takes the same values (`%@`, `%lld`) as the English. Texts that must never
be translated, such as `%@`, are marked "Don't translate" (`"shouldTranslate" : false`).

## Adding a language

1. Add it to `CFBundleLocalizations` in `build.sh`.
2. Add it to `AppLanguage` in `Sources/CueVideo/Localization.swift`, named in its own language.
3. Add it to `LocalizationTests.languages`.
4. Translate both catalogs.
5. Check the screens. Run the fake switcher (`python3 Tools/fake_atem.py 9910 --cams`), then open the app in that language: `"./Churchfront Video.app/Contents/MacOS/CueVideo" -AppleLanguages "(xx)"`, with the `CUEVIDEO_HOST` and `CUEVIDEO_FAKECAMS` settings from the README. Look for words cut off on buttons and tags.

## German glossary

The German speaks to the volunteer as *du*, short and plain. Switcher and camera terms that
are on the hardware stay English.

| English | German |
| --- | --- |
| Live | Live |
| Next | Nächstes (in sentences: "auf Nächstes legen") |
| Cut, Fade, Auto, FTB, T-Bar | Cut, Fade, Auto, FTB, T-Bar |
| Fading | Fade läuft |
| Black | Schwarz |
| On air | Auf Sendung |
| Preview, Program | Preview, Program |
| Key, DSK, Upstream key, Macro, Aux, M/E, Mix | Key, DSK, Upstream-Key, Macro, Aux, M/E, Mix |
| Switcher | Bildmischer, short: Mischer |
| Full switcher | Ganzer Mischer |
| Operate | Bedienen |
| Operator | die Bedienung |
| Setup | Einrichtung |
| Settings… (macOS menu) | Einstellungen … |
| Shot (a saved camera position or exposure) | Einstellung |
| Preset (stored on the camera) | Preset |
| Exposure | Belichtung |
| Gain, Shutter, Iris | Gain, Shutter, Iris |
| White balance | Weißabgleich |
| Daylight, Tungsten | Tageslicht, Kunstlicht |
| Pan, Tilt, Zoom | Pan, Tilt, Zoom |
| Track, Tracking, auto tracking | Verfolgen, Verfolgt, automatische Verfolgung |
| Stage scan | Bühnen-Scan |
| Wide shot | Totale |
| Shoulders up, Waist up, Full length | Ab Schultern, Ab Hüfte, Ganze Figur |
| Screen | Bildschirm |
| Source, Destination | Quelle, Ziel |
| Routing | Routing |
| Encoders and feeds | Encoder und Zuspielungen |
| Patch bay | Steckfeld |
| Lower thirds | Bauchbinden |
| Save | Sichern |
| Keychain | Schlüsselbund |
