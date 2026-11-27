import copy
import hashlib
import struct
import sys
import zipfile
from pathlib import Path

INDEX = "assets/assets.sparsepck"

PANORAMAS = [
    "belfast_sunset_puresky",
    "blouberg_sunrise_2",
]

def signature_entry(name):
    name = name.upper()
    return name.startswith("META-INF/") and (
        name.endswith((".RSA", ".DSA", ".EC", ".SF"))
        or name == "META-INF/MANIFEST.MF"
    )

def unique_names(archive):
    names = archive.namelist()
    if len(names) != len(set(names)):
        raise RuntimeError("Duplicate ZIP entries")
    return set(names)

def read_index(data):
    magic, version, major, minor, patch, flags = (
        struct.unpack_from("<6I", data, 0)
    )

    if (magic, version, flags) != (0x43504447, 4, 6):
        raise RuntimeError("Unexpected sparse pack format")

    file_base, directory = struct.unpack_from("<QQ", data, 24)

    count = struct.unpack_from("<I", data, directory)[0]
    cursor = directory + 4
    records = {}

    for _ in range(count):
        length = struct.unpack_from("<I", data, cursor)[0]
        cursor += 4

        if length <= 0 or cursor + length + 36 > len(data):
            raise RuntimeError("Invalid sparse index record")

        path = data[cursor:cursor + length]
        path = path.rstrip(b"\0").decode("utf-8")
        cursor += length

        offset, size = struct.unpack_from("<QQ", data, cursor)
        digest = bytes(data[cursor + 16:cursor + 32])
        flags = struct.unpack_from("<I", data, cursor + 32)[0]

        if offset != 0 or flags != 0 or path in records:
            raise RuntimeError("Unsupported sparse index record")

        records[path] = {
            "position": cursor,
            "size": size,
            "digest": digest,
        }

        cursor += 36

    return records

def validate_resources(archive):
    records = read_index(archive.read(INDEX))

    for path, record in records.items():
        data = archive.read("assets/" + path)

        if len(data) != record["size"]:
            raise RuntimeError("Resource size mismatch: " + path)

        if hashlib.md5(data).digest() != record["digest"]:
            raise RuntimeError("Resource hash mismatch: " + path)

    return len(records)

def replacements_for(baseline, pack):
    names = unique_names(baseline)
    unique_names(pack)

    index = bytearray(baseline.read(INDEX))
    records = read_index(index)
    replacements = {}

    def replace_resource(path):
        target = "assets/" + path

        if path not in records or target not in names:
            raise RuntimeError("Resource not indexed: " + path)

        old = baseline.read(target)
        new = pack.read(path)

        if old == new:
            print("UNCHANGED:", path)
            return

        position = records[path]["position"]

        struct.pack_into("<Q", index, position + 8, len(new))

        index[position + 16:position + 32] = (
            hashlib.md5(new).digest()
        )

        replacements[target] = new

        print("REPLACE:", path)
        print("  Original bytes:", len(old))
        print("  New bytes:", len(new))

    for name in PANORAMAS:
        candidates = [
            path for path in records
            if path.startswith(".godot/imported/" + name)
            and path.endswith(".astc.ctex")
        ]

        if len(candidates) != 1:
            raise RuntimeError("Unexpected panorama paths: " + name)

        path = candidates[0]

        if len(pack.read(path)) >= len(baseline.read("assets/" + path)):
            raise RuntimeError("Texture did not shrink: " + name)

        replace_resource(path)

        import_path = "backgrounds/" + name + ".jpg.import"
        replace_resource(import_path)

    replacements[INDEX] = bytes(index)
    return replacements

def verify(baseline, pack, result):
    expected = replacements_for(baseline, pack)

    source_names = {
        n for n in unique_names(baseline)
        if not signature_entry(n)
    }

    result_names = {
        n for n in unique_names(result)
        if not signature_entry(n)
    }

    if source_names != result_names:
        raise RuntimeError("Unexpected APK entry additions/removals")

    bad = result.testzip()
    if bad:
        raise RuntimeError("Corrupt ZIP entry: " + bad)

    native_count = 0
    unchanged = 0

    for name in sorted(source_names):
        original = baseline.read(name)
        actual = result.read(name)
        required = expected.get(name, original)

        if actual != required:
            raise RuntimeError("Unexpected content change: " + name)

        if name not in expected:
            unchanged += 1

        if name.startswith("lib/") and name.endswith(".so"):
            if original != actual:
                raise RuntimeError("Native library changed: " + name)
            native_count += 1

    print()
    print("Verified indexed resources:", validate_resources(result))
    print("Native libraries unchanged:", native_count)
    print("Other entries unchanged:", unchanged)
    print("Allowed replacement entries:", len(expected))
    print("APK CONTENT VERIFICATION: PASS")

mode = sys.argv[1]
baseline_path, pack_path, result_path = map(Path, sys.argv[2:5])

with zipfile.ZipFile(baseline_path) as baseline:
    with zipfile.ZipFile(pack_path) as pack:

        if mode == "patch":
            print("Baseline indexed resources:", validate_resources(baseline))

            replacements = replacements_for(baseline, pack)

            temporary = result_path.with_suffix(".partial")

            with zipfile.ZipFile(temporary, "w") as result:
                for entry in baseline.infolist():
                    name = entry.filename

                    if signature_entry(name):
                        continue

                    data = replacements.get(name)

                    if data is None:
                        data = baseline.read(name)

                    result.writestr(copy.copy(entry), data)

            with zipfile.ZipFile(temporary) as result:
                verify(baseline, pack, result)

            temporary.replace(result_path)

        elif mode == "verify":
            with zipfile.ZipFile(result_path) as result:
                verify(baseline, pack, result)

        else:
            raise RuntimeError("Unknown operation")

print("Output bytes:", result_path.stat().st_size)