#!/usr/bin/env python3
"""Repack an Android boot image (header v0/v1/v2) with a new kernel payload,
keeping the stock ramdisk / cmdline / addresses / AVB-relevant layout intact.

  python bootimg_pack.py <stock-boot.img> <new-kernel-blob> <out-boot.img>

The new kernel blob is normally `Image.gz-dtb` (built Image.gz + the stock
appended DTB tail).  Everything else is copied from the original image, so the
result differs from the stock image only in the kernel payload and the sizes /
offsets that follow from it.
"""
import os
import struct
import sys

PAGE = None


def parse(path):
    d = open(path, "rb").read()
    if d[0:8] == b"ANDROID!":
        off_hdr = 8
    elif d[8:16] == b"ANDROID!":
        off_hdr = 16
    else:
        raise SystemExit("not an Android boot image")

    (kernel_size, kernel_addr, ramdisk_size, ramdisk_addr, second_size,
     second_addr, tags_addr, page_size, header_version, os_version) = \
        struct.unpack_from("<10I", d, off_hdr)
    ver = header_version

    hdr_len = 1632 if ver == 0 else 1648
    name = d[off_hdr + 40:off_hdr + 56]
    cmdline = d[off_hdr + 56:off_hdr + 568]
    ident = d[off_hdr + 568:off_hdr + 600]
    extra = d[off_hdr + 600:off_hdr + 1624]
    recovery_dtbo_size = recovery_dtbo_offset = 0
    if ver >= 1:
        recovery_dtbo_size = struct.unpack_from("<I", d, off_hdr + 1624)[0]
        recovery_dtbo_offset = struct.unpack_from("<Q", d, off_hdr + 1628)[0]
    header_size = struct.unpack_from("<I", d, off_hdr + 1636)[0] if ver >= 1 else 0

    pos = page_size
    parts = {}
    for key, size in (("kernel", kernel_size), ("ramdisk", ramdisk_size),
                      ("second", second_size)):
        parts[key] = d[pos:pos + size]
        pos += (size + page_size - 1) // page_size * page_size
    if ver >= 1 and recovery_dtbo_size:
        parts["recovery_dtbo"] = d[pos:pos + recovery_dtbo_size]
        pos += (recovery_dtbo_size + page_size - 1) // page_size * page_size
    # keep everything after the last component verbatim (padding + the AVB0
    # footer): an unchanged repack stays byte-identical and the stock AVB
    # footer bytes are preserved (a kernel swap invalidates them regardless).
    tail = d[pos:]
    return {
        "version": ver, "page_size": page_size,
        "kernel_addr": kernel_addr, "ramdisk_addr": ramdisk_addr,
        "second_addr": second_addr, "tags_addr": tags_addr,
        "os_version": os_version, "name": name, "cmdline": cmdline,
        "id": ident, "extra": extra,
        "recovery_dtbo_size": recovery_dtbo_size,
        "recovery_dtbo_offset": recovery_dtbo_offset,
        "header_size": header_size,
        "parts": parts, "tail": tail,
    }


def build(info, kernel_blob):
    ps = info["page_size"]
    ver = info["version"]
    kern = kernel_blob
    ram = info["parts"].get("ramdisk", b"")
    sec = info["parts"].get("second", b"")
    rdtbo = info["parts"].get("recovery_dtbo", b"")

    def pad(b):
        r = len(b) % ps
        return b + (b"\0" * (ps - r) if r else b"")

    kern_p, ram_p, sec_p, rdtbo_p = pad(kern), pad(ram), pad(sec), pad(rdtbo)

    body = kern_p + ram_p + sec_p + (rdtbo_p if ver >= 1 else b"")

    if ver == 0:
        hdr = struct.pack("<8s10I", b"ANDROID!",
                          len(kern), info["kernel_addr"], len(ram),
                          info["ramdisk_addr"], len(sec), info["second_addr"],
                          info["tags_addr"], ps, ver, info["os_version"])
        hdr += info["name"][:16].ljust(16, b"\0")
        hdr += info["cmdline"][:512].ljust(512, b"\0")
        hdr += info["id"][:32].ljust(32, b"\0")
        hdr += info["extra"][:1024].ljust(1024, b"\0")
    else:
        hdr = struct.pack("<8s10I", b"ANDROID!",
                          len(kern), info["kernel_addr"], len(ram),
                          info["ramdisk_addr"], len(sec), info["second_addr"],
                          info["tags_addr"], ps, ver, info["os_version"])
        hdr += info["name"][:16].ljust(16, b"\0")
        hdr += info["cmdline"][:512].ljust(512, b"\0")
        hdr += info["id"][:32].ljust(32, b"\0")
        hdr += info["extra"][:1024].ljust(1024, b"\0")
        hdr += struct.pack("<IQI", len(rdtbo), info["recovery_dtbo_offset"],
                           info["header_size"] or 1648)
    assert len(hdr) in (1632, 1648), len(hdr)
    return pad(hdr) + body + info.get("tail", b"")


def main():
    stock, kernel_file, out = sys.argv[1], sys.argv[2], sys.argv[3]
    info = parse(stock)
    kern = open(kernel_file, "rb").read()
    img = build(info, kern)
    # pad to the stock image length so any "dd the whole file" flasher is happy
    stock_len = os.path.getsize(stock)
    if len(img) < stock_len:
        img = img + b"\0" * (stock_len - len(img))
    open(out, "wb").write(img)
    print("stock : %s (%d bytes, header v%d, page %d)" %
          (stock, stock_len, info["version"], info["page_size"]))
    print("kernel: %s (%d bytes)" % (kernel_file, len(kern)))
    print("output: %s (%d bytes, %.1f MB)" % (out, len(img), len(img) / 1048576))
    if len(img) > stock_len:
        print("  note: larger than the stock image (partition must be big enough)")


if __name__ == "__main__":
    main()
