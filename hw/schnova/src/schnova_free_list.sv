// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Stefan Odermatt <soderma@ethz.ch>
module schnova_free_list import schnizo_pkg::*; #(
  parameter int unsigned PipeWidth   = 1,
  parameter type         phy_id_t = logic
) (
  input  logic         clk_i,
  input  logic         rst_i,
  input  logic         clear_i,
  input  logic [PipeWidth-1:0] valid_i,
  input  logic en_superscalar_i,
  // From dispatcher, contains the desination register mappings, that the dispatcher
  // was able to allocate.
  output  phy_id_t      [PipeWidth-1:0]  phy_reg_id_o,
  output logic   [PipeWidth-1:0] ready_o
);
  // TODO (simple mapping for now)
  always_comb begin
    for (int unsigned i = 0; i < PipeWidth; i++) begin
      phy_reg_id_o[i] = phy_id_t'(0);
      ready_o[i] = 1'b1;
    end
  end

endmodule
