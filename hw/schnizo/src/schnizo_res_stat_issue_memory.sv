// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"

// TODO(colluca): generalize and upstream to tech cells as a module that can switch
// between memory or FFs
module schnizo_res_stat_issue_memory #(
  parameter  int unsigned NofRss          = 4,
  parameter  bit          UseSram         = 1'b0,
  parameter  type         rs_slot_issue_t = logic,
  localparam type         addr_t          = logic [cf_math_pkg::idx_width(NofRss)-1:0]
) (
  input  logic clk_i,
  input  logic rst_i,

  // Read port
  input  addr_t          raddr_i,
  output rs_slot_issue_t rdata_o,

  // Write port
  input  logic           wen_i,
  input  addr_t          waddr_i,
  input  rs_slot_issue_t wdata_i
);

  if (UseSram) begin : gen_sram

    typedef struct packed {
      logic [2:0] ema;
      logic [1:0] emaw;
      logic [0:0] emas;
    } sram_cfg_t;

    sram_cfg_t cfg;
    assign cfg = sram_cfg_t'('0);

    rs_slot_issue_t [1:0] rdata;

    // Port 1: read
    // Port 0: write
    tc_sram_impl #(
      .NumWords (NofRss),
      .DataWidth($bits(rs_slot_issue_t)),
      .ByteWidth(8),
      .NumPorts (2),
      .Latency  (1),
      .impl_in_t(sram_cfg_t)
    ) i_mem (
      .clk_i  ({clk_i, clk_i}),
      .rst_ni ({!rst_i, !rst_i}),
      .impl_i (cfg),
      .impl_o (),
      .req_i  ({1'b1, wen_i}),
      .we_i   ({1'b0, 1'b1}),
      .addr_i ({raddr_i, waddr_i}),
      .wdata_i({rs_slot_issue_t'('0), wdata_i}),
      .be_i   ('1),
      .rdata_o(rdata)
    );

    assign rdata_o = rdata[1];

  end else begin : gen_ffs

    rs_slot_issue_t [NofRss-1:0] slot_qs, slot_ds;

    // Read port
    assign rdata_o = slot_qs[raddr_i];

    // Write port
    always_comb begin : write_port
      slot_ds = slot_qs;
      if (wen_i) slot_ds[waddr_i] = wdata_i;
    end

    // Instantiate FF-based slots
    for (genvar rss = 0; rss < NofRss; rss++) begin : gen_slot
      `FFAR(slot_qs[rss], slot_ds[rss], '0, clk_i, rst_i);
    end

  end

endmodule
