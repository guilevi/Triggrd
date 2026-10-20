# Triggrd system sounds

`triggrd-system` is a small system service (LaunchDaemon) that plays Triggrd
sounds for events outside the logged-in session: the Mac starting up, logging
in, and logging out, restarting or shutting down. Install and remove it from
the Triggrd menu ("Install System Service..."). Its sounds live in
`/Library/Sounds/Triggrd`, named with Triggrd's usual dot-separated tags; the
events are listed at the top of `triggrd-system.swift`.

It also watches devices and connections that Hammerspoon can't watch itself,
or could only poll for: Thunderbolt devices, Wi-Fi, Ethernet and internet,
Bluetooth audio and input devices, the headphone jack and output switching, the
microphone and camera being in use, the lid, heat and Low Power Mode (the full
list is at the top of `triggrd-system.swift`). Those it hands to Triggrd, by
writing them to `/Library/Application Support/Triggrd/events`, which Triggrd
watches and plays from the user's own theme; so quitting Hammerspoon silences
them like every other Triggrd sound. Run `triggrd-system --snapshot` to see
what it currently detects, or `triggrd-system --emit lid.ready` to hand Triggrd
an event.

## Files

- `triggrd-system.swift`: the service's source.
- `triggrd-system`: the build the installer uses. As shipped here it's signed
  with a Developer ID and notarized by Apple.
- `unsigned/triggrd-system`: the same build, ad-hoc signed only, for anyone who
  wants to sign it with their own certificate.
- `build.sh`: rebuilds both (universal: Apple silicon and Intel). See its
  header for signing and notarizing with your own Developer ID.
- `install.sh`, `uninstall.sh`: run as root by Triggrd through the standard
  administrator password prompt.

## About signing

An unsigned (ad-hoc) build works when you build it yourself. When the spoon is
downloaded, though, macOS marks its files as quarantined and may refuse to run
an unnotarized service, and the "Background item added" notice won't name a
developer. If you ship an unsigned build, tell users macOS may warn that it
can't verify the service is free of malware.

Also, the administrator prompt names the app that asked for it: from the
Triggrd menu that's Hammerspoon, which is notarized. Running `install.sh`
from a terminal whose shell isn't notarized (e.g. Homebrew's bash) makes
macOS warn that it couldn't verify that shell, which has nothing to do with
the service itself.
