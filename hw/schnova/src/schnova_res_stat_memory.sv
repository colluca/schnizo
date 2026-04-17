// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"

// TODO(colluca): generalize and upstream to tech cells as a module that can switch
// between memory or FFs
module schnova_res_stat_memory #(
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
  input  logic           clear_entry_i,

  // Write port
  input  logic           wen_i,
  input  addr_t          waddr_i,
  input  rs_slot_issue_t wdata_i
);

  rs_slot_issue_t [NofRss-1:0] slot_qs, slot_ds;

  // Read port
  assign rdata_o = slot_qs[raddr_i];

  // Write port
  always_comb begin : write_port
    slot_ds = slot_qs;
    if (wen_i) begin 
      slot_ds[waddr_i] = wdata_i;
    end
    // Once the entry is issued, it can be cleared
    if (clear_entry_i) begin
      slot_ds[raddr_i].is_occupied = 1'b0;
    end
  end

  // Instantiate FF-based slots
  for (genvar rss = 0; rss < NofRss; rss++) begin : gen_slot
    `FFAR(slot_qs[rss], slot_ds[rss], '0, clk_i, rst_i);
  end

endmodule
