// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/assertions.svh"

// Author: Stefan Odermatt <soderma@ethz.ch>

// Stores the instructions and data to be dispatched to the functional units. 
// The buffer is a FIFO with multiple push and pop ports.
// Can push PipeWidth instructions per cycle into it and pop NumFus instructions per cycle from it.
module schnova_disp_buffer import schnova_pkg::*; #(
  parameter int unsigned PipeWidth      = 1,
  parameter int unsigned NumEntries     = 1,
  parameter int unsigned NumFus         = 1,
  parameter type         data_t         = logic
) (
  input  logic                          clk_i,
  input  logic                          rst_i,
  // Allocation Interface
  input  logic                          push_i,
  input  logic  [$clog2(PipeWidth):0]   push_count_i,
  input  data_t [PipeWidth-1:0]         disp_data_i,
  output logic  [$clog2(NumEntries):0]  free_count_o,
  // Deallocation Interface
  input  logic                          pop_i,
  input  logic  [$clog2(NumFus):0]      pop_count_i,
  output data_t [NumFus-1:0]            disp_data_o,
  output logic  [NumFus-1:0]            disp_valid_o,
  // Status of the buffer
  output logic                          empty_o
);

  // Width of the index used to index into the buffer
  localparam int unsigned IdxWidth = (NumEntries > 1) ? $clog2(NumEntries) : 1;

  typedef struct packed {
    data_t data;
    logic  valid;
  } buf_t;

  // Pointers and Occupancy
  logic [IdxWidth-1:0] head_ptr, tail_ptr;
  logic [NumFus-1:0]   [IdxWidth:0] tmp_read_idx;
  logic [PipeWidth-1:0][IdxWidth:0] tmp_write_idx;

  // Pointers and Count update
  logic [$clog2(NumFus):0]    actual_pop;
  logic [$clog2(PipeWidth):0] actual_push;
  logic [IdxWidth:0]      next_head_ext;
  logic [IdxWidth:0]      next_tail_ext;

  // The actual storage
  buf_t [NumEntries-1:0] disp_buffer;
  logic [$clog2(NumEntries):0] free_count;

  assign actual_pop  = (pop_i)  ? pop_count_i  : '0;
  assign actual_push = (push_i) ? push_count_i : '0;

  // Pointer look-ahead
  assign next_head_ext = {1'b0, head_ptr} + actual_pop;
  assign next_tail_ext = {1'b0, tail_ptr} + actual_push;

  // Combinational indexing for multi-port access
  always_comb begin
    disp_data_o  = '0;
    disp_valid_o = '0;

    // read logic
    for (int unsigned i = 0; i < NumFus; i++) begin
      tmp_read_idx[i]  = {1'b0, head_ptr} + IdxWidth'(i);
      if (tmp_read_idx[i] >= NumEntries[IdxWidth:0]) begin
        tmp_read_idx[i] = tmp_read_idx[i] - NumEntries[IdxWidth:0];
      end
      disp_data_o[i]  = disp_buffer[tmp_read_idx[i][IdxWidth-1:0]].data;
      disp_valid_o[i] = disp_buffer[tmp_read_idx[i][IdxWidth-1:0]].valid;
    end

    // write logic
    for (int unsigned i = 0; i < PipeWidth; i++) begin
      tmp_write_idx[i] = {1'b0, tail_ptr} + IdxWidth'(i);
      if (tmp_write_idx[i] >= NumEntries[IdxWidth:0]) begin
        tmp_write_idx[i] = tmp_write_idx[i] - NumEntries[IdxWidth:0];
      end
    end
  end

  // Sequential Update
  always_ff @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
      head_ptr   <= '0;
      tail_ptr   <= '0;
      free_count <= NumEntries;
      disp_buffer <= '0;
    end else begin
      // Update Head
      if (actual_pop > 0) begin
        for (int unsigned i = 0; i < NumFus; i++) begin
          if (i < actual_pop) begin
            disp_buffer[tmp_read_idx[i][IdxWidth-1:0]].valid <= 1'b0;
          end
        end

        if (next_head_ext >= NumEntries[IdxWidth:0]) begin
          head_ptr <= next_head_ext[IdxWidth-1:0] - NumEntries[IdxWidth-1:0];
        end else begin
          head_ptr <= next_head_ext[IdxWidth-1:0];
        end
      end

      // Update Tail and Data
      if (actual_push > 0) begin
        for (int unsigned i = 0; i < PipeWidth; i++) begin
          if (i < actual_push) begin
            disp_buffer[tmp_write_idx[i][IdxWidth-1:0]].data <= disp_data_i[i];
            disp_buffer[tmp_write_idx[i][IdxWidth-1:0]].valid <= 1'b1;
          end
        end

        if (next_tail_ext >= NumEntries[IdxWidth:0]) begin
          tail_ptr <= next_tail_ext[IdxWidth-1:0] - NumEntries[IdxWidth-1:0];
        end else begin
          tail_ptr <= next_tail_ext[IdxWidth-1:0];
        end
      end

      // Occupancy update
      free_count <= free_count - actual_push + actual_pop;
    end
  end

  assign free_count_o = free_count;

  assign empty_o = (free_count == NumEntries);

  // Assertions
  `ASSERT_INIT(DispBufferPWMismatch, PipeWidth <= NumEntries,
    "Buffer too small, should at least be able to hold pipewidth number of entries");

  `ASSERT_INIT(DispBufferFuMismatch, NumFus <= NumEntries,
    "Buffer too small, should at least be able to pop for each functional unit");

  `ASSERT(DispBufferOverflow, (actual_push <= free_count), clk_i, rst_i, 
          "Issue Buffer Overflow! Tried to push more than free_count.")

  `ASSERT(DispBufferUnderflow, (actual_pop <= (NumEntries - free_count)), clk_i, rst_i, 
          "Issue Buffer Underflow! Tried to pop more than currently valid.")

endmodule
