// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module schnizo_vfu_synth #(
  parameter int unsigned NofVLSU    = 1,
  parameter int unsigned NofVFU     = 1,
  parameter int unsigned NumFPUs    = 4,
  parameter int unsigned NumIPUs    = 1,
  parameter int unsigned VlsuNofRss = 6,
  parameter int unsigned VfuNofRss  = 8,
  // Derived — declared as parameters (not localparams) so they can be used in port dimensions
  parameter int unsigned NumFuPorts  = NofVLSU + NofVFU,
  parameter int unsigned NumMemPorts = (NumFPUs > NumIPUs) ? NumFPUs : NumIPUs,
  parameter int unsigned TCDMPorts   = NofVLSU * NumMemPorts,
  parameter int unsigned ELEN        = 64
) (
  input  logic clk_i,
  input  logic rst_i,
  input  schnizo_pkg::loop_state_e                                      loop_state_i,
  input  schnizo_synth_pkg::issue_req_t         [NumFuPorts-1:0]        issue_req_i,
  input  logic                                  [NumFuPorts-1:0]        issue_req_valid_i,
  input  logic                                  [NumFuPorts-1:0]        issue_commit_i,
  output logic                                  [NumFuPorts-1:0]        issue_req_ready_o,
  output logic                                  [NumFuPorts-1:0][ELEN-1:0] result_o,
  output logic                                  [NumFuPorts-1:0]        result_valid_o,
  input  logic                                  [NumFuPorts-1:0]        result_ready_i,
  output schnizo_pkg::instr_tag_t               [NumFuPorts-1:0]        tag_o,
  output schnizo_synth_pkg::tcdm_req_chan_t     [TCDMPorts-1:0]         tcdm_req_o,
  output logic                                  [TCDMPorts-1:0]         tcdm_req_valid_o,
  input  logic                                  [TCDMPorts-1:0]         tcdm_req_ready_i,
  input  schnizo_synth_pkg::tcdm_rsp_chan_t     [TCDMPorts-1:0]         tcdm_rsp_i,
  input  logic                                  [TCDMPorts-1:0]         tcdm_rsp_valid_i,
  output logic                                  [NumFuPorts-1:0]        busy_o
);

  schnizo_vfu #(
    .NofVLSU           (NofVLSU),
    .NofVFU            (NofVFU),
    .NumFPUs           (NumFPUs),
    .NumIPUs           (NumIPUs),
    .FPUImplementation (schnizo_synth_pkg::FpuImplementation),
    .VlsuNofRss        (VlsuNofRss),
    .VfuNofRss         (VfuNofRss),
    .issue_req_t       (schnizo_synth_pkg::issue_req_t),
    .tcdm_req_chan_t   (schnizo_synth_pkg::tcdm_req_chan_t),
    .tcdm_rsp_chan_t   (schnizo_synth_pkg::tcdm_rsp_chan_t)
  ) i_vfu (
    .clk_i,
    .rst_i,
    // pragma translate_off
    .trace_o            (),
    // pragma translate_on
    .loop_state_i,
    .issue_req_i,
    .issue_req_valid_i,
    .issue_commit_i,
    .issue_req_ready_o,
    .result_o,
    .result_valid_o,
    .result_ready_i,
    .tag_o,
    .tcdm_req_o,
    .tcdm_req_valid_o,
    .tcdm_req_ready_i,
    .tcdm_rsp_i,
    .tcdm_rsp_valid_i,
    .busy_o
  );

endmodule
