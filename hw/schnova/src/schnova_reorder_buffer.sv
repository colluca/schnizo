// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Note: The physical register size has to be a power of two, for the math to work

// Author: Stefan Odermatt <soderma@ethz.ch>
module schnova_reorder_buffer import schnizo_pkg::*; #(
  parameter int unsigned PipeWidth   = 1,
  parameter int unsigned NofEntries  = 64,
  parameter type         phy_id_t = logic,
  localparam int unsigned TagWidth = $clog2(NofEntries)
) (
  input  logic         clk_i,
  input  logic         rst_i,
  // Allocation Interface (Rename Stage)
  input logic                                rob_push_i,
  input logic [$clog2(PipeWidth):0]          rob_push_count_i,
  input phy_id_t [PipeWidth-1:0]             rob_phy_reg_rd_old_i,
  output logic [PipeWidth-1:0][TagWidth-1:0] rob_idx_o,
  output logic                               rob_ready_o,
  // Writeback Interface
  input logic [PipeWidth-1:0]                wb_valid_i,
  input logic [PipeWidth-1:0][TagWidth-1:0]  wb_rob_idx_i,
  // Freelist interface
  output logic freelist_push_o,
  output [$clog2(PipeWidth):0] push_count_o,
  output phy_id_t [PipeWidth-1:0] retired_regs_o
);

  typedef struct packed {
      logic valid;
      logic done;
      phy_id_t phy_reg_rd_old; // The physcial register rd was renamed to previously
  } rob_entry_t;

  rob_entry_t [NofEntries-1:0] rob;
  logic [PipeWidth-1:0][NofEntries-1:0] wb_dec;

  logic [NofEntries:0] head_ptr, tail_ptr; // Extra bit for wrap-around/full detection

  logic [TagWidth:0] free_count;
  logic [TagWidth:0] allocated_entries;

  logic [PipeWidth-1:0] pop_valid;
  logic [$clog2(PipeWidth):0] pop_count;
  always_comb begin : wb_decoder
    for (int unsigned j = 0; j < PipeWidth; j++) begin
      for (int unsigned i = 0; i < NofEntries; i++) begin
        if (wb_rob_idx_i[j] == i) wb_dec[j][i] = wb_valid_i[j];
        else wb_dec[j][i] = 1'b0;
      end
    end
  end

  // Calculate the current number of free rob entries
  assign allocated_entries = tail_ptr - head_ptr;
  assign free_count = NofEntries - allocated_entries;

  // The rob is ready to allocate the requested amount of entries
  // if the number of free entries is larger or equal than the number off
  // requested entries
  assign rob_ready_o = (free_count >= rob_push_count_i);

  // ROB commit
  always_comb begin
    pop_valid = 1'b0;
    for (int unsigned i = 0; i < PipeWidth; i++) begin
      // Commit has to happen in order, so we have to have a sequence of done
      // ROB entries to commit them all simultaneously
      // Note commit in schnova does just entail freeing the ROB entry and physical register
      if (i == 0) begin
        pop_valid[i] = rob[head_ptr].done;
      end else begin
        pop_valid[i] = pop_valid[i-1] && rob[(head_ptr+i)%NofEntries].done;
      end
      // We can always assign the values from the headpointer
      // the physical register that we can free is the one the instruction has
      // overwritten
      retired_regs_o[i] = rob[(head_ptr+i)%NofEntries].phy_reg_rd_old;
    end
  end

  popcount #(
    .INPUT_WIDTH(PipeWidth)
  ) i_pop_count (
    .data_i(pop_valid),
    .popcount_o(pop_count)
  );

  // The amount of physical registers we can push on to the free list is the amount of
  // entries we popped from the ROB
  assign push_count_o = pop_count;
  // We push registers to the freelist once we have we can remove at least one entry from the
  // rob
  assign freelist_push_o = |pop_valid;

  // When ever we allocate a rob index, it has to be forwarded
  always_comb begin: forward_rob_index
    // The current rob index is just the tail pointer itself
    for (int unsigned i = 0; i < PipeWidth; i++) begin
      rob_idx_o[i] = (tail_ptr + i)%NofEntries;
    end
  end

  // Sequential updates, that includes pointer calculations and retirements
  always_ff @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
      head_ptr <= '0;
      tail_ptr <= '0;
      for (int unsigned i = 0; i < NofEntries; i++) begin
        rob[i] <= rob_entry_t'{
          valid: 1'b0,
          done: 1'b0,
          phy_reg_rd_old: '0
        };
      end
    end else begin

      // Update the ROB when a writeback happens
      for (int unsigned j = 0; j < PipeWidth; j++) begin
        for (int unsigned i = 0; i < NofEntries; i++) begin
          // If the wb decoder hits, we set the done bit
          if (wb_dec[j][i]) begin
            rob[i].done <= 1'b1;
          end
        end
      end

      // Update the tail pointer when new entries are allocated
      if(rob_push_i && rob_ready_o) begin
        for (int i = 0; i < PipeWidth; i++) begin
          if (i < rob_push_count_i) begin
            rob[(tail_ptr+i)%NofEntries].valid <= 1'b1;
            rob[(tail_ptr+i)%NofEntries].done  <= 1'b0;
            rob[(tail_ptr+i)%NofEntries].phy_reg_rd_old  <= rob_phy_reg_rd_old_i[i];
          end
        end

        // Advance the pointers
        tail_ptr <= (tail_ptr + rob_push_count_i);
      end

      // Clear the ROB entries on commit
      for (int unsigned i = 0; i < PipeWidth; i++) begin
        if (pop_valid[i]) begin
          rob[(head_ptr+i)%NofEntries].valid <= 1'b0;
        end
      end

      // Advance the head pointer
      head_ptr <= (head_ptr + pop_count);
    end
  end

endmodule
