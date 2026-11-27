# RealmShuffle VR development build notes

Base: Immivio 1.0.2, commit 10f5bb87d628e84e53af0cf5054b522bdb15a137. Consult [upstream build documentation](BUILD.md) and [licensing](LICENSING.md) for the original native build and dependencies.

The tested experimental Quest APK used Godot 4.7.2 stable, OpenXR vendors addon 5.1.0, Python 3.13 and Android SDK build-tools 36.0.0. Install Pillow using tools/realmshuffle/requirements.txt.

## Experimental packaging workflow

From the repository root, prepare upstream assets using configs/prepare_assets.py --download, import app/godot in Godot, then export a resource ZIP using the "Quest 3" preset. The known command-line pattern is:

    godot --headless --xr-mode off --path app/godot --import
    godot --headless --xr-mode off --path app/godot --export-pack "Quest 3" Resources.zip

Use the original Immivio Quest 1.0.2 web release APK (2026-11-22), SHA256 4BC64F1B216AE6458CD0406B491627ECDA0FFE531F8BE3F110E09E851A4EB73A. Obtain it from the upstream project, not from an untrusted mirror.

    python tools/realmshuffle/prepare_apk.py original.apk Resources.zip unsigned.apk
    python tools/realmshuffle/patch_identity.py unsigned.apk identity.apk
    python tools/realmshuffle/patch_branding.py identity.apk branded.apk tools/realmshuffle/RealmShuffle-Icon.png
    python tools/realmshuffle/patch_icons.py branded.apk icons.apk tools/realmshuffle/RealmShuffle-Icon.png
    zipalign -f -P 16 4 icons.apk aligned.apk
    apksigner sign --ks YOUR_KEYSTORE --out RealmShuffle.apk aligned.apk
    apksigner verify --verbose RealmShuffle.apk

Use your own signing key; keep it private. The experimental package ID is com.northboundwisdom.immivio.dev, distinct from the upstream package. Updates require matching signing certificates. The original binary layout is version-specific; do not assume compatibility with newer releases.

The packager replaces six compiled scripts and their remaps, preserving the original native libraries. All twelve resources were verified against the tested APK. The full native build correspondence and redistribution review remain pending; this is not a claim of complete reproducibility or a public binary release.

## 0.7.3 Lite texture optimization

After packaging and branding the 0.7.3 baseline, use the optimized export from this branch to replace the panorama resources before final alignment and signing:

    python tools/realmshuffle/patch_optimized_textures.py patch icons.apk Resources.zip lite-unsigned.apk
    zipalign -f -P 16 4 lite-unsigned.apk lite-aligned.apk
    apksigner sign --ks YOUR_KEYSTORE --ks-key-alias YOUR_ALIAS --out RealmShuffle-Lite.apk lite-aligned.apk
    apksigner verify --verbose RealmShuffle-Lite.apk
    python tools/realmshuffle/patch_optimized_textures.py verify icons.apk Resources.zip RealmShuffle-Lite.apk

The patcher validates the sparse resource index, expected texture paths and unchanged APK entries. The tested baseline was the signed local 0.7.3 build; the unsigned branded baseline variant above has not been separately tested. Use the matching original APK layout and signing identity. All 16 targeted resources (scripts, remaps and panoramas) matched the installed Lite APK. Full native source build and distribution review remain pending.
