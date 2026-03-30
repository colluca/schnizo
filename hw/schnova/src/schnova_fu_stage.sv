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
module schnova_fu_stage import schnova_pkg::*, schnova_tracer_pkg::*; #(
  // Globally enable the superscalar feature
  parameter bit          Xfrep             = 1,
  parameter bit          MulInAlu0         = 1'b1,
  parameter int unsigned NofAlus           = 1,
  parameter int unsigned AluNofRss         = 3,
  parameter int unsigned AluNofOperands    = 2,
  parameter int unsigned AluNofResReqIfs   = 3,
  parameter int unsigned AluNofResRspPorts = 1,
  parameter int unsigned NofLsus           = 1,
  parameter int unsigned LsuNofRss         = 3,
  parameter int unsigned LsuNofOperands    = 4,
  parameter int unsigned LsuNofResReqIfs   = 3,
  parameter int unsigned LsuNofResRspPorts = 1,
  parameter int unsigned NofFpus           = 1,
  parameter int unsigned FpuNofRss         = 2,
  parameter int unsigned FpuNofOperands    = 3,
  parameter int unsigned FpuNofResReqIfs   = 3,
  parameter int unsigned FpuNofResRspPorts = 1,
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
  parameter type         slot_id_t      = logic,
  parameter type         rs_id_t        = logic,
  parameter type         operand_id_t   = logic, // used for tracer function
  parameter type         disp_req_t     = logic,
  parameter type         disp_rsp_t     = logic,
  parameter type         fu_data_t      = logic,
  parameter type         instr_tag_t    = logic,
  parameter type         issue_req_t    = logic,
  parameter type         alu_result_t   = logic,
  parameter type         alu_res_val_t  = logic,
  parameter type         dreq_t         = logic,
  parameter type         drsp_t         = logic,
  parameter type         phy_id_t       = logic,
  parameter type         operand_req_t  = logic,
  parameter type         operand_t      = logic,
  localparam type addr_t = logic [AddrWidth-1:0],
  localparam type data_t = logic [DataWidth-1:0]
) (
  input  logic        clk_i,
  input  logic        rst_i,
  input  logic [31:0] hard_id_i,

  // Trace outputs
  // pragma translate_off
  output issue_alu_trace_t  alu_trace_o        [NofAlus-1:0],
  output issue_lsu_trace_t  lsu_trace_o        [NofLsus-1:0],
  output issue_fpu_trace_t  fpu_trace_o        [NofFpus-1:0],
  output retire_fu_trace_t  alu_retire_trace_o [NofAlus-1:0],
  output retire_fu_trace_t  lsu_retire_trace_o [NofLsus-1:0],
  output retire_fu_trace_t  fpu_retire_trace_o [NofFpus-1:0],
  // pragma translate_on

  /// RS control signals
  input  logic                      restart_i,
  input  logic                      en_superscalar_i,
  // Asserted if all RS are either finishing in this cycle or have already finished
  output logic                      all_rs_finish_o,

  /// Instruction streams & FU status signals
  input  disp_req_t               disp_req_i,
  // Commit the dispatch request and allow the downstream passing.
  // The FU blocks do not require a commit signal as when we won't commit we have an exception
  // and thus anyway abort the LxP and reset the RS and RSSs.
  input  logic                    instr_exec_commit_i,
  input  logic      [NofAlus-1:0] alu_disp_reqs_valid_i,
  output logic      [NofAlus-1:0] alu_disp_reqs_ready_o,
  output disp_rsp_t [NofAlus-1:0] alu_disp_rsp_o,
  output logic      [NofAlus-1:0] alu_rs_full_o,

  input  logic      [NofLsus-1:0] lsu_disp_reqs_valid_i,
  output logic      [NofLsus-1:0] lsu_disp_reqs_ready_o,
  output disp_rsp_t [NofLsus-1:0] lsu_disp_rsp_o,
  output logic                    lsu_empty_o,
  output logic                    lsu_addr_misaligned_o,
  output dreq_t     [NofLsus-1:0] lsu_dreq_o,
  input  drsp_t     [NofLsus-1:0] lsu_drsp_i,
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
  output logic               [NofFpus-1:0] fpu_rs_full_o,
  // Combined status of all FPUs
  output fpnew_pkg::status_t fpu_status_o,
  output logic               fpu_status_valid_o,

  // Operand request interface
  output operand_req_t [NofOperandIfs-1:0] op_reqs_o,
  output logic         [NofOperandIfs-1:0] op_reqs_valid_o,
  input  logic         [NofOperandIfs-1:0] op_reqs_ready_i,

  // Operand response interface
  input  operand_t [NofOperandIfs-1:0] op_rsps_i,
  input  logic     [NofOperandIfs-1:0] op_rsps_valid_i,
  output logic     [NofOperandIfs-1:0] op_rsps_ready_o,

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

  output logic [FLEN-1:0] fpu_wb_result_o,
  output instr_tag_t      fpu_wb_result_tag_o,
  output logic            fpu_wb_result_valid_o,
  input  logic            fpu_wb_result_ready_i
);

  /////////////////////////////////////
  // Parameters and type definitions //
  /////////////////////////////////////

  // ---------------------------
  // Operand distribution network
  // ---------------------------

  localparam int unsigned NofRs = NofAlus + NofLsus + NofFpus;
  localparam int unsigned TotalNofRss = NofAlus * AluNofRss +
                                        NofLsus * LsuNofRss +
                                        NofFpus * FpuNofRss;
  localparam int unsigned TotalNofResRspPorts = NofAlus * AluNofResRspPorts +
                                                NofLsus * LsuNofResRspPorts +
                                                NofFpus * FpuNofResRspPorts;

  typedef int unsigned rs_param_array_t [NofRs-1:0];

  function automatic rs_param_array_t gen_rs_param_array(int AluParam, int LsuParam, int FpuParam);
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
    for (int unsigned i = 0; i < NofFpus; i++) begin
      tmp[k] = FpuParam;
      k++;
    end

    return tmp;
  endfunction

  localparam rs_param_array_t NofRss = gen_rs_param_array(AluNofRss, LsuNofRss, FpuNofRss);
  localparam rs_param_array_t NofRspPorts = gen_rs_param_array(AluNofResRspPorts,
    LsuNofResRspPorts, FpuNofResRspPorts);

  // ---------------------------
  // RS ID generation
  // ---------------------------

  // Each RS needs a globally unique ID. We simply count all RS.
  localparam integer unsigned AluRsIdOffset = 0;
  localparam integer unsigned LsuRsIdOffset = AluRsIdOffset + NofAlus;
  localparam integer unsigned FpuRsIdOffset = LsuRsIdOffset + NofLsus;

  // Each RS needs a globally unique ID for its operand request ports.
  // These IDs are shared between the RSSs of a reservation station.
  localparam integer unsigned AluOpIdOffset = 0;
  localparam integer unsigned LsuOpIdOffset = AluOpIdOffset +
                                              NofAlus * AluNofOperands;
  localparam integer unsigned FpuOpIdOffset = LsuOpIdOffset +
                                              NofLsus * LsuNofOperands;

  ////////////////////////////////////////
  // Operand distribution network (ODN) //
  ////////////////////////////////////////

  operand_req_t [NofAlus-1:0][AluNofOperands-1:0]  alu_op_reqs;
  logic         [NofAlus-1:0][AluNofOperands-1:0]  alu_op_reqs_valid;
  logic         [NofAlus-1:0][AluNofOperands-1:0]  alu_op_reqs_ready;
  operand_t     [NofAlus-1:0][AluNofOperands-1:0]  alu_op_rsps;
  logic         [NofAlus-1:0][AluNofOperands-1:0]  alu_op_rsps_valid;
  logic         [NofAlus-1:0][AluNofOperands-1:0]  alu_op_rsps_ready;

  operand_req_t [NofLsus-1:0][LsuNofOperands-1:0]  lsu_op_reqs;
  logic         [NofLsus-1:0][LsuNofOperands-1:0]  lsu_op_reqs_valid;
  logic         [NofLsus-1:0][LsuNofOperands-1:0]  lsu_op_reqs_ready;
  operand_t     [NofLsus-1:0][LsuNofOperands-1:0]  lsu_op_rsps;
  logic         [NofLsus-1:0][LsuNofOperands-1:0]  lsu_op_rsps_valid;
  logic         [NofLsus-1:0][LsuNofOperands-1:0]  lsu_op_rsps_ready;

  operand_req_t [NofFpus-1:0][FpuNofOperands-1:0]  fpu_op_reqs;
  logic         [NofFpus-1:0][FpuNofOperands-1:0]  fpu_op_reqs_valid;
  logic         [NofFpus-1:0][FpuNofOperands-1:0]  fpu_op_reqs_ready;
  operand_t     [NofFpus-1:0][FpuNofOperands-1:0]  fpu_op_rsps;
  logic         [NofFpus-1:0][FpuNofOperands-1:0]  fpu_op_rsps_valid;
  logic         [NofFpus-1:0][FpuNofOperands-1:0]  fpu_op_rsps_ready;

  // ---------------------------
  // Pack operand interfaces
  // ---------------------------

  // Pack the FUs' operand requests and responses into a linear array
  // TODO(colluca): think if this code can be streamlined
  always_comb begin : fu_op_reqs_rsps
    automatic integer ope_if = 0;

    op_reqs_o           = '0;
    op_reqs_valid_o     = '0;
    alu_op_reqs_ready = '0;
    lsu_op_reqs_ready = '0;
    fpu_op_reqs_ready = '0;

    op_rsps_ready_o     = '0;
    alu_op_rsps       = '0;
    alu_op_rsps_valid = '0;
    lsu_op_rsps       = '0;
    lsu_op_rsps_valid = '0;
    fpu_op_rsps       = '0;
    fpu_op_rsps_valid = '0;

    for (int alu = 0; alu < NofAlus; alu++) begin
      for (int op = 0; op < AluNofOperands; op++) begin
        // operand requests
        op_reqs_o[ope_if]            = alu_op_reqs[alu][op];
        op_reqs_valid_o[ope_if]      = alu_op_reqs_valid[alu][op];
        alu_op_reqs_ready[alu][op] = op_reqs_ready_i[ope_if];
        // operand responses
        alu_op_rsps[alu][op]       = op_rsps_i[ope_if];
        alu_op_rsps_valid[alu][op] = op_rsps_valid_i[ope_if];
        op_rsps_ready_o[ope_if]      = alu_op_rsps_ready[alu][op];
        ope_if = ope_if + 1;
      end
    end
    for (int lsu = 0; lsu < NofLsus; lsu++) begin
      for (int op = 0; op < LsuNofOperands; op++) begin
        // operand requests
        op_reqs_o[ope_if]            = lsu_op_reqs[lsu][op];
        op_reqs_valid_o[ope_if]      = lsu_op_reqs_valid[lsu][op];
        lsu_op_reqs_ready[lsu][op] = op_reqs_ready_i[ope_if];
        // operand responses
        lsu_op_rsps[lsu][op]       = op_rsps_i[ope_if];
        lsu_op_rsps_valid[lsu][op] = op_rsps_valid_i[ope_if];
        op_rsps_ready_o[ope_if]      = lsu_op_rsps_ready[lsu][op];
        ope_if = ope_if + 1;
      end
    end
    for (int fpu = 0; fpu < NofFpus; fpu++) begin
      for (int op = 0; op < FpuNofOperands; op++) begin
        // operand requests
        op_reqs_o[ope_if]            = fpu_op_reqs[fpu][op];
        op_reqs_valid_o[ope_if]      = fpu_op_reqs_valid[fpu][op];
        fpu_op_reqs_ready[fpu][op] = op_reqs_ready_i[ope_if];
        // operand responses
        fpu_op_rsps[fpu][op]       = op_rsps_i[ope_if];
        fpu_op_rsps_valid[fpu][op] = op_rsps_valid_i[ope_if];
        op_rsps_ready_o[ope_if]      = fpu_op_rsps_ready[fpu][op];
        ope_if = ope_if + 1;
      end
    end
  end

  //////////
  // ALUs //
  //////////

  typedef struct packed {
    alu_result_t result;
    instr_tag_t  tag;
  } alu_result_and_tag_t;

  alu_result_and_tag_t [NofAlus-1:0] alu_wbs_result_and_tag;
  logic                [NofAlus-1:0] alu_wbs_result_valid;
  logic                [NofAlus-1:0] alu_wbs_result_ready;

  logic [NofAlus-1:0] alu_rs_empty;
  logic [NofAlus-1:0] alu_rs_busy;

  for (genvar alu = 0; alu < NofAlus; alu++) begin : gen_alus

    // Signals connecting the FU block and the actual FU
    issue_req_t alu_issue_req;
    logic           alu_issue_req_valid;
    logic           alu_issue_req_ready;
    logic           alu_exec_commit;
    alu_result_t    alu_result;
    instr_tag_t     alu_result_tag;
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

    schnova_fu_block #(
      .disp_req_t    (disp_req_t),
      .disp_rsp_t    (disp_rsp_t),
      .issue_req_t   (issue_req_t),
      .result_t      (alu_res_val_t),
      .instr_tag_t   (instr_tag_t),
      .NofRss        (AluNofRss),
      .NofOperands   (AluNofOperands),
      .NofResRspIfs  (AluNofRss),
      .RegAddrWidth  (RegAddrWidth),
      .MaxIterationsW(MaxIterationsW),
      .producer_id_t (producer_id_t),
      .slot_id_t     (slot_id_t),
      .phy_id_t      (phy_id_t),
      .operand_req_t (operand_req_t),
      .operand_t     (operand_t)
    ) i_fu_block (
      .clk_i,
      .rst_i,
      /// RS control signals
      .producer_id_i      (producer_start_id),
      .restart_i          (restart_i),
      .en_superscalar_i   (en_superscalar_i),
      .rs_full_o          (alu_rs_full_o[alu]),
      .rs_empty_o         (alu_rs_empty[alu]),
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
      /// Operand distribution network
      .op_reqs_o          (alu_op_reqs[alu]),
      .op_reqs_valid_o    (alu_op_reqs_valid[alu]),
      .op_reqs_ready_i    (alu_op_reqs_ready[alu]),
      .op_rsps_i          (alu_op_rsps[alu]),
      .op_rsps_valid_i    (alu_op_rsps_valid[alu]),
      .op_rsps_ready_o    (alu_op_rsps_ready[alu])
    );

    // Map the results fromn the FU to the writeback arbiter signals
    assign alu_wbs_result_and_tag[alu].result = '{
      result:      alu_result.result,
      compare_res: alu_result.compare_res
    };
    assign alu_wbs_result_and_tag[alu].tag = alu_result_tag;

    assign alu_wbs_result_valid[alu] = alu_result_valid;
    assign alu_result_ready = alu_wbs_result_ready[alu];

    schnova_alu #(
      .XLEN         (XLEN),
      .HasBranch    (alu == '0), // only the first ALU has the branch logic
      .HasMultiplier((alu == '0) && MulInAlu0), // only the first ALU has the multiplier
      .issue_req_t  (issue_req_t),
      .instr_tag_t  (instr_tag_t)
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

    assign alu_rs_busy[alu] = (en_superscalar_i & alu_busy) | ~alu_rs_empty[alu];

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
  assign branch_result_o = alu_wbs_result_and_tag[0].result;

  // ALU writeback arbiter
  // The stream_arbiter has a feed through for 1 input so no special handling for disabled FREP
  // is required.
  alu_result_and_tag_t alu_wb_result_and_tag_out;
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

  assign alu_wb_result_o     = alu_wb_result_and_tag_out.result;
  assign alu_wb_result_tag_o = alu_wb_result_and_tag_out.tag;

  //////////
  // LSUs //
  //////////

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

  logic [NofLsus-1:0] lsu_rs_empty;
  logic [NofLsus-1:0] lsu_rs_busy;

  for (genvar lsu = 0; lsu < NofLsus; lsu++) begin : gen_lsus

    // Signals connecting the FU block and the actual FU
    issue_req_t  lsu_issue_req;
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

    schnova_fu_block #(
      .disp_req_t    (disp_req_t),
      .disp_rsp_t    (disp_rsp_t),
      .issue_req_t   (issue_req_t),
      .result_t      (lsu_result_t),
      .instr_tag_t   (instr_tag_t),
      .NofRss        (LsuNofRss),
      .NofOperands   (LsuNofOperands),
      .NofResRspIfs  (LsuNofRss),
      .RegAddrWidth  (RegAddrWidth),
      .MaxIterationsW(MaxIterationsW),
      .producer_id_t (producer_id_t),
      .slot_id_t     (slot_id_t),
      .phy_id_t      (phy_id_t),
      .operand_req_t (operand_req_t),
      .operand_t     (operand_t)
    ) i_fu_block (
      .clk_i,
      .rst_i,
      /// RS control signals
      .producer_id_i      (producer_start_id),
      .restart_i          (restart_i),
      .en_superscalar_i   (en_superscalar_i),
      .rs_full_o          (lsu_rs_full_o[lsu]),
      .rs_empty_o         (lsu_rs_empty[lsu]),
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
      /// Operand distribution network
      .op_reqs_o          (lsu_op_reqs[lsu]),
      .op_reqs_valid_o    (lsu_op_reqs_valid[lsu]),
      .op_reqs_ready_i    (lsu_op_reqs_ready[lsu]),
      .op_rsps_i          (lsu_op_rsps[lsu]),
      .op_rsps_valid_i    (lsu_op_rsps_valid[lsu]),
      .op_rsps_ready_o    (lsu_op_rsps_ready[lsu])
    );

    // Map the results fromn the FU to the writeback arbiter signals
    assign lsu_wbs_result_and_tag[lsu].result = lsu_result;
    assign lsu_wbs_result_and_tag[lsu].tag    = lsu_result_tag;

    assign lsu_wbs_result_valid[lsu] = lsu_result_valid;
    assign lsu_result_ready = lsu_wbs_result_ready[lsu];

    schnova_lsu #(
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

    assign lsu_rs_busy[lsu] = (en_superscalar_i & lsu_busy) | ~lsu_rs_empty[lsu];

    // TODO (soderma): Handler exceptions correctly in superscalar
    // Suppress exceptions in superscalar mode for now because we anyway don't handle them one cycle later.
    assign lsu_addr_misaligned[lsu] = lsu_addr_misaligned_raw & !en_superscalar_i;

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
      producer: producer
    };
    // pragma translate_on
  end

  // LSU empty & misalign signal combination
  assign lsu_empty_o = (&lsu_empty);
  assign lsu_addr_misaligned_o =(|lsu_addr_misaligned);

  // LSU writeback arbiter
  // The stream_arbiter has a feed through for 1 input so no special handling for disabled FREP
  // is required.
  lsu_result_and_tag_t lsu_wb_result_and_tag_out;
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

  assign lsu_wb_result_o     = lsu_wb_result_and_tag_out.result;
  assign lsu_wb_result_tag_o = lsu_wb_result_and_tag_out.tag;

  //////////
  // FPUs //
  //////////

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

  logic [NofFpus-1:0] fpu_rs_empty;
  logic [NofFpus-1:0] fpu_rs_busy;

  for (genvar fpu = 0; fpu < NofFpus; fpu++) begin : gen_fpus
    // Signals connecting the FU block and the actual FU
    issue_req_t     fpu_issue_req;
    logic           fpu_issue_req_valid;
    logic           fpu_issue_req_ready;
    logic           fpu_exec_commit;
    fpu_result_t    fpu_result;
    instr_tag_t     fpu_result_tag;
    logic           fpu_busy;

    producer_id_t producer_start_id;
    assign producer_start_id = producer_id_t'{
      slot_id: '0, // does not matter
      rs_id:   rs_id_t'(FpuRsIdOffset + fpu)
    };

    // pragma translate_off
    issue_fpu_trace_t fpu_trace_int;
    // pragma translate_on

    schnova_fu_block #(
      .disp_req_t    (disp_req_t),
      .disp_rsp_t    (disp_rsp_t),
      .issue_req_t   (issue_req_t),
      .result_t      (fpu_result_t),
      .instr_tag_t   (instr_tag_t),
      .NofRss        (FpuNofRss),
      .NofOperands   (FpuNofOperands),
      .NofResRspIfs  (FpuNofRss),
      .RegAddrWidth  (RegAddrWidth),
      .MaxIterationsW(MaxIterationsW),
      .producer_id_t (producer_id_t),
      .slot_id_t     (slot_id_t),
      .phy_id_t      (phy_id_t),
      .operand_req_t (operand_req_t),
      .operand_t     (operand_t)
    ) i_fu_block (
      .clk_i,
      .rst_i,
      /// RS control signals
      .producer_id_i      (producer_start_id),
      .restart_i          (restart_i),
      .en_superscalar_i   (en_superscalar_i),
      .rs_full_o          (fpu_rs_full_o[fpu]),
      .rs_empty_o         (fpu_rs_empty[fpu]),
      /// Instruction stream
      // From dispatcher
      .disp_req_i         (disp_req_i),
      .disp_req_valid_i   (fpu_disp_reqs_valid_i[fpu]),
      .disp_req_ready_o   (fpu_disp_reqs_ready_o[fpu]),
      .instr_exec_commit_i(instr_exec_commit_i),
      .disp_rsp_o         (fpu_disp_rsp_o[fpu]),
      // To FU
      .issue_req_o        (fpu_issue_req),
      .issue_req_valid_o  (fpu_issue_req_valid),
      .issue_req_ready_i  (fpu_issue_req_ready),
      .instr_exec_commit_o(fpu_exec_commit),
      /// Operand distribution network
      .op_reqs_o          (fpu_op_reqs[fpu]),
      .op_reqs_valid_o    (fpu_op_reqs_valid[fpu]),
      .op_reqs_ready_i    (fpu_op_reqs_ready[fpu]),
      .op_rsps_i          (fpu_op_rsps[fpu]),
      .op_rsps_valid_i    (fpu_op_rsps_valid[fpu]),
      .op_rsps_ready_o    (fpu_op_rsps_ready[fpu])
    );

    // Map the results from the FU to the writeback arbiter signals
    assign fpu_wbs_result_and_tag[fpu].result = fpu_result;
    assign fpu_wbs_result_and_tag[fpu].tag    = fpu_result_tag;

    assign fpu_wbs_result_valid[fpu] = fpu_result_valid[fpu];
    assign fpu_result_ready[fpu] = fpu_wbs_result_ready[fpu];

    schnova_fpu #(
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

    assign fpu_rs_busy[fpu] = (en_superscalar_i & fpu_busy) | ~fpu_rs_empty[fpu];

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
  assign all_rs_finish_o = &{~alu_rs_busy, ~lsu_rs_busy, ~fpu_rs_busy};

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
    end else begin
      fu_name = "FPU";
      fu_id = rs_id - NofAlus - NofLsus;
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
    end else if (consumer < FpuOpIdOffset) begin
      num_ops = LsuNofOperands;
      consumer = consumer - LsuOpIdOffset;
      fu_name = "LSU";
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
