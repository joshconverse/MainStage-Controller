# FOH Remote for MainStage — Plan

Working names: **FOH Remote** (iPad app) and **FOH Bridge** (Mac menu-bar app). Rename freely.

Goal: a native iPad mixer, in the spirit of Mixing Station, that runs **MainStage as the front-of-house console**. Channels are configured by the user, and each one gets gain, EQ, dynamics, sends and insert plugins. EQ and dynamics are driven by **whatever plugin you already use** (Waves SSL Channel first), set up through a learning procedure in the app.

**Target device:** iPad Air 13" in landscape (1366 × 1024 pt). **Scope:** FOH only, with no musician / personal monitor mixing.

---

## 1. What the current concert looks like (`~/Desktop/Church.concert`)

| Level | Channel strip | Chain / notes |
|---|---|---|
| Concert | **Botta Church** (Aux, input = Bus 1) | Space Designer, 6.6 s Botta Church IR |
| Concert | **Main** (output) | Gain → MultiMeter → Channel EQ ("Final Mix – Pop") → Multipressor ("Final Pop Compressor") → Direction Mixer ("Stereo Spread Wide") → MultiMeter |
| Concert | **Output 1** | FabFilter Pro-Q 3 |
| Concert | **Output 2** | empty, muted |
| Concert | **Master**, **Metronome** (Klopfgeist) | — |
| Patch "Song One" | **Lead vox** (In 1) | Waves Tune Real-Time → Pro-Q 3 → Waves SSL Channel ("AT Female Vocal 1"); Send 1 → Bus 1 |
| Patch "Song One" | **Guitar** (In 2) | Waves SSL Channel ("Acc Gtr"); Send 1 → Bus 1 |

- **Layout:** a 4-strip screen-control panel with Input Level, Monitor 1, Monitor 2, Effects, Reverb 1, Reverb 2, Delay, EQ on, High, Mid, Mid Freq, Low, Low Cut, Compressor on, Threshold, Solo, Mute, Pan and Fader. **No hardware assignments have been learned yet.**
- **Audio device:** 18 mono inputs / 18 mono outputs configured. **MainStage version:** 4.3, on macOS 26.6.

**Recommendation:** move Lead vox, Guitar and any future inputs to the **concert level**. That keeps them always live and their mappings fixed when a patch changes. Patches then become a setlist that only changes song-specific things, such as the Waves Tune key or scale, through patch-level overrides. Setup › Channels points this out for patch-level strips.

---

## 2. Architecture

MainStage has **no OSC support**. Its only control input is MIDI on screen controls, at 7-bit (0–127) with no 14-bit or NRPN. To get OSC over Wi-Fi, a small Mac app sits between the iPad and MainStage:

```
 iPad Air 13" ── FOH Remote (SwiftUI)
   │   OSC 1.1 over TCP (SLIP-framed)  : control, state sync, config, plugin discovery   ┐ Wi-Fi,
   │   OSC over UDP                    : meters @ 30 Hz, RTA                             ┘ Bonjour "_fohbridge._tcp"
   ▼
 Mac ── FOH Bridge (menu-bar app: CoreMIDI + CoreAudio + AudioToolbox + Network.framework)
   │   virtual MIDI ports (source + destination each):
   │     "FOH In 1-16"  "FOH In 17-32"  "FOH Aux+Bus"  "FOH Global"
   ▼
 MainStage 4.3 — concert-level assignments & mappings (learned once)
   └── "Send Value to" → same-named FOH destination (feedback)
```

What the bridge provides:

1. **OSC over Wi-Fi.** It uses readable addresses and auto-discovers the Mac.
2. **An address space that fits a whole console.** Each strip gets its own MIDI channel on its own port, and the same CC number means the same *role* on every strip (§4).
3. **A state cache.** When the iPad reconnects, it gets the full mix back, even though MainStage can't be queried.
4. **Plugin discovery.** The bridge loads the *same* Audio Unit plugins off-line on the Mac (Waves SSL Channel, Waves Tune, Pro-Q 3 and so on) and reads each one's parameter names, ranges, units and value text. That feeds the processing learn (§5), and it gives the iPad real units and accurate EQ/dynamics curves.
5. **Meters, which MainStage never sends over MIDI:**
   - Input meters come from reading the audio interface inputs directly. Core Audio allows a second reader, so MainStage is not disturbed.
   - Output meters come from a Core Audio process tap on MainStage's output (macOS 14.2+).
   - An input RTA for the EQ screen comes from the same input tap.
6. **Concert import.** The bridge reads `.concert` strip names, levels (concert/patch), I/O and plugin chains to pre-fill Setup › Channels.
7. **A Learn HUD on the Mac.** It has a global hotkey, so you never walk between the iPad and the Mac during setup.

Code layout: one Xcode workspace with:

- `FOHCore`, a local Swift package shared by both apps. It holds the strip/role model, address map, binding and profile model, OSC codec and show-file schema.
- `FOHRemote`, the iPadOS 18+ SwiftUI app.
- `FOHBridge`, the macOS 15+ SwiftUI `MenuBarExtra` app, which can launch at login.

---

## 3. Channels are user-configured

- **Strip types:**
  - Input (mono / stereo).
  - FX / aux return.
  - Bus / send (a MainStage bus feeding an aux).
  - Output.
  - Master.
- Each strip links to a MainStage channel strip. **Import from concert** creates them automatically: today that's 2 inputs, 1 FX return and 3 outputs.
- **Slot-based addressing that never shifts.** Input slot *n* → "FOH In 1-16" ch *n* (17–32 → "FOH In 17-32"). FX/aux slots 1–8 → "FOH Aux+Bus" ch 1–8. Output slots 1–8 → "FOH Aux+Bus" ch 9–16. Master → "FOH Global" ch 1.
  - Reordering or renaming in the app **never** changes a strip's address, so learned MainStage mappings survive.
  - Deleting a strip frees its slot.
- **Sends** are the buses you configure. Your layout already plans Mon 1, Mon 2, Reverb 1, Reverb 2 and Delay. Only Bus 1 (Botta Church) exists in the concert today. The app marks buses that don't exist in the concert yet so you know to add the aux strip in MainStage.
- **Layers:**
  - Automatic layers: All, Inputs, FX returns, Outputs.
  - Custom layers of your choosing, such as "Vocals".
  - Up to 16 strips fit on a layer.
- **Storage.** The configuration lives on the bridge as the "show", so it's backed up with the Mac and survives reinstalling the iPad app.

---

## 4. MIDI map (Bridge ↔ MainStage)

Rules:

- **Each strip gets a unique (port, channel).** The CC number is a *role*, such as "Band 2 gain" or "Comp threshold", and it's the same on every strip.
- What a role controls on a given strip comes from that strip's **binding** (§5).
- Every role is a CC.
- **Booleans are learned as continuous controls (a 0→127 sweep) and sent as 0 or 127**, which keeps them absolute.
- **Reserved, never used:** CC 0/32 (bank select), 6/38 (data entry), 96–101 (NRPN/RPN), 120–127 (channel mode).

| Port | Ch 1–16 |
|---|---|
| FOH In 1-16 | ch *n* = Input slot *n* |
| FOH In 17-32 | ch *n* = Input slot 16+*n* |
| FOH Aux+Bus | ch 1–8 = FX/aux slots 1–8 · ch 9–16 = Output slots 1–8 |
| FOH Global | ch 1 = Master volume (CC 7), setlist (program change), tap tempo, click · ch 2–16 reserved |

### Role → CC (same on every strip)

| CC | Role | | CC | Role |
|---|---|---|---|---|
| 1 | Mute | | 37 | Filters → dynamics sidechain |
| 2 | Solo | | 40 | Dynamics / comp on |
| 3 | Phase | | 41–47 | Comp threshold, ratio, attack, release, makeup, knee, mix |
| 7 | **Fader** | | 50 | Gate on |
| 8 | Input trim | | 51–55 | Gate threshold, range, attack, hold, release |
| 9 | Output trim | | 56 | Gate mode (expander / gate) |
| 10 | Pan | | 60–67 | Send 1–8 level |
| 12 | EQ on | | 70–77 | Send 1–8 on |
| 13–15 | HPF on, freq, slope | | 80 / 81–88 | Insert 3 bypass / macros 1–8 |
| 16–17 | LPF on, freq | | 89 / 90–95 | Insert 4 bypass / macros 1–6 |
| 18 / 19 | Band 1 type / Band 4 type (shelf ↔ bell) | | 102 / 103–110 | Insert 1 bypass / macros 1–8 |
| 20–23 | Band 1 on, freq, gain, Q | | 111 / 112–119 | Insert 2 bypass / macros 1–8 |
| 24–27 | Band 2 on, freq, gain, Q | | | |
| 28–31 | Band 3 on, freq, gain, Q | | | |
| 33–36 | Band 4 on, freq, gain, Q | | | |

Spare for later: 4, 5, 11, 39, 48, 49, 57–59, 68, 69, 78, 79.

Example: **Lead vox (input slot 1), SSL LMF gain = role "Band 2 gain" → port "FOH In 1-16", ch 1, CC 26.**

---

## 5. Processing is learned, not assumed

There is no forced plugin chain. The EQ, Dynamics and Trim pages draw themselves from a per-strip **binding**, which says which plugin parameter each app role controls. Roles a plugin doesn't have are **hidden**. For example, SSL has no per-band on switches, so the SSL EQ page shows none.

### The learning procedure (per strip; templates make later strips fast)

1. **Discover.** The bridge reads the strip's plugin chain from the concert, then loads each plugin off-line to read its parameters: names, min/max, units and value text.
2. **Bind.**
   - Choose which plugin drives which page. On Lead vox, SSL Channel drives EQ, Dynamics and Trim/Phase, while Tune and Pro-Q 3 go to the Inserts page as labelled macros.
   - A **template** auto-matches roles to parameters by name. You confirm each one or re-point it to any parameter.
   - Save it as a template and **apply it to Guitar** in one tap.
3. **Learn in MainStage.** The Learn assistant (§7) walks through only the bound roles.
4. **Verify.** The app moves each control. You confirm that MainStage moved the right knob and shows the same value. This is also the calibration spot-check.

### Units and curves

- From its private plugin instance, the bridge builds a 128-step table mapping each MIDI value to the parameter value and its display text.
- That assumes MainStage maps 0–127 linearly across the parameter's range. Spike S5 checks this. If the taper turns out different, the rule is applied per parameter type.
- The iPad shows real "320 Hz / −3.5 dB" values and draws the EQ and transfer curves from them.

### Built-in templates

- Waves SSL Channel (primary).
- FabFilter Pro-Q 3.
- Apple Channel EQ / Compressor / Noise Gate, for strips like Main.
- Custom, which binds anything by hand.

### Waves SSL Channel template

Parameter names are placeholders until the bridge reads the real list.

| Page | Role (CC) → SSL parameter |
|---|---|
| Trim | Input trim (8) → Input Trim · Output trim (9) → Output Trim · Phase (3) → Phase |
| EQ | EQ on (12) → EQ In · HPF freq (14) → HP Frq · LPF freq (17) → LP Frq · LF: freq 21, gain 22, type 18 → LF Frq / LF Gain / LF Bell · LMF: 25 / 26 / 27 → LMF Frq / Gain / Q · HMF: 29 / 30 / 31 → HMF Frq / Gain / Q · HF: 34 / 35 / 19 → HF Frq / Gain / HF Bell |
| Dynamics | Dyn on (40) → Dyn In · Comp: thresh 41, ratio 42, attack 43 (Fast Atk switch), release 44 · Exp/Gate: thresh 51, range 52, attack 53 (Fast Atk switch), release 55, mode 56 (Exp/Gate) · Filters→SC (37) |
| Not in plugin (hidden) | 13, 15, 16, 20, 23, 24, 28, 33, 36, 45, 46, 47, 50, 54 |

Insert pages are for plugins that aren't bound to EQ/Dynamics/Trim, such as Waves Tune Real-Time (Speed, Note Transition, Key, Scale, Correction) or Pro-Q 3 extras. Each has up to 8 macros you label yourself.

---

## 6. OSC (iPad ↔ Bridge)

```
/foh/{in|fx|out}/{slot}/{role…}  f|i      e.g. /foh/in/1/eq/2/gain 0.42   (role path mirrors §4)
/foh/global/{master|tap|click|patch}
/foh/meters/in    blob (per hardware input: peak, rms)   /foh/meters/out  blob (MainStage tap)
/foh/rta/{slot}   blob (on demand)
/foh/sync         → full-state bundle
/foh/config/…     show: strips, slots, names, colors, layers, buses
/foh/plugins/{strip}/{insert}/params      → discovered parameter list (names, ranges, units)
/foh/bind/{strip}/{role}  s               → bind a role to a plugin parameter
/foh/learn/fire   s                       → bridge sends the learn sweep for that address
```

Sync rules:

- The bridge is the source of truth for the last known value, and it persists its cache to disk.
- **Echo suppression:** incoming values are ignored while you touch a control, plus 250 ms after you release it.
- **Coalescing:** at most 60 messages a second per control.
- **Patch change:** MainStage re-sends mapped values through "Send Value to", and the bridge folds them in.
- **"Push all to MainStage"** re-applies the cached state. It's a guarded action that needs a confirmation.

---

## 7. Setup flow (in the app)

1. **Setup › Channels & I/O.** Import from the concert, add, reorder or rename strips, and configure buses and outputs.
2. **Setup › Processing.** Discover → Bind (templates) for each strip.
3. **Setup › MainStage learn.** For each bound role:
   1. In MainStage, open Assignments & Mappings (⇧⌘M) → New Assignment → **Assign & Map**.
   2. Tap **Send** on the iPad, or press ⌃⌥Space on the Mac. The bridge fires the sweep.
   3. Click that parameter in the plugin window.
   4. Tap **Next**.

   Then set **Send Value to** = the matching FOH port. Spike S3 checks whether this can be bulk-edited.
4. **Verify.**

At roughly 8 seconds per role: Lead vox with SSL, sends and Tune is about 45 roles, or around 6 minutes. Guitar with SSL and sends is about 35 roles, or around 5 minutes.

---

## 8. Screens (see the design canvas)

1. **Mixer.** Configured strips grouped by type (Inputs · FX returns · Outputs) with "Add" tiles. Each strip has a name tag, a mini EQ curve labelled with its source plugin, G/C badges, an inserts badge, pan, mute/solo, a fader and meters. The sidebar has layers and sends-on-faders. The Master section has tempo/tap, click and master mute.
2. **Channel › EQ.** Built from the binding (the SSL bands for Lead vox), with an RTA and the binding shown under each value.
3. **Channel › Dynamics.** SSL compressor plus expander/gate, transfer curves, input meter, estimated GR, output trim.
4. **Routing.**
   - The sends matrix (inputs × configured buses), with "not in concert yet" flags.
   - The sends for the selected channel.
   - I/O shown read-only, plus a list of buses and returns.
5. **Inserts.** Macro pages for Waves Tune, Pro-Q 3 and so on. SSL shows as "bound → EQ · Dynamics · Trim".
6. **Setup › Channels & I/O**, **Setup › Processing** (bind), **Setup › MainStage learn**.
7. **Mac bridge popover.** Client, ports, plugin discovery, meter taps, concert import, Learn HUD.

---

## 9. Phases

| Phase | Scope | Done when |
|---|---|---|
| **0 — Plan & design** (now) | This document and the design canvas | You've signed off |
| **1 — Proof** · *built 2026-10-24; MainStage-side spikes pending (SPIKES.md)* | Xcode workspace, FOHCore, a bridge with virtual ports, OSC/TCP and plugin discovery, the iPad with Lead vox end to end (fader, mute, SSL EQ and dynamics through a binding, Tune macros). Run spikes S1–S8. | An iPad move changes the SSL Channel in MainStage with correct units on the iPad, and a MainStage edit moves the iPad |
| **2 — Console** · *built 2026-10-24 (plus Verify step, Learn HUD, fader calibration)* | Channels & I/O config and import, Processing bind with templates, Learn assistant, Mixer/EQ/Dynamics/Inserts/Routing, sends-on-faders, show persistence | Sunday's setup is mixable from the iPad, and adding a channel is self-serve |
| **3 — Show-ready** · *built 2026-10-24; live meters need macOS permissions; output tap is the stereo mix for now* | Input and output meters, RTA, reconnect hardening, lock mode, guarded master / mute-all, setlist (program change) | Survives a service with Wi-Fi blips |
| **4 — Nice-to-haves** | Concert Builder automation (writing assignments straight into the concert), snapshots, estimated GR, Apple Pencil fine control | — |

---

## 9b. What's left

Built since Phase 3: backups, custom templates, display order, acknowledgements, "confirmed by MainStage" tracking, per-channel output meters, a Verify step, the Learn HUD, fader calibration, the concert writer (patch and concert level), a stability pass, FOH Remote on the iPad, and FOH Bridge installed with a login item.

1. **Plugin controls** (planned 2026-10-25, §9c). Next up.
2. **Remaining assignments** (each needs one hand-made Assign & Map to learn its encoding):
   - Output 1 and Output 2: mono output strips, `.cst` kind 0x44.
   - Master Mute: an action (`WsActionParameterMapping.actionIndex`).
3. **Meters:** recheck now that the inputs go to Main (the left-heavy reading was the Output 1 routing). Check "too hot",
   and which strip lights up: output strips share the Scarlett's two physical outputs.
4. **MainStage-side checks:** S2 (are on/off controls absolute?) and S4 (do meters stream?).
5. **Follow-ups:** real GR meters (SSL `CompAttn`, if S4 says meters stream), snapshots/scenes, Apple Pencil fine control.

## 9c. Plugin controls (plan, 2026-10-25)

**Goal:** every loaded plugin is controllable from the iPad without hand-mapping, with rich pages for the plugins that
deserve them. Decided with Josh:

| Decision | Choice |
|---|---|
| Coverage | A **core set** per plugin is mapped automatically; any other parameter can be added from the iPad and is mapped on the next update |
| Pro-Q 3 | **8 bands plus dynamic EQ** |
| Updating MainStage | **Automatic, in place**: the bridge rewrites the working concert itself (only while MainStage is closed, with a backup first) |
| First milestone | **Rich Pro-Q 3 and Pro-R 2 pages**, then generic pages for every other plugin |

### Facts it rests on

- **Per-strip MIDI space is full:** the fixed roles use 97 of the ~112 usable CCs on each strip's channel. Plugin
  parameters need their own addresses.
- **Plugins are big, much of it noise:**
  - Pro-Q 3 has 358 parameters (24 bands × 14 + globals), 273 of them real controls.
  - Pro-R 2 has 136, 120 real.
  - Waves Tune has 43, 22 real.
  - The rest are analyzer, display and meter parameters.
- **Discovery already reads everything** for third-party Audio Units: name, range, unit, value strings and display text at
  all 128 steps. MainStage maps a plugin parameter by its AU parameter ID (proven with Pro-Q 3's 315).
- **Apple's built-in plugins** (Channel EQ, Multipressor, Gain, Direction Mixer…) aren't Audio Units, so they can't be
  discovered. They wait for a "learn" path (phase 5).
- **Resolution:** MainStage screen controls are 7-bit, so each parameter has 128 steps. On a Pro-Q frequency that's about
  1/11 octave per step. The iPad always shows the exact value MainStage reports.

### Design

1. **Plugin ports.** New virtual MIDI ports "FOH Plugins 1…n", each with 1,760 addresses (16 channels × 110 usable CCs).
   - The bridge allocates an address the first time a plugin parameter is needed, keyed by
     (strip slot, plugin position, AU component, parameter ID).
   - The allocation is stored in the show and never renumbered, like the fixed roles.
   - OSC paths: `/foh/<strip>/plugin/<position>/<parameterID>`.
   - Values, feedback, "confirmed by MainStage" and Pull reuse the existing machinery.
2. **Parameter catalog.** Discovery also records each parameter's AU flags (writable, meter or read-only) and its group.
   A shared filter drops analyzer, display, meter and MIDI parameters.
3. **Core sets** (per plugin type, editable):
   - **Pro-Q 3**, about 85 per instance:
     - bands 1–8 × Used, Enabled, Frequency, Gain, Q, Shape, Slope, Dynamics Enabled, Threshold, Dynamic Range;
     - Output Level, Gain Scale, Auto Gain, Output Pan, Bypass.
   - **Pro-R 2**, about 50:
     - Space, Decay Rate, Distance, Brightness, Character, Thickness, Stereo Width, Ducking, Mix, Predelay, Output Level, Bypass;
     - Decay EQ bands 1–6 × Used, Enabled, Frequency, Rate, Q, Shape.
     - Post EQ is an add-on.
   - **Any other plugin:** the first ~24 real controls, in the plugin's own order.
   - The SSL Channel and Waves Tune keep their current role bindings.
4. **Automatic MainStage sync.** The concert writer gains a sync mode:
   - It computes the wanted set and adds missing controls.
   - It removes controls for plugins that are gone.
   - It re-points controls when a plugin moves slot.
   - The bridge runs it on the working concert when the plugins or the core sets change. It only writes while MainStage
     isn't running: it shows "N plugin changes waiting — quit MainStage to apply" otherwise.
   - Before every write it keeps a timestamped copy of the concert in `~/Library/Application Support/FOH Bridge/concert-backups/`.
   - A manual **Update MainStage assignments** command remains in the bridge menu and iPad Setup.
5. **iPad.** Every strip's channel page gets a tab per loaded plugin, in chain order, on inputs, aux, outputs and Main,
   each with a bypass.
   - **Pro-Q 3 page:**
     - EQ graph with up to 8 bands; tap to add a band, drag, pinch for Q, double-tap for 0 dB;
     - shape and slope per band;
     - dynamic threshold and range shown on the band;
     - output level and gain scale.
   - **Pro-R 2 page:**
     - Space, Decay, Distance, Brightness, Character, Width, Mix, Predelay;
     - the decay-rate EQ as a graph.
   - **Generic page** (milestone 2): knobs, switches and selectors from the catalog, grouped and searchable.
     **Add control** picks any other parameter, which joins that plugin type's set and gets mapped on the next sync.

### Phases

0. **Spike: done** (2026-10-25, SPIKES.md "Phase 0").
   - 1,074 hidden controls reported in 173 ms, with idle CPU unchanged and echoes at ~8 ms.
   - Pro-Q bands can be created and removed from MIDI.
   - Capacity isn't a blocker for the core sets.
1. **Bridge: done** (2026-10-25).
   - "FOH Plugins 1/2" ports, permanent addresses in `ShowConfig.pluginControls`, and catalog version 2 (AU flags
     and groups).
   - Core sets, plugin values over OSC with feedback and confirmation, `fohctl plugin-controls`, and plugin rows in
     `fohctl assignments`.
   - Live: 230 controls (Lead vox: Tune 12, Pro-Q 3 85; VRB Return: Pro-R 2 48; Output 1: Pro-Q 3 85).
2. **Writer sync mode: built** (2026-10-25).
   - The writer adds, removes and re-points controls (plugin ports only for removal) and writes Master Mute as
     action 8. `--in-place` backs up first.
   - FOH Bridge bundles the writer and runs it with `/usr/bin/python3 -I`. It updates the concert automatically
     after show changes settle, but never while MainStage runs: then it waits and applies when MainStage quits.
     If MainStage saved the concert, the bridge re-reads it first.
   - Controls: "Update MainStage assignments" in the bridge menu, `/foh/mainstage/update` (iPad Setup › MainStage
     state, `fohctl mainstage-update`), and a status line in both.
   - Dry run on Church FOH Live 2: adds 145 plugin controls (Lead vox 97, VRB Return 48), keeps 93 (including
     the hand-made Master Mute). Output 1's 85 wait for the mono-output example.
3. **iPad rich pages: built** (2026-10-25).
   - Channel › Inserts is a tab per plugin in chain order, with a bypass badge.
   - **Pro-Q 3:** graph with bands 1–8 in Pro-Q's colours. Tap empty graph to add a bell there, drag a band,
     pinch for Q, double-tap for 0 dB. Dynamic range is drawn as a dashed curve and a bar on the handle. Each band
     has shape, slope, dynamics and on/remove; the header has gain scale, output, pan, auto gain and bypass.
   - **Pro-R 2:** Space, decay rate, distance, brightness, character, thickness, width, predelay, ducking, mix,
     output and bypass. The decay-rate EQ is a graph scaled 12.5%–200%.
   - Other plugins with plugin controls get a plain knob grid until phase 4.
   - A notice appears when MainStage hasn't confirmed any of a plugin's controls (not mapped yet).
   - XCUITest covers the gestures (`PluginPagesUITests`).
4. **iPad generic pages and Add control: built** (2026-10-26).
   - Any plugin with plugin controls gets them under headings: the plugin's own groups ("Band 3"), else shared first
     words ("Vibrato"), else Main. Knobs, switches and step menus, with a search.
   - **Add control** lists the plugin's other parameters, searchable and grouped. Adding one puts it in that plugin
     type's set on every strip (`/foh/plugin/control/add`); FOH Bridge hands out an address and maps it in MainStage
     at the next update. Long-press a control to remove it (`/foh/plugin/control/remove`); its address is kept.
   - Pro-Q 3, Pro-R 2 and Tune have **ALL CONTROLS**, which shows the full list, including additions the page
     doesn't draw, and Add control.
   - Plugin pages replace the insert macro pages: Tune runs on its plugin controls (key, scale, speed, transition,
     correction, vibrato, formant). Macro pages remain only for plugins without plugin controls.
5. **MainStage's own plugins: built** (2026-10-26).
   - MainStage ships a parameter table for about 130 of its plugins:
     `MADSP.framework/Resources/<Plugin>.plist`, with names, sections and control types. A concert mapping's
     parameter number is the table's `parameterID` − 1, checked against 1,342 labelled mappings in Apple's concerts.
   - FOH Bridge reads these tables (`MainStagePluginCatalog`). Channel EQ, Compressor, Multipressor, Gain,
     Direction Mixer and the rest get a core set (their first 24 real controls) and Add control, like any Audio Unit.
     The writer maps them the same way: `MAPlugInParameterMapping`, slot = insert − 1.
   - The tables carry no ranges or units, so values show as 0–100% (switches as Off/On). These controls are never
     seeded with a default: their values come only from MainStage, so Push all can't send a made-up value.
   - **Learn**, for parameters no table lists (Pedalboard, some meters):
     1. Name a control on the iPad. FOH Bridge hands out an address (`PendingLearn`).
     2. Tap SEND while Assign & Map is on in MainStage.
     3. When MainStage saves and quits, the bridge reads the concert (`concert_write.py --list-mappings`) and
        records the parameter for that plugin type.
     4. Every instance of the plugin gets the control, and the writer maps them.
   - **Map by hand** on the "not confirmed" notice sends the learn signal for one control. That is how a mono
     output strip (Output 1/2, `.cst` kind 0x44) gets the one hand-made mapping the writer needs before it can map
     the rest.

### Risks

- **MainStage capacity** with hundreds of hidden controls; phase 0 measures it before anything is built on it.
- **In-place writes:** never while MainStage runs, always back up first, and detect a concert saved by MainStage after our
  write so its changes are re-imported rather than lost.
- **Plugin updates** could change parameter IDs (rare for AU); the catalog keys on component and ID, and a missing ID
  is reported, not guessed.

## 10. Spikes and risks (Phase 1)

| # | Question | Fallback |
|---|---|---|
| S1 | Do the bridge's virtual ports show up in MainStage, with sub-10 ms round trip, and does "Send Value to" feedback work? | — |
| S2 | Do booleans learned as continuous (sweep) behave absolutely at 0/127? | Momentary button mode, or note velocity |
| S3 | Can "Send Value to" be bulk-set, or set automatically by Assign & Map? | One extra click per role |
| S4 | Do meter screen controls stream levels through "Send Value to"? | Bridge taps only |
| S5 | Does MainStage map 0–127 **linearly over the AU parameter's range**? Check on SSL Channel frequency and gain. | Per-type taper rules, plus the Verify step |
| S6 | MainStage performance with several hundred concert-level assignments | Bind only the roles that are used |
| S7 | How 7-bit faders feel (about 0.5 dB steps near unity) | Fine mode and taper tuning |
| S8 | Can the bridge instantiate Waves plugins (WaveShell) off-line and read their parameter trees and value strings, alongside MainStage? | Hand-entered ranges in templates |

---

## 11. Decisions so far

- **iPad:** iPad Air 13", landscape.
- **Transport:** OSC over Wi-Fi to the FOH Bridge, then MIDI to MainStage.
- **Channels:** configured by the user. 2 inputs today: Lead vox and Guitar.
- **Processing:** no forced Apple chain. EQ, Dynamics and Trim are bound to your plugins through a learning procedure, with Waves SSL Channel first.
- **MainStage is the mixer.** No X32 in this system.
- **FOH only.** No musician monitor mixing.

## 12. Open questions

1. Should the monitor sends (Mon 1 / Mon 2 in your layout) be MainStage aux mixes you run from FOH now, or should Phase 1 ship with only the Botta Church reverb send?
2. Should every new input get the SSL Channel template automatically, assuming you'll put SSL on it?
3. Should the master fader and master mute need a confirm or hold gesture during a service?
