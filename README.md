# Hammer

A small Mac menu bar app for the desk:

- **Dell monitor** — real brightness and contrast over DDC/CI (like MonitorControl), for Apple Silicon Macs. When the monitor can't be controlled (e.g. HDMI from a USB-C adapter), Hammer dims the picture in software instead. See [Monitor](#monitor).
- **Govee lights** — on/off, brightness, color and white presets, one at a time or all together. Reaches each light the best way available:
  - **Wi-Fi** for lights with LAN Control turned on in the Govee Home app
  - **Bluetooth** for nearby bulbs without LAN Control (H6004/H6006/H6008/H6009 family)
  - **Govee cloud** with an API key, for everything else (set from Terminal: `~/Hammer/Hammer govee key <API key>`)

  Bluetooth reaches through walls, so a bulb found only over Bluetooth could be a neighbor's. Those start under **Other Lights**, where Hammer never controls them (not even with All Lights), until you choose **Add to My Lights**. Each shows roughly how far away it is, and **Blink to Identify** helps you tell which is which.
- **Turn On At** (in All Lights) — pick a time, once or every day, and your lights come on with the color and brightness they last had. Optionally wakes the Mac a minute before (macOS asks for your password once).
- **Delivery alerts** — a Mac notification when a package is delivered ("Delivered · eBay — Apple iPhone 15 Pro Max"), from the delivery emails in your Gmail: eBay, Amazon, UPS, USPS, FedEx and most other stores. Click it to open the email. Failed or attempted deliveries show as **Delivery problem**. See [Delivery alerts](#delivery-alerts).
- **YouTube** — press **⌘Y** (or **⌃⌥Y**) and YouTube appears flush in the screen's top-right corner. If you have Microsoft Edge, it opens there as an Edge app window, so you're signed in and your extensions work; press the shortcut again to tuck it away. Or use Hammer's own glass player, with a mini player that floats above everything. See [YouTube](#youtube).
- **Sleep timer** (in All Lights) — pick 5 minutes to 8 hours on a slider and all your lights turn off then. The Mac stays awake until the timer runs out (closing the lid still puts it to sleep), and the timer survives Hammer restarting.

Open the menu from the hammer icon in the menu bar, by pressing **Control-Option-H**, or by opening Hammer from Apps or Spotlight.

## Monitor

Hammer finds which of the Mac's display connections the monitor is actually on (a 14" or 16" MacBook Pro has several), the same way m1ddc and MonitorControl do. When Hammer can talk to the monitor, the Brightness and Contrast sliders start at its real values and follow changes made with its own buttons each time you open the menu. Each slider shows its value.

- **USB-C or DisplayPort, straight into the Mac**, works best.
- **HDMI** works on most Macs. On M1-era Macs the HDMI port goes through a converter chip, and Hammer talks through it the way m1ddc does.
- **USB-C to HDMI cables, adapters and hubs** usually don't pass brightness control: the converter inside drops it. Hammer spots this from the monitor's ID info (EDID) and says so. Coming from the Mac's USB-C, what matters is which port on the *monitor* the cable goes into: its DisplayPort or USB-C port, not HDMI. Either a USB-C to USB-C cable into the monitor's USB-C port (the U3818DW comes with one; then Menu → Input Source → USB Type-C), or a USB-C to DisplayPort adapter with a DisplayPort cable into the monitor's DP port (one comes in the box too; then Input Source → DP). A DisplayPort to HDMI cable still lands on HDMI.
- **DisplayLink docks, AirPlay and Sidecar** can't carry brightness control. Hammer says so in the menu.
- **DDC/CI** has to be on in the monitor's own menu. On the Dell U3818DW: Menu → Others → DDC/CI → On.
- **Locked brightness:** on the U3818DW, Uniformity Compensation (Menu → Display) locks Brightness and Contrast in the Standard and Color Temp. modes, and Dynamic Contrast locks Brightness in Game and Movie. The monitor then ignores Hammer as it does its own buttons (its Brightness/Contrast item is grayed out). Turn them off.

**When the monitor can't be controlled** (HDMI from a USB-C adapter, DDC/CI off, or no connection Hammer can find), there's one Brightness slider, and it dims the picture instead, by adjusting the screen's color curves the way f.lux does. The menu says so in one line ("Software dimming: …"). It works over any direct cable (not DisplayLink, AirPlay or Sidecar), but it can only go darker than the monitor's own brightness, so set that fairly high with the monitor's buttons and dim from there with Hammer; changes made with the monitor's buttons don't move Hammer's slider. The backlight stays as it is (less power saved, and blacks get a little greyer when it's very dim). At 0 it keeps 15% of the signal, which is only about 1.5% of the light: very dim, but never fully dark. Hammer remembers the level per monitor and puts it back after sleep, replugging or a restart (an update too) straight away, eases in and out when it starts or stops, and stops as soon as the monitor answers again. If you quit Hammer, macOS puts the picture back to normal. If another app keeps changing the screen's color curves (f.lux, other dimming apps), Hammer pauses rather than fight it ("Paused: another app keeps changing the colors"), and dims again once that app's colors are gone, after a wake, or when you move the slider. If the screen's colors are already adjusted when Hammer starts (another app, or a calibration that lowers all three colors), it can't dim, and says so. With two external monitors, one slider dims both, and only when neither answers. Apple displays (Studio Display, Pro Display XDR) are left to macOS, which sets their brightness itself.

The menu always offers **Check Monitor Connection…**, and says so if the monitor doesn't answer. It tests each step: whether macOS sees the monitor, which connection and which of the monitor's inputs it's on, whether Hammer's messages go out, whether anything can be read back over the cable (the monitor's ID info), whether the monitor answers, and whether a change actually takes effect. It moves the brightness for a moment and puts it back. Then it gives the result and, in a few lines, what to fix (and whether Hammer dims in software meanwhile), with the details below; **Copy Report** copies all of it. The same check runs in Terminal with `~/Hammer/Hammer monitor check`.

## YouTube

**⌘Y** or **⌃⌥Y** (or **Open YouTube** in the menu) opens YouTube in the top-right corner of the screen you're working on (the one with the pointer), right under the menu bar. Where it opens is up to you in **Open In**: **Microsoft Edge** or **Hammer's Player**.

### In Microsoft Edge (the default when Edge is installed)

YouTube opens in your own Edge as an *app window*: no tabs, no address bar. It's your Edge profile, so you're signed in to your account and your extensions run there as usual.

- The first time, macOS asks **"Hammer wants access to control Microsoft Edge"**. Choose **Allow**. Hammer only finds that one window and opens, moves and minimizes it; its scripts send back window numbers and positions, never your tabs' addresses. It never reads your cookies, passwords or history. If you chose Don't Allow, Hammer says so once, and the menu then has **Allow Edge Control…**, which opens System Settings → Privacy & Security → Automation (turn on Microsoft Edge under Hammer).
- **The shortcut toggles it.** In front: it's tucked away (minimized; a playing video keeps playing), and you're back in the app you were using. Anywhere else (behind other windows, minimized): it comes back to the corner, in front. Closed: a new one opens. Press it twice quickly and the second press counts too (shown, then tucked away), but not after a new window opened or a press that took a while (Edge starting, macOS's question).
- Resize it and it keeps that size, and goes back to the corner each time.
- Hammer keeps to one window: one that opened before you allowed Hammer, or that Edge was slow to show, is the one it uses next time, and so is the one Edge brings back when it restarts (Hammer knows it by where it was).
- **Play Copied Link** plays the copied YouTube link in that window.
- For a small floating video, use Edge's own picture-in-picture (right-click the video twice → Picture in picture).
- It's an ordinary Edge window, so clicking into other apps doesn't close it: it just goes behind them.

### In Hammer's player

**⌘Y** or **⌃⌥Y** opens it; press it again, press Esc or ⌘W, or click anywhere outside it to close it (clicks inside it never do, and switching apps doesn't either). It's YouTube's own mobile site on the same glass as macOS's menus (the glass follows light and dark mode), in a wide panel flush in the top-right corner: drag its edges to resize it, and it remembers the size. Search, recommendations and signing in work as usual, and ads play as YouTube serves them. Hammer doesn't download or block anything.

- **Pop out** (the ⧉ button) moves the playing video into a mini player in the corner of the screen. It floats above every window and over full-screen apps. Drag it anywhere and it settles into the nearest corner; drag its edges to resize it. Point at it for play/pause, 10 seconds back or forward, back to the dropdown, and close. Double-click it to go back to the dropdown. Click it and the keys work there: **Esc** closes it, **Space** plays or pauses, **←** and **→** go 10 seconds back or forward (not during ads).
- Closing the dropdown while a video plays pops it out by itself, and so does a video that starts after you closed it: nothing plays without a window. Closing the mini player pauses it. **Back to the Mini Player** in the menu pops a playing video out again.
- **Pin** (📌) keeps the dropdown open when you click into other apps.
- **Play Copied Link** in the menu plays the YouTube link you copied (from Share → Copy link, a message, anywhere; `<…>` around it or a full stop after it is fine).
- Links to other sites open in your browser. The ↗ button opens what you're watching there, on YouTube's full site, at the moment you're at.
- After half an hour put away and paused, or when you switch to Edge, Hammer lets the page go to free its memory; it starts afresh next time.
- Signing in: tap **You → Sign in** once and it stays signed in. It can't use your browser's sign-in: browsers keep theirs to themselves, and a copied sign-in looks to Google like a stolen one. Google sometimes refuses to sign in inside apps; everything works signed out too. To use your Edge sign-in, choose Microsoft Edge in Open In.

### ⌘Y

**⌘Y Shortcut** in the menu is on to start with. While it's on, other apps don't get ⌘Y: Quick Look in Finder (Space still works), History in Edge, Chrome and Safari (use the History menu), and Redo in Microsoft Office (⌘⇧Z or the Edit menu). Turn it off and ⌃⌥Y still works. Both are on the key that types Y on your keyboard layout (on a German keyboard that's the key labeled Y, not the one where Y is on an American keyboard), and follow you when you switch layouts. The menu shows the shortcut that works; if another app has taken it, the menu says so.

## Bluetooth bulbs and your phone

A bulb talks to one device at a time over Bluetooth, and the Govee app on a phone keeps trying to connect in the background. So Hammer keeps a standing connection to your bulbs (only yours, never Other Lights), reconnects by itself whenever the link drops, and finds them again after a restart even while they're busy. Your phone's Govee app keeps working over Wi-Fi.

If a bulb shows **can't reach**, something else has it: usually the Govee app on your phone. Force-quit the app and Hammer connects within seconds. To stop it happening at all, turn off Bluetooth for Govee Home on the phone (iPhone: Settings → Privacy & Security → Bluetooth → Govee Home); the app still controls your Wi-Fi bulbs. A tap made while a bulb can't be reached is sent as soon as it's free, if that's within 15 seconds; older taps are dropped rather than firing later.

If a bulb keeps refusing, Hammer retries more slowly each time (up to once a minute) instead of flooding it; using the light makes it try again within 2 seconds. A bulb that connects but doesn't accept Hammer's commands (for example after a firmware update) is let go, so it doesn't block your phone, and is checked again every 5 minutes.

Each bulb's menu shows its link status at the top, and **Turn On** / **Turn Off** are checked from what the bulb itself reports.

## Delivery alerts

Choose **Set Up Delivery Alerts…** in the menu, then **Start**. Hammer reads your delivery emails through a small script in your own Google account, so no app password is needed. Setup takes about 2 minutes:

1. Hammer copies the script and opens a new Google Apps Script project in your browser (script.new). Sign in as the Gmail account your deliveries go to.
2. In the editor, press ⌘A, then ⌘V to paste over what's there, then ⌘S to save.
3. Click **Deploy → New deployment**. Click the gear ⚙ next to "Select type" and choose **Web app**.
4. Set **Execute as: Me** and **Who has access: Anyone**. Click **Deploy**.
5. Click **Authorize access** and choose your account. Google warns that it hasn't verified the app (it's your own script): click **Advanced**, then **Go to … (unsafe)**. Tick **Select all** so it can read Gmail, then click **Continue**.
6. Copy the **Web app URL** (it ends in `/exec`), paste it into Hammer, and click **Turn On**.
7. When macOS asks, allow notifications from Hammer.

Google's permission screen lists everything a Gmail script *could* do. This one only reads the sender, subject and date of recent inbox emails whose subject mentions a delivery. It doesn't change, send or delete anything, and it only answers Hammer, which sends a random 64-character key the script checks. The script's code is in `Deliveries.swift` (`DeliveryScript.template`), so you can read what you're pasting.

How it works:
- Every 3 minutes, and shortly after the Mac wakes, Hammer asks the script. The first time it looks at the last 2 days; after that, only at mail since the last check (with 15 minutes' overlap), which keeps it well inside Gmail's daily limits.
- Hammer decides which emails are deliveries. Shipping updates like "Out for delivery" or "Arriving today" are skipped. Only delivered (or failed) packages make a notification. Click one to open the email in Gmail.
- The word "delivered" isn't enough on its own. The wording has to say it happened ("was delivered", "Package Delivered", "Delivered: …"). The email also has to come from a known store or carrier (Amazon, eBay, UPS, USPS, FedEx, Walmart, Target and others, judged by the sender's actual address, not the name it shows), or mention a package, order, item or shipment. So "Your message was delivered" or a colleague's "Delivered: Q3 deck" stays quiet. Replies, ads and bounced-email notices are skipped too.
- Emails already there when you turn alerts on are never announced, and nothing is announced twice.
- The key is kept in your login Keychain. **Turn Off Delivery Alerts** deletes it. To stop the script completely, delete it at script.google.com, or remove its access at myaccount.google.com/connections.
- If the script's deployment is wrong (for example, access isn't **Anyone**), the menu says what to fix and offers **Set Up Gmail Again…**. Fixing the deployment in Google works too: Hammer keeps asking and picks it up.

**With an app password instead:** choose **Use an App Password Instead** in the setup window. Hammer then reads Gmail directly over IMAP with a 16-letter app password from myaccount.google.com/apppasswords, which needs 2-Step Verification. The inbox is opened read-only and only headers are read. If Gmail stops accepting the password, Hammer stops trying, so your account isn't locked.

## Install

Paste into Terminal:

```
curl -fsSL https://raw.githubusercontent.com/ohmychael/hammer-/main/install-hammer.sh | bash
```

This builds Hammer on your Mac (it installs Apple's command-line developer tools first if needed), puts it in `~/Applications`, opens it at login, and turns on automatic updates.

## Updates

Each build is signed with a certificate made once on your Mac (in `~/Hammer/signing`, its own keychain, not your login keychain), so macOS recognizes every update as the same Hammer and doesn't ask for Bluetooth and other permissions again. You'll be asked one last time after the first build that uses it. If that certificate can't be made or used, the build is signed ad hoc as before, and the update log (`~/Hammer/update.log`) says which happened: "Signed with Hammer Local Signing" or "Signed ad hoc".

Hammer checks this repo at login and every 2 minutes. When there's a new commit it rebuilds and restarts itself. Every update first runs the tests in `Tests/main.swift`; if a test fails or the new version doesn't build, the update stops and the current one keeps running. You can also choose **Check for Updates** in the menu. The log is at `~/Hammer/update.log`.

## Terminal commands

```
~/Hammer/Hammer get brightness          read a monitor setting
~/Hammer/Hammer set brightness 40       change it (brightness, contrast, volume, or a hex VCP code)
~/Hammer/Hammer monitor check           if the monitor doesn't respond: tests each step and says why
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
| `Monitor.swift` | Monitor control logic (Foundation only): DDC/CI messages, finding the monitor's connection, the monitor check |
| `MonitorMac.swift` | Monitor control on the Mac: reads IOKit's display registry and sends the bytes |
| `Player.swift` | YouTube logic (Foundation only): YouTube links, which pages stay in the player, where the windows go, and the scripts and steps for YouTube in Edge |
| `PlayerMac.swift` | The YouTube dropdown and floating mini player, and its self-test (`Hammer player-check`) |
| `EdgeMac.swift` | YouTube in your own Microsoft Edge: starts the app window, runs Hammer's scripts, asks macOS's permission; self-test (`Hammer edge-check`) |
| `PlayerScript.js` | Runs inside the YouTube page: finds the video, plays/pauses/seeks it, shows only the video in the mini player |
| `Tests/Player/` | Tests for `PlayerScript.js` in node with a stand-in page |
| `Deliveries.swift` | Delivery alerts logic (Foundation only): which emails are deliveries, reading Gmail over IMAP |
| `DeliveryAlerts.swift` | Delivery alerts on the Mac: secure connection to Gmail, Keychain, notifications |
| `Tests/main.swift` | Tests for `HammerCore.swift`, `Monitor.swift` and `Deliveries.swift`, run before every install. The monitor tests use stand-in monitors and Macs: picky, silent, locked and broken monitors, empty ports, the M1 HDMI converter, DisplayLink |
| `Tests/Deliveries/` | Delivery alerts end to end: fake Gmail and Google script servers, and the script itself in node |
| `Tests/Bluetooth/` | Bluetooth scenarios (phone grabs the bulb, failures, resets…) against a stand-in CoreBluetooth; run on Linux |
| `build.sh` | Compiles and installs `~/Applications/Hammer.app` |
| `signing.sh` | Signs every build with the same local certificate, so macOS remembers Hammer's permissions across updates |
| `Tests/Signing/` | Tests for `signing.sh` with stand-ins for macOS's `security` and `codesign` |
| `update.sh` | Pulls the latest commit and rebuilds |
| `install-hammer.sh` | One-time setup |
| `.github/workflows/macos.yml` | Builds Hammer on a real Apple Silicon Mac for every push: tests, the app, the monitor check, and signing twice to confirm it stays the same |

## Uninstall

```
launchctl bootout gui/$(id -u)/local.hammer.updater
rm ~/Library/LaunchAgents/local.hammer.plist ~/Library/LaunchAgents/local.hammer.updater.plist
pkill -x Hammer; rm -rf ~/Applications/Hammer.app ~/Hammer ~/.config/hammer
security delete-generic-password -s local.hammer.gmail   # delivery alerts' key or app password (run until it says not found)
```

## Running the tests by hand

```
cd ~/Hammer/repo
swiftc HammerCore.swift Monitor.swift Player.swift Deliveries.swift Tests/main.swift -o /tmp/hammer-tests && /tmp/hammer-tests
node Tests/Player/script_test.js
```

The Bluetooth scenarios play out 27 situations in real time, such as your phone taking a bulb and letting it go, connections that fail or hang, Bluetooth resetting, and a neighbor's bulb nearby. They check what Hammer does in each one. They need Linux with Swift 5.9+, because the real CoreBluetooth on a Mac gets in the way of the stand-in:

```
Tests/Bluetooth/run.sh              # about 2 minutes
Tests/Bluetooth/run.sh phone storm  # just these
```

The delivery tests run Hammer's Gmail code against fake Gmail and Google-script servers, and the Google script itself in node with a fake Gmail. They cover the whole setup-to-notification flow for both routes, with stand-ins for Apple's frameworks. They also cover a wrong key or password, deployment mistakes, and Google being offline or silent. They need Swift, python3 and node:

```
Tests/Deliveries/run.sh             # about 40 seconds
```
