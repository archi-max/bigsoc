// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
// A cluster of NT tiles: shared RAM + mailbox uplink behind a round-robin arbiter, and the
// trace path (per-tile filter FIFOs -> round-robin mux -> 3-stage flit pipeline).
module bigsoc_cluster
  import bigsoc_pkg::*;
#(
  parameter int    CL        = 0,
  parameter int    SHM_WORDS = 2048,
  parameter string FW        = "fw.hex"
) (
  input  logic          clk,
  input  logic          rst_n,
  input  logic [31:0]   epoch_iters,
  input  logic          ext_evt,
  mem_if.master         up,
  trace_if.src          cl_trc,
  output logic [NT-1:0] done,
  output logic [NT-1:0] trapped
);
  // Board strap pins of the cluster; nothing drives them.
  wire [3:0] cfg_strap;

  mem_if shm [NT] (clk);
  trace_if #(.T(trace_pkt_t)) trc [NT] (clk);

  for (genvar t = 0; t < NT; t++) begin : g_tile
    bigsoc_tile #(.CL(CL), .T(t), .FW(FW)) u_tile (
      .clk        (clk),
      .rst_n      (rst_n),
      .epoch_iters(epoch_iters),
      .ext_evt    (t == 0 ? ext_evt : 1'b0),
      .cfg_strap  (cfg_strap),
      .shm        (shm[t]),
      .trc        (trc[t]),
      .done       (done[t]),
      .trapped    (trapped[t])
    );
  end

  // ---- shared bus ----
  logic [NT-1:0] req_valid, req_ready;
  logic [31:0]   req_addr [NT], req_wdata [NT];
  logic [3:0]    req_wstrb [NT];
  logic [31:0]   shm_rdata;

  for (genvar t = 0; t < NT; t++) begin : g_shm
    assign req_valid[t]  = shm[t].valid;
    assign req_addr[t]   = shm[t].addr;
    assign req_wdata[t]  = shm[t].wdata;
    assign req_wstrb[t]  = shm[t].wstrb;
    assign shm[t].ready  = req_ready[t];
    assign shm[t].rdata  = shm_rdata;
  end

  // The shared RAM was cut to SHM_WORDS; the decode window is still 16 KB (12 index bits).
  bigsoc_shm_arb #(.N(NT), .WORDS(SHM_WORDS), .IDXW(12)) u_arb (
    .clk      (clk),
    .rst_n    (rst_n),
    .req_valid(req_valid),
    .req_addr (req_addr),
    .req_wdata(req_wdata),
    .req_wstrb(req_wstrb),
    .req_ready(req_ready),
    .rdata    (shm_rdata),
    .up       (up)
  );

  // ---- trace path ----
  logic [NT-1:0] f_valid, f_pop;
  trace_pkt_t    f_data [NT];
  logic [15:0]   f_drops [NT];

  for (genvar t = 0; t < NT; t++) begin : g_tfifo
    logic keep;
    // Keep traps and accesses that leave the tile's RAM (MMIO, shared, mailbox).
    always_comb begin
      keep = 1'b0;
      if (trc[t].data.trap) keep = 1'b1;
      else if ((trc[t].data.mem_rmask != 4'h0 || trc[t].data.mem_wmask != 4'h0) && trc[t].data.mem_addr[31:28] != 4'h0)
        keep = 1'b1;
    end
    bigsoc_fifo #(.T(trace_pkt_t), .DEPTH(4)) u_fifo (
      .clk  (clk),
      .rst_n(rst_n),
      .push (trc[t].valid && keep),
      .din  (trc[t].data),
      .pop  (f_pop[t]),
      .dout (f_data[t]),
      .valid(f_valid[t]),
      .full (),
      .drops(f_drops[t])
    );
  end

  logic [1:0]  rr_last, rr_pick;
  logic        rr_any;
  logic [7:0]  seq;
  logic [63:0] ts;
  trace_pkt_t  head;
  flit_kind_e  kind;

  always_comb begin
    rr_any  = 1'b0;
    rr_pick = rr_last;
    for (int k = 1; k <= NT; k++) begin
      automatic int i = (int'(rr_last) + k) % NT;
      if (!rr_any && f_valid[i]) begin
        rr_any  = 1'b1;
        rr_pick = 2'(i);
      end
    end
    for (int t = 0; t < NT; t++) f_pop[t] = rr_any && rr_pick == 2'(t);
  end

  assign head = f_data[rr_pick];

  always_comb begin
    if (head.trap)                       kind = FLIT_TRAP;
    else if (head.mem_addr[31:28] == 4'h1) kind = FLIT_MMIO;
    else if (head.mem_wmask != 4'h0)     kind = FLIT_STORE;
    else                                 kind = FLIT_LOAD;
  end

  noc_flit_t s0, s1, s2;
  logic      s0_v, s1_v, s2_v;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rr_last <= '0;
      seq     <= '0;
      ts      <= '0;
      s0_v    <= 1'b0;
      s1_v    <= 1'b0;
      s2_v    <= 1'b0;
    end else begin
      ts   <= ts + 1'b1;
      s0_v <= rr_any;
      if (rr_any) begin
        rr_last <= rr_pick;
        seq     <= seq + 1'b1;
      end
      s0.hdr.kind  <= kind;
      s0.hdr.cl    <= 2'(CL);
      s0.hdr.tile  <= rr_pick;
      s0.hdr.seq   <= seq;
      s0.hdr.drops <= f_drops[rr_pick];
      s0.ts        <= ts;
      s0.pkt       <= head;
      s0.rsvd      <= '0;
      s0.chk       <= '0;

      s1_v     <= s0_v;
      s1       <= s0;
      s1.chk   <= fold16(s0.pkt);

      s2_v <= s1_v;
      s2   <= s1;
    end
  end

  assign cl_trc.valid = s2_v;
  assign cl_trc.data  = s2;
endmodule
