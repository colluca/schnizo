module schnova_phys_regfile_synth #(
  parameter int unsigned DataWidth = 32,
  parameter int unsigned NrReadPorts = 2,
  parameter int unsigned NrWritePorts = 1,
  parameter int unsigned NofOperandIfs = 1,
  parameter bit          ZeroRegZero = 0,
  parameter int unsigned PhysAddrWidth = 6,
  parameter int unsigned NumRegs      = 32,
  localparam int unsigned AddrWidth = $clog2(NumRegs),
  localparam type        phy_id_t = logic [AddrWidth-1:0],
  localparam type        operand_req_t = struct packed {
    phy_id_t  phy_reg; // which physical register we request
    logic     is_fp;   // if the physical register is a FPR
  }
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
  output logic [NofOperandIfs-1:0][PhysAddrWidth-1:0] sb_raddr_o,
  input  logic [NofOperandIfs-1:0]                sb_reg_busy_i,
  // operand request  port
  input operand_req_t [NofOperandIfs-1:0]         op_reqs_i,
  input logic         [NofOperandIfs-1:0]         op_reqs_valid_i,
  output logic        [NofOperandIfs-1:0]         op_reqs_ready_o,
  // operand response port
  output logic [NofOperandIfs-1:0][schnova_synth_pkg::OpLen-1:0] op_rsps_data_o,
  output logic [NofOperandIfs-1:0]                op_rsps_valid_o,
  input  logic [NofOperandIfs-1:0]                op_rsps_ready_i
);

  schnova_phys_regfile #(
    .DataWidth     (DataWidth),
    .OpLen         (schnova_synth_pkg::OpLen),
    .NrReadPorts   (NrReadPorts),
    .NofOperandIfs (NofOperandIfs),
    .NrWritePorts  (NrWritePorts),
    .ZeroRegZero   (ZeroRegZero),
    .PhysAddrWidth (PhysAddrWidth),
    .AddrWidth     (AddrWidth),
    .NumRegs       (NumRegs),
    .operand_req_t (operand_req_t)
  ) i_phy_regfile (
    .clk_i,
    .rst_ni,
    .raddr_i,
    .rdata_o,
    .waddr_i,
    .wdata_i,
    .we_i,
    .sb_raddr_o,
    .sb_reg_busy_i,
    .op_reqs_i,
    .op_reqs_valid_i,
    .op_reqs_ready_o,
    .op_rsps_data_o,
    .op_rsps_valid_o,
    .op_rsps_ready_i
  );

endmodule