# Contributing to BetterSim

Thanks for helping out. BetterSim is a small project, so focused pull requests are the easiest to review and merge.

## How the project fits together

- **`Sources/BetterSim/Simulator/`** talks to the Simulator.
  - `Simctl.swift` runs `xcrun simctl`.
  - `DeviceProfile.swift` reads Xcode's device frames from DeviceKit.
  - `SimulatorWindows.swift` finds the Simulator's windows.
  - `ScreenGeometry.swift` works out where the device screen sits inside a window.
- **`Sources/BetterSim/Features/`** holds one file per feature: captures, framing, touches, app previews, app actions, UserDefaults, location, network speed, build insights and the accessibility audit. These files don't depend on the UI.
- **`Sources/BetterSim/App/`** holds the app delegate, the main `SimulatorModel` that the panel binds to, and preferences.
- **`Sources/BetterSim/UI/`** holds the panel docked next to the Simulator, the overlay window, settings and the editors.
- **`Tests/BetterSimTests/`** holds the tests.

BetterSim is a clean-room project. It is built only on Apple's public tools and APIs. Please don't contribute code, assets or text taken from other Simulator tools.

## Getting set up

You need macOS 14 or later and Xcode 16 or later, with the iOS Simulator installed.

```bash
git clone https://github.com/NCSmit/better-sim.git
cd better-sim
./build.sh --install
```

`./build.sh` builds `build/BetterSim.app`. With `--install` it also replaces the copy in `~/Applications` and restarts it.

## Running the tests

```bash
swift test
```

Most tests run anywhere. A few also run against a real simulator when you set an environment variable:

- `BETTERSIM_LIVE_UDID=<udid>` runs read-only checks on a booted device: screenshots, recording and GIFs.
- `BETTERSIM_SCRATCH_UDID=<udid>` changes settings, defaults, location and more. Only point it at a throwaway device:

```bash
UDID=$(xcrun simctl create "BetterSim Test" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro)
xcrun simctl boot "$UDID"
BETTERSIM_SCRATCH_UDID="$UDID" swift test
xcrun simctl delete "$UDID"
```

## Checking the panel without clicking around

Render every tab of the panel to PNG files:

```bash
BETTERSIM_SNAPSHOT=/tmp/bettersim-snapshots build/BetterSim.app/Contents/MacOS/BetterSim
```

## Remaking the README images

The images in `docs/` are drawn from the real views, not taken as screenshots:

```bash
./docs/make-images.sh
```

The script builds BetterSim and the small Trails demo app in `docs/demo/`. It also starts a local API for the network monitor, and installs Trails on a throwaway simulator, which it deletes afterwards. Nothing from your own simulators or settings appears in the images.

## Watching the app

Watch what the app is doing:

```bash
log stream --level info --predicate 'subsystem == "local.bettersim"'
```

## Code style

- Swift 6 with strict concurrency. UI state lives in `@MainActor` classes.
- Keep types small and names descriptive. Add a comment only to explain why something is done, not what it does.
- The panel never becomes the active window, so system switches, sliders and segmented controls would look disabled. Use `PanelSwitchStyle`, `PanelSlider` and `Segments` from `Theme.swift`.
- When you change the UI, update the matching images in `docs/`.

## Pull requests

1. Fork the repo and create a branch from `main`.
2. Keep each pull request to one change.
3. In the description, say what changed and why in a sentence or two, and how you tested it. For UI changes, add a screenshot.
4. Make sure the app builds and `swift test` passes.
