// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Stefan Odermatt <soderma@ethz.ch>

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"

module schnova_frontend # (
    parameter int unsigned XLEN            = 32,
    parameter int unsigned PipeWidth       = 1,
    parameter logic [31:0] BootAddr        = 32'h0000_1000,
    /// Physical Address width of the core.
    parameter int unsigned AddrWidth = 48,
    // Physical memory attributes
    parameter snitch_pma_pkg::snitch_pma_t SnitchPMACfg = '{default: 0},
    /// Number of bits that get fetched per fetch request
    parameter int unsigned ICacheFetchDataWidth      = 0,
    parameter type         block_ctrl_info_t = logic,
    parameter type addr_t = logic [AddrWidth-1:0]
    ) (
    input  logic clk_i,
    input  logic rst_i,
    /// From L0 instruction cache
    // The instructions fetched from the L0 cache, valid if fetch_data_valid_o is true
    input  logic [ICacheFetchDataWidth-1:0]   instr_fetch_data_i,
    // Whether the L0 cache is ready to send new instructions
    input  logic                              instr_fetch_ready_i,
    // To L0 instruction cache
    // The address of the instruction that should be fetched
    output addr_t                             instr_fetch_addr_o,
    output logic                              instr_fetch_cacheable_o,
    // If the fetch request is valid (new fetch request when valid asserted)
    output logic                              instr_fetch_valid_o,
    /// From controller
    input  logic                              stall_i,
    input  logic                              exception_i,
    input  logic                              mret_i,
    input  logic                              sret_i,
    /// To controller
    output logic [31:0]                       pc_o,
    output logic [XLEN-1:0]                   consecutive_pc_o,
    // Branch result
    input  logic                              alu_compare_res_i,
    input  logic[XLEN-1:0]                    alu_result_i,
    // Exception source interface
    input  logic                              wfi_i,
    input  logic                              barrier_stall_i,
    input  logic [31:0]                       mtvec_i,
    input  logic [31:0]                       mepc_i,
    input  logic [31:0]                       sepc_i,
    /// From decoder
    input  block_ctrl_info_t                  blk_ctrl_info_i,
    /// To decoder and dispatcher
    output logic [PipeWidth-1:0][31:0]   instr_fetch_data_o,
    output logic [PipeWidth-1:0]         instr_fetch_data_valid_o
);
    // RV32 instructions are 32 bit/4 bytes
    localparam int unsigned INSTR_BYTES = 4;
    // Each instruction address should be aligned to this bit position
    localparam int unsigned INSTR_ALIGN = $clog2(INSTR_BYTES);
    // Each fetch request fetches this amount of bytes
    localparam int unsigned FETCH_BYTES = ICacheFetchDataWidth / 8;
    // Each fetch request should be aligned to this bit position
    localparam int unsigned FETCH_ALIGN = $clog2(FETCH_BYTES);

    // Which instruction in the fetch block the current PC points to
    logic [$clog2(PipeWidth)-1:0] instr_index;
    logic            valid_fetch_block; // Whether the current fetch block is valid
    logic [XLEN-1:0] consecutive_pc;
    // Number of remaining instructions until the next block
    
    logic [31:0]     pc_d, pc_q; // PC is fixed to 32 bits in RV32
    logic            stall_fetch; // Whether instruction fetch should be stalled
    `FFAR(pc_q, pc_d, BootAddr, clk_i, rst_i);

    ///////////////////////
    // Instruction Fetch //
    ///////////////////////
    
    // Instruction fetching for the superscalar pipeline happens roughly in three steps:
    // 1) The next PC is calculated to which the fetch request is sent. This happens at
    //    a fetch block granularity, i.e. one fetch request will fetch multiple instructions
    //    in a block. If the PC is not alligned the cache will automatically allign it down,
    //    and the frontend will have to select the correct instruction from the fetch block.
    // 2) A new fetch request is sent if the fetching is not stalled.
    // 3) The fetch block has to be extracted and realigned to be sent to the decoder. The fetch block
    //    is valid when the handshake with the L0 cache is successful and it is not one of the 
    //    instructions before the current PC that were fetched purely since we fetch in a
    //    block granualrity.

    ///////////////
    // PC update //
    ///////////////

    // We now have to handle the PC update. In particular, we have to "execute" any branch / jump
    // instruction. Any control flow instruction is performed using an ALU which is designed to be
    // combinatorial only. Thus the result is immediately available.
    //
    // To retire an instruction we must make sure:
    // ## If it is a non control flow instruction and goes to a pipelined FU:
    //   The FU has accepted the instruction. Any congestion on the register update will be
    //   handled by the write back logic as it can stall the FU.
    //   --> When instr_dispatched is asserted we are done and can step to the next instruction.
    //
    // ## If it goes to a single cycle (combinatorial) FU (control and regular instructions):
    //   In this case it is important that we handle the write back and any eventual PC manipulation
    //   in the same cycle we dispatch it. Otherwise we cannot dispatch the instruction anyway as the
    //   FU won't signal ready until the write back is ready to accept the result. This is the case
    //   because the ready signal from a combinatorial FU is directly the ready signal of the write
    //   back stage. As a consequence:
    // !!! The write back stage must be implemented so that it always acknowledges a retiring ALU
    // !!! instruction which does not write to any register (branch inst).
    //   The controller now only has to listen to the instr_dispatched signal and compute the new
    //   PC value using the ALU result (value & comparison).
    //   The write back of JAL and JALR is directly handled in the write back part.
    //   To simplify the implementation, the Dispatcher may only dispatch control flow instructions
    //   to one specific ALU.
    //
    // TODO(colluca): is debug implemented?
    // The next PC is selected as either (in priority order, first is most important):
    // - Debug
    // - Exception: go to trap handler
    // - MRET, SRET: go to handlers
    // - Jumped PC: for JAL, JALR we take the ALU result. JALR must have last bit reset
    // - Consequtive PC: PC+4 or, branch/immediate updates.
    // - Branched & Consecutive PC: for all regular instructions & branches if taken

    // Program counter
    assign consecutive_pc_o = consecutive_pc;
    assign pc_o             = pc_q;

    // We can merge the consecutive and branched PC computation such that we only have one adder.
    // The consecutive PC is either PC+imm for taken branches or
    // it depends on the amount of valid instructions we had in this fetch block. 
    // For example if the packet is 4 instructions and we had 3 valid instructions
    // we only have to increment by 4 bytes, not 16 bytes. This is important otherwise we
    // would lose performance, basically once the PC would not be aligned to a fetch block,
    // we would always have invalid instructions per fetch purely because of that.
    // If we have a JAL or JALR, we store the regular consecutive PC (PC+4) in rd.

    // TODO(soderma): Assumes the branch will be completed in the same cycle!
    // We have to stall until the branch is resolved, so we would not use the decoded instruction
    // in that case, since it would take one or multiple cycles until we have that result.
    assign consecutive_pc = pc_q +
        ((blk_ctrl_info_i.is_branch && alu_compare_res_i) ?
        // In case of a branch, we just add the immediate
                                      blk_ctrl_info_i.imm :
                                      ((blk_ctrl_info_i.is_fence_i)      ?
        // In case of a FENCE_I we have to fetch the next instruction after the fence_i
                                      (blk_ctrl_info_i.instr_idx + 1'b1) :
        // Next PC is now PC + #instructions used in the last fetch block
                                      (PipeWidth-instr_index)) << 2);

    // If we stall fetch, we don't request a new instruction
    // If however onlly stall_i is asserted, this means we were not able to dispatch the request
    // in that case we have to refetch the same instruction, hence in that case we just don't
    // update the PC, but the fetch is still valid.
    assign stall_fetch = barrier_stall_i | wfi_i;

    always_comb begin : pc_update
      pc_d = pc_q; // per default stay at current PC

      if (exception_i) begin
        pc_d = mtvec_i;
      end else if (!stall_i && !stall_fetch) begin
        // If we don't stall, step the PC unless we are waiting for an event or are stalled by the
        // cluster hw barrier.
        if (mret_i) begin
          pc_d = mepc_i;
        end else if (sret_i) begin
          pc_d = sepc_i;
        end else if (blk_ctrl_info_i.is_jal || blk_ctrl_info_i.is_jalr) begin
          // Set to alu result. Clear last bit if JALR
          pc_d = alu_result_i & {{31{1'b1}}, ~blk_ctrl_info_i.is_jalr};
        end else begin
          // The consecutive address covers regular and branch instructions as well as fence_i
          pc_d = consecutive_pc;
        end
      end
    end

    ////////////////////////////
    // Fetch Request Handling //
    ////////////////////////////

    // Request the next instruction if we don't stall the fetching
    assign instr_fetch_valid_o = !stall_fetch;

    // request the fetch block at the current PC
    assign instr_fetch_addr_o = {{{AddrWidth-32}{1'b0}}, pc_q};

    // The fetch request is cacheable if the requested address is in a cacheable region. 
    // This still works the same as for the single issue core as the fetch block is 
    // always aligned to the fetch block size. So it is impossible to have a situation
    // where the PC lies in the cacheable region but an instruction in the fetch block lies
    // outside of it. 
    assign instr_fetch_cacheable_o =
        snitch_pma_pkg::is_inside_cacheable_regions(SnitchPMACfg, instr_fetch_addr_o);

    /////////////////////////////
    // Instruction realignment //
    /////////////////////////////

    // 1) Valid instruction extraction: We have to extract the first valid instruction from the fetch block.
    // This is determined by the PC. In our case every instruction is 4 bytes,
    // so the first two bits of the PC point to bytes of an instruction.addr_t
    // The following bytes will point to individual instructions until we reach the end of the fetch block
    // PC [ 32 ...... FETCH_ALIGN | FETCH_ALING-1 .... INSTR_ALIGN | 1 0 ]
    //     | Fetch packet index   | instruction index              | byte inside instruction |
    // 2) Then we have to realign the instructions, so that the first valid instruction is always the first element.
    // This is important to simplify the logic in the decoder, rename and dispatch stage.
    //For example, if a packet cointains 4 instructions
    // [ instr3 | instr 2 | instr1 | instr0 ]
    //              ^
    //              |
    //              PC
    // and the PC points to instr2, we have to select instr2 as the first valid instruction
    // and realign the instructions to be sent to the decoder
    // [invalid | invalid | instr3 | instr2 ]

    // The fetch block is valid if the handshake with the L0 cache is successful
    assign valid_fetch_block = instr_fetch_valid_o & instr_fetch_ready_i;

    if (PipeWidth > 1) begin : gen_alignment
      // Calcualte the instruction index from the current PC
      assign instr_index = pc_q[FETCH_ALIGN-1:INSTR_ALIGN];

      for (genvar i = 0; i < PipeWidth; i++) begin: gen_realignment_mux_network
        // The instructions are realigned according to the example above, with a multiplexer network
        assign instr_fetch_data_o[i]= instr_fetch_data_i[(i + instr_index)*32 +: 32];

        // If the instruction points to the N-th instruction in the fetch block,
        // Then the first N-1 instruction in that fetch block are invalid.
        // Now since we reshuffle the instruction the first PipeWidth-N instructions in 
        // instr_fetch data will be valid and the rest invalid. Finally, they are valid in the first
        // place only if the fetch block is valid.
        assign instr_fetch_data_valid_o[i] = (i + instr_index < PipeWidth) & valid_fetch_block;
      end

    end else begin : gen_no_alignment
      // There is only one instruction per fetch block, no index necesary
      assign instr_index = '0;
      // If we only fetch one instruction, we can just forward it
      assign instr_fetch_data_o = instr_fetch_data_i;
      // The instruction is valid if the handshake with the L0 cache is successful
      assign instr_fetch_data_valid_o = valid_fetch_block;
    end

endmodule