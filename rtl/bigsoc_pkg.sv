// bigsoc: a 16-core picorv32 SoC used as a large waveform benchmark.
// SPDX-License-Identifier: ISC
`timescale 1ns/1ps
package bigsoc_pkg;
  localparam int NCL = 4;  // clusters
  localparam int NT  = 4;  // tiles (cores) per cluster

  // One retired instruction, taken from picorv32's RVFI port (385 bits).
  typedef struct packed {
    logic        valid;
    logic [7:0]  core;
    logic [63:0] order;
    logic [31:0] insn;
    logic        trap;
    logic [4:0]  rs1_addr;
    logic [4:0]  rs2_addr;
    logic [4:0]  rd_addr;
    logic [31:0] rs1_rdata;
    logic [31:0] rs2_rdata;
    logic [31:0] rd_wdata;
    logic [31:0] pc_rdata;
    logic [31:0] pc_wdata;
    logic [31:0] mem_addr;
    logic [3:0]  mem_rmask;
    logic [3:0]  mem_wmask;
    logic [31:0] mem_rdata;
    logic [31:0] mem_wdata;
  } trace_pkt_t;

  typedef enum logic [3:0] {
    FLIT_IDLE  = 4'd0,
    FLIT_LOAD  = 4'd1,
    FLIT_STORE = 4'd2,
    FLIT_MMIO  = 4'd3,
    FLIT_TRAP  = 4'd4
  } flit_kind_e;

  typedef struct packed {
    flit_kind_e  kind;
    logic [1:0]  cl;
    logic [1:0]  tile;
    logic [7:0]  seq;
    logic [15:0] drops;
  } flit_hdr_t;  // 32 bits

  // The trace interconnect's flit: header, timestamp, packet, check (512 bits).
  typedef struct packed {
    flit_hdr_t   hdr;
    logic [63:0] ts;
    trace_pkt_t  pkt;
    logic [14:0] rsvd;
    logic [15:0] chk;
  } noc_flit_t;

  // CRC-32 (reflected, poly 0xEDB88320) of one 32-bit word, LSB first.
  function automatic logic [31:0] crc32_word(input logic [31:0] crc, input logic [31:0] data);
    logic [31:0] c;
    c = crc ^ data;
    for (int i = 0; i < 32; i++) c = c[0] ? (c >> 1) ^ 32'hEDB8_8320 : (c >> 1);
    return c;
  endfunction

  // XOR-fold of a packet into 16 bits (the flit check field).
  function automatic logic [15:0] fold16(input trace_pkt_t p);
    logic [399:0] w;
    logic [15:0] f;
    w = 400'(p);
    f = '0;
    for (int i = 0; i < 25; i++) f ^= w[16*i +: 16];
    return f;
  endfunction
endpackage
