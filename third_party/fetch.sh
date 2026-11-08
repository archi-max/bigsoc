#!/bin/sh
# Fetches picorv32 (ISC, YosysHQ/picorv32) at the pinned commit into this folder.
set -eu
cd "$(dirname "$0")"
curl -fsSL -o picorv32.v https://raw.githubusercontent.com/YosysHQ/picorv32/ef203c2/picorv32.v
