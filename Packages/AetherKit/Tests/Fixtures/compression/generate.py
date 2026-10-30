#!/usr/bin/env python3
"""gzip 测试数据生成器（docs/11 §5.3）：用 Python zlib（独立实现）压缩确定的文本。

文本为 2000 行 `DOMAIN-SUFFIX,host<i>.example.com`（Swift 测试中按同样规则生成以比较）。

    python3 -I generate.py
"""
import gzip
import struct
import zlib

text = "".join(f"DOMAIN-SUFFIX,host{i}.example.com\n" for i in range(2000)).encode()


def gzip_with(level, strategy=zlib.Z_DEFAULT_STRATEGY, data=text):
    compressor = zlib.compressobj(level, zlib.DEFLATED, 31, 8, strategy)
    return compressor.compress(data) + compressor.flush()


def gzip_named(data, name):
    """带 FNAME 头字段的 gzip 成员。"""
    raw = zlib.compressobj(6, zlib.DEFLATED, -15)
    body = raw.compress(data) + raw.flush()
    header = b"\x1f\x8b\x08\x08" + struct.pack("<I", 0) + b"\x00\x03" + name + b"\x00"
    return header + body + struct.pack("<II", zlib.crc32(data) & 0xFFFFFFFF, len(data) & 0xFFFFFFFF)


open("stored.gz", "wb").write(gzip_with(0))
open("fixed.gz", "wb").write(gzip_with(6, zlib.Z_FIXED))
open("dynamic.gz", "wb").write(gzip_with(9))
open("multi.gz", "wb").write(gzip_with(6, data=text[:1000]) + gzip_with(6, data=text[1000:]))
open("empty.gz", "wb").write(gzip.compress(b"", mtime=0))
open("named.gz", "wb").write(gzip_named(text[:500], b"rules.list"))
