// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"

// The dispatcher module.
//
// Accesses the RMT to augment the dispatch requests with the relevant data and routes the
// dispatch requests to the different functional units. It selects the FU type based on the
// decoded instruction. If more than one FU of the same type is available, it further selects the
// specific FU of that type to dispatch the instruction to.
// It itself instantiates the RMT and updates it based on the dispatch and write back information.
module schnova_dispatcher import schnova_pkg::*; #(
  // Enable the superscalar feature
  parameter bit          EnableFrep  = 1,
  parameter int unsigned PipeWidth       = 1,
  /// Size of both int and fp register file
  parameter int unsigned RegAddrSize = 5,
  parameter int unsigned NofAlus     = 1,
  parameter int unsigned NofLsus     = 1,
  parameter int unsigned NofFpus     = 1,
  parameter int unsigned RobTagWidth = 1,
  parameter type         instr_dec_t = logic,
  parameter type         rmt_entry_t = logic,
  parameter type         phy_id_t    = logic,
  parameter type         disp_req_t  = logic,
  parameter type         disp_rsp_t  = logic,
  parameter type         producer_id_t = logic,
  parameter type         rs_id_t       = logic,
  parameter type         reg_map_t = logic,
  parameter type         fu_data_t   = logic,
  parameter type         acc_req_t   = logic,
  parameter type         sb_disp_data_t = logic
) (
  input  logic         clk_i,
  input  logic         rst_i,
  input  logic         en_superscalar_i,
  // Handshake to dispatch instruction consisting of instr_dec_i and instr_fu_data_i
  input  instr_dec_t [PipeWidth-1:0] instr_dec_i,
  input  fu_data_t   [PipeWidth-1:0] instr_fu_data_i,
  input  logic [32*PipeWidth-1:0]    instr_fetch_data_i,
  input  logic                       dispatch_valid_i,
  output logic                       dispatch_ready_o,
  input  logic                       instr_exec_commit_i,

  input  logic [PipeWidth-1:0]         instr_valid_i,
  input  logic [$clog2(PipeWidth):0]   instr_valid_count_i,
  input  logic [PipeWidth-1:0]         instr_rename_gpr_valid_i,
  input  logic [$clog2(PipeWidth):0]   instr_rename_gpr_count_i,
  input  logic [PipeWidth-1:0]         instr_rename_fpr_valid_i,
  input  logic [$clog2(PipeWidth):0]   instr_rename_fpr_count_i,

  // From rename stage
  input  reg_map_t [PipeWidth-1:0] reg_map_i,
  output sb_disp_data_t [PipeWidth-1:0] sb_disp_data_o,

  // From/to ROB
  output logic                                 rob_push_o,
  output logic [$clog2(PipeWidth):0]           rob_push_count_o,
  output phy_id_t [PipeWidth-1:0]              rob_phy_reg_rd_old_o,
  output logic    [PipeWidth-1:0]              rob_phy_reg_rd_old_is_fp_o,
  input logic [PipeWidth-1:0][RobTagWidth-1:0] rob_idx_i,

  // Handshake to all possible FUs. Each FU has own ready/valid interface.
  output disp_req_t disp_req_o,
  // Each FU has a response which must be valid at dispatch request handshake.
  // ALU
  output logic      [NofAlus-1:0] alu_disp_req_valid_o,
  input  logic      [NofAlus-1:0] alu_disp_req_ready_i,
  input  disp_rsp_t [NofAlus-1:0] alu_disp_rsp_i,
  input  logic      [NofAlus-1:0] alu_rs_full_i,

  // LSU
  output logic      [NofLsus-1:0] lsu_disp_req_valid_o,
  input  logic      [NofLsus-1:0] lsu_disp_req_ready_i,
  input  disp_rsp_t [NofLsus-1:0] lsu_disp_rsp_i,
  input  logic      [NofLsus-1:0] lsu_rs_full_i,

  // Handshake to the CSR FU. There is no response as it does not have a reservation station.
  output logic csr_disp_req_valid_o,
  input  logic csr_disp_req_ready_i,

  // FPU
  output logic      [NofFpus-1:0] fpu_disp_req_valid_o,
  input  logic      [NofFpus-1:0] fpu_disp_req_ready_i,
  input  disp_rsp_t [NofFpus-1:0] fpu_disp_rsp_i,
  input  logic      [NofFpus-1:0] fpu_rs_full_i,

  // Handshake to the accelerator interface
  output acc_req_t acc_req_o,
  output logic     acc_disp_req_valid_o,
  input  logic     acc_disp_req_ready_i,
  // The accelerator response is routed directly to the write back.

  // RS control signals
  // Asserted if the RSS are cleared synchronously.
  input  logic        restart_i,
  // Memory consistency mode during FREP loop
  input frep_mem_cons_mode_e frep_mem_cons_mode_i,
  // Asserted if the currently selected FU for the instruction does not have an empty RSS.
  output logic        rs_full_o
);
  localparam int unsigned NofAlusW = cf_math_pkg::idx_width(NofAlus);
  localparam int unsigned NofLsusW = cf_math_pkg::idx_width(NofLsus);
  localparam int unsigned NofFpusW = cf_math_pkg::idx_width(NofFpus);

  ////////////////////////
  // Request generation //
  ////////////////////////

  // The dispatch request contains
  // 1) The physical register mappings of the instruction
  // 2) The data if it is already valid in the physical register
  // 3) The instruction as well as its tag

  // TODO(soderma): Extend to superscalar
  always_comb begin : dispatch_generation
    disp_req_o = '0;
    disp_req_o.fu_data = instr_fu_data_i[0];

    // Forward the physical register mapings
    disp_req_o.phy_reg_op_a = reg_map_i[0].phy_reg_rs1;
    disp_req_o.phy_reg_op_b = reg_map_i[0].phy_reg_rs2;
    disp_req_o.phy_reg_op_c = reg_map_i[0].phy_reg_rs3;
    disp_req_o.phy_reg_dest  = reg_map_i[0].phy_reg_rd_new;

    // If the operand has to be fetched from the PRF, we set it as invalid
    // if it is an immediate it is already sent with the dispatch request and
    // is therefore valid
    disp_req_o.is_op_a_valid = instr_dec_i[0].use_pc_as_op_a |
                               instr_dec_i[0].use_rs1addr_as_op_a;

    disp_req_o.is_op_b_valid = (instr_dec_i[0].fu == schnova_pkg::ALU ||
                                instr_dec_i[0].fu == schnova_pkg::CTRL_FLOW) &&
                                instr_dec_i[0].use_imm_as_op_b &&
                                !instr_dec_i[0].is_branch;

    disp_req_o.is_op_c_valid = ~instr_dec_i[0].use_imm_as_rs3;

    disp_req_o.is_op_a_fp = instr_dec_i[0].rs1_is_fp;
    disp_req_o.is_op_b_fp = instr_dec_i[0].rs2_is_fp;

    // generate the tag
    disp_req_o.tag.producer_id    = fu_response.producer;
    disp_req_o.tag.dest_reg       = en_superscalar_i ? reg_map_i[0].phy_reg_rd_new
                                                     : reg_map_i[0].phy_reg_rd_old;
    disp_req_o.tag.dest_reg_is_fp = instr_dec_i[0].rd_is_fp;
    disp_req_o.tag.is_branch      = instr_dec_i[0].is_branch;
    disp_req_o.tag.is_jump        = instr_dec_i[0].is_jal | instr_dec_i[0].is_jalr;
    disp_req_o.tag.rob_tag        = rob_idx_i[0];
  end

  //////////////////
  // FU selection //
  //////////////////
  // TODO(colluca): try to make this whole part independent on the type of functional units
  // instantiated

  // Signal valid to the FU we want the instruction to dispatch into.
  // Select the appropriate response channel.

  logic       fu_ready;
  logic       fu_rs_full;
  disp_rsp_t  fu_response;
  logic       dispatched;

  // FU selection counters
  logic [NofAlusW-1:0] alu_idx;
  logic [NofAlusW-1:0] alu_idx_raw;
  logic [NofLsusW-1:0] lsu_idx;
  logic [NofLsusW-1:0] lsu_idx_raw;
  logic [NofFpusW-1:0] fpu_idx;
  logic [NofFpusW-1:0] fpu_idx_raw;

  // Demux the dispatch request to the selected FU.
  // This FU selection must occur always independently of the validity of the instruction and it
  // may never combine any signals with the valid signal. This is required because this block can
  // generate errors which will kill the instruction and therefore a loop would be created.
  always_comb begin : fu_selection_req
    alu_disp_req_valid_o = '0;
    lsu_disp_req_valid_o = '0;
    csr_disp_req_valid_o = 1'b0;
    fpu_disp_req_valid_o = '0;
    acc_disp_req_valid_o = 1'b0;

    acc_req_o         = '0;
    acc_req_o.id      = instr_dec_i[0].rd; // TODO: currently only GPR address supported
    // TODO (soderma): In superscalar this should be the acc instruction fetch data
    acc_req_o.data_op = instr_fetch_data_i[31:0];

    unique case (instr_dec_i[0].fu)
      schnova_pkg::MUL,
      schnova_pkg::CTRL_FLOW: begin
        // always select ALU0 for branch and MUL instructions
        alu_disp_req_valid_o[0] = dispatch_valid_i;
      end
      schnova_pkg::ALU: begin
        alu_disp_req_valid_o[alu_idx] = dispatch_valid_i;
      end
      schnova_pkg::LOAD,
      schnova_pkg::STORE: begin
        lsu_disp_req_valid_o[lsu_idx] = dispatch_valid_i;
      end
      schnova_pkg::CSR : begin
        csr_disp_req_valid_o = dispatch_valid_i;
      end
      schnova_pkg::FPU: begin
        fpu_disp_req_valid_o[fpu_idx] = dispatch_valid_i;
      end
      schnova_pkg::MULDIV: begin
        acc_disp_req_valid_o = dispatch_valid_i;
        acc_req_o.addr         = snitch_pkg::IPU; // TODO: use schnova defined address.
        acc_req_o.data_arga    = instr_fu_data_i[0].operand_a;
        acc_req_o.data_argb    = instr_fu_data_i[0].operand_b;
        acc_req_o.data_argc    = '0; // unused for shared muldiv
      end
      schnova_pkg::DMA: begin
        acc_disp_req_valid_o = dispatch_valid_i;
        acc_req_o.addr         = snitch_pkg::DMA_SS; // TODO: use schnova defined address.
        acc_req_o.data_arga    = instr_fu_data_i[0].operand_a;
        acc_req_o.data_argb    = instr_fu_data_i[0].operand_b;
        acc_req_o.data_argc    = '0; // unused for DMA
      end
      schnova_pkg::NONE: begin
        // No FU selected, do nothing.
      end
      default: begin
        // CRASH - should never happen as long as decoder returns valid decoding.
        // TODO: handle crash
      end
    endcase
  end

  // Mux the response from the selected FU
  always_comb begin : fu_selection_rsp
    fu_response = '0;
    fu_ready    = 1'b0;
    fu_rs_full  = 1'b0;

    unique case (instr_dec_i[0].fu)
      schnova_pkg::MUL,
      schnova_pkg::CTRL_FLOW: begin
        // always select ALU0 for branch and MUL instructions
        fu_response = alu_disp_rsp_i[0];
        fu_ready    = alu_disp_req_ready_i[0];
        fu_rs_full  = alu_rs_full_i[0];
      end
      schnova_pkg::ALU: begin
        fu_response = alu_disp_rsp_i[alu_idx];
        fu_ready    = alu_disp_req_ready_i[alu_idx];
        fu_rs_full  = alu_rs_full_i[alu_idx];
      end
      schnova_pkg::LOAD,
      schnova_pkg::STORE: begin
        // per default take the non consistent mode.
        fu_response = lsu_disp_rsp_i[lsu_idx];
        fu_ready    = lsu_disp_req_ready_i[lsu_idx];
        fu_rs_full  = lsu_rs_full_i[lsu_idx];
      end
      schnova_pkg::CSR : begin
        // There is no response because there is no reservation station.
        fu_ready = csr_disp_req_ready_i;
      end
      schnova_pkg::FPU: begin
        fu_response = fpu_disp_rsp_i[fpu_idx];
        fu_ready    = fpu_disp_req_ready_i[fpu_idx];
        fu_rs_full  = fpu_rs_full_i[fpu_idx];
      end
      schnova_pkg::MULDIV: begin
        // no dispatch response
        fu_ready = acc_disp_req_ready_i;
      end
      schnova_pkg::DMA: begin
        // no dispatch response
        fu_ready = acc_disp_req_ready_i;
      end
      schnova_pkg::NONE: begin
        // There is no FU, so we always signal ready
        fu_ready = 1'b1;
      end
      default: begin
        // CRASH - should never happen as long as decoder returns valid decoding.
        // TODO: handle crash
      end
    endcase
  end

  ////////////////////
  // Dispatch logic //
  ////////////////////

  assign dispatched = instr_exec_commit_i & fu_ready;

  // Signal back the dispatch
  assign dispatch_ready_o = dispatched;

  // Asserted if the currently selected FU has no empty RSS.
  assign rs_full_o = fu_rs_full;

  // TODO(colluca): arbitration logic to select FU within those of a single type is the same
  //                for all types, with minor differences that can be parameterized. Move to
  //                a separate module.
  if (EnableFrep) begin : gen_fu_sel_cnts
    // ---------------------------
    // FU selection counters
    // ---------------------------
    logic alu_idx_inc;
    logic lsu_idx_inc;
    logic fpu_idx_inc;
    logic alu_idx_reset;
    logic lsu_idx_reset;
    logic fpu_idx_reset;

    // Only select the counters during FREP. Without this the first instruction after LEP would be
    // executed on the "next" FU instead of the zero-th.
    assign alu_idx = (en_superscalar_i) ? alu_idx_raw : '0;
    assign lsu_idx = (en_superscalar_i) ? lsu_idx_raw : '0;
    assign fpu_idx = (en_superscalar_i) ? fpu_idx_raw : '0;

    // Reset at wrap around at dispatch or when switching to LCP2 or when restarting LxP
    assign alu_idx_reset = ((alu_idx_raw == ((NofAlus[NofAlusW-1:0])-1)) && alu_idx_inc)
                          || restart_i;
    assign lsu_idx_reset = ((lsu_idx_raw == ((NofLsus[NofLsusW-1:0])-1)) && lsu_idx_inc)
                          || restart_i;
    assign fpu_idx_reset = ((fpu_idx_raw == ((NofFpus[NofFpusW-1:0])-1)) && fpu_idx_inc)
                          || restart_i;

    always_comb begin : dispatch_fu_selection
      alu_idx_inc = 1'b0;
      lsu_idx_inc = 1'b0;
      fpu_idx_inc = 1'b0;

      if (en_superscalar_i) begin
        // Increment the counter if we dispatched into the FU during LCP
        alu_idx_inc = |(alu_disp_req_valid_o & alu_disp_req_ready_i);
        lsu_idx_inc = |(lsu_disp_req_valid_o & lsu_disp_req_ready_i);
        // Do not increment index if we want serialized memory accesses
        if (frep_mem_cons_mode_i inside {FrepMemSerialized}) begin
          lsu_idx_inc = 1'b0;
        end
        fpu_idx_inc = |(fpu_disp_req_valid_o & fpu_disp_req_ready_i);
      end
    end

    counter #(
      .WIDTH          (NofAlusW),
      .STICKY_OVERFLOW(0)
    ) i_alu_idx_counter (
      .clk_i,
      .rst_ni    (~rst_i),
      .clear_i   (alu_idx_reset),
      .en_i      (alu_idx_inc),
      .load_i    ('0),
      .down_i    ('0),
      .d_i       ('0),
      .q_o       (alu_idx_raw),
      .overflow_o()
    );

    counter #(
      .WIDTH          (NofLsusW),
      .STICKY_OVERFLOW(0)
    ) i_lsu_idx_counter (
      .clk_i,
      .rst_ni    (~rst_i),
      .clear_i   (lsu_idx_reset),
      .en_i      (lsu_idx_inc),
      .load_i    ('0),
      .down_i    ('0),
      .d_i       ('0),
      .q_o       (lsu_idx_raw),
      .overflow_o()
    );

    counter #(
      .WIDTH          (NofFpusW),
      .STICKY_OVERFLOW(0)
    ) i_fpu_idx_counter (
      .clk_i,
      .rst_ni    (~rst_i),
      .clear_i   (fpu_idx_reset),
      .en_i      (fpu_idx_inc),
      .load_i    ('0),
      .down_i    ('0),
      .d_i       ('0),
      .q_o       (fpu_idx_raw),
      .overflow_o()
    );
  end else begin : gen_fix_fu_sel
    // Always take the first FU
    assign alu_idx     = '0;
    assign lsu_idx     = '0;
    assign fpu_idx     = '0;
    assign alu_idx_raw = '0;
    assign lsu_idx_raw = '0;
    assign fpu_idx_raw = '0;
  end

  //////////////////////////////////////////
  // Generate the ROB allocation requests //
  //////////////////////////////////////////

  logic [$clog2(PipeWidth):0] alloc_idx;

  // The incoming dispatch request will only be valid
  // if we have enough ROB entries otherwise the controller
  // would stall the dispatch by forcing the valid to zero.

  // The amount of new entries we allocated, is the amount of instructions
  // that have to be allocated
  assign rob_push_count_o = instr_rename_gpr_count_i + instr_rename_fpr_count_i;

  // We only allocate new entries in the ROB in superscalar mode
  // The allocation happens at a successfull dispatch
  assign rob_push_o = dispatched & (rob_push_count_o != '0) & en_superscalar_i;

  // The ROB assumes that the incoming data is valid in a block
  // that means all the mappings that should be allocated are in contiguous elements
  // The ROB will then allocate an entry for rob_phy_reg_rd_old_o[0] at the tail pointer
  // (tail_ptr) and rob_phy_reg_rd_old_o[1] at tail_ptr + 1.
  always_comb begin : map_phy_reg_rd_old
    // Per default we don't assign a mapping
    rob_phy_reg_rd_old_o = '0;
    rob_phy_reg_rd_old_is_fp_o = '0;

    alloc_idx = '0;
    for (int unsigned i = 0; i < PipeWidth; i++) begin
      if (instr_rename_gpr_valid_i[i]) begin
        rob_phy_reg_rd_old_o[alloc_idx] = reg_map_i[i].phy_reg_rd_old;

        alloc_idx = alloc_idx + 1;
      end else if (instr_rename_fpr_valid_i[i]) begin
        rob_phy_reg_rd_old_o[alloc_idx] = reg_map_i[i].phy_reg_rd_old;
        rob_phy_reg_rd_old_is_fp_o[alloc_idx] = 1'b1;

        alloc_idx = alloc_idx + 1;
      end
    end
  end

  //////////////////////////////////////////
  // Generate the scoreboard dispatch data //
  //////////////////////////////////////////

  always_comb begin : gen_scoreboard_update
    // Forward the new destination mappings to the rename stage
    for (int unsigned i = 0; i < PipeWidth; i++) begin
      // In scalar mode we don't perform renaming, so we use the old value stored in the rmt
        sb_disp_data_o[i].rd             = en_superscalar_i ? reg_map_i[i].phy_reg_rd_new
                                                            : reg_map_i[i].phy_reg_rd_old;
        sb_disp_data_o[i].rd_is_fp       = instr_dec_i[i].rd_is_fp;
        sb_disp_data_o[i].rs1            = reg_map_i[i].phy_reg_rs1;
        sb_disp_data_o[i].rs1_is_fp      = instr_dec_i[i].rs1_is_fp;
        sb_disp_data_o[i].rs2            = reg_map_i[i].phy_reg_rs2;
        sb_disp_data_o[i].rs2_is_fp      = instr_dec_i[i].rs2_is_fp;
        sb_disp_data_o[i].rs3            = reg_map_i[i].phy_reg_rs3;
        sb_disp_data_o[i].use_imm_as_rs3 = instr_dec_i[i].use_imm_as_rs3;
    end
  end

endmodule
