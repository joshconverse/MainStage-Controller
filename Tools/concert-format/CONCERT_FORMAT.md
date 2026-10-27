# How MainStage 4.3 stores assignments and mappings

Decoded on 2026-10-25 by comparing `Church.concert` before and after two hand-made **Assign & Map** examples:

- Lead vox's fader, mapped to Volume, with "Send Value to".
- Lead vox's SSL **LMF Gain**, with "Send Value to".

The comparison is backed up by 16 of Apple's bundled concerts that contain hardware assignments. It was then
proven in MainStage: `concert_write.py` wrote 81 assignments into a copy, MainStage loaded all of them, and on
load it reported every mapped value back through "Send Value to" (the bridge went from 2 to 83 confirmed values).

The tools in this folder:

| Tool | What it does |
|---|---|
| `concert_write.py` | Writes FOH Remote's assignments into a copy of a concert (below). |
| `registrations.py BUNDLE <uuid or name>` | Lists every place a screen control appears. A complete hidden control shows up in 12. |
| `decode_layout.py <setupZ.layout \| setup.layout>` | Prints the hardware assignments and their "Send Value to". |
| `decode_cst.py <file.cst>` | Prints the archives embedded in a channel-strip file. |
| `keyed_archive.py` | The NSKeyedArchiver codec the writer uses (decode to a node graph, append to an existing archive). |
| `test_concert_write.py` | Tests, including field-by-field comparisons against MainStage's own output. |

Everything is `NSKeyedArchiver` data. Layouts are zlib-compressed (`setupZ.layout`), except MainStage autosaves,
which use a plain `setup.layout`.

## Writing assignments into a concert

```bash
fohctl assignments --out /tmp/assignments.json    # every bound role, its address and current value, from FOH Bridge
```

```bash
python3 Tools/concert-format/concert_write.py --assignments /tmp/assignments.json \
    ~/Desktop/Church.concert ~/Desktop/"Church Mapped.concert" [--strips in/1,in/2] [--dry-run]
```

- It always writes a **new copy** and refuses to overwrite anything.
- It skips addresses that are already assigned, so running it on a concert that already has some assignments
  only adds the missing ones.
- It prints a report of what it wrote and what it skipped, and why.
- Open the copy in MainStage. If MainStage prompts about the concert you had open, choose Don't Save unless you
  meant to keep changes there.

**Not written yet:**

- **Mono output strips** (`.cst` kind 0x44, Church.concert's Output 1 and Output 2). No example concert has one,
  so their channel type is unknown. One hand-made Assign & Map on such a strip settles it.
- **Sends to buses that don't exist in the concert.** Add the bus in MainStage first, re-import, and run again.

**Master Mute is an action** (learned 2026-10-25 from a hand-made Assign & Map in Church FOH Live 2). MainStage's
Master strip has no mute; the toolbar's Master Mute is a `WsActionParameterMapping` with `actionIndex` 8 and no
channel. It has no `.cst` table entry. Instead it sits in the holder's `patchMappings` as
`{"\x01IDENTITY:<uuid>": {"\x01NUMBER:0": blob}}`, where the blob's root is the mapping itself (the storeDict
copy wraps it in an array). Its input event is the generic placeholder, as MainStage saves every mapping.

**Action numbers** (`actionIndex`). These come from `+[WsActionParameterMapping nameForActionCode:]` and
`imagenameForActionCode:` in MainStageCore, whose string tables give the order. Apple's concerts and Church FOH Live 2
confirm 7, 8, 9, 11 and 15.

| # | Action | # | Action | # | Action |
|---|---|---|---|---|---|
| 0 | Prev Patch | 12 | +10 Patches | 24 | Beat Count |
| 1 | Current Patch | 13 | −10 Patches | 25 | Metronome |
| 2 | Next Patch | 14 | CPU Load | **26** | **Record** (FOH Remote's REC) |
| 3 | Prev Set | 15 | Current Patch Number | 27 | Current Time |
| 4 | Current Set | 16 | Play/Stop | 28 | Jump to Patch |
| 5 | Next Set | 17 | Reset/Compare Patch | 29 | Current Bank Number |
| 6 | Concert | 18 | Current Program Number | 30 | Chord Display |
| 7 | Tuner | 19 | MIDI Beat Clock | 31 | MIDI Transpose |
| **8** | **Master Mute** | 20 | Master Tuning | 32 | Smart Controls Tab Index |
| 9 | Tempo / Tap Tempo | 21 | Play | 33 | Elapsed Play Time |
| 10 | MIDI Display | 22 | Stop | 34 | Articulation MIDI Remote |
| 11 | Panic | 23 | Continue | 35 | Image / PDF Objects |

**Sync, not append** (PLAN.md §9c). An address that's already assigned is kept when its mapping matches, and
re-pointed when only the target changed (a plugin moved slot). Hidden controls on the plugin ports
("FOH Plugins …") that no assignment uses any more are removed from every place they're registered. Nothing on
the other ports is ever removed: those may be the user's own. `--in-place CONCERT --backup-dir DIR` syncs the
concert itself. It writes a hidden sibling copy, moves the original into DIR (keeping the newest 20) and puts
the copy in its place. If nothing needs changing, nothing is touched and no backup is made.

**What MainStage changes when it re-saves a concert** (compare `fixtures/mainstage-saved.concert`):

- every mapping's input event becomes the generic placeholder;
- saved values are filled in, including the shared null mapping's `kHasSavedValueKey`;
- each hidden control's `controlName` becomes "WsInvisibleScreenControlFactory" (Assign & Map leaves it empty);
- instance IDs and channel indexes are renumbered.

Both forms load.

**Concert-level strips work** (proven 2026-10-25 in Church FOH Live 2: 92 assignments, all responding). Their
mappings go in the concert's `Concert.patch/data.plist` and the concert's table in `Master.cst`, and each control
sits in 10 places instead of 12 (the patch and concert records coincide). When strips are copied from a patch to
the concert level, MainStage carries their mappings along and re-points them at the new strips.

## The 12 places one Assign & Map writes

`registrations.py` prints these paths. A control missing any of them is dropped by MainStage when the concert
loads: the first two test copies had 7 and then 8 of the 12, and MainStage showed none of their rows.

| File | Where | What |
|---|---|---|
| `workspace.layout/setupZ.layout` | `HardwareSetup.controllerMapping` | identity → hardware input |
| | `HardwareSetup.outputControllerAssignment` | identity → "Send Value to" |
| | `HardwareSetup.globalSettings` | identity → `{outputEnabled: true}` |
| | `OnScreenObjects.PluginModels` | a `WsInvisibleScreenControl` for the hidden control |
| | `proxyEngineNode.parameterMappingMap.storeDict` | identity → `[MANullParameterMapping]` (one shared object) |
| | `proxyEngineNode.uiPluginDataDict` | identity → empty `WsMaskedDictionary` |
| patch `data.plist` | `patch.engineNode.parameterMappingMap.storeDict["\x01IDENTITY:<id>"]` | archived `{root: [mapping]}` |
| | `patch.engineNode.uiPluginDataDict["\x01IDENTITY:<id>"]` | empty UI-data record (key and `identity` field) |
| concert `Concert.patch/data.plist` | `patch.engineNode.uiPluginDataDict["\x01IDENTITY:<id>"]` | the same empty record (key and `identity` field) |
| one strip's `.cst` in the patch | archive 0x0d `dictionary[n]` + archive 0x0e `IdentityIndexLookup[identity] = n` | the same mapping again |

### Identity

```
WsPluginIdentity { uuidString: "5EC4E125-…" , autogenerated: true }
```

Assign & Map creates an **autogenerated, invisible** screen control. Existing layout controls use their names,
e.g. `uuidString: "Vertical Fader 1"`, `autogenerated: false`. Within the layout, every entry for a control
points at the **same** identity object.

### Hardware input (`controllerMapping`)

```
WsMutableController {
  MIDIPort: { uniqueID: 1695955555, name: "FOH In 1-16", uniqueIDType: 1, isSource: true },  // our source's persisted uid
  channelID: 1,          // 1-based MIDI channel
  controllerID: 26,      // CC number
  type: 5,               // continuous CC (absolute)
  minValue: 0, maxValue: 127, bits: 7, steps: 128, value: <last>, timeStamp: <ns>, mb3: 0,
  controllerTag: $null, isBaseplate: false }
```

Apple's templates use `MIDIPort { uniqueIDType: 0, uniqueID: 0 }` with `channelID: 0` for "any port / any channel".

### "Send Value to" (`outputControllerAssignment` + `globalSettings`)

The same record shape, but:

- `MIDIPort` points at our **destination**: `uniqueID: -1912009418, name: "FOH In 1-16", isSource: false`.
- `controllerID` is 21 in MainStage's own records, yet MainStage replies on the *input* channel and CC.
- `globalSettings[identity] = {outputEnabled: true}` switches it on.

"None" is `MIDIPort { uniqueIDType: 0, uniqueID: -1 }`.

**On load, MainStage sends every mapped value to its "Send Value to" destination.** Opening a written concert
therefore fills the bridge with MainStage's real values (Pull on load).

### Invisible control (`OnScreenObjects.PluginModels`)

```
WsInvisibleScreenControl { controlClass: "WsInvisibleScreenControlFactory", pluginIdentity: <identity>,
  shelfUUID: <the layout's shelf string, one object shared by every model>, RenderLocation/UnitSize: "{0, 0}",
  textHeight/textOffset: 0.0, textAlignment/shelfRow: 0, textFont/textColorSRGB/controlName/shadowColorSRGB: $null }
```

### Mapping objects (inside `{root: [ … ]}` and the `.cst` table)

**Plugin parameter:** `MAPlugInParameterMapping`

- `parameterIndex_1`: the **AU parameter ID**, the same ID plugin discovery reports. 20 = SSL "LMF Gain"; Pro-Q 3's
  IDs start at 312, and MainStage lists 315 as "Pro-Q 3 › Output Level".
- `slot`: the 0-based plugin slot on the strip (Lead vox: Tune 0, Pro-Q 3 1, SSL 2).
- `kGInstIDKey`: the strip's `Channel_instID` from the patch `data.plist` (Lead vox 112, Guitar 116).
- `channelID`: `MAChannelID { index: <strip index>, type: 0, aliasIndex: 0 }`. The writer copies it from an
  existing mapping to the same strip (Lead vox 1, Guitar 2).
- `rangeLow` / `rangeHigh`: −1 / −1 for the full range.
- `rangeIsFlipped`, `kDiscreteStepsKey`, `kRangeMappingModeKey` (1 alongside flipped mappings).
- `kHasSavedValueKey` / `kSavedValueFloatKey` / `kSavedValueDoubleKey`: the normalized saved value (0.3858 = MIDI 49).
- `inputControlEvent`: the learned event, `type -3, bits 31, steps 2³¹` with the port, channel and CC.
- `isMIDIPlugIn: false`, `takeVelocity: false`, `momentaryType: false`, `wasAutoset: false`.
- **Switches** made for screen buttons (e.g. SSL DynamicBypass, parameter 12) add `kDiscreteStepsKey: true`,
  `rangeIsFlipped: true`, `kRangeMappingModeKey: 1` and a 4-point step `scalingGraph` (0,0) (0.5,0) (0.5,1) (1,1).

Some fields are archived as referenced objects and others inline (e.g. `slot` and `parameterIndex_1` are objects,
`kGInstIDKey` is inline). The writer reproduces this exactly; the strict tests check it.

**Plugin bypass:** `MABypassParameterMapping`, the same fields, with `parameterIndex_1 = 56 + slot`. Unflipped,
1.0 = bypassed.

**Channel-strip control:** `MABaseplateParameterMapping`, the same fields without `slot` and `isMIDIPlugIn`, plus
`isSendMuteMapping`.

| Parameter | `parameterIndex_1` |
|---|---|
| Solo | 3 |
| Volume | 7 |
| Mute | 9 |
| Pan | 10 |
| Send *n* level | 27 + *n* (send 1 = 28) |
| Send *n* mute | 71 + *n* (send 1 = 72), with `isSendMuteMapping: true` |

FOH Remote's "send on" role is MainStage's send mute flipped (`rangeIsFlipped: true`).

### Saved values

The writer copies the saved value of an existing mapping to the same parameter in the same direction, so opening
the copy changes nothing. Otherwise it writes `kHasSavedValueKey: false`, as 537 mappings in Apple's concerts do.
MainStage then keeps the plugin's own value.

### The `.cst` mapping table

A channel-strip file is a run of chunks. Each has a 36-byte header (`UCuA`/`OCuA` tag, a `u32` chunk id at +18,
and a `u64` payload length at +28) followed by its payload. Other chunks hold the plugins' state.

- Chunk **0x0d** holds archive `{dictionary: {n: [mapping]}}`.
- Chunk **0x0e** holds `{dictionary: {IdentityIndexLookup: {identity: n}, ContainsBasedOnMapping, UUID, kLgControlLabelLookupKey}}`.
- Each payload is a 20-byte sub-header (`u32` bplist length at +16), the bplist, then a 16-byte trailer: a fresh
  time-based UUID each time MainStage writes the chunk.

**MainStage keeps the whole patch's table in one strip's `.cst`.** In Church.concert that's Lead vox's, which
lists Guitar's mappings too, while Guitar's table is empty. At the concert level it's `Master.cst`. The writer
finds the strip whose table matches the patch's storeDict. Apple's bundled concerts have no tables at all (their
mappings are only in `data.plist`), and the writer handles that too.

### Channel IDs from the `.cst` header

A mapping's `MAChannelID` comes from an existing mapping to the strip when there is one. Otherwise it's read from
the first chunk's payload: byte 4 is the strip kind, the `u16` at 6 its number, which is the `MAChannelID` index.

| Kind byte | Strip | `MAChannelID` type |
|---|---|---|
| 0x40 | audio | 0 |
| 0x42 | aux | 8 |
| 0x43 | software instrument (e.g. Metronome) | 2 |
| 0x46 | Master | 7 |
| 0x4C | stereo output (e.g. Main) | 6 |
| 0x44 | mono output | unknown |

Paired across Apple's concerts and confirmed in Church.concert: after the move to the concert level, MainStage's
own mappings to Lead vox and Guitar used index 4 and 0, matching their headers.

## Side effects of a MainStage save

- Concert channel `UUID`s are regenerated.
- Unused `uiPluginDataDict` entries are pruned.
- `.cst` mapping tables are renumbered.

The writer leaves all of that alone.

## MainStage's own plugins (2026-10-26)

- **A mapping's `slot` is 0-based.** On audio and output strips, insert 1 is slot 0. On instrument strips the
  instrument is slot 0 and inserts start at 1.
- **Parameter numbers.** MainStage ships a table per plugin in
  `MainStage.app/Contents/Frameworks/MADSP.framework/Versions/A/Resources/<Plugin>.plist`: sections with
  `onOffParameter` and `groups[].parameters[]`, each `{name, parameterID, preferredControlType}`. A mapping's
  `parameterIndex_1` is `parameterID` − 1. `Resources/Plug-In Settings/<Plugin>/CSParameterOrder.plist` lists the
  same numbers 0-based ("10 Peak 1 Gain").
- **Checked** against the `customLabel` that users typed on screen controls in Apple's 16 concerts
  (`uiPluginDataDict[identity].storeDict.customLabel`): 1,342 of 1,552 effect mappings resolve to the table's name.
- **No ranges or units in the tables.** A `.cst` keeps each plugin's current values in real units (a `.pst` blob,
  `"GAMETSPP"`, where `float[k+1]` is parameter `k`), but not the limits.
- **Reading a concert's mappings:** `concert_write.py --list-mappings CONCERT` prints every hardware-assigned control
  (hand-made ones included) with its address, class, parameter, 1-based insert position and strip.

