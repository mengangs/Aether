#!/usr/bin/env python3
"""VMess AEAD 测试向量生成器（docs/06 §8.4，xtls.github.io VMess 协议文档与 v2fly vmess/aead）。

独立于 Swift 实现：用 Python `cryptography`（OpenSSL）的 AES-ECB / AES-GCM / ChaCha20-Poly1305、
hashlib、zlib.crc32 按协议逐字构造。时间与随机字节固定，结果可复现：

- 随机字节流：第 k 次取出的字节为 (0x10 + k) % 256，按 Swift 实现中的调用顺序取用
  （会话 33 字节 → AuthID 随机数 4 字节 → 连接 nonce 8 字节 → 填充长度 1 字节 → 填充）。

    python3 -I generate.py > aead.json
"""
import hashlib
import hmac as std_hmac
import json
import struct
import uuid as uuidlib
import zlib

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM, ChaCha20Poly1305

UUID = "b831381d-6324-4d53-ad4f-8cda48b30811"
TIME = 1_793_347_200


class Random:
    def __init__(self):
        self.k = 0

    def take(self, n):
        out = bytes((0x10 + self.k + i) % 256 for i in range(n))
        self.k += n
        return out


def sha256(data):
    return hashlib.sha256(data).digest()


def hmac_with(hash_fn, key, message):
    if len(key) > 64:
        key = hash_fn(key)
    key = key + b"\x00" * (64 - len(key))
    inner = hash_fn(bytes(b ^ 0x36 for b in key) + message)
    return hash_fn(bytes(b ^ 0x5C for b in key) + inner)


def kdf(key, *path):
    fn = sha256
    for element in [b"VMess AEAD KDF", *path]:
        fn = (lambda parent, k: (lambda m: hmac_with(parent, k, m)))(fn, element)
    return fn(key)


def kdf16(key, *path):
    return kdf(key, *path)[:16]


def fnv1a(data):
    h = 0x811C9DC5
    for b in data:
        h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF
    return h


def aes_block(key, block):
    enc = Cipher(algorithms.AES(key), modes.ECB()).encryptor()
    return enc.update(block) + enc.finalize()


def chacha_key(key):
    first = hashlib.md5(key).digest()
    return first + hashlib.md5(first).digest()


uuid_bytes = uuidlib.UUID(UUID).bytes
cmd_key = hashlib.md5(uuid_bytes + b"c48619fe-8f02-49e0-b9e9-edf763e17e21").digest()
SECURITY = {"aes-128-gcm": 0x03, "chacha20-poly1305": 0x04, "none": 0x05}


def header_case(security):
    rnd = Random()
    session = rnd.take(33)
    req_key, req_iv, resp_auth = session[:16], session[16:32], session[32]
    # AuthID
    plain = struct.pack(">Q", TIME) + rnd.take(4)
    plain += struct.pack(">I", zlib.crc32(plain) & 0xFFFFFFFF)
    auth_id = aes_block(kdf16(cmd_key, b"AES Auth ID Encryption"), plain)
    nonce = rnd.take(8)
    padding = rnd.take(1)[0] & 0x0F
    instruction = bytes([1]) + req_iv + req_key + bytes([resp_auth, 0x01, (padding << 4) | SECURITY[security], 0, 1])
    host = b"www.example.com"
    instruction += struct.pack(">H", 443) + bytes([2, len(host)]) + host + rnd.take(padding)
    instruction += struct.pack(">I", fnv1a(instruction))
    length_key = kdf16(cmd_key, b"VMess Header AEAD Key_Length", auth_id, nonce)
    length_iv = kdf(cmd_key, b"VMess Header AEAD Nonce_Length", auth_id, nonce)[:12]
    sealed_length = AESGCM(length_key).encrypt(length_iv, struct.pack(">H", len(instruction)), auth_id)
    payload_key = kdf16(cmd_key, b"VMess Header AEAD Key", auth_id, nonce)
    payload_iv = kdf(cmd_key, b"VMess Header AEAD Nonce", auth_id, nonce)[:12]
    sealed_payload = AESGCM(payload_key).encrypt(payload_iv, instruction, auth_id)
    header = auth_id + sealed_length + nonce + sealed_payload

    # 请求方向的数据块："hello" 与结束块。
    def seal_chunks(key, iv, chunks):
        out = b""
        for count, data in enumerate(chunks):
            if security == "none":
                out += struct.pack(">H", len(data)) + data
                continue
            nonce12 = struct.pack(">H", count) + iv[2:12]
            aead = AESGCM(key) if security == "aes-128-gcm" else ChaCha20Poly1305(chacha_key(key))
            sealed = aead.encrypt(nonce12, data, None)
            out += struct.pack(">H", len(sealed)) + sealed
        return out

    request_body = seal_chunks(req_key, req_iv, [b"hello", b""])
    # 服务端响应：AEAD 响应头（响应认证字节、选项 0、命令 0、命令长度 0）+ "world" + 结束块。
    resp_key, resp_iv = sha256(req_key)[:16], sha256(req_iv)[:16]
    resp_header = bytes([resp_auth, 0, 0, 0])
    sealed_resp_len = AESGCM(kdf16(resp_key, b"AEAD Resp Header Len Key")).encrypt(
        kdf(resp_iv, b"AEAD Resp Header Len IV")[:12], struct.pack(">H", len(resp_header)), None)
    sealed_resp = AESGCM(kdf16(resp_key, b"AEAD Resp Header Key")).encrypt(
        kdf(resp_iv, b"AEAD Resp Header IV")[:12], resp_header, None)
    response = sealed_resp_len + sealed_resp + seal_chunks(resp_key, resp_iv, [b"world", b""])
    return {
        "security": security,
        "header": header.hex(),
        "requestBody": request_body.hex(),
        "response": response.hex(),
    }


print(json.dumps({
    "source": "generate.py: Python cryptography (OpenSSL) AES-ECB/AES-GCM/ChaCha20-Poly1305, hashlib, zlib; VMess AEAD",
    "uuid": UUID,
    "time": TIME,
    "commandKey": cmd_key.hex(),
    "kdf": {
        "path1": kdf(cmd_key, b"AES Auth ID Encryption").hex(),
        "path3": kdf(b"key", b"a", b"bb", b"c" * 70).hex(),
    },
    "cases": [header_case(s) for s in SECURITY],
}, indent=2))
