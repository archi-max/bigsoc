// SPDX-License-Identifier: ISC
`timescale 1ns/1ps
// One core tile: picorv32 (RV32IM, RVFI on), 16 KB local RAM, MMIO block with a CRC
// accelerator and a perf counter, and a port to the cluster's shared bus.
//
// Memory map:  0x0000_0000-0x0000_3FFF local RAM
//              0x1000_0000              MMIO (see reg_idx below)
//              0x2000_0000              cluster shared RAM   (via shm)
//              0x3000_0000              SoC mailbox          (via shm)
module bigsoc_tile
  import bigsoc_pkg::*;
#(
  parameter int    CL        = 0,
  parameter int    T         = 0,
  parameter int    RAM_WORDS = 4096,
  parameter string FW        = "fw.hex"
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [31:0] epoch_iters,
  input  logic        ext_evt,
  input  logic [3:0]  cfg_strap,
  mem_if.master       shm,
  trace_if.src        trc,
  output logic        done,
  output logic        trapped
);
  mem_if cpu (clk);

  // ---- RVFI ----
  logic        rvfi_valid, rvfi_trap, rvfi_halt, rvfi_intr;
  logic [63:0] rvfi_order;
  logic [31:0] rvfi_insn;
  logic [1:0]  rvfi_mode, rvfi_ixl;
  logic [4:0]  rvfi_rs1_addr, rvfi_rs2_addr, rvfi_rd_addr;
  logic [31:0] rvfi_rs1_rdata, rvfi_rs2_rdata, rvfi_rd_wdata;
  logic [31:0] rvfi_pc_rdata, rvfi_pc_wdata;
  logic [31:0] rvfi_mem_addr, rvfi_mem_rdata, rvfi_mem_wdata;
  logic [3:0]  rvfi_mem_rmask, rvfi_mem_wmask;

  picorv32 #(
    .ENABLE_COUNTERS     (1),
    .ENABLE_REGS_DUALPORT(1),
    .BARREL_SHIFTER      (1),
    .COMPRESSED_ISA      (0),
    .CATCH_MISALIGN      (1),
    .CATCH_ILLINSN       (1),
    .ENABLE_MUL          (0),
    .ENABLE_FAST_MUL     (1),
    .ENABLE_DIV          (1),
    .ENABLE_IRQ          (0),
    .PROGADDR_RESET      (32'h0000_0000),
    .STACKADDR           (32'h0000_3000)
  ) u_cpu (
    .clk         (clk),
    .resetn      (rst_n),
    .trap        (trapped),
    .mem_valid   (cpu.valid),
    .mem_instr   (cpu.instr),
    .mem_ready   (cpu.ready),
    .mem_addr    (cpu.addr),
    .mem_wdata   (cpu.wdata),
    .mem_wstrb   (cpu.wstrb),
    .mem_rdata   (cpu.rdata),
    .mem_la_read (),
    .mem_la_write(),
    .mem_la_addr (),
    .mem_la_wdata(),
    .mem_la_wstrb(),
    .pcpi_valid  (),
    .pcpi_insn   (),
    .pcpi_rs1    (),
    .pcpi_rs2    (),
    .pcpi_wr     (1'b0),
    .pcpi_rd     (32'h0),
    .pcpi_wait   (1'b0),
    .pcpi_ready  (1'b0),
    .irq         (32'h0),
    .eoi         (),
    .rvfi_valid     (rvfi_valid),
    .rvfi_order     (rvfi_order),
    .rvfi_insn      (rvfi_insn),
    .rvfi_trap      (rvfi_trap),
    .rvfi_halt      (rvfi_halt),
    .rvfi_intr      (rvfi_intr),
    .rvfi_mode      (rvfi_mode),
    .rvfi_ixl       (rvfi_ixl),
    .rvfi_rs1_addr  (rvfi_rs1_addr),
    .rvfi_rs2_addr  (rvfi_rs2_addr),
    .rvfi_rs1_rdata (rvfi_rs1_rdata),
    .rvfi_rs2_rdata (rvfi_rs2_rdata),
    .rvfi_rd_addr   (rvfi_rd_addr),
    .rvfi_rd_wdata  (rvfi_rd_wdata),
    .rvfi_pc_rdata  (rvfi_pc_rdata),
    .rvfi_pc_wdata  (rvfi_pc_wdata),
    .rvfi_mem_addr  (rvfi_mem_addr),
    .rvfi_mem_rmask (rvfi_mem_rmask),
    .rvfi_mem_wmask (rvfi_mem_wmask),
    .rvfi_mem_rdata (rvfi_mem_rdata),
    .rvfi_mem_wdata (rvfi_mem_wdata),
    .rvfi_csr_mcycle_rmask  (),
    .rvfi_csr_mcycle_wmask  (),
    .rvfi_csr_mcycle_rdata  (),
    .rvfi_csr_mcycle_wdata  (),
    .rvfi_csr_minstret_rmask(),
    .rvfi_csr_minstret_wmask(),
    .rvfi_csr_minstret_rdata(),
    .rvfi_csr_minstret_wdata(),
    .trace_valid (),
    .trace_data  ()
  );

  // ---- address decode ----
  typedef enum logic [1:0] {SEL_NONE, SEL_RAM, SEL_MMIO, SEL_SHM} sel_e;
  sel_e sel;
  always_comb begin
    if (cpu.addr < 32'h0000_4000)                              sel = SEL_RAM;
    else if (cpu.addr[31:28] == 4'h1)                          sel = SEL_MMIO;
    else if (cpu.addr[31:28] == 4'h2 || cpu.addr[31:28] == 4'h3) sel = SEL_SHM;
    else                                                       sel = SEL_NONE;
  end

  // ---- local RAM (firmware image; the rest of it is never initialised) ----
  logic        ram_ready;
  logic [31:0] ram_rdata;
  bigsoc_ram #(.WORDS(RAM_WORDS), .IDXW(12), .INIT(FW)) u_ram (
    .clk  (clk),
    .rst_n(rst_n),
    .req  (cpu.valid && sel == SEL_RAM),
    .wstrb(cpu.wstrb),
    .idx  (cpu.addr[13:2]),
    .wdata(cpu.wdata),
    .rdata(ram_rdata),
    .ready(ram_ready)
  );

  // ---- MMIO ----
  logic        mmio_ready;
  logic [31:0] mmio_rdata;
  logic [31:0] sw_evt_q, perf_cnt, cycle_cnt;
  logic        perf_en;
  logic [31:0] crc_q;
  logic        err_ready;
  logic        mmio_req, mmio_we;
  logic [5:0]  reg_idx;

  assign mmio_req = cpu.valid && sel == SEL_MMIO && !mmio_ready;
  assign mmio_we  = mmio_req && |cpu.wstrb;
  assign reg_idx  = cpu.addr[7:2];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mmio_ready <= 1'b0;
      perf_en    <= 1'b0;
      perf_cnt   <= '0;
      cycle_cnt  <= '0;
      sw_evt_q   <= '0;
      done       <= 1'b0;
    end else begin
      cycle_cnt  <= cycle_cnt + 1'b1;
      mmio_ready <= mmio_req;
      if (perf_en) perf_cnt <= perf_cnt + 32'(rvfi_valid) + 32'(ext_evt);
      if (mmio_req) begin
        case (reg_idx)
          6'd0:    mmio_rdata <= {24'h0, 4'(CL), 4'(T)};
          6'd1:    mmio_rdata <= epoch_iters;
          6'd5:    mmio_rdata <= crc_q;
          6'd7:    mmio_rdata <= perf_cnt;
          6'd9:    mmio_rdata <= {24'h0, cfg_strap, 2'b00, perf_en, done};
          6'd10:   mmio_rdata <= cycle_cnt;
          default: mmio_rdata <= 32'h0;
        endcase
        if (mmio_we) begin
          case (reg_idx)
            6'd2:    sw_evt_q <= cpu.wdata;
            6'd6:    perf_en  <= cpu.wdata[0];
            6'd8:    done     <= 1'b1;
            default: ;
          endcase
        end
      end
    end
  end

  // CRC accelerator. Its state has no reset: firmware writes CRC_INIT before use.
  always_ff @(posedge clk) begin
    if (mmio_we && reg_idx == 6'd4)      crc_q <= 32'hFFFF_FFFF;
    else if (mmio_we && reg_idx == 6'd3) crc_q <= crc32_word(crc_q, cpu.wdata);
  end

  // Unmapped addresses answer with zero (a bus error in a real SoC).
  always_ff @(posedge clk) begin
    if (!rst_n) err_ready <= 1'b0;
    else        err_ready <= cpu.valid && sel == SEL_NONE && !err_ready;
  end

  // ---- shared bus ----
  assign shm.valid = cpu.valid && sel == SEL_SHM;
  assign shm.instr = cpu.instr;
  assign shm.addr  = cpu.addr;
  assign shm.wdata = cpu.wdata;
  assign shm.wstrb = cpu.wstrb;

  always_comb begin
    if (sel == SEL_RAM) begin
      cpu.ready = ram_ready;
      cpu.rdata = ram_rdata;
    end else if (sel == SEL_MMIO) begin
      cpu.ready = mmio_ready;
      cpu.rdata = mmio_rdata;
    end else if (sel == SEL_SHM) begin
      cpu.ready = shm.ready;
      cpu.rdata = shm.rdata;
    end else begin
      cpu.ready = err_ready;
      cpu.rdata = 32'h0;
    end
  end

  // ---- trace port ----
  trace_pkt_t pkt;
  always_comb begin
    pkt.valid     = rvfi_valid;
    pkt.core      = 8'(CL * 16 + T);
    pkt.order     = rvfi_order;
    pkt.insn      = rvfi_insn;
    pkt.trap      = rvfi_trap;
    pkt.rs1_addr  = rvfi_rs1_addr;
    pkt.rs2_addr  = rvfi_rs2_addr;
    pkt.rd_addr   = rvfi_rd_addr;
    pkt.rs1_rdata = rvfi_rs1_rdata;
    pkt.rs2_rdata = rvfi_rs2_rdata;
    pkt.rd_wdata  = rvfi_rd_wdata;
    pkt.pc_rdata  = rvfi_pc_rdata;
    pkt.pc_wdata  = rvfi_pc_wdata;
    pkt.mem_addr  = rvfi_mem_addr;
    pkt.mem_rmask = rvfi_mem_rmask;
    pkt.mem_wmask = rvfi_mem_wmask;
    pkt.mem_rdata = rvfi_mem_rdata;
    pkt.mem_wdata = rvfi_mem_wdata;
  end
  assign trc.valid = rvfi_valid;
  assign trc.data  = pkt;
endmodule
