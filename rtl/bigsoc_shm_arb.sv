// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
// Round-robin arbiter for N requesters onto the cluster's shared RAM (0x2...) and the
// uplink to the SoC mailbox (0x3...).
module bigsoc_shm_arb #(
  parameter int N     = 4,
  parameter int WORDS = 2048,
  parameter int IDXW  = 12
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [N-1:0] req_valid,
  input  logic [31:0] req_addr  [N],
  input  logic [31:0] req_wdata [N],
  input  logic [3:0]  req_wstrb [N],
  output logic [N-1:0] req_ready,
  output logic [31:0] rdata,
  mem_if.master       up
);
  localparam int IW = $clog2(N);
  typedef enum logic [1:0] {IDLE, RAM, UP, RESP} st_e;
  st_e st;
  logic [IW-1:0] cur, last, pick;
  logic          any;
  logic [31:0]   a, wd;
  logic [3:0]    ws;
  logic          ram_ready;
  logic [31:0]   ram_rdata;

  always_comb begin
    any  = 1'b0;
    pick = last;
    for (int k = 1; k <= N; k++) begin
      automatic int i = (int'(last) + k) % N;
      if (!any && req_valid[i]) begin
        any  = 1'b1;
        pick = IW'(i);
      end
    end
  end

  bigsoc_ram #(.WORDS(WORDS), .IDXW(IDXW)) u_smem (
    .clk  (clk),
    .rst_n(rst_n),
    .req  (st == RAM),
    .wstrb(ws),
    .idx  (a[IDXW+1:2]),
    .wdata(wd),
    .rdata(ram_rdata),
    .ready(ram_ready)
  );

  assign up.instr = 1'b0;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st        <= IDLE;
      last      <= '0;
      cur       <= '0;
      req_ready <= '0;
      up.valid  <= 1'b0;
    end else begin
      req_ready <= '0;
      case (st)
        IDLE: if (any) begin
          cur  <= pick;
          last <= pick;
          a    <= req_addr[pick];
          wd   <= req_wdata[pick];
          ws   <= req_wstrb[pick];
          if (req_addr[pick][31:28] == 4'h3) begin
            st       <= UP;
            up.valid <= 1'b1;
            up.addr  <= req_addr[pick];
            up.wdata <= req_wdata[pick];
            up.wstrb <= req_wstrb[pick];
          end else begin
            st <= RAM;
          end
        end
        RAM: if (ram_ready) begin
          rdata          <= ram_rdata;
          req_ready[cur] <= 1'b1;
          st             <= RESP;
        end
        UP: if (up.ready) begin
          up.valid       <= 1'b0;
          rdata          <= up.rdata;
          req_ready[cur] <= 1'b1;
          st             <= RESP;
        end
        RESP: st <= IDLE;
      endcase
    end
  end
endmodule
