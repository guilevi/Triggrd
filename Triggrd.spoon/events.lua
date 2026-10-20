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

-- Logout, restart and shutdown.
--
-- hs.caffeinate's systemWillPowerOff only arrives once macOS asks Hammerspoon
-- itself to quit. As a menu-bar app, Hammerspoon is quit late, after
-- loginwindow's "point of no return", with a few seconds of session left. So
-- we also follow loginwindow's own distributed notifications, which it posts
-- for the whole sequence:
--   com.apple.{logout,restart,shutdown}Initiated   confirmation shown; says which kind
--   com.apple.logoutContinued                      confirmed (for all three kinds);
--                                                  apps are about to be asked to quit
--   com.apple.logoutCancelled                      cancelled
--   com.apple.logoutInterrupted                    an app refused to quit
-- The power-off sound fires on logoutContinued, before any app has closed.
-- When the system sounds service (systemsounds.lua) is installed and has
-- sounds for the same moments (powerOff.noReturn, powerOff.cancelled), those
-- play instead of these, so nothing plays twice.
-- It's played detached (see Triggrd.playDetached in init.lua) so Hammerspoon
-- quitting doesn't cut it off.
--
-- Events:
--   {"caff", "systemWillPowerOff", kind}          -> caff.systemWillPowerOff.wav
--                                                    (or ...systemWillPowerOff.shutdown.wav, etc.)
--   {"powerOffFailed", kind, "interrupted"}       -> powerOffFailed.wav: an app kept it from happening
--   {"powerOffFailed", kind, "cancelled"}            cancelled after it had started
-- kind is "logout", "restart" or "shutdown".

Triggrd.sessionEndKind = "logout"

local function resetPowerOff()
    Triggrd.poweringOff = false
    Triggrd.sessionEndKind = "logout"
end

local function announcePowerOff()
    if Triggrd.poweringOff then return end -- already announced
    Triggrd.poweringOff = true
    -- If it's called off without us hearing about it, Hammerspoon keeps
    -- running; forget the flag after a while.
    Triggrd.poweringOffTimer = hs.timer.doAfter(60, resetPowerOff)
    -- The system sounds service plays powerOff.noReturn a moment later, for
    -- the same moment; if it has a sound for it, let that one play alone.
    if Triggrd:systemSoundsCover({"powerOff", "noReturn", Triggrd.sessionEndKind}) then return end
    Triggrd:handleEvent({
        tags = {"caff", "systemWillPowerOff", Triggrd.sessionEndKind},
        data = {
            detached = true,
            textArgs = {Triggrd.sessionEndKind}
        }
    })
end

local sessionEndKinds = {
    ["com.apple.logoutInitiated"] = "logout",
    ["com.apple.restartInitiated"] = "restart",
    ["com.apple.shutdownInitiated"] = "shutdown",
}

Triggrd.sessionWatchers = {}
local function watchSession(name, fn)
    local watcher = hs.distributednotifications.new(fn, name)
    watcher:start()
    table.insert(Triggrd.sessionWatchers, watcher)
end

for name, kind in pairs(sessionEndKinds) do
    watchSession(name, function() Triggrd.sessionEndKind = kind end)
end
watchSession("com.apple.logoutContinued", announcePowerOff)
-- loginwindow's system-wide logoutcancelled, which the system sounds service
-- plays powerOff.cancelled for, accompanies both of these.
local function systemCoversCancel()
    return Triggrd:systemSoundsCover({"powerOff", "cancelled", Triggrd.sessionEndKind})
end

watchSession("com.apple.logoutInterrupted", function()
    if not systemCoversCancel() then
        Triggrd:handleEvent({
            tags = {"powerOffFailed", Triggrd.sessionEndKind, "interrupted"},
            data = {textArgs = {Triggrd.sessionEndKind}}
        })
    end
    resetPowerOff()
end)
watchSession("com.apple.logoutCancelled", function()
    -- Cancelling the confirmation dialog also lands here; that's only a
    -- failure once it had actually started.
    if Triggrd.poweringOff and not systemCoversCancel() then
        Triggrd:handleEvent({
            tags = {"powerOffFailed", Triggrd.sessionEndKind, "cancelled"},
            data = {textArgs = {Triggrd.sessionEndKind}}
        })
    end
    resetPowerOff()
end)

Triggrd.caffWatcher = hs.caffeinate.watcher.new(function(type)
    if type == hs.caffeinate.watcher.systemWillPowerOff then
        -- Normally logoutContinued has already announced it; this is the
        -- fallback in case that notification ever goes missing.
        announcePowerOff()
        return
    end
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
    -- "hardware" + connected/disconnected is the wider umbrella shared with every
    -- wired connection (Thunderbolt, Ethernet, displays, the headphone jack).
    local state = usbInfo.eventType == "added" and "connected" or "disconnected"
    Triggrd:handleEvent({
        tags = {"device", "usb", usbInfo.eventType, "hardware", state, usbInfo.productName},
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
                        tags = {"device", "thunderbolt", "added", "hardware", "connected", name},
                        data = {textArgs = {name, "connected"}}
                    })
                end
            end
            for uid, name in pairs(Triggrd.knownTbDevices) do
                if not current[uid] then
                    Triggrd:handleEvent({
                        tags = {"device", "thunderbolt", "removed", "hardware", "disconnected", name},
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

-- Poll interval = worst-case detection latency, but also = timer-wakeup cadence,
-- which is what actually costs battery on Apple Silicon (frequent wakeups keep the
-- CPU out of deep idle). There is no push/event API a spoon can use for bare
-- Thunderbolt devices -- that needs native IOKit code -- so we poll, but gently.
-- Storage devices are already caught instantly and for free by the hs.fs.volume
-- watcher, and classic USB by hs.usb.watcher (both push-based); this poll only
-- covers non-storage devices attached directly to a TB/USB4 port.
--
-- The system sounds service (systemsounds.lua) does have that native code: when
-- it's installed, it reports Thunderbolt devices the moment they come and go,
-- with the same tags, and this poll is switched off.
Triggrd.tbPollTimer = hs.timer.new(2, pollThunderbolt)

function Triggrd:updateThunderboltPolling()
    if Triggrd:systemProvides("thunderbolt") then
        Triggrd.tbPollTimer:stop()
    elseif not Triggrd.tbPollTimer:running() then
        Triggrd.tbSeeded = false
        pollThunderbolt() -- seed the currently-connected set silently
        Triggrd.tbPollTimer:start()
    end
end
Triggrd:updateThunderboltPolling()

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

-- Watermark for level announcements. It only ever moves in the direction the
-- battery is actually travelling, and is re-based whenever the charge state
-- flips. See the comment in the watcher below.
Triggrd.batteryLevelMark = batteryLevel(Triggrd.lastBatteryState)

Triggrd.batteryWatcher = hs.battery.watcher.new(function()
    local batteryState = readBattery()
    local level = batteryLevel(batteryState)
    local charging = batteryState.isCharging == true
    local chargeStateChanged = batteryState.isCharging ~= Triggrd.lastBatteryState.isCharging

    -- Charging stopping while still plugged in is either the battery being full
    -- (battery.full) or charging being paused at a charge limit
    -- (battery.notCharging); macOS can take a moment to report which, so wait.
    -- Unplugging is announced at once.
    if chargeStateChanged then
        if Triggrd.batteryFullCheck then Triggrd.batteryFullCheck:stop() end
        if charging then
            Triggrd:handleEvent({tags = {"battery", "charging"}, data = {batteryState = batteryState}})
        elseif batteryState.powerSource == "AC Power" then
            Triggrd.batteryFullCheck = hs.timer.doAfter(3, function()
                if hs.battery.isCharging() then return end
                Triggrd:handleEvent({tags = {"battery", hs.battery.isCharged() and "full" or "notCharging"},
                                     data = {batteryState = readBattery()}})
            end)
        else
            Triggrd:handleEvent({tags = {"battery", "notCharging"}, data = {batteryState = batteryState}})
        end
    end

    -- "up" and "down" describe what the battery is actually doing (charging or
    -- not), NOT the sign of the percentage delta. macOS continuously re-estimates
    -- remaining capacity, so a Mac that is discharging can still report a
    -- percentage that ticks *up* by a point. Deriving the direction from the
    -- delta therefore emitted "up" while on battery, firing charge-complete
    -- tones during a discharge.
    --
    -- batteryLevelMark only moves in the direction of travel, so jitter around a
    -- threshold (10 -> 11 -> 10) announces that threshold once rather than twice.
    -- It is re-based -- without announcing -- whenever the charge state flips,
    -- because that is exactly when the direction of travel reverses.
    if level ~= nil then
        local mark = Triggrd.batteryLevelMark
        if chargeStateChanged or mark == nil then
            Triggrd.batteryLevelMark = level
        elseif (charging and level > mark) or (not charging and level < mark) then
            Triggrd:handleEvent({
                tags = {"battery", "level", level .. "percent",
                        charging and "up" or "down"},
                data = {
                    batteryState = batteryState,
                    textArgs = {tostring(level)}
                }
            })
            Triggrd.batteryLevelMark = level
        end
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

-- Displays connecting and disconnecting, by name. Under the "hardware"
-- umbrella like every other wired connection.
local function currentDisplays()
    local displays = {}
    for _, screen in ipairs(hs.screen.allScreens()) do
        displays[screen:getUUID() or tostring(screen:id())] = screen:name() or "Display"
    end
    return displays
end
Triggrd.knownDisplays = currentDisplays()
Triggrd.displayWatcher = hs.screen.watcher.new(function()
    local now = currentDisplays()
    for id, name in pairs(now) do
        if not Triggrd.knownDisplays[id] then
            Triggrd:handleEvent({tags = {"display", "connected", "hardware", name},
                                 data = {textArgs = {name, "connected"}}})
        end
    end
    for id, name in pairs(Triggrd.knownDisplays) do
        if not now[id] then
            Triggrd:handleEvent({tags = {"display", "disconnected", "hardware", name},
                                 data = {textArgs = {name, "disconnected"}}})
        end
    end
    Triggrd.knownDisplays = now
end)
Triggrd.displayWatcher:start()

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

-- Authentication prompts.
--
-- macOS has three kinds of password/Touch ID prompt, and none can be seen
-- reliably through the accessibility API:
--   * "sheet": the Touch ID / password sheet inside an app. In System Settings
--     it's drawn by the pane's extension process (e.g. SecurityPrivacyExtension),
--     not by System Settings itself.
--   * "dialog": the standalone SecurityAgent window ("X wants to make changes",
--     installers, AuthorizationExecuteWithPrivileges, ...).
--   * "touchid": the LocalAuthentication "App is trying to ..." / "would like
--     to authenticate" window apps like 1Password, the Passwords app and Xcode
--     ask for. Drawn by coreautha on behalf of coreauthd; these never reach
--     authd, and a request that's satisfied without showing UI isn't logged
--     by the lines below, so only visible prompts make a sound.
-- All are logged, so we follow the system log with `log stream` in a
-- subprocess. The messages used for sheets and dialogs:
--   sheet shown        SheetSupport  "Displaying sheet"
--   sheet cancelled    SheetSupport  "Sheet ended with an error: ... Canceled by user."
--   dialog shown       authd         "engine N: running mechanism builtin:authenticate (1 of 3)"
--   dialog cancelled   authd         "Failed to authorize right ... (-60006)"
--   success (both)     authd         "UID n authenticated as user x (UID n) for right 'r'"
-- The success line is also logged when the screen is unlocked or at login
-- (rights system.login.*), which already have their own caff.* events, so
-- those are skipped.
--
-- And for Touch ID prompts, all from coreauthd:
--   requesting app     "Determined name <app> and bundle ID <id> for pid <pid>"
--   shown              "showing UI: <LACRemoteUIParams ID:<rid>-<ui>-0, ..., pid: <pid>, ...>"
--   succeeded          "MechanismUI[<ui>](run) has finished with { ... }"
--   cancelled          "MechanismUI[<ui>](run) has finished with Error ... Code=-2 ..."
-- ("Activator did successfully finish request" is logged on cancel too, so it
-- is NOT a success signal.)
--
-- Events (tags are subset-matched, so they must not share a first tag):
--   {"authentication", "required", kind[, app]}          -> authentication.wav
--   {"authenticated", kind[, app]}                       -> authenticated.wav
--   {"authenticationFailed", "cancelled", kind[, app]}   -> authenticationFailed.wav
--   {"authenticationFailed", "failed", kind[, app]}      -> authenticationFailed.failed.wav, ...
-- kind is "sheet", "dialog" or "touchid"; app (touchid only) is the requesting
-- app's name, e.g. authenticated.touchid.1Password.wav.

-- kind of the prompt currently on screen, or nil. Lets the authd lines, which
-- don't say where the prompt came from, be attributed, and keeps failure
-- sounds to prompts we actually announced.
Triggrd.authPrompt = nil

-- Touch ID prompts on screen (MechanismUI id -> requesting app name), and the
-- app names coreauthd has just resolved (pid -> name), which is how a prompt
-- learns who asked for it.
Triggrd.touchIdPrompts = {}
Triggrd.authAppNames = {}

local function authEvent(tags)
    Triggrd:handleEvent({tags = tags, data = {textArgs = {tags[#tags]}}})
end

local function handleAuthLogLine(line)
    -- Skip the plain-text "Filtering the log data using ..." header; hs.json
    -- logs an error to the console for anything it can't parse.
    if line:sub(1, 1) ~= "{" then return end
    local ok, entry = pcall(hs.json.decode, line)
    if not ok or type(entry) ~= "table" or type(entry.eventMessage) ~= "string" then
        return
    end
    local msg = entry.eventMessage

    if (entry.processImagePath or ""):find("/coreauthd$") then
        local name, pid = msg:match("^Determined name (.-) and bundle ID .- for pid (%d+)")
        if name then
            Triggrd.authAppNames[pid] = name
            return
        end
        local ui, uiPid = msg:match("^showing UI: <LACRemoteUIParams ID:%d+%-(%d+)%-.-pid: (%d+)")
        if ui then
            local app = Triggrd.authAppNames[uiPid] or "unknown"
            Triggrd.authAppNames = {}
            Triggrd.touchIdPrompts[ui] = app
            authEvent({"authentication", "required", "touchid", app})
            return
        end
        local finishedUi, rest = msg:match("^MechanismUI%[(%d+)%]%(run%) has finished with (.*)")
        local app = finishedUi and Triggrd.touchIdPrompts[finishedUi]
        if app then
            Triggrd.touchIdPrompts[finishedUi] = nil
            if rest:find("^Error") then
                authEvent({"authenticationFailed",
                    rest:find("Code=-2 ", 1, true) and "cancelled" or "failed", "touchid", app})
            else
                authEvent({"authenticated", "touchid", app})
            end
        end
        return
    end

    if entry.category == "SheetSupport" then
        if msg:find("^Displaying sheet") then
            Triggrd.authPrompt = "sheet"
            authEvent({"authentication", "required", "sheet"})
        elseif msg:find("^Sheet ended with an error") then
            Triggrd.authPrompt = nil
            authEvent({"authenticationFailed", msg:find("Canceled by user") and "cancelled" or "failed", "sheet"})
        elseif msg:find("^Sheet ended with success") then
            -- authd's "authenticated as" line (which comes just before this)
            -- has already announced it.
            Triggrd.authPrompt = nil
        end
        return
    end

    -- Everything below comes from authd.
    if msg:find("running mechanism builtin:authenticate (1 of", 1, true) then
        Triggrd.authPrompt = "dialog"
        authEvent({"authentication", "required", "dialog"})
    elseif msg:find(" authenticated as user ", 1, true) then
        local right = msg:match("for right '([^']*)'") or ""
        if right:find("^system%.login%.") then return end
        local kind = Triggrd.authPrompt or "dialog"
        if kind == "dialog" then Triggrd.authPrompt = nil end
        authEvent({"authenticated", kind})
    elseif msg:find("^Failed to authorize right") and Triggrd.authPrompt == "dialog" then
        Triggrd.authPrompt = nil
        authEvent({"authenticationFailed", msg:find("(-60006)", 1, true) and "cancelled" or "failed", "dialog"})
    end
end

local authLogPredicate = table.concat({
    '(subsystem == "com.apple.Authorization" AND category == "SheetSupport")',
    'OR (process == "authd" AND category == "authd" AND (',
    'eventMessage CONTAINS "running mechanism builtin:authenticate (1 of"',
    'OR eventMessage CONTAINS " authenticated as user "',
    'OR eventMessage BEGINSWITH "Failed to authorize right"))',
    'OR (process == "coreauthd" AND subsystem == "com.apple.LocalAuthentication" AND (',
    'eventMessage BEGINSWITH "Determined name "',
    'OR eventMessage BEGINSWITH "showing UI: "',
    'OR (eventMessage BEGINSWITH "MechanismUI[" AND eventMessage CONTAINS "has finished with")))',
}, " ")

local function startAuthLogStream()
    local buffer = ""
    Triggrd.authLogTask = hs.task.new("/usr/bin/log", function()
        -- log stream only exits if something went wrong; restart it, gently.
        if not Triggrd.authLogStopped then
            Triggrd.authLogRestartTimer = hs.timer.doAfter(5, startAuthLogStream)
        end
    end, function(_, stdout)
        buffer = buffer .. (stdout or "")
        for line in buffer:gmatch("([^\n]*)\n") do
            handleAuthLogLine(line)
        end
        buffer = buffer:match("([^\n]*)$")
        return true
    end, {"stream", "--style", "ndjson", "--predicate", authLogPredicate})
    Triggrd.authLogTask:start()
end

-- Exposed for diagnostics (replaying captured log lines from the hs CLI).
Triggrd._handleAuthLogLine = handleAuthLogLine

startAuthLogStream()

Triggrd.wifiWatcher=hs.wifi.watcher.new(function(type,wifiInfo)
    print('info'..hs.inspect.inspect(wifiInfo)..' and '..hs.inspect.inspect(type))
end)
Triggrd.wifiWatcher:start()