#!/bin/sh
# Installs (or reinstalls) Triggrd's system sound service. Must run as root;
# Triggrd runs it through an administrator password prompt.
#   install.sh <this folder> [<manifest>]
# The optional manifest lists sounds to copy into the system sounds folder, one
# per line: <source path><TAB><path relative to /Library/Sounds/Triggrd>.
set -e
SRC="$1"
MANIFEST="$2"
LABEL=com.triggrd.system
APP="/Library/Application Support/Triggrd"
SOUNDS="/Library/Sounds/Triggrd"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

launchctl bootout "system/$LABEL" 2>/dev/null || true
# Earlier versions kept a log of every event here.
rm -f /Library/Logs/Triggrd-system.log

mkdir -p "$APP" "$SOUNDS"
install -m 755 -o root -g wheel "$SRC/triggrd-system" "$APP/triggrd-system"

if [ -n "$MANIFEST" ]; then
    tab=$(printf '\t')
    while IFS="$tab" read -r from to; do
        [ -n "$from" ] || continue
        mkdir -p "$(dirname "$SOUNDS/$to")"
        cp "$from" "$SOUNDS/$to"
    done < "$MANIFEST"
fi

# Administrators can add and change sounds without a password.
chown -R root:admin "$SOUNDS"
chmod -R u+rwX,g+rwX,o+rX "$SOUNDS"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP/triggrd-system</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
PLIST
chown root:wheel "$PLIST"
chmod 644 "$PLIST"
launchctl bootstrap system "$PLIST"
