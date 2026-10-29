import AppKit
import CoreAudio
import IOKit
import IOUSBHost

// MARK: - Focusrite Clarett control
//
// The Clarett's own control protocol, from the Linux kernel's scarlett2
// driver (sound/usb/mixer_scarlett2.c), which documents the "Focusrite
// Control" interface (bInterfaceClass 255): proprietary packets with a
// 16-byte header, sent as UAC2-style class requests over the default pipe
// and addressed to that interface. The values live in the device's data
// space, addressed by offset. The keys aim at the headphones: their own
// volume (line outs 2 and 3), or, when the headphones are set to follow
// the knob in the device's SW/HW switch, the master level - the very value
// the front knob moves, whose LED ring follows along. The mute is the
// headphone mute switch, or the front MUTE button in knob mode; a config
// activation applies each switch write.
//
// macOS's AppleUSBAudio claims the audio interfaces, and the Focusrite
// Control 2 app claims the Control interface while it runs, so the app
// borrows whichever interface happens to be free for the well under a
// millisecond it takes. Audio is untouched: control requests go over the
// default pipe, which no driver can own exclusively.

enum Focusrite {
    static let vendorID = 0x1235
    // Clarett 2Pre/4Pre/8Pre USB and Clarett+ 2Pre/4Pre/8Pre share the
    // protocol and the configuration layout (scarlett2_config_set_clarett)
    static let productIDs: Set<Int> = [0x8206, 0x8207, 0x8208, 0x820a, 0x820b, 0x820c]

    // packet commands
    static let cmdInit1: UInt32 = 0x00000000
    static let cmdInit2: UInt32 = 0x00000002
    static let cmdGetData: UInt32 = 0x00800000
    static let cmdSetData: UInt32 = 0x00800001
    static let cmdDataCmd: UInt32 = 0x00800002

    // configuration offsets and activation ids (Clarett config set)
    static let dimMuteOffset: UInt32 = 0x31      // byte 0 mute, byte 1 dim
    static let dimMuteActivate: UInt32 = 2
    static let lineOutVolumeOffset: UInt32 = 0x34 // 2 bytes per channel, dB
    static let muteSwitchOffset: UInt32 = 0x5c    // 1 byte per channel
    static let swHwSwitchOffset: UInt32 = 0x66    // 1 byte per channel: 1 follows the knob
    static let masterVolumeOffset: UInt32 = 0x76  // 2 bytes, dB
    // line outs 0 and 1 are the monitors, 2 and 3 the headphones
    static let headphones: UInt32 = 2
    static let configActivate: UInt32 = 1

    // Sixteen levels, like the system's volume: each press moves one level,
    // and every level sounds about as much quieter as the one before (equal
    // perceived steps, the same curve the system speaker volume uses). The
    // bottom level is the register's true bottom: full digital silence.
    // Device granularity is 1 dB, which the curve's top honours.
    static let tickDB: [Int16] = [-127, -40, -30, -24, -20, -17, -14, -12, -10, -8, -7, -5, -4, -3, -2, -1, 0]
    static let maxTick = tickDB.count - 1

    // presses closer than quickPress seconds apart double the step; a held
    // key steps at most once per holdInterval, as if pressed that fast
    static let quickPress = 0.35
    static let holdInterval = 0.2
}

struct MonitorState {
    var raw: Int16
    var muted: Bool
    var followsKnob: Bool

    var db: Double { Double(raw) }
    // the nearest of the sixteen levels
    var tick: Int {
        var best = 0, bestDistance = Double.infinity
        for (i, t) in Focusrite.tickDB.enumerated() {
            let distance = abs(Double(t) - db)
            if distance < bestDistance { bestDistance = distance; best = i }
        }
        return best
    }
    // Audio taper: the bar shows perceived loudness, not dB - each 10 dB
    // down is half as loud, so the bar falls the way the ear hears, and it
    // empties as the sound fades to the true bottom.
    var fraction: Double {
        guard !muted else { return 0 }
        let loudness = pow(2, db / 10)
        let floor = pow(2, Double(Focusrite.tickDB[0]) / 10)
        return min(1, max(0, (loudness - floor) / (1 - floor)))
    }
}

enum USBError: Error { case unreachable, corrupt, rejected }

final class MonitorControl {
    // The device answers a while after the request, so a quick second press
    // would read the old value: a double mute tap muted twice.
    private var lastWrite: (state: MonitorState, time: Date)?
    private var seq: UInt16 = 0
    // The interface the protocol is addressed to (the one with
    // bInterfaceClass 255), found while claiming.
    private var controlNumber: UInt8?

    // The interface the protocol is addressed to (the one with
    // bInterfaceClass 255), found anew every time: the device can come and go.
    private func findInterfaces() -> [(service: io_service_t, number: UInt8, cls: UInt8)] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        let parents = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        var found: [(service: io_service_t, number: UInt8, cls: UInt8)] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            let vendor = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "idVendor" as CFString, nil, parents) as? Int
            let product = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "idProduct" as CFString, nil, parents) as? Int
            guard vendor == Focusrite.vendorID, let product, Focusrite.productIDs.contains(product) else {
                IOObjectRelease(service)
                continue
            }
            let number = IORegistryEntryCreateCFProperty(service, "bInterfaceNumber" as CFString, nil, 0)?.takeRetainedValue() as? Int
            let cls = IORegistryEntryCreateCFProperty(service, "bInterfaceClass" as CFString, nil, 0)?.takeRetainedValue() as? Int
            guard let number, let cls else {
                IOObjectRelease(service)
                continue
            }
            found.append((service, UInt8(number), UInt8(cls)))
        }
        return found
    }

    // Claims one free interface for the duration of the change. Focusrite
    // Control 2, while it runs, owns the Control interface, and AppleUSBAudio
    // owns the audio ones, so the spare interface (4) is tried first, then
    // the Control interface itself, then the rest.
    private func withInterface<T>(_ body: (IOUSBHostInterface) throws -> T) throws -> T {
        let found = findInterfaces()
        defer { found.forEach { IOObjectRelease($0.service) } }
        guard let control = found.first(where: { $0.cls == 255 }) else { throw USBError.unreachable }
        controlNumber = control.number
        var candidates: [UInt8] = [4, control.number]
        candidates += found.map { $0.number }.sorted().filter { !candidates.contains($0) }

        for number in candidates {
            guard let entry = found.first(where: { $0.number == number }) else { continue }
            let iface: IOUSBHostInterface
            do {
                iface = try IOUSBHostInterface(__ioService: entry.service, options: [], queue: nil, interestHandler: nil)
            } catch {
                continue  // claimed by someone else: try the next one
            }
            defer { iface.destroy() }
            return try body(iface)
        }
        throw USBError.unreachable
    }

    // UAC2-style class requests over the default pipe, addressed to the
    // Focusrite Control interface: bmRequestType 0x21/0xa1, request 2 to
    // send a packet and 3 to fetch the answer it stages.
    private func control(_ iface: IOUSBHostInterface, read: Bool, bRequest: UInt8, bytes: [UInt8], timeout: Double) throws -> [UInt8] {
        guard let control = controlNumber else { throw USBError.unreachable }
        let request = IOUSBDeviceRequest(bmRequestType: read ? 0xa1 : 0x21, bRequest: bRequest, wValue: 0,
                                         wIndex: UInt16(control), wLength: UInt16(bytes.count))
        let data = NSMutableData(bytes: bytes, length: bytes.count)
        var transferred = 0
        try iface.__send(request, data: data, bytesTransferred: &transferred, completionTimeout: timeout)
        return Array(Data(referencing: data).prefix(transferred))
    }

    private func le16(_ value: UInt16) -> [UInt8] { [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)] }
    private func le32(_ value: UInt32) -> [UInt8] { le16(UInt16(truncatingIfNeeded: value)) + le16(UInt16(truncatingIfNeeded: value >> 16)) }
    private func readLE16(_ bytes: [UInt8], _ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
    private func readLE32(_ bytes: [UInt8], _ at: Int) -> UInt32 { UInt32(readLE16(bytes, at)) | UInt32(readLE16(bytes, at + 2)) << 16 }

    private func makePacket(_ cmd: UInt32, seqNo: UInt16, data: [UInt8]) -> [UInt8] {
        le32(cmd) + le16(UInt16(data.count)) + le16(seqNo) + le32(0) + le32(0) + data
    }

    // Sends a packet and fetches the staged answer. The device needs a
    // moment after the request, so each round retries the fetch; a whole
    // round is repeated because another client (Focusrite Control 2) may
    // interleave its own request and consume the staged answer. The
    // sequence and the header must agree (except after init, where the
    // answer carries 0). A repeated set only writes the same bytes again.
    private func reqResp(_ iface: IOUSBHostInterface, cmd: UInt32, data: [UInt8], expect: Int) throws -> [UInt8] {
        let seqNo = seq
        seq &+= 1
        let request = makePacket(cmd, seqNo: seqNo, data: data)
        for round in 0..<3 {
            var sent = false
            for _ in 0..<2 where !sent {
                sent = (try? control(iface, read: false, bRequest: 2, bytes: request, timeout: 0.5))?.count == request.count
            }
            guard sent else { throw USBError.unreachable }
            for _ in 0..<2 {
                if let resp = try? control(iface, read: true, bRequest: 3, bytes: [UInt8](repeating: 0, count: 16 + expect), timeout: 0.2),
                   resp.count == 16 + expect,
                   readLE32(resp, 0) == cmd,
                   (readLE16(resp, 6) == seqNo || (seqNo == 1 && readLE16(resp, 6) == 0)),
                   readLE16(resp, 4) == UInt16(expect),
                   readLE32(resp, 8) == 0,
                   readLE32(resp, 12) == 0 {
                    return Array(resp[16...])
                }
            }
            if round < 2 { Thread.sleep(forTimeInterval: 0.02) }
        }
        NSLog("ClarettVolume: no answer to command \(String(cmd, radix: 16))")
        throw USBError.rejected
    }

    private func getData(_ iface: IOUSBHostInterface, offset: UInt32, size: Int) throws -> [UInt8] {
        try reqResp(iface, cmd: Focusrite.cmdGetData, data: le32(offset) + le32(UInt32(size)), expect: size)
    }

    private func setData(_ iface: IOUSBHostInterface, offset: UInt32, bytes: [UInt8]) throws {
        _ = try reqResp(iface, cmd: Focusrite.cmdSetData, data: le32(offset) + le32(UInt32(bytes.count)) + bytes, expect: 0)
    }

    private func activate(_ iface: IOUSBHostInterface, id: UInt32) throws {
        _ = try reqResp(iface, cmd: Focusrite.cmdDataCmd, data: le32(id), expect: 0)
    }

    // The proprietary boot handshake, as the driver performs it: a drained
    // banner, then two init packets, their sequences starting over at 1.
    private func initHandshake(_ iface: IOUSBHostInterface) throws {
        _ = try? control(iface, read: true, bRequest: 0, bytes: [UInt8](repeating: 0, count: 24), timeout: 0.5)
        seq = 1
        _ = try reqResp(iface, cmd: Focusrite.cmdInit1, data: [], expect: 0)
        seq = 1
        _ = try reqResp(iface, cmd: Focusrite.cmdInit2, data: [], expect: 84)
    }

    // The handshake only when the direct way fails: normally the session
    // Focusrite Control 2 or the boot already opened is still good.
    private func withSession<T>(_ body: (IOUSBHostInterface) throws -> T) throws -> T {
        try withInterface { iface in
            do {
                return try body(iface)
            } catch {
                try initHandshake(iface)
                return try body(iface)
            }
        }
    }

    // Sets the mute the headphones currently answer to: the front MUTE
    // button while they follow the knob, their own mute switch otherwise.
    private func setMute(_ iface: IOUSBHostInterface, _ on: Bool, followsKnob: Bool) throws {
        if followsKnob {
            try setData(iface, offset: Focusrite.dimMuteOffset, bytes: [on ? 1 : 0])
            try activate(iface, id: Focusrite.dimMuteActivate)
        } else {
            let base = Focusrite.muteSwitchOffset + Focusrite.headphones
            try setData(iface, offset: base, bytes: [on ? 1 : 0, on ? 1 : 0])
            try activate(iface, id: Focusrite.configActivate)
        }
    }

    // Reads the level first every time, so a turn of the knob in between is
    // simply where the next key press starts from. The headphones either
    // follow the knob (SW/HW switch 1) or carry their own volume.
    private func readState(_ iface: IOUSBHostInterface) throws -> MonitorState {
        if let lastWrite, Date().timeIntervalSince(lastWrite.time) < 0.3 { return lastWrite.state }
        func clamped(_ bytes: [UInt8]) -> Int16 {
            max(Focusrite.tickDB[0], min(0, Int16(bitPattern: readLE16(bytes, 0))))
        }
        let swHw = try getData(iface, offset: Focusrite.swHwSwitchOffset + Focusrite.headphones, size: 1)
        guard swHw.count == 1 else { throw USBError.corrupt }
        if swHw[0] != 0 {
            let level = try getData(iface, offset: Focusrite.masterVolumeOffset, size: 2)
            let dimMute = try getData(iface, offset: Focusrite.dimMuteOffset, size: 2)
            guard level.count == 2, dimMute.count == 2 else { throw USBError.corrupt }
            return MonitorState(raw: clamped(level), muted: dimMute[0] != 0, followsKnob: true)
        }
        let base = Focusrite.lineOutVolumeOffset + 2 * Focusrite.headphones
        let level = try getData(iface, offset: base, size: 4)  // L and R
        let mute = try getData(iface, offset: Focusrite.muteSwitchOffset + Focusrite.headphones, size: 1)
        guard level.count == 4, mute.count == 1 else { throw USBError.corrupt }
        return MonitorState(raw: clamped(level), muted: mute[0] != 0, followsKnob: false)
    }

    // Moves one or two levels up or down, exactly like the system's volume
    // keys count through their sixteen steps.
    func adjust(by ticks: Int) -> MonitorState? {
        do {
            return try withSession { iface in
                var state = try readState(iface)
                let target = min(Focusrite.maxTick, max(0, state.tick + ticks))
                let raw = Focusrite.tickDB[target]
                if raw != state.raw {
                    if state.followsKnob {
                        try setData(iface, offset: Focusrite.masterVolumeOffset, bytes: le16(UInt16(bitPattern: raw)))
                    } else {
                        let base = Focusrite.lineOutVolumeOffset + 2 * Focusrite.headphones
                        try setData(iface, offset: base, bytes: le16(UInt16(bitPattern: raw)) + le16(UInt16(bitPattern: raw)))
                        try activate(iface, id: Focusrite.configActivate)
                    }
                    state.raw = raw
                }
                // like the system volume: any volume key lifts mute
                if state.muted {
                    try setMute(iface, false, followsKnob: state.followsKnob)
                    state.muted = false
                }
                lastWrite = (state, Date())
                return state
            }
        } catch {
            NSLog("ClarettVolume: adjust failed: \(error)")
            return nil
        }
    }

    func toggleMute() -> MonitorState? {
        do {
            return try withSession { iface in
                var state = try readState(iface)
                state.muted.toggle()
                try setMute(iface, state.muted, followsKnob: state.followsKnob)
                lastWrite = (state, Date())
                return state
            }
        } catch {
            NSLog("ClarettVolume: mute failed: \(error)")
            return nil
        }
    }
}

// MARK: - Default output

func stringProperty(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

// The name of the default output when it is a Focusrite, nil otherwise; the
// keys are left to macOS for every other device.
func focusriteDefaultOutput() -> String? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
          stringProperty(device, kAudioObjectPropertyManufacturer) == "Focusrite" else { return nil }
    return stringProperty(device, kAudioObjectPropertyName) ?? "Focusrite"
}

// MARK: - HUD
//
// A copy of the volume indicator of macOS 26 and later: a Liquid Glass panel
// that drops out of the menu bar under its icon there, with the device name
// over a bar that has a speaker at each end and a tick every 6 dB, 16 steps
// like the system's. Muted, the bar is simply empty. The device's own name is
// the only text, so there is nothing to translate.

func axValue<T>(_ element: AXUIElement, _ attribute: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? T
}

// The menu bar item the indicator hangs from, found through Accessibility,
// which the key tap needs anyway: a Sound item if the menu bar shows one,
// else Control Center's, which on macOS 27 turns into a speaker while the
// volume changes. Since macOS 27 they belong to MenuBarAgent.
func volumeMenuExtraFrame() -> NSRect? {
    let ids = ["com.apple.menuextra.sound", "com.apple.menuextra.controlcenter"]
    var found: [String: CGRect] = [:]
    func visit(_ element: AXUIElement, depth: Int) {
        if let id: String = axValue(element, kAXIdentifierAttribute), ids.contains(id), found[id] == nil,
           let value: AXValue = axValue(element, "AXFrame") {
            var frame = CGRect.zero
            if AXValueGetValue(value, .cgRect, &frame) { found[id] = frame }
        }
        guard depth < 2, let children: [AXUIElement] = axValue(element, kAXChildrenAttribute) else { return }
        children.forEach { visit($0, depth: depth + 1) }
    }
    for bundle in ["com.apple.MenuBarAgent", "com.apple.controlcenter"] {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.processIdentifier,
              let bar: AXUIElement = axValue(AXUIElementCreateApplication(pid), kAXExtrasMenuBarAttribute) else { continue }
        visit(bar, depth: 0)
    }
    // Accessibility counts from the top left of the main display, AppKit from its bottom left
    guard let frame = ids.lazy.compactMap({ found[$0] }).first, let main = NSScreen.screens.first else { return nil }
    return NSRect(x: frame.minX, y: main.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
}

final class LevelBar: NSView {
    static let steps = 16
    private let inset: CGFloat = 5  // from the ends of the bar to the ends of the scale
    private let track = CALayer()
    private let fill = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let line = CGRect(x: 0, y: bounds.height - 4, width: bounds.width, height: 4)
        for (part, alpha) in [(track, 0.4), (fill, 1.0)] {
            part.frame = line
            part.cornerRadius = line.height / 2
            part.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
            layer?.addSublayer(part)
        }
        for step in 0...Self.steps {
            let tick = CALayer()
            let x = inset + (line.width - 2 * inset) * CGFloat(step) / CGFloat(Self.steps)
            tick.frame = CGRect(x: x - 0.75, y: 0, width: 1.5, height: 2.5)
            tick.cornerRadius = 0.75
            tick.backgroundColor = NSColor.white.withAlphaComponent(0.55).cgColor
            layer?.addSublayer(tick)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // Like the system's, the fill ends right over the tick of its level;
    // at full loudness it covers the bar to the very end.
    func set(_ fraction: Double, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.15)
        fill.frame.size.width = fraction >= 1 ? bounds.width
            : fraction > 0 ? inset + (track.frame.width - 2 * inset) * fraction : 0
        CATransaction.commit()
    }
}

final class VolumeHUD {
    private let size = NSSize(width: 292, height: 62)
    private let gap: CGFloat = 11   // to the menu bar and the screen edge
    private let room: CGFloat = 24  // around the panel, for the fall and the spring
    private let panel: NSPanel
    private let mover = NSView()
    private let title = NSTextField(labelWithString: "")
    private let bar = LevelBar(frame: NSRect(x: 31, y: 14, width: 222, height: 10))
    private var shown = false
    private var generation = 0

    init() {
        // a hung menu bar must not hold up the key tap
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.2)
        let frame = NSRect(origin: .zero, size: size).insetBy(dx: -room, dy: -room)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // dark like the system's in either mode, so the white reads on any background
        panel.appearance = NSAppearance(named: .darkAqua)

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        title.frame = NSRect(x: 15, y: 36, width: size.width - 30, height: 16)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = .white
        title.lineBreakMode = .byTruncatingTail
        let quiet = Self.speaker("speaker.fill"), loud = Self.speaker("speaker.wave.3.fill")
        quiet.setFrameOrigin(NSPoint(x: 14, y: 22 - quiet.frame.height / 2))
        loud.setFrameOrigin(NSPoint(x: size.width - 14 - loud.frame.width, y: 22 - loud.frame.height / 2))
        [title, quiet, bar, loud].forEach(content.addSubview)

        let card = Self.backdrop(for: content)
        card.frame = content.frame
        mover.frame = NSRect(origin: NSPoint(x: room, y: room), size: size)
        mover.wantsLayer = true
        mover.addSubview(card)
        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        root.addSubview(mover)
        panel.contentView = root
    }

    // Clear Liquid Glass like the system's; the blurred HUD of old where the
    // system or the SDK (before Xcode 26) has no glass.
    private static func backdrop(for content: NSView) -> NSView {
        #if compiler(>=6.2)
        if #available(macOS 26, *) {
            if let glass = lightGlass(for: content) { return glass }
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.cornerRadius = 22
            glass.contentView = content
            return glass
        }
        #endif
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = roundedMask(radius: 22)
        effect.addSubview(content)
        return effect
    }

    #if compiler(>=6.2)
    // The system's own panel, drawn by MenuBarAgent, blurs what is behind it
    // by about 3 pt; the public glass blurs by about 10 and hides it. Private
    // Core Animation pieces come as close as it gets: a backdrop layer with a
    // light gaussian blur under a darkening, and on top glass variant 13,
    // which only bends the light at the edge. Every piece is looked up first;
    // if one is missing, nil, and the public glass is used.
    @available(macOS 26, *)
    private static func lightGlass(for content: NSView) -> NSView? {
        let filterWithType = NSSelectorFromString("filterWithType:"), inputKeys = NSSelectorFromString("inputKeys")
        guard let backdropType = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              backdropType.instancesRespond(to: NSSelectorFromString("setWindowServerAware:")),
              let filterType = NSClassFromString("CAFilter") as AnyObject?, filterType.responds(to: filterWithType),
              let blur = filterType.perform(filterWithType, with: "gaussianBlur" as NSString)?.takeUnretainedValue() as? NSObject,
              blur.responds(to: inputKeys),
              (blur.perform(inputKeys)?.takeUnretainedValue() as? [String])?.contains("inputRadius") == true,
              NSGlassEffectView.instancesRespond(to: NSSelectorFromString("set_variant:"))
        else { return nil }
        blur.setValue(3, forKey: "inputRadius")
        let backdrop = backdropType.init()
        backdrop.setValue(true, forKey: "windowServerAware")
        backdrop.filters = [blur]
        let darkening = CALayer()
        darkening.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor

        let view = NSView(frame: content.frame)
        view.wantsLayer = true
        view.layer?.cornerRadius = 22
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        for layer in [backdrop, darkening] {
            layer.frame = view.bounds
            view.layer?.addSublayer(layer)
        }
        let edge = NSGlassEffectView(frame: view.bounds)
        edge.cornerRadius = 22
        edge.setValue(13, forKey: "_variant")
        [edge, content].forEach(view.addSubview)
        return view
    }
    #endif

    private static func speaker(_ symbol: String) -> NSImageView {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) ?? NSImage()
        let view = NSImageView(image: image)
        view.contentTintColor = .white
        view.frame.size = image.size
        return view
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // Where the system's hangs: centred under its menu bar item, or in the
    // top right corner when the menu bar doesn't show one.
    private func placement() -> NSRect? {
        let origin: NSPoint
        if let item = volumeMenuExtraFrame(),
           let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: item.midX, y: item.midY)) }) {
            let x = min(max(item.midX - size.width / 2, screen.frame.minX + gap), screen.frame.maxX - gap - size.width)
            origin = NSPoint(x: x, y: screen.visibleFrame.maxY - gap - size.height)
        } else if let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            origin = NSPoint(x: screen.maxX - gap - size.width, y: screen.maxY - gap - size.height)
        } else {
            return nil
        }
        return NSRect(origin: origin, size: size).insetBy(dx: -room, dy: -room)
    }

    // Up in the menu bar and a little smaller, scaled about the top edge, so
    // that the panel seems to drop out of it.
    private var tucked: CATransform3D {
        let anchor = mover.layer?.anchorPoint ?? .zero
        let top = CGPoint(x: (0.5 - anchor.x) * size.width, y: (1 - anchor.y) * size.height)
        let raised = CATransform3DMakeTranslation(top.x, top.y + 20, 0)
        return CATransform3DTranslate(CATransform3DScale(raised, 0.8, 0.8, 1), -top.x, -top.y, 0)
    }

    private func appear() {
        guard let layer = mover.layer else { return }
        // from wherever a leaving panel has got to
        let current = panel.isVisible ? layer.presentation() : nil
        let fall = CASpringAnimation(keyPath: "transform")
        fall.fromValue = NSValue(caTransform3D: current?.transform ?? tucked)
        fall.stiffness = 280
        fall.damping = 22
        fall.duration = fall.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = current?.opacity ?? 0
        fade.duration = 0.15
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        layer.add(fall, forKey: "transform")
        layer.add(fade, forKey: "opacity")
        shown = true
        panel.orderFrontRegardless()
    }

    private func disappear(_ last: Int) {
        guard let layer = mover.layer else { return }
        shown = false
        let current = layer.presentation()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.generation == last else { return }
            self.panel.orderOut(nil)
        }
        let rise = CABasicAnimation(keyPath: "transform")
        rise.fromValue = NSValue(caTransform3D: current?.transform ?? CATransform3DIdentity)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = current?.opacity ?? 1
        for animation in [rise, fade] {
            animation.duration = 0.25
            animation.timingFunction = CAMediaTimingFunction(name: .easeIn)
        }
        layer.transform = tucked
        layer.opacity = 0
        layer.add(rise, forKey: "transform")
        layer.add(fade, forKey: "opacity")
        CATransaction.commit()
    }

    func show(_ state: MonitorState, device: String) {
        title.stringValue = device
        bar.set(state.fraction, animated: shown)
        if !shown {
            if !panel.isVisible {
                guard let frame = placement() else { return }
                panel.setFrame(frame, display: false)
            }
            appear()
        }
        generation += 1
        let last = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.generation == last else { return }
            self.disappear(last)
        }
    }
}

// MARK: - Volume keys

// Media keys arrive as NX_SYSDEFINED events, subtype 8, with the key in data1.
let systemDefinedEvent: UInt32 = 14
let soundUpKey = 0, soundDownKey = 1, muteKey = 7

final class VolumeKeys {
    private let control = MonitorControl()
    private let hud = VolumeHUD()
    private var lastStep: (key: Int, time: Date, ticks: Int)?

    // One level per press, like the system's keys. Quick presses in one
    // direction move two levels, the way the system speeds up when tapped
    // fast, and holding the key counts as pressing it quickly. The system
    // repeats a held key far more often than anyone can press, so repeats
    // closer than holdInterval are dropped (nil); that also spares the
    // device's control interface a flood of requests.
    private func step(for key: Int, fine: Bool, isRepeat: Bool) -> Int? {
        let now = Date()
        var ticks = 1
        if !fine, let lastStep, lastStep.key == key {
            let since = now.timeIntervalSince(lastStep.time)
            if isRepeat && since < Focusrite.holdInterval { return nil }
            if isRepeat || since < Focusrite.quickPress { ticks = 2 }
        }
        lastStep = (key, now, ticks)
        return ticks
    }

    // true when the event is ours and must not reach macOS
    func handle(_ event: CGEvent) -> Bool {
        guard event.type.rawValue == systemDefinedEvent,
              let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else { return false }
        let key = (nsEvent.data1 & 0xFFFF_0000) >> 16
        let isDown = (nsEvent.data1 & 0xFF00) >> 8 == 0x0A
        let isRepeat = nsEvent.data1 & 0x1 != 0
        guard key == soundUpKey || key == soundDownKey || key == muteKey else { return false }

        let flags = event.flags
        let fine = flags.contains(.maskAlternate) && flags.contains(.maskShift)
        // Option alone keeps its system meaning: it opens Sound settings
        if flags.contains(.maskAlternate) && !fine { return false }
        guard let device = focusriteDefaultOutput() else { return false }
        guard isDown else { return true }

        let state: MonitorState?
        switch key {
        case soundUpKey, soundDownKey:
            // a held key between two steps: nothing to change, still ours
            guard let ticks = step(for: key, fine: fine, isRepeat: isRepeat) else { return true }
            state = control.adjust(by: key == soundUpKey ? ticks : -ticks)
        default: state = control.toggleMute()
        }
        // could not reach the device: let macOS answer as it always did
        guard let state else { return false }
        hud.show(state, device: device)
        return true
    }
}

let volumeKeys = VolumeKeys()
var eventTap: CFMachPort?

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    return volumeKeys.handle(event) ? nil : Unmanaged.passUnretained(event)
}

func installTap() -> Bool {
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                      eventsOfInterest: CGEventMask(1) << systemDefinedEvent,
                                      callback: tapCallback, userInfo: nil) else { return false }
    eventTap = tap
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
}

// Swallowing keys needs Accessibility. Ask once, then wait for the switch to
// be flipped in System Settings instead of making the user relaunch.
func startWhenTrusted() {
    let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    if AXIsProcessTrustedWithOptions(prompt), installTap() {
        NSLog("ClarettVolume: listening for volume keys")
        return
    }
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
        guard AXIsProcessTrusted(), installTap() else { return }
        timer.invalidate()
        NSLog("ClarettVolume: listening for volume keys")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
startWhenTrusted()
app.run()
