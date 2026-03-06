// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// The module hosting a Reservation Station and selecting between regular and superscalar
// instruction issue paths.
//
// In superscalar execution mode, dispatch requests are routed into the RS, which in turn produces
// issue requests. Similarly results from the FU are routed into the RS, which in turn produces
// writeback requests. In regular or single-issue execution mode, the RS is bypassed: dispatch
// requests are directly issued to the FUs and FU results are directly sent to the writeback.
// This module instantiates the RS and performs the necessary demuxing and muxing to bypass or go
// through the RS.
module schnizo_fu_block import schnizo_pkg::*; #(
  // Globally enable the superscalar feature
  parameter bit          Xfrep          = 1,
  /// Instruction stream parameters
  parameter type         disp_req_t     = logic,
  parameter type         disp_rsp_t     = logic,
  parameter type         issue_req_t    = logic,
  parameter type         result_t       = logic,
  parameter type         instr_tag_t    = logic,
  /// Reservation Station parameters
  parameter int unsigned NofRss         = 4,
  // The maximal number of operands
  parameter int unsigned NofOperands    = 3,
  // The number of operand request / response ports to the operand distribution network.
  // 1 port has a connection for each operand.
  parameter int unsigned NofOpPorts     = 1,
  parameter int unsigned NofOperandIfs  = 1,
  parameter int unsigned NofResRspIfs   = 1,
  parameter int unsigned ConsumerCount  = 4,
  // The bits to address all registers
  parameter int unsigned RegAddrWidth   = 5,
  parameter int unsigned MaxIterationsW = 5,
  parameter type         producer_id_t  = logic,
  parameter type         slot_id_t      = logic,
  parameter type         operand_req_t  = logic,
  parameter type         operand_t      = logic,
  parameter type         res_req_t      = logic,
  parameter type         dest_mask_t    = logic,
  parameter type         res_rsp_t      = logic
) (
  input  logic clk_i,
  input  logic rst_i,

  /// RS control signals
  // The producer id of the RS and thus the first RSS. Must be static.
  input  producer_id_t              producer_id_i,
  // If restart is asserted, we initialize the RS. This will clean all RSS and reset the loop
  // handling logic.
  input  logic                      restart_i,
  input  loop_state_e               loop_state_i,
  input  logic                      in_lxp_i,
  input  logic [MaxIterationsW-1:0] lep_iterations_i,
  // Asserted in the last LCP1 cycle (the cycle before we start LCP2)
  input  logic                      goto_lcp2_i,
  input  logic                      fu_busy_i,
  // Asserted when all RSS finish execution (in this cycle) or have already finished.
  // LCP: No instructions in flight. LEP: All iterations done
  output logic                      loop_finish_o,
  output logic                      rs_full_o,

  /// Instruction Stream
  // TODO(colluca): use generic_reqrsp interfaces for all of these. Would then reduce to four signals:
  // disp_req_i, disp_rsp_o, issue_req_o, issue_rsp_i, result_req_i, result_rsp_o, wb_req_o, wb_rsp_i
  //
  // From dispatcher to dispatch MUX
  input  disp_req_t disp_req_i,
  input  logic      disp_req_valid_i,
  output logic      disp_req_ready_o,
  input  logic      instr_exec_commit_i,
  output disp_rsp_t disp_rsp_o,
  // From issue MUX to FU
  output issue_req_t issue_req_o,
  output logic       issue_req_valid_o,
  input  logic       issue_req_ready_i,
  output logic       instr_exec_commit_o,
  // From FU to the result DEMUX
  input  result_t    result_i,
  input  instr_tag_t result_tag_i,
  input  logic       result_valid_i,
  output logic       result_ready_o,
  // From writeback MUX to writeback
  output result_t    wb_result_o,
  output instr_tag_t wb_result_tag_o,
  output logic       wb_result_valid_o,
  input  logic       wb_result_ready_i,

  /// Operand distribution network
  // Info required for arbitration in request XBAR
  output operand_req_t [NofRss-1:0] available_results_o,

  // TODO(colluca): use generic_reqrsp interfaces for all of these. Would then reduce to four signals:
  // operand_req_o, operand_rsp_i, result_req_i, result_rsp_o.
  // We can't actually do it at the moment, because the cardinality of req_reqs and res_rsps differs.
  //
  // Operand request interface - outgoing - request a result as operand
  output operand_req_t [NofOpPorts-1:0][NofOperands-1:0] op_reqs_o,
  output logic         [NofOpPorts-1:0][NofOperands-1:0] op_reqs_valid_o,
  input  logic         [NofOpPorts-1:0][NofOperands-1:0] op_reqs_ready_i,

  // Result request interface - incoming - from each possible requester
  input  dest_mask_t [NofResRspIfs-1:0] res_reqs_i,
  input  logic       [NofResRspIfs-1:0] res_reqs_valid_i,
  output logic       [NofResRspIfs-1:0] res_reqs_ready_o,

  // Result response interface - outgoing - result as operand response
  output res_rsp_t [NofResRspIfs-1:0] res_rsps_o,
  output logic     [NofResRspIfs-1:0] res_rsps_valid_o,
  input  logic     [NofResRspIfs-1:0] res_rsps_ready_i,

  // Operand response interface - incoming - returning result as operand
  input  operand_t [NofOpPorts-1:0][NofOperands-1:0] op_rsps_i,
  input  logic     [NofOpPorts-1:0][NofOperands-1:0] op_rsps_valid_i,
  output logic     [NofOpPorts-1:0][NofOperands-1:0] op_rsps_ready_o
);

  typedef logic [cf_math_pkg::idx_width(NofRss)-1:0] rs_tag_t;

  if (Xfrep) begin : gen_superscalar
    // Module global switch between regular execution and superscalar path
    logic sel_lxp_path;
    assign sel_lxp_path = in_lxp_i;

    ////////////////////////
    // Datapath selection //
    ////////////////////////

    // There are two paths between dispatch and issue:
    // - a path for superscalar execution, which routes dispatch requests into the reservation
    //   station, which in turn produces issue requests (signals on this path have prefix "rs")
    // - a direct path for single issue or regular execution, which bypasses the reservation
    //   station and feeds through dispatch requests to issue requests (signals on this path have
    //   prefix "si")
    // This datapath selection block demuxes dispatch requests to the two paths and muxes issue
    // requests from the two paths.

    // From dispatch interface DEMUX to RS
    disp_req_t rs_disp_req;
    logic      rs_disp_req_valid;
    logic      rs_disp_req_ready;
    disp_rsp_t rs_disp_rsp;
    // From dispatch interface DEMUX to dispatch2issue converter
    disp_req_t si_disp_req;
    logic      si_disp_req_valid;
    logic      si_disp_req_ready;

    // From the RS to the Issue MUX
    issue_req_t rs_issue_req;
    logic       rs_issue_req_valid;
    logic       rs_issue_req_ready;
    logic       rs_instr_exec_commit;
    // From dispatch2issue converter to issue MUX
    issue_req_t si_issue_req;
    logic       si_issue_req_valid;
    logic       si_issue_req_ready;

    // From issue MUX to FU
    // via module interface

    // From FU to result DEMUX
    // via module interface

    // From the result DEMUX to the RS
    result_t    rs_result;
    instr_tag_t rs_result_tag;
    logic       rs_result_valid;
    logic       rs_result_ready;
    // From the RS to the writeback MUX
    result_t    rs_wb_result;
    instr_tag_t rs_wb_result_tag;
    logic       rs_wb_result_valid;
    logic       rs_wb_result_ready;
    // From result DEMUX to writeback MUX
    result_t    si_wb_result;
    instr_tag_t si_wb_result_tag;
    logic       si_wb_result_valid;
    logic       si_wb_result_ready;

    // Dispatch DEMUX
    assign rs_disp_req = disp_req_i;
    assign si_disp_req = disp_req_i;
    stream_demux #(
      .N_OUP (2)
    ) i_disp_demux (
      .inp_valid_i(disp_req_valid_i),
      .inp_ready_o(disp_req_ready_o),
      .oup_sel_i  (sel_lxp_path),
      .oup_valid_o({rs_disp_req_valid, si_disp_req_valid}),
      .oup_ready_i({rs_disp_req_ready, si_disp_req_ready})
    );
    // The dispatch response is always returned. The dispatcher must check when it is valid.
    // TODO(colluca): why not assign this to zero on the SI path and mux it here?
    assign disp_rsp_o = rs_disp_rsp;

    // Issue MUX
    // There is no logic in the regular dispatch and issue path. We can directly use the dispatch
    // valid/ready signals.
    // TODO(colluca): dispatch2issue converter for single-issue path is the same as the one
    //                in the gen_scalar block. Could maybe be reused.
    assign si_issue_req.fu_data = si_disp_req.fu_data;
    assign si_issue_req.tag     = si_disp_req.tag;
    assign si_issue_req_valid = si_disp_req_valid;
    assign si_disp_req_ready  = si_issue_req_ready;

    stream_mux #(
      .DATA_T(issue_req_t),
      .N_INP (2)
    ) i_fu_issue_mux (
      .inp_data_i ({rs_issue_req,       si_issue_req}),
      .inp_valid_i({rs_issue_req_valid, si_issue_req_valid}),
      .inp_ready_o({rs_issue_req_ready, si_issue_req_ready}),
      .inp_sel_i  (sel_lxp_path),
      .oup_data_o (issue_req_o),
      .oup_valid_o(issue_req_valid_o),
      .oup_ready_i(issue_req_ready_i)
    );

    assign instr_exec_commit_o = sel_lxp_path ? rs_instr_exec_commit : instr_exec_commit_i;

    // Result DEMUX
    assign rs_result        = result_i;
    assign rs_result_tag    = result_tag_i;
    assign si_wb_result     = result_i;
    assign si_wb_result_tag = result_tag_i;
    stream_demux #(
      .N_OUP(2)
    ) i_fu_result_demux (
      .inp_valid_i(result_valid_i),
      .inp_ready_o(result_ready_o),
      .oup_sel_i  (sel_lxp_path),
      .oup_valid_o({rs_result_valid, si_wb_result_valid}),
      .oup_ready_i({rs_result_ready, si_wb_result_ready})
    );

    // Writeback MUX
    // Local helper type to merge the MUX
    typedef struct packed {
      result_t    result;
      instr_tag_t tag;
    } result_and_tag_t;

    result_and_tag_t rs_wb_result_and_tag, si_wb_result_and_tag;
    result_and_tag_t wb_result_and_tag;
    assign rs_wb_result_and_tag = '{
      result: rs_wb_result,
      tag:    rs_wb_result_tag
    };
    assign si_wb_result_and_tag = '{
      result: si_wb_result,
      tag:    si_wb_result_tag
    };

    stream_mux #(
      .DATA_T(result_and_tag_t),
      .N_INP (2)
    ) i_fu_wb_mux (
      .inp_data_i ({rs_wb_result_and_tag, si_wb_result_and_tag}),
      .inp_valid_i({rs_wb_result_valid,   si_wb_result_valid}),
      .inp_ready_o({rs_wb_result_ready,   si_wb_result_ready}),
      .inp_sel_i  (sel_lxp_path),
      .oup_data_o (wb_result_and_tag),
      .oup_valid_o(wb_result_valid_o),
      .oup_ready_i(wb_result_ready_i)
    );

    assign wb_result_o     = wb_result_and_tag.result;
    assign wb_result_tag_o = wb_result_and_tag.tag;

    // ---------------------------
    // Reservation Station
    // ---------------------------
    // TODO(colluca): does the reservation station even need an instr_tag_t type that
    // is calculated as max(wb_tag_t, rs_tag_t)? If not, just pass rs_tag_t here
    schnizo_res_stat #(
      .NofRss        (NofRss),
      .NofOperands   (NofOperands),
      .NofOpPorts    (NofOpPorts),
      .NofOperandIfs (NofOperandIfs),
      .NofResRspIfs  (NofResRspIfs),
      .ConsumerCount (ConsumerCount),
      .RegAddrWidth  (RegAddrWidth),
      .MaxIterationsW(MaxIterationsW),
      .disp_req_t    (disp_req_t),
      .disp_rsp_t    (disp_rsp_t),
      .issue_req_t   (issue_req_t),
      .result_t      (result_t),
      .result_tag_t  (instr_tag_t),
      .producer_id_t (producer_id_t),
      .slot_id_t     (slot_id_t),
      .operand_req_t (operand_req_t),
      .operand_t     (operand_t),
      .res_req_t     (res_req_t),
      .dest_mask_t   (dest_mask_t),
      .res_rsp_t     (res_rsp_t)
    ) i_res_stat (
      .clk_i,
      .rst_i,
      // Control signals
      .producer_id_i      (producer_id_i),
      .restart_i          (restart_i),
      .loop_state_i       (loop_state_i),
      .lep_iterations_i   (lep_iterations_i),
      .goto_lcp2_i        (goto_lcp2_i),
      .loop_finish_o      (loop_finish_o),
      .rs_full_o          (rs_full_o),
      .fu_busy_i          (fu_busy_i),
      // The dispatched instruction - from Dispatcher
      .disp_req_i         (rs_disp_req),
      .disp_req_valid_i   (rs_disp_req_valid),
      .disp_req_ready_o   (rs_disp_req_ready),
      .instr_exec_commit_i(instr_exec_commit_i),
      .disp_rsp_o         (rs_disp_rsp),
      // The issued instruction - to FU
      .issue_req_o        (rs_issue_req),
      .issue_req_valid_o  (rs_issue_req_valid),
      .issue_req_ready_i  (rs_issue_req_ready),
      .instr_exec_commit_o(rs_instr_exec_commit),
      // Result from FU
      .result_i           (rs_result),
      .result_tag_i       (rs_result_tag),
      .result_valid_i     (rs_result_valid),
      .result_ready_o     (rs_result_ready),
      // RF writeback
      .rf_wb_result_o     (rs_wb_result),
      .rf_wb_tag_o        (rs_wb_result_tag),
      .rf_wb_valid_o      (rs_wb_result_valid),
      .rf_wb_ready_i      (rs_wb_result_ready),

      /// Operand distribution network - directly fed through
      .available_results_o(available_results_o),
      // Operand request interface - outgoing - request a result as operand
      .op_reqs_o          (op_reqs_o),
      .op_reqs_valid_o    (op_reqs_valid_o),
      .op_reqs_ready_i    (op_reqs_ready_i),
      // Result request interface - incoming - translated operand request
      .res_reqs_i         (res_reqs_i),
      .res_reqs_valid_i   (res_reqs_valid_i),
      .res_reqs_ready_o   (res_reqs_ready_o),
      // Result response interface - outgoing - result as operand response
      .res_rsps_o         (res_rsps_o),
      .res_rsps_valid_o   (res_rsps_valid_o),
      .res_rsps_ready_i   (res_rsps_ready_i),
      // Operand response interface - incoming - returning result as operand
      .op_rsps_i          (op_rsps_i),
      .op_rsps_valid_i    (op_rsps_valid_i),
      .op_rsps_ready_o    (op_rsps_ready_o)
    );
  end else begin : gen_scalar
    // In the non superscalar version the dispatch request is simply "converted" to an issue request.
    // The result is directly passed to the writeback.

    // Convert the dispatch request to an issue request. Direct pass-through.
    assign issue_req_o.fu_data = disp_req_i.fu_data;
    assign issue_req_o.tag     = disp_req_i.tag;
    assign issue_req_valid_o   = disp_req_valid_i;
    assign disp_req_ready_o    = issue_req_ready_i;
    // Dispatch response must match FU without superscalar feature
    assign disp_rsp_o = producer_id_t'{
      slot_id: '0,
      rs_id:   producer_id_i.rs_id
    };
    assign instr_exec_commit_o = instr_exec_commit_i;

    // From FU result to the writeback. Direct pass-through.
    assign wb_result_o       = result_i;
    assign wb_result_tag_o   = result_tag_i;
    assign wb_result_valid_o = result_valid_i;
    assign result_ready_o    = wb_result_ready_i;

    /// Superscalar specific signals
    // The "RS" has always finished
    assign loop_finish_o = 1'b1;
    // The "RS" is never full
    assign rs_full_o = 1'b0;

    /// Operand distribution network
    // There are no request signals connected anywhere. Simply set all signals to zero and ignore
    // the inputs.
    // Operand request interface - outgoing - request a result as operand
    assign op_reqs_o       = '0;
    assign op_reqs_valid_o = '0;
    // ignore the ready: op_reqs_ready_i

    // Result request interface - incoming - from each possible requester
    // ingore input: res_reqs_i
    // ingore input: res_reqs_valid_i
    assign res_reqs_ready_o = '0;

    // Result response interface - outgoing - result as operand response
    assign res_rsps_o       = '0;
    assign res_rsps_valid_o = '0;
    // ignore the ready: res_rsps_ready_i

    // Operand response interface - incoming - returning result as operand
    // ingore the input: op_rsps_i,
    // ingore the input: op_rsps_valid_i,
    assign op_rsps_ready_o = '0;
  end

endmodule
