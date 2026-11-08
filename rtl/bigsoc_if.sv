// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
// picorv32-style memory bus (valid/ready, byte strobes).
interface mem_if (input logic clk);
  logic        valid;
  logic        instr;
  logic        ready;
  logic [31:0] addr;
  logic [31:0] wdata;
  logic [3:0]  wstrb;
  logic [31:0] rdata;
  modport master (output valid, instr, addr, wdata, wstrb, input ready, rdata);
  modport slave  (input valid, instr, addr, wdata, wstrb, output ready, rdata);
endinterface

// A valid-qualified stream of T (trace packets, NoC flits).
interface trace_if #(parameter type T = logic [31:0]) (input logic clk);
  logic valid;
  T     data;
  modport src (output valid, data);
  modport dst (input valid, data);
endinterface
