// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Combines initial slot update, operand request generation, operand response handling,
// and issue logic into a single module.
module schnova_rss_dispatch_pipeline import schnova_pkg::*; #(
  parameter bit          UseFreeList      = 1'b1,
  parameter int unsigned NofOperands      = 2,
  parameter int unsigned NofConsts        = 3,
  parameter rs_type_e    RsType           = 0,
  parameter type         disp_req_t       = logic,
  parameter type         producer_id_t    = logic,
  parameter type         rs_slot_issue_t  = logic,
  parameter type         rss_operand_t    = logic,
  parameter type         rss_const_t      = logic,
  parameter type         operand_req_t    = logic,
  parameter type         operand_t        = logic,
  parameter type         rss_idx_t        = logic,
  parameter type         issue_req_t      = logic,
  parameter type         refcnt_req_t     = logic
) (
  // Control
  input  producer_id_t    disp_producer_id_i,
  input  producer_id_t    issue_producer_id_i,
  input  rss_idx_t        disp_idx_i,
  input  rss_idx_t        issue_idx_i,
  input  disp_req_t       disp_req_i,
  input  logic            disp_req_valid_i,
  output logic            disp_req_ready_o,
  input  logic            rs_full_i,
  output logic            disp_hs_o,
  input  rs_slot_issue_t  slot_issue_i,
  output rs_slot_issue_t  slot_disp_o,

  // Operand request
  output operand_req_t [NofOperands-1:0] op_reqs_o,

  // Operand response
  input  operand_t     [NofOperands-1:0] op_rsps_i,
  input  logic         [NofOperands-1:0] op_rsps_valid_i,

  // Issue reference counting interface
  output logic         issue_clr_req_valid_o,
  output refcnt_req_t  issue_clr_req_o,

  // Issue
  input  logic         issue_req_ready_i,
  output issue_req_t   issue_req_o,
  output logic         issue_req_valid_o,
  output logic         issue_hs_o
);

  /////////////////////////
  // Initial slot update //
  /////////////////////////

  // The initial operand values when accepting a new instruction
  rss_operand_t op_a_init;
  rss_operand_t op_b_init;
  rss_operand_t op_c_init;

  assign op_a_init = '{
    phy_reg_src:          disp_req_i.phy_reg_op_a,
    is_fp:                disp_req_i.is_op_a_fp,
    is_valid:             disp_req_i.is_op_a_valid
  };

  assign op_b_init = '{
    phy_reg_src:          disp_req_i.phy_reg_op_b,
    is_fp:                disp_req_i.is_op_b_fp,
    is_valid:             disp_req_i.is_op_b_valid
  };

  assign op_c_init = '{
    phy_reg_src:          disp_req_i.phy_reg_op_c,
    // If op c needs to be fetched from a physical register file
    // it will always be from the floating point physical register file
    is_fp:                1'b1,
    is_valid:             disp_req_i.is_op_c_valid
  };

  rss_const_t [NofConsts-1:0] const_init;

  if (NofConsts > 1) begin: gen_alu_const_init
    assign const_init[0] = '{
      value: disp_req_i.fu_data.operand_a,
      // There is a valid constant if the operand is valid
      // at dispatch
      is_valid: disp_req_i.is_op_a_valid
    };
    assign const_init[1] = '{
      value: disp_req_i.fu_data.operand_b,
      // There is a valid constant if the operand is valid
      // at dispatch
      is_valid: disp_req_i.is_op_b_valid
    };
  end else begin: gen_const_init
    assign const_init[0] = '{
      value: disp_req_i.fu_data.imm,
      // There is a valid constant if the operand is valid
      // at dispatch
      is_valid: disp_req_i.is_op_c_valid
    };
  end

  // Array to simplify initial operand assignment
  rss_operand_t [2:0] ops_init;
  assign ops_init[0] = op_a_init;
  assign ops_init[1] = op_b_init;
  assign ops_init[2] = op_c_init;

  // Initial value of the slot upon accepting a new instruction
  rs_slot_issue_t slot_init;
  generate
    if (RsType == ALU_RS) begin: gen_alu_slot_init
      always_comb begin
        slot_init = '{
          is_occupied:      1'b1,
          alu_op:           disp_req_i.fu_data.alu_op,
          tag:              disp_req_i.tag,
          constants:        '0,
          operands:         '0
        };

        // Constants must be assigned depending on the number we have
        for (int cnst = 0; cnst < NofConsts; cnst++) begin
          slot_init.constants[cnst] = const_init[cnst];
        end

        // Operands must be assigned depending on the number we have
        for (int op = 0; op < NofOperands; op++) begin
          slot_init.operands[op] = ops_init[op];
        end
      end
    end else if (RsType == LSU_RS) begin: gen_lsu_slot_init
      always_comb begin
        slot_init = '{
          is_occupied:      1'b1,
          lsu_op:           disp_req_i.fu_data.lsu_op,
          lsu_size:         disp_req_i.fu_data.lsu_size,
          tag:              disp_req_i.tag,
          constants:        '0,
          operands:         '0
        };

        // Constants must be assigned depending on the number we have
        for (int cnst = 0; cnst < NofConsts; cnst++) begin
          slot_init.constants[cnst] = const_init[cnst];
        end

        // Operands must be assigned depending on the number we have
        for (int op = 0; op < NofOperands; op++) begin
          slot_init.operands[op] = ops_init[op];
        end
      end
    end else if (RsType == FPU_RS) begin: gen_fpu_slot_init
      always_comb begin
        slot_init = '{
          is_occupied:      1'b1,
          fpu_op:           disp_req_i.fu_data.fpu_op,
          fpu_fmt_src:      disp_req_i.fu_data.fpu_fmt_src,
          fpu_fmt_dst:      disp_req_i.fu_data.fpu_fmt_dst,
          fpu_rnd_mode:     disp_req_i.fu_data.fpu_rnd_mode,
          tag:              disp_req_i.tag,
          constants:        '0,
          operands:         '0
        };

        // Constants must be assigned depending on the number we have
        for (int cnst = 0; cnst < NofConsts; cnst++) begin
          slot_init.constants[cnst] = const_init[cnst];
        end

        // Operands must be assigned depending on the number we have
        for (int op = 0; op < NofOperands; op++) begin
          slot_init.operands[op] = ops_init[op];
        end
      end
    end
  endgenerate


  rs_slot_issue_t selected_slot;
  always_comb begin : slot_selection
    // Update the slot depending on the state.
    selected_slot = slot_issue_i;
    // If we dispatch an instruction into this slot this cycle
    // and the disp and index pointer are the same
    // the slot is forwarded from the dispatch request.
    if (disp_req_valid_i && (disp_idx_i == issue_idx_i) && !rs_full_i) begin
      selected_slot = slot_init;
    end
  end

  // We forward/store the initialzied slot with the dispatch information
  assign slot_disp_o = slot_init;

  ///////////////////////////
  // Operand req generation//
  ///////////////////////////

  always_comb begin: operand_request_generation
    for (int op = 0; op < NofOperands; op++) begin
      op_reqs_o[op] = '{
        phy_reg:    selected_slot.operands[op].phy_reg_src,
        is_fp: selected_slot.operands[op].is_fp
      };
    end
  end

  rs_slot_issue_t slot_op_rsp;

  // Operand response handling
  always_comb begin : operand_response_handling
    slot_op_rsp = selected_slot;
    for (int op = 0; op < NofOperands; op++) begin
      // The value is valid if the operand response is valid
      if (op_rsps_valid_i[op]) begin
        slot_op_rsp.operands[op].is_valid  = 1'b1;
      end
    end
  end

  ///////////
  // Issue //
  ///////////

  // Issue an instruction if all operands have been received, based on the slot state after

  logic [NofOperands-1:0] operand_valid;
  logic                   all_operands_valid;
  logic                   issue_hs;

  generate
    if (RsType == ALU_RS) begin: gen_alu_issue_req
      always_comb begin
        // Issue the operation if all operands are valid. The FU exerts backpressure if its pipeline
        // is full or the result cannot be written because the current result has not been consumed
        // by all consumers yet.
        // Tag used for the operation is the slot_id, to identify the result destination in case
        // results can come back OoO from the FU (as is the case for the FPU).
        issue_req_o                      = '0;
        issue_req_o.fu_data.fu           = NONE; // Not required by FU
        issue_req_o.fu_data.alu_op       = slot_op_rsp.alu_op;
        issue_req_o.fu_data.lsu_op       = schnova_pkg::LsuOpLoad;
        issue_req_o.fu_data.csr_op       = CsrOpNone; // Not supported in FREP
        issue_req_o.fu_data.fpu_op       = schnova_pkg::FpuOpFadd;
        issue_req_o.fu_data.operand_a    = slot_op_rsp.constants[0].is_valid  ? slot_op_rsp.constants[0].value
                                                                              : op_rsps_i[0];
        issue_req_o.fu_data.operand_b    = slot_op_rsp.constants[1].is_valid  ? slot_op_rsp.constants[1].value
                                                                              : op_rsps_i[1];
        issue_req_o.fu_data.imm          = '0;
        issue_req_o.fu_data.lsu_size     = Word;
        issue_req_o.fu_data.fpu_fmt_src  = fpnew_pkg::FP32;
        issue_req_o.fu_data.fpu_fmt_dst  = fpnew_pkg::FP32;
        issue_req_o.fu_data.fpu_rnd_mode = fpnew_pkg::RNE;
        issue_req_o.tag                  = slot_op_rsp.tag;
      end
    end else if (RsType == LSU_RS) begin : gen_lsu_issue_req
       always_comb begin
        // Issue the operation if all operands are valid. The FU exerts backpressure if its pipeline
        // is full or the result cannot be written because the current result has not been consumed
        // by all consumers yet.
        // Tag used for the operation is the slot_id, to identify the result destination in case
        // results can come back OoO from the FU (as is the case for the FPU).
        issue_req_o                      = '0;
        issue_req_o.fu_data.fu           = NONE; // Not required by FU
        issue_req_o.fu_data.alu_op       = schnova_pkg::AluOpAdd;
        issue_req_o.fu_data.lsu_op       = slot_op_rsp.lsu_op;
        issue_req_o.fu_data.csr_op       = CsrOpNone; // Not supported in FREP
        issue_req_o.fu_data.fpu_op       = schnova_pkg::FpuOpFadd;
        issue_req_o.fu_data.operand_a    = op_rsps_i[0];
        issue_req_o.fu_data.operand_b    = op_rsps_i[1];
        issue_req_o.fu_data.imm          = slot_op_rsp.constants[0].value;
        issue_req_o.fu_data.lsu_size     = slot_op_rsp.lsu_size;
        issue_req_o.fu_data.fpu_fmt_src  = fpnew_pkg::FP32;
        issue_req_o.fu_data.fpu_fmt_dst  = fpnew_pkg::FP32;
        issue_req_o.fu_data.fpu_rnd_mode = fpnew_pkg::RNE;
        issue_req_o.tag                  = slot_op_rsp.tag;
      end
    end else if (RsType == FPU_RS) begin : gen_fpu_issue_req
       always_comb begin
        // Issue the operation if all operands are valid. The FU exerts backpressure if its pipeline
        // is full or the result cannot be written because the current result has not been consumed
        // by all consumers yet.
        // Tag used for the operation is the slot_id, to identify the result destination in case
        // results can come back OoO from the FU (as is the case for the FPU).
        issue_req_o                      = '0;
        issue_req_o.fu_data.fu           = NONE; // Not required by FU
        issue_req_o.fu_data.alu_op       = schnova_pkg::AluOpAdd;
        issue_req_o.fu_data.lsu_op       = schnova_pkg::LsuOpLoad;
        issue_req_o.fu_data.csr_op       = CsrOpNone; // Not supported in FREP
        issue_req_o.fu_data.fpu_op       = slot_op_rsp.fpu_op;
        issue_req_o.fu_data.operand_a    = op_rsps_i[0];
        issue_req_o.fu_data.operand_b    = op_rsps_i[1];
        issue_req_o.fu_data.imm          = slot_op_rsp.constants[0].is_valid  ? slot_op_rsp.constants[0].value
                                                                              : op_rsps_i[2];
        issue_req_o.fu_data.lsu_size     = Word;
        issue_req_o.fu_data.fpu_fmt_src  = slot_op_rsp.fpu_fmt_src;
        issue_req_o.fu_data.fpu_fmt_dst  = slot_op_rsp.fpu_fmt_dst;
        issue_req_o.fu_data.fpu_rnd_mode = slot_op_rsp.fpu_rnd_mode;
        issue_req_o.tag                  = slot_op_rsp.tag;
      end
    end
  endgenerate

  for (genvar i = 0; i < NofOperands; i++) begin : gen_operand_valid
    assign operand_valid[i] = slot_op_rsp.operands[i].is_valid;
  end
  assign all_operands_valid = &operand_valid;
  assign issue_req_valid_o = slot_op_rsp.is_occupied && all_operands_valid;
  assign issue_hs = issue_req_valid_o && issue_req_ready_i;
  assign issue_hs_o = issue_hs;

    // The RSS is ready to accept a dispatch request as long as the reservation station is not full
  assign disp_req_ready_o = !rs_full_i || issue_hs_o;
  assign disp_hs_o = disp_req_valid_i && disp_req_ready_o;

  ////////////////////////////
  // Issue Request Snooping //
  ////////////////////////////

  // The refence counting based reclamation needs to snoop the issue requests
  if (UseFreeList) begin : gen_no_clr_req
    // These requests are not used in a freelist based
    // physical register reclamation approach
    assign issue_clr_req_o = '0;
    assign issue_clr_req_valid_o = 1'b0;
  end else begin : gen_clr_req
    assign issue_clr_req_valid_o = issue_hs;
    if (RsType == ALU_RS) begin: gen_alu_clr_req
      // For the ALU there are only two potential src registers
      assign issue_clr_req_o = '{
        phy_reg_op_a: slot_op_rsp.operands[0].phy_reg_src,
        is_op_a_fp:   1'b0, // op a is never a FPR for the ALU
        is_op_a_cnst: slot_op_rsp.constants[0].is_valid,
        phy_reg_op_b: slot_op_rsp.operands[1].phy_reg_src,
        is_op_b_fp:   1'b0, // op b is never a FPR for the ALU
        is_op_b_cnst: slot_op_rsp.constants[1].is_valid,
        phy_reg_op_c: '0, // There is no third operand for the ALU
        is_op_c_cnst: 1'b0
      };
    end else if (RsType == LSU_RS) begin : gen_lsu_clr_req
      // For the LSU there are only two potential src registers
      assign issue_clr_req_o = '{
        phy_reg_op_a: slot_op_rsp.operands[0].phy_reg_src,
        is_op_a_fp:   1'b0, // op a always targets the GPR for the LSU
        is_op_a_cnst: 1'b0, // op a is never a constant
        phy_reg_op_b: slot_op_rsp.operands[1].phy_reg_src,
        is_op_b_fp:   slot_op_rsp.operands[1].is_fp,
        is_op_b_cnst: 1'b0, // op b is never a constant
        phy_reg_op_c: '0, // There is no third operand for the LSU
        is_op_c_cnst: 1'b0
      };
    end else if (RsType == FPU_RS) begin : gen_fpu_clr_req
      // For the FPU all sources can potentially be a register
      assign issue_clr_req_o = '{
        phy_reg_op_a: slot_op_rsp.operands[0].phy_reg_src,
        is_op_a_fp:   slot_op_rsp.operands[0].is_fp,
        is_op_a_cnst: 1'b0, // op a is never a constant
        phy_reg_op_b: slot_op_rsp.operands[1].phy_reg_src,
        is_op_b_fp:   1'b1, // op b always targets the FPR for the FPU
        is_op_b_cnst: 1'b0, // op b is never a constant
        phy_reg_op_c: slot_op_rsp.operands[2].phy_reg_src,
        is_op_c_cnst: slot_op_rsp.constants[0].is_valid
      };
    end
      
  end

endmodule
