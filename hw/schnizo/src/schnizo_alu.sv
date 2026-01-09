// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// ALU of the Schnizo Core.
//
// The ALU consists of an adder, a comparison part for branch resolving and an arithmetic
// shifter unit. It is based on the CVA6 alu module.
module schnizo_alu import schnizo_pkg::*, schnizo_tracer_pkg::*; #(
  parameter int unsigned XLEN        = 32,
  parameter bit          HasBranch   = 1'b1,
  parameter type         issue_req_t = logic,
  parameter type         instr_tag_t = logic
) (
  input  logic            clk_i,
  input  logic            rst_i,

  // Trace
  // pragma translate_off
  output issue_alu_trace_t trace_o,
  // pragma translate_on

  input  issue_req_t      issue_req_i,
  input  logic            issue_req_valid_i,
  output logic            issue_req_ready_o,
  output logic [XLEN-1:0] result_o,
  /// Set if the comparison is true
  output logic            compare_res_o,
  output instr_tag_t      tag_o,
  output logic            result_valid_o,
  input  logic            result_ready_i,
  output logic            busy_o
);

  // ---------------------
  // Valid/Ready handshake
  // ---------------------
  // This ALU is combinatorial only. Feed through handshake.
  assign result_valid_o    = issue_req_valid_i;
  assign issue_req_ready_o = result_ready_i;
  assign tag_o             = issue_req_i.tag;
  // The ALU is busy if there is valid data passing through.
  assign busy_o = issue_req_valid_i;

  // ------------------
  // Operand extraction
  // ------------------
  alu_op_e         alu_op;
  logic [XLEN-1:0] opa;
  logic [XLEN-1:0] opb;
  assign alu_op = issue_req_i.fu_data.alu_op;
  assign opa    = issue_req_i.fu_data.operand_a[XLEN-1:0];
  assign opb    = issue_req_i.fu_data.operand_b[XLEN-1:0];

  // ------
  // Adder
  // ------
  logic            adder_op_b_negate;
  logic [XLEN:0]   operand_b_neg;
  logic [XLEN:0]   adder_in_a, adder_in_b;
  logic [XLEN+1:0] adder_result_ext;
  logic [XLEN-1:0] adder_result;
  logic            adder_res_is_zero;

  assign adder_op_b_negate = alu_op inside {AluOpEq, AluOpNeq, AluOpSub};

  // prepare operand a
  assign adder_in_a = {opa, 1'b1};

  // prepare operand b (negate if required)
  assign operand_b_neg = {opb, 1'b0} ^ {XLEN + 1{adder_op_b_negate}};
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

    if ((alu_op == AluOpSlt) ||
        (alu_op == AluOpLt)  ||
        (alu_op == AluOpGe)) begin
      sgn = 1'b1;
    end

    op_a_is_less = $signed({sgn & opa[XLEN-1], opa}) < $signed({sgn & opb[XLEN-1], opb});
  end

  // -------
  // Shifter
  // -------
  // shifter control
  logic [4:0] shift_amt;
  logic       shift_left;
  logic       shift_arithmetic;

  assign shift_amt        = opb[4:0];
  assign shift_left       = (alu_op == AluOpSll);
  assign shift_arithmetic = (alu_op == AluOpSra);

  // shifter data path
  logic [XLEN-1:0] shift_opa, shift_opa_reversed;
  logic [XLEN-1:0] shift_input;
  logic [XLEN:0]   shift_input_ext;
  logic [XLEN:0]   shift_right_result_ext;
  logic [XLEN-1:0] shift_right_result, shift_left_result;
  logic [XLEN-1:0] shift_result;

  assign shift_opa = opa;

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

  assign xor_result = opa ^ opb;
  assign or_result  = opa | opb;
  assign and_result = opa & opb;

  // -----------
  // Result MUX
  // -----------
  always_comb begin : result_mux
    result_o = '0;

    unique case (alu_op)
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
      unique case (alu_op)
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

  ////////////
  // Tracer //
  ////////////

  // pragma translate_off
  assign trace_o = '{
    valid:      issue_req_valid_i && issue_req_ready_o,
    instr_iter: '0, // does not apply in regular execution
    producer:   "", // will be set by fu_stage
    alu_opa:    opa,
    alu_opb:    opb
  };
  // pragma translate_on

endmodule
