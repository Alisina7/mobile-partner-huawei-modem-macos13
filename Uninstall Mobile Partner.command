#!/bin/bash
# Removes the native Mobile Partner app, helper and PPP service.
# The Huawei driver is left installed unless you pass --driver.

set -u

echo "Mobile Partner uninstaller"
echo "=========================="
echo ""
echo "This removes:"
echo "  /Applications/Mobile Partner.app"
echo "  /usr/local/mobilepartner"
echo "  /Library/LaunchDaemons/com.mobilepartner.helper.plist"
echo "  /Library/Modem Scripts/HUAWEI Mobile Connect - 3G Modem"
echo "  the 'Mobile Partner' network service"
echo ""
echo "The Huawei kernel driver is kept unless you pass --driver."
echo ""

read -r -p "Continue? [y/N] " answer
case "$answer" in
    [yY]*) ;;
    *) echo "Cancelled."; exit 0 ;;
esac

sudo -v || exit 1

echo "Stopping helper..."
sudo launchctl bootout system/com.mobilepartner.helper 2>/dev/null || true
sudo pkill -x "Mobile Partner" 2>/dev/null || true
sleep 1

echo "Removing files..."
sudo rm -rf "/Applications/Mobile Partner.app"
sudo rm -rf /usr/local/mobilepartner
sudo rm -f /Library/LaunchDaemons/com.mobilepartner.helper.plist
sudo rm -f "/Library/Modem Scripts/HUAWEI Mobile Connect - 3G Modem"
sudo rm -f /var/run/mobilepartner.sock
sudo rm -f /var/log/mobilepartner.log /var/log/mobilepartner-install.log

echo "Removing the network service..."
sudo networksetup -removenetworkservice "Mobile Partner" 2>/dev/null || true

if [ "${1:-}" = "--driver" ]; then
    echo "Removing the Huawei kernel driver..."
    sudo rm -rf "/Library/Extensions/HuaweiDataCardDriver_10_9.kext"
    echo "The driver remains in the kernel collection until the next reboot."
fi

echo ""
echo "Done. Log out or reboot to finish cleaning up."
read -n 1 -s -r -p "Press any key to close this window."
echo ""
