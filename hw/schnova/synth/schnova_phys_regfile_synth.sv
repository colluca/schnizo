// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module schnova_phys_regfile_synth #(
  parameter int unsigned  NumRegs       = 32,
  parameter int unsigned  DataWidth     = 32,
  parameter bit           IsGpr         = 0,
  parameter int unsigned  NofAlus       = 1,
  parameter int unsigned  NofLsus       = 1,
  parameter int unsigned  NofFpus       = 1,
  parameter int unsigned  PipeWidth     = 1,
  localparam int unsigned NrReadPorts   = (IsGpr) ? 2 : 3,
  localparam int unsigned NrWritePorts  = PipeWidth,
  localparam int unsigned NrOpReadPorts = (IsGpr) ? NofAlus * 2 + NofLsus * 2 + NofFpus * 1
                                                  : NofLsus * 1 + NofFpus * 3,
  localparam int unsigned NofOperandIfs = NofAlus * 2 + NofLsus * 2 + NofFpus * 3,
  localparam int unsigned AddrWidth     = $clog2(NumRegs),
  localparam type         phy_id_t      = logic [AddrWidth-1:0],
  localparam type         operand_req_t = struct packed {
    phy_id_t  phy_reg;
    logic     is_fp; 
  }
) (
  // clock and reset
  input  logic                                                   clk_i,
  input  logic                                                   rst_ni,
  // read port
  input  logic [NrReadPorts-1:0][AddrWidth-1:0]                  raddr_i,
  output logic [NrReadPorts-1:0][DataWidth-1:0]                  rdata_o,
  // write port
  input  logic [NrWritePorts-1:0][AddrWidth-1:0]                 waddr_i,
  input  logic [NrWritePorts-1:0][DataWidth-1:0]                 wdata_i,
  input  logic [NrWritePorts-1:0]                                we_i,
  // operand request  port
  input operand_req_t [NofOperandIfs-1:0]                        op_reqs_i,
  // operand response port
  output logic [NofOperandIfs-1:0][schnova_synth_pkg::OpLen-1:0] op_rsps_data_o
);

  schnova_phys_regfile #(
    .XFREPO             (1'b1),
    .DataWidth          (DataWidth),
    .OpLen              (schnova_synth_pkg::OpLen),
    .NofAlus            (NofAlus),
    .NofLsus            (NofLsus),
    .NofFpus            (NofFpus),
    .NrReadPorts        (NrReadPorts),
    .NrWritePorts       (NrWritePorts),
    .NrOperandReadPorts (NrOpReadPorts),
    .NofOperandIfs      (NofOperandIfs),
    .IsGpr              (IsGpr),
    .PhysAddrWidth      (AddrWidth),
    .AddrWidth          (AddrWidth),
    .NumRegs            (NumRegs),
    .operand_req_t      (operand_req_t)
  ) i_phy_regfile (
    .clk_i,
    .rst_ni,
    .raddr_i,
    .rdata_o,
    .waddr_i,
    .wdata_i,
    .we_i,
    .op_reqs_i,
    .op_rsps_data_o
  );

endmodule