// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Pascal Etterli <petterli@student.ethz.ch>
// Description: Top-Level of the Schnizo FPU.
// This module wraps the FPnew FPU such that the interface matches the Schnizo dispatch requests.
// It decodes the instruction and forwards the operands to the FPU.
// The operands rs1, rs2, rs3 are defined as in the RISC-V ISA specification.
// The correct assignment matching the FPnew interface is done here.

module schnizo_fpu import schnizo_pkg::*; #(
  parameter fpnew_pkg::fpu_implementation_t FPUImplementation = '0,
  parameter bit          RVF            = 1,
  parameter bit          RVD            = 1,
  parameter bit          XF16           = 0,
  parameter bit          XF16ALT        = 0,
  parameter bit          XF8            = 0,
  parameter bit          XF8ALT         = 0,
  // Vectors are not implemented! Here for compatibility with Snitch.
  parameter bit          XFVEC          = 0,
  parameter int unsigned FLEN           = 0,
  // Register the signals directly before the FPnew instance
  parameter bit          RegisterFPUIn  = 0,
  // Register the signals directly after the FPnew instance
  parameter bit          RegisterFPUOut = 0,
  parameter type         instr_tag_t    = logic
) (
  input  logic                  clk_i,
  input  logic                  rst_ni,

  input  logic [31:0]           hart_id_i,
  input  fpu_op_e               op_i,
  input  logic [FLEN-1:0]       rs1_i,
  input  logic [FLEN-1:0]       rs2_i,
  input  logic [FLEN-1:0]       rs3_i,
  input  fpnew_pkg::roundmode_e round_mode_i,
  input  fpnew_pkg::fp_format_e fmt_src_i,
  input  fpnew_pkg::fp_format_e fmt_dst_i,
  input  instr_tag_t            tag_i,
  // Input Handshake
  input  logic                  in_valid_i,
  output logic                  in_ready_o,

  // Output signals
  output logic [FLEN-1:0]       result_o,
  output fpnew_pkg::status_t    status_o,
  output instr_tag_t            tag_o,
  // Output handshake
  output logic                  out_valid_o,
  input  logic                  out_ready_i
);
  localparam fpnew_pkg::fpu_features_t FPUFeatures = '{
    Width:         fpnew_pkg::maximum(FLEN, 32),
    EnableVectors: XFVEC,
    EnableNanBox:  1'b1,
    FpFmtMask:     {RVF, RVD, XF16, XF8, XF16ALT, XF8ALT},
    IntFmtMask:    {XFVEC && (XF8 || XF8ALT), XFVEC && (XF16 || XF16ALT), 1'b1, 1'b0}
  };

  typedef struct packed {
    logic [2:0][FLEN-1:0]   operands;
    fpnew_pkg::roundmode_e  rnd_mode;
    fpnew_pkg::operation_e  op;
    logic                   op_mod;
    fpnew_pkg::fp_format_e  src_fmt;
    fpnew_pkg::fp_format_e  dst_fmt;
    fpnew_pkg::int_format_e int_fmt;
    logic                   vectorial_op;
    instr_tag_t             tag;
  } fpu_in_t;

  typedef struct packed {
    logic [FLEN-1:0] result;
    logic [4:0]      status;
    instr_tag_t      tag;
  } fpu_out_t;

  typedef enum logic [1:0] {
    NONE,
    RS1,
    RS2,
    RS3_IMM
  } operand_sel_e;

  fpu_in_t  fpu_in_q,  fpu_in;
  fpu_out_t fpu_out_q, fpu_out;
  logic in_valid_q, in_ready_q;
  logic out_valid, out_ready;

  // We mux the operands from the ISA definition (rs1, rs2, rs3) to the FPnew definition.
  // Whereas FPnew specifies op[0..2] as the operands and for some instructions the mapping is not
  // 1 to 1.
  logic [2:0][FLEN-1:0] fpnew_operands;
  operand_sel_e [2:0] op_selection;

  fpnew_pkg::operation_e fpnew_op;
  logic operand_mod; // the operand modifier for alternative function of operation
  logic vectorial_op;
  fpnew_pkg::int_format_e int_fmt;

  // ---------------------------
  // Decoder
  // ---------------------------
  // The integer format depends on the XLEN of the core and is thus "fixed".
  assign int_fmt = fpnew_pkg::INT32; // TODO: make it configurable via XLEN

  // Decode the instruction op and assign the operands such that these match the FPnew interface.
  always_comb begin : fpu_op_decoder
    operand_mod = 1'b0;
    vectorial_op = 1'b0;
    op_selection[0] = RS1;
    op_selection[1] = RS2;
    op_selection[2] = NONE;

    fpnew_op = fpnew_pkg::ADD;
    operand_mod = '0;

    unique case (op_i)
      schnizo_pkg::FpuOpFadd: begin
        fpnew_op = fpnew_pkg::ADD; // rs1 + rs2
        op_selection[0] = NONE;
        op_selection[1] = RS1;
        op_selection[2] = RS2;
      end
      schnizo_pkg::FpuOpFsub: begin // rs1 - rs2
        fpnew_op = fpnew_pkg::ADD;
        operand_mod = 1'b1;
        op_selection[0] = NONE;
        op_selection[1] = RS1;
        op_selection[2] = RS2;
      end
      schnizo_pkg::FpuOpFmadd: begin // (rs1 * rs2) + rs3
        fpnew_op = fpnew_pkg::FMADD;
        op_selection[2] = RS3_IMM;
      end
      schnizo_pkg::FpuOpFmsub: begin // (rs1 * rs2) - rs3
        fpnew_op = fpnew_pkg::FMADD;
        operand_mod = 1'b1;
        op_selection[2] = RS3_IMM;
      end
      schnizo_pkg::FpuOpFnmsub: begin // -(rs1 * rs2) + rs3
        fpnew_op = fpnew_pkg::FNMSUB;
        op_selection[2] = RS3_IMM;
      end
      schnizo_pkg::FpuOpFnmadd: begin // -(rs1 * rs2) - rs3
        fpnew_op = fpnew_pkg::FNMSUB;
        operand_mod = 1'b1;
        op_selection[2] = RS3_IMM;
      end
      schnizo_pkg::FpuOpFmul: begin // rs1 * rs2
        fpnew_op = fpnew_pkg::MUL;
      end
      schnizo_pkg::FpuOpFdiv: begin // rs1 / rs2
        fpnew_op = fpnew_pkg::DIV; // TODO: Is this illegal? See comment in Snitch
      end
      schnizo_pkg::FpuOpFsqrt: begin
        fpnew_op = fpnew_pkg::SQRT;
        op_selection[0] = RS1;
        op_selection[1] = RS1; // TODO: Same as in Snitch: why both inputs to RS1?
      end
      schnizo_pkg::FpuOpFsgnj: begin
        fpnew_op = fpnew_pkg::SGNJ;
      end
      schnizo_pkg::FpuOpFsgnjSignExt: begin
        fpnew_op = fpnew_pkg::SGNJ;
        operand_mod = 1'b1;
      end
      schnizo_pkg::FpuOpFminmax: begin
        fpnew_op = fpnew_pkg::MINMAX;
      end
      schnizo_pkg::FpuOpFcmp: begin
        fpnew_op = fpnew_pkg::CMP;
      end
      schnizo_pkg::FpuOpF2I: begin
        fpnew_op = fpnew_pkg::F2I;
        op_selection[1] = NONE;
      end
      schnizo_pkg::FpuOpF2Iunsigned: begin
        fpnew_op = fpnew_pkg::F2I;
        operand_mod = 1'b1;
        op_selection[1] = NONE;
      end
      schnizo_pkg::FpuOpI2F: begin
        fpnew_op = fpnew_pkg::I2F;
        op_selection[1] = NONE;
      end
      schnizo_pkg::FpuOpI2Funsigned: begin
        fpnew_op = fpnew_pkg::I2F;
        operand_mod = 1'b1;
        op_selection[1] = NONE;
      end
      schnizo_pkg::FpuOpF2F: begin
        fpnew_op = fpnew_pkg::F2F;
        op_selection[1] = NONE;
      end
      schnizo_pkg::FpuOpFclassify: begin
        fpnew_op = fpnew_pkg::CLASSIFY;
        op_selection[1] = NONE;
      end
    endcase
  end

  // Operand MUX (allows to implement replication for vector instructions)
  for (genvar op = 0; op < 3; op++) begin : gen_operand_select
    always_comb begin : operand_mux
      case (op_selection[op])
        RS1:     fpnew_operands[op] = rs1_i;
        RS2:     fpnew_operands[op] = rs2_i;
        RS3_IMM: fpnew_operands[op] = rs3_i;
        NONE: fpnew_operands[op] = '0;
        default: fpnew_operands[op] = '0;
      endcase
    end
  end

  // ---------------------------
  // Downstream FPU
  // ---------------------------
  // Optionally cut the path to the FPU
  assign fpu_in = '{
    operands:     fpnew_operands,
    rnd_mode:     round_mode_i,
    op:           fpnew_op,
    op_mod:       operand_mod,
    src_fmt:      fmt_src_i,
    dst_fmt:      fmt_dst_i,
    int_fmt:      int_fmt,
    vectorial_op: vectorial_op,
    tag: tag_i
  };

  spill_register #(
    .T     ( fpu_in_t ),
    .Bypass( ~RegisterFPUIn )
    ) i_spill_register_fpu_in (
    .clk_i,
    .rst_ni,
    .valid_i(in_valid_i),
    .ready_o(in_ready_o),
    .data_i (fpu_in),
    .valid_o(in_valid_q),
    .ready_i(in_ready_q),
    .data_o (fpu_in_q)
  );

  fpnew_top #(
    // FPU configuration
    .Features                   (FPUFeatures),
    .Implementation             (FPUImplementation),
    .TagType                    (instr_tag_t),
    .CompressedVecCmpResult     (1),
    .StochasticRndImplementation(fpnew_pkg::DEFAULT_RSR)
  ) i_fpu (
    .clk_i,
    .rst_ni,
    .hart_id_i     (hart_id_i),
    .operands_i    (fpu_in_q.operands),
    .rnd_mode_i    (fpu_in_q.rnd_mode),
    .op_i          (fpu_in_q.op),
    .op_mod_i      (fpu_in_q.op_mod),
    .src_fmt_i     (fpu_in_q.src_fmt),
    .dst_fmt_i     (fpu_in_q.dst_fmt),
    .int_fmt_i     (fpu_in_q.int_fmt),
    .vectorial_op_i(fpu_in_q.vectorial_op),
    .tag_i         (fpu_in_q.tag),
    .simd_mask_i   ('1),
    .in_valid_i    (in_valid_q),
    .in_ready_o    (in_ready_q),
    .flush_i       (1'b0),
    .result_o      (fpu_out.result),
    .status_o      (fpu_out.status),
    .tag_o         (fpu_out.tag),
    .out_valid_o   (out_valid),
    .out_ready_i   (out_ready),
    .busy_o        ()
  );

  spill_register #(
    .T      (fpu_out_t),
    .Bypass (~RegisterFPUOut)
  ) i_spill_register_fpu_out (
    .clk_i,
    .rst_ni,
    .valid_i(out_valid),
    .ready_o(out_ready),
    .data_i (fpu_out),
    .valid_o(out_valid_o),
    .ready_i(out_ready_i),
    .data_o (fpu_out_q)
  );

  assign result_o = fpu_out_q.result;
  assign status_o = fpu_out_q.status;
  assign tag_o = fpu_out_q.tag;
endmodule
