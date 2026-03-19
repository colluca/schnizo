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
module schnova_dispatcher import schnizo_pkg::*; #(
  // Enable the superscalar feature
  parameter bit          EnableFrep  = 1,
  parameter int unsigned PipeWidth       = 1,
  /// Size of both int and fp register file
  parameter int unsigned RegAddrSize = 5,
  parameter int unsigned NofAlus     = 1,
  parameter int unsigned NofLsus     = 1,
  parameter int unsigned NofFpus     = 1,
  parameter type         instr_dec_t = logic,
  parameter type         rmt_entry_t = logic,
  parameter type         phy_id_t    = logic,
  parameter type         disp_req_t  = logic,
  parameter type         disp_rsp_t  = logic,
  parameter type         producer_id_t = logic,
  parameter type         rs_id_t       = logic,
  parameter type         rename_data_t = logic,
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
  input  logic [32*PipeWidth-1:0]  instr_fetch_data_i,
  input  logic [PipeWidth-1:0]     dispatch_valid_i,
  output logic [PipeWidth-1:0]     dispatch_ready_o,
  input  logic [PipeWidth-1:0]     instr_exec_commit_i,

  // From rename stage
  input  rename_data_t [PipeWidth-1:0] rename_info_i,
  output sb_disp_data_t [PipeWidth-1:0] sb_disp_data_o,

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

  // ---------------------------
  // Virtual RS ID generation
  // ---------------------------
  // We assume the CSR, MULDIV and DMA to have a virtual reservation station
  // with one slot for not. This is needed, since we use the RMT as a
  // scoreboard in scalar mode.
  localparam integer unsigned RsIdOffset = NofAlus + NofLsus + NofFpus;
  localparam integer unsigned RsCsrId = RsIdOffset;
  localparam integer unsigned RsMuldivId = RsCsrId + 1;
  localparam integer unsigned RsDmaId = RsMuldivId + 1;

  // CSR producer id
  producer_id_t csr_producer;
  assign csr_producer = producer_id_t'{
    slot_id: '0, // We only have one
    rs_id:   rs_id_t'(RsCsrId)
  };

  // MULDIV producer id
  producer_id_t muldiv_producer;
  assign muldiv_producer = producer_id_t'{
    slot_id: '0, // We only have one
    rs_id:   rs_id_t'(RsMuldivId)
  };

  // DMA producer id
  producer_id_t dma_producer;
  assign dma_producer = producer_id_t'{
    slot_id: '0, // We only have one
    rs_id:   rs_id_t'(RsDmaId)
  };

  ////////////////////////
  // Request generation //
  ////////////////////////

  // Read from RMT (register map table) and include the data in the dispatch request

  rmt_entry_t no_mapping;
  assign no_mapping = '{
    producer:    '0,
    valid: 1'b0
  };

  rmt_entry_t current_dest_entry;
  // TODO (soderma): Remove this
  // Not needed at this point
  assign current_dest_entry = no_mapping;

  always_comb begin : dispatch_generation
    disp_req_o = '0;
    disp_req_o.fu_data = instr_fu_data_i[0];

    // Operand indfo
    disp_req_o.producer_op_a = no_mapping;
    disp_req_o.producer_op_b = no_mapping;
    disp_req_o.producer_op_c = no_mapping;

    // current destination producer
    // TODO(colluca): the comment correctly calls it "current destination producer".
    //                Align LHS signal name.
    disp_req_o.current_producer_dest = current_dest_entry;

    // generate the tag
    disp_req_o.tag.producer_id    = fu_response.producer;
    disp_req_o.tag.dest_reg       = instr_dec_i[0].rd;
    disp_req_o.tag.dest_reg_is_fp = instr_dec_i[0].rd_is_fp;
    disp_req_o.tag.is_branch      = instr_dec_i[0].is_branch;
    disp_req_o.tag.is_jump        = instr_dec_i[0].is_jal | instr_dec_i[0].is_jalr;
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
      schnizo_pkg::MUL,
      schnizo_pkg::CTRL_FLOW: begin
        // always select ALU0 for branch and MUL instructions
        alu_disp_req_valid_o[0] = dispatch_valid_i[0];
      end
      schnizo_pkg::ALU: begin
        alu_disp_req_valid_o[alu_idx] = dispatch_valid_i[0];
      end
      schnizo_pkg::LOAD,
      schnizo_pkg::STORE: begin
        lsu_disp_req_valid_o[lsu_idx] = dispatch_valid_i[0];
      end
      schnizo_pkg::CSR : begin
        csr_disp_req_valid_o = dispatch_valid_i[0];
      end
      schnizo_pkg::FPU: begin
        fpu_disp_req_valid_o[fpu_idx] = dispatch_valid_i[0];
      end
      schnizo_pkg::MULDIV: begin
        acc_disp_req_valid_o = dispatch_valid_i[0];
        acc_req_o.addr         = snitch_pkg::IPU; // TODO: use schnizo defined address.
        acc_req_o.data_arga    = instr_fu_data_i[0].operand_a;
        acc_req_o.data_argb    = instr_fu_data_i[0].operand_b;
        acc_req_o.data_argc    = '0; // unused for shared muldiv
      end
      schnizo_pkg::DMA: begin
        acc_disp_req_valid_o = dispatch_valid_i[0];
        acc_req_o.addr         = snitch_pkg::DMA_SS; // TODO: use schnizo defined address.
        acc_req_o.data_arga    = instr_fu_data_i[0].operand_a;
        acc_req_o.data_argb    = instr_fu_data_i[0].operand_b;
        acc_req_o.data_argc    = '0; // unused for DMA
      end
      schnizo_pkg::NONE: begin
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
      schnizo_pkg::MUL,
      schnizo_pkg::CTRL_FLOW: begin
        // always select ALU0 for branch and MUL instructions
        fu_response = alu_disp_rsp_i[0];
        fu_ready    = alu_disp_req_ready_i[0];
        fu_rs_full  = alu_rs_full_i[0];
      end
      schnizo_pkg::ALU: begin
        fu_response = alu_disp_rsp_i[alu_idx];
        fu_ready    = alu_disp_req_ready_i[alu_idx];
        fu_rs_full  = alu_rs_full_i[alu_idx];
      end
      schnizo_pkg::LOAD,
      schnizo_pkg::STORE: begin
        // per default take the non consistent mode.
        fu_response = lsu_disp_rsp_i[lsu_idx];
        fu_ready    = lsu_disp_req_ready_i[lsu_idx];
        fu_rs_full  = lsu_rs_full_i[lsu_idx];
      end
      schnizo_pkg::CSR : begin
        // We can map the virtual producer here
        // this is only needed for the scalar mode
        // so that the RMT can work as a scoreboard
        fu_response = disp_rsp_t'{
          producer: csr_producer
        };
        fu_ready = csr_disp_req_ready_i;
      end
      schnizo_pkg::FPU: begin
        fu_response = fpu_disp_rsp_i[fpu_idx];
        fu_ready    = fpu_disp_req_ready_i[fpu_idx];
        fu_rs_full  = fpu_rs_full_i[fpu_idx];
      end
      schnizo_pkg::MULDIV: begin
        // We can map the virtual producer here
        // this is only needed for the scalar mode
        // so that the RMT can work as a scoreboard
        fu_response = disp_rsp_t'{
          producer: muldiv_producer
        };
        fu_ready = acc_disp_req_ready_i;
      end
      schnizo_pkg::DMA: begin
        // We can map the virtual producer here
        // this is only needed for the scalar mode
        // so that the RMT can work as a scoreboard
        fu_response = disp_rsp_t'{
          producer: dma_producer
        };
        fu_ready = acc_disp_req_ready_i;
      end
      schnizo_pkg::NONE: begin
        // No FU selected, do nothing. Signal ready to controller.
        // But we must stall if there is an ongoing FREP loop.
        // TODO (sorderma): Why do we have to stall in that case
        fu_ready = ~en_superscalar_i;
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

  assign dispatched = instr_exec_commit_i[0] & fu_ready;

  // Signal back the dispatch
  always_comb begin
    for (int unsigned i = 0; i < PipeWidth; i++) begin
      if (i == 0) begin
        dispatch_ready_o[i] = dispatched;
      end else begin
        dispatch_ready_o[i] = 1'b0;
      end
    end
  end

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
  // Generate the scroboard dispatch data //
  //////////////////////////////////////////
  always_comb begin : write_rmt
    // Forward the new destination mappings to the rename stage
    for (int unsigned i = 0; i < PipeWidth; i++) begin
        sb_disp_data_o[i].rd             = rename_info_i[i].phy_reg_dest_new;        
        sb_disp_data_o[i].rd_is_fp       = instr_dec_i[i].rd_is_fp;
        sb_disp_data_o[i].rs1            = rename_info_i[i].phy_reg_op_a; 
        sb_disp_data_o[i].rs1_is_fp      = instr_dec_i[i].rs1_is_fp;
        sb_disp_data_o[i].rs2            = rename_info_i[i].phy_reg_op_b; 
        sb_disp_data_o[i].rs2_is_fp      = instr_dec_i[i].rs2_is_fp;
        sb_disp_data_o[i].rs3            = rename_info_i[i].phy_reg_op_c;
        sb_disp_data_o[i].use_imm_as_rs3 = instr_dec_i[i].use_imm_as_rs3;
    end
  end
endmodule
