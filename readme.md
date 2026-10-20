# Triggrd

React to various system events by creating files with specific names.

## What's new in 2.0

* **Authentication sounds.** Password and Touch ID prompts are detected reliably, whether they're a sheet in System Settings, a standalone "wants to make changes" dialog, or an app asking for Touch ID, with separate events for success and cancelling.
* **Logout, restart and shutdown.** `systemWillPowerOff` now fires the moment you confirm, before apps start quitting, says which of the three it is, and plays its sound in a separate process so Hammerspoon quitting can't cut it off. There are new events for an app stopping it (`powerOffFailed`) and for Triggrd itself stopping (`Triggrd.stopped`).
* **The Triggrd System Service** (optional): a small background service, installed from the Triggrd menu, that adds sounds Hammerspoon can't make on its own, from the Mac starting up through to shutting down; see [The System Service](#the-system-service).
* **Thunderbolt and USB4 devices**, displays, and a fully-charged battery event.
* **Umbrella tags**: every wired connection also has `hardware.connected` / `hardware.disconnected`, and every wireless one `wireless.connected` / `wireless.disconnected`, so a pair of sounds can cover them all.
* **Fixes**: battery events never fired (the watcher was never started), battery level tags never matched (`100.0percent`), and reading battery information crashed Hammerspoon on macOS 26 and later.
* `.caf` sound files are supported.

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

### Migrating from SoundNote

Triggrd includes a utility to migrate SoundNote soundpacks to the Triggrd format. To access it, click on the Triggrd menu on the menu bar and select "Migrate SoundNote soundpack..."

Note for blind users: The Triggrd menu in menu extras is spoken as "Hammerspoon: Triggrd". There seems to be nothing I can do about that for now.

## Basic concepts

* All of your automations will be in a path of your choosing. By default, this is `~/documents/My Triggrd Automations`. You can change this by modifying the `userAutomationsPath` variable in the spoon's `init.lua`.
* Any file or folder in the automations directory whose name *beginns with a dot (.)* will be ignored by Triggrd.
* Every event is composed of several *tags*. To react to an event, you can create a file in the automations directory or any of its subdirectories with a name composed of tags separated by dots (.). The list of supported extensions is down below. For example, `app.launched.wav`, `battery.20percent.down.lua`, or `power.txt`.
* An automation will only trigger if the event contains *all* of its tags. `volume.wav` will play every time any event happens with any volume, `app.launched.Safari` will trigger when Safari is launched, `battery.40percent.txt` will be spoken when the battery reaches 40% either charging or discharging.

## Supported file types

* Audio files: Any file format supported by `hs.sound`, plus `.caf`.
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
* `systemWillPowerOff`, followed by `logout`, `restart` or `shutdown`. Fires as soon as you confirm, before apps are asked to quit, and its sounds play in a separate process, so Hammerspoon quitting doesn't cut them off. If the System Service has a `powerOff.noReturn` sound for the same moment, this one stays quiet.

### Logout, restart or shutdown stopped (powerOffFailed)

The second tag is `logout`, `restart` or `shutdown`, the third:

* `interrupted`: an app refused to quit.
* `cancelled`: it was cancelled after it had started (not from the confirmation dialog, which hasn't started anything yet).

### Triggrd itself (Triggrd)

* `started`: Triggrd loaded. Skipped once at login if the System Service has just played login sounds.
* `stopped`: Hammerspoon quitting or reloading its configuration. Not played during logout, restart or shutdown.
* `reloaded`: automations reloaded from the menu.

### Authentication

The last tag is the kind of prompt: `sheet` (a password or Touch ID sheet inside an app, such as System Settings), `dialog` (a standalone administrator dialog, such as "wants to make changes" or an installer) or `touchid` (an app asking for Touch ID, followed by the app's name, e.g. `authenticated.touchid.1Password.wav`).

* `authentication.required`: a prompt appeared.
* `authenticated`: it succeeded.
* `authenticationFailed.cancelled`: it was cancelled.
* `authenticationFailed.failed`: it failed some other way.

These are read from the system log, which needs no extra permissions.

### Devices (device)

The second tag is where the device is connected: `usb` or `thunderbolt` (Thunderbolt and USB4 devices plugged straight into the Mac, such as an SSD or a dock, which the USB watcher can't see). All of these events include a tag with the name of the device, and the umbrella tags `hardware.connected` or `hardware.disconnected`. The old `usb.added` and `usb.removed` names still work.

TXT files may also reference two formatstring arguments, the name of the device and connected or disconnected.

* `added` (connected)
* `removed` (disconnected)

Without the System Service, Thunderbolt devices are found by checking every 2 seconds; with it, they're announced the moment they come and go.

### Displays (display)

* `connected` and `disconnected`, with the display's name and the `hardware` umbrella tag.

### Space Change Event (spacechange)

The second tag may be the word space followed by the number of the new space. This number will also be passed as a formatstring argument to txt files.

### Pasteboard Change Event (pasteboard)

The second tag may be the contents of the pasteboard. These will also be passed as a formatstring to txt files.

### Battery Events (battery)

* xpercent, where x is a battery percentage
* up, when the change in percentage is upwards
* down, for the opposite
* charging, for when the battery starts charging. Will not include percentage tags
* notCharging, for when it stops charging: unplugged, or paused at a charge limit
* full, for when it stops charging because it's full

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

## The System Service

Hammerspoon only runs while you're logged in, and some things it can't watch at all (on macOS 26 and later, touching Bluetooth from Hammerspoon crashes it). The Triggrd System Service is a small background service that covers both. Install it, and later reinstall or uninstall it, from the Triggrd menu ("Install System Service..."); you'll be asked for an administrator password. When it's installed, the menu also has "Open System Sounds Folder".

### Startup, login and logout

These happen while Hammerspoon isn't running, so the service plays them itself, from `/Library/Sounds/Triggrd` (and any theme folders inside it), named in the usual way. Administrators can add sounds there without a password. They play whether or not Hammerspoon is running.

* `system.started`: the Mac has started up.
* `login.started`, `login.desktopReady`, `login.itemsLaunched`: the stages of logging in. `login.started` is skipped if it comes within 5 seconds of a `system.started` sound: on a Mac with FileVault, you're logged in straight after unlocking it at startup, so the two would overlap.
* `powerOff.requested`: the logout, restart or shutdown confirmation dialog appeared.
* `powerOff.likely`: macOS expects the session to end (at the same moment).
* `powerOff.cancelled`: it was cancelled.
* `powerOff.noReturn`: the point of no return; the last moment a sound can be heard.

Each `powerOff` event is followed by `logout`, `restart` or `shutdown`. Choosing Restart or Shut Down at the login window, with nobody logged in, makes no sound.

When installing, Triggrd offers to move sounds you already have for these moments: `Triggrd.started` is copied as `login.desktopReady`, and `caff.systemWillPowerOff` sounds are moved to `powerOff.noReturn`.

### Devices and connections

The service also watches these, without polling, and hands them to Triggrd, which plays them from your usual automations folder. So quitting Hammerspoon silences them like every other Triggrd sound. The names of devices are included as tags.

* `device.thunderbolt.added` / `removed`: as above, but instantly.
* `network.wifi.connected` / `disconnected` (with the `wireless` umbrella), `network.ethernet.connected` / `disconnected` (with `hardware`), and `network.internet.connected` / `disconnected`. Drops shorter than 2 seconds are ignored.
* `bluetooth.connected` / `disconnected`, followed by `audio` (headphones and speakers) or `input` (keyboards, mice, trackpads and game controllers), with the `wireless` umbrella. Other Bluetooth devices, such as phones and watches, aren't detected.
* `audio.headphones.connected` / `disconnected`: the headphone jack (with `hardware`).
* `audio.outputChanged`: the sound output switched device.
* `microphone.started` / `stopped` and `camera.started` / `stopped`: something began or stopped using a microphone or camera; the sound equivalent of the orange and green dots on screen.
* `lid.closed`, `lid.opened` and `lid.ready`, which is when the Mac has finished waking after the lid is opened. A sound when the lid closes may be cut off if you're listening through Bluetooth headphones, as macOS drops them straight away.
* `thermal.throttling.serious` / `critical`: macOS is slowing the Mac down because it's too hot; `thermal.cooled` when it recovers.
* `lowPowerMode.on` / `off`.

Connection sounds stay quiet while the Mac sleeps, and for 30 seconds after it wakes or starts up, when everything reconnects at once.

### Building and signing

The service's source and scripts are in `Triggrd.spoon/system`; see the [README there](Triggrd.spoon/system/README.md). The bundled build is signed and notarized, and an unsigned build is included for anyone who'd rather sign it themselves.

## Plans

The "roadmap" is "detailed" [here](tasks.md). Any suggestions and/or pull requests are welcome.

## Acknowledgments

* @GRMrGecko for creating [SoundNote](https://github.com/GRMrGecko/SoundNote), which became an invaluable tool for me and many other blind mac users and inspired Triggrd.
* @Mikholysz for writing the first few lines of code, and finally getting me to work on this.
* My good friends of [Currently Untitled Audio](https://currentlyuntitledaudio.design) for the example set, which we will be expanding as new events come in.
* Version 2.0 (authentication, logout and shutdown, the System Service, Thunderbolt, network, Bluetooth and the rest) by [Tobias Heath](https://github.com/heath-toby).
