import copy
import hashlib
import struct
import sys
import zipfile
from pathlib import Path

original = Path(sys.argv[1])
resources = Path(sys.argv[2])
output = Path(sys.argv[3])

index_name = "assets/assets.sparsepck"

scripts = [
    "input_coordinator",
    "main",
    "playback_coordinator",
    "playback_feedback",
    "realm_adaptive_shuffle",
    "realm_shuffle_controller",
]

def md5(data):
    return hashlib.md5(data).digest()

def sha256(data):
    return hashlib.sha256(data).hexdigest()

print("\n===== 01. OPEN ORIGINAL APK =====")

with zipfile.ZipFile(original) as apk, \
     zipfile.ZipFile(resources) as compiled:

    index = apk.read(index_name)

    magic, version, major, minor, patch, flags = \
        struct.unpack_from("<6I", index, 0)

    file_base, directory = \
        struct.unpack_from("<QQ", index, 24)

    print("Pack version:", version)
    print("Godot:", f"{major}.{minor}.{patch}")
    print("Pack flags:", flags)
    print("File base:", file_base)
    print("Directory offset:", directory)

    if magic != 0x43504447:
        raise RuntimeError("Invalid Godot package magic")

    if version != 4 or flags != 6:
        raise RuntimeError("Unexpected sparse package format")

    count = struct.unpack_from("<I", index, directory)[0]
    cursor = directory + 4

    records = {}
    names = set(apk.namelist())

    print("\n===== 02. VALIDATE ORIGINAL RESOURCE INDEX =====")
    print("Indexed resources:", count)

    for _ in range(count):

        length = struct.unpack_from("<I", index, cursor)[0]
        cursor += 4

        if length <= 0 or cursor + length + 36 > len(index):
            raise RuntimeError("Invalid index record")

        path_bytes = index[cursor:cursor + length]
        cursor += length

        path = path_bytes.rstrip(b"\0").decode("utf-8")

        offset, size = struct.unpack_from("<QQ", index, cursor)
        cursor += 16

        digest = index[cursor:cursor + 16]
        cursor += 16

        record_flags = struct.unpack_from("<I", index, cursor)[0]
        cursor += 4

        if path in records:
            raise RuntimeError("Duplicate index path: " + path)

        records[path] = {
            "offset": offset,
            "size": size,
            "digest": digest,
            "flags": record_flags,
        }

    print("Parsed records:", len(records))
    print("Index bytes consumed:", cursor)
    print("Original index bytes:", len(index))

    if any(r["flags"] != 0 for r in records.values()):
        raise RuntimeError("Unexpected per-file flags")

    if any(r["offset"] != 0 for r in records.values()):
        raise RuntimeError("Unexpected sparse resource offsets")

    mismatches = []

    for path, record in records.items():

        entry = "assets/" + path

        if entry not in names:
            mismatches.append((path, "Missing APK entry"))
            continue

        data = apk.read(entry)

        if len(data) != record["size"]:
            mismatches.append((path, "Size mismatch"))

        if md5(data) != record["digest"]:
            mismatches.append((path, "MD5 mismatch"))

    print("Original index mismatches:", len(mismatches))

    for item in mismatches[:20]:
        print(item)

    if mismatches:
        raise RuntimeError(
            "Original resource index validation failed"
        )

    print("\n===== 03. PREPARE COMPILED MODIFICATIONS =====")

    replacements = {}

    for script in scripts:

        for suffix in (".gdc", ".gd.remap"):

            path = "scripts/" + script + suffix

            data = compiled.read(path)

            if not data:
                raise RuntimeError("Empty resource: " + path)

            if suffix == ".gd.remap":
                expected = (
                    'res://scripts/' + script + '.gdc'
                ).encode()

                if expected not in data:
                    raise RuntimeError(
                        "Invalid resource remap: " + path
                    )

            status = "UPDATE" if path in records else "ADD"

            replacements["assets/" + path] = data

            records[path] = {
                "offset": 0,
                "size": len(data),
                "digest": md5(data),
                "flags": 0,
            }

            print(status, path, len(data), "bytes")

    print("\n===== 04. REGENERATE SPARSE RESOURCE INDEX =====")

    new_index = bytearray(index[:directory])

    new_index.extend(
        struct.pack("<I", len(records))
    )

    for path, record in records.items():

        path_bytes = path.encode("utf-8")

        # Include null termination and 4-byte alignment.
        path_bytes += b"\0" * (4 - len(path_bytes) % 4)

        new_index.extend(
            struct.pack("<I", len(path_bytes))
        )

        new_index.extend(path_bytes)

        new_index.extend(
            struct.pack(
                "<QQ",
                record["offset"],
                record["size"],
            )
        )

        new_index.extend(record["digest"])

        new_index.extend(
            struct.pack("<I", record["flags"])
        )

    replacements[index_name] = bytes(new_index)

    print("Original resource count:", count)
    print("Updated resource count:", len(records))
    print("Original index size:", len(index))
    print("Updated index size:", len(new_index))

    print("\n===== 05. CREATE UNSIGNED EXPERIMENTAL APK =====")

    temporary = output.with_suffix(".partial")

    with zipfile.ZipFile(temporary, "w") as target:

        for entry in apk.infolist():

            name = entry.filename
            upper = name.upper()

            # Remove old APK signature files only.
            if upper.startswith("META-INF/") and (
                upper.endswith((".RSA", ".DSA", ".EC", ".SF"))
                or upper == "META-INF/MANIFEST.MF"
            ):
                continue

            if name in replacements:
                data = replacements.pop(name)
            else:
                data = apk.read(name)

            target.writestr(copy.copy(entry), data)

        for name, data in replacements.items():
            target.writestr(
                name,
                data,
                compress_type=zipfile.ZIP_STORED
            )

    print("\n===== 06. VERIFY EXPERIMENTAL APK =====")

    with zipfile.ZipFile(temporary) as target:

        bad = target.testzip()

        if bad is not None:
            raise RuntimeError("Corrupt ZIP entry: " + bad)

        for path, record in records.items():

            data = target.read("assets/" + path)

            if len(data) != record["size"]:
                raise RuntimeError("Size mismatch: " + path)

            if md5(data) != record["digest"]:
                raise RuntimeError("MD5 mismatch: " + path)

        native_count = 0

        for name in apk.namelist():

            if name.startswith("lib/") and name.endswith(".so"):

                if sha256(apk.read(name)) != \
                   sha256(target.read(name)):

                    raise RuntimeError(
                        "Native library changed: " + name
                    )

                native_count += 1

        print("Native libraries preserved:", native_count)
        print("Verified resources:", len(records))
        print("ZIP integrity: PASS")

    temporary.replace(output)

    print("\n===== PHASE 13 RESOURCE PACKAGING COMPLETE =====")
    print("Output:", output)
    print("Bytes:", output.stat().st_size)
    print("APK remains unsigned.")
    print("Do not install this intermediate package.")
