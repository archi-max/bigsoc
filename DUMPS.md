# Dumps

How the three bigsoc waveform dumps used in our viewer benchmarks were made, so they can be rebuilt
and checked. Each is a full-design FSDB dump of the same testbench; only the run length differs.

| name  | plusargs                                        | cycles     | sim end time        | size (bytes)   | sha256 |
|-------|-------------------------------------------------|-----------:|---------------------|---------------:|--------|
| small | `+epoch_iters=5   +max_cycles=20000000`         |    545,697 |   5,457,175,000 ps  |    144,772,988 | `bb819da39152f9281503db43321b746c6bd5a159509d6737871cd1601b680087` |
| big   | `+epoch_iters=60  +max_cycles=20000000`         |  6,484,877 |  64,848,975,000 ps  |  1,717,745,246 | `9a196c2ba21079f1bcea096aa0ee64e36ec3a22619351032dc3acd8e41a2911a` |
| huge  | `+epoch_iters=350 +max_cycles=60000000`         | 37,736,668 | 377,366,885,000 ps  | 10,018,099,430 | `69eb0b8ff59d652911de231dde6fbbd47eb8c041937f70cae2b7247f333f377d` |

"cycles" and "sim end time" are what the testbench prints when every core has finished
(`[bigsoc] all cores finished at <time>: cycles <n>, ...`). `+max_cycles` is only a safety stop;
none of the three runs reached it. The design and firmware are those of this repository at the
commit that adds this file, with picorv32 at `ef203c2` (fetched by `third_party/fetch.sh`).

## Tools

- Simulator: Synopsys VCS W-2024.09 (Full64).
- Dumper: the FSDB dumper that ships with Verdi W-2024.09, enabled with `-kdb -debug_access+all`.
- The FSDB files themselves are not in this repository (they are 0.14–10 GB).

## Build

```sh
sh third_party/fetch.sh                       # picorv32.v at ef203c2, SHA-256 checked
export PICORV32=$PWD/third_party/picorv32.v
export R=$PWD/rtl
mkdir -p run && cd run && cp ../fw/fw.hex .   # the testbench loads fw.hex from the run directory
vcs -full64 -sverilog -kdb -debug_access+all +lint=TFIPC-L \
  +define+RISCV_FORMAL -top tb_bigsoc -o simv -l compile.log \
  "$PICORV32" "$R/bigsoc_pkg.sv" "$R/bigsoc_if.sv" "$R/bigsoc_ram.sv" "$R/bigsoc_fifo.sv" \
  "$R/bigsoc_tile.sv" "$R/bigsoc_shm_arb.sv" "$R/bigsoc_cluster.sv" "$R/bigsoc_soc.sv" "$R/tb_bigsoc.sv"
```

`+define+RISCV_FORMAL` turns on picorv32's RVFI port, which the trace path uses.

## Run

```sh
./simv +epoch_iters=5   +max_cycles=20000000 +fsdb=small.fsdb -l small.log
./simv +epoch_iters=60  +max_cycles=20000000 +fsdb=big.fsdb   -l big.log
./simv +epoch_iters=350 +max_cycles=60000000 +fsdb=huge.fsdb  -l huge.log
```

`+fsdb=<file>` dumps the whole design from time 0 (`$fsdbDumpvars(0, tb_bigsoc, "+all")`: memories,
packed structs and interfaces included). Without `+fsdb` nothing is dumped.

## Checking a rebuilt dump

The run is deterministic (no random seeds, no wall-clock input), so the cycle count and end time
above should match exactly. The FSDB bytes can differ between dumper versions and settings, so
compare the sha256 only against a dump made with the same tool version; otherwise compare the
`[bigsoc]` summary line and the signal values.

## Open tools

There is no open-tools route yet: the testbench only has the FSDB dump (`+fsdb`), which needs the
commercial simulator and its dumper. A `$dumpfile`/`$dumpvars` (VCD/FST) option, and a check that an
open-source simulator builds the design (it uses interfaces, packed structs and type parameters),
are planned but not done.

## FST copy used for the GTKWave and VaporView comparison

`small.fst` was converted from `small.fsdb` by exporting VCD with the dumper's own `fsdb2vcd` and
streaming it into `vcd2fst` from GTKWave 3.3.116 (default settings, LZ4), with no VCD written to disk.
Because it goes through VCD, packed structs come out split into their fields.
