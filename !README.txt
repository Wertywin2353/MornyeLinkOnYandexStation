// This project was created by ChatGPT and verified using an actual Yandex Station 2.
// Support for other models has not been tested and is likely unavailable.
// Installation and operation require "rooting" (hacking) the smart speaker, following the method described here:
// https://github.com/Marker284/yandex-station-extended/blob/main/docs/start/root.md#%D0%B8%D0%BD%D1%81%D1%82%D1%80%D1%83%D0%BA%D1%86%D0%B8%D1%8F--dns-unlock-

Before start:
Get Platform Tools (By Google) and drivers

0. Connect to jailbroken Station via ADB and fix IP-addresses in Scripts to match yours
1. Make first pair with Mornye - run pair-mornye-station2.ps1 (done once)
2. Create certificate for Station - run export-mornye-cert.ps1 (done once)
3. push the script and dependencies: (done once or on each update)
adb push mornye-link-player-v0.3\mornye-link-ws-arm64 /data/local/tmp/
adb push mornye-link-player-v0.3\mornye-link-ws-armv7 /data/local/tmp/
adb push mornye-link-player-v0.3\mornye-ledviz-arm64 /data/local/tmp/
adb push mornye-link-player-v0.3\mornye-ledviz-armv7 /data/local/tmp/
adb push mornye-link-player-v0.3\mornye-link-bridge.sh /data/local/tmp/
adb push mornye-link-player-v0.3\mornye-station2.sh /data/local/tmp/

4. Install Script (thru adb shell, done once or on each update):
sh /data/local/tmp/mornye-link-bridge.sh install
5. Run Script (thru adb shell, on each restart):
sh /data/local/tmp/mornye-link-bridge.sh start


Beta Feature:
sh /data/local/tmp/mornye-station2.sh ledviz test\on\off - manage LED



