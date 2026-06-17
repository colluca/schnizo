// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// TODO(colluca): there's a lot of common boilerplate in the connection between an
// RS and its FU. Can we reduce it and improve code reuse?
// TODO(colluca): move ODN to its own module.

`include "common_cells/registers.svh"

// The module hosting all RSs and FUs.
//
// Instantiates all the FUs and connects each FU to an FU block (containing the RS).
// Further instantiates the operand distribution network (ODN) and connects FU blocks to it.
module schnizo_fu_stage import schnizo_pkg::*, schnizo_tracer_pkg::*, cf_math_pkg::*; #(
  // Globally enable the superscalar feature
  parameter bit          Xfrep             = 1,
  parameter bit          MulInAlu0         = 1'b1,
  parameter int unsigned NofAlus           = 1,
  parameter int unsigned AluNofRss         = 3,
  parameter int unsigned AluNofConstants   = 4,
  parameter int unsigned AluNofOperands    = 2,
  parameter int unsigned AluNofResReqIfs   = 3,
  parameter int unsigned AluNofResRspPorts = 1,
  parameter int unsigned NofLsus           = 1,
  parameter int unsigned LsuNofRss         = 3,
  parameter int unsigned LsuNofConstants   = 4,
  parameter int unsigned LsuNofOperands    = 4,
  parameter int unsigned LsuNofResReqIfs   = 3,
  parameter int unsigned LsuNofResRspPorts = 1,
  parameter int unsigned NofFpus           = 1,
  parameter int unsigned FpuNofRss         = 2,
  parameter int unsigned FpuNofConstants   = 4,
  parameter int unsigned FpuNofOperands    = 3,
  parameter int unsigned FpuNofResReqIfs   = 3,
  parameter int unsigned FpuNofResRspPorts = 1,
  parameter bit UseAluLsu = 0,
  parameter bit PostIncrement = 0,
  parameter int unsigned NofAluLsus         = 1,
  parameter int unsigned AluLsuNofRsis       = 3,
  parameter int unsigned AluLsuNofRsrs      = 3,
  parameter int unsigned AluLsuNofConstants   = 4,
  parameter int unsigned AluLsuNofOperands  = 3,
  parameter int unsigned AluLsuNofResReqIfs = 3,
  parameter int unsigned AluLsuNofResRspPorts = 1,
  parameter int unsigned AluLsuNofResPorts = 2,
  // The following 3 NofIfs parameters depend directly on the previous FU specific Nof parameters
  // but they must be defined on the outer scope as they are needed there as well.
  // Make sure to match them!
  // TODO(colluca): use a function or something to ensure the consistency of these parameters.
  parameter int unsigned NofOperandIfs   = 1,
  parameter int unsigned NofResReqIfs    = 1,
  parameter int unsigned XLEN            = 32,
  parameter int unsigned FLEN            = 64,
  parameter int unsigned OpLen           = 64,
  parameter int unsigned AddrWidth       = 32,
  parameter int unsigned DataWidth       = 32,
  parameter int unsigned RegAddrWidth    = 5,
  parameter int unsigned MaxIterationsW  = 5,
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
  parameter type         result_slot_id_t = logic,
  parameter type         rs_id_t        = logic,
  parameter type         operand_id_t   = logic, // used for tracer function
  parameter type         disp_req_t     = logic,
  parameter type         disp_rsp_t     = logic,
  parameter type         fu_data_t      = logic,
  parameter type         instr_tag_t    = logic,
  parameter type         issue_req_t    = logic,
  parameter type         alu_result_t   = logic,
  parameter type         alu_res_val_t  = logic,
  parameter type         alu_lsu_result_t   = alu_result_t,
  parameter type         dreq_t         = logic,
  parameter type         drsp_t         = logic,
  localparam type addr_t = logic [AddrWidth-1:0],
  localparam type data_t = logic [DataWidth-1:0]
) (
  input  logic        clk_i,
  input  logic        rst_i,
  input  logic [31:0] hard_id_i,

  // Trace outputs
  // pragma translate_off
  output issue_alu_trace_t      alu_trace_o             [0:iomsb(NofAlus)],
  output issue_lsu_trace_t      lsu_trace_o             [0:iomsb(NofLsus)],
  output issue_alu_lsu_trace_t  alu_lsu_trace_o         [0:iomsb(NofAluLsus)],
  output issue_fpu_trace_t      fpu_trace_o             [0:iomsb(NofFpus)],
  output retire_fu_trace_t      alu_retire_trace_o      [0:iomsb(NofAlus)],
  output retire_fu_trace_t      lsu_retire_trace_o      [0:iomsb(NofLsus)],
  output retire_fu_trace_t      alu_lsu_retire_trace_o  [0:iomsb(NofAluLsus)][0:iomsb(AluLsuNofResPorts)],
  output retire_fu_trace_t      fpu_retire_trace_o      [0:iomsb(NofFpus)],
  // pragma translate_on

  /// RS control signals
  input  logic                      restart_i,
  input  loop_state_e               loop_state_i,
  input  logic [MaxIterationsW-1:0] lep_iterations_i,
  input  logic                      goto_lcp2_i,
  // Asserted if all RS are either finishing in this cycle or have already finished
  output logic                      all_rs_finish_o,

  /// Instruction streams & FU status signals
  input  disp_req_t               disp_req_i,
  // Commit the dispatch request and allow the downstream passing.
  // The FU blocks do not require a commit signal as when we won't commit we have an exception
  // and thus anyway abort the LxP and reset the RS and RSSs.
  input  logic                    instr_exec_commit_i,
  // FPU-specific commit: same as instr_exec_commit_i but without instr_addr_misaligned_o in its
  // timing cone (FP instructions are never branches, so instr_addr_misaligned_o is always 0).
  input  logic                    fpu_instr_exec_commit_i,
  input  logic      [iomsb(NofAlus):0] alu_disp_reqs_valid_i,
  output logic      [iomsb(NofAlus):0] alu_disp_reqs_ready_o,
  output disp_rsp_t [iomsb(NofAlus):0] alu_disp_rsp_o,
  output logic      [iomsb(NofAlus):0] alu_rs_full_o,

  input  logic      [iomsb(NofLsus):0] lsu_disp_reqs_valid_i,
  output logic      [iomsb(NofLsus):0] lsu_disp_reqs_ready_o,
  output disp_rsp_t [iomsb(NofLsus):0] lsu_disp_rsp_o,
  output logic                    lsu_empty_o,
  output logic                    lsu_addr_misaligned_o,
  output dreq_t     [iomsb(NofLsus):0] lsu_dreq_o,
  input  drsp_t     [iomsb(NofLsus):0] lsu_drsp_i,
  output logic      [iomsb(NofLsus):0] lsu_rs_full_o,
  input  addr_t     [iomsb(NofLsus):0] caq_addr_i,
  input  logic      [iomsb(NofLsus):0] caq_track_write_i,
  input  logic      [iomsb(NofLsus):0] caq_req_valid_i,
  output logic      [iomsb(NofLsus):0] caq_req_ready_o,
  input  logic      [iomsb(NofLsus):0] caq_rsp_valid_i,
  output logic      [iomsb(NofLsus):0] caq_rsp_valid_o,

  input  logic      [iomsb(NofAluLsus):0] alu_lsu_disp_reqs_valid_i,
  output logic      [iomsb(NofAluLsus):0] alu_lsu_disp_reqs_ready_o,
  output disp_rsp_t [iomsb(NofAluLsus):0][PostIncrement:0] alu_lsu_disp_rsp_o,
  output logic      [iomsb(NofAluLsus):0] alu_lsu_rs_full_o,
  output dreq_t     [iomsb(NofAluLsus):0] alu_lsu_dreq_o,
  input  drsp_t     [iomsb(NofAluLsus):0] alu_lsu_drsp_i,

  input  logic               [iomsb(NofFpus):0] fpu_disp_reqs_valid_i,
  output logic               [iomsb(NofFpus):0] fpu_disp_reqs_ready_o,
  output disp_rsp_t          [iomsb(NofFpus):0] fpu_disp_rsp_o,
  output logic               [iomsb(NofFpus):0] fpu_rs_full_o,
  // Combined status of all FPUs
  output fpnew_pkg::status_t fpu_status_o,
  output logic               fpu_status_valid_o,

  // Writeback ports. We only have one per FU type.
  output alu_result_t alu_wb_result_o,
  output instr_tag_t  alu_wb_result_tag_o,
  output logic        alu_wb_result_valid_o,
  input  logic        alu_wb_result_ready_i,
  output alu_result_t branch_result_o,

  output data_t      lsu_wb_result_o,
  output instr_tag_t lsu_wb_result_tag_o,
  output logic       lsu_wb_result_valid_o,
  input  logic       lsu_wb_result_ready_i,

  output alu_lsu_result_t [AluLsuNofResPorts-1:0] alu_lsu_wb_results_o,
  output instr_tag_t      [AluLsuNofResPorts-1:0] alu_lsu_wb_result_tags_o,
  output logic            [AluLsuNofResPorts-1:0] alu_lsu_wb_results_valid_o,
  input  logic            [AluLsuNofResPorts-1:0] alu_lsu_wb_results_ready_i,

  output logic [FLEN-1:0] fpu_wb_result_o,
  output instr_tag_t      fpu_wb_result_tag_o,
  output logic            fpu_wb_result_valid_o,
  input  logic            fpu_wb_result_ready_i
);

  /////////////////////////////////////
  // Parameters and type definitions //
  /////////////////////////////////////

  // ---------------------------
  // RSS
  // ---------------------------

  // We need to know the total operands such that we can allocate the correct width for the
  // consumer count inside the FU stage.
  // In theory each other RSS in the system and the RSS itself could be a consumer. Thus use full width.
  // TODO: Add consumer count restriction to achieve a feasible bit width.
  localparam integer unsigned ConsumerCount = AluNofOperands * AluNofRss * NofAlus +
                                              LsuNofOperands * LsuNofRss * NofLsus +
                                              AluLsuNofOperands * AluLsuNofRsis * NofAluLsus +
                                              FpuNofOperands * FpuNofRss * NofFpus;

  // ---------------------------
  // Operand distribution network
  // ---------------------------

  localparam int unsigned NofRs = NofAlus + NofLsus + NofAluLsus + NofFpus;
  localparam int unsigned TotalNofRsrs = NofAlus * AluNofRss +
                                         NofLsus * LsuNofRss +
                                         NofAluLsus * AluLsuNofRsrs +
                                         NofFpus * FpuNofRss;
  localparam int unsigned TotalNofResRspPorts = NofAlus * AluNofResRspPorts +
                                                NofLsus * LsuNofResRspPorts +
                                                NofAluLsus * AluLsuNofResRspPorts +
                                                NofFpus * FpuNofResRspPorts;

  typedef int unsigned rs_param_array_t [NofRs-1:0];

  function automatic rs_param_array_t gen_rs_param_array(int AluParam, int LsuParam, int AluLsuParam, int FpuParam);
    rs_param_array_t tmp;
    int unsigned k;

    k = 0;
    for (int unsigned i = 0; i < NofAlus; i++) begin
      tmp[k] = AluParam;
      k++;
    end
    for (int unsigned i = 0; i < NofLsus; i++) begin
      tmp[k] = LsuParam;
      k++;
    end
    for (int unsigned i = 0; i < NofAluLsus; i++) begin
      tmp[k] = AluLsuParam;
      k++;
    end
    for (int unsigned i = 0; i < NofFpus; i++) begin
      tmp[k] = FpuParam;
      k++;
    end

    return tmp;
  endfunction

  localparam rs_param_array_t NofRsrs = gen_rs_param_array(AluNofRss, LsuNofRss, AluLsuNofRsrs, FpuNofRss);
  localparam rs_param_array_t NofRspPorts = gen_rs_param_array(AluNofResRspPorts,
    LsuNofResRspPorts, AluLsuNofResRspPorts, FpuNofResRspPorts);

  typedef struct packed {
    logic valid;
    logic iteration;
  } available_result_t;

  // The request arriving at the crossbar output connections. This is converted to a destination
  // mask inside the crossbar output logic. This mask is used to send the result to multiple
  // operands at once.
  typedef struct packed {
    logic            requested_iter;
    result_slot_id_t slot_id;
  } res_req_t;

  // The request going into the request crossbar
  // TODO(colluca): replace with a flat struct, called result_tag_t
  typedef struct packed {
    rs_id_t   producer; // where to place the request
    res_req_t request;
  } operand_req_t;

  // TODO(colluca): what does W stand for? In schnizo.sv there is actually a difference between the
  // two parameters
  localparam integer unsigned NofOperandIfsW = NofOperandIfs;

  // To which operand we should send the current result. This is a bitvector selecting each operand
  // where we want to send the result. The actual request uses the operand_id_t because this is
  // smaller and thus the request crossbar is also smaller. The conversion happens at the output of
  // the request crossbar. This signal then controls the response crossbar.
  typedef logic [NofOperandIfsW-1:0] dest_mask_t;

  // TODO(colluca): rename into simply res_req_t, and just unpack that struct
  typedef struct packed {
    dest_mask_t       dest_mask;
    result_slot_id_t  slot_id;
  } ext_res_req_t;

  // The data coming out of the response crossbar.
  typedef logic [OpLen-1:0] operand_t;

  // The request going into the response crossbar.
  typedef struct packed {
    dest_mask_t dest_mask; // where to send the response to
    operand_t   operand;
  } res_rsp_t;

  // ---------------------------
  // RS ID generation
  // ---------------------------

  // Each RS needs a globally unique ID. We simply count all RS.
  localparam integer unsigned AluRsIdOffset = 0;
  localparam integer unsigned LsuRsIdOffset = AluRsIdOffset + NofAlus;
  localparam integer unsigned AluLsuRsIdOffset = LsuRsIdOffset + NofLsus;
  localparam integer unsigned FpuRsIdOffset = AluLsuRsIdOffset + NofAluLsus;

  // Each RS needs a globally unique ID for its operand request ports.
  // These IDs are shared between the RSSs of a reservation station.
  localparam integer unsigned AluOpIdOffset = 0;
  localparam integer unsigned LsuOpIdOffset = AluOpIdOffset +
                                              NofAlus * AluNofOperands;
  localparam integer unsigned AluLsuOpIdOffset = LsuOpIdOffset +
                                              NofLsus * LsuNofOperands;
  localparam integer unsigned FpuOpIdOffset = AluLsuOpIdOffset +
                                              NofAluLsus * AluLsuNofOperands;

  ////////////////////////////////////////
  // Operand distribution network (ODN) //
  ////////////////////////////////////////

  operand_req_t [iomsb(NofAlus):0][AluNofOperands-1:0]  alu_op_reqs;
  logic         [iomsb(NofAlus):0][AluNofOperands-1:0]  alu_op_reqs_valid;
  logic         [iomsb(NofAlus):0][AluNofOperands-1:0]  alu_op_reqs_ready;
  available_result_t [iomsb(NofAlus):0][iomsb(AluNofRss):0] alu_available_results;
  ext_res_req_t   [iomsb(NofAlus):0][AluNofResRspPorts-1:0] alu_res_reqs;
  logic         [iomsb(NofAlus):0][AluNofResRspPorts-1:0]   alu_res_reqs_valid;
  logic         [iomsb(NofAlus):0][AluNofResRspPorts-1:0]   alu_res_reqs_ready;
  res_rsp_t     [iomsb(NofAlus):0][AluNofResRspPorts-1:0]   alu_res_rsps;
  logic         [iomsb(NofAlus):0][AluNofResRspPorts-1:0]   alu_res_rsps_valid;
  logic         [iomsb(NofAlus):0][AluNofResRspPorts-1:0]   alu_res_rsps_ready;
  operand_t     [iomsb(NofAlus):0][AluNofOperands-1:0]  alu_op_rsps;
  logic         [iomsb(NofAlus):0][AluNofOperands-1:0]  alu_op_rsps_valid;
  logic         [iomsb(NofAlus):0][AluNofOperands-1:0]  alu_op_rsps_ready;

  operand_req_t [iomsb(NofLsus):0][LsuNofOperands-1:0]  lsu_op_reqs;
  logic         [iomsb(NofLsus):0][LsuNofOperands-1:0]  lsu_op_reqs_valid;
  logic         [iomsb(NofLsus):0][LsuNofOperands-1:0]  lsu_op_reqs_ready;
  available_result_t [iomsb(NofLsus):0][iomsb(LsuNofRss):0]       lsu_available_results;
  ext_res_req_t   [iomsb(NofLsus):0][iomsb(LsuNofResRspPorts):0]  lsu_res_reqs;
  logic         [iomsb(NofLsus):0][iomsb(LsuNofResRspPorts):0]    lsu_res_reqs_valid;
  logic         [iomsb(NofLsus):0][iomsb(LsuNofResRspPorts):0]    lsu_res_reqs_ready;
  res_rsp_t     [iomsb(NofLsus):0][iomsb(LsuNofResRspPorts):0]    lsu_res_rsps;
  logic         [iomsb(NofLsus):0][iomsb(LsuNofResRspPorts):0]    lsu_res_rsps_valid;
  logic         [iomsb(NofLsus):0][iomsb(LsuNofResRspPorts):0]    lsu_res_rsps_ready;
  operand_t     [iomsb(NofLsus):0][LsuNofOperands-1:0]  lsu_op_rsps;
  logic         [iomsb(NofLsus):0][LsuNofOperands-1:0]  lsu_op_rsps_valid;
  logic         [iomsb(NofLsus):0][LsuNofOperands-1:0]  lsu_op_rsps_ready;

  operand_req_t [iomsb(NofAluLsus):0][AluLsuNofOperands-1:0]  alu_lsu_op_reqs;
  logic         [iomsb(NofAluLsus):0][AluLsuNofOperands-1:0]  alu_lsu_op_reqs_valid;
  logic         [iomsb(NofAluLsus):0][AluLsuNofOperands-1:0]  alu_lsu_op_reqs_ready;
  available_result_t [iomsb(NofAluLsus):0][iomsb(AluLsuNofRsrs):0]      alu_lsu_available_results;
  ext_res_req_t   [iomsb(NofAluLsus):0][iomsb(AluLsuNofResRspPorts):0]  alu_lsu_res_reqs;
  logic         [iomsb(NofAluLsus):0][iomsb(AluLsuNofResRspPorts):0]    alu_lsu_res_reqs_valid;
  logic         [iomsb(NofAluLsus):0][iomsb(AluLsuNofResRspPorts):0]    alu_lsu_res_reqs_ready;
  res_rsp_t     [iomsb(NofAluLsus):0][iomsb(AluLsuNofResRspPorts):0]    alu_lsu_res_rsps;
  logic         [iomsb(NofAluLsus):0][iomsb(AluLsuNofResRspPorts):0]    alu_lsu_res_rsps_valid;
  logic         [iomsb(NofAluLsus):0][iomsb(AluLsuNofResRspPorts):0]    alu_lsu_res_rsps_ready;
  operand_t     [iomsb(NofAluLsus):0][AluLsuNofOperands-1:0]  alu_lsu_op_rsps;
  logic         [iomsb(NofAluLsus):0][AluLsuNofOperands-1:0]  alu_lsu_op_rsps_valid;
  logic         [iomsb(NofAluLsus):0][AluLsuNofOperands-1:0]  alu_lsu_op_rsps_ready;

  operand_req_t [iomsb(NofFpus):0][FpuNofOperands-1:0]  fpu_op_reqs;
  logic         [iomsb(NofFpus):0][FpuNofOperands-1:0]  fpu_op_reqs_valid;
  logic         [iomsb(NofFpus):0][FpuNofOperands-1:0]  fpu_op_reqs_ready;
  available_result_t [iomsb(NofFpus):0][iomsb(FpuNofRss):0] fpu_available_results;
  ext_res_req_t   [iomsb(NofFpus):0][FpuNofResRspPorts-1:0] fpu_res_reqs;
  logic         [iomsb(NofFpus):0][FpuNofResRspPorts-1:0]   fpu_res_reqs_valid;
  logic         [iomsb(NofFpus):0][FpuNofResRspPorts-1:0]   fpu_res_reqs_ready;
  res_rsp_t     [iomsb(NofFpus):0][FpuNofResRspPorts-1:0]   fpu_res_rsps;
  logic         [iomsb(NofFpus):0][FpuNofResRspPorts-1:0]   fpu_res_rsps_valid;
  logic         [iomsb(NofFpus):0][FpuNofResRspPorts-1:0]   fpu_res_rsps_ready;
  operand_t     [iomsb(NofFpus):0][FpuNofOperands-1:0]  fpu_op_rsps;
  logic         [iomsb(NofFpus):0][FpuNofOperands-1:0]  fpu_op_rsps_valid;
  logic         [iomsb(NofFpus):0][FpuNofOperands-1:0]  fpu_op_rsps_ready;

  operand_req_t [NofOperandIfs-1:0] op_reqs;
  logic         [NofOperandIfs-1:0] op_reqs_valid;
  logic         [NofOperandIfs-1:0] op_reqs_ready;

  ext_res_req_t [TotalNofResRspPorts-1:0] res_reqs;
  logic         [TotalNofResRspPorts-1:0] res_reqs_valid;
  logic         [TotalNofResRspPorts-1:0] res_reqs_ready;
  available_result_t [TotalNofRsrs-1:0] available_results;

  res_rsp_t     [TotalNofResRspPorts-1:0] res_rsps;
  logic         [TotalNofResRspPorts-1:0] res_rsps_valid;
  logic         [TotalNofResRspPorts-1:0] res_rsps_ready;

  operand_t     [NofOperandIfs-1:0] op_rsps;
  logic         [NofOperandIfs-1:0] op_rsps_valid;
  logic         [NofOperandIfs-1:0] op_rsps_ready;

  if (Xfrep) begin : gen_odn

    // ---------------------------
    // Pack operand interfaces
    // ---------------------------

    // Pack the FUs' operand requests and responses into a linear array to connect to the XBAR.
    // The array index must match the operand / consumer id.
    // TODO(colluca): think if this code can be streamlined
    always_comb begin : fu_op_reqs_rsps
      automatic integer ope_if = 0;

      op_reqs           = '0;
      op_reqs_valid     = '0;
      alu_op_reqs_ready = '0;
      lsu_op_reqs_ready = '0;
      alu_lsu_op_reqs_ready = '0;
      fpu_op_reqs_ready = '0;

      op_rsps_ready     = '0;
      alu_op_rsps       = '0;
      alu_op_rsps_valid = '0;
      lsu_op_rsps       = '0;
      lsu_op_rsps_valid = '0;
      alu_lsu_op_rsps       = '0;
      alu_lsu_op_rsps_valid = '0;
      fpu_op_rsps       = '0;
      fpu_op_rsps_valid = '0;

      for (int alu = 0; alu < NofAlus; alu++) begin
        for (int op = 0; op < AluNofOperands; op++) begin
          // operand requests
          op_reqs[ope_if]            = alu_op_reqs[alu][op];
          op_reqs_valid[ope_if]      = alu_op_reqs_valid[alu][op];
          alu_op_reqs_ready[alu][op] = op_reqs_ready[ope_if];
          // operand responses
          alu_op_rsps[alu][op]       = op_rsps[ope_if];
          alu_op_rsps_valid[alu][op] = op_rsps_valid[ope_if];
          op_rsps_ready[ope_if]      = alu_op_rsps_ready[alu][op];
          ope_if = ope_if + 1;
        end
      end
      for (int lsu = 0; lsu < NofLsus; lsu++) begin
        for (int op = 0; op < LsuNofOperands; op++) begin
          // operand requests
          op_reqs[ope_if]            = lsu_op_reqs[lsu][op];
          op_reqs_valid[ope_if]      = lsu_op_reqs_valid[lsu][op];
          lsu_op_reqs_ready[lsu][op] = op_reqs_ready[ope_if];
          // operand responses
          lsu_op_rsps[lsu][op]       = op_rsps[ope_if];
          lsu_op_rsps_valid[lsu][op] = op_rsps_valid[ope_if];
          op_rsps_ready[ope_if]      = lsu_op_rsps_ready[lsu][op];
          ope_if = ope_if + 1;
        end
      end
      for (int alu_lsu = 0; alu_lsu < NofAluLsus; alu_lsu++) begin
        for (int op = 0; op < AluLsuNofOperands; op++) begin
          // operand requests
          op_reqs[ope_if]            = alu_lsu_op_reqs[alu_lsu][op];
          op_reqs_valid[ope_if]      = alu_lsu_op_reqs_valid[alu_lsu][op];
          alu_lsu_op_reqs_ready[alu_lsu][op] = op_reqs_ready[ope_if];
          // operand responses
          alu_lsu_op_rsps[alu_lsu][op]       = op_rsps[ope_if];
          alu_lsu_op_rsps_valid[alu_lsu][op] = op_rsps_valid[ope_if];
          op_rsps_ready[ope_if]      = alu_lsu_op_rsps_ready[alu_lsu][op];
          ope_if = ope_if + 1;
        end
      end
      for (int fpu = 0; fpu < NofFpus; fpu++) begin
        for (int op = 0; op < FpuNofOperands; op++) begin
          // operand requests
          op_reqs[ope_if]            = fpu_op_reqs[fpu][op];
          op_reqs_valid[ope_if]      = fpu_op_reqs_valid[fpu][op];
          fpu_op_reqs_ready[fpu][op] = op_reqs_ready[ope_if];
          // operand responses
          fpu_op_rsps[fpu][op]       = op_rsps[ope_if];
          fpu_op_rsps_valid[fpu][op] = op_rsps_valid[ope_if];
          op_rsps_ready[ope_if]      = fpu_op_rsps_ready[fpu][op];
          ope_if = ope_if + 1;
        end
      end
    end

    // Unpack the linear array of result requests onto the FUs' result request interfaces.
    // Pack the FUs' result responses (one per slot) into a linear array to connect to the XBAR.
    // The array index must match the result / producer id.
    // TODO(colluca): think if this code can be streamlined
    always_comb begin : fu_res_reqs_rsps
      automatic integer req_if = 0;
      automatic integer rsrs = 0;
      automatic integer rsp_if = 0;

      res_reqs_ready     = '0;
      alu_res_reqs       = '0;
      alu_res_reqs_valid = '0;
      lsu_res_reqs       = '0;
      alu_lsu_res_reqs       = '0;
      alu_lsu_res_reqs_valid = '0;
      fpu_res_reqs       = '0;

      available_results = '0;

      res_rsps           = '0;
      res_rsps_valid     = '0;
      alu_res_rsps_ready = '0;
      lsu_res_rsps_ready = '0;
      alu_lsu_res_rsps_ready = '0;
      fpu_res_rsps_ready = '0;

      for (int alu = 0; alu < NofAlus; alu++) begin
        for (int alu_rsrs = 0; alu_rsrs < AluNofRss; alu_rsrs++) begin
          available_results[rsrs] = alu_available_results[alu][alu_rsrs];
          rsrs = rsrs + 1;
        end
        for (int alu_req_if = 0; alu_req_if < AluNofResRspPorts; alu_req_if++) begin
          // requests
          alu_res_reqs[alu][alu_req_if]       = res_reqs[req_if];
          alu_res_reqs_valid[alu][alu_req_if] = res_reqs_valid[req_if];
          res_reqs_ready[req_if]              = alu_res_reqs_ready[alu][alu_req_if];
          req_if = req_if + 1;
        end
        for (int rsp = 0; rsp < AluNofResRspPorts; rsp++) begin
          // responses
          res_rsps[rsp_if]             = alu_res_rsps[alu][rsp];
          res_rsps_valid[rsp_if]       = alu_res_rsps_valid[alu][rsp];
          alu_res_rsps_ready[alu][rsp] = res_rsps_ready[rsp_if];
          rsp_if = rsp_if + 1;
        end
      end
      for (int lsu = 0; lsu < NofLsus; lsu++) begin
        for (int lsu_rsrs = 0; lsu_rsrs < LsuNofRss; lsu_rsrs++) begin
          available_results[rsrs] = lsu_available_results[lsu][lsu_rsrs];
          rsrs = rsrs + 1;
        end
        for (int lsu_req_if = 0; lsu_req_if < LsuNofResRspPorts; lsu_req_if++) begin
          // requests
          lsu_res_reqs[lsu][lsu_req_if]       = res_reqs[req_if];
          lsu_res_reqs_valid[lsu][lsu_req_if] = res_reqs_valid[req_if];
          res_reqs_ready[req_if]              = lsu_res_reqs_ready[lsu][lsu_req_if];
          req_if = req_if + 1;
        end
        for (int rsp = 0; rsp < LsuNofResRspPorts; rsp++) begin
          // responses
          res_rsps[rsp_if]             = lsu_res_rsps[lsu][rsp];
          res_rsps_valid[rsp_if]       = lsu_res_rsps_valid[lsu][rsp];
          lsu_res_rsps_ready[lsu][rsp] = res_rsps_ready[rsp_if];
          rsp_if = rsp_if + 1;
        end
      end
      for (int alu_lsu = 0; alu_lsu < NofAluLsus; alu_lsu++) begin
        for (int alu_lsu_rsrs = 0; alu_lsu_rsrs < AluLsuNofRsrs; alu_lsu_rsrs++) begin
          available_results[rsrs] = alu_lsu_available_results[alu_lsu][alu_lsu_rsrs];
          rsrs = rsrs + 1;
        end
        for (int alu_lsu_req_if = 0; alu_lsu_req_if < AluLsuNofResRspPorts; alu_lsu_req_if++) begin
          // requests
          alu_lsu_res_reqs[alu_lsu][alu_lsu_req_if]       = res_reqs[req_if];
          alu_lsu_res_reqs_valid[alu_lsu][alu_lsu_req_if] = res_reqs_valid[req_if];
          res_reqs_ready[req_if]              = alu_lsu_res_reqs_ready[alu_lsu][alu_lsu_req_if];
          req_if = req_if + 1;
        end
        for (int rsp = 0; rsp < AluLsuNofResRspPorts; rsp++) begin
          // responses
          res_rsps[rsp_if]             = alu_lsu_res_rsps[alu_lsu][rsp];
          res_rsps_valid[rsp_if]       = alu_lsu_res_rsps_valid[alu_lsu][rsp];
          alu_lsu_res_rsps_ready[alu_lsu][rsp] = res_rsps_ready[rsp_if];
          rsp_if = rsp_if + 1;
        end
      end
      for (int fpu = 0; fpu < NofFpus; fpu++) begin
        for (int fpu_rsrs = 0; fpu_rsrs < FpuNofRss; fpu_rsrs++) begin
          available_results[rsrs] = fpu_available_results[fpu][fpu_rsrs];
          rsrs = rsrs + 1;
        end
        for (int fpu_req_if = 0; fpu_req_if < FpuNofResRspPorts; fpu_req_if++) begin
          // requests
          fpu_res_reqs[fpu][fpu_req_if]       = res_reqs[req_if];
          fpu_res_reqs_valid[fpu][fpu_req_if] = res_reqs_valid[req_if];
          res_reqs_ready[req_if]              = fpu_res_reqs_ready[fpu][fpu_req_if];
          req_if = req_if + 1;
        end
        for (int rsp = 0; rsp < FpuNofResRspPorts; rsp++) begin
          // responses
          res_rsps[rsp_if]             = fpu_res_rsps[fpu][rsp];
          res_rsps_valid[rsp_if]       = fpu_res_rsps_valid[fpu][rsp];
          fpu_res_rsps_ready[fpu][rsp] = res_rsps_ready[rsp_if];
          rsp_if = rsp_if + 1;
        end
      end
    end

    // ---------------------------
    // Operand request XBAR
    // ---------------------------

    schnizo_req_xbar #(
      .NofOperandReqs(NofOperandIfs),
      .NofRs         (NofRs),
      .NofRsrs       (NofRsrs),
      .NofResRspIfs  (NofRspPorts),
      .TotalNofRsrs   (TotalNofRsrs),
      .TotalNofResRspIfs(TotalNofResRspPorts),
      .operand_req_t (operand_req_t),
      .res_req_t     (res_req_t),
      .ext_res_req_t (ext_res_req_t),
      .available_result_t (available_result_t),
      .slot_id_t     (result_slot_id_t),
      .dest_mask_t   (dest_mask_t)
    ) i_req_xbar (
      .op_reqs_i          (op_reqs),
      .op_reqs_valid_i    (op_reqs_valid),
      .op_reqs_ready_o    (op_reqs_ready),
      .available_results_i(available_results),
      .res_reqs_o         (res_reqs),
      .res_reqs_valid_o   (res_reqs_valid),
      .res_reqs_ready_i   (res_reqs_ready)
    );

    // ---------------------------
    // Operand distribution network - response xbar
    // ---------------------------
    operand_t   [TotalNofResRspPorts-1:0] res_rsps_operands;
    dest_mask_t [TotalNofResRspPorts-1:0] res_rsps_dest_masks;

    for (genvar i = 0; i < TotalNofResRspPorts; i++) begin : gen_flatten_res_rsps
      assign res_rsps_operands[i]  = res_rsps[i].operand;
      assign res_rsps_dest_masks[i] = res_rsps[i].dest_mask;
    end

    schnizo_rsp_xbar #(
      .NumInp    (TotalNofResRspPorts),
      .NumOut    (NofOperandIfs),
      .payload_t (operand_t)
    ) i_rsp_xbar (
      .clk_i,
      .rst_ni (!rst_i),
      .data_i (res_rsps_operands),
      .sel_i  (res_rsps_dest_masks),
      .valid_i(res_rsps_valid),
      .ready_o(res_rsps_ready),
      .data_o (op_rsps),
      .valid_o(op_rsps_valid),
      .ready_i(op_rsps_ready)
    );

  end else begin : gen_no_odn
    // Tie down all signals of the operand distribution network which are set either by a crossbar
    // or when distributing to the reservation stations.
    assign op_reqs           = '0;
    assign op_reqs_valid     = '0;
    assign alu_op_reqs_ready = '0;
    assign lsu_op_reqs_ready = '0;
    assign alu_lsu_op_reqs_ready = '0;
    assign fpu_op_reqs_ready = '0;

    assign op_rsps_ready     = '0;
    assign alu_op_rsps       = '0;
    assign alu_op_rsps_valid = '0;
    assign lsu_op_rsps       = '0;
    assign lsu_op_rsps_valid = '0;
    assign alu_lsu_op_rsps       = '0;
    assign alu_lsu_op_rsps_valid = '0;
    assign fpu_op_rsps       = '0;
    assign fpu_op_rsps_valid = '0;

    assign res_reqs_ready     = '0;
    assign alu_res_reqs       = '0;
    assign alu_res_reqs_valid = '0;
    assign lsu_res_reqs       = '0;
    assign alu_lsu_res_reqs       = '0;
    assign alu_lsu_res_reqs_valid = '0;
    assign fpu_res_reqs       = '0;

    assign res_rsps           = '0;
    assign res_rsps_valid     = '0;
    assign alu_res_rsps_ready = '0;
    assign lsu_res_rsps_ready = '0;
    assign alu_lsu_res_rsps_ready = '0;
    assign fpu_res_rsps_ready = '0;

    assign op_reqs_ready  = '0;
    assign res_reqs       = '0;
    assign res_reqs_valid = '0;

    assign res_rsps_ready = '0;
    assign op_rsps        = '0;
    assign op_rsps_valid  = '0;
  end

  // ---------------------------
  // LxP data path selection
  // ---------------------------
  // We generate one global signal which then controls all request/issue/result/wb MUXs.
  // This should enable the timing separation for the branch result.
  logic in_lxp;
  assign in_lxp = Xfrep ? loop_state_i inside {LoopLcp1, LoopLcp2, LoopLep} : 1'b0;

  logic in_lcp;
  assign in_lcp = Xfrep ? loop_state_i inside {LoopLcp1, LoopLcp2} : 1'b0;

  //////////
  // ALUs //
  //////////

  typedef logic [cf_math_pkg::idx_width(AluNofRss)-1:0] alu_rs_tag_t;
  typedef logic [cf_math_pkg::max($bits(alu_rs_tag_t),$bits(instr_tag_t))-1:0] alu_instr_tag_t;

  typedef struct packed {
    fu_data_t       fu_data;
    alu_instr_tag_t tag;
  } alu_issue_req_t;

  typedef struct packed {
    alu_result_t result;
    instr_tag_t  tag;
  } alu_result_and_tag_t;

  alu_result_and_tag_t [iomsb(NofAlus):0] alu_wbs_result_and_tag;
  logic                [iomsb(NofAlus):0] alu_wbs_result_valid;
  logic                [iomsb(NofAlus):0] alu_wbs_result_ready;

  logic [iomsb(NofAlus):0] alu_loop_finish;

  for (genvar alu = 0; alu < NofAlus; alu++) begin : gen_alus
    // Helper signals to merge the result and tag
    alu_res_val_t   alu_wb_result_value;
    alu_instr_tag_t alu_wb_result_tag;

    // Signals connecting the FU block and the actual FU
    alu_issue_req_t alu_issue_req;
    logic           alu_issue_req_valid;
    logic           alu_issue_req_ready;
    logic           alu_exec_commit;
    alu_result_t    alu_result;
    alu_res_val_t   alu_result_value;
    alu_instr_tag_t alu_result_tag;
    logic           alu_result_valid_raw;
    logic           alu_result_valid;
    logic           alu_result_ready;
    logic           alu_busy;

    producer_id_t producer_start_id;
    assign producer_start_id = producer_id_t'{
      slot_id: '0, // does not matter
      rs_id:   rs_id_t'(AluRsIdOffset + alu)
    };

    // pragma translate_off
    issue_alu_trace_t alu_trace_int;
    // pragma translate_on

    schnizo_fu_block #(
      .Xfrep         (Xfrep),
      .disp_req_t    (disp_req_t),
      .disp_rsp_t    (disp_rsp_t),
      .issue_req_t   (alu_issue_req_t),
      .result_t      (alu_res_val_t),
      .instr_tag_t   (alu_instr_tag_t),
      .NofRsis       (AluNofRss),
      .NofRsrs       (AluNofRss),
      .NofConstants  (AluNofConstants),
      .NofOperands   (AluNofOperands),
      .NofResRspIfs  (AluNofResRspPorts),
      .ConsumerCount (ConsumerCount),
      .RegAddrWidth  (RegAddrWidth),
      .MaxIterationsW(MaxIterationsW),
      .producer_id_t (producer_id_t),
      .slot_id_t     (result_slot_id_t),
      .operand_req_t (operand_req_t),
      .operand_t     (operand_t),
      .res_req_t     (res_req_t),
      .ext_res_req_t (ext_res_req_t),
      .available_result_t (available_result_t),
      .dest_mask_t   (dest_mask_t),
      .res_rsp_t     (res_rsp_t)
    ) i_fu_block (
      .clk_i,
      .rst_i,
      /// RS control signals
      .producer_id_i      (producer_start_id),
      .restart_i          (restart_i),
      .loop_state_i       (loop_state_i),
      .in_lxp_i           (in_lxp),
      .lep_iterations_i   (lep_iterations_i),
      .goto_lcp2_i        (goto_lcp2_i),
      .fu_busy_i          (alu_busy),
      .loop_finish_o      (alu_loop_finish[alu]),
      .rs_full_o          (alu_rs_full_o[alu]),
      /// Instruction stream
      // From dispatcher
      .disp_req_i         (disp_req_i),
      .disp_req_valid_i   (alu_disp_reqs_valid_i[alu]),
      .disp_req_ready_o   (alu_disp_reqs_ready_o[alu]),
      .instr_exec_commit_i(instr_exec_commit_i),
      .disp_rsp_o         (alu_disp_rsp_o[alu]),
      // To FU
      .issue_req_o        (alu_issue_req),
      .issue_req_valid_o  (alu_issue_req_valid),
      .issue_req_ready_i  (alu_issue_req_ready),
      .instr_exec_commit_o(alu_exec_commit),
      // From FU
      .result_i           (alu_result.result),
      .result_tag_i       (alu_result_tag),
      .result_valid_i     (alu_result_valid),
      .result_ready_o     (alu_result_ready),
      // To writeback
      .wb_result_o        (alu_wb_result_value),
      .wb_result_tag_o    (alu_wb_result_tag),
      .wb_result_valid_o  (alu_wbs_result_valid[alu]),
      .wb_result_ready_i  (alu_wbs_result_ready[alu]),
      /// Operand distribution network
      .available_results_o(alu_available_results[alu]),
      .op_reqs_o          (alu_op_reqs[alu]),
      .op_reqs_valid_o    (alu_op_reqs_valid[alu]),
      .op_reqs_ready_i    (alu_op_reqs_ready[alu]),
      .res_reqs_i         (alu_res_reqs[alu]),
      .res_reqs_valid_i   (alu_res_reqs_valid[alu]),
      .res_reqs_ready_o   (alu_res_reqs_ready[alu]),
      .res_rsps_o         (alu_res_rsps[alu]),
      .res_rsps_valid_o   (alu_res_rsps_valid[alu]),
      .res_rsps_ready_i   (alu_res_rsps_ready[alu]),
      .op_rsps_i          (alu_op_rsps[alu]),
      .op_rsps_valid_i    (alu_op_rsps_valid[alu]),
      .op_rsps_ready_o    (alu_op_rsps_ready[alu])
    );
    // DANGER!
    // HACK: We do not pass the branch result into the RS so keep the same RS implementation for
    // all FUs. For any write back we directly take the branch result from the FU. This is
    // possible because if we want to do a writeback the RS accepts the result only if the
    // writeback also accepts the writeback. Thus we can bypass the RS.
    // TODO: find a clean solution how to handle the branch result.
    assign alu_wbs_result_and_tag[alu].result = '{
      result:      alu_wb_result_value,
      compare_res: alu_result.compare_res
    };
    assign alu_wbs_result_and_tag[alu].tag = alu_wb_result_tag;

    schnizo_alu #(
      .XLEN         (XLEN),
      .HasBranch    (alu == '0), // only the first ALU has the branch logic
      .HasMultiplier((alu == '0) && MulInAlu0), // only the first ALU has the multiplier
      .issue_req_t  (alu_issue_req_t),
      .instr_tag_t  (alu_instr_tag_t)
    ) i_alu (
      .clk_i,
      .rst_i,
      // pragma translate_off
      .trace_o          (alu_trace_int),
      // pragma translate_on
      .issue_req_i      (alu_issue_req),
      .issue_req_valid_i(alu_issue_req_valid),
      .issue_req_ready_o(alu_issue_req_ready),
      .result_o         (alu_result.result),
      .compare_res_o    (alu_result.compare_res),
      .tag_o            (alu_result_tag),
      .result_valid_o   (alu_result_valid_raw),
      .result_ready_i   (alu_result_ready),
      .busy_o           (alu_busy)
    );

    // Populate the producer field of the trace
    // pragma translate_off
    string producer;
    always_comb producer = $sformatf("ALU%0d", alu);
    always_comb begin
      alu_trace_o[alu] = alu_trace_int;
      alu_trace_o[alu].producer = producer;
    end
    assign alu_retire_trace_o[alu] = '{
      valid:    alu_result_valid && alu_result_ready,
      rd:       alu_wb_result_tag_o.dest_reg,
      rd_is_fp: alu_wb_result_tag_o.dest_reg_is_fp,
      producer: producer
    };
    // pragma translate_on

    // Guard the result with the commit signal
    // If we want to dispatch an ALU instruction, in particular a branching instruction, we may only
    // commit the instruction if there is no instruction address misaligned exception.
    // Therefore, we must "kill" the writeback if we don't commit. The kill must be after the result
    // as otherwise we create a loop. For the other FUs the "kill" is before we pass the instruction
    // downstream.
    // TODO(colluca): this can no longer be applied after addition of the multiplier which, taking
    // multiple cycles, does not receive alu_exec_commit in the cycle of its writeback. As a result,
    // the writeback never occurs.
    // In any case, this does not sound needed to me. Branch instructions never writeback to the RF.
    // The only side effect they have is on the PC, but this does not seem to depend on
    // alu_result_valid at all.
    // assign alu_result_valid = alu_result_valid_raw & alu_exec_commit;
    assign alu_result_valid = alu_result_valid_raw;
  end

  // ALU branch result forwarding
  // We bypass the arbiter for branch results as only ALU 0 has branch logic.
  // We need the branch result at least in LCP1 to support jump & branch instructions where we
  // fallback into the HW loop mode. If we decide to crash if an unsupported instruction is
  // encountered, it is possible to optimize the timing by only forwarding the ALU result in
  // regular mode. This will gain around 10ps for a 1ns target clock cycle.
  // NOTE(lnoussi): Moved to ALU_LSU
  // assign branch_result_o = alu_wbs_result_and_tag[0].result;

  // ALU writeback arbiter
  // The stream_arbiter has a feed through for 1 input so no special handling for disabled FREP
  // is required.
  alu_result_and_tag_t alu_wb_result_and_tag_out;

  if (NofAlus > 0) begin: gen_alu_wb_arbiter
    stream_arbiter #(
      .DATA_T (alu_result_and_tag_t),
      .N_INP  (NofAlus),
      .ARBITER("prio")
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
  end else begin: gen_no_alu
    assign alu_rs_full_o = '0;
    assign alu_disp_reqs_ready_o = '0;
    assign alu_disp_rsp_o = '0;
    assign alu_wbs_result_and_tag = '0;
    assign alu_wbs_result_valid = '0;
    assign alu_wbs_result_ready = '0;
    assign alu_available_results = '0;
    assign alu_op_reqs = '0;
    assign alu_op_reqs_valid = '0;
    assign alu_res_reqs_ready = '0;
    assign alu_res_rsps = '0;
    assign alu_res_rsps_valid = '0;
    assign alu_op_rsps_ready = '0;
    // pragma translate_off
    assign alu_retire_trace_o = '{default: '0};
    // pragma translate_on
    assign alu_wb_result_and_tag_out = '0;
    assign alu_wb_result_valid_o = '0;
    assign alu_loop_finish = 1'b1;
  end

  assign alu_wb_result_o     = alu_wb_result_and_tag_out.result;
  assign alu_wb_result_tag_o = alu_wb_result_and_tag_out.tag;

  //////////
  // LSUs //
  //////////
  typedef logic [cf_math_pkg::idx_width(LsuNofRss)-1:0] lsu_rs_tag_t;
  typedef logic [cf_math_pkg::max($bits(lsu_rs_tag_t),$bits(instr_tag_t))-1:0] lsu_instr_tag_t;

  typedef struct packed {
    fu_data_t       fu_data;
    lsu_instr_tag_t tag;
  } lsu_issue_req_t;

  // The LSU always returns a data_t value. Define a type for clarity.
  typedef data_t lsu_result_t;
  typedef struct packed {
    lsu_result_t result;
    instr_tag_t  tag;
  } lsu_result_and_tag_t;

  logic                [iomsb(NofLsus):0] lsu_empty;
  logic                [iomsb(NofLsus):0] lsu_addr_misaligned;
  lsu_result_and_tag_t [iomsb(NofLsus):0] lsu_wbs_result_and_tag;
  logic                [iomsb(NofLsus):0] lsu_wbs_result_valid;
  logic                [iomsb(NofLsus):0] lsu_wbs_result_ready;

  logic [iomsb(NofLsus):0] lsu_loop_finish;

  for (genvar lsu = 0; lsu < NofLsus; lsu++) begin : gen_lsus
    // Helper signals to merge the result and tag
    lsu_result_t lsu_wb_result;
    instr_tag_t  lsu_wb_result_tag;

    // Signals connecting the FU block and the actual FU
    lsu_issue_req_t  lsu_issue_req;
    logic        lsu_issue_req_valid;
    logic        lsu_issue_req_ready;
    logic        lsu_exec_commit;
    logic        lsu_addr_misaligned_raw;
    lsu_result_t lsu_result;
    instr_tag_t  lsu_result_tag;
    logic        lsu_result_valid;
    logic        lsu_result_ready;
    logic        lsu_busy;

    producer_id_t producer_start_id;
    assign producer_start_id = producer_id_t'{
      slot_id: '0, // does not matter
      rs_id:   rs_id_t'(LsuRsIdOffset + lsu)
    };

    // pragma translate_off
    issue_lsu_trace_t lsu_trace_int;
    // pragma translate_on

    schnizo_fu_block #(
      .Xfrep         (Xfrep),
      .disp_req_t    (disp_req_t),
      .disp_rsp_t    (disp_rsp_t),
      .issue_req_t   (lsu_issue_req_t),
      .result_t      (lsu_result_t),
      .instr_tag_t   (instr_tag_t),
      .NofRsis       (LsuNofRss),
      .NofRsrs       (LsuNofRss),
      .NofConstants  (LsuNofConstants),
      .NofOperands   (LsuNofOperands),
      .NofResRspIfs  (LsuNofResRspPorts),
      .ConsumerCount (ConsumerCount),
      .RegAddrWidth  (RegAddrWidth),
      .MaxIterationsW(MaxIterationsW),
      .producer_id_t (producer_id_t),
      .slot_id_t     (result_slot_id_t),
      .operand_req_t (operand_req_t),
      .operand_t     (operand_t),
      .res_req_t     (res_req_t),
      .ext_res_req_t (ext_res_req_t),
      .available_result_t (available_result_t),
      .dest_mask_t   (dest_mask_t),
      .res_rsp_t     (res_rsp_t)
    ) i_fu_block (
      .clk_i,
      .rst_i,
      /// RS control signals
      .producer_id_i      (producer_start_id),
      .restart_i          (restart_i),
      .loop_state_i       (loop_state_i),
      .in_lxp_i           (in_lxp),
      .lep_iterations_i   (lep_iterations_i),
      .goto_lcp2_i        (goto_lcp2_i),
      .fu_busy_i          (lsu_busy),
      .loop_finish_o      (lsu_loop_finish[lsu]),
      .rs_full_o          (lsu_rs_full_o[lsu]),
      /// Instruction stream
      // From dispatcher
      .disp_req_i         (disp_req_i),
      .disp_req_valid_i   (lsu_disp_reqs_valid_i[lsu]),
      .disp_req_ready_o   (lsu_disp_reqs_ready_o[lsu]),
      .instr_exec_commit_i(instr_exec_commit_i),
      .disp_rsp_o         (lsu_disp_rsp_o[lsu]),
      // To FU
      .issue_req_o        (lsu_issue_req),
      .issue_req_valid_o  (lsu_issue_req_valid),
      .issue_req_ready_i  (lsu_issue_req_ready),
      .instr_exec_commit_o(lsu_exec_commit),
      // From FU
      .result_i           (lsu_result),
      .result_tag_i       (lsu_result_tag),
      .result_valid_i     (lsu_result_valid),
      .result_ready_o     (lsu_result_ready),
      // To writeback
      .wb_result_o        (lsu_wb_result),
      .wb_result_tag_o    (lsu_wb_result_tag),
      .wb_result_valid_o  (lsu_wbs_result_valid[lsu]),
      .wb_result_ready_i  (lsu_wbs_result_ready[lsu]),
      /// Operand distribution network
      .available_results_o(lsu_available_results[lsu]),
      .op_reqs_o          (lsu_op_reqs[lsu]),
      .op_reqs_valid_o    (lsu_op_reqs_valid[lsu]),
      .op_reqs_ready_i    (lsu_op_reqs_ready[lsu]),
      .res_reqs_i         (lsu_res_reqs[lsu]),
      .res_reqs_valid_i   (lsu_res_reqs_valid[lsu]),
      .res_reqs_ready_o   (lsu_res_reqs_ready[lsu]),
      .res_rsps_o         (lsu_res_rsps[lsu]),
      .res_rsps_valid_o   (lsu_res_rsps_valid[lsu]),
      .res_rsps_ready_i   (lsu_res_rsps_ready[lsu]),
      .op_rsps_i          (lsu_op_rsps[lsu]),
      .op_rsps_valid_i    (lsu_op_rsps_valid[lsu]),
      .op_rsps_ready_o    (lsu_op_rsps_ready[lsu])
    );
    assign lsu_wbs_result_and_tag[lsu].result = lsu_wb_result;
    assign lsu_wbs_result_and_tag[lsu].tag    = lsu_wb_result_tag;

    schnizo_lsu #(
      .XLEN               (XLEN),
      .issue_req_t        (lsu_issue_req_t),
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
      // pragma translate_off
      .trace_o          (lsu_trace_int),
      // pragma translate_on
      .issue_req_i      (lsu_issue_req),
      .issue_req_valid_i(lsu_issue_req_valid),
      .issue_commit_i   (lsu_exec_commit),
      .issue_req_ready_o(lsu_issue_req_ready),
      .result_o         (lsu_result),
      .tag_o            (lsu_result_tag),
      .result_error_o   (), // ignored
      .result_valid_o   (lsu_result_valid),
      .result_ready_i   (lsu_result_ready),
      .busy_o           (lsu_busy),
      .empty_o          (lsu_empty[lsu]),
      .addr_misaligned_o(lsu_addr_misaligned_raw),
      .data_req_o       (lsu_dreq_o[lsu]),
      .data_rsp_i       (lsu_drsp_i[lsu]),
      .caq_addr_i       (caq_addr_i[lsu]),
      .caq_track_write_i(caq_track_write_i[lsu]),
      .caq_req_valid_i  (caq_req_valid_i[lsu]),
      .caq_req_ready_o  (caq_req_ready_o[lsu]),
      .caq_rsp_valid_i  (caq_rsp_valid_i[lsu]),
      .caq_rsp_valid_o  (caq_rsp_valid_o[lsu])
    );

    // Suppress exceptions in LCP and LEP because we anyway don't handle them one cycle later.
    assign lsu_addr_misaligned[lsu] = lsu_addr_misaligned_raw & !in_lxp;

    // Populate the producer and instr_iter fields of the trace
    // pragma translate_off
    string producer;
    always_comb producer = $sformatf("LSU%0d", lsu);
    always_comb begin
      lsu_trace_o[lsu] = lsu_trace_int;
      lsu_trace_o[lsu].producer = producer;
    end
    assign lsu_retire_trace_o[lsu] = '{
      valid:    lsu_result_valid && lsu_result_ready,
      rd:       lsu_wb_result_tag_o.dest_reg,
      rd_is_fp: lsu_wb_result_tag_o.dest_reg_is_fp,
      producer: producer
    };
    // pragma translate_on
  end

  // LSU empty & misalign signal combination
  // NOTE(lnoussi): Moved and combined at ALU/LSU
  // assign lsu_empty_o = (&lsu_empty);
  // assign lsu_addr_misaligned_o =(|lsu_addr_misaligned);

  // LSU writeback arbiter
  // The stream_arbiter has a feed through for 1 input so no special handling for disabled FREP
  // is required.
  lsu_result_and_tag_t lsu_wb_result_and_tag_out;

  if (NofLsus > 0) begin: gen_lsu_wb_arbiter
    stream_arbiter #(
      .DATA_T (lsu_result_and_tag_t),
      .N_INP  (NofLsus),
      .ARBITER("prio")
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
  end else begin: gen_no_lsu
    assign lsu_rs_full_o = '0;
    assign lsu_disp_reqs_ready_o = '0;
    assign lsu_disp_rsp_o = '0;
    assign lsu_exec_commit = '0;
    assign lsu_wbs_result_and_tag = '0;
    assign lsu_wbs_result_valid = '0;
    assign lsu_wbs_result_ready = '0;
    assign lsu_available_results = '0;
    assign lsu_op_reqs = '0;
    assign lsu_op_reqs_valid = '0;
    assign lsu_res_reqs_ready = '0;
    assign lsu_res_rsps = '0;
    assign lsu_res_rsps_valid = '0;
    assign lsu_op_rsps_ready = '0;
    // pragma translate_off
    assign lsu_retire_trace_o = '{default: '0};
    // pragma translate_on
    assign lsu_wb_result_and_tag_out = '0;
    assign lsu_loop_finish = 1'b1;

    assign lsu_empty = '0;
    assign lsu_wb_result_valid_o = '0;
    assign lsu_addr_misaligned = '0;
    assign lsu_dreq_o = '0;
  end

  assign lsu_wb_result_o     = lsu_wb_result_and_tag_out.result;
  assign lsu_wb_result_tag_o = lsu_wb_result_and_tag_out.tag;

  ////////////////
  // ALU + LSUs //
  ////////////////

  typedef logic [cf_math_pkg::idx_width(AluLsuNofRsrs)-1:0] alu_lsu_rs_tag_t;
  typedef logic [cf_math_pkg::max($bits(alu_lsu_rs_tag_t),$bits(instr_tag_t))-1:0] alu_lsu_instr_tag_t;

  typedef struct packed {
    fu_data_t       fu_data;
    alu_lsu_instr_tag_t tag;
    alu_lsu_instr_tag_t tag2;
  } alu_lsu_issue_req_t;

  typedef struct packed {
    fu_data_t       fu_data;
    alu_lsu_instr_tag_t tag;
  } alu_lsu_fu_issue_req_t;

  typedef struct packed {
    alu_lsu_result_t result;
    instr_tag_t  tag;
  } alu_lsu_result_and_tag_t;

  alu_lsu_result_and_tag_t  [iomsb(NofAluLsus):0][AluLsuNofResPorts-1:0] alu_lsu_wbs_results_and_tags;
  logic                     [iomsb(NofAluLsus):0][AluLsuNofResPorts-1:0] alu_lsu_wbs_results_valid;
  logic                     [iomsb(NofAluLsus):0][AluLsuNofResPorts-1:0] alu_lsu_wbs_results_ready;
  logic                     [iomsb(NofAluLsus):0] alu_lsu_empty;
  logic                     [iomsb(NofAluLsus):0] alu_lsu_addr_misaligned;

  logic [iomsb(NofAluLsus):0] alu_lsu_loop_finish;
  logic [iomsb(NofAluLsus):0] alu_lsu_compare_results;

  for (genvar alu_lsu = 0; alu_lsu < NofAluLsus; alu_lsu++) begin : gen_alu_lsus
    // Helper signals to merge the result and tag
    alu_lsu_result_t    [AluLsuNofResPorts-1:0] alu_lsu_wb_results;
    alu_lsu_instr_tag_t [AluLsuNofResPorts-1:0] alu_lsu_wb_result_tags;

    // Signals connecting the FU block and the actual FU
    alu_lsu_issue_req_t alu_lsu_issue_req;
    logic               alu_lsu_issue_req_valid;
    logic               alu_lsu_issue_req_ready;
    logic               alu_lsu_exec_commit;
    logic               alu_lsu_addr_misaligned_raw;
    alu_lsu_result_t    [AluLsuNofResPorts-1:0] alu_lsu_results;
    alu_lsu_instr_tag_t [AluLsuNofResPorts-1:0] alu_lsu_result_tags;
    logic               [AluLsuNofResPorts-1:0] alu_lsu_results_valid;
    logic               [AluLsuNofResPorts-1:0] alu_lsu_results_ready;
    logic               alu_lsu_busy;

    producer_id_t producer_start_id;
    assign producer_start_id = producer_id_t'{
      slot_id: '0, // does not matter
      rs_id:   rs_id_t'(AluLsuRsIdOffset + alu_lsu)
    };

    // pragma translate_off
    issue_alu_lsu_trace_t alu_lsu_trace_int;
    // issue_alu_trace_t _alu_lsu_trace_int;
    // assign alu_lsu_trace_int = issue_alu_lsu_trace_t'(_alu_lsu_trace_int);
    // pragma translate_on

    schnizo_fu_block #(
      .Xfrep         (Xfrep),
      .disp_req_t    (disp_req_t),
      .disp_rsp_t    (disp_rsp_t),
      .issue_req_t   (alu_lsu_issue_req_t),
      .result_t      (alu_lsu_result_t),
      .instr_tag_t   (alu_lsu_instr_tag_t),
      .NofRsis       (AluLsuNofRsis),
      .NofRsrs       (AluLsuNofRsrs),
      .NofConstants  (AluLsuNofConstants),
      .NofOperands   (AluLsuNofOperands),
      .NofResRspIfs  (AluLsuNofResRspPorts),
      .ConsumerCount (ConsumerCount),
      .RegAddrWidth  (RegAddrWidth),
      .MaxIterationsW(MaxIterationsW),
      .producer_id_t (producer_id_t),
      .slot_id_t     (result_slot_id_t),
      .operand_req_t (operand_req_t),
      .operand_t     (operand_t),
      .res_req_t     (res_req_t),
      .ext_res_req_t (ext_res_req_t),
      .available_result_t (available_result_t),
      .dest_mask_t   (dest_mask_t),
      .res_rsp_t     (res_rsp_t),
      .NofResPorts   (AluLsuNofResPorts),
      .HasTwoDests   (PostIncrement)
    ) i_fu_block (
      .clk_i,
      .rst_i,
      /// RS control signals
      .producer_id_i      (producer_start_id),
      .restart_i          (restart_i),
      .loop_state_i       (loop_state_i),
      .in_lxp_i           (in_lxp),
      .lep_iterations_i   (lep_iterations_i),
      .goto_lcp2_i        (goto_lcp2_i),
      .fu_busy_i          (alu_lsu_busy),
      .loop_finish_o      (alu_lsu_loop_finish[alu_lsu]),
      .rs_full_o          (alu_lsu_rs_full_o[alu_lsu]),
      /// Instruction stream
      // From dispatcher
      .disp_req_i         (disp_req_i),
      .disp_req_valid_i   (alu_lsu_disp_reqs_valid_i[alu_lsu]),
      .disp_req_ready_o   (alu_lsu_disp_reqs_ready_o[alu_lsu]),
      .instr_exec_commit_i(instr_exec_commit_i),
      .disp_rsp_o         (alu_lsu_disp_rsp_o[alu_lsu]),
      // To FU
      .issue_req_o        (alu_lsu_issue_req),
      .issue_req_valid_o  (alu_lsu_issue_req_valid),
      .issue_req_ready_i  (alu_lsu_issue_req_ready),
      .instr_exec_commit_o(alu_lsu_exec_commit),
      // From FU
      .result_i           (alu_lsu_results),
      .result_tag_i       (alu_lsu_result_tags),
      .result_valid_i     (alu_lsu_results_valid),
      .result_ready_o     (alu_lsu_results_ready),
      // To writeback
      .wb_result_o        (alu_lsu_wb_results),
      .wb_result_tag_o    (alu_lsu_wb_result_tags),
      .wb_result_valid_o  (alu_lsu_wbs_results_valid[alu_lsu]),
      .wb_result_ready_i  (alu_lsu_wbs_results_ready[alu_lsu]),
      /// Operand distribution network
      .available_results_o(alu_lsu_available_results[alu_lsu]),
      .op_reqs_o          (alu_lsu_op_reqs[alu_lsu]),
      .op_reqs_valid_o    (alu_lsu_op_reqs_valid[alu_lsu]),
      .op_reqs_ready_i    (alu_lsu_op_reqs_ready[alu_lsu]),
      .res_reqs_i         (alu_lsu_res_reqs[alu_lsu]),
      .res_reqs_valid_i   (alu_lsu_res_reqs_valid[alu_lsu]),
      .res_reqs_ready_o   (alu_lsu_res_reqs_ready[alu_lsu]),
      .res_rsps_o         (alu_lsu_res_rsps[alu_lsu]),
      .res_rsps_valid_o   (alu_lsu_res_rsps_valid[alu_lsu]),
      .res_rsps_ready_i   (alu_lsu_res_rsps_ready[alu_lsu]),
      .op_rsps_i          (alu_lsu_op_rsps[alu_lsu]),
      .op_rsps_valid_i    (alu_lsu_op_rsps_valid[alu_lsu]),
      .op_rsps_ready_o    (alu_lsu_op_rsps_ready[alu_lsu])
    );
    // DANGER!
    // HACK: We do not pass the branch result into the RS so keep the same RS implementation for
    // all FUs. For any write back we directly take the branch result from the FU. This is
    // possible because if we want to do a writeback the RS accepts the result only if the
    // writeback also accepts the writeback. Thus we can bypass the RS.
    // TODO: find a clean solution how to handle the branch result.
    assign alu_lsu_wbs_results_and_tags[alu_lsu][0].result = alu_lsu_wb_results[0];
    assign alu_lsu_wbs_results_and_tags[alu_lsu][0].tag = alu_lsu_wb_result_tags[0];

    if (AluLsuNofResPorts == 2) begin
      assign alu_lsu_wbs_results_and_tags[alu_lsu][1].result = alu_lsu_wb_results[1];
      assign alu_lsu_wbs_results_and_tags[alu_lsu][1].tag = alu_lsu_wb_result_tags[1];
    end

    schnizo_alu_lsu #(
      .alu_lsu_result_t     (alu_lsu_result_t),
      .alu_lsu_instr_tag_t  (alu_lsu_instr_tag_t),
      .alu_lsu_issue_req_t  (alu_lsu_issue_req_t),
      .fu_issue_req_t       (alu_lsu_fu_issue_req_t),
      .NofResPorts          (AluLsuNofResPorts),
      .PostIncrement        (PostIncrement),
      // ALU
      .XLEN                 (XLEN),
      .HasBranch            (alu_lsu == '0), // only the first ALU has the branch logic
      .HasMultiplier        ((alu_lsu == '0) && MulInAlu0), // only the first ALU has the multiplier
      .alu_res_val_t        (alu_res_val_t),
      // LSU
      .AddrWidth            (AddrWidth),
      .DataWidth            (DataWidth),
      .NumOutstandingMem    (NumOutstandingMem),
      .NumOutstandingLoads  (NumOutstandingLoads),

      .Caq                (0), // TODO: Enable. What is it?
      .CaqDepth           (CaqDepth),
      .CaqTagWidth        (CaqTagWidth),
      .CaqRespSrc         (0),
      .CaqRespTrackSeq    (0),

      .dreq_t             (dreq_t),
      .drsp_t             (drsp_t)
    ) i_alu_lsu (
      .clk_i,
      .rst_i,
      // pragma translate_off
      .trace_o          (alu_lsu_trace_int),
      // pragma translate_on
      .issue_req_i      (alu_lsu_issue_req),
      .issue_req_valid_i(alu_lsu_issue_req_valid),
      .issue_commit_i   (alu_lsu_exec_commit),
      .issue_req_ready_o(alu_lsu_issue_req_ready),
      .result_o         (alu_lsu_results),
      .compare_res_o    (alu_lsu_compare_results[alu_lsu]),
      .tag_o            (alu_lsu_result_tags),
      .result_error_o   (), // ignored
      .result_valid_o   (alu_lsu_results_valid),
      .result_ready_i   (alu_lsu_results_ready),
      .busy_o           (alu_lsu_busy),
      .empty_o          (alu_lsu_empty[alu_lsu]),
      .addr_misaligned_o(alu_lsu_addr_misaligned_raw),
      .data_req_o       (alu_lsu_dreq_o[alu_lsu]),
      .data_rsp_i       (alu_lsu_drsp_i[alu_lsu]),
      // TODO(lnoussi): How would one handle these properly?
      .caq_addr_i       ('0),
      .caq_track_write_i('0),
      .caq_req_valid_i  ('0),
      .caq_req_ready_o  (),
      .caq_rsp_valid_i  ('0),
      .caq_rsp_valid_o  ()
    );

    // Populate the producer field of the trace
    // pragma translate_off
    string producer;
    always_comb producer = $sformatf("ALU_LSU%0d", alu_lsu);
    always_comb begin
      alu_lsu_trace_o[alu_lsu] = alu_lsu_trace_int;
      alu_lsu_trace_o[alu_lsu].producer = producer;
    end
    for (genvar res_port = 0; res_port < AluLsuNofResPorts; res_port++) begin: gen_alu_lsu_retire_trace
      assign alu_lsu_retire_trace_o[alu_lsu][res_port] = '{
        valid:    alu_lsu_results_valid[res_port] && alu_lsu_results_ready[res_port],
        rd:       alu_lsu_wb_result_tags_o[res_port].dest_reg,
        rd_is_fp: alu_lsu_wb_result_tags_o[res_port].dest_reg_is_fp,
        producer: producer
      };
    end
    // pragma translate_on

    assign alu_lsu_addr_misaligned[alu_lsu] = alu_lsu_addr_misaligned_raw & !in_lxp;
  end

  // ALU writeback arbiter
  // The stream_arbiter has a feed through for 1 input so no special handling for disabled FREP
  // is required.
  alu_lsu_result_and_tag_t [1:0] alu_lsu_wb_result_and_tag_outs;

  if (NofAluLsus > 0) begin: gen_alu_lsu_wb_arbiter
    // Declare intermediate "Channel-First" signals
    // These match the port requirements of the arbiters
    alu_lsu_result_and_tag_t [AluLsuNofResPorts-1:0][iomsb(NofAluLsus):0] arb_inp_data;
    logic                    [AluLsuNofResPorts-1:0][iomsb(NofAluLsus):0] arb_inp_valid;
    logic                    [AluLsuNofResPorts-1:0][iomsb(NofAluLsus):0] arb_inp_ready;

    // transpose the arrays
    for (genvar i = 0; i < NofAluLsus; i++) begin : gen_lsu_transpose
      assign arb_inp_data[0][i]  = alu_lsu_wbs_results_and_tags[i][0];
      assign arb_inp_valid[0][i] = alu_lsu_wbs_results_valid[i][0];
      assign alu_lsu_wbs_results_ready[i][0] = arb_inp_ready[0][i];

      if (AluLsuNofResPorts == 2) begin
        assign arb_inp_data[1][i]  = alu_lsu_wbs_results_and_tags[i][1];
        assign arb_inp_valid[1][i] = alu_lsu_wbs_results_valid[i][1];
        assign alu_lsu_wbs_results_ready[i][1] = arb_inp_ready[1][i];
      end
    end

    // Instantiate using the transposed signals
    for (genvar c = 0; c < AluLsuNofResPorts; c++) begin : gen_arbiters
      stream_arbiter #(
        .DATA_T (alu_lsu_result_and_tag_t),
        .N_INP  (NofAluLsus),
        .ARBITER("prio")
      ) i_alu_lsu_wb_arbiter (
        .clk_i,
        .rst_ni     (~rst_i),
        .inp_data_i (arb_inp_data[c]),  // Now a clean [NofAluLsus-1:0] slice
        .inp_valid_i(arb_inp_valid[c]),
        .inp_ready_o(arb_inp_ready[c]),
        .oup_data_o (alu_lsu_wb_result_and_tag_outs[c]),
        .oup_valid_o(alu_lsu_wb_results_valid_o[c]),
        .oup_ready_i(alu_lsu_wb_results_ready_i[c])
      );
    end

  end else begin: gen_no_alu_lsu
    assign alu_lsu_rs_full_o = '0;
    assign alu_lsu_disp_reqs_ready_o = '0;
    assign alu_lsu_disp_rsp_o = '0;
    assign alu_lsu_wbs_results_and_tags = '{default: '0};;
    assign alu_lsu_wbs_results_valid = '{default: '0};;
    assign alu_lsu_wbs_results_ready = '{default: '0};;
    assign alu_lsu_available_results = '0;
    assign alu_lsu_op_reqs = '0;
    assign alu_lsu_op_reqs_valid = '0;
    assign alu_lsu_res_reqs_ready = '0;
    assign alu_lsu_res_rsps = '0;
    assign alu_lsu_res_rsps_valid = '0;
    assign alu_lsu_op_rsps_ready = '0;
    // pragma translate_off
    assign alu_lsu_retire_trace_o = '{default: '{default: '0}};
    // pragma translate_on
    assign alu_lsu_wb_result_and_tag_outs = '0;
    assign alu_lsu_wb_results_valid_o = '0;
    assign alu_lsu_loop_finish = 1'b1;

    assign alu_lsu_empty = '0;
    assign alu_lsu_addr_misaligned = '0;

    assign alu_lsu_dreq_o = '0;
  end

  assign alu_lsu_wb_results_o[0]     = alu_lsu_wb_result_and_tag_outs[0].result;
  assign alu_lsu_wb_result_tags_o[0] = alu_lsu_wb_result_and_tag_outs[0].tag;

  if (AluLsuNofResPorts == 2) begin: gen_connect_2nd_alu_lsu_res_port
    assign alu_lsu_wb_results_o[1]     = alu_lsu_wb_result_and_tag_outs[1].result;
    assign alu_lsu_wb_result_tags_o[1] = alu_lsu_wb_result_and_tag_outs[1].tag;
  end

  // MUX IN SPECIAL SIGNALS
  // ----------------------

  // ALU branch result forwarding
  // We bypass the arbiter for branch results as only ALU 0 has branch logic.
  // We need the branch result at least in LCP1 to support jump & branch instructions where we
  // fallback into the HW loop mode. If we decide to crash if an unsupported instruction is
  // encountered, it is possible to optimize the timing by only forwarding the ALU result in
  // regular mode. This will gain around 10ps for a 1ns target clock cycle.
  alu_result_t alu_lsu_branch_result;
  assign alu_lsu_branch_result = alu_result_t'{
    result: alu_lsu_wbs_results_and_tags[0][0].result,
    compare_res: alu_lsu_compare_results[0]
  };
  assign branch_result_o = (UseAluLsu) ? alu_lsu_branch_result : alu_wbs_result_and_tag[0].result;
  assign lsu_empty_o = UseAluLsu ? (&alu_lsu_empty) : (&lsu_empty);
  assign lsu_addr_misaligned_o = UseAluLsu ? (|alu_lsu_addr_misaligned) : (|lsu_addr_misaligned);

  //////////
  // FPUs //
  //////////

  typedef logic [FLEN-1:0] fpu_result_t;

  typedef logic [cf_math_pkg::idx_width(FpuNofRss)-1:0] fpu_rs_tag_t;

  typedef logic [cf_math_pkg::max($bits(fpu_rs_tag_t),$bits(instr_tag_t))-1:0] fpu_instr_tag_t;

  typedef struct packed {
    fu_data_t       fu_data;
    fpu_instr_tag_t tag;
  } fpu_issue_req_t;

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

  logic [NofFpus-1:0] fpu_loop_finish;

  for (genvar fpu = 0; fpu < NofFpus; fpu++) begin : gen_fpus
    // Helper signals to merge the result and tag
    fpu_result_t    fpu_wb_result;
    fpu_instr_tag_t fpu_wb_result_tag;

    // Signals connecting the FU block and the actual FU
    fpu_issue_req_t fpu_issue_req;
    logic           fpu_issue_req_valid;
    logic           fpu_issue_req_ready;
    logic           fpu_exec_commit;
    fpu_result_t    fpu_result;
    fpu_instr_tag_t fpu_result_tag;
    logic           fpu_busy;

    producer_id_t producer_start_id;
    assign producer_start_id = producer_id_t'{
      slot_id: '0, // does not matter
      rs_id:   rs_id_t'(FpuRsIdOffset + fpu)
    };

    // pragma translate_off
    issue_fpu_trace_t fpu_trace_int;
    // pragma translate_on

    schnizo_fu_block #(
      .Xfrep         (Xfrep),
      .disp_req_t    (disp_req_t),
      .disp_rsp_t    (disp_rsp_t),
      .issue_req_t   (fpu_issue_req_t),
      .result_t      (fpu_result_t),
      .instr_tag_t   (fpu_instr_tag_t),
      .NofRsis       (FpuNofRss),
      .NofRsrs       (FpuNofRss),
      .NofConstants  (FpuNofConstants),
      .NofOperands   (FpuNofOperands),
      .NofResRspIfs  (FpuNofResRspPorts),
      .ConsumerCount (ConsumerCount),
      .RegAddrWidth  (RegAddrWidth),
      .MaxIterationsW(MaxIterationsW),
      .producer_id_t (producer_id_t),
      .slot_id_t     (result_slot_id_t),
      .operand_req_t (operand_req_t),
      .operand_t     (operand_t),
      .res_req_t     (res_req_t),
      .ext_res_req_t (ext_res_req_t),
      .available_result_t (available_result_t),
      .dest_mask_t   (dest_mask_t),
      .res_rsp_t     (res_rsp_t)
    ) i_fu_block (
      .clk_i,
      .rst_i,
      /// RS control signals
      .producer_id_i      (producer_start_id),
      .restart_i          (restart_i),
      .loop_state_i       (loop_state_i),
      .in_lxp_i           (in_lxp),
      .lep_iterations_i   (lep_iterations_i),
      .goto_lcp2_i        (goto_lcp2_i),
      .fu_busy_i          (fpu_busy),
      .loop_finish_o      (fpu_loop_finish[fpu]),
      .rs_full_o          (fpu_rs_full_o[fpu]),
      /// Instruction stream
      // From dispatcher
      .disp_req_i         (disp_req_i),
      .disp_req_valid_i   (fpu_disp_reqs_valid_i[fpu]),
      .disp_req_ready_o   (fpu_disp_reqs_ready_o[fpu]),
      .instr_exec_commit_i(fpu_instr_exec_commit_i),
      .disp_rsp_o         (fpu_disp_rsp_o[fpu]),
      // To FU
      .issue_req_o        (fpu_issue_req),
      .issue_req_valid_o  (fpu_issue_req_valid),
      .issue_req_ready_i  (fpu_issue_req_ready),
      .instr_exec_commit_o(fpu_exec_commit),
      // From FU
      .result_i           (fpu_result),
      .result_tag_i       (fpu_result_tag),
      .result_valid_i     (fpu_result_valid[fpu]),
      .result_ready_o     (fpu_result_ready[fpu]),
      // To writeback
      .wb_result_o        (fpu_wb_result),
      .wb_result_tag_o    (fpu_wb_result_tag),
      .wb_result_valid_o  (fpu_wbs_result_valid[fpu]),
      .wb_result_ready_i  (fpu_wbs_result_ready[fpu]),
      /// Operand distribution network
      .available_results_o(fpu_available_results[fpu]),
      .op_reqs_o          (fpu_op_reqs[fpu]),
      .op_reqs_valid_o    (fpu_op_reqs_valid[fpu]),
      .op_reqs_ready_i    (fpu_op_reqs_ready[fpu]),
      .res_reqs_i         (fpu_res_reqs[fpu]),
      .res_reqs_valid_i   (fpu_res_reqs_valid[fpu]),
      .res_reqs_ready_o   (fpu_res_reqs_ready[fpu]),
      .res_rsps_o         (fpu_res_rsps[fpu]),
      .res_rsps_valid_o   (fpu_res_rsps_valid[fpu]),
      .res_rsps_ready_i   (fpu_res_rsps_ready[fpu]),
      .op_rsps_i          (fpu_op_rsps[fpu]),
      .op_rsps_valid_i    (fpu_op_rsps_valid[fpu]),
      .op_rsps_ready_o    (fpu_op_rsps_ready[fpu])
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
      .issue_req_t      (fpu_issue_req_t),
      .instr_tag_t      (fpu_instr_tag_t)
    ) i_fpu (
      .clk_i,
      .rst_ni           (~rst_i),
      // pragma translate_off
      .trace_o          (fpu_trace_int),
      // pragma translate_on
      .hart_id_i        (hard_id_i),
      .issue_req_i      (fpu_issue_req),
      .issue_req_valid_i(fpu_issue_req_valid),
      .issue_commit_i   (fpu_exec_commit),
      .issue_req_ready_o(fpu_issue_req_ready),
      .result_o         (fpu_result),
      .tag_o            (fpu_result_tag),
      .result_valid_o   (fpu_result_valid[fpu]),
      .result_ready_i   (fpu_result_ready[fpu]),
      .status_o         (fpu_status[fpu]),
      .busy_o           (fpu_busy)
    );

    // Populate the producer and instr_iter fields of the trace
    // pragma translate_off
    string producer;
    always_comb producer = $sformatf("FPU%0d", fpu);
    always_comb begin
      fpu_trace_o[fpu] = fpu_trace_int;
      fpu_trace_o[fpu].producer = producer;
    end
    assign fpu_retire_trace_o[fpu] = '{
      valid:    fpu_result_valid[fpu] && fpu_result_ready[fpu],
      rd:       fpu_wb_result_tag_o.dest_reg,
      rd_is_fp: fpu_wb_result_tag_o.dest_reg_is_fp,
      producer: producer
    };
    // pragma translate_on
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
  // The stream_arbiter has a feed through for 1 input so no special handling for disabled FREP
  // is required.
  fpu_result_and_tag_t fpu_wb_result_and_tag_out;
  stream_arbiter #(
    .DATA_T (fpu_result_and_tag_t),
    .N_INP  (NofFpus),
    .ARBITER("prio")
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

  ////////////
  // Status //
  ////////////

  // The complete core finishes if all RS finish.
  assign all_rs_finish_o = &{&alu_loop_finish, &lsu_loop_finish, &alu_lsu_loop_finish, &fpu_loop_finish};

  ////////////////////
  // Tracer helpers //
  ////////////////////

  // pragma translate_off

  function automatic string rs_to_string(rs_id_t rs_id);
    string fu_name;
    int fu_id;

    if (rs_id < NofAlus) begin
      fu_name = "ALU";
      fu_id = rs_id - 0;
    end else if (rs_id < NofAlus + NofLsus) begin
      fu_name = "LSU";
      fu_id = rs_id - NofAlus;
    end else if (rs_id < NofAlus + NofLsus + NofAluLsus) begin
      fu_name = "ALU_LSU";
      fu_id = rs_id - NofAlus - NofLsus;
    end else begin
      fu_name = "FPU";
      fu_id = rs_id - NofAlus - NofLsus - NofAluLsus;
    end

    return $sformatf("%s%0d", fu_name, fu_id);
  endfunction

  // This function converts a producer id to a string depending on the number of FUs and RSSs.
  // This string converts e.g. producer id 2 to "0.1" (ALU 0, RSS 1)
  // This function must be inside this module to have access to the producer_id_t type and
  // the id computations.
  function automatic string producer_to_string(producer_id_t producer_id);
    string fu_name;

    fu_name = rs_to_string(producer_id.rs_id);

    return $sformatf("%s.%0d", fu_name, producer_id.slot_id);
  endfunction

  // This function converts a consumer id to a string depending on the number of FUs.
  // As the crossbar is independent of the number of slots there is no information about
  // which slot is the actual consumer. But we add the information about the request port.
  // Returns "FU.x.y" where FU is the actual FU type, x is the port id and y the operand id.
  function automatic string consumer_to_string(operand_id_t consumer_id);
    int unsigned consumer = unsigned'(consumer_id);
    int unsigned num_ops;
    int unsigned rs_id;
    int unsigned op_id;
    string fu_name;

    if (consumer < LsuOpIdOffset) begin
      num_ops = AluNofOperands;
      consumer = consumer - AluOpIdOffset;
      fu_name = "ALU";
    end else if (consumer < AluLsuOpIdOffset) begin
      num_ops = LsuNofOperands;
      consumer = consumer - LsuOpIdOffset;
      fu_name = "LSU";
    end else if (consumer < FpuOpIdOffset) begin
      num_ops = AluLsuNofOperands;
      consumer = consumer - AluLsuOpIdOffset;
      fu_name = "ALU_LSU";
    end else begin
      num_ops = FpuNofOperands;
      consumer = consumer - FpuOpIdOffset;
      fu_name = "FPU";
    end

    rs_id = consumer / num_ops;
    // Reduce into operand range of current RS.
    // --> range of 0..(num_ops - 1)
    consumer = consumer - (rs_id * num_ops);
    op_id = consumer % num_ops;

    return $sformatf("%s%0d.%0d", fu_name, rs_id, op_id);
  endfunction

  // pragma translate_on

endmodule
