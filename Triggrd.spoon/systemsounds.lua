-- System sounds: installing, removing and cooperating with triggrd-system, the
-- small system service (a LaunchDaemon) that plays sounds for events outside
-- the logged-in session: the Mac starting up, logging in, and logging out /
-- restarting / shutting down. Its source and the install scripts live in the
-- spoon's system/ folder; see system/triggrd-system.swift for its events.
local Triggrd = ...

local label = "com.triggrd.system"
local plistPath = "/Library/LaunchDaemons/" .. label .. ".plist"
local soundsFolder = "/Library/Sounds/Triggrd"
local stateFolder = "/Library/Application Support/Triggrd"
local loginMarker = stateFolder .. "/loginSounds"
local systemFolder = hs.spoons.resourcePath("system")

Triggrd.systemSoundsFolder = soundsFolder

function Triggrd:systemSoundsInstalled()
    return hs.fs.attributes(plistPath) ~= nil
end

-- Hand-off: the service also watches devices and connections (things
-- Hammerspoon can't watch itself, or could only poll for), and passes those
-- events here, by appending "<tags>\t<name>" lines to <state>/events, for
-- Triggrd to play from the user's own theme. So quitting Hammerspoon silences
-- them along with every other Triggrd sound. <state>/features lists what this
-- version of the service watches.

-- state is only for testing; it defaults to the service's state folder.
function Triggrd:systemProvides(feature, state)
    if not state and not Triggrd:systemSoundsInstalled() then return false end
    local file = io.open((state or stateFolder) .. "/features")
    if not file then return false end
    local features = file:read("a")
    file:close()
    return (" " .. features:gsub("%s+", " ") .. " "):find(" " .. feature .. " ", 1, true) ~= nil
end

local handOff = {}

local function readHandedOffEvents()
    local path = handOff.folder .. "/events"
    local attrs = hs.fs.attributes(path)
    if not attrs then return end
    -- The service starts a fresh file now and then; read that from the top.
    if attrs.ino ~= handOff.inode or attrs.size < handOff.position then
        handOff.inode = attrs.ino
        handOff.position = 0
    end
    if attrs.size == handOff.position then return end
    local file = io.open(path, "rb")
    if not file then return end
    file:seek("set", handOff.position)
    local data = file:read("a") or ""
    file:close()
    -- Only whole lines; a partly written one is picked up next time.
    local consumed = 0
    for line in data:gmatch("([^\n]*)\n") do
        consumed = consumed + #line + 1
        local fields = hs.fnutils.split(line, "\t", nil, true)
        local tagText, name = fields[1], fields[2] or ""
        if tagText and tagText ~= "" then
            local tags = hs.fnutils.split(tagText, "%.")
            if name ~= "" then table.insert(tags, name) end
            Triggrd:handleEvent({
                tags = tags,
                data = {textArgs = {name, tagText}}
            })
        end
    end
    handOff.position = handOff.position + consumed
end

-- Starts (or restarts) following the service's events. Events already in the
-- file are skipped: they happened before Triggrd was listening.
-- state is only for testing; it defaults to the service's state folder.
function Triggrd:startSystemHandOff(state)
    if handOff.watcher then handOff.watcher:stop() end
    handOff = {folder = state or stateFolder}
    if not state and not Triggrd:systemSoundsInstalled() then return end
    local attrs = hs.fs.attributes(handOff.folder .. "/events")
    handOff.inode = attrs and attrs.ino
    handOff.position = attrs and attrs.size or 0
    handOff.watcher = hs.pathwatcher.new(handOff.folder, function(paths)
        for _, changed in ipairs(paths) do
            if changed:match("/events$") then readHandedOffEvents() return end
        end
    end):start()
end

function Triggrd:stopSystemHandOff()
    if handOff.watcher then handOff.watcher:stop() end
    handOff = {}
end

-- True when the system service is installed and will play a sound for an
-- event with these tags, using the same matching as the service (a file plays
-- when all of its tags are among the event's). Triggrd uses this to stay quiet
-- where the service covers the same moment, so nothing plays twice.
-- folder is only for testing; it defaults to the system sounds folder.
function Triggrd:systemSoundsCover(tags, folder)
    if not folder and not Triggrd:systemSoundsInstalled() then return false end
    local function covered(dir)
        local ok, iter, state = pcall(hs.fs.dir, dir)
        if not ok or not iter then return false end
        for file in iter, state do
            if file:sub(1, 1) ~= "." then
                local full = dir .. "/" .. file
                if hs.fs.attributes(full, "mode") == "directory" then
                    if covered(full) then return true end
                else
                    local name, ext = file:match("^(.*)%.([%w]+)$")
                    if name and Triggrd.automationHandlers[ext] and ext ~= "lua" and ext ~= "txt" then
                        local all = true
                        for _, tag in ipairs(hs.fnutils.split(name, "%.")) do
                            if not hs.fnutils.contains(tags, tag) then all = false break end
                        end
                        if all then return true end
                    end
                end
            end
        end
        return false
    end
    return covered(folder or soundsFolder)
end

-- True the first time Triggrd starts after a login for which the system
-- service played login sounds (it touches loginMarker at login when the system
-- theme has any login.* sound). That start is Hammerspoon launching as part of
-- the login, which the login sounds have already announced, so Triggrd.started
-- is skipped. Later starts (config reloads, restarting Hammerspoon) still play.
function Triggrd:startedDuringSystemLogin()
    if not Triggrd:systemSoundsInstalled() then return false end
    local loginTime = hs.fs.attributes(loginMarker, "modification")
    if not loginTime or os.time() - loginTime > 300 then return false end
    if hs.settings.get("Triggrd.systemLoginSeen") == loginTime then return false end
    hs.settings.set("Triggrd.systemLoginSeen", loginTime)
    return true
end

local function alert(message, info, button1, button2)
    hs.focus()
    if button2 then
        return hs.dialog.blockAlert(message, info or "", button1, button2, "informational")
    end
    -- An empty second button title would still add a (blank) button.
    return hs.dialog.blockAlert(message, info or "", button1 or "OK")
end

-- Runs a script from the system folder as root, via the standard
-- administrator password prompt. callback(ok, cancelled, errorText).
local function runAsAdmin(script, args, prompt, callback)
    local command = Triggrd.shellQuote(systemFolder .. "/" .. script)
    for _, arg in ipairs(args) do command = command .. " " .. Triggrd.shellQuote(arg) end
    local applescript = "do shell script " .. string.format("%q", command) ..
        " with prompt " .. string.format("%q", prompt) .. " with administrator privileges"
    Triggrd.adminTask = hs.task.new("/usr/bin/osascript", function(exitCode, _, stderr)
        Triggrd.adminTask = nil
        callback(exitCode == 0, (stderr or ""):find("%-128") ~= nil, stderr)
    end, {"-e", applescript})
    Triggrd.adminTask:start()
end

-- Sounds in the user's themes that the system service has an equivalent for.
-- copy: also keep the original (Triggrd.started still plays on config reloads).
local function findExistingSounds()
    local found = {}
    local root = hs.fs.pathToAbsolute(Triggrd.userAutomationsPath)
    -- folder: the theme folder path relative to the automations folder, with a
    -- trailing slash (or ""), recreated under the system sounds folder.
    local function scan(dir, folder)
        for file in hs.fs.dir(dir) do
            if file:sub(1, 1) ~= "." then
                local full = dir .. "/" .. file
                if hs.fs.attributes(full, "mode") == "directory" then
                    scan(full, folder .. file .. "/")
                else
                    local name, ext = file:match("^(.*)%.([%w]+)$")
                    local isSound = name and Triggrd.automationHandlers[ext] and ext ~= "lua" and ext ~= "txt"
                    if isSound then
                        if name == "Triggrd.started" then
                            table.insert(found, {from = full, to = folder .. "login.desktopReady." .. ext,
                                                 name = file, copy = true})
                        else
                            local kind = name:match("^caff%.systemWillPowerOff(.*)$")
                            if kind == "" or kind == ".logout" or kind == ".restart" or kind == ".shutdown" then
                                table.insert(found, {from = full, to = folder .. "powerOff.noReturn" .. kind .. "." .. ext,
                                                     name = file})
                            end
                        end
                    end
                end
            end
        end
    end
    if root then scan(root, "") end
    return found
end

local function copyFile(from, to)
    local input = io.open(from, "rb")
    if not input then return false end
    local output = io.open(to, "wb")
    if not output then input:close() return false end
    output:write(input:read("a"))
    input:close()
    output:close()
    return true
end

-- Exposed for diagnostics.
Triggrd._findExistingSounds = findExistingSounds

function Triggrd:installSystemSounds()
    local reinstall = Triggrd:systemSoundsInstalled()
    local answer = alert(reinstall and "Reinstall the Triggrd System Service?" or "Install the Triggrd System Service?",
        "The Triggrd System Service is a small background service that runs from startup to shutdown. " ..
        "Installing it makes these sounds possible:\n\n" ..
        "Startup, login and logout:\n" ..
        "- The Mac starting up, login starting, the desktop ready and login items launching.\n" ..
        "- The log out, restart or shut down dialog appearing, being cancelled, and the point of no return.\n" ..
        "These play from " .. soundsFolder .. ", because they happen while Hammerspoon isn't running. " ..
        "Name them like Triggrd's, for example system.started.wav or powerOff.requested.shutdown.wav.\n\n" ..
        "Devices and connections, played from your usual Triggrd theme:\n" ..
        "- Thunderbolt devices announced the moment they connect, instead of checked every 2 seconds.\n" ..
        "- Wi-Fi, Ethernet and internet connecting and disconnecting.\n" ..
        "- Bluetooth headphones, speakers, keyboards and mice connecting and disconnecting.\n" ..
        "- Headphones plugged into the headphone jack, and the sound output switching device.\n" ..
        "- The microphone or camera starting and stopping, like the orange and green dots on screen.\n" ..
        "- The lid closing, opening, and the Mac being ready to use after opening it.\n" ..
        "- The Mac slowing down because it's too hot, and cooling off again.\n" ..
        "- Low Power Mode turning on and off.\n" ..
        "Every wired connection also plays hardware.connected and hardware.disconnected, and every wireless one " ..
        "wireless.connected and wireless.disconnected, so one pair of sounds can cover them all.\n\n" ..
        "You'll be asked for an administrator password.",
        reinstall and "Reinstall" or "Install", "Cancel")
    if answer ~= "Install" and answer ~= "Reinstall" then return end

    local existing = findExistingSounds()
    local toCopy = {}
    if #existing > 0 then
        local lines = {}
        local keepsStarted = false
        for _, sound in ipairs(existing) do
            table.insert(lines, sound.name .. " becomes " .. sound.to)
            if sound.copy then keepsStarted = true end
        end
        local answer2 = alert("Let the System Service play some of your sounds?",
            "These sounds from your Triggrd themes have a system equivalent, which can also play " ..
            "when Hammerspoon isn't running, for example all the way through logging out:\n\n" ..
            table.concat(lines, "\n") .. "\n\n" ..
            "They'll be moved to " .. soundsFolder .. "." ..
            (keepsStarted and " Triggrd.started is copied rather than moved, so it still plays when you reload your config." or ""),
            "Move Them", "Leave Them")
        if answer2 == "Move Them" then toCopy = existing end
    end

    -- Stage the files as ourselves: the root install script can't read
    -- ~/Documents (privacy protection applies to root too).
    local args = {systemFolder}
    local staging
    if #toCopy > 0 then
        staging = os.tmpname() .. "-triggrd"
        hs.fs.mkdir(staging)
        local manifest = {}
        for i, sound in ipairs(toCopy) do
            local staged = staging .. "/" .. i
            if copyFile(sound.from, staged) then
                table.insert(manifest, staged .. "\t" .. sound.to)
            end
        end
        local f = io.open(staging .. "/manifest", "w")
        f:write(table.concat(manifest, "\n") .. "\n")
        f:close()
        table.insert(args, staging .. "/manifest")
    end

    runAsAdmin("install.sh", args, "Triggrd wants to install its System Service.", function(ok, cancelled, err)
        if staging then os.execute("rm -rf " .. Triggrd.shellQuote(staging)) end
        if not ok then
            if not cancelled then
                alert("The Triggrd System Service couldn't be installed.", err or "")
            end
            return
        end
        for _, sound in ipairs(toCopy) do
            if not sound.copy then os.remove(sound.from) end
        end
        Triggrd:startSystemHandOff()
        -- The service lists what it watches as it starts, a moment from now.
        Triggrd.handOffSetupTimer = hs.timer.doAfter(3, function() Triggrd:updateThunderboltPolling() end)
        if #toCopy > 0 then Triggrd:reloadAutomations() end
        local done = alert("The Triggrd System Service is installed.",
            "Startup, login and logout sounds go in " .. soundsFolder .. "; device and connection sounds go in your usual Triggrd theme. " ..
            "Add them whenever you like; no reload is needed. " ..
            "You can remove the service again from the Triggrd menu.",
            "Open Folder", "OK")
        if done == "Open Folder" then hs.open(soundsFolder) end
    end)
end

function Triggrd:uninstallSystemSounds()
    local answer = alert("Uninstall the Triggrd System Service?",
        "The System Service will be removed, along with every sound it makes possible: startup, login and logout; " ..
        "network, Bluetooth, headphones, microphone and camera, lid, heat and Low Power Mode. Thunderbolt devices go back to " ..
        "being checked every 2 seconds. Your sounds in " .. soundsFolder .. " are left where they are, " ..
        "so reinstalling picks them up again.\n\nYou'll be asked for an administrator password.",
        "Uninstall", "Cancel")
    if answer ~= "Uninstall" then return end
    runAsAdmin("uninstall.sh", {}, "Triggrd wants to remove its System Service.", function(ok, cancelled, err)
        if ok then
            Triggrd:stopSystemHandOff()
            Triggrd:updateThunderboltPolling()
            alert("The Triggrd System Service is uninstalled.")
        elseif not cancelled then
            alert("The Triggrd System Service couldn't be uninstalled.", err or "")
        end
    end)
end

function Triggrd:systemSoundsMenuItems()
    if Triggrd:systemSoundsInstalled() then
        return {
            {title = "Open System Sounds Folder", fn = function() hs.open(soundsFolder) end},
            {title = "Reinstall System Service...", fn = function() Triggrd:installSystemSounds() end},
            {title = "Uninstall System Service...", fn = function() Triggrd:uninstallSystemSounds() end},
        }
    end
    return {
        {title = "Install System Service...", fn = function() Triggrd:installSystemSounds() end},
    }
end
