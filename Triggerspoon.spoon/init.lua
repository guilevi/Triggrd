local Triggerspoon = {
    name = "Triggerspoon",
    version = "0.1",
    author = "Guillem León <guilevi2000@gmail.com>; Mikolaj Holysz <miki123211@gmail.com>",
    license = "The Unlicense, <https://unlicense.org>",
    homepage = "https://github.com/guilevi/Triggerspoon",

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
                eventData.Triggerspoon.tts:speak(string.format(text, (eventData.textArgs and table.unpack(eventData.textArgs)) or nil))
            end
        end
    }
}

local logger = hs.logger.new("Triggerspoon")
logger.setLogLevel("info")

local userAutomationsPath = "~/Documents/My Triggerspoon Automations"

local registeredAutomations = {}

local function audioHandler(path, eventData)
    local sound = hs.sound.getByFile(path)
    return function()
        sound:currentTime(0)
        sound:play()
    end
end

-- add audio handlers
for _, type in pairs(hs.sound.soundFileTypes()) do
    Triggerspoon.automationHandlers[type] = audioHandler
end

function Triggerspoon:start()
    -- Create the user automations directory (if it doesn't exist)
    local exists = hs.fs.attributes(userAutomationsPath)
    if not exists then
        logger.i("Directory '" .. userAutomationsPath .. "' doesn't exist, creating...")
        hs.fs.mkdir(userAutomationsPath)
    end

    Triggerspoon:registerAutomations(userAutomationsPath)
    Triggerspoon.tts = hs.speech.new()

    loadfile(hs.spoons.resourcePath("events.lua"))(Triggerspoon)
    Triggerspoon:setupHotkeys()
    logger.i("Triggerspoon is ready")
    Triggerspoon:handleEvent({
        tags = {"Triggerspoon", "started"}
    })

end

function Triggerspoon:handleEvent(event)
    logger.i("Received event with tags " .. hs.inspect.inspect(event.tags))
    local automations = Triggerspoon:automationsForTags(event.tags)
    if #automations == 0 then
        logger.i("No automations for event " .. hs.inspect.inspect(event.tags))
        return
    end

    if event.data then
        event.data.Triggerspoon = Triggerspoon
    else
        event.data = {Triggerspoon=Triggerspoon}
    end
    for i = 1, #automations do
        automations[i].actor(event.data)
    end
end

function Triggerspoon:automationsForTags(tags)
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

function Triggerspoon:registerAutomations(path)
    for file in hs.fs.dir(path) do
        local fullPath = path .. "/" .. file
        fullPath = hs.fs.pathToAbsolute(fullPath)
        if hs.fs.attributes(fullPath, "mode") == "directory" and file:sub(1, 1) ~= "." then
            Triggerspoon:registerAutomations(fullPath)
        end
        -- The files we're interested in have alphanumeric extensions.
        local pattern = "(.*)%.([%w]+)$"
        local name, extension = string.match(file, pattern)
        if name and Triggerspoon.automationHandlers[extension] then
            local automation = {
                tags = hs.fnutils.split(name, "%."),
                actor = Triggerspoon.automationHandlers[extension](fullPath)
            }
            table.insert(registeredAutomations, automation)
            logger.i("Registered automation " .. fullPath)
        end
    end
end

function Triggerspoon:setupHotkeys()
    for eventName, _ in pairs(registeredAutomations) do
        -- The pat	tern is "hotkey.", followed by a dash-separated list of modifiers,
        -- followed by a key.
        local pattern = "^hotkey.([%w-]*)-(%w*)$"
        local modifiers, key = string.match(eventName, pattern)
        if modifiers then
            hs.hotkey.bind(modifiers, key, function()
                Triggerspoon.emit(eventName)
            end)
        end
    end
end

return Triggerspoon
