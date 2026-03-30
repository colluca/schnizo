// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"

// TODO(colluca): generalize and upstream to tech cells as a module that can switch
// between memory or FFs
module schnizo_res_stat_constant_memory #(
  parameter  int unsigned NofConstants    = 4,
  parameter  int unsigned NofPorts        = 2,
  parameter  bit          UseSram         = 1'b0,
  parameter  type         operand_t       = logic,
  localparam type         addr_t          = logic [cf_math_pkg::idx_width(NofConstants)-1:0]
) (
  input  logic clk_i,
  input  logic rst_ni,

  // Read ports
  input  logic     [NofPorts-1:0] ren_i,
  input  addr_t    [NofPorts-1:0] raddr_i,
  output operand_t [NofPorts-1:0] rdata_o,

  // Write ports
  input  logic     [NofPorts-1:0] wen_i,
  input  addr_t    [NofPorts-1:0] waddr_i,
  input  operand_t [NofPorts-1:0] wdata_i
);

  // TODO(colluca): update to support multiple ports through banking
  if (UseSram) begin : gen_sram

    typedef struct packed {
      logic [2:0] ema;
      logic [1:0] emaw;
      logic [0:0] emas;
    } sram_cfg_t;

    sram_cfg_t cfg;
    assign cfg = sram_cfg_t'('0);

    operand_t [1:0] rdata;

    // Port 1: read
    // Port 0: write
    tc_sram_impl #(
      .NumWords (NofConstants),
      .DataWidth($bits(operand_t)),
      .ByteWidth(8),
      .NumPorts (2),
      .Latency  (1),
      .impl_in_t(sram_cfg_t)
    ) i_mem (
      .clk_i  ({clk_i, clk_i}),
      .rst_ni ({rst_ni, rst_ni}),
      .impl_i (cfg),
      .impl_o (),
      .req_i  ({ren_i, wen_i}),
      .we_i   ({1'b0, 1'b1}),
      .addr_i ({raddr_i, waddr_i}),
      .wdata_i({operand_t'('0), wdata_i}),
      .be_i   ('1),
      .rdata_o(rdata)
    );

    assign rdata_o = rdata[1];

  end else begin : gen_ffs

    operand_t [NofConstants-1:0] slot_qs, slot_ds;

    // Instantiate write ports
    always_comb begin : write_ports
      slot_ds = slot_qs;
      for (int port = 0; port < NofPorts; port++) begin
        if (wen_i[port]) slot_ds[waddr_i[port]] = wdata_i[port];
      end
    end

    // Instantiate read ports (there is no benefit in using the read enable here)
    for (genvar port = 0; port < NofPorts; port++) begin : gen_read_ports
      assign rdata_o[port] = slot_qs[raddr_i[port]];
    end

    // Instantiate FF-based slots
    for (genvar rss = 0; rss < NofConstants; rss++) begin : gen_slots
      `FF(slot_qs[rss], slot_ds[rss], '0);
    end
  end

endmodule
