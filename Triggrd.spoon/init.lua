local Triggrd = {
    name = "Triggrd",
    version = "0.1",
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
    Triggrd.automationHandlers[type] = audioHandler
end

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
    Triggrd:createMenubar()
    loadfile(hs.spoons.resourcePath("events.lua"))(Triggrd)
    Triggrd:setupHotkeys()
    -- logger.i("Triggrd is ready")
    Triggrd:handleEvent({
        tags = {"Triggrd", "started"}
    })

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

function Triggrd:createMenubar()
    Triggrd.menu = hs.menubar.new(true)
    Triggrd.menu:setTitle("Triggrd")
    local menuContents = {{
        title = "Reload automations",
        fn = function()
            registeredAutomations = {}
            Triggrd:registerAutomations(userAutomationsPath)
            Triggrd:handleEvent({
                tags = {"Triggrd", "reloaded"}
            })
        end
    }, {
        title = "Migrate SoundNote soundpack...",
        fn = function()
            loadfile(hs.spoons.resourcePath("snmigrate.lua"))(userAutomationsPath)
        end
    }}
    Triggrd.menu:setMenu(menuContents)
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
