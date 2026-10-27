# Phase 1 spikes

This file records what each spike asked, how it was tested and what came back. "Autonomous" spikes ran on this Mac with no MainStage. "MainStage" spikes need you at the Mac for a few clicks; the steps are below.

Unless noted, every command runs from the repo root after setup:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # Xcode, not the Command Line Tools
cd Packages/FOHCore && swift build && cd ../..
alias fohctl="$PWD/Packages/FOHCore/.build/debug/fohctl"
```

| # | Question | Status |
|---|---|---|
| S8 | Can the bridge load your plugins off-line and read their parameters? | ✅ **Pass** (autonomous) |
| S1 | Do the virtual ports work, keep stable IDs, and carry MainStage feedback? | ✅ **Pass** (2026-10-25): MainStage follows; feedback works; echo round trip 0.5–1.6 ms |
| S2 | Do booleans learned as continuous behave absolutely at 0/127? | ⏳ MainStage |
| S3 | Can "Send Value to" be set in bulk, or set automatically by Assign & Map? | ✅ **Moot** (2026-10-25): the concert writer writes every assignment with "Send Value to"; MainStage loaded all 81 and reported every value on load |
| S4 | Do meter screen controls stream levels through "Send Value to"? | ⏳ MainStage |
| S5 | Does MainStage map 0–127 linearly over a plugin parameter's range, and what is the fader law? | ✅ **Pass** (2026-10-25): fader law = estimate within 0.1 dB (calibration saved); SSL LMF Gain 5/5 exact |
| Format | How does MainStage store assignments and mappings? | ✅ **Decoded** (2026-10-25): see `Tools/concert-format/CONCERT_FORMAT.md` |
| Writer | Can every assignment be written straight into a concert? | ✅ **Pass** (2026-10-25): 81 assignments for Lead vox and Guitar, all shown in Assignments & Mappings, 83/117 values confirmed on load |
| S6 | How does MainStage perform with hundreds of assignments? | ✅ **Pass** (2026-10-25): 1,074 hidden plugin controls load and report in 173 ms, idle CPU unchanged, echoes ~8 ms; memory cost not isolated (see "Phase 0") |
| S7 | How do 7-bit faders feel? | Later (on the iPad) |
| E2E | iPad ⇄ Bridge ⇄ MIDI with no MainStage | ✅ **Pass** (autonomous) |
| E2E-touch | Real taps and drags (XCUITest) → Bridge → MIDI | ✅ **Pass** (autonomous, Phase 2) |
| Audio | Input meters, MainStage output tap, RTA | ✅ DSP tests pass · ⏳ live levels need your Microphone / System Audio Recording OK |

**S5 is now self-serve.** Once Lead vox's fader and a plugin parameter are learned, run these and type what MainStage shows:

```bash
fohctl calibrate fader --strip in/1
```

```bash
fohctl calibrate param --path /foh/in/1/band/2/gain
```

- **`calibrate fader`** stores the readings in the show (`faderCalibration`). Every fader and send readout on the iPad then follows MainStage exactly.
- **`calibrate param`** reports whether the plugin's value table matches MainStage (✓/✗ per value).

---

## Phase 2 results (2026-10-24)

**Real-touch end to end ✅.**

- **Setup:**
  - `Apps/FOHRemoteUITests` drove FOH Remote on a simulator.
  - It used XCUITest's own touch synthesis. The Claude Simulator panel's touch injection doesn't work with the iOS 17.2 runtime under Xcode 27, and neither does its Home button.
  - The test bridge ran with `--port 9124 --suffix " (test)"`.
- **Results:**
  - Tapping Lead vox's MUTE sent `CC 1 = 127` then `0`.
  - Dragging the fader sent a smooth `CC 7` stream from 90 → 111 → 90, coalesced at 60 Hz.
  - The Setup flow test opened Channels & I/O → Processing → MainStage learn → Verify.

**Bridge loopback ✅** (from the Bridge agent, on isolated test ports):

- Concert merge of `~/Desktop/Church.concert`: 8 strips, 1 patch.
- Config set round trip.
- Manual binding (Lead vox band.2.gain → HMF Gain) survives a forced rediscovery, and Apply copies it to Guitar.
- Patch select sends `status=C0` on FOH Global.
- Learn state broadcasts to a second client.
- Meters reach clients at 25 Hz (fake source) with 59-band RTA frames.
- Silent clients are dropped after 10 s.

**Concert parser ✅.** Tests run against a copy of `Church.concert`:

- Lead vox is a patch-level audio input on In 1, with Waves Tune RT, Pro-Q 3 and SSLChannel (preset "AT Femal Vocal 1", Waves' own spelling) and send 1 → bus 1.
- Botta Church is an aux fed by Bus 1, and Metronome is an instrument (not shown on the mixer).
- The setlist is "Song One".

**Audio:**

- **DSP tests pass:**
  - A 1 kHz sine lands in the 1 kHz band at the right level.
  - Pink noise is flat within ±2.5 dB from 100 Hz to 10 kHz.
  - Peak/RMS, peak hold and band coverage are correct.
- **Live levels are blocked by macOS permissions, not code:**
  - The input waits on the Microphone prompt.
  - The process tap delivers silence until System Audio Recording is allowed.
  - FOH Bridge.app asks for both on first launch.
- **Output tap scope:** it currently captures MainStage's **stereo mix**, so Main gets meters. Output 1/2 need per-channel tapping, which is a follow-up.

---

## End-to-end without MainStage ✅

Setup:

- The real **FOHBridge.app** running.
- `fohctl monitor "FOH In 1-16"` standing in for MainStage's MIDI input.
- **FOH Remote** in the iPad Pro 12.9" Simulator (iOS 17.2, the same 1366 × 1024 screen as the iPad Air 13"), launched with `-host 127.0.0.1:9000 -e2e`.
- `-e2e` drives Lead vox controls through the app's real store → client → TCP path once it has synced.

**iPad → Bridge → MIDI.** Every message arrived on FOH In 1-16, ch 1, as MainStage will receive it:

```
CC 1 = 127 / 0   (mix.mute on, off)
CC 7 = 100       (mix.fader → est. +1.8 dB)
CC 26 = 100      (band.2.gain → SSL LMF Gain +8.6 dB)
CC 12 = 0        (eq.on = 127 → inverted onto SSL EQBypass)
CC 105 = 60      (ins.1.macro.3 → Waves Tune Scale Root "F")
CC 25 = 64       (band.2.freq dragged to 1.01 kHz — "KHz" unit handled)
```

**MainStage → iPad.** `fohctl feedback` simulated "Send Value to" with CC 30=20, 27=100, 19=127 and 12=0. The iPad's EQ page updated live: HMF −10.3 dB, LMF Q 0.78, HF switched to BELL, and EQ IN lit.

**Bridge headless loopback** (from the Bridge agent):

- A learn sweep sends 65 CC messages, 0→127→0.
- `learn/send` sends one raw value.
- A fresh discovery binds Lead vox to 56 roles (14 channel strip, 29 SSL, 9 Tune, 4 Pro-Q 3) and Guitar to 43.

**Fixed along the way:**

- A fresh bridge cache used to read 0 for everything, which showed every gain at −15 dB and every fader at −∞. The bridge now seeds unseen roles with the plugin's own defaults, plus unity fader and centre pan, until MainStage feedback replaces them. Nothing is sent to MainStage.
- Dragging frequency on the EQ graph now honours the "KHz" unit.
- Off/On parameters that aren't flagged as boolean (Tune "Formant") are treated as switches.

**Not testable here:** real touch input. The Claude Simulator panel needs `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`, which needs your password. The script path covers the same code, but finger feel (S7) is for you on the iPad.

---

## S8: plugin discovery ✅

`fohctl params <name>` loads an Audio Unit off-line through AVFoundation and reads its full parameter tree. Results on this Mac (Waves V15, FabFilter):

| Plugin | Component | Params | Load time |
|---|---|---|---|
| Waves SSLChannel (m) | `aufx/SCHM/ksWV` (matches the concert file) | 36 | 1.1 s |
| Waves Tune Real-Time (m) | `aumf/LVLM/ksWV` | 43 | ~1 s |
| FabFilter Pro-Q 3 | `aumf/FQ3p/FabF` | 358 | 0.13 s |

What was learned:

- **Real SSL parameter names:**
  - `InputLevel` (−18…+18 dB) is the input trim, and `Gain` (−24…+12 dB) is the output trim.
  - `PhaseReverse`, `HP Frq`, `LP Frq`, and `LF/LMF/HMF/HF Gain/Frq` (Q on LMF/HMF), plus `LF Type` / `HF Type` (bell).
  - `CompThresh/Ratio/Fast/Release`, and `ExpThresh/Range/Attack/Release` with `ExpGate`.
  - `FilterSplit`, plus `EQBypass` and `DynamicBypass`.
  - The SSL template now uses these names: **29/29 roles bind**, and the 14 "not in plugin" roles match PLAN.md exactly.
- **Bypass switches are inverted.** `EQBypass` / `DynamicBypass` mean "On = bypassed", so they bind to `eq.on` / `dyn.on` with `invert`. The bridge sends 127 − value.
- **Waves normalizes every knob to 0…1000.** The plugin applies its own taper. If MainStage maps linearly across 0…1000 (S5), MIDI feels exactly like turning the plugin's knob.
- **Some knobs run backwards:** Q goes 3.50 → 0.10, CompThresh +10 → −20 dB, and ExpThresh −30 → +10. The value tables handle this, so the iPad shows the right numbers.
- **No exact 0.0 dB on ±15 dB gains.** MIDI 63 = −0.1 dB and 64 = +0.1 dB (7-bit). "Flat" sends 64. This is inaudible but visible in the readout.
- **Waves reports `CompRelease` / `ExpRelease` in "ms"** while the values are seconds (0.10–4.00), so the template overrides the unit to `s`.
- **SSL exposes gain-reduction meters** (`CompAttn`, `ExpAttn`) and `VU` as parameters. That's a possible GR source if S4 shows meters can stream.
- **Waves Tune:** `Scale Root` has 17 steps (C…B) and `Scale Type` has 44. The iPad sends the MIDI value at the centre of each step (`RoleBinding.stepCenters`).
- **Pro-Q 3** band frequencies are log2 internally (10 Hz…30 kHz), so a linear MIDI map gives a musical sweep.
- **Waves prints harmless Objective-C duplicate-class warnings** (WaveShell vs WavesLib) when loaded outside a DAW.

The raw dumps are test fixtures in `Packages/FOHCore/Tests/FOHCoreTests/Fixtures/`. `FOHCoreTests.testLeadVoxBindingFromRealSSLDiscovery` builds Lead vox's full binding from them.

## S1: virtual ports (Mac side ✅)

`fohctl ports` created "FOH In 1-16", "FOH In 17-32", "FOH Aux+Bus" and "FOH Global", each as a virtual source and destination. `fohctl midi` listed all eight from another process.

**Stable IDs:** two separate runs published identical unique IDs (for example, FOH In 1-16 source = 1695955555). MainStage ties assignments to a port, so learned mappings survive a bridge restart.

The app and `fohctl bridge` share one ID store, so either one can be running, but **never run both at once**. The second would get temporary IDs, and it logs a warning when that happens.

---

## MainStage spikes (need you, about 20 minutes)

**Before you start:** in MainStage, choose File › Save As and make a copy, for example `FOH Spike.concert`, so the experiments never touch `Church.concert`. Then start the bridge: launch **FOH Bridge.app**, or run `fohctl bridge` in a terminal.

In a second terminal, run `fohctl bridge`'s log or the app's "Open log" to watch feedback. Learn sweeps are fired with:

```bash
fohctl osc /foh/learn/fire --s /foh/in/1/mix/fader
```

You can also use the iPad app's Setup › MainStage learn screen, in the Simulator or on the device.

### S1: MainStage sees the ports, and feedback works

1. Open Assignments & Mappings (⇧⌘M) and choose Action › **New Assignment** → **Assign & Map**.
2. Run `fohctl osc /foh/learn/fire --s /foh/in/1/mix/fader`. The row should show **FOH In 1-16 · ch 1 · CC 7**.
3. Click **Lead vox's volume fader** to map it.
4. In that assignment's Hardware Input, set **Send Value to → FOH In 1-16**.
5. Drag Lead vox's fader with the mouse. The bridge log should show `← FOH In 1-16 … CC 7`.
6. Run `fohctl osc /foh/in/1/mix/fader 90`. The fader should jump to about 0 dB, and the log should show `echo … rtt N ms` (the round-trip time).

**Record:** the port names you saw, whether feedback arrived, and the rtt.

### S2: booleans are absolute

1. Use New Assignment → Assign & Map, then run `fohctl osc /foh/learn/fire --s /foh/in/1/mix/mute` and click Lead vox's **Mute**.
2. Run `fohctl osc /foh/in/1/mix/mute 127` **twice**. It must stay muted, not toggle back.
3. Run `fohctl osc /foh/in/1/mix/mute 0` **twice**. It must stay unmuted.
4. Repeat with the SSL's EQ switch: learn `/foh/in/1/eq/on` and click **EQBypass** in the SSL window. `… eq/on 127` should put the EQ *in* (EQBypass off).

**Record:** absolute or toggling, and which Hardware Input "Type" MainStage chose.

### S3: "Send Value to" in bulk

1. After S1 and S2, check whether the new assignments already had **Send Value to** filled in.
2. In the Assignments & Mappings table, multi-select several rows and try changing Send Value to for all of them at once.

**Record:** whether it's auto-filled, bulk-editable, or one row at a time.

### S4: do meters stream?

1. In Layout mode, add a **Meter** screen control.
2. Select it, click **Learn**, and run `fohctl osc /foh/learn/send --s /foh/in/1/mix/mute --i 0` twice. Any message works; it just gives the meter an assignment. Alternatively, set its Hardware Input to FOH In 1-16 ch 1, CC 4 (spare) by hand.
3. Map the meter to **Lead vox › SSLChannel › CompAttn**. Also try a meter mapped to the channel's own level meter.
4. Set **Send Value to → FOH In 1-16**, play audio through Lead vox, and watch the bridge log for `unmapped feedback … d1=4`.

**Record:** whether values stream, and roughly how often.

### S5: tapers (linear?) and the fader law

1. Learn and map `/foh/in/1/band/2/gain` → SSL **LMF Gain**, and `/foh/in/1/band/2/freq` → **LMF Frq**.
2. Send each value below with `fohctl osc /foh/in/1/band/2/gain <v>` and read the SSL window:

| MIDI | expected LMF Gain | expected LMF Frq | you saw |
|---|---|---|---|
| 0 | −15.0 dB | 0.20 kHz | |
| 32 | −7.4 dB | 0.47 kHz | |
| 64 | +0.1 dB | 1.01 kHz | |
| 96 | +7.7 dB | 1.85 kHz | |
| 127 | +15.0 dB | 2.50 kHz | |

3. With the S1 fader assignment, send `/foh/in/1/mix/fader <v>` and read Lead vox's fader:

| MIDI | estimated dB (40·log10(v/127)+6) | you saw |
|---|---|---|
| 0 | −∞ | |
| 45 | −12.0 | |
| 90 | 0.0 | |
| 110 | +3.5 | |
| 127 | +6.0 | |

If the readings match, the bridge's value tables are exact. If not, the readings become the calibration table for `ChannelStripParameter` and the per-type taper rule.

---

## Finishing batch (2026-10-24)

- **UI tests:** all 5 offline UI tests pass, with real touches via XCUITest:
  - Backup & Templates screens
  - patch-change toast
  - reorder changes display order only (`mute.in/1` stays Lead vox)
  - the Channel/Setup flow
  - mute plus fader drag
- **Bridge:**
  - Backups: snapshot, change, restore brings back the show, overrides and learn state.
  - Automatic snapshots dedupe and prune to 30.
  - Export/import round-trips, and a newer format is rejected.
  - A template saved from Lead vox applies to Guitar (plugin 1) and survives a rebuild.
  - Every action gets an ack.
  - The confirmed count goes 0 → 2 on simulated MainStage feedback and drops after an unechoed change.
- **Per-channel output tap:**
  - It reads MainStage's output device from its preferences: a **Focusrite Scarlett 2i2**, not connected now.
  - It falls back to the system output, which was 2 channels on the MacBook speakers in testing.
  - Levels read silent from the command line (no System Audio Recording for `fohctl`). FOH Bridge.app has the permission.
- **Learn HUD:** rendered offline (`FOHBridge -renderHUD out.png -store <dir>`). It shows the item label, port/ch/CC chips, the three steps and the buttons.
- **Fixed:** concert import used to read files on the bridge's main thread. A pending macOS folder-access prompt froze MIDI and OSC until it was answered. Reading now happens in the background.

---

## Mapping session (2026-10-25, with MainStage)

**Example 1: Lead vox's fader.**
- Assign & Map put FOH In 1-16 · ch 1 · CC 7 on the existing *Vertical Fader 1* control, mapped to Song One › Lead vox › Volume.
- MainStage followed every value the Bridge sent.
- After "Send Value to → FOH In 1-16", the Bridge logged "Feedback seen on FOH In 1-16". Echo round trip was 0.7–0.8 ms.

**Fader calibration (S5).** `fohctl calibrate fader`: all 12 readings matched `40·log10(v/127)+6` within 0.1 dB (127 → +6.0, 90 → 0.0, 45 → −12.1, 15 → −31.2). The readings are saved to the show.

**Example 2: SSL LMF Gain.**
- Assign & Map created an autogenerated hidden control for CC 26, mapped to Lead vox › SSLChannel › LMF Gain, with "Send Value to".
- A slow wiggle followed exactly, and the echoes confirmed the value at 0.5–1.6 ms.
- `fohctl calibrate param` passed 5/5 exactly (−15.0, −7.4, +0.1, +7.7, +15.0 dB). MainStage maps MIDI linearly over the AU range, so discovery's value tables are exact.

**Pull.**
- Re-selecting the *same* patch (Program Change 0) didn't make MainStage re-send LMF Gain. The fader was already confirmed.
- Moving a control in MainStage always reports it.
- A real patch change still needs testing once there's a second patch.

**Format.** Everything Assign & Map writes is decoded; see `Tools/concert-format/CONCERT_FORMAT.md`. That's enough to build the concert writer.

**Tool fix.** `fohctl calibrate` now opens one connection per step. The bridge drops clients that are silent for 10 s, and the tool sits waiting for your typing.

## Concert writer (2026-10-25, with MainStage)

`fohctl assignments` + `Tools/concert-format/concert_write.py` wrote every bound Lead vox and Guitar role into
`Church FOH Mapped 3.concert`: 46 + 35 hidden controls, each with "Send Value to". The two hand-made examples
were kept, and the 16 sends to buses that don't exist yet and the 18 concert-level roles were skipped.

**It took three tries.** A hidden control lives in 12 places. MainStage silently drops any that is missing one:

1. **Copy 1** wrote 7: the layout input and output, the patch's mapping and UI record, and the concert's UI record.
2. **Copy 2** added the patch's mapping table in Lead vox's `.cst`, making 8. MainStage keeps the whole patch's
   table in one strip's file.
3. **Copy 3** added the layout's invisible-control model, `outputEnabled`, null mapping and UI record, making 12.
   All rows showed.

`registrations.py` now checks this, and a test compares generated controls against MainStage's own.

**On load, MainStage sent every mapped value through "Send Value to".** The bridge went from 2 to 83 confirmed
values. The values match the console:

- Lead vox's fader reads 0.0 dB and Guitar's −∞.
- Guitar's Botta send is −11.1 dB.
- Both sends are on, which shows the flipped send-mute mapping works.
- The SSL settings are the presets' real ones.
- Pro-Q 3 reported its defaults (Output Level ≈ 0 dB, Gain Scale ≈ 100 %), and Assignments & Mappings lists
  CC 112–114 as Output Level, Auto Gain and Gain Scale. So `parameterIndex_1` is the AU parameter ID even when
  IDs don't match list positions.
- The table names the other inferred numbers correctly too: CC 62 → Bus 1, CC 72 → Mute Bus 1, CC 102/111 →
  Waves Tune / Pro-Q 3 Bypass.

This also answers part of **Pull**: loading a concert reports everything. Re-selecting the same patch still
doesn't.

## Phase 0: plugin-control capacity (2026-10-25, with MainStage)

`Church FOH Spike.concert` = Church FOH Live 2 + **1,074 hidden plugin controls**: every parameter of Lead vox's
Pro-Q 3 (358) and Waves Tune (43) and VRB Return's Pro-R 2 (136), each mapped twice, all with "Send Value to", on the
"(spike)" ports of an isolated test bridge.

| Check | Result |
|---|---|
| Values reported on load | All 1,074, within **173 ms** |
| Idle CPU | **45%**, unchanged from Live 2 (the plugins' own processing) |
| CPU while sweeping a Pro-Q band | 55% |
| Response (echo round trip) | **7–8 ms** average, 21 ms worst, with Pro-Q's window open |
| Pro-Q band from MIDI | Setting band 7's Used/Enabled **creates and removes the band**; gain and a 128-step frequency sweep follow |
| Memory | 1,045 MB with Live 2, 2,090 MB after opening the spike, and still **2,119 MB after reopening Live 2**: MainStage keeps memory across concert switches, so the controls' own cost isn't isolated. Two cold launches would measure it |
| Load time | Not reported |

**Verdict:** capacity isn't a blocker. The planned core sets come to roughly 300 controls for today's plugins, under
a third of this test. Even at a worst case of ~1 MB each that's ~300 MB, and the Mac has 16 GB with ~6 GB free.

**Also learned:** Josh's hand-made Assign & Map on the iPad's MUTE MASTER address shows **Master Mute is action 8**
(`WsActionParameterMapping.actionIndex = 8`, discrete step graph). Action mappings sit in the concert's
`patch.patchMappings[identity]` as well as its storeDict, and have no channel-strip table entry.

