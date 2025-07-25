// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Pascal Etterli <petterli@student.ethz.ch>
// Description: ALU of the Schnizo Core.
//  The ALU consists of an adder, a comparison part for branch resolving and an arithmetic
//  shifter unit. It is based on the CVA6 alu module.

module schnizo_alu import schnizo_pkg::*; #(
  parameter int unsigned XLEN = 32,
  parameter bit          HasBranch     = 1'b1
)
(
  input  logic            clk_i,
  input  logic            rst_i,

  input  alu_op_e         alu_op_i,
  input  logic [XLEN-1:0] opa_i,
  input  logic [XLEN-1:0] opb_i,
  output logic [XLEN-1:0] result_o,
  /// Set if the comparison is true
  output logic            compare_res_o
);
  // ------
  // Adder
  // ------
  logic            adder_op_b_negate;
  logic [XLEN:0]   operand_b_neg;
  logic [XLEN:0]   adder_in_a, adder_in_b;
  logic [XLEN+1:0] adder_result_ext;
  logic [XLEN-1:0] adder_result;
  logic            adder_res_is_zero;

  assign adder_op_b_negate = alu_op_i inside {AluOpEq, AluOpNeq, AluOpSub};

  // prepare operand a
  assign adder_in_a = {opa_i, 1'b1};

  // prepare operand b (negate if required)
  assign operand_b_neg = {opb_i, 1'b0} ^ {XLEN + 1{adder_op_b_negate}};
  assign adder_in_b    = operand_b_neg;

  // actual adder
  assign adder_result_ext  = adder_in_a + adder_in_b;
  assign adder_result      = adder_result_ext[XLEN:1];
  assign adder_res_is_zero = ~|adder_result;

  // ------------
  // Comparisons
  // ------------
  logic op_a_is_less;
  always_comb begin : comparisons
    logic sgn;
    sgn = 1'b0;

    if ((alu_op_i == AluOpSlt) ||
        (alu_op_i == AluOpLt)  ||
        (alu_op_i == AluOpGe)) begin
      sgn = 1'b1;
    end

    op_a_is_less = $signed({sgn & opa_i[XLEN-1], opa_i}) < $signed({sgn & opb_i[XLEN-1], opb_i});
  end

  // -------
  // Shifter
  // -------
  // shifter control
  logic [4:0] shift_amt;
  logic       shift_left;
  logic       shift_arithmetic;

  assign shift_amt = opb_i[4:0];
  assign shift_left = (alu_op_i == AluOpSll);
  assign shift_arithmetic = (alu_op_i == AluOpSra);

  // shifter data path
  logic [XLEN-1:0] shift_opa, shift_opa_reversed;
  logic [XLEN-1:0] shift_input;
  logic [XLEN:0]   shift_input_ext;
  logic [XLEN:0]   shift_right_result_ext;
  logic [XLEN-1:0] shift_right_result, shift_left_result;
  logic [XLEN-1:0] shift_result;

  assign shift_opa = opa_i;

  for (genvar i = 0; i < XLEN; i++) begin : gen_reverse_shift_opa
    assign shift_opa_reversed[i] = shift_opa[XLEN-1-i];
  end

  assign shift_input = shift_left ? shift_opa_reversed : shift_opa;
  assign shift_input_ext = {shift_input[XLEN-1] & shift_arithmetic, shift_input};
  assign shift_right_result_ext = $unsigned($signed(shift_input_ext) >>> shift_amt);

  assign shift_right_result = shift_right_result_ext[XLEN-1:0];
  for (genvar i = 0; i < XLEN; i++) begin : gen_reverse_shift_result
    assign shift_left_result[i] = shift_right_result[XLEN-1-i];
  end

  assign shift_result = shift_left ? shift_left_result : shift_right_result;

  //---------------------------
  // Bitwise logical operations
  //---------------------------
  logic [XLEN-1:0] xor_result;
  logic [XLEN-1:0] or_result;
  logic [XLEN-1:0] and_result;

  assign xor_result = opa_i ^ opb_i;
  assign or_result  = opa_i | opb_i;
  assign and_result = opa_i & opb_i;

  // -----------
  // Result MUX
  // -----------
  always_comb begin : result_mux
    result_o = '0;

    unique case (alu_op_i)
      AluOpAdd,
      AluOpSub:  result_o = adder_result;
      AluOpXor:  result_o = xor_result;
      AluOpOr:   result_o = or_result;
      AluOpAnd:  result_o = and_result;
      AluOpSlt,
      AluOpSltu: result_o = {{(XLEN-1){1'b0}}, op_a_is_less};
      AluOpSll,
      AluOpSrl,
      AluOpSra:  result_o = shift_result;
      default:   result_o = '0;
    endcase
  end

  // ----------------
  // Branch Resolving
  // ----------------
  if (HasBranch) begin : gen_branch_resolve
    always_comb begin
      unique case (alu_op_i)
        AluOpEq:  compare_res_o = adder_res_is_zero;
        AluOpNeq: compare_res_o = ~adder_res_is_zero;
        AluOpLt,
        AluOpLtu: compare_res_o = op_a_is_less;
        AluOpGe,
        AluOpGeu: compare_res_o = ~op_a_is_less;
        default:  compare_res_o = 1'b0;
      endcase
    end
  end else begin : gen_no_branch_resolve
    assign compare_res_o = 1'b0;
  end

  // --------------
  // Unused Signals
  // --------------
  // clk_i and rst_i are only used by assertions
  logic unused_clk;
  logic unused_rst;
  assign unused_clk = clk_i;
  assign unused_rst = rst_i;

  // TODO: unused adder & shifter bits
endmodule
