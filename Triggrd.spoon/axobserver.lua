local Triggrd, app = ...
if app:kind() == -1 then
    return {app, nil, nil}
end
local element = hs.axuielement.applicationElement(app)
local observer = hs.axuielement.observer.new(app:pid())
pcall(function()
    observer:addWatcher(element, hs.axuielement.observer.notifications.menuOpened)
    observer:addWatcher(element, hs.axuielement.observer.notifications.menuClosed)
    observer:addWatcher(element, hs.axuielement.observer.notifications.menuItemSelected)
    observer:addWatcher(element, hs.axuielement.observer.notifications.focusedWindowChanged)
    observer:addWatcher(element, hs.axuielement.observer.notifications.windowMiniaturized)
    observer:addWatcher(element, hs.axuielement.observer.notifications.windowDeminiaturized)
    observer:addWatcher(element, hs.axuielement.observer.notifications.sheetCreated)
end)
observer:callback(function(observer, element, type, notificationInfo)
    local tags = {}
    local data = {}
    if type == hs.axuielement.observer.notifications.menuOpened then
        tags = {'menu', 'opened'}
    elseif type == hs.axuielement.observer.notifications.menuClosed then
        tags = {'menu', 'closed'}
    elseif type == hs.axuielement.observer.notifications.menuItemSelected then
        tags = {'menu', 'itemSelected', element:attributeValue(hs.axuielement.attributes.title)}
        data = {
            textArgs = {element:attributeValue(hs.axuielement.attributes.title)}
        }
    elseif type == hs.axuielement.observer.notifications.focusedWindowChanged then
        tags = {'window', 'focused', element:attributeValue(hs.axuielement.attributes.title)}
        data = {
            textArgs = {element:attributeValue(hs.axuielement.attributes.title)}
        }
    elseif type == hs.axuielement.observer.notifications.windowMiniaturized then
        tags = {'window', 'minimized', 'miniaturized', element:attributeValue(hs.axuielement.attributes.title)}
        data = {
            textArgs = {element:attributeValue(hs.axuielement.attributes.title)}
        }
    elseif type == hs.axuielement.observer.notifications.windowDeminiaturized then
        tags = {'window', 'deminimized', 'deminiaturized', element:attributeValue(hs.axuielement.attributes.title)}
        data = {
            textArgs = {element:attributeValue(hs.axuielement.attributes.title)}
        }
    elseif type == hs.axuielement.observer.notifications.sheetCreated then
        tags = {'sheetcreated'}
        -- This is absolutely horrible but I literally cannot think of another way of doing this
if element:attributeValue('AXChildren')[3] and element:attributeValue('AXChildren')[3]:attributeValue('AXValue'):find("is trying to") then
table.insert(tags, 'authentication')
end
    end
    Triggrd:handleEvent({
        tags = tags,
        data = data
    })

end)
observer:start()

return {app, element, observer}
