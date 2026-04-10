// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/assertions.svh"
`include "common_cells/registers.svh"

// Datapath of the Reservation Station.
// Contains the slot registers, dispatch pipeline, result capture, and RF writeback path.
module schnizo_res_stat_slots import schnizo_pkg::*; #(
  parameter  int unsigned     NofRss           = 4,
  parameter  int unsigned     NofConstants     = 4,
  parameter  int unsigned     NofConstantPorts = 2,
  parameter  int unsigned     NofOperands      = 3,
  parameter  int unsigned     NofResRspIfs     = 1,
  parameter  int unsigned     ConsumerCount    = 4,
  parameter  int unsigned     RegAddrWidth     = 5,
  parameter  bit              UseSram          = 1'b0,
  parameter  type             rs_slot_issue_t  = logic,
  parameter  type             rs_slot_result_t = logic,
  parameter  type             rss_operand_t    = logic,
  parameter  type             rss_result_t     = logic,
  parameter  type             disp_req_t       = logic,
  parameter  type             issue_req_t      = logic,
  parameter  type             result_t         = logic,
  parameter  type             result_tag_t     = logic,
  parameter  type             producer_id_t    = logic,
  parameter  type             slot_id_t        = logic,
  parameter  type             operand_req_t    = logic,
  parameter  type             operand_t        = logic,
  parameter  type             res_req_t        = logic,
  parameter  type             ext_res_req_t    = logic,
  parameter  type             available_result_t = logic,
  parameter  type             dest_mask_t      = logic,
  parameter  type             res_rsp_t        = logic,
  localparam integer unsigned NofRssWidth      = cf_math_pkg::idx_width(NofRss),
  localparam type             rss_idx_t        = logic [NofRssWidth-1:0]
) (
  input  logic clk_i,
  input  logic rst_i,

  // Control
  input  producer_id_t producer_id_i,
  input  logic         restart_i,
  input  loop_state_e  loop_state_i,
  input  rss_idx_t     disp_idx_i,
  input  rss_idx_t     issue_idx_i,
  input  logic         last_issue_iter_i,
  input  logic         last_result_iter_i,
  output logic         retire_at_issue_o,

  // Dispatch
  input  disp_req_t    disp_req_i,
  input  logic         disp_req_valid_i,
  output logic         disp_req_ready_o,
  // producer id of the slot that was dispatched to
  output producer_id_t disp_rsp_o,

  // Issue
  output issue_req_t issue_req_o,
  output logic       issue_req_valid_o,
  input  logic       issue_req_ready_i,
  output logic       instr_exec_commit_o,

  // Result from FU
  input  result_t     result_i,
  input  result_tag_t result_tag_i,
  input  logic        result_valid_i,
  output logic        result_ready_o,

  // RF writeback
  output result_t     rf_wb_result_o,
  output result_tag_t rf_wb_tag_o,
  output logic        rf_wb_valid_o,
  input  logic        rf_wb_ready_i,

  // Operand request
  output available_result_t [NofRss-1:0] available_results_o,
  output operand_req_t [NofOperands-1:0] op_reqs_o,
  output logic         [NofOperands-1:0] op_reqs_valid_o,
  input  logic         [NofOperands-1:0] op_reqs_ready_i,

  // Result request
  input  ext_res_req_t [NofResRspIfs-1:0] res_reqs_i,
  input  logic       [NofResRspIfs-1:0] res_reqs_valid_i,
  output logic       [NofResRspIfs-1:0] res_reqs_ready_o,

  // Result response
  output res_rsp_t [NofResRspIfs-1:0] res_rsps_o,
  output logic     [NofResRspIfs-1:0] res_rsps_valid_o,
  input  logic     [NofResRspIfs-1:0] res_rsps_ready_i,

  // Operand response
  input  operand_t [NofOperands-1:0] op_rsps_i,
  input  logic     [NofOperands-1:0] op_rsps_valid_i,
  output logic     [NofOperands-1:0] op_rsps_ready_o
);

  /////////////////////////////////////
  // Parameters and type definitions //
  /////////////////////////////////////

  localparam integer unsigned ConsumerCountWidth = cf_math_pkg::idx_width(ConsumerCount);

  localparam integer unsigned ConstMemAddrWidth = cf_math_pkg::idx_width(NofConstants);
  typedef logic [ConstMemAddrWidth-1:0] const_op_addr_t;

  /////////////////
  // Connections //
  /////////////////

  rss_idx_t result_rss_sel;
  assign result_rss_sel = rss_idx_t'(result_tag_i);

  rs_slot_issue_t               slot_issue_rdata;  // registered issue state for the selected slot
  rs_slot_issue_t               slot_issue_wdata;  // post-dispatch-pipeline issue state for the selected slot
  logic                         slot_issue_wen;    // write enable for the issue slot
  rs_slot_result_t [NofRss-1:0] slot_result_qs;    // registered result state of each slot
  rs_slot_result_t [NofRss-1:0] slot_result_ds;    // next result state for each slot
  rs_slot_result_t              slot_result_init;  // initial result state from dispatch pipeline (LCP1)
  rs_slot_result_t [NofResRspIfs-1:0] handler_slot_out;  // Per-port handler outputs (indexed by response port k)
  rs_slot_result_t [NofRss-1:0]       slot_base_state;   // Per-slot pre-handler state (registered or dispatch init)
  rs_slot_result_t [NofRss-1:0]       slot_updated_state; // Per-slot post-handler state, before FU result capture
  rs_slot_result_t              slot_wb_capture;   // post-result-capture result state for the selected slot
  result_tag_t                  capture_rf_wb_tag;
  logic                         capture_rf_do_writeback;

  ///////////
  // Slots //
  ///////////

  slot_id_t     [NofRss-1:0] slot_ids;
  producer_id_t [NofRss-1:0] rss_ids;

  rs_slot_result_t slot_result_reset;
  assign slot_result_reset = '{
    consumer_count: '0,
    consumed_by:    '0,
    // We ignore the result part - the iteration flag could be X.
    result:         '0,
    no_dest:       1'b0,
    dest_id:        '0,
    dest_is_fp:     '0,
    do_writeback:   1'b0
  };

  // Issue slots
  schnizo_res_stat_issue_memory #(
    .NofRss         (NofRss),
    .UseSram        (UseSram),
    .rs_slot_issue_t(rs_slot_issue_t)
  ) i_issue_slots (
    .clk_i,
    .rst_ni (!rst_i),
    .raddr_i(issue_idx_i),
    .rdata_o(slot_issue_rdata),
    .wen_i  (slot_issue_wen),
    .waddr_i(issue_idx_i),
    .wdata_i(slot_issue_wdata)
  );

  /////////////////////
  // Constant memory //
  /////////////////////

  const_op_addr_t [NofConstantPorts-1:0] const_op_raddr, const_op_waddr;
  operand_t       [NofConstantPorts-1:0] const_op_rdata, const_op_wdata;
  logic           [NofConstantPorts-1:0] const_op_ren, const_op_wen;

  schnizo_res_stat_constant_memory #(
    .NofConstants(NofConstants),
    .NofPorts    (NofConstantPorts),
    .operand_t   (operand_t)
  ) i_constant_memory (
    .clk_i,
    .rst_ni (!rst_i),
    .ren_i  (const_op_ren),
    .raddr_i(const_op_raddr),
    .rdata_o(const_op_rdata),
    .wen_i  (const_op_wen),
    .waddr_i(const_op_waddr),
    .wdata_i(const_op_wdata)
  );

  // Count how many write requests we receive simultaneously
  logic [cf_math_pkg::idx_width(NofConstantPorts+1)-1:0] const_op_wen_popcount;
  popcount #(
    .INPUT_WIDTH(NofConstantPorts)
  ) i_const_mem_popcount (
    .data_i    (const_op_wen),
    .popcount_o(const_op_wen_popcount)
  );

  // Track the write pointer into the constant memory
  const_op_addr_t const_mem_write_ptr;
  logic           const_mem_overflow;
  delta_counter #(
    .WIDTH          (ConstMemAddrWidth),
    .STICKY_OVERFLOW(0)
  ) i_const_mem_counter (
    .clk_i,
    .rst_ni    (!rst_i),
    .clear_i   (restart_i),
    .en_i      (|const_op_wen),
    .load_i    (1'b0),
    .down_i    (1'b0),
    .delta_i   (const_op_addr_t'(const_op_wen_popcount)),
    .d_i       ('0),
    .q_o       (const_mem_write_ptr),
    .overflow_o(const_mem_overflow)
  );
  assign const_op_waddr[0] = const_mem_write_ptr;
  assign const_op_waddr[1] = const_mem_write_ptr + 1;

  /////////////////////////////
  // Result request handling //
  /////////////////////////////

  // Per-slot identifiers and enable_capture_consumers state.
  // enable_capture_consumers is per-slot state tracking whether we are in the consumer-counting
  // phase (between LCP1 and LCP2 results). It must be per-slot because response ports can be
  // dynamically reassigned across cycles.
  logic [NofRss-1:0] enable_cap_consumers_q, enable_cap_consumers_d;

  for (genvar rss = 0; rss < NofRss; rss++) begin : gen_rss
    assign slot_ids[rss] = slot_id_t'(rss);
    assign rss_ids[rss] = producer_id_t'{
      slot_id: slot_ids[rss],
      rs_id:   producer_id_i.rs_id
    };

    // Per-slot available result info
    assign available_results_o[rss].iteration = slot_result_qs[rss].result.iteration;
    assign available_results_o[rss].valid = slot_result_qs[rss].result.is_valid;

    // Per-slot enable_capture_consumers state machine.
    logic retired_rss;
    assign retired_rss = result_valid_i && result_ready_o && (rss_idx_t'(rss) == result_rss_sel);

    always_comb begin
      enable_cap_consumers_d[rss] = enable_cap_consumers_q[rss];
      // Set after LCP1 result arrives for this slot
      if (!enable_cap_consumers_q[rss] && retired_rss && (loop_state_i == LoopLcp1)) begin
        enable_cap_consumers_d[rss] = 1'b1;
      end
      // Clear after LCP2 result arrives for this slot
      if (enable_cap_consumers_q[rss] && retired_rss) begin
        enable_cap_consumers_d[rss] = 1'b0;
      end
      // Initialization has highest priority
      if (restart_i) begin
        enable_cap_consumers_d[rss] = 1'b0;
      end
    end
    `FFAR(enable_cap_consumers_q[rss], enable_cap_consumers_d[rss], 1'b0, clk_i, rst_i);

    // Per-slot base state: use slot_result_init on dispatch so the fresh init is always
    // captured regardless of whether a result request is in flight, otherwise fall back to the
    // registered state. This is also what the handler reads as its input.
    assign slot_base_state[rss] = (disp_req_valid_i && disp_idx_i == rss_idx_t'(rss)) ?
                                   slot_result_init : slot_result_qs[rss];

    // Per-slot updated state: apply handler output if a port is serving this slot,
    // otherwise use the base state.
    always_comb begin
      slot_updated_state[rss] = slot_base_state[rss];
      for (int k = 0; k < NofResRspIfs; k++) begin
        if (res_reqs_valid_i[k] && res_reqs_i[k].slot_id == rss_idx_t'(rss)) begin
          slot_updated_state[rss] = handler_slot_out[k];
        end
      end
    end

    // Result state register: FU result capture has highest priority.
    assign slot_result_ds[rss] = (rss_idx_t'(rss) == result_rss_sel) ?
                                 slot_wb_capture : slot_updated_state[rss];
    // Result slot
    `FFAR(slot_result_qs[rss], slot_result_ds[rss], slot_result_reset, clk_i, rst_i);
  end

  // NofResRspIfs result request handlers — one per response port.
  for (genvar k = 0; k < NofResRspIfs; k++) begin : gen_rsp_ports
    rss_idx_t slot_sel;
    assign slot_sel = res_reqs_i[k].slot_id;

    schnizo_rss_res_req_handling #(
      .rs_slot_result_t(rs_slot_result_t),
      .dest_mask_t     (dest_mask_t),
      .res_rsp_t       (res_rsp_t)
    ) i_res_req_handling (
      .slot_i            (slot_base_state[slot_sel]),
      .enable_capture_consumers_i(enable_cap_consumers_q[slot_sel]),
      .slot_o            (handler_slot_out[k]),
      .dest_mask_i       (res_reqs_i[k].dest_mask),
      .dest_mask_valid_i (res_reqs_valid_i[k]),
      .dest_mask_ready_o (res_reqs_ready_o[k]),
      .res_rsp_o         (res_rsps_o[k]),
      .res_rsp_valid_o   (res_rsps_valid_o[k]),
      .res_rsp_ready_i   (res_rsps_ready_i[k])
    );
  end

  ///////////////////////
  // Dispatch pipeline //
  ///////////////////////

  logic       issue_req_valid_raw;
  issue_req_t issue_req_raw;

  // Gate dispatch when issue and dispatch pointers diverge to ensure that
  // dispatch is only done once, for the current slot we are processing, i.e.
  // the one pointed to by issue_idx.
  logic disp_req_valid_raw, disp_req_ready_raw;
  assign disp_req_valid_raw = disp_req_valid_i && (disp_idx_i == issue_idx_i);
  assign disp_req_ready_o = disp_req_ready_raw && (disp_idx_i == issue_idx_i);

  schnizo_rss_dispatch_pipeline #(
    .NofOperands     (NofOperands),
    .NofConstantPorts(NofConstantPorts),
    .disp_req_t      (disp_req_t),
    .producer_id_t   (producer_id_t),
    .rs_slot_issue_t (rs_slot_issue_t),
    .rs_slot_result_t(rs_slot_result_t),
    .rss_operand_t   (rss_operand_t),
    .rss_result_t    (rss_result_t),
    .operand_req_t   (operand_req_t),
    .const_op_addr_t (const_op_addr_t),
    .res_req_t       (res_req_t),
    .operand_t       (operand_t),
    .issue_req_t     (issue_req_t)
  ) i_dispatch_pipeline (
    .clk_i                  (clk_i),
    .rst_ni                 (!rst_i),
    .restart_i              (restart_i),
    .disp_producer_id_i     (rss_ids[disp_idx_i]),
    .issue_producer_id_i    (rss_ids[issue_idx_i]),
    .loop_state_i           (loop_state_i),
    .last_issue_iter_i      (last_issue_iter_i),
    .retire_at_issue_o      (retire_at_issue_o),
    .disp_req_i             (disp_req_i),
    .disp_req_valid_i       (disp_req_valid_raw),
    .disp_req_ready_o       (disp_req_ready_raw),
    .slot_issue_i           (slot_issue_rdata),
    .slot_issue_o           (slot_issue_wdata),
    .slot_issue_wen_o       (slot_issue_wen),
    .alloc_const_op_valid_o (const_op_wen),
    .alloc_const_op_data_o  (const_op_wdata),
    .alloc_const_op_addr_i  (const_op_waddr),
    .slot_result_i          (slot_result_qs[disp_idx_i]),
    .slot_result_reset_val_i(slot_result_reset),
    .slot_result_o          (slot_result_init),
    .odn_op_reqs_o          (op_reqs_o),
    .odn_op_reqs_valid_o    (op_reqs_valid_o),
    .odn_op_reqs_ready_i    (op_reqs_ready_i),
    .const_op_reqs_o        (const_op_raddr),
    .const_op_reqs_valid_o  (const_op_ren),
    .odn_op_rsps_i          (op_rsps_i),
    .odn_op_rsps_valid_i    (op_rsps_valid_i),
    .odn_op_rsps_ready_o    (op_rsps_ready_o),
    .const_op_rsps_i        (const_op_rdata),
    .issue_req_o            (issue_req_raw),
    .issue_req_valid_o      (issue_req_valid_raw),
    .issue_req_ready_i      (issue_req_ready_i)
  );

  // TODO(colluca): use rss_ids
  assign disp_rsp_o = producer_id_t'{
    slot_id: slot_ids[disp_idx_i],
    rs_id:   producer_id_i.rs_id
  };

  assign issue_req_valid_o   = issue_req_valid_raw;
  assign issue_req_o         = issue_req_raw;

  // Each accepted dispatch request was committed so we also commit to each issue request.
  assign instr_exec_commit_o = issue_req_valid_o;

  /////////////////////////
  // Result RF/RSS demux //
  /////////////////////////

  logic rss_wb_valid, rss_wb_ready;
  logic rf_wb_valid, rf_wb_ready;

  stream_fork #(
    .N_OUP(32'd2)
  ) i_result_fork (
    .clk_i,
    .rst_ni (!rst_i),
    .valid_i(result_valid_i),
    .ready_o(result_ready_o),
    .valid_o({rf_wb_valid, rss_wb_valid}),
    .ready_i({rf_wb_ready, rss_wb_ready})
  );

  ///////////////////////////////////////
  // Synchronize RF and RSS writebacks //
  ///////////////////////////////////////

  // Synchronize the two streams, otherwise it may occur that a result
  // capture event precedes an issue event, with single-cycle FUs.
  // While this does not seem to compromise correctness, it does complicate the
  // tracer design, and it does go against the expectation that issue
  // precedes result capture.

  logic rf_do_writeback;
  assign rf_do_writeback = capture_rf_do_writeback;

  logic rss_wb_valid_sync, rss_wb_ready_sync;
  logic rf_wb_valid_sync, rf_wb_ready_sync;
  logic rss_wb_enable;

  assign rf_wb_valid_sync  = rf_wb_valid && rss_wb_ready_sync;
  assign rf_wb_ready       = rf_wb_ready_sync && rss_wb_ready_sync;
  assign rss_wb_enable     = rf_do_writeback ? rf_wb_valid_sync && rf_wb_ready_sync : 1'b1;
  assign rss_wb_valid_sync = rss_wb_valid && rss_wb_enable;
  assign rss_wb_ready      = rss_wb_ready_sync && rss_wb_enable;

  //////////////////
  // RF writeback //
  //////////////////

  stream_filter i_filter_rf_writeback (
    .valid_i(rf_wb_valid_sync),
    .ready_o(rf_wb_ready_sync),
    .drop_i (!rf_do_writeback),
    .valid_o(rf_wb_valid_o),
    .ready_i(rf_wb_ready_i)
  );
  assign rf_wb_result_o = result_i;
  assign rf_wb_tag_o    = capture_rf_wb_tag;

  /////////////////////
  // Result capture  //
  /////////////////////

  schnizo_rss_result_capture #(
    .rs_slot_result_t(rs_slot_result_t),
    .result_t        (result_t),
    .result_tag_t    (result_tag_t),
    .disp_req_t      (disp_req_t)
  ) i_result_capture (
    .slot_i               (slot_updated_state[result_rss_sel]),
    .result_i             (result_i),
    .result_valid_i       (rss_wb_valid_sync),
    .loop_state_i         (loop_state_i),
    .is_last_result_iter_i(last_result_iter_i),
    .disp_req_i           (disp_req_i),
    .result_ready_o       (rss_wb_ready_sync),
    .slot_o               (slot_wb_capture),
    .rf_wb_tag_o          (capture_rf_wb_tag),
    .rf_do_writeback_o    (capture_rf_do_writeback)
  );

  ////////////////
  // Assertions //
  ////////////////

  // TODO(colluca): replace with fallback to HWLOOP mode
  `ASSERT(ConstMemNoOverflow, !const_mem_overflow, clk_i, rst_i)

endmodule
