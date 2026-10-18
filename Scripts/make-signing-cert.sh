#!/bin/zsh
# @author ixxxxoooo
# 创建本地自签代码签名证书(免费、无需开发者账号),让每次重编译的签名身份保持不变,
# 这样辅助功能、屏幕录制等 TCC 权限不会反复失效。已存在则直接退出。
# 用法: Scripts/make-signing-cert.sh [证书名称]   (默认 "OhMyAgent Local Dev",有效期 3650 天)
set -euo pipefail

NAME="${1:-OhMyAgent Local Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "证书已存在:$NAME"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS="oma-$(uuidgen)"

cat > "$WORK/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/openssl.cnf" 2>/dev/null
# macOS 的 security 只认旧式 PKCS12 加密,需 -legacy(LibreSSL 无此参数时回退)
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -passout "pass:$PASS" -out "$WORK/id.p12" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
       -name "$NAME" -passout "pass:$PASS" -out "$WORK/id.p12"

security import "$WORK/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
# 设为"始终信任代码签名"(会弹出系统密码框)
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo "已创建并信任证书:$NAME"
security find-identity -v -p codesigning | grep "\"$NAME\"" || echo "警告:尚未出现在有效身份列表,请在钥匙串访问中确认已设为始终信任"
