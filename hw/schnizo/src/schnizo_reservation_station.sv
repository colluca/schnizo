// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Pascal Etterli <petterli@student.ethz.ch>
// Description: The Reservation station which handles the instruction issuing of a functional
// unit during superscalar loop execution. It instantiates the FU.

`include "common_cells/registers.svh"

module schnizo_reservation_station import schnizo_pkg::*; #(
  parameter int unsigned ProdAddrSize = 5,
  parameter int unsigned XLEN         = 32,
  parameter type         disp_req_t   = logic,
  parameter type         disp_res_t   = logic,
  parameter type         result_t     = logic,
  parameter type         result_tag_t = logic,
  parameter type         fu_t         = logic,
  parameter fu_t         Fu,

  /// ALU specific
  // Enable the branch comparison logic
  parameter bit          HasBranch = 0,

  /// LSU specific
  // Physical Address width of the core.
  parameter int unsigned AddrWidth = 48,
  // Data width of memory interface.
  parameter int unsigned DataWidth = 64,
  // Data port request type.
  parameter type         dreq_t    = logic,
  // Data port response type.
  parameter type         drsp_t    = logic,
  parameter int unsigned NumIntOutstandingLoads = 0,
  parameter int unsigned NumIntOutstandingMem   = 0,
  // Consistency Address Queue (CAQ) parameters
  parameter bit          CaqEn       = 0,
  parameter int unsigned CaqDepth    = 0,
  parameter int unsigned CaqTagWidth = 0,
  // Derived parameter *Do not override*
  parameter type         addr_t = logic [AddrWidth-1:0],
  parameter type         data_t = logic [DataWidth-1:0],

  /// LSU and FPU specific *Do not override*
  parameter int unsigned FLEN         = DataWidth,

  /// FPU specific
  parameter fpnew_pkg::fpu_implementation_t FPUImplementation = '0,
  parameter bit          RVF     = 0,
  parameter bit          RVD     = 0,
  parameter bit          XF16    = 0,
  parameter bit          XF16ALT = 0,
  parameter bit          XF8     = 0,
  parameter bit          XF8ALT  = 0,
  // Vectors are not implemented! Here for compatibility with Snitch.
  parameter bit          XFVEC   = 0,
  parameter bit          RegisterFPUIn  = 0,
  parameter bit          RegisterFPUOut = 0
) (
  input  logic        clk_i,
  input  logic        rst_i,
  input  disp_req_t   disp_req_i,
  input  logic        disp_req_valid_i,
  output logic        disp_req_ready_o,
  // The response to the dispatch request. Is valid at handshake.
  output disp_res_t   disp_res_o,
  output logic        rss_full_o,

  // LSU memory interface
  output dreq_t       lsu_data_req_o,
  input  drsp_t       lsu_data_rsp_i,
  output logic        lsu_empty_o,
  output logic        lsu_addr_misaligned_o,

  // Consistency address queue interface
  input  addr_t       caq_addr_i,
  input  logic        caq_is_fp_store_i,
  input  logic        caq_req_valid_i,
  output logic        caq_req_ready_o,
  // Answer from other LSU
  input  logic        caq_rsp_valid_i,
  output logic        caq_rsp_valid_o,

  // FPU signals
  input  logic [31:0]        hart_id_i,
  output fpnew_pkg::status_t fpu_status_o,

  // Write back port
  output result_t     result_o,
  output result_tag_t result_tag_o,
  output logic        result_valid_o,
  input  logic        result_ready_i
);
  initial begin
    $display("Passed FU type: %d\n", Fu);
    $display("ALU type is %d\n", schnizo_pkg::ALU);
    $display("STORE type is %d\n", schnizo_pkg::STORE);
    $display("LOAD type is %d\n", schnizo_pkg::LOAD);
  end

  // ---------------------------
  // Reservation Station
  // ---------------------------
  // TODO: the RSS logic / FFs

  // ---------------------------
  // ALU
  // ---------------------------
  if (Fu == schnizo_pkg::ALU) begin : gen_alu
    // For now the ALU always accepts a dispatch request.
    // It simply forwards the valid signal to the write back.
    // Ready also comes from the write back
    assign result_valid_o = disp_req_valid_i;
    assign disp_req_ready_o = result_ready_i;

    schnizo_alu #(
      .XLEN     (XLEN),
      .HasBranch(HasBranch)
    ) i_rs_alu (
      .clk_i,
      .rst_i,
      .alu_op_i(disp_req_i.fu_data.alu_op),
      .opa_i(disp_req_i.fu_data.operand_a[XLEN-1:0]),
      .opb_i(disp_req_i.fu_data.operand_b[XLEN-1:0]),
      .result_o(result_o.result),
      .compare_res_o(result_o.compare_res)
    );
    // Feed through the tag directly as it is a combinatorial FU.
    assign result_tag_o = disp_req_i.tag;
  end // no signals to tie off for ALU

  // ---------------------------
  // LSU
  // ---------------------------
  data_t lsu_store_data;
  addr_t lsu_addr; // the address to load from / store to
  logic is_store;
  logic is_signed;
  ls_size_e ls_size;
  reqrsp_pkg::amo_op_e ls_amo;
  result_tag_t input_tag, result_tag;
  logic lsu_issue_valid, lsu_issue_ready;
  logic lsu_result_valid, lsu_result_ready;
  data_t lsu_result;
  if (Fu == schnizo_pkg::LOAD || Fu == schnizo_pkg::STORE) begin : gen_lsu
    // Request handshake
    assign lsu_issue_valid = disp_req_valid_i;
    assign disp_req_ready_o = lsu_issue_ready;

    // Sign extend the data to be stored to the appropriate length
    assign lsu_store_data = $unsigned(disp_req_i.fu_data.operand_b);

    // Pass the tag to the LSU
    assign input_tag = disp_req_i.tag;

    // Compute the address
    // For the superscalar case we cannot use the ALU for this computation.
    // Therefore, we create a separate adder.
    assign lsu_addr = disp_req_i.fu_data.operand_a + disp_req_i.fu_data.imm;

    // Control signals
    assign is_store = disp_req_i.fu_data.lsu_op inside {LsuOpStoreByte, LsuOpStoreHalf,
                                                        LsuOpStoreWord,
                                                        LsuOpFpStoreByte, LsuOpFpStoreHalf,
                                                        LsuOpFpStoreWord, LsuOpFpStoreDouble};
    assign is_signed = disp_req_i.fu_data.lsu_op inside {LsuOpLoadByte, LsuOpLoadHalf,
                                                         LsuOpLoadWord};
    always_comb begin
      unique case (disp_req_i.fu_data.lsu_op)
        LsuOpStoreByte,
        LsuOpLoadByte,
        LsuOpLoadByteUnsigned,
        LsuOpFpStoreByte,
        LsuOpFpLoadByte: begin
          ls_size = schnizo_pkg::Byte;
        end
        LsuOpStoreHalf,
        LsuOpLoadHalf,
        LsuOpLoadHalfUnsigned,
        LsuOpFpStoreHalf,
        LsuOpFpLoadHalf: begin
          ls_size = schnizo_pkg::HalfWord;
        end
        LsuOpStoreWord,
        LsuOpLoadWord,
        LsuOpFpStoreWord,
        LsuOpFpLoadWord: begin
          ls_size = schnizo_pkg::Word;
        end
        LsuOpFpStoreDouble,
        LsuOpFpLoadDouble: begin
          ls_size = schnizo_pkg::Double;
        end
        default: ls_size = schnizo_pkg::Byte;
      endcase
    end

    assign ls_amo = reqrsp_pkg::AMONone; // TODO: no atomic support yet

    // Unaligned Address Check
    always_comb begin
      lsu_addr_misaligned_o = 1'b0;
      unique case (ls_size)
        HalfWord: if (lsu_addr[0] != 1'b0)     lsu_addr_misaligned_o = 1'b1;
        Word:     if (lsu_addr[1:0] != 2'b00)  lsu_addr_misaligned_o = 1'b1;
        Double:   if (lsu_addr[2:0] != 3'b000) lsu_addr_misaligned_o = 1'b1;
        default:  lsu_addr_misaligned_o = 1'b0;
      endcase
    end

    snitch_lsu #(
      .AddrWidth          (AddrWidth),
      .DataWidth          (DataWidth),
      .dreq_t             (dreq_t),
      .drsp_t             (drsp_t),
      .tag_t              (result_tag_t),
      .NumOutstandingMem  (NumIntOutstandingMem),
      .NumOutstandingLoads(NumIntOutstandingLoads),
      .Caq                (CaqEn),
      .CaqDepth           (CaqDepth),
      .CaqTagWidth        (CaqTagWidth),
      .CaqRespSrc         (1'b0),
      .CaqRespTrackSeq    (1'b0)
    ) i_rs_lsu (
      .clk_i,
      .rst_i,
      // The request
      .lsu_qtag_i   (input_tag),
      .lsu_qwrite_i (is_store),
      .lsu_qsigned_i(is_signed),
      .lsu_qsize_i  (ls_size),
      .lsu_qamo_i   (ls_amo),
      .lsu_qrepd_i  (1'b0), // it is no sequencer repetition -> set to 1 during LEP?
      .lsu_qaddr_i  (lsu_addr), // Address to load from / store to
      .lsu_qdata_i  (lsu_store_data), // The data to store
      .lsu_qvalid_i (lsu_issue_valid), // valid for request
      .lsu_qready_o (lsu_issue_ready), // ready for request
      // The response
      .lsu_pdata_o  (lsu_result), // the loaded data
      .lsu_ptag_o   (result_tag), // the tag to the loaded data
      .lsu_perror_o (/* ignored for the moment */),
      .lsu_pvalid_o (lsu_result_valid), // the valid for the loaded data. only asserted to retire loads
      .lsu_pready_i (lsu_result_ready), // the ready for the loaded data
      .lsu_empty_o  (lsu_empty_o), // empty signal to wait on for a flush

      // Consistency address queue
      .caq_qaddr_i  (caq_addr_i),
      .caq_qwrite_i (caq_is_fp_store_i),
      .caq_qvalid_i (caq_req_valid_i),
      .caq_qready_o (caq_req_ready_o),
      .caq_pvalid_i (caq_rsp_valid_i),
      .caq_pvalid_o (caq_rsp_valid_o), // unconnected for the integer LSU
      // The actual memory interface
      .data_req_o   (lsu_data_req_o),
      .data_rsp_i   (lsu_data_rsp_i)
    );

    // Output assignments will change in FREP mode
    assign result_o = lsu_result;
    assign result_tag_o = result_tag;
    // Result handshake
    assign result_valid_o = lsu_result_valid;
    assign lsu_result_ready = result_ready_i;
  end else begin : gen_tieoff_lsu
    assign lsu_addr_misaligned_o = 1'b0;
    assign lsu_empty_o = 1'b0;
    assign caq_rsp_valid_o = 1'b0;
    assign caq_req_ready_o = 1'b0;

    assign lsu_store_data = '0;
    assign lsu_addr = '0;
    assign is_store = '0;
    assign is_signed = '0;
    assign ls_size = schnizo_pkg::Word;
    assign ls_amo = reqrsp_pkg::AMONone;
    assign input_tag = '0;
    assign result_tag = '0;
    assign lsu_issue_valid = '0;
    assign lsu_issue_ready = '0;
    assign lsu_result_valid = '0;
    assign  lsu_result_ready = '0;
    assign lsu_result = '0;
  end

  // ---------------------------
  // FPU
  // ---------------------------
  // We decode the rest of the instruction in the FPU as it is specific to the chosen FPU.
  logic fpu_issue_valid, fpu_issue_ready;
  logic fpu_result_valid, fpu_result_ready;

  logic [FLEN-1:0] fpu_result;
  if (Fu == schnizo_pkg::FPU) begin : gen_fpu

    assign fpu_issue_valid = disp_req_valid_i;
    assign disp_req_ready_o = fpu_issue_ready;
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
      .instr_tag_t      (result_tag_t)
    ) i_rs_fpu (
      .clk_i,
      .rst_ni(~rst_i),

      .hart_id_i   (hart_id_i),
      .op_i        (disp_req_i.fu_data.fpu_op),
      .rs1_i       (disp_req_i.fu_data.operand_a),
      .rs2_i       (disp_req_i.fu_data.operand_b),
      .rs3_i       (disp_req_i.fu_data.imm),
      .round_mode_i(disp_req_i.fu_data.fpu_rnd_mode),
      .fmt_src_i   (disp_req_i.fu_data.fpu_fmt_src),
      .fmt_dst_i   (disp_req_i.fu_data.fpu_fmt_dst),
      .tag_i       (disp_req_i.tag),
      // Input Handshake
      .in_valid_i  (fpu_issue_valid),
      .in_ready_o  (fpu_issue_ready),
      // Output signals
      .result_o    (fpu_result),
      .status_o    (fpu_status_o),
      .tag_o       (result_tag_o),
      // Output handshake
      .out_valid_o (fpu_result_valid),
      .out_ready_i (fpu_result_ready)
    );

    assign result_o = fpu_result;

    // Result handshake
    assign result_valid_o = fpu_result_valid;
    assign fpu_result_ready = result_ready_i;
  end else begin : gen_tieoff_fpu
    assign fpu_status_o = '0;
    assign fpu_issue_valid = '0;
    assign fpu_issue_ready = '0;
    assign fpu_result_valid = '0;
    assign fpu_result_ready = '0;
  end

endmodule
