# Hammer

A small Mac menu bar app for the desk:

- **Dell monitor** — real brightness and contrast over DDC/CI (like MonitorControl), for Apple Silicon Macs.
- **Govee lights** — on/off, brightness, color and white presets, one at a time or all together. Reaches each light the best way available:
  - **Wi-Fi** for lights with LAN Control turned on in the Govee Home app
  - **Bluetooth** for nearby bulbs without LAN Control (H6004/H6006/H6008/H6009 family)
  - **Govee cloud** with an API key, for everything else (set from Terminal: `~/Hammer/Hammer govee key <API key>`)

  Bluetooth reaches through walls, so a bulb found only over Bluetooth could be a neighbor's. Those start under **Other Lights**, where Hammer never controls them (not even with All Lights), until you choose **Add to My Lights**. Each shows roughly how far away it is, and **Blink to Identify** helps you tell which is which.
- **Turn On At** (in All Lights) — pick a time, once or every day, and your lights come on with the color and brightness they last had. Optionally wakes the Mac a minute before (macOS asks for your password once).
- **Sleep timer** (in All Lights) — pick 5 minutes to 8 hours on a slider and all your lights turn off then. The Mac stays awake until the timer runs out (closing the lid still puts it to sleep), and the timer survives Hammer restarting.

Open the menu from the hammer icon in the menu bar, by pressing **Control-Option-H**, or by opening Hammer from Apps or Spotlight.

## Install

Paste into Terminal:

```
curl -fsSL https://raw.githubusercontent.com/ohmychael/hammer-/main/install-hammer.sh | bash
```

This builds Hammer on your Mac (it installs Apple's command-line developer tools first if needed), puts it in `~/Applications`, opens it at login, and turns on automatic updates.

## Updates

Hammer checks this repo at login and every 2 minutes. When there's a new commit it rebuilds and restarts itself. If a new version fails to build, the current one keeps running. You can also choose **Check for Updates** in the menu. The log is at `~/Hammer/update.log`.

## Terminal commands

```
~/Hammer/Hammer get brightness          read a monitor setting
~/Hammer/Hammer set brightness 40       change it (brightness, contrast, volume, or a hex VCP code)
~/Hammer/Hammer govee list              find Wi-Fi and cloud lights
~/Hammer/Hammer govee on | off          all Wi-Fi and cloud lights
~/Hammer/Hammer govee key <API key>     save a Govee cloud API key
```

Bluetooth bulbs are controlled from the menu bar app only.

## Files

| File | What it does |
|---|---|
| `Hammer.swift` | The whole app |
| `build.sh` | Compiles and installs `~/Applications/Hammer.app` |
| `update.sh` | Pulls the latest commit and rebuilds |
| `install-hammer.sh` | One-time setup |

## Uninstall

```
launchctl bootout gui/$(id -u)/local.hammer.updater
rm ~/Library/LaunchAgents/local.hammer.plist ~/Library/LaunchAgents/local.hammer.updater.plist
pkill -x Hammer; rm -rf ~/Applications/Hammer.app ~/Hammer ~/.config/hammer
```
