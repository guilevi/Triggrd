local userAutomationsPath = ...

local snMapping = {
    login = 'Triggrd.started',
    logout = 'caff.systemWillPowerOff',
    willsleep = 'caff.systemWillSleep',
    didwake = 'caff.systemDidWake',
    applicationbecamefront = 'app.activated',
    applicationwilllaunch = 'app.launching',
    applicationdidlaunch = 'app.launched',
    applicationdidterminate = 'app.terminated',
    applicationdidhide = 'app.hidden',
    applicationdidunhide = 'app.unhidden',
    screensdidsleep = 'caff.screensDidSleep',
    screenswakesleep = 'caff.screensDidWake',
    screenchange = 'screenchanged',
    spacechanged = 'spacechanged',
    volumerenamed = 'volume.didRename',
    didmountvolume = 'volume.didMount',
    willunmountvolume = 'volume.willUnmount',
    didunmountvolume = 'volume.didUnmount',
    usbconnected = 'usb.added',
    usbdisconnected = 'usb.removed',
    powersourcechanged = 'power',
    poweronac = 'power.onAC',
    poweronbattery = 'power.onBattery',
    charging = 'battery.charging',
    charged = 'battery.level.100percent.up',
    battery20minutes = 'battery.remaining.20min',
    battery10minutes = 'battery.remaining.10min',
    battery5minutes = 'battery.remaining.5min',
    focusedwindowchanged = 'window.focused',
    windowcreated = 'window.created',
    windowminiaturized = 'window.minimized',
    windowdeminiaturized = 'window.deminimized',
    drawercreated = 'window,drawer',
    sheetcreated = 'window.sheet',
    menuopened = 'menu.opened',
    menuclosed = 'menu.closed',
    menuitemselected = 'menu.itemSelected'
}

function copyFile(srcfile, destfile)
    if hs.fs.attributes(srcfile, 'mode') ~= "file" then
        return nil
    end
    infile = io.open(srcfile, 'rb')
    contents = infile:read('*a')
    infile:close()

    outfile = io.open(destfile, 'wb')
    outfile:write(contents)
    outfile:close()
    return true
end

sndir = hs.dialog.chooseFileOrFolder("Choose location of SoundNote pack",
    hs.fs.pathToAbsolute('~/Library/Application Support/MrGeckosMedia/SoundNote'), false, true)
local filesMigrated = 0

_, subdir = hs.dialog.textPrompt('Subdirectory name',
    'Enter the name of the subdirectory to be created in your automations folder', '')
hs.fs.mkdir(userAutomationsPath .. '/' .. subdir)

if sndir then
    sndir = sndir["1"]
    for k, v in pairs(snMapping) do
        if copyFile(sndir .. '/' .. k .. '.wav',
            hs.fs.pathToAbsolute(userAutomationsPath) .. '/' .. subdir .. '/' .. v .. '.wav') then
            filesMigrated = filesMigrated + 1
        end
    end
end

hs.dialog.alert(1, 1, function()
end, filesMigrated .. " files migrated successfully. The changes will take effect after the next reload.")
