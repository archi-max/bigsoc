#!/bin/sh
# SPDX-License-Identifier: MIT
# Builds fw.hex ($readmemh words) from fw.S with GNU binutils for RISC-V (no compiler needed).
#   build.sh [out dir]   RISCV_PREFIX defaults to the first of riscv64-elf-, riscv64-unknown-elf-, riscv32-unknown-elf- found.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE}"
if [ -z "${RISCV_PREFIX:-}" ]; then
  for p in riscv64-elf- riscv64-unknown-elf- riscv32-unknown-elf-; do
    command -v "${p}as" >/dev/null 2>&1 && RISCV_PREFIX=$p && break
  done
fi
: "${RISCV_PREFIX:?no RISC-V binutils found; set RISCV_PREFIX}"
"${RISCV_PREFIX}as" -march=rv32im -mabi=ilp32 -o "$OUT/fw.o" "$HERE/fw.S"
"${RISCV_PREFIX}ld" -m elf32lriscv -T "$HERE/link.ld" -o "$OUT/fw.elf" "$OUT/fw.o"
"${RISCV_PREFIX}objcopy" -O binary "$OUT/fw.elf" "$OUT/fw.bin"
"${RISCV_PREFIX}objdump" -d "$OUT/fw.elf" > "$OUT/fw.dis"
python3 - "$OUT/fw.bin" "$OUT/fw.hex" <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read()
b += b'\0' * (-len(b) % 4)
with open(sys.argv[2], 'w') as f:
    f.write('@0\n')
    for i in range(0, len(b), 4):
        f.write('%08x\n' % struct.unpack_from('<I', b, i)[0])
PY
rm -f "$OUT/fw.o" "$OUT/fw.bin"
echo "fw.hex: $(($(wc -l < "$OUT/fw.hex") - 1)) words"
