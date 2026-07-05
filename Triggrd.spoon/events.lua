local Triggrd = ...;

-- the shittiest enum in existence
local appEvents = {
    [hs.application.watcher.activated] = "activated",
    [hs.application.watcher.deactivated] = "deactivated",
    [hs.application.watcher.hidden] = "hidden",
    [hs.application.watcher.launched] = "launched",
    [hs.application.watcher.launching] = "launching",
    [hs.application.watcher.terminated] = "terminated",
    [hs.application.watcher.unhidden] = "unhidden"
}

Triggrd.appWatcher = hs.application.watcher.new(function(name, type, app)
    Triggrd:handleEvent({
        tags = {"app", appEvents[type], name},
        data = {
            app = app,
            textArgs = {name, appEvents[type]}
        }
    })
    updateAppList(type, app)
end)
Triggrd.appWatcher:start()

local caffEvents = {
    [hs.caffeinate.watcher.screensaverDidStart] = "screensaverDidStart",
    [hs.caffeinate.watcher.screensaverDidStop] = "screensaverDidStop",
    [hs.caffeinate.watcher.screensaverWillStop] = "screensaverWillStop",
    [hs.caffeinate.watcher.screensDidLock] = "screensDidLock",
    [hs.caffeinate.watcher.screensDidSleep] = "screensDidSleep",
    [hs.caffeinate.watcher.screensDidUnlock] = "screensDidUnlock",
    [hs.caffeinate.watcher.screensDidWake] = "screensDidWake",
    [hs.caffeinate.watcher.sessionDidBecomeActive] = "sessionDidBecomeActive",
    [hs.caffeinate.watcher.sessionDidResignActive] = "sessionDidResignActive",
    [hs.caffeinate.watcher.systemDidWake] = "systemDidWake",
    [hs.caffeinate.watcher.systemWillPowerOff] = "systemWillPowerOff",
    [hs.caffeinate.watcher.systemWillSleep] = "systemWillSleep"
}

Triggrd.caffWatcher = hs.caffeinate.watcher.new(function(type)
    Triggrd:handleEvent({
        tags = {"caff", caffEvents[type]},
        data = {
            textArgs = {caffEvents[type]}
        }
    })
end)
Triggrd.caffWatcher:start()

Triggrd.usbWatcher = hs.usb.watcher.new(function(usbInfo)
    -- "device" is the umbrella tag (any device connect/disconnect, regardless of
    -- bus); "usb" is kept as a source qualifier for backward compatibility with
    -- existing usb.added.wav / usb.removed.wav soundpacks. See the Thunderbolt
    -- poller below, which emits the same "device" tag with a "thunderbolt" qualifier.
    Triggrd:handleEvent({
        tags = {"device", "usb", usbInfo.eventType, usbInfo.productName},
        data = {
            eventInfo = usbInfo,
            textArgs = {usbInfo.productName, ((usbInfo.eventType == "added") and "connected" or "disconnected")}
        }
    })
end)
Triggrd.usbWatcher:start()

-- Thunderbolt / USB4 device connect / disconnect.
--
-- Devices attached DIRECTLY to a USB4/Thunderbolt port (e.g. a bus-powered SSD)
-- are invisible to hs.usb.watcher -- they enumerate on the Thunderbolt bus, not
-- classic USB. Hammerspoon has no push-based Thunderbolt watcher, and the
-- in-process enumeration paths (hs.usb.attachedDevices / hs.battery.getAll) are
-- Bluetooth-TCC landmines that SIGKILL the app on macOS 27. So we poll
-- `system_profiler -json SPThunderboltDataType` in a SUBPROCESS via hs.task
-- (crash-free, no in-process Bluetooth, non-blocking) and diff the device set.
--
-- Connects/disconnects are announced with the umbrella "device" tag plus a
-- "thunderbolt" source qualifier ({"device","thunderbolt","added"/"removed", name}),
-- mirroring the USB watcher above. So device.added.wav / device.removed.wav fire
-- for BOTH USB and Thunderbolt, while thunderbolt.added.wav / usb.added.wav can be
-- used for source-specific sounds.

Triggrd.knownTbDevices = {}   -- switch_uid_key -> friendly device name
Triggrd.tbSeeded = false      -- first poll seeds silently (no startup chimes)
Triggrd.tbPolling = false     -- guard against overlapping polls

-- Downstream devices live in `_items`; the top-level bus entries are the Mac
-- itself and are skipped. Recurse to catch daisy-chained devices too.
local function collectTbDevices(items, out)
    if type(items) ~= "table" then return out end
    for _, dev in ipairs(items) do
        local uid = dev.switch_uid_key
        if uid then
            out[uid] = dev.device_name_key or dev.vendor_name_key or "Thunderbolt device"
        end
        collectTbDevices(dev._items, out)
    end
    return out
end

local function pollThunderbolt()
    if Triggrd.tbPolling then return end
    Triggrd.tbPolling = true
    local task = hs.task.new("/usr/sbin/system_profiler", function(exitCode, stdout)
        Triggrd.tbPolling = false
        if exitCode ~= 0 or not stdout then return end
        local ok, data = pcall(hs.json.decode, stdout)
        if not ok or type(data) ~= "table" or type(data.SPThunderboltDataType) ~= "table" then
            return
        end

        local current = {}
        for _, bus in ipairs(data.SPThunderboltDataType) do
            collectTbDevices(bus._items, current)
        end

        if Triggrd.tbSeeded then
            for uid, name in pairs(current) do
                if not Triggrd.knownTbDevices[uid] then
                    Triggrd:handleEvent({
                        tags = {"device", "thunderbolt", "added", name},
                        data = {textArgs = {name, "connected"}}
                    })
                end
            end
            for uid, name in pairs(Triggrd.knownTbDevices) do
                if not current[uid] then
                    Triggrd:handleEvent({
                        tags = {"device", "thunderbolt", "removed", name},
                        data = {textArgs = {name, "disconnected"}}
                    })
                end
            end
        else
            Triggrd.tbSeeded = true -- established the baseline; announce changes from here on
        end
        Triggrd.knownTbDevices = current
    end, {"-json", "SPThunderboltDataType"})
    if task then task:start() else Triggrd.tbPolling = false end
end

pollThunderbolt() -- seed the currently-connected set silently
-- Poll interval = worst-case detection latency, but also = timer-wakeup cadence,
-- which is what actually costs battery on Apple Silicon (frequent wakeups keep the
-- CPU out of deep idle). There is no push/event API a spoon can use for bare
-- Thunderbolt devices -- that would need native IOKit code -- so we poll, but
-- gently. Storage devices are already caught instantly and for free by the
-- hs.fs.volume watcher, and classic USB by hs.usb.watcher (both push-based); this
-- poll only covers non-storage devices attached directly to a TB/USB4 port.
Triggrd.tbPollTimer = hs.timer.doEvery(2, pollThunderbolt)

Triggrd.spacesWatcher = hs.spaces.watcher.new(function(spaceNumber)
    Triggrd:handleEvent({
        tags = {"spacechanged", "space" .. spaceNumber},
        data = {
            spaceNumber = spaceNumber,
            textArgs = {spaceNumber}
        }
    })
end)
Triggrd.spacesWatcher:start()

Triggrd.pasteboardWatcher = hs.pasteboard.watcher.new(function(pasteboard)
    Triggrd:handleEvent({
        tags = {"pasteboard", pasteboard},
        data = {
            contents = pasteboard,
            textArgs = {pasteboard}
        }
    })
end)
Triggrd.pasteboardWatcher:start()

-- Only wire up the battery watcher on machines that actually have a battery.
-- (The original guard was `hs.battery.batteryType==nil`, which compares the
-- function value itself to nil -- always false -- so this whole block never ran
-- and no battery sounds ever played. batteryType() returns the battery type
-- string, or nil when there is no battery.)
if hs.battery.batteryType() ~= nil then
-- for some amount of filename convention
local powerSourceFilenames = {
    ["AC Power"] = "onAC",
    ["Battery Power"] = "onBattery",
    ["Off Line"] = "offline"
}

-- IMPORTANT: do NOT use hs.battery.getAll() here. getAll() iterates every
-- battery field, including privateBluetoothBatteryInfo(), which reads Bluetooth
-- peripheral batteries. On macOS 27 that trips a Bluetooth privacy (TCC) check,
-- and because Hammerspoon's Info.plist has no NSBluetoothAlwaysUsageDescription
-- the OS SIGKILLs the whole app. Read only the internal-battery fields we need.
--
-- Also note hs.battery.percentage() returns a float (100.0 * current / max), so
-- the level is rounded to a whole number; otherwise tags would look like
-- "100.0percent" and never match automation files like battery.100percent.
local function readBattery()
    return {
        percentage = hs.battery.percentage(),
        isCharging = hs.battery.isCharging(),
        powerSource = hs.battery.powerSource(),
    }
end

local function batteryLevel(state)
    local pct = state.percentage
    if type(pct) ~= "number" then return nil end
    return math.floor(pct + 0.5)
end

Triggrd.lastBatteryState = readBattery()

Triggrd.batteryWatcher = hs.battery.watcher.new(function()
    local batteryState = readBattery()
    if batteryState.isCharging ~= Triggrd.lastBatteryState.isCharging then
        Triggrd:handleEvent({
            tags = {"battery", batteryState.isCharging and "charging" or "notCharging"},
            data = {
                batteryState = batteryState
            }
        })
    end
    local level = batteryLevel(batteryState)
    local lastLevel = batteryLevel(Triggrd.lastBatteryState)
    if level ~= nil and level ~= lastLevel then
        Triggrd:handleEvent({
            tags = {"battery", "level", level .. "percent",
                    (lastLevel ~= nil and level > lastLevel) and "up" or "down"},
            data = {
                batteryState = batteryState,
                textArgs = {tostring(level)}
            }
        })
    end
    if batteryState.powerSource ~= Triggrd.lastBatteryState.powerSource then
        Triggrd:handleEvent({
            tags = {"power", powerSourceFilenames[batteryState.powerSource]},
            data = {
                batteryState = batteryState,
                textArgs = {tostring(batteryState.powerSource)}
            }
        })
    end
    Triggrd.lastBatteryState = batteryState
end)
Triggrd.batteryWatcher:start()
end

Triggrd.screenWatcher = hs.screen.watcher.newWithActiveScreen(function()
    Triggrd:handleEvent({
        tags = {"screenchanged"}
    })
end)
Triggrd.screenWatcher:start()

-- I'm tired of these shitty enums, is there a better way to do this?
local volumeEvents = {
    [hs.fs.volume.didMount] = "didMount",
    [hs.fs.volume.didRename] = "didRename",
    [hs.fs.volume.didUnmount] = "didUnmount",
    [hs.fs.volume.willUnmount] = "willUnmount"
}

Triggrd.volumeWatcher = hs.fs.volume.new(function(eventType, volumeInfo)
if not volumeInfo.path:lower():find("timemachine") then
    Triggrd:handleEvent({
        tags = {"volume", volumeEvents[eventType]},
        data = {
            volumeInfo = volumeInfo,
            textArgs = {volumeInfo.NSURLVolumeNameKey}
        }
    })
end
end)
Triggrd.volumeWatcher:start()

function updateAppList(eventType, app)
    if eventType == hs.application.watcher.launched then
        for _, i in ipairs(Triggrd.runningApps) do
            if i[1] == app then
                return
            end
        end
        table.insert(Triggrd.runningApps, Triggrd.generateAppListItem(Triggrd, app))
    elseif eventType == hs.application.watcher.terminated then
        Triggrd.runningApps = hs.fnutils.ifilter(Triggrd.runningApps, function(i)
            -- Quick attempted fix, there is probably a cleaner way
            if i[1] == app and i[3] ~= nil then
                i[3]:stop()
            end
            return i[1] ~= app
        end)
    end
end

Triggrd.wifiWatcher=hs.wifi.watcher.new(function(type,wifiInfo)
    print('info'..hs.inspect.inspect(wifiInfo)..' and '..hs.inspect.inspect(type))
end)
Triggrd.wifiWatcher:start()