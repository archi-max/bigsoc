// SPDX-License-Identifier: ISC
`timescale 1ns/1ps
// SoC level: NCL clusters, a shared mailbox, and the trace funnel.

// 64-word mailbox shared by all clusters (round-robin over their uplinks).
module bigsoc_mailbox
  import bigsoc_pkg::*;
(
  input logic  clk,
  input logic  rst_n,
  mem_if.slave ups [NCL]
);
  logic [NCL-1:0] v, rdy;
  logic [31:0]    addr [NCL], wdata [NCL];
  logic [3:0]     wstrb [NCL];
  logic [31:0]    rdata;
  logic [31:0]    box [64];
  logic [1:0]     last, pick, cur;
  logic           any, busy;

  for (genvar c = 0; c < NCL; c++) begin : g_up
    assign v[c]          = ups[c].valid;
    assign addr[c]       = ups[c].addr;
    assign wdata[c]      = ups[c].wdata;
    assign wstrb[c]      = ups[c].wstrb;
    assign ups[c].ready  = rdy[c];
    assign ups[c].rdata  = rdata;
  end

  always_comb begin
    any  = 1'b0;
    pick = last;
    for (int k = 1; k <= NCL; k++) begin
      automatic int i = (int'(last) + k) % NCL;
      if (!any && v[i] && !rdy[i]) begin
        any  = 1'b1;
        pick = 2'(i);
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rdy  <= '0;
      last <= '0;
      busy <= 1'b0;
    end else begin
      rdy  <= '0;
      busy <= 1'b0;
      if (any && !busy) begin
        last      <= pick;
        busy      <= 1'b1;
        rdy[pick] <= 1'b1;
        rdata     <= box[addr[pick][7:2]];
        for (int b = 0; b < 4; b++)
          if (wstrb[pick][b]) box[addr[pick][7:2]][8*b +: 8] <= wdata[pick][8*b +: 8];
      end
    end
  end
endmodule

// Merges the clusters' flit streams into one FIFO; flits that lose arbitration are dropped.
module bigsoc_funnel
  import bigsoc_pkg::*;
(
  input  logic      clk,
  input  logic      rst_n,
  trace_if.dst      cl_in [NCL],
  output noc_flit_t out,
  output logic      out_valid
);
  logic [NCL-1:0] v;
  noc_flit_t      d [NCL];
  logic [31:0]    lost [NCL];
  logic [1:0]     last, pick;
  logic           any;
  noc_flit_t      head;
  logic           head_v;

  for (genvar c = 0; c < NCL; c++) begin : g_in
    assign v[c] = cl_in[c].valid;
    assign d[c] = cl_in[c].data;
  end

  always_comb begin
    any  = 1'b0;
    pick = last;
    for (int k = 1; k <= NCL; k++) begin
      automatic int i = (int'(last) + k) % NCL;
      if (!any && v[i]) begin
        any  = 1'b1;
        pick = 2'(i);
      end
    end
  end

  bigsoc_fifo #(.T(noc_flit_t), .DEPTH(16)) u_q (
    .clk  (clk),
    .rst_n(rst_n),
    .push (any),
    .din  (d[pick]),
    .pop  (head_v),
    .dout (head),
    .valid(head_v),
    .full (),
    .drops()
  );

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      last      <= '0;
      out_valid <= 1'b0;
      for (int c = 0; c < NCL; c++) lost[c] <= '0;
    end else begin
      if (any) last <= pick;
      for (int c = 0; c < NCL; c++) if (v[c] && !(any && pick == 2'(c))) lost[c] <= lost[c] + 1'b1;
      out_valid <= head_v;
      if (head_v) out <= head;
    end
  end
endmodule

module bigsoc_top
  import bigsoc_pkg::*;
#(
  parameter string FW = "fw.hex"
) (
  input  logic               clk,
  input  logic               rst_n,
  input  logic [31:0]        epoch_iters,
  output noc_flit_t          trace_out,
  output logic               trace_out_valid,
  output logic [NCL*NT-1:0]  done,
  output logic [NCL*NT-1:0]  trapped
);
  // Event source for the clusters' perf counters (one tick every 16 cycles).
  logic [3:0] tick_div;
  logic       tick;
  always_ff @(posedge clk) begin
    if (!rst_n) tick_div <= '0;
    else        tick_div <= tick_div + 1'b1;
  end
  assign tick = tick_div == 4'hF;

  wire [NCL-1:0] ext_evt;
  assign ext_evt[NCL/2-1:0] = {(NCL/2){tick}};

  mem_if up [NCL] (clk);
  trace_if #(.T(noc_flit_t)) cl_trc [NCL] (clk);

  for (genvar c = 0; c < NCL; c++) begin : g_cl
    bigsoc_cluster #(.CL(c), .FW(FW)) u_cluster (
      .clk        (clk),
      .rst_n      (rst_n),
      .epoch_iters(epoch_iters),
      .ext_evt    (ext_evt[c]),
      .up         (up[c]),
      .cl_trc     (cl_trc[c]),
      .done       (done[c*NT +: NT]),
      .trapped    (trapped[c*NT +: NT])
    );
  end

  bigsoc_mailbox u_mbox (
    .clk  (clk),
    .rst_n(rst_n),
    .ups  (up)
  );

  bigsoc_funnel u_funnel (
    .clk      (clk),
    .rst_n    (rst_n),
    .cl_in    (cl_trc),
    .out      (trace_out),
    .out_valid(trace_out_valid)
  );
endmodule
