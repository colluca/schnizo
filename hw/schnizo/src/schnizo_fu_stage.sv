// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Pascal Etterli <petterli@student.ethz.ch>
// Description: The module hosting all RS and FUs.

module schnizo_fu_stage import schnizo_pkg::*; #(
  parameter int unsigned NofAlus        = 1,
  parameter int unsigned AluNofRss      = 3,
  parameter int unsigned AluNofOperands = 2,
  parameter int unsigned NofLsus        = 1,
  parameter int unsigned LsuNofRss      = 3,
  parameter int unsigned LsuNofOperands = 4,
  parameter int unsigned NofFpus        = 1,
  parameter int unsigned FpuNofRss      = 2,
  parameter int unsigned FpuNofOperands = 3,
  parameter int unsigned NofOperandIfs  = 12,
  parameter int unsigned NofResultIfs   = 6,
  parameter int unsigned XLEN           = 32,
  parameter int unsigned FLEN           = 64,
  parameter int unsigned OpLen          = 64,
  parameter int unsigned AddrWidth      = 32,
  parameter int unsigned DataWidth      = 32,
  parameter int unsigned RegAddrWidth   = 5,
  parameter int unsigned MaxIterationsW = 5,
  // Consistency Address Queue (CAQ) parameters
  parameter int unsigned CaqDepth    = 0,
  parameter int unsigned CaqTagWidth = 0,
  /// How many issued loads the LSU and thus the CAQ (consistency address queue) can hold.
  // This applies to all LSUs (each LSU can handle NumOutstandingLoads loads).
  parameter int unsigned NumOutstandingLoads = 0,
  /// How many total transactions (load and store) the LSU can handle at once
  // This applies to all LSUs (each LSU can handle NumOutstandingMem transactions).
  parameter int unsigned NumOutstandingMem = 0,
  /// FPU parameters
  parameter fpnew_pkg::fpu_implementation_t FPUImplementation = '0,
  parameter bit          RVF            = 1,
  parameter bit          RVD            = 1,
  parameter bit          XF16           = 0,
  parameter bit          XF16ALT        = 0,
  parameter bit          XF8            = 0,
  parameter bit          XF8ALT         = 0,
  // Vectors are not implemented! Here for compatibility with Snitch.
  parameter bit          XFVEC          = 0,
  // Register the signals directly before the FPnew instance
  parameter bit          RegisterFPUIn  = 0,
  // Register the signals directly after the FPnew instance
  parameter bit          RegisterFPUOut = 0,
  /// Others
  parameter type         producer_id_t  = logic,
  parameter type         operand_id_t   = logic,
  parameter type         disp_req_t     = logic,
  parameter type         disp_rsp_t     = logic,
  parameter type         issue_req_t    = logic,
  parameter type         instr_tag_t    = logic,
  parameter type         alu_result_t   = logic,
  parameter type         dreq_t         = logic,
  parameter type         drsp_t         = logic,
  /// Derived parameter *Do not override*
  parameter type addr_t = logic [AddrWidth-1:0],
  parameter type data_t = logic [DataWidth-1:0]
) (
  input  logic        clk_i,
  input  logic        rst_i,
  input  logic [31:0] hard_id_i,

  /// RS control signals
  input  logic                      restart_i,
  input  loop_state_e               loop_state_i,
  input  logic [MaxIterationsW-1:0] lep_iterations_i,
  input  logic                      goto_lcp2_i,
  // Asserted if all RS are either finishing in this cycle or have already finished
  output logic                      all_rs_finish_o,

  /// Instruction streams & FU status signals
  input  disp_req_t               disp_req_i,
  input  logic      [NofAlus-1:0] alu_disp_reqs_valid_i,
  output logic      [NofAlus-1:0] alu_disp_reqs_ready_o,
  output disp_rsp_t [NofAlus-1:0] alu_disp_rsp_o,
  output logic      [NofAlus-1:0] alu_loop_finish_o,
  output logic      [NofAlus-1:0] alu_rs_full_o,

  input  logic      [NofLsus-1:0] lsu_disp_reqs_valid_i,
  output logic      [NofLsus-1:0] lsu_disp_reqs_ready_o,
  output disp_rsp_t [NofLsus-1:0] lsu_disp_rsp_o,
  output logic                    lsu_empty_o,
  output logic                    lsu_addr_misaligned_o,
  output dreq_t     [NofLsus-1:0] lsu_dreq_o,
  input  drsp_t     [NofLsus-1:0] lsu_drsp_i,
  output logic      [NofLsus-1:0] lsu_loop_finish_o,
  output logic      [NofLsus-1:0] lsu_rs_full_o,
  input  addr_t     [NofLsus-1:0] caq_addr_i,
  input  logic      [NofLsus-1:0] caq_track_write_i,
  input  logic      [NofLsus-1:0] caq_req_valid_i,
  output logic      [NofLsus-1:0] caq_req_ready_o,
  input  logic      [NofLsus-1:0] caq_rsp_valid_i,
  output logic      [NofLsus-1:0] caq_rsp_valid_o,

  input  logic               [NofFpus-1:0] fpu_disp_reqs_valid_i,
  output logic               [NofFpus-1:0] fpu_disp_reqs_ready_o,
  output disp_rsp_t          [NofFpus-1:0] fpu_disp_rsp_o,
  output logic               [NofFpus-1:0] fpu_loop_finish_o,
  output logic               [NofFpus-1:0] fpu_rs_full_o,
  // Combined status of all FPUs
  output fpnew_pkg::status_t fpu_status_o,
  output logic               fpu_status_valid_o,

  /// Writeback ports. We only have one per FU type.
  output alu_result_t alu_wb_result_o,
  output instr_tag_t  alu_wb_result_tag_o,
  output logic        alu_wb_result_valid_o,
  input  logic        alu_wb_result_ready_i,

  output data_t      lsu_wb_result_o,
  output instr_tag_t lsu_wb_result_tag_o,
  output logic       lsu_wb_result_valid_o,
  input  logic       lsu_wb_result_ready_i,

  output logic [FLEN-1:0] fpu_wb_result_o,
  output instr_tag_t      fpu_wb_result_tag_o,
  output logic            fpu_wb_result_valid_o,
  input  logic            fpu_wb_result_ready_i
);
  // ---------------------------
  // RSS definitions / parameters
  // ---------------------------
  // In theory each other RSS in the system and the RSS itself could be a consumer. Thus use full width.
  // TODO: optimize to a useful number
  localparam integer unsigned ConsumerCount = 2**$bits(operand_id_t);

  // ---------------------------
  // Operand distribution network definitions
  // ---------------------------
  typedef struct packed {
    logic        requested_iter;
    operand_id_t consumer; // where to send the response to
  } res_req_t;

  typedef struct packed {
    producer_id_t producer; // where to place the request
    res_req_t     request;
  } operand_req_t;

  typedef logic [OpLen-1:0] operand_t;

  typedef struct packed {
    operand_id_t consumer; // where to send the response to
    operand_t    operand;
  } res_rsp_t;

  operand_req_t [NofOperandIfs-1:0] op_reqs;
  logic         [NofOperandIfs-1:0] op_reqs_valid;
  logic         [NofOperandIfs-1:0] op_reqs_ready;

  res_req_t     [NofResultIfs-1:0]  res_reqs;
  logic         [NofResultIfs-1:0]  res_reqs_valid;
  logic         [NofResultIfs-1:0]  res_reqs_ready;

  res_rsp_t     [NofResultIfs-1:0]  res_rsps;
  logic         [NofResultIfs-1:0]  res_rsps_valid;
  logic         [NofResultIfs-1:0]  res_rsps_ready;

  operand_t     [NofOperandIfs-1:0] op_rsps;
  logic         [NofOperandIfs-1:0] op_rsps_valid;
  logic         [NofOperandIfs-1:0] op_rsps_ready;

  // ---------------------------
  // RS ID generation
  // ---------------------------
  // Each RS needs a globally unique ID. We simply count all RS.
  localparam integer unsigned AluRsIdOffset = 0;
  localparam integer unsigned LsuRsIdOffset = AluRsIdOffset + NofAlus * AluNofRss;
  localparam integer unsigned FpuRsIdOffset = LsuRsIdOffset + NofLsus * LsuNofRss;

  // Each operands needs a globally unique ID. We simply count all operands.
  localparam integer unsigned AluOpIdOffset = 0;
  localparam integer unsigned LsuOpIdOffset = AluOpIdOffset + NofAlus * AluNofRss * AluNofOperands;
  localparam integer unsigned FpuOpIdOffset = LsuOpIdOffset + NofLsus * LsuNofRss * LsuNofOperands;

  operand_req_t [NofAlus-1:0][AluNofRss-1:0][AluNofOperands-1:0] alu_op_reqs;
  logic         [NofAlus-1:0][AluNofRss-1:0][AluNofOperands-1:0] alu_op_reqs_valid;
  logic         [NofAlus-1:0][AluNofRss-1:0][AluNofOperands-1:0] alu_op_reqs_ready;
  res_req_t     [NofAlus-1:0][AluNofRss-1:0]                     alu_res_reqs;
  logic         [NofAlus-1:0][AluNofRss-1:0]                     alu_res_reqs_valid;
  logic         [NofAlus-1:0][AluNofRss-1:0]                     alu_res_reqs_ready;
  res_rsp_t     [NofAlus-1:0][AluNofRss-1:0]                     alu_res_rsps;
  logic         [NofAlus-1:0][AluNofRss-1:0]                     alu_res_rsps_valid;
  logic         [NofAlus-1:0][AluNofRss-1:0]                     alu_res_rsps_ready;
  operand_t     [NofAlus-1:0][AluNofRss-1:0][AluNofOperands-1:0] alu_op_rsps;
  logic         [NofAlus-1:0][AluNofRss-1:0][AluNofOperands-1:0] alu_op_rsps_valid;
  logic         [NofAlus-1:0][AluNofRss-1:0][AluNofOperands-1:0] alu_op_rsps_ready;

  operand_req_t [NofLsus-1:0][LsuNofRss-1:0][LsuNofOperands-1:0] lsu_op_reqs;
  logic         [NofLsus-1:0][LsuNofRss-1:0][LsuNofOperands-1:0] lsu_op_reqs_valid;
  logic         [NofLsus-1:0][LsuNofRss-1:0][LsuNofOperands-1:0] lsu_op_reqs_ready;
  res_req_t     [NofLsus-1:0][LsuNofRss-1:0]                     lsu_res_reqs;
  logic         [NofLsus-1:0][LsuNofRss-1:0]                     lsu_res_reqs_valid;
  logic         [NofLsus-1:0][LsuNofRss-1:0]                     lsu_res_reqs_ready;
  res_rsp_t     [NofLsus-1:0][LsuNofRss-1:0]                     lsu_res_rsps;
  logic         [NofLsus-1:0][LsuNofRss-1:0]                     lsu_res_rsps_valid;
  logic         [NofLsus-1:0][LsuNofRss-1:0]                     lsu_res_rsps_ready;
  operand_t     [NofLsus-1:0][LsuNofRss-1:0][LsuNofOperands-1:0] lsu_op_rsps;
  logic         [NofLsus-1:0][LsuNofRss-1:0][LsuNofOperands-1:0] lsu_op_rsps_valid;
  logic         [NofLsus-1:0][LsuNofRss-1:0][LsuNofOperands-1:0] lsu_op_rsps_ready;

  operand_req_t [NofFpus-1:0][FpuNofRss-1:0][FpuNofOperands-1:0] fpu_op_reqs;
  logic         [NofFpus-1:0][FpuNofRss-1:0][FpuNofOperands-1:0] fpu_op_reqs_valid;
  logic         [NofFpus-1:0][FpuNofRss-1:0][FpuNofOperands-1:0] fpu_op_reqs_ready;
  res_req_t     [NofFpus-1:0][FpuNofRss-1:0]                     fpu_res_reqs;
  logic         [NofFpus-1:0][FpuNofRss-1:0]                     fpu_res_reqs_valid;
  logic         [NofFpus-1:0][FpuNofRss-1:0]                     fpu_res_reqs_ready;
  res_rsp_t     [NofFpus-1:0][FpuNofRss-1:0]                     fpu_res_rsps;
  logic         [NofFpus-1:0][FpuNofRss-1:0]                     fpu_res_rsps_valid;
  logic         [NofFpus-1:0][FpuNofRss-1:0]                     fpu_res_rsps_ready;
  operand_t     [NofFpus-1:0][FpuNofRss-1:0][FpuNofOperands-1:0] fpu_op_rsps;
  logic         [NofFpus-1:0][FpuNofRss-1:0][FpuNofOperands-1:0] fpu_op_rsps_valid;
  logic         [NofFpus-1:0][FpuNofRss-1:0][FpuNofOperands-1:0] fpu_op_rsps_ready;

  // Map the operand requests and responses to a linear array to connect to the xbar.
  // The array index must match the operand / consumer id.
  always_comb begin : fu_op_reqs_rsps
    automatic integer ope_if = 0;

    op_reqs           = '0;
    op_reqs_valid     = '0;
    alu_op_reqs_ready = '0;
    lsu_op_reqs_ready = '0;
    fpu_op_reqs_ready = '0;

    op_rsps_ready     = '0;
    alu_op_rsps       = '0;
    alu_op_rsps_valid = '0;
    lsu_op_rsps       = '0;
    lsu_op_rsps_valid = '0;
    fpu_op_rsps       = '0;
    fpu_op_rsps_valid = '0;

    for (int alu = 0; alu < NofAlus; alu++) begin
      for (int rss = 0; rss < AluNofRss; rss++) begin
        for (int op = 0; op < AluNofOperands; op++) begin
          // operand requests
          op_reqs[ope_if]                 = alu_op_reqs[alu][rss][op];
          op_reqs_valid[ope_if]           = alu_op_reqs_valid[alu][rss][op];
          alu_op_reqs_ready[alu][rss][op] = op_reqs_ready[ope_if];
          // operand responses
          alu_op_rsps[alu][rss][op]       = op_rsps[ope_if];
          alu_op_rsps_valid[alu][rss][op] = op_rsps_valid[ope_if];
          op_rsps_ready[ope_if]           = alu_op_rsps_ready[alu][rss][op];
          ope_if = ope_if + 1;
        end
      end
    end
    for (int lsu = 0; lsu < NofLsus; lsu++) begin
      for (int rss = 0; rss < LsuNofRss; rss++) begin
        for (int op = 0; op < LsuNofOperands; op++) begin
          // operand requests
          op_reqs[ope_if]                 = lsu_op_reqs[lsu][rss][op];
          op_reqs_valid[ope_if]           = lsu_op_reqs_valid[lsu][rss][op];
          lsu_op_reqs_ready[lsu][rss][op] = op_reqs_ready[ope_if];
          // operand responses
          lsu_op_rsps[lsu][rss][op]       = op_rsps[ope_if];
          lsu_op_rsps_valid[lsu][rss][op] = op_rsps_valid[ope_if];
          op_rsps_ready[ope_if]           = lsu_op_rsps_ready[lsu][rss][op];
          ope_if = ope_if + 1;
        end
      end
    end
    for (int fpu = 0; fpu < NofFpus; fpu++) begin
      for (int rss = 0; rss < FpuNofRss; rss++) begin
        for (int op = 0; op < FpuNofOperands; op++) begin
          // operand requests
          op_reqs[ope_if]                 = fpu_op_reqs[fpu][rss][op];
          op_reqs_valid[ope_if]           = fpu_op_reqs_valid[fpu][rss][op];
          fpu_op_reqs_ready[fpu][rss][op] = op_reqs_ready[ope_if];
          // operand responses
          fpu_op_rsps[fpu][rss][op]       = op_rsps[ope_if];
          fpu_op_rsps_valid[fpu][rss][op] = op_rsps_valid[ope_if];
          op_rsps_ready[ope_if]           = fpu_op_rsps_ready[fpu][rss][op];
          ope_if = ope_if + 1;
        end
      end
    end
  end

  // Map the res reqs and rsps to a linear array to connect to the xbar.
  // The array index must match the result / producer id.
  always_comb begin : fu_res_reqs_rsps
    automatic integer res_if = 0;

    res_reqs_ready     = '0;
    alu_res_reqs       = '0;
    alu_res_reqs_valid = '0;
    lsu_res_reqs       = '0;
    fpu_res_reqs       = '0;

    res_rsps           = '0;
    res_rsps_valid     = '0;
    alu_res_rsps_ready = '0;
    lsu_res_rsps_ready = '0;
    fpu_res_rsps_ready = '0;

    for (int alu = 0; alu < NofAlus; alu++) begin
      for (int rss = 0; rss < AluNofRss; rss++) begin
        // requests
        alu_res_reqs[alu][rss]       = res_reqs[res_if];
        alu_res_reqs_valid[alu][rss] = res_reqs_valid[res_if];
        res_reqs_ready[res_if]       = alu_res_reqs_ready[alu][rss];
        // responses
        res_rsps[res_if]             = alu_res_rsps[alu][rss];
        res_rsps_valid[res_if]       = alu_res_rsps_valid[alu][rss];
        alu_res_rsps_ready[alu][rss] = res_rsps_ready[res_if];

        res_if = res_if + 1;
      end
    end
    for (int lsu = 0; lsu < NofLsus; lsu++) begin
      for (int rss = 0; rss < LsuNofRss; rss++) begin
        // requests
        lsu_res_reqs[lsu][rss]       = res_reqs[res_if];
        lsu_res_reqs_valid[lsu][rss] = res_reqs_valid[res_if];
        res_reqs_ready[res_if]       = lsu_res_reqs_ready[lsu][rss];
        // responses
        res_rsps[res_if]             = lsu_res_rsps[lsu][rss];
        res_rsps_valid[res_if]       = lsu_res_rsps_valid[lsu][rss];
        lsu_res_rsps_ready[lsu][rss] = res_rsps_ready[res_if];

        res_if = res_if + 1;
      end
    end
    for (int fpu = 0; fpu < NofFpus; fpu++) begin
      for (int rss = 0; rss < FpuNofRss; rss++) begin
        // requests
        fpu_res_reqs[fpu][rss]       = res_reqs[res_if];
        fpu_res_reqs_valid[fpu][rss] = res_reqs_valid[res_if];
        res_reqs_ready[res_if]       = fpu_res_reqs_ready[fpu][rss];
        // responses
        res_rsps[res_if]             = fpu_res_rsps[fpu][rss];
        res_rsps_valid[res_if]       = fpu_res_rsps_valid[fpu][rss];
        fpu_res_rsps_ready[fpu][rss] = res_rsps_ready[res_if];

        res_if = res_if + 1;
      end
    end
  end

  // ---------------------------
  // Operand distribution network - request xbar
  // ---------------------------
  res_req_t     [NofOperandIfs-1:0] op_reqs_requests;
  producer_id_t [NofOperandIfs-1:0] op_reqs_producers;
  for (genvar i = 0; i < NofOperandIfs; i++) begin : gen_flatten_op_reqs
    assign op_reqs_requests[i]  = op_reqs[i].request;
    assign op_reqs_producers[i] = op_reqs[i].producer;
  end
  stream_xbar #(
    .NumInp     (NofOperandIfs),
    .NumOut     (NofResultIfs),
    .payload_t  (res_req_t),
    .OutSpillReg(0),
    .ExtPrio    (0),
    .AxiVldRdy  (0),
    .LockIn     (0),
    .AxiVldMask ('0)
  ) i_request_xbar (
    .clk_i,
    .rst_ni (~rst_i),
    .flush_i('0),
    .rr_i   ('0),
    .data_i (op_reqs_requests),
    .sel_i  (op_reqs_producers),
    .valid_i(op_reqs_valid),
    .ready_o(op_reqs_ready),
    .data_o (res_reqs),
    .idx_o  (),
    .valid_o(res_reqs_valid),
    .ready_i(res_reqs_ready)
  );

  // ---------------------------
  // Operand distribution network - response xbar
  // ---------------------------
  operand_t    [NofResultIfs-1:0] res_rsps_operands;
  operand_id_t [NofResultIfs-1:0] res_rsps_consumers;
  for (genvar i = 0; i < NofResultIfs; i++) begin : gen_flatten_res_rsps
    assign res_rsps_operands[i]  = res_rsps[i].operand;
    assign res_rsps_consumers[i] = res_rsps[i].consumer;
  end
  stream_xbar #(
    .NumInp     (NofResultIfs),
    .NumOut     (NofOperandIfs),
    .payload_t  (operand_t),
    .OutSpillReg(0),
    .ExtPrio    (0),
    .AxiVldRdy  (0),
    .LockIn     (0),
    .AxiVldMask ('0)
  ) i_response_xbar (
    .clk_i,
    .rst_ni (~rst_i),
    .flush_i('0),
    .rr_i   ('0),
    .data_i (res_rsps_operands),
    .sel_i  (res_rsps_consumers),
    .valid_i(res_rsps_valid),
    .ready_o(res_rsps_ready),
    .data_o (op_rsps),
    .idx_o  (),
    .valid_o(op_rsps_valid),
    .ready_i(op_rsps_ready)
  );

  // ---------------------------
  // ALUs
  // ---------------------------
  typedef struct packed {
    alu_result_t result;
    instr_tag_t  tag;
  } alu_result_and_tag_t;

  alu_result_and_tag_t [NofAlus-1:0] alu_wbs_result_and_tag;
  logic                [NofAlus-1:0] alu_wbs_result_valid;
  logic                [NofAlus-1:0] alu_wbs_result_ready;

  for (genvar alu = 0; alu < NofAlus; alu++) begin : gen_alus
    // Helper signals to merge the result and tag
    alu_result_t alu_wb_result;
    instr_tag_t  alu_wb_result_tag;

    // Signals connecting the FU block and the actual FU
    issue_req_t  alu_issue_req;
    logic        alu_issue_req_valid;
    logic        alu_issue_req_ready;
    alu_result_t alu_result;
    instr_tag_t  alu_result_tag;
    logic        alu_result_valid;
    logic        alu_result_ready;
    logic        alu_busy;

    producer_id_t producer_start_id;
    operand_id_t  op_start_id;
    assign producer_start_id = producer_id_t'(AluRsIdOffset + alu * AluNofRss);
    assign op_start_id       = operand_id_t'(AluOpIdOffset + alu * AluNofRss * AluNofOperands);

    schnizo_fu_block #(
      .disp_req_t    (disp_req_t),
      .disp_rsp_t    (disp_rsp_t),
      .issue_req_t   (issue_req_t),
      .result_t      (alu_result_t),
      .instr_tag_t   (instr_tag_t),
      .NofRss        (AluNofRss),
      .NofOperands   (AluNofOperands),
      .ConsumerCount (ConsumerCount),
      .RegAddrWidth  (RegAddrWidth),
      .MaxIterationsW(MaxIterationsW),
      .producer_id_t (producer_id_t),
      .operand_id_t  (operand_id_t),
      .operand_req_t (operand_req_t),
      .operand_t     (operand_t),
      .res_req_t     (res_req_t),
      .res_rsp_t     (res_rsp_t)
    ) i_alu_block (
      .clk_i,
      .rst_i,
      /// RS control signals
      .producer_id_i   (producer_start_id),
      .op_start_id_i   (op_start_id),
      .restart_i       (restart_i),
      .loop_state_i    (loop_state_i),
      .lep_iterations_i(lep_iterations_i),
      .goto_lcp2_i     (goto_lcp2_i),
      .fu_busy_i       (alu_busy),
      .loop_finish_o   (alu_loop_finish_o[alu]),
      .rs_full_o       (alu_rs_full_o[alu]),
      /// Instruction stream
      // From dispatcher
      .disp_req_i       (disp_req_i),
      .disp_req_valid_i (alu_disp_reqs_valid_i[alu]),
      .disp_req_ready_o (alu_disp_reqs_ready_o[alu]),
      .disp_rsp_o       (alu_disp_rsp_o[alu]),
      // To FU
      .issue_req_o      (alu_issue_req),
      .issue_req_valid_o(alu_issue_req_valid),
      .issue_req_ready_i(alu_issue_req_ready),
      // From FU
      .result_i         (alu_result),
      .result_tag_i     (alu_result_tag),
      .result_valid_i   (alu_result_valid),
      .result_ready_o   (alu_result_ready),
      // To writeback
      .wb_result_o      (alu_wb_result),
      .wb_result_tag_o  (alu_wb_result_tag),
      .wb_result_valid_o(alu_wbs_result_valid[alu]),
      .wb_result_ready_i(alu_wbs_result_ready[alu]),
      /// Operand distribution network
      .op_reqs_o       (alu_op_reqs[alu]),
      .op_reqs_valid_o (alu_op_reqs_valid[alu]),
      .op_reqs_ready_i (alu_op_reqs_ready[alu]),
      .res_reqs_i      (alu_res_reqs[alu]),
      .res_reqs_valid_i(alu_res_reqs_valid[alu]),
      .res_reqs_ready_o(alu_res_reqs_ready[alu]),
      .res_rsps_o      (alu_res_rsps[alu]),
      .res_rsps_valid_o(alu_res_rsps_valid[alu]),
      .res_rsps_ready_i(alu_res_rsps_ready[alu]),
      .op_rsps_i       (alu_op_rsps[alu]),
      .op_rsps_valid_i (alu_op_rsps_valid[alu]),
      .op_rsps_ready_o (alu_op_rsps_ready[alu])
    );
    assign alu_wbs_result_and_tag[alu].result = alu_wb_result;
    assign alu_wbs_result_and_tag[alu].tag    = alu_wb_result_tag;

    schnizo_alu #(
      .XLEN       (XLEN),
      .HasBranch  (alu == '0), // only the first ALU has the branch logic
      .issue_req_t(issue_req_t),
      .instr_tag_t(instr_tag_t)
    ) i_alu (
      .clk_i,
      .rst_i,
      .issue_req_i      (alu_issue_req),
      .issue_req_valid_i(alu_issue_req_valid),
      .issue_req_ready_o(alu_issue_req_ready),
      .result_o         (alu_result.result),
      .compare_res_o    (alu_result.compare_res),
      .tag_o            (alu_result_tag),
      .result_valid_o   (alu_result_valid),
      .result_ready_i   (alu_result_ready),
      .busy_o           (alu_busy)
    );
  end

  // ALU writeback arbiter
  alu_result_and_tag_t alu_wb_result_and_tag_out;
  stream_arbiter #(
    .DATA_T (alu_result_and_tag_t),
    .N_INP  (NofAlus),
    .ARBITER("rr")
  ) i_alu_wb_arbiter (
    .clk_i,
    .rst_ni     (~rst_i),
    .inp_data_i (alu_wbs_result_and_tag),
    .inp_valid_i(alu_wbs_result_valid),
    .inp_ready_o(alu_wbs_result_ready),
    .oup_data_o (alu_wb_result_and_tag_out),
    .oup_valid_o(alu_wb_result_valid_o),
    .oup_ready_i(alu_wb_result_ready_i)
  );

  assign alu_wb_result_o     = alu_wb_result_and_tag_out.result;
  assign alu_wb_result_tag_o = alu_wb_result_and_tag_out.tag;

  // ---------------------------
  // LSUs
  // ---------------------------
  // The LSU always returns a data_t value. Define a type for clarity.
  typedef data_t lsu_result_t;
  typedef struct packed {
    lsu_result_t result;
    instr_tag_t  tag;
  } lsu_result_and_tag_t;

  logic                [NofLsus-1:0] lsu_empty;
  logic                [NofLsus-1:0] lsu_addr_misaligned;
  lsu_result_and_tag_t [NofLsus-1:0] lsu_wbs_result_and_tag;
  logic                [NofLsus-1:0] lsu_wbs_result_valid;
  logic                [NofLsus-1:0] lsu_wbs_result_ready;

  for (genvar lsu = 0; lsu < NofLsus; lsu++) begin : gen_lsus
    // Helper signals to merge the result and tag
    lsu_result_t lsu_wb_result;
    instr_tag_t  lsu_wb_result_tag;

    // Signals connecting the FU block and the actual FU
    issue_req_t  lsu_issue_req;
    logic        lsu_issue_req_valid;
    logic        lsu_issue_req_ready;
    lsu_result_t lsu_result;
    instr_tag_t  lsu_result_tag;
    logic        lsu_result_valid;
    logic        lsu_result_ready;
    logic        lsu_busy;

    producer_id_t producer_start_id;
    operand_id_t  op_start_id;
    assign producer_start_id = producer_id_t'(LsuRsIdOffset + lsu * LsuNofRss);
    assign op_start_id       = operand_id_t'(LsuOpIdOffset + lsu * LsuNofRss * LsuNofOperands);

    schnizo_fu_block #(
      .disp_req_t    (disp_req_t),
      .disp_rsp_t    (disp_rsp_t),
      .issue_req_t   (issue_req_t),
      .result_t      (lsu_result_t),
      .instr_tag_t   (instr_tag_t),
      .NofRss        (LsuNofRss),
      .NofOperands   (LsuNofOperands),
      .ConsumerCount (ConsumerCount),
      .RegAddrWidth  (RegAddrWidth),
      .MaxIterationsW(MaxIterationsW),
      .producer_id_t (producer_id_t),
      .operand_id_t  (operand_id_t),
      .operand_req_t (operand_req_t),
      .operand_t     (operand_t),
      .res_req_t     (res_req_t),
      .res_rsp_t     (res_rsp_t)
    ) i_lsu_block (
      .clk_i,
      .rst_i,
      /// RS control signals
      .producer_id_i   (producer_start_id),
      .op_start_id_i   (op_start_id),
      .restart_i       (restart_i),
      .loop_state_i    (loop_state_i),
      .lep_iterations_i(lep_iterations_i),
      .goto_lcp2_i     (goto_lcp2_i),
      .fu_busy_i       (lsu_busy),
      .loop_finish_o   (lsu_loop_finish_o[lsu]),
      .rs_full_o       (lsu_rs_full_o[lsu]),
      /// Instruction stream
      // From dispatcher
      .disp_req_i       (disp_req_i),
      .disp_req_valid_i (lsu_disp_reqs_valid_i[lsu]),
      .disp_req_ready_o (lsu_disp_reqs_ready_o[lsu]),
      .disp_rsp_o       (lsu_disp_rsp_o[lsu]),
      // To FU
      .issue_req_o      (lsu_issue_req),
      .issue_req_valid_o(lsu_issue_req_valid),
      .issue_req_ready_i(lsu_issue_req_ready),
      // From FU
      .result_i         (lsu_result),
      .result_tag_i     (lsu_result_tag),
      .result_valid_i   (lsu_result_valid),
      .result_ready_o   (lsu_result_ready),
      // To writeback
      .wb_result_o      (lsu_wb_result),
      .wb_result_tag_o  (lsu_wb_result_tag),
      .wb_result_valid_o(lsu_wbs_result_valid[lsu]),
      .wb_result_ready_i(lsu_wbs_result_ready[lsu]),
      /// Operand distribution network
      .op_reqs_o       (lsu_op_reqs[lsu]),
      .op_reqs_valid_o (lsu_op_reqs_valid[lsu]),
      .op_reqs_ready_i (lsu_op_reqs_ready[lsu]),
      .res_reqs_i      (lsu_res_reqs[lsu]),
      .res_reqs_valid_i(lsu_res_reqs_valid[lsu]),
      .res_reqs_ready_o(lsu_res_reqs_ready[lsu]),
      .res_rsps_o      (lsu_res_rsps[lsu]),
      .res_rsps_valid_o(lsu_res_rsps_valid[lsu]),
      .res_rsps_ready_i(lsu_res_rsps_ready[lsu]),
      .op_rsps_i       (lsu_op_rsps[lsu]),
      .op_rsps_valid_i (lsu_op_rsps_valid[lsu]),
      .op_rsps_ready_o (lsu_op_rsps_ready[lsu])
    );
    assign lsu_wbs_result_and_tag[lsu].result = lsu_wb_result;
    assign lsu_wbs_result_and_tag[lsu].tag    = lsu_wb_result_tag;

    schnizo_lsu #(
      .XLEN               (XLEN),
      .issue_req_t        (issue_req_t),
      .AddrWidth          (AddrWidth),
      .DataWidth          (DataWidth),
      .dreq_t             (dreq_t),
      .drsp_t             (drsp_t),
      .tag_t              (instr_tag_t),
      .NumOutstandingMem  (NumOutstandingMem),
      .NumOutstandingLoads(NumOutstandingLoads),
      .Caq                (0), // TODO: Enable
      .CaqDepth           (CaqDepth),
      .CaqTagWidth        (CaqTagWidth),
      .CaqRespSrc         (0),
      .CaqRespTrackSeq    (0)
    ) i_lsu (
      .clk_i,
      .rst_i,
      .issue_req_i      (lsu_issue_req),
      .issue_req_valid_i(lsu_issue_req_valid),
      .issue_req_ready_o(lsu_issue_req_ready),
      .result_o         (lsu_result),
      .tag_o            (lsu_result_tag),
      .result_error_o   (), // ignored
      .result_valid_o   (lsu_result_valid),
      .result_ready_i   (lsu_result_ready),
      .busy_o           (lsu_busy),
      .empty_o          (lsu_empty[lsu]),
      .addr_misaligned_o(lsu_addr_misaligned[lsu]),
      .data_req_o       (lsu_dreq_o[lsu]),
      .data_rsp_i       (lsu_drsp_i[lsu]),
      .caq_addr_i       (caq_addr_i[lsu]),
      .caq_track_write_i(caq_track_write_i[lsu]),
      .caq_req_valid_i  (caq_req_valid_i[lsu]),
      .caq_req_ready_o  (caq_req_ready_o[lsu]),
      .caq_rsp_valid_i  (caq_rsp_valid_i[lsu]),
      .caq_rsp_valid_o  (caq_rsp_valid_o[lsu])
    );
  end

  // LSU empty & misalign signal combination
  assign lsu_empty_o           = &lsu_empty;
  assign lsu_addr_misaligned_o = |lsu_addr_misaligned;

  // LSU writeback arbiter
  lsu_result_and_tag_t lsu_wb_result_and_tag_out;
  stream_arbiter #(
    .DATA_T (lsu_result_and_tag_t),
    .N_INP  (NofLsus),
    .ARBITER("rr")
  ) i_lsu_wb_arbiter (
    .clk_i,
    .rst_ni     (~rst_i),
    .inp_data_i (lsu_wbs_result_and_tag),
    .inp_valid_i(lsu_wbs_result_valid),
    .inp_ready_o(lsu_wbs_result_ready),
    .oup_data_o (lsu_wb_result_and_tag_out),
    .oup_valid_o(lsu_wb_result_valid_o),
    .oup_ready_i(lsu_wb_result_ready_i)
  );

  assign lsu_wb_result_o     = lsu_wb_result_and_tag_out.result;
  assign lsu_wb_result_tag_o = lsu_wb_result_and_tag_out.tag;

  // LSU memory interface arbiter

  // ---------------------------
  // FPUs
  // ---------------------------
  typedef logic [FLEN-1:0] fpu_result_t;

  typedef struct packed {
    fpu_result_t result;
    instr_tag_t  tag;
  } fpu_result_and_tag_t;

  // Keep the handshake signals to combine the fpu status
  logic                [NofFpus-1:0] fpu_result_valid;
  logic                [NofFpus-1:0] fpu_result_ready;
  fpnew_pkg::status_t  [NofFpus-1:0] fpu_status;
  fpu_result_and_tag_t [NofFpus-1:0] fpu_wbs_result_and_tag;
  logic                [NofFpus-1:0] fpu_wbs_result_valid;
  logic                [NofFpus-1:0] fpu_wbs_result_ready;

  for (genvar fpu = 0; fpu < NofFpus; fpu++) begin : gen_fpus
    // Helper signals to merge the result and tag
    fpu_result_t fpu_wb_result;
    instr_tag_t  fpu_wb_result_tag;

    // Signals connecting the FU block and the actual FU
    issue_req_t  fpu_issue_req;
    logic        fpu_issue_req_valid;
    logic        fpu_issue_req_ready;
    fpu_result_t fpu_result;
    instr_tag_t  fpu_result_tag;
    logic        fpu_busy;

    producer_id_t producer_start_id;
    operand_id_t  op_start_id;
    assign producer_start_id = producer_id_t'(FpuRsIdOffset + fpu * FpuNofRss);
    assign op_start_id       = operand_id_t'(FpuOpIdOffset + fpu * FpuNofRss * FpuNofOperands);

    schnizo_fu_block #(
      .disp_req_t    (disp_req_t),
      .disp_rsp_t    (disp_rsp_t),
      .issue_req_t   (issue_req_t),
      .result_t      (fpu_result_t),
      .instr_tag_t   (instr_tag_t),
      .NofRss        (FpuNofRss),
      .NofOperands   (FpuNofOperands),
      .ConsumerCount (ConsumerCount),
      .RegAddrWidth  (RegAddrWidth),
      .MaxIterationsW(MaxIterationsW),
      .producer_id_t (producer_id_t),
      .operand_id_t  (operand_id_t),
      .operand_req_t (operand_req_t),
      .operand_t     (operand_t),
      .res_req_t     (res_req_t),
      .res_rsp_t     (res_rsp_t)
    ) i_fpu_block (
      .clk_i,
      .rst_i,
      /// RS control signals
      .producer_id_i   (producer_start_id),
      .op_start_id_i   (op_start_id),
      .restart_i       (restart_i),
      .loop_state_i    (loop_state_i),
      .lep_iterations_i(lep_iterations_i),
      .goto_lcp2_i     (goto_lcp2_i),
      .fu_busy_i       (fpu_busy),
      .loop_finish_o   (fpu_loop_finish_o[fpu]),
      .rs_full_o       (fpu_rs_full_o[fpu]),
      /// Instruction stream
      // From dispatcher
      .disp_req_i       (disp_req_i),
      .disp_req_valid_i (fpu_disp_reqs_valid_i[fpu]),
      .disp_req_ready_o (fpu_disp_reqs_ready_o[fpu]),
      .disp_rsp_o       (fpu_disp_rsp_o[fpu]),
      // To FU
      .issue_req_o      (fpu_issue_req),
      .issue_req_valid_o(fpu_issue_req_valid),
      .issue_req_ready_i(fpu_issue_req_ready),
      // From FU
      .result_i         (fpu_result),
      .result_tag_i     (fpu_result_tag),
      .result_valid_i   (fpu_result_valid[fpu]),
      .result_ready_o   (fpu_result_ready[fpu]),
      // To writeback
      .wb_result_o      (fpu_wb_result),
      .wb_result_tag_o  (fpu_wb_result_tag),
      .wb_result_valid_o(fpu_wbs_result_valid[fpu]),
      .wb_result_ready_i(fpu_wbs_result_ready[fpu]),
      /// Operand distribution network
      .op_reqs_o       (fpu_op_reqs[fpu]),
      .op_reqs_valid_o (fpu_op_reqs_valid[fpu]),
      .op_reqs_ready_i (fpu_op_reqs_ready[fpu]),
      .res_reqs_i      (fpu_res_reqs[fpu]),
      .res_reqs_valid_i(fpu_res_reqs_valid[fpu]),
      .res_reqs_ready_o(fpu_res_reqs_ready[fpu]),
      .res_rsps_o      (fpu_res_rsps[fpu]),
      .res_rsps_valid_o(fpu_res_rsps_valid[fpu]),
      .res_rsps_ready_i(fpu_res_rsps_ready[fpu]),
      .op_rsps_i       (fpu_op_rsps[fpu]),
      .op_rsps_valid_i (fpu_op_rsps_valid[fpu]),
      .op_rsps_ready_o (fpu_op_rsps_ready[fpu])
    );
    assign fpu_wbs_result_and_tag[fpu].result = fpu_wb_result;
    assign fpu_wbs_result_and_tag[fpu].tag    = fpu_wb_result_tag;

    schnizo_fpu #(
      .FPUImplementation(FPUImplementation),
      .RVF              (RVF),
      .RVD              (RVD),
      .XF16             (XF16),
      .XF16ALT          (XF16ALT),
      .XF8              (XF8),
      .XF8ALT           (XF8ALT),
      .XFVEC            (XFVEC),
      .FLEN             (FLEN),
      .RegisterFPUIn    (RegisterFPUIn),
      .RegisterFPUOut   (RegisterFPUOut),
      .issue_req_t      (issue_req_t),
      .instr_tag_t      (instr_tag_t)
    ) i_fpu (
      .clk_i,
      .rst_ni           (~rst_i),
      .hart_id_i        (hard_id_i),
      .issue_req_i      (fpu_issue_req),
      .issue_req_valid_i(fpu_issue_req_valid),
      .issue_req_ready_o(fpu_issue_req_ready),
      .result_o         (fpu_result),
      .tag_o            (fpu_result_tag),
      .result_valid_o   (fpu_result_valid[fpu]),
      .result_ready_i   (fpu_result_ready[fpu]),
      .status_o         (fpu_status[fpu]),
      .busy_o           (fpu_busy)
    );
  end

  // FU status combintation
  // During LEP we still want to capture all FCSR status updates. So we must combine all valid
  // status values and generate a valid bit. The valid bit ensures that we update the FCSR only
  // on a handshake.
  logic               fpu_status_valid;
  fpnew_pkg::status_t combined_fpu_status;

  always_comb begin
    fpu_status_valid    = 1'b0;
    combined_fpu_status = '0;
    for (int fpu = 0; fpu < NofFpus; fpu++) begin
      if (fpu_result_valid[fpu] && fpu_result_ready[fpu]) begin
        fpu_status_valid = 1'b1;
        combined_fpu_status = combined_fpu_status | fpu_status[fpu];
      end
    end
  end

  assign fpu_status_o       = combined_fpu_status;
  assign fpu_status_valid_o = fpu_status_valid;

  // FPU writeback arbiter
  fpu_result_and_tag_t fpu_wb_result_and_tag_out;
  stream_arbiter #(
    .DATA_T (fpu_result_and_tag_t),
    .N_INP  (NofFpus),
    .ARBITER("rr")
  ) i_fpu_wb_arbiter (
    .clk_i,
    .rst_ni     (~rst_i),
    .inp_data_i (fpu_wbs_result_and_tag),
    .inp_valid_i(fpu_wbs_result_valid),
    .inp_ready_o(fpu_wbs_result_ready),
    .oup_data_o (fpu_wb_result_and_tag_out),
    .oup_valid_o(fpu_wb_result_valid_o),
    .oup_ready_i(fpu_wb_result_ready_i)
  );

  assign fpu_wb_result_o     = fpu_wb_result_and_tag_out.result;
  assign fpu_wb_result_tag_o = fpu_wb_result_and_tag_out.tag;

  // ---------------------------
  // Finish signals
  // ---------------------------
  // The complete core finishes if all RS finish.
  assign all_rs_finish_o = &{&alu_loop_finish_o, &lsu_loop_finish_o, &fpu_loop_finish_o};

endmodule
