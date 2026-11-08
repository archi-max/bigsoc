// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
// Single-port word RAM, one-cycle ready pulse. IDXW address bits index WORDS entries.
module bigsoc_ram #(
  parameter int    WORDS = 4096,
  parameter int    IDXW  = 12,
  parameter string INIT  = ""
) (
  input  logic            clk,
  input  logic            rst_n,
  input  logic            req,
  input  logic [3:0]      wstrb,
  input  logic [IDXW-1:0] idx,
  input  logic [31:0]     wdata,
  output logic [31:0]     rdata,
  output logic            ready
);
  logic [31:0] mem [0:WORDS-1];

  initial if (INIT != "") $readmemh(INIT, mem);

  // always (not always_ff): the initial $readmemh also writes mem.
  always @(posedge clk) begin
    if (!rst_n) begin
      ready <= 1'b0;
    end else begin
      ready <= 1'b0;
      if (req && !ready) begin
        ready <= 1'b1;
        rdata <= mem[idx];
        for (int b = 0; b < 4; b++)
          if (wstrb[b]) mem[idx][8*b +: 8] <= wdata[8*b +: 8];
      end
    end
  end
endmodule
