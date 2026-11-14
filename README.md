# MainStage Controller

**FOH Remote**, an iPad mixer for running MainStage as a front-of-house console, and **FOH Bridge**, its Mac companion. The iPad talks OSC over Wi-Fi to **FOH Bridge**, a small menu-bar app on the Mac. The bridge turns that into MIDI on four virtual ports that MainStage learns once.

- [PLAN.md](PLAN.md): architecture, the MIDI map, the processing learn, phases and status.
- [SPIKES.md](SPIKES.md): spike results and the remaining MainStage-side checks.
- Design canvas: https://claude.ai/artifact/VSR85Bv2h6HcEoYoJ15D61

## What's in it

**FOH Remote (iPad):**

- **Mixer**
  - Strips grouped as inputs, FX returns and outputs.
  - Each strip has meters (input via the bridge, FX returns via the FOH Meter plugin, outputs via a MainStage tap), a mini EQ, G/C/insert badges, pan, mute/solo and a fader.
  - Sends-on-faders, a guarded master (hold to arm), click and tempo.
- **Channel**
  - **EQ**: built from the strip's binding (SSL bands for Lead vox and Guitar), with an RTA overlay.
  - **Dynamics**: SSL compressor and expander/gate.
  - **Inserts**: macro pages, such as Waves Tune's 17 keys and 44 scales.
- **Routing**: a sends matrix (inputs × buses), "not in concert yet" flags, and per-input sends.
- **Setup flow**
  1. **Channels & I/O**: add/edit/remove strips and sends, and import from the concert.
  2. **Processing**: bind app controls to plugin parameters, apply to another strip, reset to template.
  3. **MainStage learn**: walks you through every bound role, shared with the Mac's Learn HUD.
  4. **Verify**: wiggle each control and confirm MainStage follows.
- **Connection**: bridge status, Pull from MainStage, Push all, guard settings, and "N of M values confirmed by MainStage".
- **Values MainStage hasn't confirmed** show a dimmer "≈". A value counts as confirmed once MainStage has reported it through "Send Value to".
- **Backup & restore**: the bridge's automatic snapshots (taken before risky changes, newest 30 kept), Snapshot now, and Export/Import of `.fohshow` files.
- **Plugin templates**: the built-in templates (SSL Channel, Waves Tune, Pro-Q 3) and your own. Use "Save as template…" in Processing.
- **Reorder strips** in Channels & I/O. This changes display order only; MIDI addresses never change.
- **Toasts** confirm Pull, Push, patch changes, merges, restores and template saves.
- **Safety**: lock mode, offline banner, and reconnect with backoff.

**FOH Bridge (Mac menu bar):**

- Four virtual MIDI ports with stable IDs.
- OSC over TCP, advertised over Bonjour.
- Off-line plugin discovery, templates and manual bindings.
- Concert import (Import concert…). Reading runs in the background, so a macOS folder-access prompt never stalls MIDI.
- Backups, custom templates and acknowledgements.
- Log mirrored to `~/Library/Logs/FOH Bridge.log` (capped at 10 MB).
- **Damaged state files:** if `show.json`, `values.json`, `learn.json` or `overrides.json` won't read at launch, the bridge keeps the file (renamed `*.unreadable-<date>.json`), restores that part from the newest backup and shows a warning at the top of the menu. It never silently starts over and saves the default over your show.
- Setlist (Program Change on FOH Global) and Pull from MainStage.
- Input metering, the MainStage output tap and RTA. Outputs are metered per channel of MainStage's output device, so Output 1/2 get their own meters.
- **FX return meters** come from **FOH Meter** (`Apps/FOHMeter`), a pass-through Audio Unit you insert in MainStage. An aux return has no interface input or output of its own, so only something inside MainStage can measure it. While MainStage plays, the plugin sends its strip's peak and RMS to the bridge (UDP on 127.0.0.1:9009, about 25 times a second). The bridge matches it to a strip by the MainStage channel strip name. A strip with FOH Meter on it shows that meter instead of its hardware one, so it also works on any other strip you want metered after its plugins.
- Input meters follow the interface. Plug in or unplug the chosen device (e.g. the Scarlett) and the meters switch within about half a second. While it's unplugged they read nothing and the menu, `fohctl sync` and the iPad's Connection screen say "waiting for Scarlett 2i2 USB". They never fall back to the built-in mic. With "System default input" they follow macOS's default input.
- **Learn HUD**, a floating panel with hotkeys: ⌃⌥Space sends the sweep, ⌃⌥→ marks it learned and moves on, ⌃⌥← goes back.

## Layout

```
Packages/FOHCore/          Swift package
  Sources/FOHCore/         shared model: roles & CC map, addressing, OSC + SLIP, show, concert, plugins,
                           bindings & templates, learn state, meters/RTA codecs, calibration
  Sources/FOHMacKit/       macOS: virtual MIDI ports, AU plugin discovery, concert parser, BridgeServer,
                           Audio/ (input capture, MainStage process tap, RTA analyser)
  Sources/fohctl/          command-line tool for spikes, calibration and headless testing
  Tests/FOHCoreTests/      unit tests (incl. real SSL Channel / Waves Tune discovery fixtures)
  Tests/FOHMacKitTests/    concert parser (Church.concert fixture), bridge, audio DSP tests
Apps/FOHBridge/            macOS menu-bar app (wraps BridgeServer, Learn HUD)
Apps/FOHMeter/             FOH Meter, the metering Audio Unit for MainStage (plain C, AUv2)
Apps/FOHRemote/            iPad app (SwiftUI)
Apps/FOHRemoteUITests/     XCUITest: real taps/drags, offline or against a live bridge
project.yml                XcodeGen spec → FOH.xcodeproj (generated, not committed)
```

## Build and run

You need Xcode 27+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen generate
```

```bash
cd Packages/FOHCore && swift test
```

Open `FOH.xcodeproj` and run **FOHBridge** (My Mac) and **FOHRemote** (your iPad, or the iPad Pro 12.9" simulator).

**Install FOH Bridge for services:** after building the FOHBridge scheme, run the script below. It copies the app to
`/Applications/FOH Bridge.app` and adds a login item (`~/Library/LaunchAgents/io.itstudios.foh.bridge.agent.plist`), so the
bridge opens at login and restarts if it ever crashes. Quit from its menu stays quit. Run it again after each rebuild;
`--uninstall` removes the login item.

```bash
Tools/install-bridge.sh
```

**First launch of FOH Bridge:** macOS asks for two permissions.

- **Microphone**: input meters and RTA from your audio interface.
- **System Audio Recording**: MainStage output meters.

Without them, everything still works, just without meters. Pick the audio interface once in the menu's **Input** picker; the bridge remembers it and picks it up whenever it's plugged in.

**FX return meters:** install FOH Meter, then in MainStage insert **Audio Units › FOH Remote › FOH Meter** as the last
plugin on each FX return (e.g. VRB Return) and save the concert. The bridge menu and the iPad's Connection screen list the
strips it hears from. Run the script again after changing the plugin, and bump its `version` in `project.yml`.

```bash
Tools/install-meter.sh
```

**On your iPad Air 13":**

1. Sign Xcode in to your Apple ID. A free Personal Team works: put its team ID in `project.yml` (`DEVELOPMENT_TEAM`), then run `xcodegen generate`. `xcrun devicectl list devices` shows your iPad's UDID for the commands below.
2. Connect the iPad with a cable, trust the Mac, and turn on Settings › Privacy & Security › Developer Mode.
3. Build and install, either from Xcode (Run on the iPad) or from the command line:

   ```bash
   xcodebuild -project FOH.xcodeproj -scheme FOHRemote -destination 'id=<your-iPad-UDID>' -derivedDataPath build/DD-device -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
   ```

   ```bash
   xcrun devicectl device install app --device <your-iPad-UDID> build/DD-device/Build/Products/Debug-iphoneos/FOHRemote.app
   ```

   ```bash
   xcrun devicectl device process launch --device <your-iPad-UDID> io.itstudios.foh.remote
   ```

4. The first time, trust the developer certificate on the iPad: Settings › General › VPN & Device Management.
5. Allow **Local Network** when asked. With the iPad on the same Wi-Fi as the Mac, it finds the bridge over Bonjour.
6. If the Mac firewall asks about FOHBridge, allow incoming connections.

**Keeping it installed:** with a free Personal Team, iOS stops opening the app 7 days after it was signed. That's
Apple's limit; a paid Developer Program membership ($99/year) makes it a year. The refresh script rebuilds the app with
a fresh 7-day profile and reinstalls it over Wi-Fi (`devicectl` reaches the iPad wirelessly after the first cable
install). Your settings on the iPad are kept.

```bash
Tools/refresh-ipad.sh --enable
```

After that, FOH Bridge runs `Tools/refresh-ipad.sh --if-due` every 2 hours. It renews once under 4 days are left,
never while FOH Remote is connected, and not while MainStage is running unless under 12 hours are left. The first time,
macOS asks whether FOH Bridge may access your Documents folder (the project lives there); allow it. The menu shows when
the app expires and the last result. If it can't renew within the last day, a notification says why (usually that the
iPad is asleep or on another network). `Tools/refresh-ipad.sh` renews right away, and `--status` shows where it stands.

**First-time setup:**

1. Import your concert: FOH Bridge menu › Import concert…, or iPad Setup › Channels & I/O.
2. Check Setup › Processing.
3. Write the assignments into a copy of your concert (below), and open the copy in MainStage. The fallback is
   Setup › MainStage learn alongside MainStage's Assignments & Mappings (⇧⌘M), using the Mac Learn HUD's hotkeys.
4. Run Setup › Verify.
5. Calibrate the fader scale once (below).

## Useful commands

`fohctl` is at `Packages/FOHCore/.build/debug/fohctl` after `swift build`.

```bash
fohctl assignments --out /tmp/a.json    # every bound role's MIDI address, for the concert writer
python3 Tools/concert-format/concert_write.py --assignments /tmp/a.json ~/Desktop/Church.concert ~/Desktop/"Church Mapped.concert"
fohctl calibrate fader --strip in/1      # S5: type MainStage's fader readings → exact dB scale on every fader/send
fohctl calibrate param --path /foh/in/1/band/2/gain   # S5: check a plugin's value table against MainStage
fohctl backup list|create <reason>|restore <id>|export <file>|import <file>
fohctl template list|save <strip> <name> <use> <position>|delete <id>
fohctl concert ~/Desktop/Church.concert  # what the concert parser finds
fohctl merge                             # import the concert into the running bridge's show
fohctl learn [next]                      # learn walk-through state
fohctl devices | meters | rta --channel 1 | tap --pid N   # audio inputs, live meters, RTA, process tap
fohctl params SCHM / bind SCHM           # plugin discovery and the SSL template
fohctl monitor all                       # the MIDI MainStage receives (restart it after relaunching FOH Bridge)
fohctl feedback "FOH In 1-16" 1 26 40    # pretend to be MainStage "Send Value to"
fohctl osc /foh/in/1/mix/fader 90        # set Lead vox's fader via OSC
fohctl sync                              # summarise the bridge's state
fohctl bridge --port 9124 --suffix " (test)" --store /tmp/foh-test   # an isolated test bridge
```

**Concert writer tests:** `python3 Tools/concert-format/test_concert_write.py`. See
[CONCERT_FORMAT.md](Tools/concert-format/CONCERT_FORMAT.md) for what it writes and why.

**UI tests** (real touches through XCUITest):

- Offline: `xcodebuild test -project FOH.xcodeproj -scheme FOHRemote -destination 'platform=iOS Simulator,name=…'`
- Against a live bridge: prefix the command with `TEST_RUNNER_FOH_HOST=127.0.0.1:9124`.

**FOH Remote launch arguments:**

- Screens: `-screen mixer|eq|dynamics|inserts|routing|connection|channels|processing|learn|verify|backup|templates`
- Connection: `-demo`, `-host 127.0.0.1:9000`
- Selection: `-strip in/2`, `-sof 3`
- States: `-import`, `-locked`, `-armed`, `-offline`, `-reorder`, `-toast`
- Testing: `-e2e`

## License

MIT. See [LICENSE](LICENSE).
