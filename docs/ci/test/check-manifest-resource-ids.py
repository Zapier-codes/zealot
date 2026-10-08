#!/usr/bin/env python3
"""Task 46c-prov: fail if an android: attribute on the injected SDK elements has resource id 0.

Reads the binary AndroidManifest.xml of an APK directly (string pool, resource map, start-element
chunks), because aapt2 and androguard print attributes by name and would not show a missing id.
usage: python3 -I check-manifest-resource-ids.py <apk>
"""
import struct
import sys
import zipfile


def strings_of(d, o):
    sc, = struct.unpack_from('<I', d, o + 8)
    flags, sstart = struct.unpack_from('<II', d, o + 16)
    hs, = struct.unpack_from('<H', d, o + 2)
    utf8 = bool(flags & 0x100)
    out = []
    for so in struct.unpack_from('<%dI' % sc, d, o + hs):
        p = o + sstart + so
        if utf8:
            p += 1 if d[p] < 0x80 else 2
            n = d[p]
            p += 1
            if n & 0x80:
                n = ((n & 0x7f) << 8) | d[p]
                p += 1
            out.append(d[p:p + n].decode('utf-8', 'replace'))
        else:
            n, = struct.unpack_from('<H', d, p)
            out.append(d[p + 2:p + 2 + 2 * n].decode('utf-16le', 'replace'))
    return out


def main(apk):
    d = zipfile.ZipFile(apk).read('AndroidManifest.xml')
    strings, resmap, off = [], (), 8
    bad, seen = [], 0
    while off < len(d):
        t, _, size = struct.unpack_from('<HHI', d, off)
        if t == 0x1:
            strings = strings_of(d, off)
        elif t == 0x180:
            resmap = struct.unpack_from('<%dI' % ((size - 8) // 4), d, off + 8)
        elif t == 0x102:
            name, = struct.unpack_from('<i', d, off + 20)
            aoff, = struct.unpack_from('<H', d, off + 24)
            acount, = struct.unpack_from('<H', d, off + 28)
            tag = strings[name]
            for i in range(acount):
                a = off + 16 + aoff + i * 20
                ns, an, raw = struct.unpack_from('<iii', d, a)
                val = strings[raw] if 0 <= raw < len(strings) else ''
                if ns < 0 or an >= len(strings):
                    continue
                injected = 'zealot' in val.lower() or tag == 'uses-permission'
                if injected and tag in ('provider', 'meta-data', 'uses-permission'):
                    seen += 1
                    rid = resmap[an] if an < len(resmap) else 0
                    if rid == 0:
                        bad.append('<%s> android:%s = %r has resource id 0' % (tag, strings[an], val))
        off += size
    if not seen:
        print('FAIL: no injected element found to check')
        return 1
    if bad:
        print('FAIL: Android would not read these attributes:\n  ' + '\n  '.join(bad))
        return 1
    print('PASS: %d injected attributes all carry a resource id' % seen)
    return 0


sys.exit(main(sys.argv[1]))
