// triggrd-system: Triggrd's system sound service.
//
// Hammerspoon (and so Triggrd) only runs inside a logged-in session. This small
// helper runs as a LaunchDaemon, from boot to shutdown, and plays sounds for
// the events that happen outside of that session: the system starting, logging
// in, and logging out / restarting / shutting down. It listens for the
// system-wide notify(3) notifications loginwindow posts, and plays sound files
// from /Library/Sounds/Triggrd, which it scans recursively on every event. File
// names follow Triggrd's convention: dot-separated tags, and a file plays when
// all of its tags are among the event's tags.
//
// Events:
//   system.started                  at boot (the service starting within 5 minutes of boot)
//   login.started                   loginwindow.loginInitiated (not played within 5 seconds
//                                   of a system.started sound: on a FileVault Mac the login
//                                   follows the unlock at once, and the two would overlap)
//   login.desktopReady              loginwindow.desktopUp
//   login.itemsLaunched             loginwindow.delayedLoginItemsInitiated
//   powerOff.requested.<kind>       loginwindow.{logout,restart,shutdown}Initiated (confirmation shown)
//   powerOff.likely.<kind>          loginwindow.likelyUserSessionExit / likelyShutdown
//   powerOff.cancelled.<kind>       loginwindow.logoutcancelled
//   powerOff.noReturn.<kind>        loginwindow.logoutNoReturn / shutdownNoReturn
// <kind> is logout, restart or shutdown. A restart or shutdown posts both the
// logout and the shutdown flavour of some notifications within milliseconds;
// those are merged into one event.
//
// Nothing is played when launchd stops the service at shutdown: by then audio
// is already being torn down (a sound started on SIGTERM is cut off within a
// quarter of a second), so powerOff.noReturn is the last event that can be heard.
//
// Tells Triggrd about logins: at login.started, if the sounds folder has any
// login.* sound, or a system.started sound played at this boot (a FileVault
// Mac logs in straight after it), it touches <state>/loginSounds, so Triggrd
// can skip its own Triggrd.started sound when Hammerspoon launches as part of
// that login.
//
// It also watches hardware and connections that Hammerspoon can't watch
// itself (in-process Thunderbolt and Bluetooth access crashes it on macOS 27),
// or could only poll for, and hands those events to Triggrd to play from the
// user's own theme; see "Devices and connections" below.
//
// Options (for testing without installing): --sounds DIR, --state DIR,
// --prefix NOTIFICATION-PREFIX, --boot (treat this launch as boot), --verbose,
// --snapshot (print the devices and connections currently seen, then exit),
// --emit TAGS (hand one device/connection event to Triggrd as if it had
// happened, e.g. --emit lid.ready, then exit).

import CoreAudio
import CoreMediaIO
import Foundation
import IOKit
import IOKit.pwr_mgt
import notify
import SystemConfiguration

var soundsDir = "/Library/Sounds/Triggrd"
var stateDir = "/Library/Application Support/Triggrd"
var prefix = "com.apple.system.loginwindow."
var pretendBoot = false
var verbose = false
var snapshotOnly = false
var emitTags: [String]?
var emitName = ""

var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--sounds": soundsDir = args.next() ?? soundsDir
    case "--state": stateDir = args.next() ?? stateDir
    case "--prefix": prefix = args.next() ?? prefix
    case "--boot": pretendBoot = true
    case "--verbose": verbose = true
    case "--snapshot": snapshotOnly = true
    case "--emit":
        emitTags = (args.next() ?? "").split(separator: ".").map(String.init)
        snapshotOnly = true // no watchers, no startup sound
    default: break
    }
}

let dateFormatter = ISO8601DateFormatter()
dateFormatter.timeZone = .current

func log(_ message: String) {
    FileHandle.standardError.write("\(dateFormatter.string(from: Date())) \(message)\n".data(using: .utf8)!)
}

let audioExtensions: Set<String> = ["wav", "aif", "aiff", "aifc", "caf", "mp3", "m4a", "au", "snd", "ulw", "m4p"]

struct Automation {
    let tags: [String]
    let path: String
}

func automations() -> [Automation] {
    let root = URL(fileURLWithPath: soundsDir)
    guard let walker = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
    var found: [Automation] = []
    for case let url as URL in walker where audioExtensions.contains(url.pathExtension.lowercased()) {
        let name = url.deletingPathExtension().lastPathComponent
        found.append(Automation(tags: name.split(separator: ".").map(String.init), path: url.path))
    }
    return found
}

func matching(_ tags: [String], in autos: [Automation]) -> [Automation] {
    autos.filter { $0.tags.allSatisfy(tags.contains) }
}

func play(_ path: String) {
    let player = Process()
    player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    player.arguments = [path]
    do { try player.run() } catch { log("could not play \(path): \(error)") }
}

@discardableResult
func emit(_ tags: [String]) -> Bool {
    let matches = matching(tags, in: automations())
    for automation in matches { play(automation.path) }
    log("\(tags.joined(separator: ".")) -> \(matches.map { ($0.path as NSString).lastPathComponent })")
    return !matches.isEmpty
}

// Merges the duplicate notifications a restart/shutdown posts (e.g. both
// logoutNoReturn and shutdownNoReturn, milliseconds apart).
var lastEmitted: [String: Date] = [:]
func emitOnce(_ tags: [String]) {
    let key = tags.joined(separator: ".")
    if let last = lastEmitted[key], Date().timeIntervalSince(last) < 1 { return }
    lastEmitted[key] = Date()
    emit(tags)
}

let loginEvents = [["login", "started"], ["login", "desktopReady"], ["login", "itemsLaunched"]]

// Whether a system.started sound played at this boot and no login has used it yet.
var startupSoundPending = false
// When that system.started sound played.
var startupSoundTime: Date?

func noteLogin() {
    let autos = automations()
    let marker = (stateDir as NSString).appendingPathComponent("loginSounds")
    let announced = startupSoundPending || loginEvents.contains(where: { !matching($0, in: autos).isEmpty })
    startupSoundPending = false
    if announced {
        try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: marker, contents: nil,
                                       attributes: [.posixPermissions: 0o644])
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: marker)
    } else {
        try? FileManager.default.removeItem(atPath: marker)
    }
}

var kind = "logout"

let handlers: [String: () -> Void] = [
    "loginInitiated": {
        kind = "logout"
        noteLogin()
        if let played = startupSoundTime, Date().timeIntervalSince(played) <= 5 {
            log("login.started -> skipped, \(String(format: "%.1f", Date().timeIntervalSince(played)))s after system.started")
        } else {
            emit(["login", "started"])
        }
        startupSoundTime = nil
    },
    "desktopUp": { emit(["login", "desktopReady"]) },
    "delayedLoginItemsInitiated": { emit(["login", "itemsLaunched"]) },
    "logoutInitiated": { kind = "logout"; emitOnce(["powerOff", "requested", kind]) },
    "restartinitiated": { kind = "restart"; emitOnce(["powerOff", "requested", kind]) },
    "shutdownInitiated": { kind = "shutdown"; emitOnce(["powerOff", "requested", kind]) },
    "likelyUserSessionExit": { emitOnce(["powerOff", "likely", kind]) },
    "likelyShutdown": { emitOnce(["powerOff", "likely", kind]) },
    "logoutcancelled": {
        emitOnce(["powerOff", "cancelled", kind])
        kind = "logout"
        lastEmitted.removeAll() // a fresh request right after this should sound again
    },
    "logoutNoReturn": { emitOnce(["powerOff", "noReturn", kind]) },
    "shutdownNoReturn": { emitOnce(["powerOff", "noReturn", kind]) },
]

var tokens: [Int32] = []
for (suffix, handler) in handlers {
    var token: Int32 = 0
    let status = notify_register_dispatch(prefix + suffix, &token, DispatchQueue.main) { _ in handler() }
    if status == 0 { tokens.append(token) } else { log("could not register for \(prefix + suffix): \(status)") }
}

var bootTime = timeval()
var bootTimeSize = MemoryLayout<timeval>.size
sysctlbyname("kern.boottime", &bootTime, &bootTimeSize, nil, 0)
let secondsSinceBoot = Date().timeIntervalSince1970 - Double(bootTime.tv_sec)

log("started (\(Int(secondsSinceBoot))s after boot), sounds from \(soundsDir)")
if !snapshotOnly && (pretendBoot || secondsSinceBoot < 300) {
    startupSoundPending = emit(["system", "started"])
    if startupSoundPending { startupSoundTime = Date() }
}

// MARK: - Devices and connections
//
// These events are handed to Triggrd rather than played here. Their sounds
// belong in the user's Triggrd theme (in ~/Documents, which this service,
// running as root, can't read anyway), and they're part of using the Mac:
// quitting Hammerspoon silences them, the same as Triggrd's own sounds. Each is
// appended to <state>/events as "<tags>\t<name>\n"; Triggrd watches the file
// and plays <tags> plus the name as an extra tag. <state>/features tells
// Triggrd which watchers this service has, so it can stop doing them itself.
//
//   device.thunderbolt.added / removed     a Thunderbolt / USB4 device, by name
//   network.wifi.connected / disconnected
//   network.ethernet.connected / disconnected
//   network.internet.connected / disconnected
//   bluetooth.connected / disconnected .audio / .input   headphones, speakers;
//                                          keyboards, mice, trackpads, controllers
//   audio.headphones.connected / disconnected   the built-in headphone jack
//   audio.outputChanged                    the default output device changed, by name
//   microphone.started / stopped           any microphone in use (the orange dot)
//   camera.started / stopped               any camera in use (the green dot)
//   lid.closed / lid.opened / lid.ready    ready: awake and the screen on after opening
//   thermal.throttling.serious / critical  macOS slowing the Mac down to cool it
//   thermal.cooled                         back to normal
//   lowPowerMode.on / off
// Wired connections also carry hardware.connected / hardware.disconnected, and
// wireless ones wireless.connected / wireless.disconnected, so one pair of
// sounds can cover every kind.
//
// No polling: IOKit, SystemConfiguration and Core Audio all notify. Brief
// drops are smoothed over (see PresenceReporter), and while the Mac sleeps,
// and for 30 seconds after it wakes, connection changes are taken in silently:
// Wi-Fi and Bluetooth drop and reconnect around every sleep, and wake has its
// own sound.

let eventsPath = (stateDir as NSString).appendingPathComponent("events")

func handOff(_ tags: [String], name: String) {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
    // Triggrd notices a shrunk or replaced file and starts again from the top.
    if let size = (try? fm.attributesOfItem(atPath: eventsPath))?[.size] as? UInt64, size > 65_536 {
        try? fm.removeItem(atPath: eventsPath)
    }
    if !fm.fileExists(atPath: eventsPath) {
        fm.createFile(atPath: eventsPath, contents: nil, attributes: [.posixPermissions: 0o644])
    }
    let line = tags.joined(separator: ".") + "\t" + name.replacingOccurrences(of: "\n", with: " ") + "\n"
    if let file = FileHandle(forWritingAtPath: eventsPath) {
        file.seekToEndOfFile()
        file.write(line.data(using: .utf8)!)
        try? file.close()
    }
    log("\(tags.joined(separator: ".")) \(name) -> Triggrd")
}

var asleep = false
// Everything connects as the Mac starts up, too; stay quiet about that the same way.
var connectionsQuietUntil = !snapshotOnly && (pretendBoot || secondsSinceBoot < 300)
    ? Date().addingTimeInterval(30) : Date.distantPast

/// Reports things coming and going (keyed, with a display name), from a
/// snapshot function that is re-read whenever something may have changed.
/// Appearances are reported after `appearDelay` and disappearances after
/// `disappearDelay`, and only if still true then, so flapping is ignored.
final class PresenceReporter {
    let snapshot: () -> [String: String]
    let report: (_ key: String, _ name: String, _ present: Bool) -> Void
    let appearDelay: Double
    let disappearDelay: Double
    let quietAfterWake: Bool
    private var reported: [String: String] = [:]
    private var pending: [String: DispatchWorkItem] = [:]

    init(appearDelay: Double, disappearDelay: Double, quietAfterWake: Bool,
         snapshot: @escaping () -> [String: String],
         report: @escaping (String, String, Bool) -> Void) {
        self.appearDelay = appearDelay
        self.disappearDelay = disappearDelay
        self.quietAfterWake = quietAfterWake
        self.snapshot = snapshot
        self.report = report
        reported = snapshot()
    }

    private var quiet: Bool { asleep || (quietAfterWake && Date() < connectionsQuietUntil) }

    func changed() {
        let now = snapshot()
        for key in Set(now.keys).union(reported.keys) {
            let present = now[key] != nil
            if present == (reported[key] != nil) {
                pending.removeValue(forKey: key)?.cancel()
                continue
            }
            if pending[key] != nil { continue }
            let item = DispatchWorkItem { [weak self] in self?.settle(key) }
            pending[key] = item
            DispatchQueue.main.asyncAfter(deadline: .now() + (present ? appearDelay : disappearDelay), execute: item)
        }
    }

    private func settle(_ key: String) {
        pending[key] = nil
        let now = snapshot()
        if let name = now[key], reported[key] == nil {
            reported[key] = name
            if !quiet { report(key, name, true) }
        } else if now[key] == nil, let name = reported[key] {
            reported[key] = nil
            if !quiet { report(key, name, false) }
        }
    }

    /// Takes the current state as known, without reporting anything.
    func resync() {
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        reported = snapshot()
    }
}

func registryProperty(_ service: io_object_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

func registryServices(_ matching: CFDictionary) -> [io_object_t] {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iterator) }
    var services: [io_object_t] = []
    var service = IOIteratorNext(iterator)
    while service != 0 {
        services.append(service)
        service = IOIteratorNext(iterator)
    }
    return services
}

func registryID(_ service: io_object_t) -> String {
    var id: UInt64 = 0
    IORegistryEntryGetRegistryEntryID(service, &id)
    return String(id)
}

/// Calls `changed` whenever a service matching `matching` appears or goes.
var registryWatchers: [(IONotificationPortRef, io_iterator_t, io_iterator_t)] = []
final class ChangeHandler { let changed: () -> Void; init(_ changed: @escaping () -> Void) { self.changed = changed } }
var changeHandlers: [ChangeHandler] = []

func watchRegistry(_ makeMatching: () -> CFDictionary, changed: @escaping () -> Void) {
    guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
    IONotificationPortSetDispatchQueue(port, .main)
    let handler = ChangeHandler(changed)
    changeHandlers.append(handler)
    let refcon = Unmanaged.passUnretained(handler).toOpaque()
    let callback: IOServiceMatchingCallback = { refcon, iterator in
        var service = IOIteratorNext(iterator)
        while service != 0 { IOObjectRelease(service); service = IOIteratorNext(iterator) }
        guard let refcon else { return }
        Unmanaged<ChangeHandler>.fromOpaque(refcon).takeUnretainedValue().changed()
    }
    var added: io_iterator_t = 0
    var removed: io_iterator_t = 0
    // Draining each iterator once arms it (and skips what is already there).
    if IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, makeMatching(), callback, refcon, &added) == KERN_SUCCESS {
        var s = IOIteratorNext(added); while s != 0 { IOObjectRelease(s); s = IOIteratorNext(added) }
    }
    if IOServiceAddMatchingNotification(port, kIOTerminatedNotification, makeMatching(), callback, refcon, &removed) == KERN_SUCCESS {
        var s = IOIteratorNext(removed); while s != 0 { IOObjectRelease(s); s = IOIteratorNext(removed) }
    }
    registryWatchers.append((port, added, removed))
}

// Thunderbolt / USB4. Every Thunderbolt switch is in the I/O Registry; depth 0
// ones are the Mac's own ports, anything deeper is an attached device.
func thunderboltDevices() -> [String: String] {
    var devices: [String: String] = [:]
    for service in registryServices(IOServiceMatching("IOThunderboltSwitch")) {
        defer { IOObjectRelease(service) }
        guard let depth = registryProperty(service, "Depth") as? Int, depth > 0 else { continue }
        let model = registryProperty(service, "Device Model Name") as? String
        let vendor = registryProperty(service, "Device Vendor Name") as? String
        devices[registryID(service)] = model ?? vendor ?? "Thunderbolt device"
    }
    return devices
}

let thunderbolt = PresenceReporter(appearDelay: 0, disappearDelay: 0, quietAfterWake: false,
                                   snapshot: thunderboltDevices) { _, name, present in
    handOff(["device", "thunderbolt", present ? "added" : "removed",
             "hardware", present ? "connected" : "disconnected"], name: name)
}
watchRegistry({ IOServiceMatching("IOThunderboltSwitch") }) { thunderbolt.changed() }

// Network. Interface link state and the global route live in the
// SystemConfiguration dynamic store, which notifies on change.
var networkStore: SCDynamicStore?

func networkInterfaces() -> [String: (kind: String, name: String)] {
    let all = (SCNetworkInterfaceCopyAll() as NSArray) as? [SCNetworkInterface] ?? []
    var interfaces: [String: (kind: String, name: String)] = [:]
    for interface in all {
        guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
              let type = SCNetworkInterfaceGetInterfaceType(interface) else { continue }
        let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? bsd
        if type == kSCNetworkInterfaceTypeIEEE80211 {
            interfaces[bsd] = ("wifi", name)
        } else if type == kSCNetworkInterfaceTypeEthernet, !name.hasPrefix("Thunderbolt") {
            // "Thunderbolt 1" etc. are Mac-to-Mac Thunderbolt Bridge ports, not Ethernet.
            interfaces[bsd] = ("ethernet", name)
        }
    }
    return interfaces
}

func networkConnections() -> [String: String] {
    guard let store = networkStore else { return [:] }
    var connections: [String: String] = [:]
    for (bsd, interface) in networkInterfaces() {
        let link = SCDynamicStoreCopyValue(store, "State:/Network/Interface/\(bsd)/Link" as CFString) as? [String: Any]
        if link?["Active"] as? Bool == true { connections["\(interface.kind)|\(bsd)"] = interface.name }
    }
    for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
        if let global = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
           global["PrimaryInterface"] != nil {
            connections["internet"] = "Internet"
        }
    }
    return connections
}

var network: PresenceReporter?
networkStore = SCDynamicStoreCreate(nil, "triggrd-system" as CFString, { _, _, _ in network?.changed() }, nil)
if let store = networkStore {
    SCDynamicStoreSetNotificationKeys(store,
        ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] as CFArray,
        ["State:/Network/Interface/[^/]+/Link"] as CFArray)
    SCDynamicStoreSetDispatchQueue(store, .main)
}
network = PresenceReporter(appearDelay: 0, disappearDelay: 2, quietAfterWake: true,
                           snapshot: networkConnections) { key, name, present in
    let kind = key == "internet" ? "internet" : String(key.split(separator: "|")[0])
    let state = present ? "connected" : "disconnected"
    let umbrella = ["wifi": ["wireless"], "ethernet": ["hardware"]][kind] ?? []
    handOff(["network", kind, state] + umbrella, name: name)
}

// Bluetooth, without Bluetooth access (which root daemons and Hammerspoon
// can't get): audio devices come from Core Audio, input devices from the I/O
// Registry, both of which say when a device's transport is Bluetooth. Keyed by
// name, so AirPods (an audio device and several HID services) count once.
func bluetoothAudioDevices() -> [String: String] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [:] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [:] }
    var devices: [String: String] = [:]
    for id in ids {
        var transport: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                          mScope: kAudioObjectPropertyScopeGlobal,
                                                          mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport) == noErr,
              transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE else { continue }
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr,
              let deviceName = name?.takeRetainedValue() as String? else { continue }
        devices[deviceName] = "audio"
    }
    return devices
}

func bluetoothHIDMatching(_ transport: String) -> CFDictionary {
    let matching = IOServiceMatching("IOHIDDevice") as NSMutableDictionary
    matching[kIOPropertyMatchKey] = ["Transport": transport]
    return matching
}

func bluetoothInputDevices() -> [String: String] {
    var devices: [String: String] = [:]
    for transport in ["Bluetooth", "Bluetooth Low Energy"] {
        for service in registryServices(bluetoothHIDMatching(transport)) {
            defer { IOObjectRelease(service) }
            if let product = registryProperty(service, "Product") as? String, !product.isEmpty {
                devices[product] = "input"
            }
        }
    }
    return devices
}

func bluetoothDevices() -> [String: String] {
    // An audio device that also has HID services (AirPods' controls) is audio.
    bluetoothInputDevices().merging(bluetoothAudioDevices()) { _, audio in audio }
}

// Values are "<kind>|<name>", so a device changing kind isn't reported twice.
let bluetooth = PresenceReporter(appearDelay: 1, disappearDelay: 2, quietAfterWake: false,
                                 snapshot: { bluetoothDevices().mapValues { $0 } }) { name, kind, present in
    handOff(["bluetooth", present ? "connected" : "disconnected", kind, "wireless"], name: name)
}
var audioDevicesAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &audioDevicesAddress, .main) { _, _ in
    bluetooth.changed()
}
for transport in ["Bluetooth", "Bluetooth Low Energy"] {
    watchRegistry({ bluetoothHIDMatching(transport) }) { bluetooth.changed() }
}

// Core Audio helpers.
func audioProperty<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                      _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ initial: T) -> T? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(id, &address) else { return nil }
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
}

func audioName(_ id: AudioObjectID) -> String {
    var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var name: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr else { return "Audio device" }
    return (name?.takeRetainedValue() as String?) ?? "Audio device"
}

func audioHasStreams(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
}

func allAudioDevices() -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

/// Calls `changed` when `selector` changes on any audio device, including
/// devices that appear later.
var audioListenedDevices = Set<String>()
func watchAudioDevices(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope,
                       changed: @escaping () -> Void) {
    func attach() {
        for id in allAudioDevices() where !audioListenedDevices.contains("\(selector)|\(scope)|\(id)") {
            audioListenedDevices.insert("\(selector)|\(scope)|\(id)")
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(id, &address, .main) { _, _ in changed() }
        }
    }
    attach()
    var devices = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devices, .main) { _, _ in
        attach()
        changed()
    }
}

// Microphone in use: any real input device running for any process. Virtual
// and aggregate devices (Loopback and the like) aren't microphones.
func microphonesInUse() -> [String: String] {
    for id in allAudioDevices() where audioHasStreams(id, kAudioObjectPropertyScopeInput) {
        let transport = audioProperty(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0
        if transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate { continue }
        if audioProperty(id, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, UInt32(0)) == 1 {
            return ["microphone": audioName(id)]
        }
    }
    return [:]
}

let microphone = PresenceReporter(appearDelay: 0.5, disappearDelay: 1, quietAfterWake: false,
                                  snapshot: microphonesInUse) { _, name, present in
    handOff(["microphone", present ? "started" : "stopped"], name: name)
}
watchAudioDevices(kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal) { microphone.changed() }

// The built-in headphone jack: the built-in output's data source switches
// between the speakers ('ispk') and headphones ('hdpn').
let dataSourceHeadphones: UInt32 = 0x6864_706E // 'hdpn'
func headphonesPlugged() -> [String: String] {
    for id in allAudioDevices() where audioHasStreams(id, kAudioObjectPropertyScopeOutput) {
        guard audioProperty(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, UInt32(0)) == kAudioDeviceTransportTypeBuiltIn else { continue }
        if audioProperty(id, kAudioDevicePropertyJackIsConnected, kAudioObjectPropertyScopeOutput, UInt32(0)) == 1
            || audioProperty(id, kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput, UInt32(0)) == dataSourceHeadphones {
            return ["headphones": "Headphones"]
        }
    }
    return [:]
}

let headphones = PresenceReporter(appearDelay: 0, disappearDelay: 0.5, quietAfterWake: false,
                                  snapshot: headphonesPlugged) { _, name, present in
    let state = present ? "connected" : "disconnected"
    handOff(["audio", "headphones", state, "hardware"], name: name)
}
watchAudioDevices(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput) { headphones.changed() }
watchAudioDevices(kAudioDevicePropertyJackIsConnected, kAudioObjectPropertyScopeOutput) { headphones.changed() }

// The default output device changing (AirPods taking over, and so on).
func defaultOutput() -> [String: String] {
    guard let id = audioProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                                 kAudioObjectPropertyScopeGlobal, AudioObjectID(0)), id != 0 else { return [:] }
    let name = audioName(id)
    return [name: name]
}
let output = PresenceReporter(appearDelay: 0.5, disappearDelay: 0.5, quietAfterWake: true,
                              snapshot: defaultOutput) { _, name, present in
    if present { handOff(["audio", "outputChanged"], name: name) }
}
var defaultOutputAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                      mScope: kAudioObjectPropertyScopeGlobal,
                                                      mElement: kAudioObjectPropertyElementMain)
AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultOutputAddress, .main) { _, _ in
    output.changed()
}

// Camera in use, through Core Media I/O.
func cmioAddress(_ selector: Int) -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                              mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                              mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
}

func allCameras() -> [CMIOObjectID] {
    var address = cmioAddress(kCMIOHardwarePropertyDevices)
    var size: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
    var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &ids) == noErr else { return [] }
    return ids
}

func camerasInUse() -> [String: String] {
    for id in allCameras() {
        var running: UInt32 = 0
        var used: UInt32 = 0
        var address = cmioAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
        guard CMIOObjectGetPropertyData(id, &address, 0, nil, 4, &used, &running) == noErr, running == 1 else { continue }
        var name: Unmanaged<CFString>?
        var nameAddress = cmioAddress(kCMIOObjectPropertyName)
        CMIOObjectGetPropertyData(id, &nameAddress, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, &name)
        return ["camera": (name?.takeRetainedValue() as String?) ?? "Camera"]
    }
    return [:]
}

let camera = PresenceReporter(appearDelay: 0.5, disappearDelay: 1, quietAfterWake: false,
                              snapshot: camerasInUse) { _, name, present in
    handOff(["camera", present ? "started" : "stopped"], name: name)
}
var cameraListened = Set<CMIOObjectID>()
func attachCameras() {
    for id in allCameras() where !cameraListened.contains(id) {
        cameraListened.insert(id)
        var address = cmioAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
        CMIOObjectAddPropertyListenerBlock(id, &address, .main) { _, _ in camera.changed() }
    }
}
attachCameras()
var cameraListAddress = cmioAddress(kCMIOHardwarePropertyDevices)
CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &cameraListAddress, .main) { _, _ in
    attachCameras()
    camera.changed()
}

// Heat and Low Power Mode.
func throttleLevel(_ state: ProcessInfo.ThermalState) -> String? {
    switch state {
    case .serious: return "serious"
    case .critical: return "critical"
    default: return nil
    }
}
var lastThermalState = ProcessInfo.processInfo.thermalState
NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
    let state = ProcessInfo.processInfo.thermalState
    let level = throttleLevel(state)
    let wasLevel = throttleLevel(lastThermalState)
    lastThermalState = state
    if let level, level != wasLevel {
        handOff(["thermal", "throttling", level], name: "")
    } else if level == nil, wasLevel != nil {
        handOff(["thermal", "cooled"], name: "")
    }
}
var lastLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
NotificationCenter.default.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
    let enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    guard enabled != lastLowPowerMode else { return }
    lastLowPowerMode = enabled
    handOff(["lowPowerMode", enabled ? "on" : "off"], name: "")
}

// The lid. IOPMrootDomain's AppleClamshellState changes with it, and the root
// domain's general-interest messages say when to look.
let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
func lidIsClosed() -> Bool? { registryProperty(rootDomain, "AppleClamshellState") as? Bool }
var lastLidClosed = lidIsClosed()
var lidClosedAt: Date?
var lidOpenedAt: Date?
var awaitingLidReady = false
var lidPort: IONotificationPortRef?
var lidNotification: io_object_t = 0

func lidChanged() {
    guard let closed = lidIsClosed(), closed != lastLidClosed else { return }
    lastLidClosed = closed
    if closed {
        lidClosedAt = Date()
        awaitingLidReady = false
        handOff(["lid", "closed"], name: "")
    } else {
        lidOpenedAt = Date()
        awaitingLidReady = true
        handOff(["lid", "opened"], name: "")
        checkLidReady()
    }
}

// Ready: the system awake and the display on. Called whenever either might
// have changed since the lid opened.
func displayIsOn() -> Bool {
    // The internal display's power state, as the display wrangler sees it
    // (4 = on). Missing on some Macs; then wake alone counts.
    let wrangler = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IODisplayWrangler"))
    defer { if wrangler != 0 { IOObjectRelease(wrangler) } }
    guard wrangler != 0,
          let power = registryProperty(wrangler, "IOPowerManagement") as? [String: Any],
          let state = power["CurrentPowerState"] as? Int else { return true }
    return state >= 4
}

func checkLidReady() {
    guard awaitingLidReady, !asleep, displayIsOn() else { return }
    awaitingLidReady = false
    handOff(["lid", "ready"], name: "")
}

if let port = IONotificationPortCreate(kIOMainPortDefault) {
    lidPort = port
    IONotificationPortSetDispatchQueue(port, .main)
    IOServiceAddInterestNotification(port, rootDomain, kIOGeneralInterest, { _, _, _, _ in
        lidChanged()
        checkLidReady()
    }, nil, &lidNotification)
}

if let emitTags {
    handOff(emitTags, name: emitName)
    exit(0)
}

if snapshotOnly {
    let lid = lidIsClosed().map { $0 ? "closed" : "open" } ?? "unknown"
    print("Lid: \(lid), display on: \(displayIsOn()), heat: \(ProcessInfo.processInfo.thermalState.rawValue), " +
          "Low Power Mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled)")
    for (title, items) in [("Thunderbolt", thunderboltDevices()), ("Network", networkConnections()),
                           ("Bluetooth", bluetoothDevices()), ("Microphone", microphonesInUse()),
                           ("Camera", camerasInUse()), ("Headphone jack", headphonesPlugged()),
                           ("Default output", defaultOutput())] {
        print("\(title): " + (items.isEmpty ? "none" : items.map { "\($0.key) = \($0.value)" }.sorted().joined(separator: ", ")))
    }
    exit(0)
}

// Sleep and wake. The messages are IOKit macros Swift doesn't import.
let messageCanSystemSleep: UInt32 = 0xE000_0270
let messageSystemWillSleep: UInt32 = 0xE000_0280
let messageSystemHasPoweredOn: UInt32 = 0xE000_0300
var rootPowerPort: io_connect_t = 0
var powerNotifier: io_object_t = 0
var powerPort: IONotificationPortRef?
rootPowerPort = IORegisterForSystemPower(nil, &powerPort, { _, _, messageType, argument in
    switch messageType {
    case messageCanSystemSleep:
        IOAllowPowerChange(rootPowerPort, Int(bitPattern: argument))
    case messageSystemWillSleep:
        asleep = true
        // Closing the lid sends the Mac straight to sleep; hold it back a
        // moment (macOS allows up to 30 seconds) so the lid sound is heard.
        if let closed = lidClosedAt, Date().timeIntervalSince(closed) < 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                IOAllowPowerChange(rootPowerPort, Int(bitPattern: argument))
            }
        } else {
            IOAllowPowerChange(rootPowerPort, Int(bitPattern: argument))
        }
    case messageSystemHasPoweredOn:
        asleep = false
        connectionsQuietUntil = Date().addingTimeInterval(30)
        for reporter in [thunderbolt, bluetooth, microphone, camera, headphones, output] + (network.map { [$0] } ?? []) {
            reporter.resync()
        }
        lidChanged()
        checkLidReady()
    default:
        break
    }
}, &powerNotifier)
if let powerPort { IONotificationPortSetDispatchQueue(powerPort, .main) }

try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
FileManager.default.createFile(atPath: (stateDir as NSString).appendingPathComponent("features"),
                               contents: "thunderbolt network bluetooth audio microphone camera lid thermal lowPowerMode\n".data(using: .utf8),
                               attributes: [.posixPermissions: 0o644])

dispatchMain()
