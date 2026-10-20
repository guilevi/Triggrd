#!/bin/sh
# Removes Triggrd's system sound service. Must run as root. Sounds in
# /Library/Sounds/Triggrd are left in place.
LABEL=com.triggrd.system
launchctl bootout "system/$LABEL" 2>/dev/null
rm -f "/Library/LaunchDaemons/$LABEL.plist"
rm -rf "/Library/Application Support/Triggrd"
rm -f /Library/Logs/Triggrd-system.log
exit 0
