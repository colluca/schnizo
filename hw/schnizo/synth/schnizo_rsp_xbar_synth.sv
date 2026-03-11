// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module schnizo_rsp_xbar_synth #(
  parameter int unsigned  NofRs            = 32'd0,
  parameter int unsigned  NofRssPerRs      = 32'd0,
  parameter int unsigned  NofRspPortsPerRs = 32'd0,
  parameter int unsigned  NumOut           = 32'd0,
  localparam int unsigned NumInp           = NofRs * NofRssPerRs,
  localparam type         payload_t        = logic [63:0],
  localparam type         dest_mask_t      = logic [NumOut-1:0]
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,
  input  payload_t   [NumInp-1:0] data_i,
  input  dest_mask_t [NumInp-1:0] sel_i,
  input  logic       [NumInp-1:0] valid_i,
  output logic       [NumInp-1:0] ready_o,
  output payload_t   [NumOut-1:0] data_o,
  output logic       [NumOut-1:0] valid_o,
  input  logic       [NumOut-1:0] ready_i
);

  localparam int unsigned NofRss [NofRs-1:0] = '{default: NofRssPerRs};
  localparam int unsigned NofRspPorts [NofRs-1:0] = '{default: NofRspPortsPerRs};

  localparam int unsigned TotalNofRspPorts = NofRs * NofRspPortsPerRs;

  schnizo_rsp_xbar #(
    .NofRs(NofRs),
    .NofRss(NofRss),
    .NofRspPorts(NofRspPorts),
    .TotalNofRspPorts(TotalNofRspPorts),
    .NumInp(NumInp),
    .NumOut(NumOut),
    .payload_t(payload_t)
  ) i_rsp_xbar (
    .clk_i,
    .rst_ni,
    .data_i,
    .sel_i,
    .valid_i,
    .ready_o,
    .data_o,
    .valid_o,
    .ready_i
  );

endmodule