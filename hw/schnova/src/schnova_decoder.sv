// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Stefan Odermatt <soderma@ethz.ch>

// The PipeWidth-wide decoder of Schnova, based on the decoder of Schnizo
module schnova_decoder import schnizo_pkg::*; #(
  parameter int unsigned XLEN        = 32,
  parameter int unsigned PipeWidth   = 1,
  parameter bit          Xdma        = 0,
  parameter bit          Xfrep       = 1,
  /// Enable F Extension (single).
  parameter bit          RVF         = 1,
  /// Enable D Extension (double).
  parameter bit          RVD         = 0,
  parameter bit          XF16        = 0,
  parameter bit          XF16ALT     = 0,
  parameter bit          XF8         = 0,
  parameter bit          XF8ALT      = 0,
  parameter type         block_ctrl_info_t = logic,
  parameter type         instr_dec_t = logic
) (
  // For assertions only.
  input logic                          clk_i,
  input logic                          rst_i,

  input  logic [PipeWidth-1:0][31:0]   instr_fetch_data_i,
  input  logic [PipeWidth-1:0]         instr_fetch_data_valid_i,
  input  fpnew_pkg::roundmode_e        fpu_round_mode_i,
  input  fpnew_pkg::fmt_mode_t         fpu_fmt_mode_i,
  output logic [PipeWidth-1:0]         instr_valid_o,
  output logic [PipeWidth-1:0]         instr_illegal_o,
  output block_ctrl_info_t             blk_ctrl_info_o,
  output instr_dec_t [PipeWidth-1:0]   instr_dec_o
);

  logic [PipeWidth-1:0] instr_valid;
  logic [PipeWidth-1:0] instr_valid_masked;
  // Per instruction signal, whether the instruction is a control instruction
  logic [PipeWidth-1:0] is_ctrl_instr;
  // Per instruction signal, whether the instruction is a fence_i instruction
  logic [PipeWidth-1:0] is_fence_i_instr;
  // Signal that tracks whether the following innstructions have to be invalidated
  logic [PipeWidth-2:0] invalidate_instr;
  // The idx of the instruction that is relevant for the block control info
  // this instruction is the relevant instruction that decides how the frontend
  // controller has to react to this fetch block
  logic [$clog2(PipeWidth)-1:0] blk_ctrl_instr_idx;

  // The decoder has to main tasks
  // 1) Decode all the instructions of the fetch block
  // 2) Mask (invalidate) all the speculative instructions after the first control instruction

  //////////////////////////
  // Instruction Decoding //
  //////////////////////////

  // Generate all the decoder needed for the superscalar pipeline
  for (genvar dec_idx = 0; dec_idx < PipeWidth; dec_idx++) begin: gen_decoders
    schnizo_decoder #(
      .XLEN   (XLEN),
      .Xdma   (Xdma),
      .Xfrep  (Xfrep),
      .RVF    (RVF),
      .RVD    (RVD),
      .XF16   (XF16),
      .XF16ALT(XF16ALT),
      .XF8    (XF8),
      .XF8ALT (XF8ALT),
      .instr_dec_t(instr_dec_t)
    ) i_decoder (
      .clk_i,
      .rst_i,
      .instr_fetch_data_i      (instr_fetch_data_i[dec_idx]),
      .instr_fetch_data_valid_i(instr_fetch_data_valid_i[dec_idx]),
      .fpu_round_mode_i        (fpu_round_mode_i),
      .fpu_fmt_mode_i          (fpu_fmt_mode_i),
      .instr_valid_o           (instr_valid[dec_idx]),
      .instr_illegal_o         (instr_illegal_o[dec_idx]),
      .instr_dec_o             (instr_dec_o[dec_idx])
    );
  end

  ///////////////////////////////
  // Instruction valid masking //
  ///////////////////////////////

  // The fetch block must invalidate all younger instructions after the first
  // control instruction because Schnova does not speculatively execute
  // beyond a control transfer.  `instr_dec_o[0]` corresponds to the
  // oldest instruction, so we walk the vector in index order to find the
  // first control and then mask out everything after it
  // Similarily, we have to invalidate all instructions after a fence_i instruction
  // they have to be refetched after the fence_i (and thus I-cache flush) has been
  // executed.

  // Compute per instruction indicator whether it is a valid control or fence_i instruction
  for (genvar i=0; i < PipeWidth; i++) begin: gen_is_ctrl_fence_i
    assign is_ctrl_instr[i] = (instr_dec_o[i].is_branch |
                              instr_dec_o[i].is_jal    |
                              instr_dec_o[i].is_mret   |
                              instr_dec_o[i].is_sret   |
                              instr_dec_o[i].is_jalr)  &
                              instr_valid[i];
    assign is_fence_i_instr[i] = instr_dec_o[i].is_fence_i & instr_valid[i];
  end


  for (genvar instr_idx = 0; instr_idx < PipeWidth; instr_idx++) begin: gen_valid_mask
    // Iterate through the slots and kill any instruction younger than the
    // the first valid control or fence_i instruction.
    if (instr_idx == 0) begin: gen_no_masking
      // We don't have to mask the first instruction, it is always valid if it was valid before
      assign instr_valid_masked[instr_idx] = instr_valid[instr_idx];
      // We invalidate the second instruction if the first is a control or fence_i instruction.
      assign invalidate_instr[instr_idx] =  is_ctrl_instr[instr_idx] |
                                            is_fence_i_instr[instr_idx];
    end else begin: gen_valid_masking
      // If an older instruction was a control or  fence_i instruction,
      // this instruction has to be invalidated
      assign instr_valid_masked[instr_idx] = (invalidate_instr[instr_idx-1])
                                              ? 1'b0
                                              : instr_valid[instr_idx];
      // Propagate the invalidate signal as well
      assign invalidate_instr[instr_idx] = (invalidate_instr[instr_idx-1]) ?
                                            invalidate_instr[instr_idx-1] :
                                            is_ctrl_instr[instr_idx] |
                                            is_fence_i_instr[instr_idx];
    end
  end

  // The instruction valid output is now just the masked instruction valid signal
  assign instr_valid_o = instr_valid_masked;

  // Instructions are always valid until the first invalid instruction comes either
  // since the fetch block was misaligned or it was invalidated due to a ctrl or
  // fence i instruction. Hence the last valid instruction is a candiate to be a
  // ctrl or fence_i instruction
  always_comb begin: fetch_idx_calc
    blk_ctrl_instr_idx = '0;
    for (int instr_idx = 0; instr_idx < PipeWidth; instr_idx++) begin
      blk_ctrl_instr_idx += instr_valid_masked[instr_idx];
    end
  end
  // Assign the control block info according to the instruction
  // the blk_ctr_instr_idx points to
  assign blk_ctrl_info_o = '{
    imm:        instr_dec_o[blk_ctrl_instr_idx].imm,
    is_branch:  instr_dec_o[blk_ctrl_instr_idx].is_branch,
    is_jal:     instr_dec_o[blk_ctrl_instr_idx].is_jal,
    is_jalr:    instr_dec_o[blk_ctrl_instr_idx].is_jalr,
    is_fence_i: instr_dec_o[blk_ctrl_instr_idx].is_fence_i,
    is_ctrl:    instr_dec_o[blk_ctrl_instr_idx].is_branch |
                instr_dec_o[blk_ctrl_instr_idx].is_jal    |
                instr_dec_o[blk_ctrl_instr_idx].is_mret   |
                instr_dec_o[blk_ctrl_instr_idx].is_sret   |
                instr_dec_o[blk_ctrl_instr_idx].is_jalr,
    instr_idx:  blk_ctrl_instr_idx
  };

endmodule
