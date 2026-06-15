# XRP Flasher

> Start here if you just want to flash and configure XRP robots. More detailed developer notes, OS compatibility details, and forking instructions are near the bottom.

XRP Flasher is a desktop app for preparing XRP robots in batches. It watches for XRP USB volumes, copies XRP firmware onto bootloader drives, reads each robot's status file, assigns robot numbers, sends Wi-Fi configuration to the robot, and saves records that can be copied into a spreadsheet.

## Download And Run

1. Open this project's GitHub page.
2. Click **Releases** on the right side of the page.
3. Open the release named **Latest build**.
4. Pick the file for your computer:
   - **Windows:** download `xrp_flasher-windows-x64-setup.exe`, run it, then open **XRP Flasher** from the Start menu.
   - **Linux:** download `xrp_flasher-linux-x86_64.AppImage`, mark it as executable if your desktop asks, then double-click it.

If you are on Windows and the installer is blocked by SmartScreen, click **More info** and only continue if the file came from this repository's release page.

## What You Need

- An XRP robot or controller board.
- A USB cable that supports data, not just charging.
- A Windows or Linux computer.
- On Linux, NetworkManager with `nmcli` is recommended if you want the app to connect to each robot's Wi-Fi automatically.
- On Linux, `udisksctl` is recommended so the app can mount unmounted XRP drives.

The app includes the firmware file `xrp-wpilib-firmware-2.1.0-aa439f0.uf2`. You can also type a different `.uf2` firmware path in the app if you want to flash another version.
Click **Download UF2** to fetch the same firmware from WPILib's GitHub release. The app logs download start, progress, file verification, and the final local path before using it for flashing.

## Basic Robot Workflow

1. Start XRP Flasher.
2. Put the robot controller into USB bootloader mode and plug it into the computer. Many RP2040/RP2350 boards use a BOOTSEL button while plugging in USB, but use your board's instructions if they differ.
3. Click **Scan** if the robot does not appear automatically.
4. When a bootloader volume appears as `RPI-RP2`, `RP2350`, or `RP23501`, click **Flash** for one robot or **Flash all** for every detected robot.
5. Wait for the robot to reboot and appear as `PICODISK`.
6. Click **Read status** or leave **Auto read** on. The app looks for `xrp-status.txt` or `status.txt`.
7. Enter a robot number. The app fills in default credentials:
   - Robot `5` becomes AP SSID `XR_5`.
   - Robot `5` becomes AP password `XRP_Robot_5`.
   - The default station network is `XRC-AP` with password `xrc-psc-ap`.
8. Change the AP or station credentials if needed.
9. Click **Configure**. With **Auto Wi-Fi** enabled, the app tries to connect to the robot's original access point, update its config over HTTP, and verify that the saved config matches. Linux uses `nmcli`; Windows uses `netsh` WLAN profiles.
10. Restart the robot after the app reports **Config saved**.

## Helpful Buttons And Switches

- **Auto flash:** flashes each detected bootloader volume as soon as it appears.
- **Auto read:** reads `PICODISK` status files as soon as they appear.
- **Auto save:** writes record files after successful reads or configuration.
- **Auto Wi-Fi:** lets the app use Linux `nmcli` or Windows `netsh` to connect to the robot Wi-Fi.
- **Assign missing:** fills empty robot-number boxes with the next available numbers.
- **Copy row:** copies one tab-separated row for spreadsheets.
- **Latest:** checks the latest upstream XRP WPILib firmware release on GitHub.
- **Download UF2:** downloads `xrp-wpilib-firmware-2.1.0-aa439f0.uf2`, verifies the file length and UF2 block structure, then updates the firmware path.

## Where Records Go

By default, records are saved in:

```text
~/XRPFlasher/robots
```

The app writes:

- `robots.json` with all known robot records.
- `XR_<number>.txt` files for robots that have assigned numbers.

These files include robot credentials and Wi-Fi passwords in plain text. Keep them private unless you intentionally want to share those credentials.

## Troubleshooting

- **No device appears:** click **Scan**, check that the USB cable supports data, and confirm that the drive is mounted or visible in your file manager.
- **Windows permission check:** click **Scan** and read the event log. If the log says the app can list the drive root, normal filesystem permission is not the detection blocker. If it says access failed, check Windows security policy, removable-drive restrictions, or whether the volume disconnected.
- **Flash fails:** check that the firmware path points to an existing `.uf2` file and that the bootloader drive is writable.
- **PICODISK never appears:** unplug and replug the robot after flashing, then wait a few seconds and scan again.
- **Configure fails while connecting Wi-Fi:** turn off the **Auto Wi-Fi** switch and manually connect your computer to the robot's Wi-Fi, then click **Configure** again.
- **Permission or mount errors on Linux:** install or enable desktop automount support, or make sure `udisksctl mount -b /dev/...` works for your user.

## Developer Setup

Requirements:

- Flutter with desktop support enabled.
- Linux build dependencies for local Linux builds: `clang`, `cmake`, `ninja`, `pkg-config`, `libgtk-3-dev`, and `liblzma-dev`.
- Optional Windows installer dependency: Inno Setup 6.

Common commands:

```bash
flutter pub get
flutter test
flutter run -d linux
flutter build linux --release
```

This repository includes a pre-push hook in `.githooks/pre-push`. Enable it in your clone with:

```bash
git config core.hooksPath .githooks
```

After that, `git push` runs `scripts/package_on_push.sh`. On Linux it tests the app, builds the Linux desktop bundle, and creates `dist/xrp_flasher-linux-x86_64.AppImage`. On Windows Git Bash it calls `scripts/package_windows.ps1`, which creates `dist/xrp_flasher-windows-x64.zip` and, when Inno Setup is installed, `dist/xrp_flasher-windows-x64-setup.exe`.

To skip local packaging for one push:

```bash
SKIP_PACKAGE_ON_PUSH=1 git push
```

The GitHub Actions workflow in `.github/workflows/package.yml` builds both Windows and Linux packages on every push. Pushes to the default branch also update the rolling **Latest build** GitHub release.

## How The App Works Internally

- `lib/main.dart` owns the Flutter UI, per-robot state, batch actions, log panel, and controller lifecycle.
- `lib/src/device_watcher.dart` polls every two seconds and finds matching USB volumes from `/proc/mounts`, `lsblk`, `/media`, `/run/media`, `/mnt`, Windows PowerShell `Get-Volume`, Windows `wmic`, Windows drive-letter probing, and XRP marker files such as `INFO_UF2.TXT` or `xrp-status.txt`.
- `lib/src/firmware_manager.dart` mounts unmounted Linux block devices with `udisksctl`, copies the selected `.uf2` file to the bootloader drive, runs `sync` where available, reads status files, and checks upstream firmware releases.
- `lib/src/status_parser.dart` extracts fields such as firmware version, chip ID, Wi-Fi mode, AP SSID, AP password, and IP address from XRP status text.
- `lib/src/xrp_config_service.dart` reads the robot HTTP config from `http://192.168.42.1:5000`, repairs empty configs when needed, writes AP/STA Wi-Fi settings, and verifies the saved config.
- `lib/src/record_store.dart` writes `robots.json` plus one text report per numbered robot.
- `lib/src/models.dart` defines detected volumes, robot stages, status fields, credentials, validation, display names, JSON output, and text output.

## Compatibility Notes

Linux supports mounted-volume detection through `/proc/mounts`, `lsblk`, common mount roots, `udisksctl` mounting, and optional `nmcli` Wi-Fi automation.

Windows supports mounted drive detection through PowerShell `Get-Volume`, `wmic`, drive-letter probing, and marker-file fallback. The Wi-Fi automation path creates a temporary `netsh` WLAN profile, connects to the XRP AP, polls the active Wi-Fi interface, then confirms success by reading the XRP HTTP config endpoint. If Windows blocks automatic connection, leave **Auto Wi-Fi** off and connect to the XRP network manually before clicking **Configure**.

macOS is not scaffolded in this repository. A fork could add macOS with `flutter create --platforms=macos .`, but drive detection, mounting, signing, notarization, and Wi-Fi automation would need separate implementation and testing.

## Forking Into Another Project

1. Fork or copy the repository.
2. Change the app name in `pubspec.yaml`, `README.md`, packaging scripts, and the GitHub workflow.
3. Replace the bundled `.uf2` file and update `FirmwareManager.bundledFirmwareName`.
4. Adjust `RobotCredentials.defaults` if your robot naming, AP password, or station network should differ.
5. Replace `XrpConfigService.buildConfig` if the target robot uses a different HTTP API or config schema.
6. Add platform-specific `DeviceWatcher` and Wi-Fi code before claiming support for another OS.

## License

This project is released under the MIT License. See `LICENSE`.
