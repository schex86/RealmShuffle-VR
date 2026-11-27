# RealmShuffle changelog

## 0.7.3 Lite — Development baseline

- Persistent local video and music journals: playback starts and ends, navigation reasons, and periodic active-playback checkpoints.
- Panorama import limits reduced to 2048 pixels; both original background choices retained.
- Signed test APK reduced from 170.75 MiB to 120.63 MiB (29.35%); all 16 native libraries preserved byte for byte.
- Installed on Quest 3; startup, playback initiation, journal persistence, forward navigation and completion logging verified. Previous-navigation semantics, visual background quality and further journal recovery tests remain pending.
- All 16 targeted rebuilt resources match the installed development APK. Source commit: 4526ab6d2cfe9e1609eaee4bf5f8d5d5a90e51e8.

No public APK distribution or automatic media eviction is enabled. Journals remain local.

## 0.7.2 — Initial public source baseline

Based on Immivio 1.0.2. Includes adaptive shuffle and extended short-video sessions, independent music playback, scene soundtrack synchronization, binaural audio, randomized transitions, persistent session orientation and zoom, quiet looping with frame hold where supported, and a performance overlay with corrected layout.

Tested on Meta Quest 3. Six compiled scripts and six remaps matched the tested APK byte for byte. The source is public; the APK is not yet distributed by this repository.

For original Immivio development history, see [CHANGELOG.md](CHANGELOG.md).
