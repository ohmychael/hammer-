# Hammer

A small Mac menu bar app for the desk:

- **Dell monitor** — real brightness and contrast over DDC/CI (like MonitorControl), for Apple Silicon Macs.
- **Govee lights** — on/off, brightness, color and white presets, one at a time or all together. Reaches each light the best way available:
  - **Wi-Fi** for lights with LAN Control turned on in the Govee Home app
  - **Bluetooth** for nearby bulbs without LAN Control (H6004/H6006/H6008/H6009 family)
  - **Govee cloud** with an API key, for everything else (set from Terminal: `~/Hammer/Hammer govee key <API key>`)

  Bluetooth reaches through walls, so a bulb found only over Bluetooth could be a neighbor's. Those start under **Other Lights**, where Hammer never controls them (not even with All Lights), until you choose **Add to My Lights**. Each shows roughly how far away it is, and **Blink to Identify** helps you tell which is which.
- **Turn On At** (in All Lights) — pick a time, once or every day, and your lights come on with the color and brightness they last had. Optionally wakes the Mac a minute before (macOS asks for your password once).
- **Delivery alerts** — a Mac notification when a package is delivered ("Delivered · eBay — Apple iPhone 15 Pro Max"), from the delivery emails in your Gmail: eBay, Amazon, UPS, USPS, FedEx and most other stores. Click it to open the email. Failed or attempted deliveries show as **Delivery problem**. See [Delivery alerts](#delivery-alerts).
- **Sleep timer** (in All Lights) — pick 5 minutes to 8 hours on a slider and all your lights turn off then. The Mac stays awake until the timer runs out (closing the lid still puts it to sleep), and the timer survives Hammer restarting.

Open the menu from the hammer icon in the menu bar, by pressing **Control-Option-H**, or by opening Hammer from Apps or Spotlight.

## Bluetooth bulbs and your phone

A bulb talks to one device at a time over Bluetooth, and the Govee app on a phone keeps trying to connect in the background. So Hammer keeps a standing connection to your bulbs (only yours, never Other Lights), reconnects by itself whenever the link drops, and finds them again after a restart even while they're busy. Your phone's Govee app keeps working over Wi-Fi.

If a bulb shows **can't reach**, something else has it: usually the Govee app on your phone. Force-quit the app and Hammer connects within seconds. To stop it happening at all, turn off Bluetooth for Govee Home on the phone (iPhone: Settings → Privacy & Security → Bluetooth → Govee Home); the app still controls your Wi-Fi bulbs. A tap made while a bulb can't be reached is sent as soon as it's free, if that's within 15 seconds; older taps are dropped rather than firing later.

If a bulb keeps refusing, Hammer retries more slowly each time (up to once a minute) instead of flooding it; using the light makes it try again within 2 seconds. A bulb that connects but doesn't accept Hammer's commands (for example after a firmware update) is let go, so it doesn't block your phone, and is checked again every 5 minutes.

Each bulb's menu shows its link status at the top, and **Turn On** / **Turn Off** are checked from what the bulb itself reports.

## Delivery alerts

Choose **Set Up Delivery Alerts…** in the menu. It needs a Gmail **app password**, a separate 16-letter password Google makes for one app. You need 2-Step Verification on your Google account to make one:

1. Click **Get App Password** in Hammer's setup window (or go to myaccount.google.com/apppasswords).
2. Type `Hammer` as the name and click **Create**.
3. Copy the 16 letters, paste them into Hammer with your Gmail address, and click **Turn On**.
4. When macOS asks, allow notifications from Hammer.

How it works:
- Every 3 minutes, and right after the Mac wakes, Hammer looks at new mail in your inbox for subjects about deliveries.
- It reads only the sender, subject, date and message ID. The inbox is opened read-only, so nothing is marked as read.
- Mail that was already there when you turned alerts on is never announced, and nothing is announced twice.
- Shipping updates like "Out for delivery" or "Arriving today" are skipped. Only delivered (or failed) packages make a notification.
- The app password is kept in your login Keychain, not in Hammer's files. **Turn Off Delivery Alerts** deletes it. You can also revoke it any time at myaccount.google.com/apppasswords.
- If Gmail stops accepting the password, Hammer stops trying (so your account isn't locked) and shows **Set Up Gmail Again…** in the menu.

## Install

Paste into Terminal:

```
curl -fsSL https://raw.githubusercontent.com/ohmychael/hammer-/main/install-hammer.sh | bash
```

This builds Hammer on your Mac (it installs Apple's command-line developer tools first if needed), puts it in `~/Applications`, opens it at login, and turns on automatic updates.

## Updates

Hammer checks this repo at login and every 2 minutes. When there's a new commit it rebuilds and restarts itself. Every update first runs the tests in `Tests/main.swift`; if a test fails or the new version doesn't build, the update stops and the current one keeps running. You can also choose **Check for Updates** in the menu. The log is at `~/Hammer/update.log`.

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
| `Hammer.swift` | The app: menu, monitor, Govee Wi-Fi/cloud/Bluetooth |
| `HammerCore.swift` | Logic that needs only Foundation: packets, the Bluetooth command queue, name parsing |
| `Deliveries.swift` | Delivery alerts logic (Foundation only): which emails are deliveries, reading Gmail over IMAP |
| `DeliveryAlerts.swift` | Delivery alerts on the Mac: secure connection to Gmail, Keychain, notifications |
| `Tests/main.swift` | Tests for `HammerCore.swift`, run before every install |
| `Tests/Deliveries/` | Delivery alerts end to end, against a fake Gmail server |
| `Tests/Bluetooth/` | Bluetooth scenarios (phone grabs the bulb, failures, resets…) against a stand-in CoreBluetooth; run on Linux |
| `build.sh` | Compiles and installs `~/Applications/Hammer.app` |
| `update.sh` | Pulls the latest commit and rebuilds |
| `install-hammer.sh` | One-time setup |

## Uninstall

```
launchctl bootout gui/$(id -u)/local.hammer.updater
rm ~/Library/LaunchAgents/local.hammer.plist ~/Library/LaunchAgents/local.hammer.updater.plist
pkill -x Hammer; rm -rf ~/Applications/Hammer.app ~/Hammer ~/.config/hammer
security delete-generic-password -s local.hammer.gmail   # the Gmail app password, if you set up delivery alerts
```

## Running the tests by hand

```
cd ~/Hammer/repo
swiftc HammerCore.swift Deliveries.swift Tests/main.swift -o /tmp/hammer-tests && /tmp/hammer-tests
```

The Bluetooth scenarios play out 27 situations in real time, such as your phone taking a bulb and letting it go, connections that fail or hang, Bluetooth resetting, and a neighbor's bulb nearby. They check what Hammer does in each one. They need Linux with Swift 5.9+, because the real CoreBluetooth on a Mac gets in the way of the stand-in:

```
Tests/Bluetooth/run.sh              # about 2 minutes
Tests/Bluetooth/run.sh phone storm  # just these
```

The delivery tests run Hammer's Gmail code against a fake Gmail server. They cover new mail, read flags left alone, a wrong password, Gmail unreachable or silent, and the whole setup-to-notification flow, with stand-ins for Apple's frameworks. They need Swift and python3:

```
Tests/Deliveries/run.sh             # about 15 seconds
```
