// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
// Small FIFO of T. Storage is not reset; a push when full is dropped and counted.
module bigsoc_fifo #(
  parameter type T     = logic [31:0],
  parameter int  DEPTH = 4
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        push,
  input  T            din,
  input  logic        pop,
  output T            dout,
  output logic        valid,
  output logic        full,
  output logic [15:0] drops
);
  localparam int AW = $clog2(DEPTH);
  T q [DEPTH];
  logic [AW:0] wp, rp;

  assign valid = wp != rp;
  assign full  = (wp[AW] != rp[AW]) && (wp[AW-1:0] == rp[AW-1:0]);
  assign dout  = q[rp[AW-1:0]];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wp    <= '0;
      rp    <= '0;
      drops <= '0;
    end else begin
      if (push && !full) begin
        q[wp[AW-1:0]] <= din;
        wp <= wp + 1'b1;
      end else if (push) begin
        drops <= drops + 1'b1;
      end
      if (pop && valid) rp <= rp + 1'b1;
    end
  end
endmodule
