#!/usr/bin/env python3
"""Shadowsocks 2022 测试向量生成器（SIP022，docs/06 §8.4）。

独立于 Swift 实现：用 Python `blake3`（官方绑定）、`cryptography`（OpenSSL）的 AES-ECB / AES-GCM /
ChaCha20-Poly1305 按 SIP022 逐字构造 TCP 请求与响应、UDP 请求与回包。时间与随机字节固定：
随机字节流的第 k 个字节为 (0x10 + k) % 256，按 Swift 实现中的调用顺序取用
（TCP：salt → 填充长度 2 字节 → 填充；UDP：会话 ID 8 字节）。

    python3 -I generate.py > vectors.json   （需要 `pip install blake3 cryptography`）
"""
import json
import struct

import blake3
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM, ChaCha20Poly1305

TIME = 1_793_347_200
METHODS = {
    "2022-blake3-aes-128-gcm": (16, AESGCM),
    "2022-blake3-aes-256-gcm": (32, AESGCM),
    "2022-blake3-chacha20-poly1305": (32, ChaCha20Poly1305),
}


class Random:
    def __init__(self):
        self.k = 0

    def take(self, n):
        out = bytes((0x10 + self.k + i) % 256 for i in range(n))
        self.k += n
        return out


def subkey(psk, salt):
    return blake3.blake3(psk + salt, derive_key_context="shadowsocks 2022 session subkey").digest(len(psk))


class Sealer:
    def __init__(self, cls, key):
        self.aead, self.n = cls(key), 0

    def seal(self, data):
        out = self.aead.encrypt(self.n.to_bytes(12, "little"), data, None)
        self.n += 1
        return out


def socks(ip, port):
    return b"\x01" + bytes(ip) + struct.pack(">H", port)


cases = []
for method, (key_len, cls) in METHODS.items():
    psk = bytes(range(key_len))
    rnd = Random()
    salt = rnd.take(key_len)
    sealer = Sealer(cls, subkey(psk, salt))
    draw = rnd.take(2)
    padding = 1 + ((draw[0] << 8) | draw[1]) % 900
    host = b"www.example.com"
    variable = b"\x03" + bytes([len(host)]) + host + struct.pack(">H", 443) + struct.pack(">H", padding)
    variable += rnd.take(padding)
    fixed = b"\x00" + struct.pack(">Q", TIME) + struct.pack(">H", len(variable))
    request = salt + sealer.seal(fixed) + sealer.seal(variable)
    request_chunk = sealer.seal(struct.pack(">H", 5)) + sealer.seal(b"hello")

    server_salt = bytes(range(0x80, 0x80 + key_len))
    server = Sealer(cls, subkey(psk, server_salt))
    first = b"world"
    response = server_salt + server.seal(b"\x01" + struct.pack(">Q", TIME) + salt + struct.pack(">H", len(first)))
    response += server.seal(first)
    response += server.seal(struct.pack(">H", 2)) + server.seal(b"!!")

    case = {
        "method": method,
        "psk": psk.hex(),
        "request": request.hex(),
        "requestChunk": request_chunk.hex(),
        "response": response.hex(),
    }
    if cls is AESGCM:
        udp_rnd = Random()
        session = udp_rnd.take(8)
        ecb = Cipher(algorithms.AES(psk), modes.ECB())
        header = session + struct.pack(">Q", 0)
        body = b"\x00" + struct.pack(">Q", TIME) + struct.pack(">H", 0) + socks([192, 0, 2, 53], 53) + b"query"
        enc = ecb.encryptor()
        udp_request = enc.update(header) + enc.finalize()
        udp_request += AESGCM(subkey(psk, session)).encrypt(header[4:16], body, None)
        server_session = bytes(range(0xA0, 0xA8))
        server_header = server_session + struct.pack(">Q", 7)
        server_body = b"\x01" + struct.pack(">Q", TIME) + session + struct.pack(">H", 3) + b"pad"
        server_body += socks([198, 51, 100, 7], 5353) + b"answer"
        enc = ecb.encryptor()
        udp_response = enc.update(server_header) + enc.finalize()
        udp_response += AESGCM(subkey(psk, server_session)).encrypt(server_header[4:16], server_body, None)
        case["udpRequest"] = udp_request.hex()
        case["udpResponse"] = udp_response.hex()
    cases.append(case)

print(json.dumps({
    "source": "generate.py: Python blake3 (official bindings) and cryptography (OpenSSL); SIP022",
    "time": TIME,
    "cases": cases,
}, indent=2))
