// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"

// The reservation station dispatcher module.
//
// Accesses the RMT to augment the dispatch requests with the relevant data and routes the
// dispatch requests to the different functional units. It selects the FU type based on the
// decoded instruction. If more than one FU of the same type is available, it further selects the
// specific FU of that type to dispatch the instruction to.
module schnova_rs_dispatcher import schnova_pkg::*; #(
  /// If a freelist based physical register reclamation strategy is used
  /// or a refernce counting based strategy.
  parameter bit UseFreeList = 1,
  parameter int unsigned PipeWidth   = 1,
  parameter int unsigned XLEN        = 1,
  parameter int unsigned NofAlus     = 1,
  parameter int unsigned NofLsus     = 1,
  parameter int unsigned NofFpus     = 1,
  parameter int unsigned NofAluBufEntries = 32,
  parameter int unsigned NofLsuBufEntries = 32,
  parameter int unsigned NofFpuBufEntries = 32,
  parameter int unsigned RobTagWidth = 1,
  parameter type         instr_dec_t = logic,
  parameter type         instr_tag_t = logic,
  parameter type         alu_rs_disp_req_t = logic,
  parameter type         lsu_rs_disp_req_t = logic,
  parameter type         fpu_rs_disp_req_t = logic,
  parameter type         disp_rsp_t  = logic,
  parameter type         refcnt_req_t = logic,
  parameter type         reg_map_t = logic,
  parameter type         fu_data_t   = logic
) (
  input  logic         clk_i,
  input  logic         rst_i,
  input  logic         en_superscalar_i,
  // Handshake to dispatch instruction consisting of instr_dec_i and instr_fu_data_i
  input  instr_dec_t [PipeWidth-1:0] instr_dec_i,
  input  fu_data_t   [PipeWidth-1:0] instr_fu_data_i,
  input  logic [32*PipeWidth-1:0]    instr_fetch_data_i,
  input  logic                       dispatch_valid_i,
  // Asserted inf all the instructions of this fetch block have been successfully dispatched
  // in this cycle
  output logic                       dispatched_o,
  input  logic                       instr_exec_commit_i,

  input  logic [PipeWidth-1:0]         instr_valid_i,
  input  logic [PipeWidth-1:0]         instr_rename_gpr_valid_i,
  input  logic [$clog2(PipeWidth):0]   instr_rename_gpr_count_i,
  input  logic [PipeWidth-1:0]         instr_rename_fpr_valid_i,
  input  logic [$clog2(PipeWidth):0]   instr_rename_fpr_count_i,

  // From rename stage
  input  reg_map_t [PipeWidth-1:0]     reg_map_i,

  // From/to ROB
  output logic                                 first_instr_dispatched_o,
  input logic [PipeWidth-1:0][RobTagWidth-1:0] rob_idx_i,
  // Each FU has a response which must be valid at dispatch request handshake.
  // ALU
  output alu_rs_disp_req_t [NofAlus-1:0] alu_rs_disp_reqs_o,
  output logic      [NofAlus-1:0]        alu_rs_disp_req_valid_o,
  input  logic      [NofAlus-1:0]        alu_rs_disp_req_ready_i,
  input  disp_rsp_t [NofAlus-1:0]        alu_rs_disp_rsp_i,
  input  logic      [NofAlus-1:0]        alu_rs_full_i,
  // LSU
  output lsu_rs_disp_req_t [NofLsus-1:0] lsu_rs_disp_reqs_o,
  output logic      [NofLsus-1:0]        lsu_rs_disp_req_valid_o,
  input  logic      [NofLsus-1:0]        lsu_rs_disp_req_ready_i,
  input  disp_rsp_t [NofLsus-1:0]        lsu_rs_disp_rsp_i,
  input  logic      [NofLsus-1:0]        lsu_rs_full_i,
  // FPU
  output fpu_rs_disp_req_t [NofFpus-1:0] fpu_rs_disp_reqs_o,
  output logic      [NofFpus-1:0]        fpu_rs_disp_req_valid_o,
  input  logic      [NofFpus-1:0]        fpu_rs_disp_req_ready_i,
  input  disp_rsp_t [NofFpus-1:0]        fpu_rs_disp_rsp_i,
  input  logic      [NofFpus-1:0]        fpu_rs_full_i,
  // The accelerator response is routed directly to the write back.
  output logic                           disp_buffers_empty_o,
  // RS control signals
  // Asserted if the RSS are cleared synchronously.
  input  logic                           restart_i,
  // Memory consistency mode during FREP loop
  input frep_mem_cons_mode_e             frep_mem_cons_mode_i,
  input logic [NofLsus-1:0]              frep_lsu_load_en_i,
  input logic [NofLsus-1:0]              frep_lsu_store_en_i,
  // To refcount
  output refcnt_req_t [PipeWidth-1:0]    refcnt_disp_req_o
);

  localparam int unsigned NofAlusW = cf_math_pkg::idx_width(NofAlus);
  localparam int unsigned NofLsusW = cf_math_pkg::idx_width(NofLsus);
  localparam int unsigned NofFpusW = cf_math_pkg::idx_width(NofFpus);
  localparam int unsigned InstIdxW = cf_math_pkg::idx_width(PipeWidth);
  localparam bit NofAlusIsPow2 = (NofAlus > 0) && ((NofAlus & (NofAlus - 1)) == 0);
  localparam bit NofLsusIsPow2 = (NofLsus > 0) && ((NofLsus & (NofLsus - 1)) == 0);
  localparam bit NofFpusIsPow2 = (NofFpus > 0) && ((NofFpus & (NofFpus - 1)) == 0);

  // FU selection counters
  logic [NofAlusW-1:0] alu_idx;
  logic [NofAlusW-1:0] alu_idx_raw_q, alu_idx_raw_d;
  logic [NofLsusW-1:0] lsu_idx;
  logic [NofLsusW-1:0] lsu_idx_raw_q, lsu_idx_raw_d;
  logic [NofFpusW-1:0] fpu_idx;
  logic [NofFpusW-1:0] fpu_idx_raw_q, fpu_idx_raw_d;

  `FFAR(alu_idx_raw_q, alu_idx_raw_d, '0, clk_i, rst_i);
  `FFAR(lsu_idx_raw_q, lsu_idx_raw_d, '0, clk_i, rst_i);
  `FFAR(fpu_idx_raw_q, fpu_idx_raw_d, '0, clk_i, rst_i);

  alu_rs_disp_req_t [PipeWidth-1:0] alu_rs_disp_reqs;
  lsu_rs_disp_req_t [PipeWidth-1:0] lsu_rs_disp_reqs;
  fpu_rs_disp_req_t [PipeWidth-1:0] fpu_rs_disp_reqs;

  logic [PipeWidth-1:0] dispatched_q, dispatched_d;
  `FFAR(dispatched_q, dispatched_d, '0, clk_i, rst_i);

  // Rob Tag state
  logic [PipeWidth-1:0][RobTagWidth-1:0] rob_tag_d, rob_tag_q;
  logic rob_tag_saved_d, rob_tag_saved_q;
  logic [PipeWidth-1:0] instr_dispatched;

  typedef struct packed {
    alu_rs_disp_req_t disp_req;
    logic             disp_to_alu0;
  } alu_buf_t;

  typedef struct packed {
    lsu_rs_disp_req_t disp_req;
    logic             disp_to_lsu0;
    logic             is_load;
  } lsu_buf_t;
  typedef fpu_rs_disp_req_t fpu_buf_t;

  ////////////////////////
  // Request generation //
  ////////////////////////
  instr_tag_t [PipeWidth-1:0] tag;

  // The dispatch request contains
  // 1) The physical register mappings of the instruction
  // 2) If the operands are constand and therefore don't have to be fetched from
  // the physical register file
  // 3) The instruction as well as its tag

  always_comb begin : rs_dispatch_generation
    alu_rs_disp_reqs = '0;
    lsu_rs_disp_reqs = '0;
    fpu_rs_disp_reqs = '0;
    tag          = '0;
    for (int unsigned i = 0; i < PipeWidth; i++) begin
      // Instruction tag
      tag[i].dest_reg       = reg_map_i[i].phy_reg_rd_new;
      tag[i].dest_reg_is_fp = instr_dec_i[i].rd_is_fp;
      tag[i].is_branch      = instr_dec_i[i].is_branch;
      tag[i].is_jump        = instr_dec_i[i].is_jal | instr_dec_i[i].is_jalr;
      if (UseFreeList) begin
        // If we have already dispatched some instructions we have to use the rob tag we saved
        // otherwise we can just use the rob tag coming from the ROB which are contiguous ROB
        // tags starating from the current tail pointer
        tag[i].rob_tag        = (rob_tag_saved_q) ? rob_tag_q[i] : rob_idx_i[i];
      end

      // ALU
      alu_rs_disp_reqs[i].alu_op       = instr_fu_data_i[i].alu_op;
      alu_rs_disp_reqs[i].operand_a    = instr_fu_data_i[i].operand_a[XLEN-1:0]; 
      alu_rs_disp_reqs[i].operand_b    = instr_fu_data_i[i].operand_b[XLEN-1:0];
      alu_rs_disp_reqs[i].tag          = tag[i];

      alu_rs_disp_reqs[i].phy_reg_op_a = reg_map_i[i].phy_reg_rs1;
      alu_rs_disp_reqs[i].is_op_a_cnst = instr_dec_i[i].use_pc_as_op_a |
                                        instr_dec_i[i].use_rs1addr_as_op_a;
      alu_rs_disp_reqs[i].phy_reg_op_b = reg_map_i[i].phy_reg_rs2;
      alu_rs_disp_reqs[i].is_op_b_cnst = (instr_dec_i[i].fu == schnova_pkg::ALU ||
                                        instr_dec_i[i].fu == schnova_pkg::CTRL_FLOW) &&
                                        instr_dec_i[i].use_imm_as_op_b &&
                                        !instr_dec_i[i].is_branch;

      // LSU
      lsu_rs_disp_reqs[i].lsu_op    = instr_fu_data_i[i].lsu_op;
      lsu_rs_disp_reqs[i].imm       = instr_fu_data_i[i].imm[XLEN-1:0];
      lsu_rs_disp_reqs[i].lsu_size  = instr_fu_data_i[i].lsu_size;
      lsu_rs_disp_reqs[i].tag       = tag[i];

      lsu_rs_disp_reqs[i].phy_reg_op_a = reg_map_i[i].phy_reg_rs1;
      lsu_rs_disp_reqs[i].phy_reg_op_b = reg_map_i[i].phy_reg_rs2;
      lsu_rs_disp_reqs[i].is_op_b_fp   = instr_dec_i[i].rs2_is_fp;

      // FPU
      fpu_rs_disp_reqs[i].fpu_op       = instr_fu_data_i[i].fpu_op;
      fpu_rs_disp_reqs[i].imm          = instr_fu_data_i[i].imm;
      fpu_rs_disp_reqs[i].fpu_fmt_src  = instr_fu_data_i[i].fpu_fmt_src;
      fpu_rs_disp_reqs[i].fpu_fmt_dst  = instr_fu_data_i[i].fpu_fmt_dst;
      fpu_rs_disp_reqs[i].fpu_rnd_mode = instr_fu_data_i[i].fpu_rnd_mode;
      fpu_rs_disp_reqs[i].tag          = tag[i];

      fpu_rs_disp_reqs[i].phy_reg_op_a = reg_map_i[i].phy_reg_rs1;
      fpu_rs_disp_reqs[i].is_op_a_fp   = instr_dec_i[i].rs1_is_fp;
      fpu_rs_disp_reqs[i].phy_reg_op_b = reg_map_i[i].phy_reg_rs2;
      fpu_rs_disp_reqs[i].phy_reg_op_c = reg_map_i[i].phy_reg_rs3;
      fpu_rs_disp_reqs[i].is_op_c_cnst = ~instr_dec_i[i].use_imm_as_rs3;
    end
  end

  // 1) FU selection

  // For every instruction in the pipe, determine which FU type with an RS it needs

  logic [PipeWidth-1:0] disp_to_alu;
  logic [PipeWidth-1:0] disp_to_alu0;
  logic [PipeWidth-1:0] disp_to_lsu;
  logic [PipeWidth-1:0] disp_to_fpu;

  always_comb begin: identify_fu_type
    disp_to_alu0 = '0;
    disp_to_alu  = '0;
    disp_to_lsu  = '0;
    disp_to_fpu  = '0;

    for (int unsigned i = 0; i < PipeWidth; i++) begin
      disp_to_alu0[i] = ((instr_dec_i[i].fu == schnova_pkg::MUL)       |
                        (instr_dec_i[i].fu == schnova_pkg::CTRL_FLOW)) &
                        instr_valid_i[i]                               &
                        !dispatched_q[i]                               &
                        dispatch_valid_i;
      disp_to_alu[i] = (instr_dec_i[i].fu == schnova_pkg::ALU) &
                        instr_valid_i[i]                       &
                        !dispatched_q[i]                       &
                        dispatch_valid_i;
      disp_to_lsu[i] =  ((instr_dec_i[i].fu == schnova_pkg::LOAD)  |
                        (instr_dec_i[i].fu == schnova_pkg::STORE)) &
                        instr_valid_i[i]                           &
                        !dispatched_q[i]                           &
                        dispatch_valid_i;
      disp_to_fpu[i] = (instr_dec_i[i].fu == schnova_pkg::FPU) &
                        instr_valid_i[i]                       &
                        !dispatched_q[i]                       &
                        dispatch_valid_i;
    end
  end

  // 2) Hazard detection

  // Each instruction must dispatch in order in respect to the same functional unit type
  // This works without deadlock since before the dispatch request is valid the physical registers
  // and rob entries (if used) already are allocated.

  logic [PipeWidth-1:0]                  instr_has_hazard;
  logic [PipeWidth-1:0][InstIdxW-1:0]    alu_push_idx;
  logic [PipeWidth-1:0][InstIdxW-1:0]    lsu_push_idx;
  logic [PipeWidth-1:0][InstIdxW-1:0]    fpu_push_idx;

  logic                                  alu_disp_buf_push;
  logic     [$clog2(PipeWidth):0]        alu_disp_buf_push_count;
  alu_buf_t [PipeWidth-1:0]              alu_disp_buf_push_data;
  logic     [$clog2(NofAluBufEntries):0] alu_buf_free_count;
  logic                                  alu_disp_buf_pop;
  logic     [$clog2(NofAlus):0]          alu_disp_pop_count;
  alu_buf_t [NofAlus-1:0]                alu_disp_buf_pop_data;
  logic     [NofAlus-1:0]                alu_disp_buf_pop_data_valid;

  logic                                  lsu_disp_buf_push;
  logic     [$clog2(PipeWidth):0]        lsu_disp_buf_push_count;
  lsu_buf_t [PipeWidth-1:0]              lsu_disp_buf_push_data;
  logic     [$clog2(NofLsuBufEntries):0] lsu_buf_free_count;
  logic                                  lsu_disp_buf_pop;
  logic     [$clog2(NofLsus):0]          lsu_disp_pop_count;
  lsu_buf_t [NofLsus-1:0]                lsu_disp_buf_pop_data;
  logic     [NofLsus-1:0]                lsu_disp_buf_pop_data_valid;

  logic                                  fpu_disp_buf_push;
  logic     [$clog2(PipeWidth):0]        fpu_disp_buf_push_count;
  fpu_buf_t [PipeWidth-1:0]              fpu_disp_buf_push_data;
  logic     [$clog2(NofFpuBufEntries):0] fpu_buf_free_count;
  logic                                  fpu_disp_buf_pop;
  logic     [$clog2(NofFpus):0]          fpu_disp_pop_count;
  fpu_buf_t [NofFpus-1:0]                fpu_disp_buf_pop_data;
  logic     [NofFpus-1:0]                fpu_disp_buf_pop_data_valid;

  always_comb begin : hazard_detection
    // Per default no port is claimed and no instruciton has an hazard
    instr_has_hazard = '0;
    alu_disp_buf_push_count = '0;
    lsu_disp_buf_push_count = '0;
    fpu_disp_buf_push_count = '0;
    alu_push_idx = '0;
    lsu_push_idx = '0;
    fpu_push_idx = '0;

    for (int unsigned i = 0; i < PipeWidth; i++) begin
      if (disp_to_alu[i] || disp_to_alu0[i]) begin
        if (alu_disp_buf_push_count < alu_buf_free_count) begin
          // ALU dispatch buffer has enough space
          alu_push_idx[i] = alu_disp_buf_push_count[InstIdxW-1:0];
          alu_disp_buf_push_count = alu_disp_buf_push_count + 1'b1;
        end else begin
          // ALU dispatcher does not have enough space
          instr_has_hazard[i] = 1'b1;
        end
      end
      if (disp_to_lsu[i]) begin
        if (lsu_disp_buf_push_count < lsu_buf_free_count) begin
          // LSU dispatch buffer has enough space
          lsu_push_idx[i] = lsu_disp_buf_push_count[InstIdxW-1:0];
          lsu_disp_buf_push_count = lsu_disp_buf_push_count + 1'b1;
        end else begin
          // LSU dispatcher does not have enough space
          instr_has_hazard[i] = 1'b1;
        end
      end
      if (disp_to_fpu[i]) begin
        if (fpu_disp_buf_push_count < fpu_buf_free_count) begin
          // LSU dispatch buffer has enough space
          fpu_push_idx[i] = fpu_disp_buf_push_count[InstIdxW-1:0];
          fpu_disp_buf_push_count = fpu_disp_buf_push_count + 1'b1;
        end else begin
          // LSU dispatcher does not have enough space
          instr_has_hazard[i] = 1'b1;
        end
      end
    end
  end

  // Dispatch tracking
  always_comb begin
    instr_dispatched = '0;
    dispatched_d = dispatched_q;

    for (int unsigned i = 0; i < PipeWidth; i++) begin
      // An instruction is dispatched to the dispatch buffer
      // in this cycle if it does not have a hazard
      instr_dispatched[i] = (!instr_has_hazard[i] & instr_exec_commit_i) | dispatched_q[i];
    end

    if (dispatched_o || restart_i) begin
      // If we dispatched all the instructions in this cycle we have to reset the state
      dispatched_d = '0;
    end else begin
      // We update the dispatched state for the instructions that are being dispatched in this cycle
      dispatched_d = instr_dispatched;
    end
  end

  // 3) Dispatch Buffer Management
  always_comb begin
    alu_disp_buf_push_data = '0;
    lsu_disp_buf_push_data = '0;
    fpu_disp_buf_push_data = '0;

    for (int unsigned i = 0; i < PipeWidth; i++) begin
      // Only pack the data if it can be disaptched into the buffer this cycle
      if ((disp_to_alu[i] || disp_to_alu0[i]) && !instr_has_hazard[i]) begin
        alu_disp_buf_push_data[alu_push_idx[i]] = '{
                                                    disp_req: alu_rs_disp_reqs[i],
                                                    disp_to_alu0: disp_to_alu0[i]
                                                  };
      end
      if (disp_to_lsu[i] && !instr_has_hazard[i]) begin
        lsu_disp_buf_push_data[lsu_push_idx[i]] = '{
                                                    disp_req: lsu_rs_disp_reqs[i],
                                                    disp_to_lsu0: (frep_mem_cons_mode_i == FrepMemSerialized) ? 1'b1 : 1'b0,
                                                    is_load: instr_dec_i[i].fu == schnova_pkg::LOAD
                                                  };
      end
      if (disp_to_fpu[i] && !instr_has_hazard[i]) begin
        fpu_disp_buf_push_data[fpu_push_idx[i]] = fpu_rs_disp_reqs[i];
      end
    end

    // We push if we have valid instructions queued
    alu_disp_buf_push = en_superscalar_i ? (alu_disp_buf_push_count > 0) && instr_exec_commit_i : 1'b0;
    lsu_disp_buf_push = en_superscalar_i ? (lsu_disp_buf_push_count > 0) && instr_exec_commit_i : 1'b0;
    fpu_disp_buf_push = en_superscalar_i ? (fpu_disp_buf_push_count > 0) && instr_exec_commit_i : 1'b0;
  end

  logic alu_disp_buf_empty;
  logic lsu_disp_buf_empty;
  logic fpu_disp_buf_empty;

  schnova_disp_buffer #(
    .PipeWidth (PipeWidth),
    .NumEntries(NofAluBufEntries),
    .NumFus    (NofAlus),
    .data_t    (alu_buf_t)
  ) alu_disp_buffer (
    .clk_i,
    .rst_i,
    // Allocation Interface
    .push_i      (alu_disp_buf_push),
    .push_count_i(alu_disp_buf_push_count),
    .disp_data_i (alu_disp_buf_push_data),
    .free_count_o(alu_buf_free_count),
    // Deallocation Interface
    .pop_i       (alu_disp_buf_pop),
    .pop_count_i (alu_disp_pop_count),
    .disp_data_o (alu_disp_buf_pop_data),
    .disp_valid_o(alu_disp_buf_pop_data_valid),
    .empty_o     (alu_disp_buf_empty)
  );

  schnova_disp_buffer #(
    .PipeWidth (PipeWidth),
    .NumEntries(NofLsuBufEntries),
    .NumFus    (NofLsus),
    .data_t    (lsu_buf_t)
  ) lsu_disp_buffer (
    .clk_i,
    .rst_i,
    // Allocation Interface
    .push_i      (lsu_disp_buf_push),
    .push_count_i(lsu_disp_buf_push_count),
    .disp_data_i (lsu_disp_buf_push_data),
    .free_count_o(lsu_buf_free_count),
    // Deallocation Interface
    .pop_i       (lsu_disp_buf_pop),
    .pop_count_i (lsu_disp_pop_count),
    .disp_data_o (lsu_disp_buf_pop_data),
    .disp_valid_o(lsu_disp_buf_pop_data_valid),
    .empty_o     (lsu_disp_buf_empty)
  );

  schnova_disp_buffer #(
    .PipeWidth (PipeWidth),
    .NumEntries(NofFpuBufEntries),
    .NumFus    (NofFpus),
    .data_t    (fpu_buf_t)
  ) fpu_disp_buffer (
    .clk_i,
    .rst_i,
    // Allocation Interface
    .push_i      (fpu_disp_buf_push),
    .push_count_i(fpu_disp_buf_push_count),
    .disp_data_i (fpu_disp_buf_push_data),
    .free_count_o(fpu_buf_free_count),
    // Deallocation Interface
    .pop_i       (fpu_disp_buf_pop),
    .pop_count_i (fpu_disp_pop_count),
    .disp_data_o (fpu_disp_buf_pop_data),
    .disp_valid_o(fpu_disp_buf_pop_data_valid),
    .empty_o     (fpu_disp_buf_empty)
  );

  assign disp_buffers_empty_o = (alu_disp_buf_empty & lsu_disp_buf_empty & fpu_disp_buf_empty);

  logic [NofAlus-1:0]               alu_assigned;       // Whether this dispatch req was assigned an rs
  logic [NofAlus-1:0][NofAlusW-1:0] alu_port;           // The assigned alu port
  logic [NofAlus-1:0]               alu_claimed;        // Whether this rs was already claimed
  logic                             alu_older_stalled;  // Cascade flag for strict in-order blocking
  logic [NofAlusW-1:0]              alu_rot_idx;

  always_comb begin : alu_buffer_pop_steering
    alu_rs_disp_reqs_o      = '0;
    alu_rs_disp_req_valid_o = '0;
    alu_assigned            = '0;
    alu_claimed             = '0;
    alu_port                = '0;
    alu_disp_pop_count      = '0;
    alu_older_stalled       = 1'b0;
    alu_rot_idx             = '0;

    for (int unsigned i = 0; i < NofAlus; i++) begin
      if (alu_disp_buf_pop_data_valid[i] && !alu_older_stalled) begin
        // Restricted to dispatch to ALU 0
        if (alu_disp_buf_pop_data[i].disp_to_alu0) begin
          alu_rot_idx = NofAlusW'(0);
        end else begin
          // Otherwise strict deterministic round-robin slot mapping
          if (NofAlusIsPow2) begin
            alu_rot_idx = alu_idx + NofAlusW'(i);
          end else begin
            alu_rot_idx = ((alu_idx + NofAlusW'(i)) >= NofAlus) ? (alu_idx + NofAlusW'(i)) - NofAlus
                                                                : (alu_idx + NofAlusW'(i));
          end
        end
        // Check availability of the RS pointed to by the idx
        if (alu_rs_disp_req_ready_i[alu_rot_idx] && !alu_claimed[alu_rot_idx]) begin
          alu_assigned[i] = 1'b1;
          alu_claimed[alu_rot_idx]  = 1'b1;
          alu_port[i]     = alu_rot_idx; 
        end

        if (alu_assigned[i]) begin
          alu_rs_disp_reqs_o[alu_port[i]]      = alu_disp_buf_pop_data[i].disp_req;
          // pragma translate_off
          alu_rs_disp_reqs_o[alu_port[i]].tag.producer_id = alu_rs_disp_rsp_i[alu_port[i]].producer;
          // pragma translate_on
          alu_rs_disp_req_valid_o[alu_port[i]] = 1'b1;
          alu_disp_pop_count                   = i + 1;
        end else begin
          alu_older_stalled = 1'b1;
        end
      end
    end

    alu_disp_buf_pop = (alu_disp_pop_count > 0);
  end

  logic [NofLsus-1:0]               lsu_assigned;       // Whether this dispatch req was assigned an rs
  logic [NofLsus-1:0][NofLsusW-1:0] lsu_port;           // The assigned lsu port
  logic [NofLsus-1:0]               lsu_claimed;        // Whether this rs was already claimed
  // Whether this dispatch request matches the type of instructions that this LSU is
  // configured for.
  logic [NofLsus-1:0][NofLsus-1:0]  lsu_match_matrix;  // [instruction_idx][lsu_idx]       
  logic                             lsu_older_stalled;  // Cascade flag for strict in-order blocking
  logic [NofLsusW-1:0]              lsu_rot_idx;

  // Precalcualte t he LSU match matrix
  always_comb begin: lsu_match_matrix_gen
    lsu_match_matrix = '0;
    for (int unsigned i = 0; i < NofLsus; i++) begin
      for (int unsigned j = 0; j < NofLsus; j++) begin
        lsu_match_matrix[i][j] = (lsu_disp_buf_pop_data[i].is_load  && frep_lsu_load_en_i[j]) ||
                                 (!lsu_disp_buf_pop_data[i].is_load && frep_lsu_store_en_i[j]);
      end
    end
  end

  always_comb begin : lsu_buffer_pop_steering
    lsu_rs_disp_reqs_o      = '0;
    lsu_rs_disp_req_valid_o = '0;
    lsu_assigned            = '0;
    lsu_claimed             = '0;
    lsu_port                = '0;
    lsu_disp_pop_count      = '0;
    lsu_older_stalled       = 1'b0;
    lsu_rot_idx             = '0;

    for (int unsigned i = 0; i < NofLsus; i++) begin
      if (lsu_disp_buf_pop_data_valid[i] && !lsu_older_stalled) begin
        if (lsu_disp_buf_pop_data[i].disp_to_lsu0) begin
          // Instructions restricted to LSU0 must dispatch to LSU0
          if (lsu_rs_disp_req_ready_i[0] && !lsu_claimed[0]) begin
              lsu_assigned[i] = 1'b1;
              lsu_claimed[0]  = 1'b1;
              lsu_port[i]     = NofLsusW'(0);
          end 
        end else begin
          // General LSU dispatching to any LSU that is configured to handle this type of 
          // instruction
          for (int unsigned j = 0; j < NofLsus; j++) begin
            if (!lsu_assigned[i]) begin
              if (NofLsusIsPow2) begin
                lsu_rot_idx = lsu_idx + NofLsusW'(j);
              end else begin
                lsu_rot_idx = ((lsu_idx + NofLsusW'(j)) >= NofLsus) ? (lsu_idx + NofLsusW'(j)) - NofLsus
                                                                    : (lsu_idx + NofLsusW'(j));
              end
              if (lsu_rs_disp_req_ready_i[lsu_rot_idx] && !lsu_claimed[lsu_rot_idx] && lsu_match_matrix[i][lsu_rot_idx]) begin
                lsu_assigned[i]          = 1'b1;
                lsu_claimed[lsu_rot_idx] = 1'b1;
                lsu_port[i]              = lsu_rot_idx;
              end
            end
          end
        end

        if (lsu_assigned[i]) begin
          lsu_rs_disp_reqs_o[lsu_port[i]]      = lsu_disp_buf_pop_data[i].disp_req;
          // pragma translate_off
          lsu_rs_disp_reqs_o[lsu_port[i]].tag.producer_id = lsu_rs_disp_rsp_i[lsu_port[i]].producer;
          // pragma translate_on
          lsu_rs_disp_req_valid_o[lsu_port[i]] = 1'b1;
          lsu_disp_pop_count                   = i + 1;
        end else begin
          lsu_older_stalled = 1'b1;
        end
      end
    end

    lsu_disp_buf_pop = (lsu_disp_pop_count > 0);
  end

  logic [NofFpus-1:0]               fpu_assigned;       // Whether this dispatch req was assigned an rs
  logic [NofFpus-1:0][NofFpusW-1:0] fpu_port;           // The assigned fpu port
  logic [NofFpus-1:0]               fpu_claimed;        // Whether this rs was already claimed
  logic                             fpu_older_stalled;  // Cascade flag for strict in-order blocking
  logic [NofFpusW-1:0]              fpu_rot_idx;

  always_comb begin : fpu_buffer_pop_steering
    fpu_rs_disp_reqs_o      = '0;
    fpu_rs_disp_req_valid_o = '0;
    fpu_assigned            = '0;
    fpu_claimed             = '0;
    fpu_port                = '0;
    fpu_disp_pop_count      = '0;
    fpu_older_stalled       = 1'b0;
    fpu_rot_idx             = '0;

    for (int unsigned i = 0; i < NofFpus; i++) begin
      if (fpu_disp_buf_pop_data_valid[i] && !fpu_older_stalled) begin
        // Strict deterministic round-robin slot mapping
        if (NofFpusIsPow2) begin
            fpu_rot_idx = fpu_idx + NofFpusW'(i);
          end else begin
            fpu_rot_idx = ((fpu_idx + NofFpusW'(i)) >= NofFpus) ? (fpu_idx + NofFpusW'(i)) - NofFpus
                                                                : (fpu_idx + NofFpusW'(i));
        end
        // Check availability of only the strictly designated port
        if (fpu_rs_disp_req_ready_i[fpu_rot_idx] && !fpu_claimed[fpu_rot_idx]) begin
          fpu_assigned[i]          = 1'b1;
          fpu_claimed[fpu_rot_idx] = 1'b1;
          fpu_port[i]              = fpu_rot_idx;
        end
        if (fpu_assigned[i]) begin
          fpu_rs_disp_reqs_o[fpu_port[i]]      = fpu_disp_buf_pop_data[i];
          // pragma translate_off
          fpu_rs_disp_reqs_o[fpu_port[i]].tag.producer_id = fpu_rs_disp_rsp_i[fpu_port[i]].producer;
          // pragma translate_on
          fpu_rs_disp_req_valid_o[fpu_port[i]] = 1'b1;
          fpu_disp_pop_count                   = i + 1;
        end else begin
          fpu_older_stalled = 1'b1;
        end
      end
    end

    fpu_disp_buf_pop = (fpu_disp_pop_count > 0);
  end


  logic [NofAlus-1:0] alu0_forced;
  logic [NofAlus-1:0] rr_assigned;
  logic [$clog2(NofAlus):0] alu_idx_inc;
  logic [$clog2(NofLsus):0] lsu_idx_inc_raw;
  logic [$clog2(NofLsus):0] lsu_idx_inc;
  logic [$clog2(NofFpus):0] fpu_idx_inc;


  always_comb begin
    // For the ALU it can be that some instructions are forced to ALU0, these we ignore for the round-robin
    // counter update
    for (int unsigned i = 0; i < NofAlus; i++) begin
      alu0_forced[i] = alu_disp_buf_pop_data[i].disp_to_alu0;
    end

    rr_assigned = alu_assigned & ~alu0_forced;
    alu_idx_inc = '0;
    // Calcualte the the increment with by counting the number of set bits
    for (int unsigned i = 0; i < NofAlus; i++) begin
      alu_idx_inc += rr_assigned[i];
    end
  end
  
  // FPU the increment is always equal to the pop count
  assign fpu_idx_inc = fpu_disp_pop_count;

  // For the LSU it can be that we are in the serialized mode then we don't have to increment
  // Since we anyway only dispatch to LSU0
  assign lsu_idx_inc_raw = lsu_disp_pop_count;
  assign lsu_idx_inc = (frep_mem_cons_mode_i inside {FrepMemSerialized}) ? '0 : lsu_idx_inc_raw;

  // ---------------------------
  // FU selection counters
  // ---------------------------
  assign alu_idx = (NofAlus > 1) ? alu_idx_raw_q : '0;
  assign lsu_idx = (NofLsus > 1) ? lsu_idx_raw_q : '0;
  assign fpu_idx = (NofFpus > 1) ? fpu_idx_raw_q : '0;

  // ALU counter
  if (NofAlusIsPow2) begin : gen_alu_idx_pow2
    // If the number of FUs is a power of 2, the wrap around happens naturally
    always_comb begin: alu_idx_calculation
      if (restart_i) begin
        alu_idx_raw_d = '0;
      end else if (alu_disp_buf_pop) begin
        alu_idx_raw_d = alu_idx_raw_q + alu_idx_inc;
      end else begin
        alu_idx_raw_d = alu_idx_raw_q;
      end
    end
  end else begin : gen_alu_idx
    // In this case we use a single-substraction to calculate the wrap around
    // Use slightly wider counters to catch overflows before the wrap around
    logic [NofAlusW:0] alu_idx_sum;
    always_comb begin: alu_idx_calculation
      alu_idx_sum = alu_idx_raw_q + alu_idx_inc;
      if (restart_i) begin
        alu_idx_raw_d = '0;
      end else if (alu_disp_buf_pop) begin
        alu_idx_raw_d = (alu_idx_sum >= NofAlus)  ? alu_idx_sum - NofAlus
                                                  : alu_idx_sum[NofAlusW-1:0];
      end else begin
        alu_idx_raw_d = alu_idx_raw_q;
      end
    end
  end

  // LSU counter
  if (NofLsusIsPow2) begin : gen_lsu_idx_pow2
    // If the number of FUs is a power of 2, the wrap around happens naturally
    always_comb begin: lsu_idx_calculation
      if (restart_i) begin
        lsu_idx_raw_d = '0;
      end else if (lsu_disp_buf_pop) begin
        lsu_idx_raw_d = lsu_idx_raw_q + lsu_idx_inc;
      end else begin
        lsu_idx_raw_d = lsu_idx_raw_q;
      end
    end
  end else begin : gen_lsu_idx
    // In this case we use a single-substraction to calculate the wrap around
    // Use slightly wider counters to catch overflows before the wrap around
    logic [NofLsusW:0] lsu_idx_sum;
    always_comb begin: lsu_idx_calculation
      lsu_idx_sum = lsu_idx_raw_q + lsu_idx_inc;
      if (restart_i) begin
        lsu_idx_raw_d = '0;
      end else if (lsu_disp_buf_pop) begin
        lsu_idx_raw_d = (lsu_idx_sum >= NofLsus)  ? lsu_idx_sum - NofLsus
                                                  : lsu_idx_sum[NofLsusW-1:0];
      end else begin
        lsu_idx_raw_d = lsu_idx_raw_q;
      end
    end
  end

  // FPU counter
  if (NofFpusIsPow2) begin : gen_fpu_idx_pow2
    // If the number of FUs is a power of 2, the wrap around happens naturally
    always_comb begin: fpu_idx_calculation
      if (restart_i) begin
        fpu_idx_raw_d = '0;
      end else if (fpu_disp_buf_pop) begin
        fpu_idx_raw_d = fpu_idx_raw_q + fpu_idx_inc;
      end else begin
        fpu_idx_raw_d = fpu_idx_raw_q;
      end
    end
  end else begin : gen_fpu_idx
    // In this case we use a single-substraction to calculate the wrap around
    // Use slightly wider counters to catch overflows before the wrap around
    logic [NofFpusW:0] fpu_idx_sum;
    always_comb begin: fpu_idx_calculation
      fpu_idx_sum = fpu_idx_raw_q + fpu_idx_inc;
      if (restart_i) begin
        fpu_idx_raw_d = '0;
      end else if (fpu_disp_buf_pop) begin
        fpu_idx_raw_d = (fpu_idx_sum >= NofFpus)  ? fpu_idx_sum - NofFpus
                                                  : fpu_idx_sum[NofFpusW-1:0];
      end else begin
        fpu_idx_raw_d = fpu_idx_raw_q;
      end
    end
  end

  ///////////////////////////////////////
  // Reorder buffer tag state update   //
  // and scorebored signal handling    //
  ///////////////////////////////////////

  // Tracks if any valid instruction has *already* been dispatched in a previous cycle
  logic valid_already_dispatched;
  assign valid_already_dispatched = |(dispatched_q & instr_valid_i);

  // Fires exactly on the cycle where the first valid instruction(s) transition to dispatched
  assign first_instr_dispatched_o = |(instr_dispatched & instr_valid_i) & !valid_already_dispatched;

  // Only need to send the rob tag in case we do free list based reclamation
  if (UseFreeList) begin : gen_rob_tag
    // Only needed for the refcounter based implementation.
    assign refcnt_disp_req_o = '0;
    // Delacre the tag FF
    `FFAR(rob_tag_q, rob_tag_d, '0, clk_i, rst_i);
    `FFAR(rob_tag_saved_q, rob_tag_saved_d, 1'b0, clk_i, rst_i);
    // We have to remember the first ROB tags because of partial dispatch
    always_comb begin
      rob_tag_d = rob_tag_q;
      rob_tag_saved_d = rob_tag_saved_q;
      // Remember the rob tags the next cycle we pushed these into the ROB
      if (first_instr_dispatched_o & en_superscalar_i) begin
        rob_tag_d = rob_idx_i;
        rob_tag_saved_d = 1'b1;
      end
      if (dispatched_o) begin
        rob_tag_saved_d = 1'b0;
      end
      if (restart_i) begin
        rob_tag_d = '0;
        rob_tag_saved_d = 1'b0;
      end
    end
  end else begin: gen_refcnt_set_req
    always_comb begin
      rob_tag_q = '0;
      rob_tag_d = '0;
      refcnt_disp_req_o = '0;
      for (int unsigned i = 0; i < PipeWidth; i++) begin
        refcnt_disp_req_o[i].phy_reg_op_a = reg_map_i[i].phy_reg_rs1;
        refcnt_disp_req_o[i].is_op_a_cnst = instr_dec_i[i].use_pc_as_op_a |
                                            instr_dec_i[i].use_rs1addr_as_op_a;;
        refcnt_disp_req_o[i].is_op_a_fp   = instr_dec_i[i].rs1_is_fp;
        refcnt_disp_req_o[i].phy_reg_op_b = reg_map_i[i].phy_reg_rs2;
        refcnt_disp_req_o[i].is_op_b_cnst = (instr_dec_i[i].fu == schnova_pkg::ALU ||
                                            instr_dec_i[i].fu == schnova_pkg::CTRL_FLOW) &&
                                            instr_dec_i[i].use_imm_as_op_b &&
                                            !instr_dec_i[i].is_branch;
        refcnt_disp_req_o[i].is_op_b_fp   = instr_dec_i[i].rs2_is_fp;
        refcnt_disp_req_o[i].phy_reg_op_c = reg_map_i[i].phy_reg_rs3;
        refcnt_disp_req_o[i].is_op_c_cnst = ~instr_dec_i[i].use_imm_as_rs3;
      end
    end
  end

  // All instructions are successfully dispatched if all the instructions are being dispatched in this cycle
  // that are valid in the first place
  assign dispatched_o = (|instr_valid_i) & (&instr_dispatched);

endmodule
