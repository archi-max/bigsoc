# bigsoc

A 16-core RISC-V SoC in SystemVerilog, written to produce large, realistic waveform dumps for testing waveform viewers and driver tracing (finding where an x/z value comes from). It is built around picorv32 (ISC, YosysHQ/picorv32 at ef203c2, fetched by `third_party/fetch.sh`, not vendored). Everything else here is ISC.

## Design

```
tb_bigsoc
└─ u_soc (bigsoc_top)
   ├─ g_cl[0..3].u_cluster (bigsoc_cluster)              generate, 4 clusters
   │  ├─ g_tile[0..3].u_tile (bigsoc_tile)                generate, 4 tiles each
   │  │  ├─ u_cpu (picorv32, RV32IM, RVFI on)             + genblk1.pcpi_mul, genblk2.pcpi_div
   │  │  ├─ cpu (mem_if)                                  interface instance, core bus
   │  │  ├─ u_ram (bigsoc_ram, 4096 x 32, $readmemh)      firmware image, rest never initialised
   │  │  └─ MMIO: CRC accelerator (crc_q, no reset), perf counter, STATUS, TRACE_OUT, DONE
   │  ├─ shm[0..3] (mem_if), trc[0..3] (trace_if #(trace_pkt_t))
   │  ├─ u_arb (bigsoc_shm_arb): round robin -> u_smem (2048 x 32) or the mailbox uplink
   │  ├─ g_tfifo[0..3].u_fifo (bigsoc_fifo #(.T(trace_pkt_t)))   per-tile trace filter FIFOs
   │  └─ round-robin mux -> s0 -> s1 (fold16 check) -> s2: noc_flit_t (512-bit packed struct)
   ├─ up[0..3] (mem_if) -> u_mbox (bigsoc_mailbox, 64 words)
   └─ u_funnel (bigsoc_funnel): 4 flit streams -> u_q (bigsoc_fifo #(noc_flit_t), 16 deep) -> trace_out
```

`trace_pkt_t` (385 bits) is one retired instruction from the RVFI port; `noc_flit_t` (512 bits) is
header + timestamp + packet + check. Firmware (`fw/fw.S`, assembled with GNU binutils only, no
compiler) runs 8 epochs of `epoch_iters` work iterations per core: LCG fill, CRC through the
accelerator, 4x4 matrix multiply (MUL), insertion sort, DIVU/REMU, 16 pushes into a ring in
cluster shared RAM with read-back, and an end-of-epoch report to TRACE_OUT and the mailbox.

## X sources (what trace-X chases)

| id | kind | where | when it shows |
|----|------|-------|---------------|
| X1 | unreset flop | `u_tile.crc_q` (CRC state has no reset); tile 1 skips CRC_INIT in epoch 0 | x from t=0 to the epoch-1 init; CRC_RES read, `cpuregs[7]`, mailbox store at the end of epoch 0 |
| X2 | uninitialised memory read | tile 2 sums a calibration table at 0x3400 (`u_ram.mem[3328..]`) in epoch 2 | `u_ram.rdata`, `cpuregs[6]`, then `cpuregs[26]` (s10) x for epoch 2 |
| X3 | undriven net | `u_soc.ext_evt[3:2]` never assigned; clusters 2/3 tile 0 perf counter adds it once enabled (epoch 1) | `perf_cnt` x from epoch 1 on; mailbox words 8, 12 |
| X3b | floating pins | `u_cluster.cfg_strap` declared, never driven | STATUS reads (`mmio_rdata` = 000000z0) |
| X4 | out-of-range array read, mid-run, through mux + pipeline | ring index masked with 1023 instead of 511; tile 3's ring runs past the 2048-word shared RAM (decoder still has 12 index bits) | `u_smem.rdata` / `u_arb.rdata` x, `rvfi_mem_rdata`, `pkt`, FIFO, flit `s2`, funnel, `trace_out`, `sig`; in windows of 32 iterations out of every 64 |
| X5 | x program counter | core 0x12 (cluster 1, tile 2) jumps through a handler table at 0x3800 that nothing writes, in epoch 7 | `cpuregs[7]`, `reg_pc`, `mem_addr` go x; the unmapped fetch reads 0 and the core traps |
| X0 | unreset pipeline data | flit pipeline `s0..s2` data before the first valid flit | first microsecond |

Stores to fresh shared-RAM words also return x read data (the RAM reads the old word); that is
benign and shows in `u_arb.rdata`. `u_mbox.cur` is declared and never assigned (an incidental
undriven signal, listed in `undriven.txt`).

## Files

- `rtl/`: the design and the testbench (`tb_bigsoc.sv`).
- `fw/`: hand-written RV32IM firmware (`fw.S`, `link.ld`). `fw/build.sh` builds `fw.hex` with GNU binutils for RISC-V, no compiler needed; `RISCV_PREFIX` picks the toolchain. A prebuilt `fw.hex` is included.
- `third_party/fetch.sh`: fetches `picorv32.v` at the pinned commit.

## Running

Testbench plusargs:
- `+epoch_iters=N`: work-loop iterations per epoch (8 epochs).
- `+max_cycles=N`: hard stop.
- `+fsdb=<file>`: dump everything (memories, structs, interfaces) to an FSDB file.

The dumps we use (145 MB, 1.7 GB and 10 GB) were made with a commercial SystemVerilog simulator and `+fsdb`. The design uses interfaces, packed structs and type parameters, so it needs a simulator with good SystemVerilog support.

## License

ISC, Copyright (c) 2026 archi-max (see `LICENSE`); picorv32 is ISC, Copyright (C) 2015 Claire Xenia Wolf.
