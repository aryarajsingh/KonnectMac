#!/bin/bash
# KonnectMac Uninstaller
echo "Uninstalling KonnectMac..."

# Kill the app
killall KonnectMac 2>/dev/null

# Remove the app
rm -rf /Applications/KonnectMac.app

# Remove app data
rm -rf ~/Library/Application\ Support/KonnectMac
rm -rf ~/Library/Caches/KonnectMac

# Remove preferences
defaults delete com.konnectmac.app 2>/dev/null

# Unregister from LaunchServices
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u /Applications/KonnectMac.app 2>/dev/null

# Reset notification registration
killall usernoted 2>/dev/null

# Remove log
rm -f /tmp/konnectmac.log

echo "KonnectMac has been uninstalled."
echo "Note: Notification and Login Item entries in System Settings may take a restart to disappear."
