#!/bin/bash
systemctl stop carracho.service
bash ServerLinux/build.sh
bash TrackerLinux/build.sh
# Keep live server/Bot configuration when deploying a freshly compiled binary.
# The build tree contains defaults for first installation only.
if [ -e /opt/carracho/etc/carracho-server.json ]; then
    rm -f .build/linux/etc/carracho-server.json
fi
if [ -e /opt/carracho/etc/carracho-bot.json ]; then
    rm -f .build/linux/etc/carracho-bot.json
fi
cp -rf .build/linux/* /opt/carracho
rm -rf .build
chown pi:pi -R /opt/carracho
systemctl start carracho.service
sleep 1
systemctl status carracho.service
sleep 1
systemctl start carracho-tracker.service
sleep 1
systemctl status carracho-tracker.service

