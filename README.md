<div align="center">

# BetterSim

**A free, open-source sidekick for the iOS Simulator.**

Capture, compare, test and debug your app without leaving the Simulator.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)](#install)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://swift.org)
[![CI](https://github.com/NCSmit/better-sim/actions/workflows/ci.yml/badge.svg)](https://github.com/NCSmit/better-sim/actions/workflows/ci.yml)

</div>

BetterSim docks a slim panel next to the Simulator window. Everything you reach for while building an iOS app is one click away there: screenshots and recordings, design overlays, deep links, push notifications, permissions, location, accessibility settings and more. It's built entirely on Apple's own tools, mostly `xcrun simctl` and the device frames that ship with Xcode, so there's nothing to sign up for and nothing leaves your Mac.

## Features

### Capture
- **Screenshots** in the Simulator's own device frame, with the side buttons. Add a background, a shadow, an aspect ratio and a title for slides and store pages.
- **MP4 and GIF recordings**, with dots that show where you tapped and dragged.
- **120 fps recordings with sound**, captured from the Simulator window.
- **A trim editor** before you save, if you want one.
- **App Store Connect mode.** Screenshots come out full screen without transparency. Recordings become 30 fps app previews at the sizes Apple accepts, with a stereo audio track.
- **A thumbnail after every capture.** Drag it straight into Slack, a pull request or Xcode.
- **A clean status bar**: 9:41, full battery, full signal, or any time and battery level you choose.

### Compare
- **Design overlays.** Drop or paste a design over the running app. Fade it, compare side by side, mirror it, zoom it or nudge it.
- **A grid, rulers and a measuring tool** in points, with the pointer's position.
- **A colour picker** that copies the colour as hex, SwiftUI or UIKit code.

### App actions
- Launch, relaunch, terminate and uninstall. Relaunch in another language or time zone.
- **Deep links**, saved per app, with an `{ARG}` placeholder you fill in each time.
- **Push notifications** from templates or your own payloads. You can also drop an `.apns` file on the panel.
- **Permissions**: grant, revoke or reset each one.
- **A UserDefaults editor**, including App Group defaults.
- **App folders**: Documents, Library, Caches, the bundle and App Groups.
- **Recent builds** from DerivedData, installed with one click, and **build insights** with your average build time.
- Reset the keychain, copy the clipboard either way, and clean up DerivedData and SwiftUI preview simulators.
- **Drop files on the panel**: apps install, photos and videos go to Photos, certificates get trusted and payloads get sent.

### Device settings and accessibility
- Light and dark mode, Dynamic Type, Increase Contrast, Bold Text, Reduce Motion, Reduce Transparency, Button Shapes and Differentiate Without Colour. Running apps update straight away.
- **An accessibility audit.** It finds missing labels, small tap targets, duplicate labels and low text contrast.
- **A VoiceOver navigator** that steps through the screen in reading order and speaks each element.
- **Location**: places, coordinates, Apple's built-in scenarios, and real walking, cycling or driving routes from Apple Maps.
- Shake, memory warnings, slow animations and restarting the device.

### Network
- **A network monitor.** Relaunch your app with monitoring to see every URLSession request it makes, with method, status, headers, bodies and timings. You can copy any request as a cURL command.
- **Network speed**: 3G, Edge, LTE, a very bad network, or no connection at all.

### Physical devices
- **Mirror a USB-connected iPhone or iPad** in a window, with its sound, then take framed screenshots and recordings of it.
- Install apps, and launch, relaunch or terminate them. You can also open a link in an app.

### For agents and automation
- A `bettersim` command-line tool that can read what's on screen, tap, swipe, type, wait for text, take screenshots and change settings. It's made for AI coding agents.
- **A browser preview** that shows the Simulator and lets you control it.

## Install

You need macOS 14 or later and Xcode 16 or later.

```bash
git clone https://github.com/NCSmit/better-sim.git
cd better-sim
./build.sh --install
```

BetterSim appears in the menu bar. Open the Simulator and the panel docks next to it.

### Permissions

BetterSim works without any special permissions. Some features ask for one the first time you use them:

| Permission | Used for |
| --- | --- |
| Accessibility | Placing overlays exactly over the screen, plus shake, memory warning, slow animations, the audit, the VoiceOver navigator, and taps from the command-line tool |
| Screen Recording | 120 fps recordings with sound |
| Camera and Microphone | Mirroring a connected iPhone or iPad, which macOS treats as a camera |
| Your administrator password | Network speed. macOS asks for it, and BetterSim never sees it |

## Command-line tool

Choose **Install Command-Line Tool…** in BetterSim's menu bar menu. That links `bettersim` into `~/.local/bin`. Then:

```bash
bettersim doctor                 # check that everything is ready
bettersim screenshot --frame     # a framed screenshot
bettersim ui                     # what's on screen, as JSON
bettersim tap --label "Sign In"  # tap an element by its label
bettersim type "hello@example.com"
bettersim wait --label "Welcome" --timeout 10
bettersim preview                # see and control the Simulator in a browser
```

Run `bettersim --help` for every command. Commands that read or touch the screen go through the running app, so they need BetterSim to be open and allowed to use Accessibility.

## How it works

- **`xcrun simctl`** does most of the work: screenshots, recordings, push notifications, deep links, permissions, location, the status bar, appearance and Dynamic Type.
- **Device frames** come from the DeviceKit folder Xcode installs on every Mac. BetterSim doesn't ship any Apple artwork.
- **The panel** follows the Simulator's windows through the window list, and works out where the device screen is from the window's size. With Accessibility access, it asks the Simulator directly instead.
- **Accessibility settings** are written to the device's own preferences, followed by the notification iOS apps listen for.
- **The network monitor** relaunches your app with a small library that BetterSim builds for the Simulator. The library records the app's URLSession requests and hands them to BetterSim on your Mac. Only apps you relaunch from BetterSim are monitored.
- **Network speed** uses dummynet, the traffic shaper built into macOS. The Simulator shares your Mac's network, so this slows down the whole Mac until you switch it back or quit BetterSim.

## Contributing

Bug reports, ideas and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) explains how the code fits together, how to run the tests, and how to render the panel without clicking around.
