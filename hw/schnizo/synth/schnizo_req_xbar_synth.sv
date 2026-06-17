// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module schnizo_req_xbar_synth #(
  parameter int unsigned NofOperandReqs     = 32'd2,
  parameter int unsigned NofRs              = 32'd2,
  parameter int unsigned NofRsrsPerRs       = 32'd4,
  parameter int unsigned NofResRspIfsPerRs  = 32'd1,
  localparam int unsigned TotalNofRsrs      = NofRs * NofRsrsPerRs,
  localparam int unsigned TotalNofResRspIfs = NofRs * NofResRspIfsPerRs,
  localparam integer unsigned RsIdWidth = $clog2(NofRs),
  localparam type dest_mask_t = logic [NofOperandReqs-1:0],
  localparam type slot_id_t = logic [$clog2(NofRsrsPerRs)-1:0],
  localparam type ext_res_req_t = struct packed {
    dest_mask_t dest_mask;
    slot_id_t   slot_id;
  },
  localparam type rs_id_t = logic [RsIdWidth-1:0],
  localparam type res_req_t = struct packed {
    logic       requested_iter;
    slot_id_t   slot_id;
  },
  localparam type operand_req_t = struct packed {
    rs_id_t   producer;
    res_req_t request;
  }
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  operand_req_t                         [NofOperandReqs-1:0]    op_reqs_i,
  input  logic                                 [NofOperandReqs-1:0]    op_reqs_valid_i,
  output logic                                 [NofOperandReqs-1:0]    op_reqs_ready_o,
  input  schnizo_synth_pkg::available_result_t [TotalNofRsrs-1:0]      available_results_i,
  output ext_res_req_t                         [TotalNofResRspIfs-1:0] res_reqs_o,
  output logic                                 [TotalNofResRspIfs-1:0] res_reqs_valid_o,
  input  logic                                 [TotalNofResRspIfs-1:0] res_reqs_ready_i
);

  localparam int unsigned NofRsrsArr       [NofRs-1:0] = '{default: NofRsrsPerRs};
  localparam int unsigned NofResRspIfsArr [NofRs-1:0] = '{default: NofResRspIfsPerRs};

  schnizo_req_xbar #(
    .NofOperandReqs    (NofOperandReqs),
    .NofRs             (NofRs),
    .NofRsrs           (NofRsrsArr),
    .NofResRspIfs      (NofResRspIfsArr),
    .TotalNofRsrs      (TotalNofRsrs),
    .TotalNofResRspIfs (TotalNofResRspIfs),
    .operand_req_t     (operand_req_t),
    .res_req_t         (res_req_t),
    .ext_res_req_t     (ext_res_req_t),
    .available_result_t(schnizo_synth_pkg::available_result_t),
    .slot_id_t         (slot_id_t),
    .dest_mask_t       (dest_mask_t)
  ) i_req_xbar (
    .op_reqs_i,
    .op_reqs_valid_i,
    .op_reqs_ready_o,
    .available_results_i,
    .res_reqs_o,
    .res_reqs_valid_o,
    .res_reqs_ready_i
  );

endmodule
