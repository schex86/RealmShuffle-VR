<p align="center"><img src="tools/realmshuffle/RealmShuffle-Icon.png" width="120" alt="RealmShuffle VR icon"></p>

# RealmShuffle VR

An independent open-source fork of [Immivio](https://github.com/NorthBoundWisdom/immivio), designed for continuous immersive VR media sessions on Meta Quest 3.

**Status:** 0.7.2 source baseline, tested on Quest 3. Public APK distribution is pending dependency and licensing review. Other headsets have not been validated for this fork.

## Features

- Adaptive shuffle without repeating scenes within a shuffle round.
- Videos shorter than four minutes loop toward a five-minute viewing session; longer videos play their natural duration.
- Independent randomized music and optional scene-matched soundtrack synchronization.
- Adjustable binaural audio, peaceful transitions, persistent session zoom and orientation.
- Controller navigation and a performance monitoring overlay.
- Standalone operation with locally supplied media, without a connected PC.

## Getting started

The current source uses local media under `/sdcard/Movies/RealmShuffle/Videos` and `/sdcard/Movies/RealmShuffle/Music`. Supply your own authorized VR180 side-by-side videos and audio. The project does not distribute commercial VR experiences or their soundtracks.

- [RealmShuffle controls](docs/REALMSHUFFLE-CONTROLS.md)
- [Build and packaging notes](docs/REALMSHUFFLE-BUILD.md)
- [Development roadmap](docs/REALMSHUFFLE-ROADMAP.md)
- [Original Immivio documentation](docs/IMMIVIO-README.md) (upstream features, not all independently verified in this fork)

## Attribution and licensing

Based on Immivio 1.0.2 by NorthBoundWisdom, commit `10f5bb87d628e84e53af0cf5054b522bdb15a137`. Immivio continues from [Thru3D Media Player](https://github.com/zerochocobo/Thru3D-Media-Player). Original history, credits and [GPL-3.0-only license](LICENSE) are retained. See [upstream licensing details](docs/LICENSING.md) for third-party components. RealmShuffle is independently maintained by schex86 and is not an official Immivio release.

The six modified Godot scripts and their remap files were rebuilt with Godot 4.7.2 and matched the twelve corresponding resources in the tested 0.7.2 APK byte for byte. This verifies the modified scripts, not complete native dependency correspondence.
