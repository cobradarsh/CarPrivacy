# CarPrivacy

A roothide tweak for iOS 16 (built for iPhone 14 Pro Max, iOS 16.5).

- **Part 1, Notification Privacy:** notifications from apps you choose don't show on the CarPlay screen. They still show on your iPhone as usual.
- **Part 2, Auto Location Services:** Location Services turn on when the phone connects to your car (CarPlay and/or the car's Bluetooth), and are handled when you leave according to the mode you choose:
  - **Restore Previous State** (default): turns them off only if they were off before you got in. If they were already on, for example because other apps use them, they stay on.
  - **Always Turn Off**
  - **Leave On**

  A disconnect delay (20 s by default) keeps a short Bluetooth drop, or switching from wireless to wired CarPlay, from toggling anything.

Settings live in **Settings → CarPrivacy**.

## Requirements on the phone

- A roothide jailbreak with SpringBoard tweak injection (roothide Dopamine). With roothide Bootstrap, turn on tweak injection for SpringBoard.
- From your package manager: **PreferenceLoader** and **AltList** (`com.opa334.altlist`). AltList provides the app picker.

## Download

Every push to `main` is built by GitHub Actions. Get the newest `.deb` from the
[Releases page](https://github.com/cobradarsh/CarPrivacy/releases), open it on your iPhone, and install it with Sileo or Filza.

## Building on Windows (via WSL)

Theos doesn't run on Windows directly, so build inside WSL (Ubuntu).

1. Install Ubuntu from an **administrator** PowerShell window, then reboot if asked:
   ```
   wsl --install -d Ubuntu
   ```
2. Open Ubuntu and install the **roothide fork** of Theos. The normal Theos can't build roothide packages:
   ```bash
   bash -c "$(curl -fsSL https://raw.githubusercontent.com/roothide/theos/master/bin/install-theos)"
   ```
   Restart the Ubuntu shell afterwards so `$THEOS` is set. Check it with `echo $THEOS`.
3. Copy the project into your Linux home folder. Building from `/mnt/c/...` is slow and can break on file permissions.
   ```bash
   cp -r "/mnt/c/path/to/CarPrivacy" ~/CarPrivacy && cd ~/CarPrivacy
   ```
4. Build the package:
   ```bash
   make clean package FINALPACKAGE=1
   ```
   The `.deb` is written to `packages/`, e.g. `com.adarsh.carprivacy_1.0.0_iphoneos-arm64e.deb`.

## Installing

Send the `.deb` to your phone (AirDrop, iCloud Drive, etc.), open it in **Sileo** or **Filza**, install it, and respring.
If OpenSSH is installed on the phone, you can instead run `make do THEOS_DEVICE_IP=<phone-ip>`.

## Setup

1. **Settings → CarPrivacy → Car Bluetooth Devices:** turn on your car. If it isn't listed, type its name in **Names**.
2. **Apps to Hide:** pick the apps whose notifications shouldn't show on the car screen (e.g. Messages, WhatsApp, Instagram).
3. Choose a **When I Leave the Car** mode.

## Testing and troubleshooting

1. Turn on **Debug Logging**.
2. Connect to the car, send yourself a notification from a hidden app, then tap **Show Status → Copy**.
   - **CarPlay destinations hooked** should list at least one class once CarPlay is connected.
   - **Last hidden notification** shows whether a notification was caught.
   - **Last notification destinations** lists how SpringBoard routed the latest notification. If a hidden app still appears on CarPlay, this is the information needed to fix it.
3. Live logs: on a Mac, open Console.app with the phone connected and filter for `CarPrivacy`. On the phone, use a log viewer that reads `os_log`.

## Known limitations

- **CarPlay vs. plain Bluetooth screens:** Part 1 filters the **CarPlay** screen. A car without CarPlay that shows messages over plain Bluetooth reads them through the Bluetooth Message Access Profile, which only carries SMS/iMessage and can't be filtered per app from SpringBoard. For those cars, use iOS's own per-car **Show Notifications** switch under Settings → Bluetooth → (i).
- **Siri "Announce Notifications" in CarPlay** is a separate iOS feature. Turn it off per app under Settings → Notifications → Announce Notifications → CarPlay.
- The tweak uses private SpringBoard APIs. The CarPlay detection API (`CARSessionStatus`) and the Bluetooth notifications are confirmed present in the iOS 16.5 SDK. The notification-routing class names come from earlier iOS versions, so the tweak finds them at runtime and does nothing (no crash) if they're missing. If hiding doesn't work, use the status screen above.

## Project layout

```
CarPrivacy/
├── Makefile, control, CarPrivacy.plist   tweak package (injects into SpringBoard only)
├── Tweak.x                               car detection, notification filtering, location toggling
├── Headers/Private.h                     private iOS interfaces
└── carprivacyprefs/                      Settings pane (PreferenceLoader bundle)
    ├── CPRootListController.m            main page + Status button
    ├── CPDevicePickerController.m        paired-Bluetooth-device picker
    ├── Resources/Root.plist              settings layout
    └── layout/…/CarPrivacyPrefs.plist    Settings entry
```

To use your own package ID, replace `com.adarsh.carprivacy` everywhere it appears (in `control`, `Tweak.x`, both `.m` files, and `Root.plist`).
