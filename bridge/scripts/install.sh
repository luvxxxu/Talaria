#!/bin/zsh
# Build talaria-bridge in release mode, sign it, and install it where the
# bot's macOS user can run it (default /Users/Shared/talaria).
#
#   TALARIA_INSTALL_DIR   where to install (default /Users/Shared/talaria)
#   TALARIA_SIGN_IDENTITY codesign identity. Default "-" (ad-hoc): macOS then
#                         forgets the Full Disk Access / Automation grants after
#                         every rebuild. A self-signed "Code Signing" certificate
#                         from Keychain Access keeps them across rebuilds.
set -euo pipefail

cd "${0:A:h}/.."
install_dir="${TALARIA_INSTALL_DIR:-/Users/Shared/talaria}"
identity="${TALARIA_SIGN_IDENTITY:--}"

swift build -c release
binary=".build/release/talaria-bridge"
codesign --force --sign "$identity" --identifier dev.talaria.bridge "$binary"

mkdir -p "$install_dir/bin"
install -m 755 "$binary" "$install_dir/bin/talaria-bridge"
install -m 644 bridge.env.example "$install_dir/bridge.env.example"
chmod 755 "$install_dir"

echo "installed $("$install_dir/bin/talaria-bridge" --version) to $install_dir/bin/talaria-bridge"
codesign -dv "$install_dir/bin/talaria-bridge" 2>&1 | grep -E "^(Identifier|Signature)"
