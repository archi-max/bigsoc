// SPDX-License-Identifier: ISC
// Testbench: clock/reset, run length from plusargs, trace sink, FSDB dump.
//   +epoch_iters=N   firmware work loop iterations per epoch (8 epochs)
//   +max_cycles=N    hard stop
//   +fsdb=<file>     dump everything (+all: memories, structs, interfaces) to <file>
`timescale 1ns/1ps
module tb_bigsoc;
  import bigsoc_pkg::*;

  logic clk = 1'b0;
  logic rst_n = 1'b0;
  always #5 clk = ~clk;

  logic [31:0]          epoch_iters;
  noc_flit_t            trace_out;
  logic                 trace_out_valid;
  logic [NCL*NT-1:0]    done, trapped;

  bigsoc_top #(.FW("fw.hex")) u_soc (
    .clk            (clk),
    .rst_n          (rst_n),
    .epoch_iters    (epoch_iters),
    .trace_out      (trace_out),
    .trace_out_valid(trace_out_valid),
    .done           (done),
    .trapped        (trapped)
  );

  // Trace sink: counts flits per kind and keeps a running signature.
  longint unsigned cycles, flits;
  logic [511:0]    sig;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cycles <= 0;
      flits  <= 0;
      sig    <= '0;
    end else begin
      cycles <= cycles + 1;
      if (trace_out_valid) begin
        flits <= flits + 1;
        sig   <= {sig[510:0], sig[511]} ^ trace_out;
      end
    end
  end

  int unsigned  max_cycles, iters;
  string        fsdb;
  initial begin
    if (!$value$plusargs("epoch_iters=%d", iters)) iters = 4;
    if (!$value$plusargs("max_cycles=%d", max_cycles)) max_cycles = 10_000_000;
    epoch_iters = iters;
    if ($value$plusargs("fsdb=%s", fsdb)) begin
      $fsdbDumpfile(fsdb);
      $fsdbDumpvars(0, tb_bigsoc, "+all");
    end
    repeat (20) @(posedge clk);
    rst_n = 1'b1;
  end

  // Stop when every core is done or trapped, or at max_cycles.
  int unsigned settle;
  always @(posedge clk) begin
    if (rst_n && (&(done | trapped))) begin
      settle++;
      if (settle == 200) finish_run("all cores finished");
    end
    if (rst_n && cycles >= max_cycles) finish_run("max_cycles");
  end

  task automatic finish_run(string why);
    $display("[bigsoc] %s at %0t: cycles %0d, flits %0d, done %b, trapped %b, sig %h",
             why, $time, cycles, flits, done, trapped, sig[63:0]);
    $finish;
  endtask
endmodule
