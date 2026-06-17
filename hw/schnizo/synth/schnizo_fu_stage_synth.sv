// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module schnizo_fu_stage_synth import cf_math_pkg::*; #(
  parameter bit          Xfrep = 1,
  parameter bit          MulInAlu0 = 1'b1,
  parameter bit          UseAluLsu = 0,
  parameter bit          PostIncrement = 1'b0,
  parameter int unsigned NofRss = 0,
  parameter int unsigned ConstantMemory = 0,
  // ALU
  parameter int unsigned NofAlus = 3,
  parameter int unsigned AluNofRss = NofRss,
  parameter int unsigned AluNofConstants = ConstantMemory,
  // LSU
  parameter int unsigned NofLsus = 3,
  parameter int unsigned LsuNofRss = NofRss,
  parameter int unsigned LsuNofConstants = ConstantMemory,
  // ALU-LSU
  parameter int unsigned NofAluLsus = 0,
  parameter int unsigned AluLsuNofRsis = 2*NofRss,
  parameter int unsigned AluLsuNofRsrs = 2*NofRss,
  parameter int unsigned AluLsuNofResPorts = 2,
  parameter int unsigned AluLsuNofConstants = 4,
  // FPU
  parameter int unsigned NofFpus = 1,
  parameter int unsigned FpuNofRss = NofRss,
  parameter int unsigned FpuNofConstants = ConstantMemory
) (
  input  logic                                     clk_i,
  input  logic                                     rst_ni,
  input  logic                                     restart_i,
  input  schnizo_pkg::loop_state_e                 loop_state_i,
  input  logic [schnizo_pkg::FrepMaxItersWidth-1:0] lep_iterations_i,
  input  logic                                     goto_lcp2_i,
  output logic                                     all_rs_finish_o,
  input  schnizo_synth_pkg::disp_req_t             disp_req_i,
  input  logic                                     instr_exec_commit_i,
  input  logic               [iomsb(NofAlus):0]         alu_disp_reqs_valid_i,
  output logic               [iomsb(NofAlus):0]         alu_disp_reqs_ready_o,
  output schnizo_synth_pkg::disp_rsp_t [iomsb(NofAlus):0] alu_disp_rsp_o,
  output logic               [iomsb(NofAlus):0]         alu_rs_full_o,
  input  logic               [iomsb(NofLsus):0]         lsu_disp_reqs_valid_i,
  output logic               [iomsb(NofLsus):0]         lsu_disp_reqs_ready_o,
  output schnizo_synth_pkg::disp_rsp_t [iomsb(NofLsus):0] lsu_disp_rsp_o,
  output logic                                     lsu_empty_o,
  output logic                                     lsu_addr_misaligned_o,
  output schnizo_synth_pkg::data_req_t [iomsb(NofLsus):0] lsu_dreq_o,
  input  schnizo_synth_pkg::data_rsp_t [iomsb(NofLsus):0] lsu_drsp_i,
  output logic               [iomsb(NofLsus):0]         lsu_rs_full_o,
  input  logic               [iomsb(NofAluLsus):0]         alu_lsu_disp_reqs_valid_i,
  output logic               [iomsb(NofAluLsus):0]         alu_lsu_disp_reqs_ready_o,
  output schnizo_synth_pkg::disp_rsp_t [iomsb(NofAluLsus):0][PostIncrement:0] alu_lsu_disp_rsp_o,
  output logic               [iomsb(NofAluLsus):0]         alu_lsu_rs_full_o,
  output schnizo_synth_pkg::data_req_t [iomsb(NofAluLsus):0] alu_lsu_dreq_o,
  input  schnizo_synth_pkg::data_rsp_t [iomsb(NofAluLsus):0] alu_lsu_drsp_i,
  input  logic               [iomsb(NofFpus):0]         fpu_disp_reqs_valid_i,
  output logic               [iomsb(NofFpus):0]         fpu_disp_reqs_ready_o,
  output schnizo_synth_pkg::disp_rsp_t [iomsb(NofFpus):0] fpu_disp_rsp_o,
  output logic               [iomsb(NofFpus):0]         fpu_rs_full_o,
  output fpnew_pkg::status_t                       fpu_status_o,
  output logic                                     fpu_status_valid_o,
  output schnizo_synth_pkg::alu_result_t           alu_wb_result_o,
  output schnizo_pkg::instr_tag_t                  alu_wb_result_tag_o,
  output logic                                     alu_wb_result_valid_o,
  input  logic                                     alu_wb_result_ready_i,
  output schnizo_synth_pkg::alu_result_t           branch_result_o,
  output schnizo_synth_pkg::data_t                 lsu_wb_result_o,
  output schnizo_pkg::instr_tag_t                  lsu_wb_result_tag_o,
  output logic                                     lsu_wb_result_valid_o,
  input  logic                                     lsu_wb_result_ready_i,
  output schnizo_synth_pkg::alu_lsu_result_t [AluLsuNofResPorts-1:0] alu_lsu_wb_results_o,
  output schnizo_pkg::instr_tag_t            [AluLsuNofResPorts-1:0] alu_lsu_wb_result_tags_o,
  output logic                               [AluLsuNofResPorts-1:0] alu_lsu_wb_results_valid_o,
  input  logic                               [AluLsuNofResPorts-1:0] alu_lsu_wb_results_ready_i,
  output logic [schnizo_synth_pkg::FLEN-1:0]       fpu_wb_result_o,
  output schnizo_pkg::instr_tag_t                  fpu_wb_result_tag_o,
  output logic                                     fpu_wb_result_valid_o,
  input  logic                                     fpu_wb_result_ready_i
);

  localparam int unsigned NofOperandIfs = NofAlus*2 + NofLsus*3 + NofAluLsus*3 + NofFpus*3;
  localparam int unsigned NofResReqIfs = NofAlus + NofLsus + NofAluLsus + NofFpus;

  localparam int unsigned MaxNofRss = (AluNofRss >= LsuNofRss && AluNofRss >= AluLsuNofRsrs && AluNofRss >= FpuNofRss) ? AluNofRss :
                                      (LsuNofRss >= AluLsuNofRsrs && LsuNofRss >= FpuNofRss)             ? LsuNofRss :
                                      (AluLsuNofRsrs >= FpuNofRss)                         ? AluLsuNofRsrs : FpuNofRss;

  localparam int unsigned ActualRsIdWidth   = cf_math_pkg::idx_width(NofAlus + NofLsus + NofAluLsus + NofFpus);
  localparam int unsigned ActualSlotIdWidth = cf_math_pkg::idx_width(MaxNofRss);

  typedef logic [ActualSlotIdWidth-1:0] actual_slot_id_t;
  typedef logic [ActualRsIdWidth-1:0]   actual_rs_id_t;

  typedef struct packed {
    actual_slot_id_t slot_id;
    actual_rs_id_t   rs_id;
  } actual_producer_id_t;

  typedef struct packed {
    actual_producer_id_t producer;
    logic                valid;
  } actual_rmt_entry_t;

  typedef struct packed {
    schnizo_synth_pkg::fu_data_t fu_data;
    actual_rmt_entry_t           producer_op_a;
    actual_rmt_entry_t           producer_op_b;
    actual_rmt_entry_t           producer_op_c;
    logic                        has_two_dests;
    actual_rmt_entry_t           current_dest_producer;
    actual_rmt_entry_t           current_dest2_producer;
    schnizo_pkg::instr_tag_t     tag;
    schnizo_pkg::instr_tag_t     tag2;
  } actual_disp_req_t;

  typedef struct packed {
    actual_producer_id_t producer;
  } actual_disp_rsp_t;


  actual_disp_req_t disp_req_casted;
  assign disp_req_casted = disp_req_i; // SV handles truncation of wide package fields to narrow actual fields

  actual_disp_rsp_t [iomsb(NofAlus):0]     alu_disp_rsp_internal;
  actual_disp_rsp_t [iomsb(NofLsus):0]     lsu_disp_rsp_internal;
  actual_disp_rsp_t [iomsb(NofAluLsus):0][PostIncrement:0] alu_lsu_disp_rsp_internal;
  actual_disp_rsp_t [iomsb(NofFpus):0]     fpu_disp_rsp_internal;

  // Cast internal results back to wide package ports
  always_comb begin
    alu_disp_rsp_o = '0;
    for (int i=0; i<NofAlus; i++) alu_disp_rsp_o[i] = alu_disp_rsp_internal[i];
    lsu_disp_rsp_o = '0;
    for (int i=0; i<NofLsus; i++) lsu_disp_rsp_o[i] = lsu_disp_rsp_internal[i];
    for (int i=0; i<NofAluLsus; i++) begin
      alu_lsu_disp_rsp_o[i][0] = alu_lsu_disp_rsp_internal[i][0];
    end
    fpu_disp_rsp_o = '0;
    for (int i=0; i<NofFpus; i++) fpu_disp_rsp_o[i] = fpu_disp_rsp_internal[i];
  end

  if (PostIncrement) begin: gen_post_increment
    always_comb begin
      for (int i=0; i<NofAluLsus; i++) begin
        alu_lsu_disp_rsp_o[i][1] = alu_lsu_disp_rsp_internal[i][1];
      end
    end
  end

  schnizo_fu_stage #(
    .Xfrep(Xfrep),
    .MulInAlu0(MulInAlu0),
    .NofAlus(NofAlus),
    .AluNofRss(AluNofRss),
    .AluNofConstants(AluNofConstants),
    .AluNofOperands(2),
    .AluNofResReqIfs(1),
    .AluNofResRspPorts(2),
    .NofLsus(NofLsus),
    .LsuNofRss(LsuNofRss),
    .LsuNofConstants(LsuNofConstants),
    .LsuNofOperands(3),
    .LsuNofResReqIfs(1),
    .LsuNofResRspPorts(2),
    .NofFpus(NofFpus),
    .FpuNofRss(FpuNofRss),
    .FpuNofConstants(FpuNofConstants),
    .FpuNofOperands(3),
    .FpuNofResReqIfs(1),
    .FpuNofResRspPorts(2),
    .UseAluLsu(UseAluLsu),
    .PostIncrement(PostIncrement),
    .NofAluLsus(NofAluLsus),
    .AluLsuNofRsis(AluLsuNofRsis),
    .AluLsuNofRsrs(AluLsuNofRsrs),
    .AluLsuNofConstants(AluLsuNofConstants),
    .AluLsuNofOperands(3),
    .AluLsuNofResReqIfs(1),
    .AluLsuNofResRspPorts(2),
    .AluLsuNofResPorts(AluLsuNofResPorts),
    .NofOperandIfs(NofOperandIfs),
    .NofResReqIfs(NofResReqIfs),
    .XLEN(schnizo_synth_pkg::XLEN),
    .FLEN(schnizo_synth_pkg::FLEN),
    .OpLen(schnizo_synth_pkg::OpLen),
    .AddrWidth(schnizo_synth_pkg::AddrWidth),
    .DataWidth(schnizo_synth_pkg::DataWidth),
    .RegAddrWidth(schnizo_pkg::RegAddrSize),
    .MaxIterationsW(schnizo_pkg::FrepMaxItersWidth),
    .CaqDepth(8),
    .CaqTagWidth(16),
    .NumOutstandingLoads(schnizo_synth_pkg::NumIntOutstandingLoads),
    .NumOutstandingMem(schnizo_synth_pkg::NumIntOutstandingMem),
    .FPUImplementation(schnizo_synth_pkg::FpuImplementation),
    .RVF(1),
    .RVD(1),
    .XF16(0),
    .XF16ALT(0),
    .XF8(0),
    .XF8ALT(0),
    .XFVEC(0),
    .RegisterFPUIn(0),
    .RegisterFPUOut(0),
    .producer_id_t(actual_producer_id_t),
    .result_slot_id_t(actual_slot_id_t),
    .rs_id_t(actual_rs_id_t),
    .operand_id_t(schnizo_synth_pkg::operand_id_t),
    .disp_req_t(actual_disp_req_t),
    .disp_rsp_t(actual_disp_rsp_t),
    .fu_data_t(schnizo_synth_pkg::fu_data_t),
    .instr_tag_t(schnizo_pkg::instr_tag_t),
    .alu_result_t(schnizo_synth_pkg::alu_result_t),
    .alu_res_val_t(schnizo_synth_pkg::alu_res_val_t),
    .alu_lsu_result_t(schnizo_synth_pkg::alu_lsu_result_t),
    .dreq_t(schnizo_synth_pkg::data_req_t),
    .drsp_t(schnizo_synth_pkg::data_rsp_t)
  ) i_fu_stage (
    .clk_i,
    .rst_i(!rst_ni),
    .hard_id_i('0),
    .restart_i,
    .loop_state_i,
    .lep_iterations_i,
    .goto_lcp2_i,
    .all_rs_finish_o,
    .disp_req_i        (disp_req_casted),
    .instr_exec_commit_i,
    .fpu_instr_exec_commit_i(instr_exec_commit_i),
    .alu_disp_reqs_valid_i,
    .alu_disp_reqs_ready_o,
    .alu_disp_rsp_o    (alu_disp_rsp_internal),
    .alu_rs_full_o,
    .lsu_disp_reqs_valid_i,
    .lsu_disp_reqs_ready_o,
    .lsu_disp_rsp_o    (lsu_disp_rsp_internal),
    .lsu_empty_o,
    .lsu_addr_misaligned_o,
    .lsu_dreq_o,
    .lsu_drsp_i,
    .lsu_rs_full_o,
    .caq_addr_i('0),
    .caq_track_write_i('0),
    .caq_req_valid_i('0),
    .caq_req_ready_o(),
    .caq_rsp_valid_i('0),
    .caq_rsp_valid_o(),
    .alu_lsu_disp_reqs_valid_i,
    .alu_lsu_disp_reqs_ready_o,
    .alu_lsu_disp_rsp_o(alu_lsu_disp_rsp_internal),
    .alu_lsu_rs_full_o,
    .alu_lsu_dreq_o,
    .alu_lsu_drsp_i,
    .fpu_disp_reqs_valid_i,
    .fpu_disp_reqs_ready_o,
    .fpu_disp_rsp_o    (fpu_disp_rsp_internal),
    .fpu_rs_full_o,
    .fpu_status_o,
    .fpu_status_valid_o,
    .alu_wb_result_o,
    .alu_wb_result_tag_o,
    .alu_wb_result_valid_o,
    .alu_wb_result_ready_i,
    .branch_result_o,
    .lsu_wb_result_o,
    .lsu_wb_result_tag_o,
    .lsu_wb_result_valid_o,
    .lsu_wb_result_ready_i,
    .alu_lsu_wb_results_o,
    .alu_lsu_wb_result_tags_o,
    .alu_lsu_wb_results_valid_o,
    .alu_lsu_wb_results_ready_i,
    .fpu_wb_result_o,
    .fpu_wb_result_tag_o,
    .fpu_wb_result_valid_o,
    .fpu_wb_result_ready_i
  );

endmodule
