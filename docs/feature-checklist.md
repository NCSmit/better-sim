# Feature checklist

This compares BetterSim with the features RocketSim lists in its public documentation, as of October 2026. Everything in BetterSim is built from scratch on Apple's own tools.

- ✅ means BetterSim has it.
- 🔒 means BetterSim has it, but it needs a permission that hasn't been tested on this Mac yet.
- ⚠️ means it can't be done, with the reason.

## Capture

| Feature | Status | Notes |
| --- | --- | --- |
| Screenshots | ✅ | PNG, saved to a folder you choose and copied to the clipboard. |
| Device bezels | ✅ | Uses the Simulator's own frames from Xcode, including the side buttons. |
| Backgrounds, shadow, aspect ratio and title | ✅ | White, black or gradient. Auto, 1:1, 4:3, 3:2, 16:9 or 9:16. An optional title goes above the device. |
| MP4 and GIF recordings | ✅ | GIF width can be chosen. |
| Touch indicators in recordings | ✅ | Dots follow taps and drags, then fade out. |
| Trim editor | ✅ | Trim with AVKit's trim bar before saving, and choose MP4 or GIF. |
| App Store Connect mode | ✅ | Screenshots are full screen without transparency. Recordings become 30 fps H.264 app previews at Apple's accepted sizes, with a stereo AAC track, and you're warned when one isn't 15 to 30 seconds. |
| 120 fps recording with sound | 🔒 | Captures the Simulator window with ScreenCaptureKit. Needs Screen Recording access. |
| Floating thumbnail after a capture | ✅ | Drag it into any app, or copy, reveal or delete it. |
| 9:41 and custom status bar | ✅ | Time, battery, charging, network, signal bars and carrier. |

## Design comparison

| Feature | Status | Notes |
| --- | --- | --- |
| Design overlay | ✅ | Fade or split view, mirror, zoom and offset. Drop, paste or choose a design. |
| Grid | ✅ | Spacing and colour. |
| Rulers and measuring | ✅ | Point rulers, a crosshair that shows the pointer's position, and drag to measure. |
| Magnifier and colour picker | ✅ | Uses the system magnifier, and copies the colour as hex, SwiftUI or UIKit. |
| Slow animations | 🔒 | Needs Accessibility. |

## App actions

| Feature | Status | Notes |
| --- | --- | --- |
| Launch, relaunch, terminate, uninstall | ✅ | |
| Relaunch in another language or time zone | ✅ | |
| Permissions | ✅ | Grant, revoke or reset each service, or all of them. |
| Deep links | ✅ | Saved per app, with an {ARG} placeholder. |
| Push notifications | ✅ | Templates and a saved payload per app, or drop an .apns file. |
| App folders | ✅ | Documents, Library, Caches, Preferences, tmp, the container, the bundle and App Groups. |
| UserDefaults editor | ✅ | View, search, edit, add and delete keys, including App Group defaults. |
| Reset keychain, clipboard both ways | ✅ | |
| Recent builds from DerivedData | ✅ | Install and launch with one click. |
| Build insights | ✅ | 7-day average build time, change from the week before, slowest build, failures, and per scheme. Xcode only records builds started in Xcode. |
| Delete DerivedData and SwiftUI preview simulators | ✅ | |
| Drop files on the panel | ✅ | Payloads, apps, photos, videos and certificates. |
| Shake, memory warning, restart | 🔒 | Shake and memory warning need Accessibility. |

## Device settings and accessibility

| Feature | Status | Notes |
| --- | --- | --- |
| Light and dark mode, Dynamic Type | ✅ | |
| Increase contrast, bold text, reduce motion, reduce transparency, button shapes, differentiate without colour | ✅ | Running apps update straight away. |
| Accessibility audit | 🔒 | Missing labels, small tap targets, duplicate labels and low text contrast. Needs Accessibility. |
| VoiceOver navigator | 🔒 | Steps through the screen in reading order, highlights each element and speaks it. Needs Accessibility. |
| Colour filters, grayscale, invert | ⚠️ | The Xcode 26 simulator doesn't draw them: grayscale changed nothing and invert only changed icons. |
| Location: places, coordinates, scenarios and routes | ✅ | Routes come from Apple Maps. |
| Network speed control | 🔒 | Uses macOS's own traffic shaper and needs an administrator password. It slows the whole Mac, because the Simulator shares the Mac's network. |

## Network, devices and automation

| Feature | Status | Notes |
| --- | --- | --- |
| Network traffic monitoring | ✅ | Relaunch an app with monitoring to see its URLSession requests. Tested end to end. |
| Physical devices | 🔒 | Mirroring, screenshots and recordings over USB, plus install, launch, relaunch, terminate and open URL. Untested, because no unlocked USB device was connected. |
| Command-line tool for AI agents | ✅ / 🔒 | Simulator commands are tested. ui, tap, swipe, type and wait need Accessibility. |
| Browser preview | ✅ | Local only, protected by a token. Click to tap and drag to swipe, which need Accessibility. |
| Side window, menu bar menu and global shortcuts | ✅ | |
| Simulator camera | ✅ | Your Mac's camera, an iPhone through Continuity Camera, or a test pattern. Previews, video frames and photos work, with no changes to the app. Code scanning, movie recording and DataScannerViewController don't yet. |
| Team build insights | ⚠️ | Needs a shared server, which is out of scope for a local tool. |
