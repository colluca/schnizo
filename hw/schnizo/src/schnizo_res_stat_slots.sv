// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/assertions.svh"
`include "common_cells/registers.svh"

// Datapath of the Reservation Station.
// Contains the slot registers, dispatch pipeline, result capture, and RF writeback path.
module schnizo_res_stat_slots import schnizo_pkg::*; #(
  parameter  int unsigned     NofRsis           = 4,
  parameter  int unsigned     NofRsrs          = 4,
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
  parameter int unsigned      NofResPorts      = 1,
  parameter bit               HasTwoDests      = 0,
  localparam integer unsigned NofRsisWidth     = cf_math_pkg::idx_width(NofRsis),
  localparam integer unsigned NofRsrsWidth     = cf_math_pkg::idx_width(NofRsrs),
  localparam type             rsis_idx_t       = logic [NofRsisWidth-1:0],
  localparam type             rsrs_idx_t       = logic [NofRsrsWidth-1:0]
) (
  input  logic clk_i,
  input  logic rst_i,

  // Control
  input  producer_id_t producer_id_i,
  input  logic         restart_i,
  input  loop_state_e  loop_state_i,
  input  rsis_idx_t    disp_idx_i,
  input  rsrs_idx_t    allocated_rsrs_idx_i,
  input  rsrs_idx_t    assigned_rsrs_idx_i,
  input  rsis_idx_t    issue_idx_i,
  input  logic         last_issue_iter_i,
  input  logic         last_result_iter_i,
  output logic         retire_at_issue_o,

  // Dispatch
  input  disp_req_t    disp_req_i,
  input  logic         disp_req_valid_i,
  output logic         disp_req_ready_o,
  // producer id of the slot that was dispatched to
  output producer_id_t [HasTwoDests:0] disp_rsp_o,

  // Issue
  output issue_req_t issue_req_o,
  output logic       issue_req_valid_o,
  input  logic       issue_req_ready_i,
  output logic       instr_exec_commit_o,

  // Result from FU
  input  result_t     [NofResPorts-1:0] result_i,
  input  result_tag_t [NofResPorts-1:0] result_tag_i,
  input  logic        [NofResPorts-1:0] result_valid_i,
  output logic        [NofResPorts-1:0] result_ready_o,

  // RF writeback
  output result_t     [NofResPorts-1:0] rf_wb_result_o,
  output result_tag_t [NofResPorts-1:0] rf_wb_tag_o,
  output logic        [NofResPorts-1:0] rf_wb_valid_o,
  input  logic        [NofResPorts-1:0] rf_wb_ready_i,

  // Operand request
  output available_result_t [NofRsrs-1:0] available_results_o,
  output operand_req_t  [NofOperands-1:0] op_reqs_o,
  output logic          [NofOperands-1:0] op_reqs_valid_o,
  input  logic          [NofOperands-1:0] op_reqs_ready_i,

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

  rsrs_idx_t [NofResPorts-1:0] result_rsrs_sel;
  for (genvar res_port = 0; res_port < NofResPorts; res_port++) begin: gen_2nd_rsrs_sel
    assign result_rsrs_sel[res_port] = rsrs_idx_t'(result_tag_i[res_port]);
  end

  rs_slot_issue_t               slot_issue_rdata;  // registered issue state for the selected slot
  rs_slot_issue_t               slot_issue_wdata;  // post-dispatch-pipeline issue state for the selected slot
  logic                         slot_issue_wen;    // write enable for the issue slot
  rs_slot_result_t [NofRsrs-1:0] slot_result_qs;    // registered result state of each slot
  rs_slot_result_t [NofRsrs-1:0] slot_result_ds;    // next result state for each slot
  rs_slot_result_t [HasTwoDests:0] slot_result_inits;
  rs_slot_result_t [NofResRspIfs-1:0] handler_slot_out;  // Per-port handler outputs (indexed by response port k)
  rs_slot_result_t [NofRsrs-1:0]       slot_base_state;   // Per-slot pre-handler state (registered or dispatch init)
  rs_slot_result_t [NofRsrs-1:0]       slot_updated_state; // Per-slot post-handler state, before FU result capture
  rs_slot_result_t [NofResPorts-1:0] slot_wb_capture;   // post-result-capture result state for the selected slot
  result_tag_t [NofResPorts-1:0] capture_rf_wb_tag;
  logic   [NofResPorts-1:0] capture_rf_do_writeback;

  ///////////
  // Slots //
  ///////////

  // Next idices are used for issue requests with two results.
  // There we assign the results to the current and next result slots
  rsrs_idx_t allocated_rsrs_idx_next;
  assign allocated_rsrs_idx_next = rsrs_idx_t'(allocated_rsrs_idx_i + 1);

  rsrs_idx_t assigned_rsrs_idx_next;
  assign assigned_rsrs_idx_next = rsrs_idx_t'(assigned_rsrs_idx_i + 1);


  // pragma translate_off
  producer_id_t [NofRsrs-1:0] rsrs_ids;
  for (genvar rsrs = 0; rsrs < NofRsrs; rsrs++) begin: gen_rsrs_ids
    assign rsrs_ids[rsrs] = producer_id_t'{
      slot_id: slot_id_t'(rsrs),
      rs_id:   producer_id_i.rs_id
    };
  end
  // pragma translate_on

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
    .NofRsis        (NofRsis),
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
  logic [NofRsrs-1:0] enable_cap_consumers_q, enable_cap_consumers_d;

  for (genvar rsrs = 0; rsrs < NofRsrs; rsrs++) begin : gen_rsrs
    // Per-slot available result info
    assign available_results_o[rsrs].iteration = slot_result_qs[rsrs].result.iteration;
    assign available_results_o[rsrs].valid = slot_result_qs[rsrs].result.is_valid;

    // Per-slot enable_capture_consumers state machine.
    logic [0:NofResPorts-1] retired_rsrs_port;
    for (genvar res_port = 0; res_port < NofResPorts; res_port++) begin
      assign retired_rsrs_port[res_port] = result_valid_i[res_port] && result_ready_o[res_port] && (rsrs_idx_t'(rsrs) == result_rsrs_sel[res_port]);
    end
    logic retired_rsrs;
    assign retired_rsrs = |retired_rsrs_port;

    always_comb begin
      enable_cap_consumers_d[rsrs] = enable_cap_consumers_q[rsrs];
      // Set after LCP1 result arrives for this slot
      if (!enable_cap_consumers_q[rsrs] && retired_rsrs && (loop_state_i == LoopLcp1)) begin
        enable_cap_consumers_d[rsrs] = 1'b1;
      end
      // Clear after LCP2 result arrives for this slot
      if (enable_cap_consumers_q[rsrs] && retired_rsrs) begin
        enable_cap_consumers_d[rsrs] = 1'b0;
      end
      // Initialization has highest priority
      if (restart_i) begin
        enable_cap_consumers_d[rsrs] = 1'b0;
      end
    end
    `FFAR(enable_cap_consumers_q[rsrs], enable_cap_consumers_d[rsrs], 1'b0, clk_i, rst_i);

    // Per-slot base state: use slot_result_init on dispatch so the fresh init is always
    // captured regardless of whether a result request is in flight, otherwise fall back to the
    // registered state. This is also what the handler reads as its input.
    always_comb begin
      slot_base_state[rsrs] = slot_result_qs[rsrs];

      if (disp_req_valid_i && allocated_rsrs_idx_i == rsrs_idx_t'(rsrs)) begin
        slot_base_state[rsrs] = slot_result_inits[0];
      end else if (HasTwoDests && disp_req_valid_i && allocated_rsrs_idx_next == rsrs_idx_t'(rsrs) && disp_req_i.has_two_dests) begin
        slot_base_state[rsrs] = slot_result_inits[1];
      end
    end

    // Per-slot updated state: apply handler output if a port is serving this slot,
    // otherwise use the base state.
    always_comb begin
      slot_updated_state[rsrs] = slot_base_state[rsrs];
      for (int k = 0; k < NofResRspIfs; k++) begin
        if (res_reqs_valid_i[k] && res_reqs_i[k].slot_id == rsrs_idx_t'(rsrs)) begin
          slot_updated_state[rsrs] = handler_slot_out[k];
        end
      end
    end

    // Result state register: FU result capture has highest priority.
    always_comb begin
      slot_result_ds[rsrs] = slot_updated_state[rsrs];

      for (int res_port = 0; res_port < NofResPorts; res_port++) begin
        if (rsrs_idx_t'(rsrs) == result_rsrs_sel[res_port] && result_valid_i[res_port]) begin
          slot_result_ds[rsrs] = slot_wb_capture[res_port];
        end
      end
    end
    // Result slot
    `FFAR(slot_result_qs[rsrs], slot_result_ds[rsrs], slot_result_reset, clk_i, rst_i);
  end

  // NofResRspIfs result request handlers — one per response port.
  for (genvar k = 0; k < NofResRspIfs; k++) begin : gen_rsp_ports
    rsrs_idx_t slot_sel;
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

  // These IDs will be used to send to the disptacher for producer information
  producer_id_t [HasTwoDests:0] allocated_result_slot_ids;
  assign allocated_result_slot_ids[0] = producer_id_t'{
    slot_id: slot_id_t'(allocated_rsrs_idx_i),
    rs_id:   producer_id_i.rs_id
  };
  if (HasTwoDests) begin: gen_2nd_destination_result_slot
    assign allocated_result_slot_ids[1] = producer_id_t'{
      slot_id: slot_id_t'(allocated_rsrs_idx_next),
      rs_id:   producer_id_i.rs_id
    };
  end

  // These slots will will be initialized when a new instruction is dispatched to this FU block.
  rs_slot_result_t [HasTwoDests:0] result_slots_for_dispatch;
  assign result_slots_for_dispatch[0] = slot_result_qs[allocated_rsrs_idx_i];
  if (HasTwoDests) begin
    assign result_slots_for_dispatch[1] = slot_result_qs[allocated_rsrs_idx_next];
  end

  // These IDs will be used to fill in the destination tags for the issued instructions
  producer_id_t [HasTwoDests:0] issue_result_tag_ids;
  assign issue_result_tag_ids[0] = producer_id_t'{
    slot_id: slot_id_t'(assigned_rsrs_idx_i),
    rs_id:   producer_id_i.rs_id
  };
  if (HasTwoDests) begin
    assign issue_result_tag_ids[1] = producer_id_t'{
      slot_id: slot_id_t'(assigned_rsrs_idx_next),
      rs_id:   producer_id_i.rs_id
    };
  end

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
    .issue_req_t     (issue_req_t),
    .NofResPorts     (NofResPorts),
    .HasTwoDests     (HasTwoDests)
  ) i_dispatch_pipeline (
    .clk_i                  (clk_i),
    .rst_ni                 (!rst_i),
    .restart_i              (restart_i),
    .disp_producer_id_i     (allocated_result_slot_ids),
    .issue_result_tag_id_i  (issue_result_tag_ids),
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
    .slot_result_i          (result_slots_for_dispatch),
    .slot_result_reset_val_i(slot_result_reset),
    .slot_result_o          (slot_result_inits),
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
  // TODO(lnoussi): Check todo above in new implementation with two dests
  assign disp_rsp_o[0] = producer_id_t'{
    slot_id: slot_id_t'(allocated_rsrs_idx_i),
    rs_id:   producer_id_i.rs_id
  };

  if (HasTwoDests) begin
    assign disp_rsp_o[1] = producer_id_t'{
      slot_id: slot_id_t'(allocated_rsrs_idx_next),
      rs_id:   producer_id_i.rs_id
    };
  end

  assign issue_req_valid_o   = issue_req_valid_raw;
  assign issue_req_o         = issue_req_raw;

  // Each accepted dispatch request was committed so we also commit to each issue request.
  assign instr_exec_commit_o = issue_req_valid_o;

  /////////////////////////
  // Result RF/RSS demux //
  /////////////////////////

  logic [NofResPorts-1:0] rss_wb_valid, rss_wb_ready;
  logic [NofResPorts-1:0] rf_wb_valid, rf_wb_ready;

  for (genvar res_port = 0; res_port < NofResPorts; res_port++) begin: gen_result_forks
    stream_fork #(
      .N_OUP(32'd2)
    ) i_result_fork (
      .clk_i,
      .rst_ni (!rst_i),
      .valid_i(result_valid_i[res_port]),
      .ready_o(result_ready_o[res_port]),
      .valid_o({rf_wb_valid[res_port], rss_wb_valid[res_port]}),
      .ready_i({rf_wb_ready[res_port], rss_wb_ready[res_port]})
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
    assign rf_do_writeback = capture_rf_do_writeback[res_port];

    logic rss_wb_valid_sync, rss_wb_ready_sync;
    logic rf_wb_valid_sync, rf_wb_ready_sync;
    logic rss_wb_enable;

    assign rf_wb_valid_sync  = rf_wb_valid[res_port] && rss_wb_ready_sync;
    assign rf_wb_ready[res_port] = rf_wb_ready_sync && rss_wb_ready_sync;
    assign rss_wb_enable     = rf_do_writeback ? rf_wb_valid_sync && rf_wb_ready_sync : 1'b1;
    assign rss_wb_valid_sync = rss_wb_valid[res_port] && rss_wb_enable;
    assign rss_wb_ready[res_port] = rss_wb_ready_sync && rss_wb_enable;

    //////////////////
    // RF writeback //
    //////////////////

    stream_filter i_filter_rf_writeback (
      .valid_i(rf_wb_valid_sync),
      .ready_o(rf_wb_ready_sync),
      .drop_i (!rf_do_writeback),
      .valid_o(rf_wb_valid_o[res_port]),
      .ready_i(rf_wb_ready_i[res_port])
    );
    assign rf_wb_result_o[res_port] = result_i[res_port];
    assign rf_wb_tag_o[res_port]    = capture_rf_wb_tag[res_port];

    /////////////////////
    // Result capture  //
    /////////////////////

    schnizo_rss_result_capture #(
      .rs_slot_result_t(rs_slot_result_t),
      .result_t        (result_t),
      .result_tag_t    (result_tag_t),
      .disp_req_t      (disp_req_t)
    ) i_result_capture (
      .slot_i               (slot_updated_state[result_rsrs_sel[res_port]]),
      .result_i             (result_i[res_port]),
      .result_valid_i       (rss_wb_valid_sync),
      .loop_state_i         (loop_state_i),
      .is_last_result_iter_i(last_result_iter_i),
      .disp_req_i           (disp_req_i),
      .result_ready_o       (rss_wb_ready_sync),
      .slot_o               (slot_wb_capture[res_port]),
      .rf_wb_tag_o          (capture_rf_wb_tag[res_port]),
      .rf_do_writeback_o    (capture_rf_do_writeback[res_port])
    );
  end

  ////////////////
  // Assertions //
  ////////////////

  // TODO(colluca): replace with fallback to HWLOOP mode
  `ASSERT(ConstMemNoOverflow, !const_mem_overflow, clk_i, rst_i)

endmodule