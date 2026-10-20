local Triggrd = {
    name = "Triggrd",
    version = "2.0.1",
    author = "Guillem León <guilevi2000@gmail.com>; Mikolaj Holysz <miki123211@gmail.com>",
    license = "The Unlicense, <https://unlicense.org>",
    homepage = "https://github.com/guilevi/Triggrd",

    automationHandlers = {
        lua = function(path)
            return function(eventData)
                loadfile(path)(eventData)
            end
        end,
        txt = function(path)
            return function(eventData)
                local file = io.open(path)
                local text = file:read("a")
                eventData.Triggrd.tts:speak(string.format(text,
                    (eventData.textArgs and table.unpack(eventData.textArgs)) or nil))
            end
        end
    }
}

local logger = hs.logger.new("Triggrd")
logger.setLogLevel("info")

local userAutomationsPath = "~/Documents/My Triggrd Automations"
Triggrd.userAutomationsPath = userAutomationsPath

local registeredAutomations = {}

local function shellQuote(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end
Triggrd.shellQuote = shellQuote

-- Play a sound in a fully detached process that outlives Hammerspoon.
--
-- hs.sound plays inside Hammerspoon, so when the app is told to quit (which is
-- exactly what happens at shutdown, restart and logout) the sound is cut off
-- mid-play. Here perl forks, the parent exits at once (so os.execute returns
-- in a few ms and nothing is left for hs.task to clean up), and the child
-- starts its own session, ignores the polite termination signals
-- (TERM/HUP/INT -- ignored dispositions survive exec) and becomes afplay. It
-- can then only be stopped by SIGKILL, which launchd sends only once its exit
-- timeout has elapsed during shutdown, well after a short sound has finished.
function Triggrd.playDetached(path)
    os.execute("/usr/bin/perl -MPOSIX -e " .. shellQuote(
        'exit 0 if fork; POSIX::setsid(); $SIG{$_} = "IGNORE" for qw(TERM HUP INT); ' ..
        'open STDIN, "<", "/dev/null"; open STDOUT, ">", "/dev/null"; open STDERR, ">", "/dev/null"; ' ..
        'exec "/usr/bin/afplay", @ARGV') .. " " .. shellQuote(path))
end

local function audioHandler(path)
    local sound = hs.sound.getByFile(path)
    return function(eventData)
        if eventData and eventData.detached then
            Triggrd.playDetached(path)
            return
        end
        sound:currentTime(0)
        -- NSSound can get stuck believing it is still playing (position frozen
        -- at 0, e.g. after the output device changed mid-sound), and then
        -- refuses every play() and the sound is silent from then on. stop()
        -- clears that; for a sound that really is playing, this just restarts
        -- it, as before.
        if not sound:play() then
            sound:stop()
            sound:currentTime(0)
            sound:play()
        end
    end
end

-- add audio handlers
for _, type in pairs(hs.sound.soundFileTypes()) do
    Triggrd.automationHandlers[type] = audioHandler
end
-- Core Audio Format isn't in soundFileTypes(), but NSSound (and afplay) play it
-- fine, and it's what many macOS system sounds ship as.
Triggrd.automationHandlers.caf = audioHandler
Triggrd.automationHandlers.CAF = audioHandler

function Triggrd:start()
    -- Create the user automations directory (if it doesn't exist)
    local exists = hs.fs.attributes(userAutomationsPath)
    if not exists then
        -- logger.i("Directory '" .. userAutomationsPath .. "' doesn't exist, creating...")
        hs.fs.mkdir(userAutomationsPath)
    end

    Triggrd:registerAutomations(userAutomationsPath)
    Triggrd.tts = hs.speech.new()
    Triggrd.generateAppListItem = loadfile(hs.spoons.resourcePath('axobserver.lua'))
    Triggrd.runningApps = {}

    for _,app in ipairs(hs.application.runningApplications()) do
        table.insert(Triggrd.runningApps, Triggrd.generateAppListItem(Triggrd, app))
    end
    loadfile(hs.spoons.resourcePath("systemsounds.lua"))(Triggrd)
    Triggrd:startSystemHandOff()
    Triggrd:createMenubar()
    loadfile(hs.spoons.resourcePath("events.lua"))(Triggrd)
    Triggrd:setupHotkeys()
    -- logger.i("Triggrd is ready")
    -- When the system service has just played the login sounds, Hammerspoon
    -- launching as part of that login needs no sound of its own.
    if not Triggrd:startedDuringSystemLogin() then
        Triggrd:handleEvent({
            tags = {"Triggrd", "started"}
        })
    end

    -- Hammerspoon calls this as it quits or reloads its config. The sound is
    -- played detached so quitting doesn't cut it off. Skipped when the system
    -- is powering off, where caff.systemWillPowerOff has already played.
    hs.shutdownCallback = function()
        if Triggrd.poweringOff then return end
        Triggrd:handleEvent({
            tags = {"Triggrd", "stopped"},
            data = {detached = true}
        })
    end

end

function Triggrd:handleEvent(event)
    -- logger.i("Received event with tags " .. hs.inspect.inspect(event.tags))
    local automations = Triggrd:automationsForTags(event.tags)
    if #automations == 0 then
        -- logger.i("No automations for event " .. hs.inspect.inspect(event.tags))
        return
    end

    if event.data then
        event.data.Triggrd = Triggrd
    else
        event.data = {
            Triggrd = Triggrd
        }
    end
    for i = 1, #automations do
        automations[i].actor(event.data)
    end
end

function Triggrd:automationsForTags(tags)
    local autos = {}
    -- there is probably a better way to do this
    local addThis = true
    for _, automation in ipairs(registeredAutomations) do
        addThis = true
        for _, tag in ipairs(automation.tags) do
            if not hs.fnutils.contains(tags, tag) then
                addThis = false
                break
            end
        end
        if addThis then
            table.insert(autos, automation)
        end
    end
    return autos
end

function Triggrd:registerAutomations(path)
    for file in hs.fs.dir(path) do
        local fullPath = path .. "/" .. file
        fullPath = hs.fs.pathToAbsolute(fullPath)
        if hs.fs.attributes(fullPath, "mode") == "directory" and file:sub(1, 1) ~= "." then
            Triggrd:registerAutomations(fullPath)
        end
        -- The files we're interested in have alphanumeric extensions.
        local pattern = "(.*)%.([%w]+)$"
        local name, extension = string.match(file, pattern)
        if name and Triggrd.automationHandlers[extension] then
            local automation = {
                tags = hs.fnutils.split(name, "%."),
                actor = Triggrd.automationHandlers[extension](fullPath)
            }
            table.insert(registeredAutomations, automation)
            -- logger.i("Registered automation " .. fullPath)
        end
    end
end

function Triggrd:reloadAutomations()
    registeredAutomations = {}
    Triggrd:registerAutomations(userAutomationsPath)
end

function Triggrd:createMenubar()
    Triggrd.menu = hs.menubar.new(true)
    Triggrd.menu:setTitle("Triggrd")
    -- Built each time the menu opens, so the system sounds items reflect
    -- whether the service is currently installed.
    Triggrd.menu:setMenu(function()
        local menuContents = {{
            title = "Reload automations",
            fn = function()
                Triggrd:reloadAutomations()
                Triggrd:handleEvent({
                    tags = {"Triggrd", "reloaded"}
                })
            end
        }, {
            title = "Migrate SoundNote soundpack...",
            fn = function()
                loadfile(hs.spoons.resourcePath("snmigrate.lua"))(userAutomationsPath)
            end
        }, {
            title = "-"
        }}
        for _, item in ipairs(Triggrd:systemSoundsMenuItems()) do
            table.insert(menuContents, item)
        end
        return menuContents
    end)
end

function Triggrd:setupHotkeys()
    for eventName, _ in pairs(registeredAutomations) do
        -- The pat	tern is "hotkey.", followed by a dash-separated list of modifiers,
        -- followed by a key.
        local pattern = "^hotkey.([%w-]*)-(%w*)$"
        local modifiers, key = string.match(eventName, pattern)
        if modifiers then
            hs.hotkey.bind(modifiers, key, function()
                Triggrd.emit(eventName)
            end)
        end
    end
end

return Triggrd
