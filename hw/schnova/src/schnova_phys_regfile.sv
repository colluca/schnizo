// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Stefan Odermatt <soderma@ethz.ch>
// Description: Variable Register File
// verilog_lint: waive module-filename
module schnova_phys_regfile #(
  parameter int unsigned DataWidth    = 32,
  parameter int unsigned OpLen        = 32,
  parameter int unsigned NrReadPorts  = 2,
  parameter int unsigned NrWritePorts = 1,
  parameter int unsigned NofOperandIfs = 1,
  parameter bit          ZeroRegZero  = 0,
  parameter int unsigned AddrWidth    = 4,
  parameter type         operand_req_t = logic
) (
  // clock and reset
  input  logic                                    clk_i,
  input  logic                                    rst_ni,
  // read port
  input  logic [NrReadPorts-1:0][AddrWidth-1:0]   raddr_i,
  output logic [NrReadPorts-1:0][DataWidth-1:0]   rdata_o,
  // write port
  input  logic [NrWritePorts-1:0][AddrWidth-1:0]  waddr_i,
  input  logic [NrWritePorts-1:0][DataWidth-1:0]  wdata_i,
  input  logic [NrWritePorts-1:0]                 we_i,
  // Scoreboard read port
  output logic [NofOperandIfs-1:0][AddrWidth-1:0] sb_raddr_o,
  input  logic [NofOperandIfs-1:0]                sb_reg_busy_i,
  // operand request  port
  input operand_req_t [NofOperandIfs-1:0]         op_reqs_i,
  input logic         [NofOperandIfs-1:0]         op_reqs_valid_i,
  output logic        [NofOperandIfs-1:0]         op_reqs_ready_o,
  // operand response port
  output logic [NofOperandIfs-1:0][OpLen-1:0]     op_rsps_data_o,
  output logic [NofOperandIfs-1:0]                op_rsps_valid_o,
  input  logic [NofOperandIfs-1:0]                op_rsps_ready_i
);
  // We have to have a read port for every read port and every operand interface
  localparam int unsigned NrRegfileReadPorts = NrReadPorts + NofOperandIfs;

  logic [NrRegfileReadPorts-1:0][AddrWidth-1:0] rf_raddr;
  logic [NrRegfileReadPorts-1:0][DataWidth-1:0] rf_rdata;

  // ---------------------------
  // Pack read ports
  // ---------------------------
  always_comb begin
    automatic integer port_idx = 0;

    rf_raddr = '0;
    rdata_o  = '0;
    op_rsps_data_o = '0;

    for (int unsigned i = 0; i < NrReadPorts; i++) begin
      rf_raddr[port_idx] = raddr_i[i];
      rdata_o[i]         = rf_rdata[port_idx];
      port_idx = port_idx + 1;
    end

    for (int unsigned op = 0; op < NofOperandIfs; op++) begin
      rf_raddr[port_idx] = op_reqs_i[op].phy_reg;
      op_rsps_data_o[op] = rf_rdata[port_idx];
      port_idx = port_idx + 1;
    end
  end

  // Request Handling
  always_comb begin: op_req_handling
    for (int unsigned op = 0; op < NofOperandIfs; op++) begin
      // The physical register file is always ready, since we allocate
      // as many ports as operands we could potentially simutlaneously
      // request
      op_reqs_ready_o[op] = op_reqs_valid_i[op];
    end
  end

  // Pack the read address for the scoreboard entries that should be read.
  always_comb begin
    for (int unsigned op = 0; op < NofOperandIfs; op++) begin
      sb_raddr_o[op] = op_reqs_i[op].phy_reg;
    end
  end

  // Response Handling
  always_comb begin : op_rsp_handling
    // We don't need the ready signal, we just always forward the scoreboard entry
    // of the currently requested data. The ROB makes sure that this entry
    // does not suddendly get invalidate once it was valid (not busy) for
    // as long as other insturctions need to consume this value.
    for (int unsigned op = 0; op < NofOperandIfs; op++) begin
      // The response is valid as soon as the scoreboard entry
      // for that physical register file is not busy anymore
      op_rsps_valid_o[op] = ~sb_reg_busy_i[op];
    end
  end

  // Register file that contains the values
  snitch_regfile #(
    .DataWidth   (DataWidth),
    .NrReadPorts (NrRegfileReadPorts),
    .NrWritePorts(NrWritePorts),
    .ZeroRegZero (ZeroRegZero),
    .AddrWidth   (AddrWidth)
  ) i_regfile (
    .clk_i,
    .rst_ni (rst_ni),
    .raddr_i(rf_raddr),
    .rdata_o(rf_rdata),
    .waddr_i(waddr_i),
    .wdata_i(wdata_i),
    .we_i   (we_i)
  );

endmodule
