import copy
import struct
import sys
import zipfile

OLD = "com.northboundwisdom.immivio"
NEW = OLD + ".dev"

source, output = sys.argv[1:3]

def u16(b, p):
    return struct.unpack_from("<H", b, p)[0]

def u32(b, p):
    return struct.unpack_from("<I", b, p)[0]

def put32(b, p, v):
    struct.pack_into("<I", b, p, v)

def patch_manifest(data):
    assert u16(data, 0) == 3

    pos = u16(data, 2)
    assert u16(data, pos) == 1

    hs = u16(data, pos + 2)
    size = u32(data, pos + 4)
    count = u32(data, pos + 8)
    styles = u32(data, pos + 12)
    flags = u32(data, pos + 16)
    start = u32(data, pos + 20)

    assert hs == 28
    assert styles == 0
    assert not flags & 0x100

    pool = data[pos:pos + size]
    strings = []

    for i in range(count):
        p = start + u32(pool, hs + i * 4)
        length = u16(pool, p)
        assert length < 0x8000

        value = pool[
            p + 2:p + 2 + length * 2
        ].decode("utf-16le")

        strings.append(value)

    expected = {
        OLD,
        OLD + ".fileprovider",
        OLD + ".androidx-startup"
    }

    changed = set()

    for i, value in enumerate(strings):
        if value in expected:
            strings[i] = NEW + value[len(OLD):]
            changed.add(value)
            print(value, "->", strings[i])

    assert changed == expected

    offsets = []
    payload = bytearray()

    for value in strings:
        offsets.append(len(payload))
        raw = value.encode("utf-16le")
        payload.extend(struct.pack("<H", len(raw) // 2))
        payload.extend(raw)
        payload.extend(b"\0\0")

    while len(payload) % 4:
        payload.append(0)

    new_start = hs + count * 4
    new_pool = bytearray(pool[:hs])

    put32(new_pool, 4, new_start + len(payload))
    put32(new_pool, 16, flags & ~1)
    put32(new_pool, 20, new_start)

    for offset in offsets:
        new_pool.extend(struct.pack("<I", offset))

    new_pool.extend(payload)

    result = bytearray(
        data[:pos] + new_pool + data[pos + size:]
    )

    put32(result, 4, len(result))

    return bytes(result)

def patch_resources(data):
    result = bytearray(data)
    assert u16(result, 0) == 2

    pos = u16(result, 2)
    changed = 0

    while pos + 8 <= len(result):
        kind = u16(result, pos)
        size = u32(result, pos + 4)

        assert size >= 8
        assert pos + size <= len(result)

        if kind == 0x0200:
            start = pos + 12
            end = start + 256

            name = bytes(
                result[start:end]
            ).decode("utf-16le").split("\0")[0]

            if name == OLD:
                result[start:end] = NEW.encode(
                    "utf-16le"
                ).ljust(256, b"\0")

                changed += 1
                print("Resource package:", NEW)

        pos += size

    assert changed == 1
    return bytes(result)

with zipfile.ZipFile(source) as src:
    replacements = {
        "AndroidManifest.xml": patch_manifest(
            src.read("AndroidManifest.xml")
        ),
        "resources.arsc": patch_resources(
            src.read("resources.arsc")
        ),
    }

    with zipfile.ZipFile(output, "w") as dst:
        for entry in src.infolist():
            data = replacements.get(entry.filename)

            if data is None:
                data = src.read(entry.filename)

            dst.writestr(copy.copy(entry), data)

    with zipfile.ZipFile(output) as dst:
        assert dst.testzip() is None

        for name in src.namelist():
            if name not in replacements:
                assert src.read(name) == dst.read(name)

print("Identity patch: PASS")
print("Original components preserved.")
