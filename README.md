# Hammer

A small Mac menu bar app for the desk:

- **Dell monitor** — real brightness and contrast over DDC/CI (like MonitorControl), for Apple Silicon Macs. When the monitor can't be controlled (e.g. HDMI from a USB-C adapter), Hammer dims the picture in software instead. See [Monitor](#monitor).
- **Govee lights** — on/off, brightness, color and white presets, one at a time or all together. Reaches each light the best way available:
  - **Wi-Fi** for lights with LAN Control turned on in the Govee Home app
  - **Bluetooth** for nearby bulbs without LAN Control (H6004, H6006, H6008, H6009, H600A, H600D and H6010)
  - **Govee cloud** with an API key, for everything else (set from Terminal: run `~/Hammer/Hammer govee key` and paste the key when it asks)

  On macOS 14 or later, each Bluetooth bulb's row says **On** or **Off** on the right, from what the bulb last reported, and All Lights says **On**, **Off**, or how many are on. Lights that haven't said (not connected, or on Wi-Fi or the cloud) show nothing there.

  Lights in your Govee account (with a cloud API key) are yours. A light found only nearby could be someone else's: Bluetooth reaches through walls, and dorms and offices share Wi-Fi. Those start under **Other Lights**, where Hammer won't control them (not with All Lights, the sleep timer or Turn On At either) until you choose **Add to My Lights**. Each Bluetooth bulb shows roughly how far away it is, and **Blink to Identify** flashes just that one, twice, and leaves it on or off as it was. A bulb found over Bluetooth counts as one of your account's lights only when its Bluetooth name matches that light's device ID; otherwise it waits under Other Lights, where you can add it. If the cloud doesn't answer (say, at login before Wi-Fi is up), Hammer goes by your account's lights from the last time it did. When you updated, lights on your network that you'd renamed or colored in an older Hammer were added for you, at the first scan that reached your network; add any others from Other Lights.
- **Turn On At** (in All Lights, or in your light's own menu if you have just one) — pick a time, once or every day, and your lights come on with the color and brightness they last had. Optionally wakes the Mac a minute before (macOS asks for your password). Changing the time, unticking the wake or choosing **Cancel Turn On** cancels exactly the wake Hammer set. A daily wake uses macOS's repeating schedule, which holds only one wake, so if your Mac already has its own repeating wake or sleep schedule, Hammer leaves it alone and says so.
- **Delivery alerts** — a Mac notification when a package is delivered ("Delivered · eBay — Apple iPhone 15 Pro Max"), from the delivery emails in your Gmail: eBay, Amazon, UPS, USPS, FedEx and most other stores. Click it to open the email. Failed or attempted deliveries show as **Delivery problem**. See [Delivery alerts](#delivery-alerts).
- **YouTube** — press **⌘Y** (or **⌃⌥Y**) and YouTube appears flush in the screen's top-right corner. If you have Microsoft Edge, it opens there as an Edge app window, so you're signed in and your extensions work; press the shortcut again to tuck it away. Or use Hammer's own glass player, with a mini player that floats above everything. See [YouTube](#youtube).
- **Sleep timer** (in All Lights, or in your light's own menu if you have just one) — pick 5 minutes to 8 hours on a slider and all your lights turn off then. The Mac stays awake until the timer runs out (closing the lid still puts it to sleep), and the timer survives Hammer restarting. If the Mac slept through both the timer and a Turn On At, only the one set for later happens. A bulb that's busy (with your phone, or Bluetooth just woke up) gets 5 minutes to take a scheduled command, and the Mac stays awake until every light has it (or for those 5 minutes); if a light still doesn't take it, the menu says so. A tap in Hammer meanwhile replaces it.

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

If a bulb shows **can't reach**, something else has it: usually the Govee app on your phone. Force-quit the app and Hammer connects within seconds. To stop it happening at all, turn off Bluetooth for Govee Home on the phone (iPhone: Settings → Privacy & Security → Bluetooth → Govee Home); the app still controls your Wi-Fi bulbs. If macOS itself refuses the connection (for example, too many Bluetooth devices are connected), the bulb's menu says that instead. A tap made while a bulb can't be reached is sent as soon as it's free, if that's within 15 seconds; older taps are dropped rather than firing later, and the menu says "Couldn't reach" for a while. The color checkmark moves only once the light has taken the change.

If a bulb keeps refusing, Hammer retries more slowly each time (up to once a minute) instead of flooding it; using the light makes it try again within 2 seconds. A bulb that connects but doesn't accept Hammer's commands (for example after a firmware update) is let go, so it doesn't block your phone, and is checked again every 5 minutes.

Each bulb's menu shows its link status at the top, and **Turn On** / **Turn Off** are checked from what the bulb itself reports.

## Delivery alerts

Choose **Set Up Delivery Alerts…** in the menu, then **Start**. Hammer reads your delivery emails through a small script in your own Google account, so no app password is needed. Setup takes about 2 minutes:

1. Hammer copies the script and opens a new Google Apps Script project in your browser (script.new). Sign in as the Gmail account your deliveries go to. The script is copied for this Mac only (not to your other devices), marked so clipboard managers don't keep it, and cleared from the clipboard once alerts are on.
2. In the editor, press ⌘A, then ⌘V to paste over what's there, then ⌘S to save.
3. Click **Deploy → New deployment**. Click the gear ⚙ next to "Select type" and choose **Web app**.
4. Set **Execute as: Me** and **Who has access: Anyone**. Click **Deploy**.
5. Click **Authorize access** and choose your account. Google warns that it hasn't verified the app (it's your own script): click **Advanced**, then **Go to … (unsafe)**. Tick **Select all** so it can read Gmail, then click **Continue**.
6. Copy the **Web app URL** (it ends in `/exec`), paste it into Hammer, and click **Turn On**.
7. When macOS asks, allow notifications from Hammer.

Google's permission screen lists everything a Gmail script *could* do. This one only searches your inbox for emails from the last 2 days whose subject mentions a delivery, and for each sends Hammer the sender, subject, date, Message-ID and Gmail's ID for the email, plus your Gmail address. It doesn't change, send or delete anything, and it only answers Hammer, which sends a random 64-character key the script checks. The script's code is in `Deliveries.swift` (`DeliveryScript.template`), so you can read what you're pasting.

How it works:
- Every 3 minutes, and shortly after the Mac wakes, Hammer asks the script. The first time it looks at the last 2 days; after that, only at mail since the last check (with 15 minutes' overlap), which keeps it well inside Gmail's daily limits.
- Hammer decides which emails are deliveries, from the subject and the sender. It only understands English subjects, and only looks at the inbox. A delivered package, a failed or attempted delivery (**Delivery problem**), and a package that's **Out for delivery** make a notification. A package's "Delivered" replaces its "Out for delivery" notification. Out-for-delivery alerts can be turned off with **Out for Delivery Alerts** in the **Delivery Alerts** submenu. Food and grocery deliveries ("Your Instacart order has been delivered") alert too. Click a notification to open the email in Gmail.
- Each subject goes through the same steps, in order, and the first that applies decides: replies, forwards and read receipts are skipped (Re:, Fwd:, FW:, AW:, WG:, SV:, Antw:, RV:, TR: and the like); so are help pages, a question about something wrong followed by what to do ("Item delivered - not as described? Open a case"); then anything that isn't a parcel coming to you (cancelled or refunded orders, returns you sent, gift cards, parcels waiting to be picked up or handed to a carrier, ads); then a failed or attempted delivery anywhere in the subject is a **Delivery problem** ("Delivery attempted — redelivery scheduled for Tuesday"); then the first part of the subject that says where the parcel is decides: **Out for delivery**, **Delivered** (said in the past tense), or not yet ("Shipped", "Arriving today", "Scheduled for delivery": skipped). So "Part of your order has been delivered; the rest is on its way" is a delivery. Other questions decide nothing ("Was your order delivered on time?", "How did we do? Leave a review"). Product names in quotes never decide: `Shipped: "Package Delivered Sign"` is a shipping update, `Delivered: "Expected Value"` a delivery.
- Out for delivery, problems and deliveries have to name a parcel: a package, parcel, shipment, order, item, purchase or box, a tracking number in a carrier's own format, or an item a store Hammer knows names in quotes right after "Delivered:", "Out for delivery:" or "Delivery attempted:". "Delivery" alone isn't enough, so a fax, SMS, webhook or report "delivery", "Your message was delivered" or a colleague's "Delivered: Q3 deck" stays quiet. A carrier (UPS, USPS, FedEx, DHL and others) is taken at its word for problems and out for delivery, but its "Delivered" needs a parcel word or tracking number too, so "Holiday cheer, delivered" stays quiet. Bounced-email notices are skipped too.
- A store or carrier is recognized by the domain of the sender's address, or a subdomain of it: `email.ups.com` is UPS, `ups.attacker.top` isn't. Only the address itself counts, never a name, comment or quoted text around it, and an email with more than one sender counts as from no one Hammer knows. Any other sender is shown by its domain, so a "USPS" email from `usps-redeliver.top` shows as **Delivery problem · usps-redeliver.top**. Messages Amazon and eBay pass on from sellers show as **Amazon seller** and **eBay seller**, and Shopify isn't on the list, since it sends for every shop.
- The address an email claims to be from can be forged. With an app password, Hammer also reads Gmail's own check of the sender, the one Gmail puts on top of every email it receives: the email has to be signed (DKIM) by the sender's domain, or pass Gmail's DMARC check for it. If it doesn't, or that check is missing, the email shows as **Unverified sender**, whatever domain it claims, and a "delivery problem" from it isn't shown at all (that's where phishing usually is). One limit: if Gmail added no check of its own (possibly mail Gmail fetched from another account), a check the sender wrote above the From line is taken as Gmail's. Another: a small shop that signs its email only with its email provider's domain and has no DMARC record shows as **Unverified sender** with an app password, and its delivery problems aren't shown. The Google script doesn't pass that check on, so there a forged email that gets past Gmail's spam filter can show a known store's name. Either way a notification is only text, and clicking it opens the email in Gmail.
- Emails already there when you turn alerts on aren't announced, and nothing is announced twice. If alerts stopped working and you set up the same Gmail account again, Hammer catches up on what arrived since the last check that worked (up to 3 days back), and keeps the list in the menu. The menu shows the last 7 days' deliveries.
- A package's "Delivered" takes the place of its "Out for delivery" (never the other way round) when they share a tracking number in the carrier's own format, or name the same item (and order number, if any) within 2 days. A store's order number isn't a tracking number, so another part of a split shipment gets its own notification, and so does a "Delivered" when two orders of the same item are out for delivery at once (Hammer doesn't guess which).
- If something's wrong, the menu says so in one line, with **Fix…** when there's something to do. Problems that pass by themselves (no internet, Google busy) clear on their own; after waking, Hammer tries once more quietly before saying it can't reach Gmail. If the script's deployment is wrong (for example, access isn't **Anyone**), **Fix…** says what to change. Fixing it in Google is enough: Hammer keeps asking and picks it up.
- The key, the script's web address and the app password are kept in your login Keychain, not in Hammer's settings. macOS's `security` tool keeps them, not Hammer itself. Hammer's certificate is made on your Mac, not issued by Apple, so macOS would tie anything Hammer stored to that exact build and ask for your login password after every update. The catch: any program running as you could read them with `security`. `~/Hammer/Hammer keychain-check` stores, reads and deletes a test item the same way. The macOS build check runs it.
- **Turn Off Delivery Alerts** deletes the key, the address and the app password from the Keychain. The script stays deployed in your Google account: to remove it, delete its project at script.google.com, or remove its access at myaccount.google.com/connections.

**With an app password instead:** choose **Use an App Password Instead** in the setup window. Hammer then reads Gmail directly over IMAP with a 16-letter app password from myaccount.google.com/apppasswords, which needs 2-Step Verification. The inbox is opened read-only and only a few headers are read: sender, subject, date, Message-ID and Gmail's check of the sender. If Gmail stops accepting the password, Hammer stops trying, so your account isn't locked; **Fix…** takes you straight to typing a new one. If Google wants you to sign in to Gmail in the browser first, the menu says so. Personal Gmail accounts always allow IMAP (since January 2025); if a Google Workspace administrator has turned it off, the menu says so.

## Install

Paste into Terminal:

```
curl -fsSL https://raw.githubusercontent.com/ohmychael/hammer-/main/install-hammer.sh | bash
```

This builds Hammer on your Mac (it installs Apple's command-line developer tools first if needed), puts it in `~/Applications`, opens it at login, and turns on automatic updates. In System Settings → General → Login Items, these show as **Hammer** and **Hammer Updates**; if you turn one off, Hammer's menu says so and offers **Turn On…**.

Opening Hammer from Spotlight, Finder or Apps shows its menu at the pointer, so you can reach it even when its menu bar icon is hidden. If the icon is hidden, the menu says so and shows where to allow it.

## Updates

Each build is signed with a certificate made once on your Mac (in `~/Hammer/signing`, its own keychain, not your login keychain), so macOS recognizes every update as the same Hammer and doesn't ask for Bluetooth and other permissions again. You'll be asked one last time after the first build that uses it. If that certificate can't be made or used, the build is signed ad hoc as before, and the update log (`~/Hammer/update.log`) says which happened: "Signed with Hammer Local Signing" or "Signed ad hoc".

Hammer checks this repo at login and every 5 minutes, and every 2 minutes while it's running. When there's a new commit it rebuilds and restarts itself. Every update first runs the tests in `Tests/main.swift`; if a test fails or the new version doesn't build, the update stops and the current one keeps running. The new version is kept only once it has started properly and kept running for 20 seconds (quitting it yourself meanwhile is fine); if it doesn't, the one you had comes back. You can also choose **Check for Updates** in the menu. The menu shows what the last check found (for example "Up to date · checked 2:14 PM"), and Hammer shows a notification when it has updated.

- An update doesn't restart Hammer while one of its dialogs is open, while Hammer's own YouTube player is open or playing, or while it's in the middle of Turn On At's password prompt, Blink to Identify or Check Monitor Connection; it waits until you're done, for up to 30 minutes. (A video in Edge isn't affected: it plays in Edge. The color picker isn't covered: it isn't a dialog.)
- Problems with your Mac rather than the update (Apple's command-line tools need reinstalling after a macOS upgrade, the disk is almost full) are shown in the menu with what to do, and the update is tried again later.
- An update cut off part-way (by a logout or a shutdown) puts the Hammer you had back on the next run, even offline.

The log is at `~/Hammer/update.log`.

**If updates seem stuck** (the version in the menu stays old), run the install command above again. It's safe: it waits for an update that's running, rebuilds the latest version, and sets the login items up again.

## Terminal commands

```
~/Hammer/Hammer get brightness          read a monitor setting
~/Hammer/Hammer set brightness 40       change it (brightness, contrast, volume, or a hex VCP code)
~/Hammer/Hammer monitor check           if the monitor doesn't respond: tests each step and says why
~/Hammer/Hammer govee list              find Wi-Fi and cloud lights
~/Hammer/Hammer govee on | off          all your Wi-Fi and cloud lights (not Bluetooth bulbs)
~/Hammer/Hammer govee key               save a Govee cloud API key (paste it when asked)
```

Bluetooth bulbs are controlled from the menu bar app only: `govee on` from Terminal doesn't reach them. It skips lights you've removed, and lights found only on the network that you haven't added.

## Files

| File | What it does |
|---|---|
| `Hammer.swift` | The app: menu, monitor, Govee Wi-Fi/cloud/Bluetooth |
| `HammerCore.swift` | Logic that needs only Foundation: packets, the Bluetooth command queue, name parsing, which lights are yours, the sleep timer and Turn On At rules, the Mac's wake schedule |
| `Monitor.swift` | Monitor control logic (Foundation only): DDC/CI messages, finding the monitor's connection, the monitor check |
| `MonitorMac.swift` | Monitor control on the Mac: reads IOKit's display registry and sends the bytes |
| `Player.swift` | YouTube logic (Foundation only): YouTube links, which pages stay in the player, where the windows go, and the scripts and steps for YouTube in Edge |
| `PlayerMac.swift` | The YouTube dropdown and floating mini player, and its self-test (`Hammer player-check`) |
| `EdgeMac.swift` | YouTube in your own Microsoft Edge: starts the app window, runs Hammer's scripts, asks macOS's permission; self-test (`Hammer edge-check`) |
| `PlayerScript.js` | Runs inside the YouTube page: finds the video, plays/pauses/seeks it, shows only the video in the mini player |
| `Tests/Player/` | Tests for `PlayerScript.js` in node with a stand-in page |
| `Deliveries.swift` | Delivery alerts logic (Foundation only): which emails are deliveries, reading Gmail over IMAP |
| `DeliveryAlerts.swift` | Delivery alerts on the Mac: secure connection to Gmail, Keychain, notifications |
| `Tests/main.swift` | Tests for `HammerCore.swift`, `Monitor.swift`, `Player.swift` and `Deliveries.swift`, run before every install. The monitor tests use stand-in monitors and Macs: picky, silent, locked and broken monitors, empty ports, the M1 HDMI converter, DisplayLink |
| `Tests/Deliveries/` | Delivery alerts end to end: fake Gmail and Google script servers, and the script itself in node |
| `Tests/Bluetooth/` | Bluetooth scenarios (phone grabs the bulb, failures, resets…) against a stand-in CoreBluetooth; run on Linux |
| `build.sh` | Compiles and installs `~/Applications/Hammer.app` |
| `signing.sh` | Signs every build with the same local certificate, so macOS remembers Hammer's permissions across updates |
| `Tests/Signing/` | Tests for `signing.sh` with stand-ins for macOS's `security` and `codesign` |
| `update.sh` | Pulls the latest commit and rebuilds; writes what it did to `~/Hammer/update-status` for the menu |
| `install-hammer.sh` | One-time setup |
| `agents.sh` | The two login items (open at login, updates), named "Hammer" and "Hammer Updates" |
| `UpdatesMac.swift` | Hammer's side of updating: the menu's update line and notifications, login items, the busy and started notes for `build.sh`, the app icon (`Hammer make-icon`) |
| `Tests/Update/` | Updates and installs played out in a sandbox (real git, stand-ins for swiftc, open, launchctl…): interrupted swaps, a crash at launch, broken tools, a full disk, hangs, the installer racing an update, and updating from the scripts before these (`old/`) |
| `.github/workflows/macos.yml` | Builds Hammer on a real Apple Silicon Mac for every push: tests, the app, the monitor check, and signing twice to confirm it stays the same |

## Uninstall

```
launchctl bootout gui/$(id -u)/local.hammer.updater; launchctl bootout gui/$(id -u)/local.hammer
rm ~/Library/LaunchAgents/local.hammer.plist ~/Library/LaunchAgents/local.hammer.updater.plist
pkill -x Hammer; rm -rf ~/Applications/Hammer.app ~/Hammer ~/.config/hammer
security delete-generic-password -s local.hammer.gmail   # delivery alerts' key or app password (run until it says not found)
sudo pmset repeat cancel                                 # if you used Turn On At with waking the Mac
```

## Running the tests by hand

```
cd ~/Hammer/repo
target="$(uname -m)-apple-macosx$(sw_vers -productVersion | cut -d. -f1).0"   # the macOS this Mac runs, as build.sh does
swiftc -swift-version 5 -target "$target" HammerCore.swift Monitor.swift Player.swift Deliveries.swift Tests/main.swift \
  -o /tmp/hammer-tests && /tmp/hammer-tests
node Tests/Player/script_test.js
Tests/Update/run.sh                 # updates and installs, in a sandbox (about a minute)
```

The Bluetooth scenarios play out 37 situations in real time, such as your phone taking a bulb and letting it go, connections that fail or hang, Bluetooth resetting, a neighbor's bulb nearby, and a scheduled command waiting for a busy bulb. They check what Hammer does in each one. They need Linux with Swift 5.9+, because the real CoreBluetooth on a Mac gets in the way of the stand-in:

```
Tests/Bluetooth/run.sh              # about 2 minutes
Tests/Bluetooth/run.sh phone storm  # just these
```

The delivery tests run Hammer's Gmail code against fake Gmail and Google-script servers, and the Google script itself in node with a fake Gmail. They cover the whole setup-to-notification flow for both routes, with stand-ins for Apple's frameworks. They also cover a wrong key or password, deployment mistakes, and Google being offline or silent. They need Swift, python3 and node:

```
Tests/Deliveries/run.sh             # about 40 seconds
```
