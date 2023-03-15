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
    Triggrd:handleEvent({
        tags = {"usb", usbInfo.eventType, usbInfo.productName},
        data = {
            eventInfo = usbInfo,
            textArgs = {usbInfo.productName, ((usbInfo.eventType == "added") and "connected" or "disconnected")}
        }
    })
end)
Triggrd.usbWatcher:start()

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

if hs.battery.batteryType==nil then
-- for some amount of filename convention
local powerSourceFilenames = {
    ["AC Power"] = "onAC",
    ["Battery Power"] = "onBattery",
    ["Off Line"] = "offline"
}

Triggrd.lastBatteryState = hs.battery.getAll()

Triggrd.batteryWatcher = hs.battery.watcher.new(function()
    local batteryState = hs.battery.getAll()
    if batteryState.isCharging ~= Triggrd.lastBatteryState.isCharging then
        Triggrd:handleEvent({
            tags = {"battery", batteryState.isCharging and "charging" or "notCharging"},
            data = {
                batteryState = batteryState
            }
        })
    end
    if batteryState.percentage ~= Triggrd.lastBatteryState.percentage then
        Triggrd:handleEvent({
            tags = {"battery", "level", tostring(batteryState.percentage) .. "percent",
                    (batteryState.percentage > Triggrd.lastBatteryState.percentage) and "up" or "down"},
            data = {
                batteryState = batteryState,
                textArgs = {tostring(batteryState.percentage)}
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