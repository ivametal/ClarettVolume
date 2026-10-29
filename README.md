# ClarettVolume

ClarettVolume makes the Mac's volume keys work with a Focusrite Clarett+ (or
Clarett USB) audio interface, exactly the way
[iDVolume](https://github.com/andwhy/iDVolume) does it for the Audient iD:
they change the interface's own monitor level, the same one the front knob
moves.

macOS drives the Clarett with its built-in USB audio driver, and the
interface reports no volume or mute control to it. The monitor level is set
inside the Clarett, and only the endless knob on the front moves it. So while
the Clarett is the output, the volume keys show a crossed-out speaker and do
nothing.

ClarettVolume is a small background app. While a Focusrite is the default
output, it catches the volume keys and changes the Clarett's own monitor
level. You can use the knob and the keys interchangeably: turn the knob,
press a key, and the key starts from where the knob left the level. Nothing
is added to the audio path: no virtual device, no software gain, no extra
latency.

## What it does

- The keys control **the headphones** (the device's headphone pair, line outs
  2/3). If the headphones are set to follow the monitor knob in the device's
  SW/HW switch, they move the knob level instead - whatever the headphones
  actually answer to.
- **Sixteen levels, like the system's volume**: each press moves one level,
  every level sounds about as much quieter as the one before, and the bottom
  level is true digital silence. Quick presses move two levels at a time;
  **Shift+Option+key** moves one fine level.
- **Mute** turns the headphone mute on and off (the front MUTE button while
  the headphones follow the knob). Like in macOS, any volume key turns mute
  off.
- **Option+volume key** still opens Sound settings.
- For a second and a half a panel like the system volume indicator shows the
  level: it drops out of the menu bar under the Control Center icon, with the
  device name over a bar with a tick every 6 dB. Muted, the bar is empty.
- It only acts while a Focusrite device is the default output. For the
  built-in speakers, AirPods and everything else, the keys reach macOS
  untouched.
- If the interface can't be reached, the key goes through to macOS as usual.

## How it works

The Clarett's control protocol is documented by the Linux kernel's
`scarlett2` driver (`sound/usb/mixer_scarlett2.c`, which supports the
Clarett USB and Clarett+ series). The device has a vendor-specific
"Focusrite Control" interface (class 255) that carries a proprietary
request/response packet protocol over the default pipe:

- send: `bmRequestType 0x21, bRequest 2, wValue 0, wIndex <control interface>`
- fetch the staged answer: `bmRequestType 0xa1, bRequest 3`

Each packet is a 16-byte header (command, size, sequence, error, pad) plus
data. Volume and mute are ordinary values in the device's data space:

| Value         | Command   | Offset | Size | Notes                                    |
|---------------|-----------|--------|------|------------------------------------------|
| Master volume | GET/SET   | 0x76   | 2    | s16, 1 dB steps, -127 (silence) to 0 dB  |
| Line out vol. | GET/SET   | 0x34   | 2×4  | per channel, ch 2/3 = headphones; needs activation |
| Mute switch   | GET/SET   | 0x5c   | 1×4  | per channel, ch 2/3 = headphones; needs activation |
| SW/HW switch  | GET/SET   | 0x66   | 1×4  | per channel, 1 = follows the knob        |
| Dim/Mute      | GET/SET   | 0x31   | 2    | byte 0 mute, byte 1 dim                  |

Writing a switch (mute, line out volume) needs a configuration activation: a
`DATA_CMD` (0x00800002) with activation id 1. Writing the master volume
applies immediately - the knob's LED ring follows it. Writing the dim/mute
byte needs activation id 2 and mutes every output that follows the knob, as
if the front button had been pressed.

Sound keeps playing because the audio interfaces themselves are never
touched, and no root access is needed. AppleUSBAudio claims the audio
interfaces, and the Focusrite Control 2 app claims the Control interface
while it runs, so the app borrows whichever interface happens to be free
(normally the unclaimed one) only for one change, well under a millisecond,
so it never blocks the official app, replugging or sleep. Before every
change it reads the current level from the device, which is how the keys
keep up with the knob. If the device has no session yet, the app repeats
the proprietary three-step boot handshake the driver performs.

The keys are caught with a `CGEvent` tap on system-defined events, which
needs the Accessibility permission.

All of it is one file, [main.swift](main.swift), a port of iDVolume's.

## Requirements

- macOS 13 or later.
- Xcode or the Command Line Tools, for `swiftc`.
- A Focusrite Clarett USB or Clarett+ interface (2Pre/4Pre/8Pre; tested with
  the Clarett+ 2Pre).

## Install

```
git clone <this repo>
cd ClarettVolume
./install.sh
```

`install.sh` builds the app, copies it to `~/Applications/ClarettVolume.app`
and adds a login agent, so it starts at every login and restarts if it quits.
On the first launch macOS asks for Accessibility: turn on ClarettVolume in
**System Settings → Privacy & Security → Accessibility**. The keys start
working about two seconds later, no relaunch needed.

The app has an ad hoc signature, so after every rebuild macOS sees a new app
and the Accessibility permission has to be given again. That's why
`install.sh` reuses an existing build. To update, run `./build.sh`, then
`./install.sh`.

The log is at `~/Library/Logs/ClarettVolume.log`.

## Uninstall

```
./uninstall.sh
```

This stops the app and removes it and its login agent. The Accessibility
entry stays in System Settings until you delete it there.

## Limitations

- The protocol is unofficial. A firmware update from Focusrite may change
  it. Then the keys just go back to the usual macOS behaviour.
- The keys move the master (monitor) level, the same value the front knob
  moves. Headphones and line outs that were detached from the knob in
  Focusrite Control keep their own levels, and the mute button does not
  reach them - exactly as pressing the front panel does not.
- Turning the knob doesn't show the panel. That would need constant polling
  of the device.
- The panel is ClarettVolume's own copy of the system volume indicator, not
  the indicator itself. On recent macOS only Apple's own processes can show
  that one.

## Credits

- [iDVolume](https://github.com/andwhy/iDVolume) by Andrey Rozhkov: the
  original, for the Audient iD, and the app this is ported from.
- The Linux kernel [scarlett2](https://github.com/git-moss) driver by
  Geoffrey D. Bennett and contributors, the documentation of the Focusrite
  protocol this port follows. See also the driver's documentation at
  <https://docs.kernel.org/sound/designs/scarlett2.html>.

MIT license, see [LICENSE](LICENSE).
