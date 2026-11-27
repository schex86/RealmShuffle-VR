import copy
import struct
import sys
import zipfile
from pathlib import Path

source, output, icon = sys.argv[1:4]
icon_data = Path(icon).read_bytes()

def u16(data, pos):
    return struct.unpack_from("<H", data, pos)[0]

def u32(data, pos):
    return struct.unpack_from("<I", data, pos)[0]

def patch_manifest(data):
    pos = u16(data, 2)
    size = u32(data, pos + 4)
    header = u16(data, pos + 2)
    count = u32(data, pos + 8)
    styles = u32(data, pos + 12)
    flags = u32(data, pos + 16)
    start = u32(data, pos + 20)

    assert u16(data, pos) == 1
    assert header == 28
    assert styles == 0
    assert not flags & 0x100

    pool = data[pos:pos + size]
    strings = []

    for i in range(count):
        p = start + u32(pool, header + 4*i)
        length = u16(pool, p)
        assert length < 0x8000
        strings.append(
            pool[p+2:p+2+length*2].decode("utf-16le")
        )

    def string_index(value):
        if value not in strings:
            strings.append(value)
        return strings.index(value)

    label_index = string_index("RealmShuffle VR")

    payload = bytearray()
    offsets = []

    for value in strings:
        offsets.append(len(payload))
        raw = value.encode("utf-16le")
        payload.extend(struct.pack("<H", len(raw)//2))
        payload.extend(raw)
        payload.extend(b"\0\0")

    while len(payload) % 4:
        payload.append(0)

    new_start = 28 + 4*len(strings)
    new_pool = bytearray(pool[:28])

    struct.pack_into("<I", new_pool, 4,
                     new_start + len(payload))
    struct.pack_into("<I", new_pool, 8, len(strings))
    struct.pack_into("<I", new_pool, 16, flags & ~1)
    struct.pack_into("<I", new_pool, 20, new_start)

    for offset in offsets:
        new_pool.extend(struct.pack("<I", offset))

    new_pool.extend(payload)

    result = bytearray(
        data[:pos] + new_pool + data[pos+size:]
    )

    struct.pack_into("<I", result, 4, len(result))

    cursor = pos + len(new_pool)
    changed = 0

    while cursor + 8 <= len(result):
        kind = u16(result, cursor)
        chunk_size = u32(result, cursor+4)

        assert chunk_size >= 8
        assert cursor + chunk_size <= len(result)

        if kind == 0x0102:
            element = u32(result, cursor+20)

            if strings[element] in (
                "application",
                "activity",
                "activity-alias"
            ):
                attr_start = u16(result, cursor+24)
                attr_size = u16(result, cursor+26)
                attr_count = u16(result, cursor+28)

                for i in range(attr_count):
                    a = cursor+16+attr_start+i*attr_size
                    name = u32(result, a+4)

                    if strings[name] == "label":
                        struct.pack_into(
                            "<I", result, a+8, label_index
                        )
                        result[a+15] = 3
                        struct.pack_into(
                            "<I", result, a+16, label_index
                        )
                        changed += 1

        cursor += chunk_size

    assert changed > 0
    print("Launcher labels updated:", changed)

    return bytes(result)

with zipfile.ZipFile(source) as src:
    manifest = patch_manifest(
        src.read("AndroidManifest.xml")
    )

    # Preserve the existing adaptive icon resource.
    # Replace its binary XML with a valid bitmap drawable
    # referring to the existing PNG resource only when
    # a compatible target has been identified.

    with zipfile.ZipFile(output, "w") as dst:
        for entry in src.infolist():
            name = entry.filename

            if name == "AndroidManifest.xml":
                data = manifest
            elif name == "assets/branding/immivio-icon.png":
                # Godot's indexed assets must remain unchanged.
                data = src.read(name)
            else:
                data = src.read(name)

            dst.writestr(copy.copy(entry), data)

    with zipfile.ZipFile(output) as dst:
        assert dst.testzip() is None

print("Application label patch: PASS")
