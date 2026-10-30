#!/usr/bin/env python3
"""Shadowsocks AEAD 测试向量生成器（docs/06 §8.4，shadowsocks.org AEAD 规范）。

独立于 Swift 实现：用 Python `cryptography`（OpenSSL）的 AES-GCM、ChaCha20-Poly1305 与 HKDF-SHA1，
按规范逐字构造 TCP 流与 UDP 包。输出 aead.json；salt 与密码固定，结果可复现。

    python3 -I generate.py > aead.json
"""
import hashlib
import json

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM, ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

METHODS = {
    "aes-128-gcm": (16, AESGCM),
    "aes-256-gcm": (32, AESGCM),
    "chacha20-ietf-poly1305": (32, ChaCha20Poly1305),
}
PASSWORD = b"aether-test-password"


def bytes_to_key(password, length):
    result, previous = b"", b""
    while len(result) < length:
        previous = hashlib.md5(previous + password).digest()
        result += previous
    return result[:length]


def subkey(master, salt):
    return HKDF(algorithm=hashes.SHA1(), length=len(master), salt=salt, info=b"ss-subkey").derive(master)


def nonce(counter):
    return counter.to_bytes(12, "little")


def stream(method, salt, payloads):
    """salt ‖ 每个载荷一块（载荷 ≤ 0x3FFF）。"""
    key_len, cls = METHODS[method]
    aead = cls(subkey(bytes_to_key(PASSWORD, key_len), salt))
    out, counter = salt, 0
    for payload in payloads:
        assert len(payload) <= 0x3FFF
        out += aead.encrypt(nonce(counter), len(payload).to_bytes(2, "big"), None)
        out += aead.encrypt(nonce(counter + 1), payload, None)
        counter += 2
    return out


def socks_domain(host, port):
    return b"\x03" + bytes([len(host)]) + host + port.to_bytes(2, "big")


def udp(method, salt, address, payload):
    key_len, cls = METHODS[method]
    aead = cls(subkey(bytes_to_key(PASSWORD, key_len), salt))
    return salt + aead.encrypt(nonce(0), address + payload, None)


cases = []
for method, (key_len, _) in METHODS.items():
    client_salt = bytes(range(1, key_len + 1))
    server_salt = bytes(range(0x80, 0x80 + key_len))
    header = socks_domain(b"www.example.com", 443)
    # 客户端：首块只含目标地址（连接时立即发送），第二块是 "hello"。
    request = stream(method, client_salt, [header, b"hello"])
    # 服务端响应："world" 与一个 0x3FFF 字节的满块。
    big = bytes(i % 251 for i in range(0x3FFF))
    response = stream(method, server_salt, [b"world", big])
    # UDP：发往 192.0.2.53:53 的载荷，以及来自 198.51.100.7:5353 的回包。
    udp_request = udp(method, client_salt, b"\x01" + bytes([192, 0, 2, 53]) + (53).to_bytes(2, "big"), b"query")
    udp_response = udp(
        method, server_salt, b"\x01" + bytes([198, 51, 100, 7]) + (5353).to_bytes(2, "big"), b"answer")
    cases.append({
        "method": method,
        "masterKey": bytes_to_key(PASSWORD, key_len).hex(),
        "clientSalt": client_salt.hex(),
        "serverSalt": server_salt.hex(),
        "request": request.hex(),
        "response": response.hex(),
        "udpRequest": udp_request.hex(),
        "udpResponse": udp_response.hex(),
    })

print(json.dumps({
    "source": "generate.py: Python cryptography (OpenSSL) AES-GCM, ChaCha20-Poly1305, HKDF-SHA1; shadowsocks.org AEAD spec",
    "password": PASSWORD.decode(),
    "cases": cases,
}, indent=2))
