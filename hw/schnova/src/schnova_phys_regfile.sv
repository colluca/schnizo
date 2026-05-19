// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Stefan Odermatt <soderma@ethz.ch>
// Description: Variable Register File
// verilog_lint: waive module-filename
module schnova_phys_regfile #(
  parameter int unsigned DataWidth    = 32,
  parameter int unsigned OpLen        = 32,
  parameter int unsigned NofAlus      = 1,
  parameter int unsigned NofLsus      = 1,
  parameter int unsigned NofFpus      = 1,
  parameter int unsigned NrReadPorts  = 2,
  parameter int unsigned NrWritePorts = 1,
  parameter int unsigned NrOperandReadPorts = 1,
  parameter int unsigned NofOperandIfs = 1,
  parameter bit          IsGpr         = 0,
  parameter int unsigned PhysAddrWidth = 6,
  parameter int unsigned AddrWidth    = 4,
  parameter int unsigned NumRegs      = 32,
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
  // operand request  port
  input operand_req_t [NofOperandIfs-1:0]         op_reqs_i,
  // operand response port
  output logic [NofOperandIfs-1:0][OpLen-1:0]     op_rsps_data_o
);
  // We have to have a read port for every read port and every operand interface
  localparam int unsigned NrRegfileReadPorts = NrReadPorts + NrOperandReadPorts;

  logic [NrRegfileReadPorts-1:0][AddrWidth-1:0] rf_raddr;
  logic [NrRegfileReadPorts-1:0][DataWidth-1:0] rf_rdata;

  // The operand requests are placed in the following order
  // 1) ALU operand requests
  // 2) LSU operand requests
  // 3) FPU operand requests
  // For more details see the file schnova_fu_stage.sv

  // ----------------
  // Pack read ports
  // ----------------
  always_comb begin : read_port_packing
      automatic integer unsigned port_idx = 0;
      automatic integer unsigned base_op = 0;

      rf_raddr = '0;
      rdata_o  = '0;
      op_rsps_data_o = '0;

      for (int unsigned i = 0; i < NrReadPorts; i++) begin
        rf_raddr[port_idx] = raddr_i[i];
        rdata_o[i]         = rf_rdata[port_idx];
        port_idx = port_idx + 1;
      end

      // ALU Section (Each ALU has 2 operands, always GPR)
      base_op = 0; // ALU requests start at index 0
      for (int unsigned alu = 0; alu < NofAlus; alu++) begin
        if (IsGpr) begin
          rf_raddr[port_idx]       = op_reqs_i[base_op + (alu*2) + 0].phy_reg[AddrWidth-1:0];
          op_rsps_data_o[base_op + (alu*2)] = rf_rdata[port_idx];
          port_idx++;

          rf_raddr[port_idx]       = op_reqs_i[base_op + (alu*2) + 1].phy_reg[AddrWidth-1:0];
          op_rsps_data_o[base_op + (alu*2) + 1] = rf_rdata[port_idx];
          port_idx++;
        end
      end

      // LSU Section (Starts after all ALUs; each LSU has 2 operands)
      base_op = NofAlus * 2; 
      for (int unsigned lsu = 0; lsu < NofLsus; lsu++) begin
        // Operand 0 (Address Generation) is ALWAYS GPR
        if (IsGpr) begin
          rf_raddr[port_idx]       = op_reqs_i[base_op + (lsu*2) + 0].phy_reg[AddrWidth-1:0];
          op_rsps_data_o[base_op + (lsu*2) + 0] = rf_rdata[port_idx];
          port_idx++;
        end

        // Operand 1 (Store Data) can be GPR or FPR
        if (IsGpr) begin
          rf_raddr[port_idx]       = op_reqs_i[base_op + (lsu*2) + 1].phy_reg[AddrWidth-1:0];
          op_rsps_data_o[base_op + (lsu*2) + 1] = rf_rdata[port_idx];
          port_idx++;
        end else begin
          rf_raddr[port_idx]       = op_reqs_i[base_op + (lsu*2) + 1].phy_reg[AddrWidth-1:0];
          op_rsps_data_o[base_op + (lsu*2) + 1] = rf_rdata[port_idx];
          port_idx++;
        end
      end

      // FPU Section (Starts after ALUs + LSUs; each FPU has 3 operands)
      base_op = (NofAlus * 2) + (NofLsus * 2);
      for (int unsigned fpu = 0; fpu < NofFpus; fpu++) begin
        // Operand 0 (e.g., Conversion source / FP Move) can be GPR
        if (IsGpr) begin
          rf_raddr[port_idx]       = op_reqs_i[base_op + (fpu*3) + 0].phy_reg[AddrWidth-1:0];
          op_rsps_data_o[base_op + (fpu*3) + 0] = rf_rdata[port_idx];
          port_idx++;
        end else begin
          rf_raddr[port_idx]       = op_reqs_i[base_op + (fpu*3) + 0].phy_reg[AddrWidth-1:0];
          op_rsps_data_o[base_op + (fpu*3) + 0] = rf_rdata[port_idx];
          port_idx++;
        end

        // Operands 1 and 2 are strictly FPR
        if (!IsGpr) begin
          rf_raddr[port_idx]       = op_reqs_i[base_op + (fpu*3) + 1].phy_reg[AddrWidth-1:0];
          op_rsps_data_o[base_op + (fpu*3) + 1] = rf_rdata[port_idx];
          port_idx++;

          rf_raddr[port_idx]       = op_reqs_i[base_op + (fpu*3) + 2].phy_reg[AddrWidth-1:0];
          op_rsps_data_o[base_op + (fpu*3) + 2] = rf_rdata[port_idx];
          port_idx++;
        end
      end
  end

  // Register file that contains the values
  schnova_regfile #(
    .DataWidth   (DataWidth),
    .NrReadPorts (NrRegfileReadPorts),
    .NrWritePorts(NrWritePorts),
    .ZeroRegZero (IsGpr),
    .AddrWidth   (AddrWidth),
    .NumRegs(NumRegs)
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
