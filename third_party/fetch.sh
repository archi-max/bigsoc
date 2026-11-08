#!/bin/sh
# SPDX-License-Identifier: ISC
# Fetches picorv32 (ISC, Copyright (C) 2015 Claire Xenia Wolf; YosysHQ/picorv32) at the pinned
# commit into this folder and checks its SHA-256. See NOTICE.
set -eu
cd "$(dirname "$0")"
SHA=0836050971b3c6cdd28ac3b1e5719a67fb645161912bef1e472e63995ceb0622
curl -fsSL -o picorv32.v.tmp https://raw.githubusercontent.com/YosysHQ/picorv32/ef203c2/picorv32.v
if command -v sha256sum >/dev/null 2>&1; then GOT=$(sha256sum picorv32.v.tmp | cut -d' ' -f1); else GOT=$(shasum -a 256 picorv32.v.tmp | cut -d' ' -f1); fi
if [ "$GOT" != "$SHA" ]; then echo "picorv32.v: SHA-256 mismatch ($GOT)" >&2; rm -f picorv32.v.tmp; exit 1; fi
mv picorv32.v.tmp picorv32.v
echo "picorv32.v OK (ef203c2)"
