// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Stefan Odermatt <soderma@ethz.ch>
// Description: Variable Register Mapping Table
// verilog_lint: waive module-filename
module schnova_rmt #(
  parameter int unsigned NrReadPorts  = 2,
  parameter int unsigned NrWritePorts = 1,
  parameter bit          ZeroRegZero  = 0,
  parameter int unsigned AddrWidth    = 4,
  parameter type         rmt_entry_t = logic
) (
  // clock and reset
  input  logic                                        clk_i,
  input  logic                                        rst_ni,
  // read port
  input  logic       [NrReadPorts-1:0][AddrWidth-1:0]  raddr_i,
  output rmt_entry_t [NrReadPorts-1:0]                 rdata_o,
  // write port
  input  logic       [NrWritePorts-1:0][AddrWidth-1:0] waddr_i,
  input  rmt_entry_t [NrWritePorts-1:0]                wdata_i,
  input  logic       [NrWritePorts-1:0]                we_i
);

  localparam int unsigned NumWords  = 2**AddrWidth;

  rmt_entry_t [NumWords-1:0] mem;
  logic [NrWritePorts-1:0][NumWords-1:0] we_dec;

  rmt_entry_t no_mapping;
  assign no_mapping = '{
    producer:    '0,
    valid: 1'b0
  };

  always_comb begin : we_decoder
    for (int unsigned j = 0; j < NrWritePorts; j++) begin
      for (int unsigned i = 0; i < NumWords; i++) begin
        if (waddr_i[j] == i) we_dec[j][i] = we_i[j];
        else we_dec[j][i] = 1'b0;
      end
    end
  end

  // loop from 1 to NumWords-1 as R0 is nil
  always_ff @(posedge clk_i, negedge rst_ni) begin : register_write_behavioral
    if (~rst_ni) begin
      mem <= no_mapping;
    end else begin
      for (int unsigned j = 0; j < NrWritePorts; j++) begin
        for (int unsigned i = 0; i < NumWords; i++) begin
          if (we_dec[j][i]) begin
            mem[i] <= wdata_i[j];
          end
        end
      end
      if (ZeroRegZero) begin
        mem[0] <= no_mapping;
      end
    end
  end

  for (genvar i = 0; i < NrReadPorts; i++) begin : gen_read_port
    assign rdata_o[i] = mem[raddr_i[i]];
  end

endmodule