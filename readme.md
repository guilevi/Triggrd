# Triggrd

React to various system events by creating files with specific names.

## Setup

1. Triggrd is a spoon (plugin) for [Hammerspoon](https://hammerspoon.org). You will need to download and install it first. If you already have and use Hammerspoon, ignore the next step.
1. Make sure you have a `.hammerspoon`directory in your home folder, and an `init.lua` file in it.
1. Open `Triggrd.spoon` or copy it to `~/.hammerspoon/spoons/`
1. Somewhere within your `init.lua` file, add the following lines:
```lua
hs.loadSpoon("Triggrd")
spoon.Triggrd:start()
````
1. There is a set of example event automations in the *My Example Triggrd Automations* directory in this repository. Copy or symlink it into your documents folder if you wish, making sure to remove the word "Example".

## Basic concepts

* All of your automations will be in a path of your choosing. By default, this is `~/documents/My Triggrd Automations`. You can change this by modifying the `userAutomationsPath` variable in the spoon's `init.lua`.
* Any file or folder in the automations directory whose name *beginns with a dot (.)* will be ignored by Triggrd.
* Every event is composed of several *tags*. To react to an event, you can create a file in the automations directory or any of its subdirectories with a name composed of tags separated by dots (.). The list of supported extensions is down below. For example, `app.launched.wav`, `battery.20percent.down.lua`, or `power.txt`.
* An automation will only trigger if the event contains *all* of its tags. `volume.wav` will play every time any event happens with any volume, `app.launched.Safari` will trigger when Safari is launched, `battery.40percent.txt` will be spoken when the battery reaches 40% either charging or discharging.

## Supported file types

* Audio files: Any file format supported by `hs.sound`.
* Lua scripts: They will receive an event data table as a vararg which will contain, at the very least, a reference to the `Triggrd` object.
* TXT files: They will be spoken by the default system voice. Some of them may let you use formatstrings to add relevant data into the spoken text.

## Supported events

### Application events (app)

All of these events will include a tag with the name of the app in question.

TXT files may also reference two formatstring arguments, the name of the app and the event type.

* `activated` (gets focus)
* `deactivated` (loses focus)
* `hidden`
* `unhidden`
* `launching`
* `launched`
* `terminated` (quit)

### Screen and system power states (caff)

TXT files may also reference a single formatstring argument, the event type.

* `screensaverDidStart`
* `screensaverWillStop`
* `screensaverDidStop`
* `screensDidLock`
* `screensDidUnlock`
* `screensDidWake`
* `screensDidSleep`
* `sessionDidBecomeActive`
* `sessionDidResignActive`
* `systemWillSleep`
* `systemDidWake`
* `systemWillPowerOff`

### USB Events (usb)

All of these events will include a tag with the name of the USB device in question.

TXT files may also reference two formatstring arguments, the name of the device and the event type.

* `added` (connected)
* `removed` (disconnected)

### Space Change Event (spacechange)

The second tag may be the word space followed by the number of the new space. This number will also be passed as a formatstring argument to txt files.

### Pasteboard Change Event (pasteboard)

The second tag may be the contents of the pasteboard. These will also be passed as a formatstring to txt files.

### Battery Events (battery)

* xpercent, where x is a battery percentage
* up, when the change in percentage is upwards
* down, for the opposite
* charging, for when the battery starts charging. Will not include percentage tags
* notCharging, for the opposite

### Power source change events (power)

* `onAC`
* `onBattery`
* `offLine`

### Screen Change Event (screenchanged)

This event seems to fire whenever a change occurs in the screen configuration or layout.

### Volume Events (volume)

* `didMount`
* `willUnmount`
* `didUnmount`
* `didRename`

## Plans

The "roadmap" is "detailed" [here](tasks.md). Any suggestions and/or pull requests are welcome.

## Acknowledgments

* @GRMrGecko for creating [SoundNote](https://github.com/GRMrGecko/SoundNote), which became an invaluable tool for me and many other blind mac users and inspired Triggrd.
* @Mikholysz for writing the first few lines of code, and finally getting me to work on this.
* My good friends of [Currently Untitled Audio](https://currentlyuntitledaudio.design) for the example set, which we will be expanding as new events come in.
