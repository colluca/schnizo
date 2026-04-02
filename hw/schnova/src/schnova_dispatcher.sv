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
  // Each FU has a response which must be valid at dispatch request handshake.
  // ALU
  output disp_req_t [NofAlus-1:0] alu_disp_reqs_o,
  output logic      [NofAlus-1:0] alu_disp_req_valid_o,
  input  logic      [NofAlus-1:0] alu_disp_req_ready_i,
  input  disp_rsp_t [NofAlus-1:0] alu_disp_rsp_i,
  input  logic      [NofAlus-1:0] alu_rs_full_i,

  // LSU
  output disp_req_t [NofLsus-1:0] lsu_disp_reqs_o,
  output logic      [NofLsus-1:0] lsu_disp_req_valid_o,
  input  logic      [NofLsus-1:0] lsu_disp_req_ready_i,
  input  disp_rsp_t [NofLsus-1:0] lsu_disp_rsp_i,
  input  logic      [NofLsus-1:0] lsu_rs_full_i,

  // Handshake to the CSR FU. There is no response as it does not have a reservation station.
  output disp_req_t csr_disp_req_o,
  output logic csr_disp_req_valid_o,
  input  logic csr_disp_req_ready_i,

  // FPU
  output disp_req_t [NofFpus-1:0] fpu_disp_reqs_o,
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
  input frep_mem_cons_mode_e frep_mem_cons_mode_i
);

  localparam int unsigned NofAlusW = cf_math_pkg::idx_width(NofAlus);
  localparam int unsigned NofLsusW = cf_math_pkg::idx_width(NofLsus);
  localparam int unsigned NofFpusW = cf_math_pkg::idx_width(NofFpus);
  localparam bit NofAlusIsPow2 = (NofAlus > 0) && ((NofAlus & (NofAlus - 1)) == 0);
  localparam bit NofLsusIsPow2 = (NofLsus > 0) && ((NofLsus & (NofLsus - 1)) == 0);
  localparam bit NofFpusIsPow2 = (NofFpus > 0) && ((NofFpus & (NofFpus - 1)) == 0);

  disp_req_t [PipeWidth-1:0] disp_req;

  logic [PipeWidth-1:0] dispatched_q, dispatched_d;
  `FFAR(dispatched_q, dispatched_d, '0, clk_i, rst_i);

  logic      [PipeWidth-1:0] fu_ready;
  disp_rsp_t [PipeWidth-1:0] fu_response;
  logic       dispatched;

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

  // Rob Tag
  logic [PipeWidth-1:0][RobTagWidth-1:0] rob_tag_d, rob_tag_q;
  `FFAR(rob_tag_q, rob_tag_d, '0, clk_i, rst_i);

  logic [PipeWidth-1:0] instr_dispatched;
z
  ////////////////////////
  // Request generation //
  ////////////////////////

  // The dispatch request contains
  // 1) The physical register mappings of the instruction
  // 2) The data if it is already valid in the physical register
  // 3) The instruction as well as its tag

  always_comb begin : dispatch_generation
    for (int unsigned i = 0; i < PipeWidth; i++) begin
      disp_req[i] = '0;
      disp_req[i].fu_data = instr_fu_data_i[i];

      // Forward the physical register mapings
      disp_req[i].phy_reg_op_a = reg_map_i[i].phy_reg_rs1;
      disp_req[i].phy_reg_op_b = reg_map_i[i].phy_reg_rs2;
      disp_req[i].phy_reg_op_c = reg_map_i[i].phy_reg_rs3;
      disp_req[i].phy_reg_dest  = reg_map_i[i].phy_reg_rd_new;

      // If the operand has to be fetched from the PRF, we set it as invalid
      // if it is an immediate it is already sent with the dispatch request and
      // is therefore valid
      disp_req[i].is_op_a_valid = instr_dec_i[i].use_pc_as_op_a |
                                  instr_dec_i[i].use_rs1addr_as_op_a;

      disp_req[i].is_op_b_valid = (instr_dec_i[i].fu == schnova_pkg::ALU ||
                                  instr_dec_i[i].fu == schnova_pkg::CTRL_FLOW) &&
                                  instr_dec_i[i].use_imm_as_op_b &&
                                  !instr_dec_i[i].is_branch;

      disp_req[i].is_op_c_valid = ~instr_dec_i[i].use_imm_as_rs3;

      // Forward the is fp flag for the source registers
      disp_req[i].is_op_a_fp = instr_dec_i[i].rs1_is_fp;
      disp_req[i].is_op_b_fp = instr_dec_i[i].rs2_is_fp;

      // generate the instruction tag
      disp_req[i].tag.producer_id    = fu_response[i].producer;
      disp_req[i].tag.dest_reg       = en_superscalar_i ? reg_map_i[i].phy_reg_rd_new
                                                          : reg_map_i[i].phy_reg_rd_old;
      disp_req[i].tag.dest_reg_is_fp = instr_dec_i[i].rd_is_fp;
      disp_req[i].tag.is_branch      = instr_dec_i[i].is_branch;
      disp_req[i].tag.is_jump        = instr_dec_i[i].is_jal | instr_dec_i[i].is_jalr;
      // If we have already dispatched some instructions we have to use the rob tag we saved
      // otherwise we can just use the rob tag coming from the ROB which are contiguous ROB
      // tags starating from the current tail pointer
      disp_req[i].tag.rob_tag        = (|dispatched_q) ? rob_tag_q[i] : rob_idx_i[i];
    end
  end

  //////////////////
  // FU selection //
  //////////////////

  // 1) For every instruction in the pipe, determine which FU type with an RS it needs

  logic [PipeWidth-1:0] disp_to_alu;
  logic [PipeWidth-1:0] disp_to_alu0;
  logic [PipeWidth-1:0] disp_to_lsu;
  logic [PipeWidth-1:0] disp_to_fpu;

  always_comb begin: identify_fu_type
    for (int unsigned i = 0; i < PipeWidth; i++) begin
      disp_to_alu0[i] = ((instr_dec_i[i].fu == schnova_pkg::MUL)       |
                        (instr_dec_i[i].fu == schnova_pkg::CTRL_FLOW)) &
                        instr_valid_i[i];
      disp_to_alu[i] = (instr_dec_i[i].fu == schnova_pkg::ALU) &
                        instr_valid_i[i];
      disp_to_lsu[i] =  ((instr_dec_i[i].fu == schnova_pkg::LOAD)  |
                        (instr_dec_i[i].fu == schnova_pkg::STORE)) &
                        instr_valid_i[i];
      disp_to_fpu[i] = (instr_dec_i[i].fu == schnova_pkg::FPU) &
                        instr_valid_i[i];
    end
  end

  // 2) Calculate the rank of the instruction for each FU type (Prefix Sum calculation)
  // i.e. if we have 3 ALU instructions in the same cycle, they will have the rank 0, 1 and 2 for the ALU FU selection.
  // This is used to select the FU port in case there are multiple FUs of the same type.
  logic [PipeWidth-1:0][$clog2(PipeWidth):0] alu_rank;
  logic [PipeWidth-1:0][$clog2(PipeWidth):0] lsu_rank;
  logic [PipeWidth-1:0][$clog2(PipeWidth):0] fpu_rank;

  always_comb begin: identify_fu_rank
    // Per default the rank of every instruction is 0
    alu_rank = '0;
    lsu_rank = '0;
    fpu_rank = '0;

    for (int unsigned i = 0; i < PipeWidth; i++) begin
      if (i == 0) begin
        // The first instruction always has the highest rank because there is no previous instruction that can have the same FU type.
        alu_rank[i] = '0;
        lsu_rank[i] = '0;
        fpu_rank[i] = '0;
      end else begin
        // We decrease the rank for every previous instruction that needs the same FU type.
        alu_rank[i] = disp_to_alu[i] ? alu_rank[i-1] + 1'b1 : alu_rank[i-1];
        lsu_rank[i] = disp_to_lsu[i] ? lsu_rank[i-1] + 1'b1 : lsu_rank[i-1];
        fpu_rank[i] = disp_to_fpu[i] ? fpu_rank[i-1] + 1'b1 : fpu_rank[i-1];
      end
    end
  end

  // 3) Select the FU of that type to dispatch to. If there is only one FU of that type, select it. If there are multiple, select the next one in a round robin fashion.
  logic [PipeWidth-1:0][NofAlusW-1:0] target_alu_port;
  logic [PipeWidth-1:0][NofLsusW-1:0] target_lsu_port;
  logic [PipeWidth-1:0][NofFpusW-1:0] target_fpu_port;

  if (NofAlusIsPow2) begin : gen_alu_port_pow2
    always_comb begin
      target_alu_port = '0;

      for (int unsigned i = 0; i < PipeWidth; i++) begin
        if (disp_to_alu[i] && (NofAlus > 1) && !disp_to_alu0[i]) begin
          target_alu_port[i] = alu_idx + alu_rank[i];
        end
      end
    end
  end else begin : gen_alu_port
    // Use 1 more bit to catch overflow
    logic [PipeWidth-1:0][NofAlusW:0] target_alu_port_unwrapped;
    always_comb begin
      target_alu_port = '0;
      for (int unsigned i = 0; i < PipeWidth; i++) begin
        if (disp_to_alu[i] && (NofAlus > 1) && !disp_to_alu0[i]) begin
          target_alu_port_unwrapped[i] = alu_idx + alu_rank[i];
          // Wrap around if the index exceeds the number of FUs
          if (target_alu_port_unwrapped[i] >= NofAlus) begin
            target_alu_port[i] = target_alu_port_unwrapped[i] - NofAlus;
          end else begin
            target_alu_port[i] = target_alu_port_unwrapped[i][NofAlusW-1:0];
          end
        end
      end
    end
  end

  if (NofLsusIsPow2) begin : gen_lsu_port_pow2
    always_comb begin
      target_lsu_port = '0;

      for (int unsigned i = 0; i < PipeWidth; i++) begin
        if (disp_to_lsu[i] &&
            (NofLsus > 1)  &&
            (frep_mem_cons_mode_i != FrepMemSerialized)) begin
          target_lsu_port[i] = lsu_idx + lsu_rank[i];
        end
      end
    end
  end else begin : gen_lsu_port
    // Use 1 more bit to catch overflow
    logic [PipeWidth-1:0][NofLsusW:0] target_lsu_port_unwrapped;
    always_comb begin
      target_lsu_port = '0;
      for (int unsigned i = 0; i < PipeWidth; i++) begin
        if (disp_to_lsu[i] &&
            (NofLsus > 1)  &&
            (frep_mem_cons_mode_i != FrepMemSerialized)) begin
          target_lsu_port_unwrapped[i] = lsu_idx + lsu_rank[i];
          // Wrap around if the index exceeds the number of FUs
          if (target_lsu_port_unwrapped[i] >= NofLsus) begin
            target_lsu_port[i] = target_lsu_port_unwrapped[i] - NofLsus;
          end else begin
            target_lsu_port[i] = target_lsu_port_unwrapped[i][NofLsusW-1:0];
          end
        end
      end
    end
  end

  if (NofFpusIsPow2) begin : gen_fpu_port_pow2
    always_comb begin
      target_fpu_port = '0;

      for (int unsigned i = 0; i < PipeWidth; i++) begin
        if (disp_to_fpu[i] && (NofFpus > 1)) begin
          target_fpu_port[i] = fpu_idx + fpu_rank[i];
        end
      end
    end
  end else begin : gen_fpu_port
    // Use 1 more bit to catch overflow
    logic [PipeWidth-1:0][NofFpusW:0] target_fpu_port_unwrapped;
    always_comb begin
      target_fpu_port = '0;
      for (int unsigned i = 0; i < PipeWidth; i++) begin
        if (disp_to_fpu[i] && (NofFpus > 1)) begin
          target_fpu_port_unwrapped[i] = fpu_idx + fpu_rank[i];
          // Wrap around if the index exceeds the number of FUs
          if (target_fpu_port_unwrapped[i] >= NofFpus) begin
            target_fpu_port[i] = target_fpu_port_unwrapped[i] - NofFpus;
          end else begin
            target_fpu_port[i] = target_fpu_port_unwrapped[i][NofFpusW-1:0];
          end
        end
      end
    end
  end

  // 4) Check for hazards
  // The instructions can have an hazard due to the following reasons:
  // - Dispatching happens in order to avoid deadlocks. Thus, if an older
  // has an hazard, younger instructions cannot be dispatched even if they themselves could be dispatched
  // - This instruction uses the same port as an older instruction that was not yet dispatched.
  logic [PipeWidth-1:0] instr_has_hazard;
  logic [NofAlus-1:0] port_claimed_alu;
  logic [NofLsus-1:0] port_claimed_lsu;
  logic [NofFpus-1:0] port_claimed_fpu;

  always_comb begin : hazard_detection
    // Per default no port is claimed and no instruciton has an hazard
    instr_has_hazard = '0;
    port_claimed_alu = '0;
    port_claimed_lsu = '0;
    port_claimed_fpu = '0;

    for (int unsigned i = 0; i < PipeWidth; i++) begin
      if (i == 0) begin
        // There are no younger instructions in this block
        // it never has a hazard since it is the first instruction
        // that has to be dispatched.
        instr_has_hazard[i] = 1'b0;
      end else begin
        // The instruction has an hazard if an older instruction has an hazard or
        // if an older instruction claimed the same port this instruction needs.
        // or if an older instruction was not yet dispatched in this cycle
        // we need to strictly enforce in order dispatch
        instr_has_hazard[i] =   instr_has_hazard[i-1]                                    ||
                                !instr_dispatched[i-1]                                   ||
                                ((disp_to_alu0[i] || disp_to_alu[i]) &&
                                port_claimed_alu[target_alu_port[i]])                    ||
                                (disp_to_lsu[i] && port_claimed_lsu[target_lsu_port[i]]) ||
                                (disp_to_fpu[i] && port_claimed_fpu[target_fpu_port[i]]);

        // Claim the port for this instruction if it was not already dispatched
        if (instr_valid_[i] && !dispatched_q[i]) begin
          if (disp_to_alu0[i]) begin
            port_claimed_alu[0] = 1'b1;
          end else if (disp_to_alu[i]) begin
            port_claimed_alu[target_alu_port[i]] = 1'b1;
          end

          if (disp_to_lsu[i]) begin
            port_claimed_lsu[target_lsu_port[i]] = 1'b1;
          end

          if (disp_to_fpu[i]) begin
            port_claimed_fpu[target_fpu_port[i]] = 1'b1;
          end
        end
      end
    end
  end

  // 5) Demux the dispatch requests to the selected FU.


  // Signal valid to the FU we want the instruction to dispatch into.
  // Select the appropriate response channel.
  always_comb begin : fu_selection_req
    alu_disp_req_valid_o = '0;
    lsu_disp_req_valid_o = '0;
    csr_disp_req_valid_o = 1'b0;
    fpu_disp_req_valid_o = '0;
    acc_disp_req_valid_o = 1'b0;

    alu_disp_reqs_o = '0;
    lsu_disp_reqs_o = '0;
    fpu_disp_reqs_o = '0;

    // Accelerator and CSR instructions are only allowed in scalar mode, hence we only have to consider the
    // the first instruction in the block for them.

    // Accelerator Instruction Request Selection
    acc_req_o         = '0;
    acc_req_o.id      = instr_dec_i[0].rd; // TODO (soderma): currently only GPR address supported
    acc_req_o.data_op = instr_fetch_data_i[31:0];

    if (instr_dec_i[0].fu == schnova_pkg::MULDIV) begin
      acc_disp_req_valid_o = dispatch_valid_i;
      acc_req_o.addr         = snitch_pkg::IPU; // TODO: use schnova defined address.
      acc_req_o.data_arga    = instr_fu_data_i[0].operand_a;
      acc_req_o.data_argb    = instr_fu_data_i[0].operand_b;
      acc_req_o.data_argc    = '0; // unused for shared muldiv
    end else if (instr_dec_i[0].fu == schnova_pkg::DMA) begin
      acc_disp_req_valid_o = dispatch_valid_i;
      acc_req_o.addr         = snitch_pkg::DMA_SS; // TODO: use schnova defined address.
      acc_req_o.data_arga    = instr_fu_data_i[0].operand_a;
      acc_req_o.data_argb    = instr_fu_data_i[0].operand_b;
      acc_req_o.data_argc    = '0; // unused for DMA
    end

    // CSR Instruction Request Selection
    csr_disp_req_o = disp_req[0];
    if (instr_dec_i[0].fu == schnova_pkg::CSR) begin
      csr_disp_req_valid_o = dispatch_valid_i;
    end

    // Request selection for instructions with reservation stations
    for (int unsigned i = 0; i < PipeWidth; i++) begin
      if ((disp_to_alu0[i] || disp_to_alu[i]) && !instr_has_hazard[i] && !dispatched_q[i]) begin
        // always select ALU0 for branch and MUL instructions
        alu_disp_req_valid_o[target_alu_port[i]] = dispatch_valid_i;
        alu_disp_reqs_o[target_alu_port[i]] = disp_req[i];
      end else if (disp_to_lsu[i] && !instr_has_hazard[i] && !dispatched_q[i]) begin
        lsu_disp_req_valid_o[target_lsu_port[i]] = dispatch_valid_i;
        lsu_disp_reqs_o[target_lsu_port[i]] = disp_req[i];
      end else if (disp_to_fpu[i] && !instr_has_hazard[i] && !dispatched_q[i]) begin
        fpu_disp_req_valid_o[target_fpu_port[i]] = dispatch_valid_i;
        fpu_disp_reqs_o[target_fpu_port[i]] = disp_req[i];
      end
    end
  end

  // Mux the response from the selected FU
  always_comb begin : fu_selection_rsp
    fu_response = '0;
    fu_ready    = 1'b0;

    for (int unsigned i = 0; i < PipeWidth; i++) begin
      unique case (instr_dec_i[i].fu)
        schnova_pkg::MUL,
        schnova_pkg::CTRL_FLOW,
        schnova_pkg::ALU: begin
          // always select ALU0 for branch and MUL instructions
          fu_response[i] = alu_disp_rsp_i[target_alu_port[i]];
          fu_ready[i]    = alu_disp_req_ready_i[target_alu_port[i]] & !instr_has_hazard[i];
        end
        schnova_pkg::LOAD,
        schnova_pkg::STORE: begin
          // per default take the non consistent mode.
          fu_response[i] = lsu_disp_rsp_i[target_lsu_port[i]];
          fu_ready[i]    = lsu_disp_req_ready_i[target_lsu_port[i]] & !instr_has_hazard[i];
        end
        schnova_pkg::CSR : begin
          // There is no response because there is no reservation station.
          fu_ready[i] = csr_disp_req_ready_i;
        end
        schnova_pkg::FPU: begin
          fu_response[i] = fpu_disp_rsp_i[target_fpu_port[i]];
          fu_ready[i]    = fpu_disp_req_ready_i[target_fpu_port[i]] & !instr_has_hazard[i];
        end
        schnova_pkg::MULDIV: begin
          // no dispatch response
          fu_ready[i] = acc_disp_req_ready_i;
        end
        schnova_pkg::DMA: begin
          // no dispatch response
          fu_ready[i] = acc_disp_req_ready_i;
        end
        schnova_pkg::NONE: begin
          // There is no FU, so we always signal ready
          fu_ready[i] = 1'b1;
        end
        default: begin
          // CRASH - should never happen as long as decoder returns valid decoding.
          // TODO: handle crash
        end
      endcase
    end
  end

  ////////////////////
  // Dispatch logic //
  ////////////////////

  always_comb begin
    instr_dispatched = '0;
    dispatched_d = dispatched_q;

    for (int unsigned i = 0; i < PipeWidth; i++) begin
      // An instruction is dispatched if the functional unit
      //signals ready or it was already dispatched in a previous cycle
      instr_dispatched[i] = (instr_exec_commit_i & fu_ready[i]) | dispatched_q[i];
    end

    if (dispatched || restart_i) begin
      // If we dispatched all the instructions in this cycle we have to reset the state
      dispatched_d = '0;
    end else begin
      // We update the dispatched state for the instructions that are being dispatched in this cycle
      dispatched_d = instr_dispatched;
    end
  end

  // All instructions are successfully dispatched if all the instructions are being dispatched in this cycle
  // that are valid in the first place
  assign dispatched = (|instr_valid_i) & (&(instr_dispatched | ~instr_valid_i));

  // Signal back the dispatch
  assign dispatch_ready_o = dispatched;

  logic [$clog2(PipeWidth):0] alu_idx_inc_raw;
  logic [$clog2(PipeWidth):0] alu_idx_inc;
  logic [$clog2(PipeWidth):0] lsu_idx_inc_raw;
  logic [$clog2(PipeWidth):0] lsu_idx_inc;
  logic [$clog2(PipeWidth):0] fpu_idx_inc;

  // Calculate the increments for the FU selection counters
  popcount #(
    .INPUT_WIDTH(PipeWidth)
  ) i_alu_idx_inc_count (
    .data_i(disp_to_alu),
    .popcount_o(alu_idx_inc_raw)
  );

  popcount #(
    .INPUT_WIDTH(PipeWidth)
  ) i_lsu_idx_inc_count (
    .data_i(disp_to_lsu),
    .popcount_o(lsu_idx_inc_raw)
  );

  popcount #(
    .INPUT_WIDTH(PipeWidth)
  ) i_fpu_idx_inc_count (
    .data_i(disp_to_fpu),
    .popcount_o(fpu_idx_inc)
  );

  // In case we dispatched at least one instruction to ALU0 we have to increment the ALU index by 1
  assign alu_idx_inc = |disp_to_alu0  ? alu_idx_inc_raw + 1
                                      : alu_idx_inc_raw;

  // If we are in serialized mode, we dont increment the LSU index since all instructions get dispatched
  // to LSU0
  assign lsu_idx_inc = (frep_mem_cons_mode_i inside {FrepMemSerialized}) ? '0 : lsu_idx_inc_raw;

  // ---------------------------
  // FU selection counters
  // ---------------------------
  // Only select the counters during superscalar exectuion. Without this the first instruction after DEP would be
  // executed on the "next" FU instead of the zero-th.
  assign alu_idx = (en_superscalar_i & (NofAlus > 1)) ? alu_idx_raw_q : '0;
  assign lsu_idx = (en_superscalar_i & (NofLsus > 1)) ? lsu_idx_raw_q : '0;
  assign fpu_idx = (en_superscalar_i & (NofFpus > 1)) ? fpu_idx_raw_q : '0;

  // ALU counter
  if (NofAlusIsPow2) begin : gen_alu_idx_pow2
    // If the number of FUs is a power of 2, the wrap around happens naturally
    always_comb begin: alu_idx_calculation
      if (restart_i) begin
        alu_idx_raw_d = '0;
      end else if (en_superscalar_i & dispatched) begin
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
      end else if (en_superscalar_i & dispatched) begin
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
      end else if (en_superscalar_i & dispatched) begin
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
      end else if (en_superscalar_i & dispatched) begin
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
      end else if (en_superscalar_i & dispatched) begin
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
      end else if (en_superscalar_i & dispatched) begin
        fpu_idx_raw_d = (fpu_idx_sum >= NofFpus)  ? fpu_idx_sum - NofFpus
                                                  : fpu_idx_sum[NofFpusW-1:0];
      end else begin
        fpu_idx_raw_d = fpu_idx_raw_q;
      end
    end
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
  // The allocation happens once the first instruction is successfully dispatched.
  // we immediately allocate all the instructions in the block at once even if not all of them are yet dispatched
  assign rob_push_o = (|instr_dispatched)      &
                      !(|dispatched_q)         &
                      en_superscalar_i;

  // We have to remember the first ROB tags because of partial dispatch
  always_comb begin
    rob_tag_d = rob_tag_q;
    // Remember the rob tags the next cycle we pushed these into the ROB
    if (rob_push_o) begin
      rob_tag_d = rob_idx_i;
    end
    if (restart_i) begin
      rob_tag_d = '0;
    end
  end

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

  `ASSERT_INIT(
    DispPipeWidthTooLarge,
    (NofAlusIsPow2 || (PipeWidth <= 2 * NofAlus)) &&
    (NofLsusIsPow2 || (PipeWidth <= 2 * NofLsus)) &&
    (NofFpusIsPow2 || (PipeWidth <= 2 * NofFpus)),
    "PipeWidth is too large for single-subtraction wrap logic."
  );

endmodule
