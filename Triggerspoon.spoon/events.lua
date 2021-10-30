local Triggerspoon = ...;

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

Triggerspoon.appWatcher = hs.application.watcher.new(function(name, type, app)
    Triggerspoon:handleEvent({
        tags = {"app", appEvents[type], name},
        data = {
            app = app,
            textArgs = {name, appEvents[type]}
        }
    })
end)
Triggerspoon.appWatcher:start()

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

Triggerspoon.caffWatcher = hs.caffeinate.watcher.new(function(type)
    Triggerspoon:handleEvent({
        tags = {"caff", caffEvents[type]},
        data = {
            textArgs = {caffEvents[type]}
        }
    })
end)
Triggerspoon.caffWatcher:start()

Triggerspoon.usbWatcher = hs.usb.watcher.new(function(usbInfo)
    Triggerspoon:handleEvent({
        tags = {"usb", usbInfo.eventType, usbInfo.productName},
        data = {
            eventInfo = usbInfo,
            textArgs = {((usbInfo.eventType == "added") and "connected" or "disconnected"), usbInfo.productName}
        }
    })
end)
Triggerspoon.usbWatcher:start()

Triggerspoon.spacesWatcher = hs.spaces.watcher.new(function(spaceNumber)
    Triggerspoon:handleEvent({
        tags = {"spacechanged", "space" .. spaceNumber},
        data = {
            spaceNumber = spaceNumber,
            textArgs = {spaceNumber}
        }
    })
end)
Triggerspoon.spacesWatcher:start()

Triggerspoon.pasteboardWatcher = hs.pasteboard.watcher.new(function(pasteboard)
    Triggerspoon:handleEvent({
        tags = {"pasteboard", pasteboard},
        data = {
            contents = pasteboard,
            textArgs = {pasteboard}
        }
    })
end)
Triggerspoon.pasteboardWatcher:start()

-- for some amount of filename convention
local powerSourceFilenames = {
    ["AC Power"] = "onAC",
    ["Battery Power"] = "onBattery",
    ["Off Line"] = "offline"
}

Triggerspoon.lastBatteryState = hs.battery.getAll()

Triggerspoon.batteryWatcher = hs.battery.watcher.new(function()
    local batteryState = hs.battery.getAll()
    if batteryState.isCharging ~= Triggerspoon.lastBatteryState.isCharging then
        Triggerspoon:handleEvent({
            tags = {"battery", batteryState.isCharging and "charging" or "notCharging"},
            data = {
                batteryState = batteryState
            }
        })
    end
    if batteryState.percentage ~= Triggerspoon.lastBatteryState.percentage then
        Triggerspoon:handleEvent({
            tags = {"battery", "level", tostring(batteryState.percentage) .. "percent",
                    (batteryState.percentage > Triggerspoon.lastBatteryState.percentage) and "up" or "down"},
            data = {
                batteryState = batteryState,
                textArgs = {tostring(batteryState.percentage)}
            }
        })
    end
    if batteryState.powerSource ~= Triggerspoon.lastBatteryState.powerSource then
        Triggerspoon:handleEvent({
            tags = {"power", powerSourceFilenames[batteryState.powerSource]},
            data = {
                batteryState = batteryState,
                textArgs = {tostring(batteryState.powerSource)}
            }
        })
    end
    Triggerspoon.lastBatteryState = batteryState
end)
Triggerspoon.batteryWatcher:start()

Triggerspoon.screenWatcher=hs.screen.watcher.newWithActiveScreen(function()
Triggerspoon:handleEvent({
    tags={"screenchanged"}
})
end)
Triggerspoon.screenWatcher:start()
