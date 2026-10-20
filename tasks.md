# Triggerspoon Tasks

## Done

* Event framework with tags
* Recursively look at every file in the directory and subdirectories
* Handle Lua files
* Handle audio files
* Handle txt files for TTS with optional parameters for formatstring
* hs.application.watcher events
* Battery and power events
* Pasterboard watcher event
* USB events
* hs.caffeinate related events
* Space changed event
* Volume events
* Migrate SoundNote soundpacks
* Authentication prompts (sheets, dialogs and app Touch ID), with success and cancellation
* Logout, restart and shutdown, including when an app stops them
* Thunderbolt and USB4 devices
* Display events
* Audiodevice events (headphone jack, output switching, microphone in use)
* Network events (Wi-Fi, Ethernet, internet)
* Bluetooth (audio and input devices)
* Camera in use, lid, heat and Low Power Mode
* System Service: sounds at startup, login and logout

## To Do

* Handle osascript files
* Handle automator workflows
* Receive events from hs.urlevent (maybe think about hs.httpserver because urlevent opens the HS console)
* All axuielement events (oh boy, will definitely require timer)
