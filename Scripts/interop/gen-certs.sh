#!/usr/bin/env bash
# 生成互通测试用的 CA 与服务端证书（docs/13 §3.1）：每次运行重新生成，私钥不入库。
# 服务端证书的名称为 interop.example.com 与 127.0.0.1。
set -euo pipefail
out="${1:?usage: gen-certs.sh <dir>}"
mkdir -p "$out"
cd "$out"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 \
  -subj "/CN=Aether Interop Test CA" -keyout ca.key -out ca.pem 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -subj "/CN=interop.example.com" -keyout server.key -out server.csr 2>/dev/null
printf 'subjectAltName=DNS:interop.example.com,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n' > server.ext
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 2 \
  -extfile server.ext -out server.pem 2>/dev/null
rm -f server.csr server.ext ca.srl
echo "certificates in $out"
