// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Minimal VLSU for Schnizo.  Replaces spatz_vlsu with a low-latency pipeline
// that exploits the combinational vregfile and eliminates all spill-registers.
//
// Load  latency: 2 cycles  (cycle 0: issue TCDM reads;
//                            cycle 1: all responses ? combinational VRF write ? done)
// Store latency: 1 cycle   (VRF read is combinational; stores fire-and-forget)
//                           Falls back to STORE_ISSUE when TCDM back-pressures.

module schnizo_vlsu
  import spatz_pkg::*, rvv_pkg::*; #(
  parameter int unsigned NrMemPorts         = 4,
  parameter int unsigned NrOutstandingLoads = 8,    // kept for interface compatibility
  parameter type         spatz_mem_req_t    = logic,
  parameter type         spatz_mem_rsp_t    = logic
) (
  input  logic clk_i,
  input  logic rst_ni,

  // Spatz request
  input  spatz_req_t spatz_req_i,
  input  logic       spatz_req_valid_i,
  output logic       spatz_req_ready_o,

  // VLSU response
  output logic       vlsu_rsp_valid_o,
  output vlsu_rsp_t  vlsu_rsp_o,

  // VRF write port (loads)
  output vrf_addr_t  vrf_waddr_o,
  output vrf_data_t  vrf_wdata_o,
  output logic       vrf_we_o,
  output vrf_be_t    vrf_wbe_o,
  input  logic       vrf_wvalid_i,

  // VRF id (unused without controller, kept for interface compat)
  output spatz_id_t [2:0] vrf_id_o,

  // VRF read ports: [0] = VLSU_VD_RD (store source), [1] = vs2/indexed (unused)
  output vrf_addr_t [1:0] vrf_raddr_o,
  output logic      [1:0] vrf_re_o,
  input  vrf_data_t [1:0] vrf_rdata_i,
  input  logic      [1:0] vrf_rvalid_i,

  // Memory ports
  output spatz_mem_req_t [NrMemPorts-1:0] spatz_mem_req_o,
  output logic           [NrMemPorts-1:0] spatz_mem_req_valid_o,
  input  logic           [NrMemPorts-1:0] spatz_mem_req_ready_i,
  input  spatz_mem_rsp_t [NrMemPorts-1:0] spatz_mem_rsp_i,
  input  logic           [NrMemPorts-1:0] spatz_mem_rsp_valid_i,

  output logic spatz_mem_finished_o,
  output logic spatz_mem_str_finished_o
);

`include "common_cells/registers.svh"

  // VRF word address = reg_number << $clog2(NrWordsPerVector).
  // For VLEN=256, N_FU=4, ELEN=64 ? NrWordsPerVector=1 ? shift=0.
  localparam int unsigned VrfAddrShift = $clog2(NrWordsPerVector);

  ////////////
  //  State //
  ////////////

  typedef enum logic [1:0] {
    IDLE,
    LOAD_WAIT,
    STORE_ISSUE   // only entered when TCDM back-pressures a store
  } state_e;

  state_e state_q, state_d;
  `FF(state_q, state_d, IDLE)

  ////////////////////////////
  //  Registered state      //
  ////////////////////////////

  spatz_req_t             req_q;          // latched request
  vrf_data_t              store_data_q;   // latched VRF data for store retry
  logic [NrMemPorts-1:0]  store_sent_q;   // which store ports accepted so far

  // Load response accumulation
  elen_t [NrMemPorts-1:0] rsp_data_q;
  logic  [NrMemPorts-1:0] rsp_valid_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      req_q        <= '0;
      store_data_q <= '0;
      store_sent_q <= '0;
      rsp_data_q   <= '0;
      rsp_valid_q  <= '0;
    end else begin
      // Capture new request only when it is actually accepted (valid && ready).
      // For loads that is always; for stores vrf_rvalid_i[0] must be 1 so that
      // store_data_q holds real VRF data and not a stale/garbage value.
      if (state_q == IDLE && spatz_req_valid_i &&
          (spatz_req_i.op_mem.is_load || vrf_rvalid_i[0])) begin
        req_q <= spatz_req_i;
        if (spatz_req_i.op_mem.is_load) begin
          rsp_valid_q <= '0;
        end else begin
          // Latch VRF data (combinational) and accepted-ports mask for STORE_ISSUE retry
          store_data_q <= vrf_rdata_i[0];
          store_sent_q <= spatz_mem_req_ready_i;
        end
      end

      // Accumulate load responses as they arrive (possibly out of order)
      if (state_q == LOAD_WAIT) begin
        for (int p = 0; p < NrMemPorts; p++) begin
          if (spatz_mem_rsp_valid_i[p] && !rsp_valid_q[p]) begin
            rsp_data_q[p]  <= spatz_mem_rsp_i[p].data;
            rsp_valid_q[p] <= 1'b1;
          end
        end
      end

      // Track which store ports have been accepted during STORE_ISSUE
      if (state_q == STORE_ISSUE) begin
        for (int p = 0; p < NrMemPorts; p++) begin
          if (spatz_mem_req_valid_o[p] && spatz_mem_req_ready_i[p]) begin
            store_sent_q[p] <= 1'b1;
          end
        end
      end
    end
  end

  ////////////////////////////////////////////////////////
  //  Combinatorial response accumulation (same-cycle)  //
  ////////////////////////////////////////////////////////

  // Combine already-latched responses with those arriving this very cycle so
  // the load can complete without an extra register stage.
  logic  [NrMemPorts-1:0] rsp_valid_now;
  elen_t [NrMemPorts-1:0] rsp_data_now;
  for (genvar p = 0; p < NrMemPorts; p++) begin : gen_rsp_now
    assign rsp_valid_now[p] = rsp_valid_q[p] ||
                              (state_q == LOAD_WAIT && spatz_mem_rsp_valid_i[p]);
    assign rsp_data_now[p]  = rsp_valid_q[p] ? rsp_data_q[p] : spatz_mem_rsp_i[p].data;
  end
  logic all_rsp_done;
  assign all_rsp_done = &rsp_valid_now;

  // For STORE_ISSUE: combine previously-sent with newly-accepted this cycle
  logic [NrMemPorts-1:0] store_done_now;
  for (genvar p = 0; p < NrMemPorts; p++) begin : gen_store_done_now
    assign store_done_now[p] = store_sent_q[p] ||
                               (state_q == STORE_ISSUE &&
                                spatz_mem_req_valid_o[p] && spatz_mem_req_ready_i[p]);
  end
  logic all_store_done;
  assign all_store_done = &store_done_now;

  //////////////////////
  //  State machine   //
  //////////////////////

  // A store that has all TCDM ports accept immediately (common case) resolves in
  // IDLE without transitioning to STORE_ISSUE.
  logic idle_store_done;
  assign idle_store_done = spatz_req_valid_i && !spatz_req_i.op_mem.is_load &&
                           vrf_rvalid_i[0] && &spatz_mem_req_ready_i;

  always_comb begin
    state_d = state_q;
    unique case (state_q)
      IDLE: begin
        if (spatz_req_valid_i) begin
          if (spatz_req_i.op_mem.is_load) begin
            // Loads don't read VRF ? accept and issue memory reads unconditionally.
            state_d = LOAD_WAIT;
          end
          else if (vrf_rvalid_i[0]) begin
            // Store: VRF data is ready this cycle.
            // If all TCDM ports accepted, stay in IDLE; otherwise retry in STORE_ISSUE.
            state_d = idle_store_done ? IDLE : STORE_ISSUE;
          end
          // else !vrf_rvalid_i[0]: VRF bank conflict; spatz_req_ready_o=0 so the
          // instruction is not consumed ? stay in IDLE and retry next cycle.
        end
      end
      LOAD_WAIT:   if (all_rsp_done   && vrf_wvalid_i) state_d = IDLE;
      STORE_ISSUE: if (all_store_done)                  state_d = IDLE;
      default:     state_d = IDLE;
    endcase
  end

  ///////////////////////////
  //  Request handshake    //
  ///////////////////////////

  // Stall stores if the VRF bank is occupied by a higher-priority VFU read this cycle.
  // vrf_rvalid_i[0] is combinational: it is 0 only when the shared bank port 0 is
  // taken by VFU_VS2_RD in the same cycle.
  assign spatz_req_ready_o = (state_q == IDLE) &&
      (!spatz_req_valid_i || spatz_req_i.op_mem.is_load || vrf_rvalid_i[0]);

  /////////////////////
  //  Memory requests //
  /////////////////////

  for (genvar p = 0; p < NrMemPorts; p++) begin : gen_mem_req
    always_comb begin
      spatz_mem_req_o[p]       = '0;
      spatz_mem_req_valid_o[p] = 1'b0;

      if (state_q == IDLE && spatz_req_valid_i) begin
        if (spatz_req_i.op_mem.is_load) begin
          // Issue all NrMemPorts read requests in one shot
          spatz_mem_req_o[p].addr  = spatz_req_i.rs1 + elen_t'(p * ELENB);
          spatz_mem_req_o[p].write = 1'b0;
          spatz_mem_req_o[p].amo   = reqrsp_pkg::AMONone;
          spatz_mem_req_o[p].strb  = '1;
          spatz_mem_req_o[p].user  = '0;
          spatz_mem_req_valid_o[p] = 1'b1;
        end else if (vrf_rvalid_i[0]) begin
          // Store: VRF read is combinational; drive all write requests immediately
          spatz_mem_req_o[p].addr  = spatz_req_i.rs1 + elen_t'(p * ELENB);
          spatz_mem_req_o[p].write = 1'b1;
          spatz_mem_req_o[p].amo   = reqrsp_pkg::AMONone;
          spatz_mem_req_o[p].data  = vrf_rdata_i[0][ELEN*p +: ELEN];
          spatz_mem_req_o[p].strb  = '1;
          spatz_mem_req_o[p].user  = '0;
          spatz_mem_req_valid_o[p] = 1'b1;
        end
      end

      // Retry unsent store ports (only entered on TCDM back-pressure)
      if (state_q == STORE_ISSUE && !store_sent_q[p]) begin
        spatz_mem_req_o[p].addr  = req_q.rs1 + elen_t'(p * ELENB);
        spatz_mem_req_o[p].write = 1'b1;
        spatz_mem_req_o[p].amo   = reqrsp_pkg::AMONone;
        spatz_mem_req_o[p].data  = store_data_q[ELEN*p +: ELEN];
        spatz_mem_req_o[p].strb  = '1;
        spatz_mem_req_o[p].user  = '0;
        spatz_mem_req_valid_o[p] = 1'b1;
      end
    end
  end : gen_mem_req

  ///////////////////////
  //  VRF read (stores) //
  ///////////////////////

  // vrf_rdata_i[0] is live in the same cycle re_o[0] is asserted (combinational vregfile).
  assign vrf_raddr_o[0] = spatz_req_i.vd << VrfAddrShift;
  assign vrf_re_o[0]    = (state_q == IDLE && spatz_req_valid_i && !spatz_req_i.op_mem.is_load);
  assign vrf_raddr_o[1] = '0;   // vs2 indexed loads ? not used in schnizo
  assign vrf_re_o[1]    = '0;

  ////////////////////////
  //  VRF write (loads) //
  ////////////////////////

  // Drive the write as soon as all responses are in; vrf_wvalid_i is combinational.
  always_comb begin
    vrf_we_o    = 1'b0;
    vrf_waddr_o = '0;
    vrf_wdata_o = '0;
    vrf_wbe_o   = '0;
    if (state_q == LOAD_WAIT && all_rsp_done) begin
      vrf_we_o    = 1'b1;
      vrf_waddr_o = req_q.vd << VrfAddrShift;
      for (int p = 0; p < NrMemPorts; p++) begin
        vrf_wdata_o[ELEN*p +: ELEN] = rsp_data_now[p];
      end
      vrf_wbe_o = '1;
    end
  end

  ////////////////////////
  //  Response          //
  ////////////////////////

  assign vlsu_rsp_valid_o =
    (state_q == LOAD_WAIT  && all_rsp_done   && vrf_wvalid_i   ) ||
    (state_q == IDLE       && idle_store_done                   ) ||
    (state_q == STORE_ISSUE && all_store_done                   );

  assign vlsu_rsp_o = '{id: (state_q == IDLE ? spatz_req_i.id : req_q.id), default: '0};

  assign spatz_mem_finished_o     = vlsu_rsp_valid_o;
  assign spatz_mem_str_finished_o = vlsu_rsp_valid_o &&
                                    ((state_q == IDLE && !spatz_req_i.op_mem.is_load) ||
                                      state_q == STORE_ISSUE);

  // Unused
  assign vrf_id_o = '0;

  ////////////////
  // Assertions //
  ////////////////

  // pragma translate_off
  if (NrMemPorts != N_FU)
    $error("[schnizo_vlsu] NrMemPorts must equal N_FU (%0d)", N_FU);

  // In normal snitch-cluster operation TCDM is always ready; this fires if
  // the fall-back STORE_ISSUE path is ever triggered (useful for debug).
  // synthesis translate_off
  always_ff @(posedge clk_i) begin
    if (rst_ni && (state_d == STORE_ISSUE) && (state_q == IDLE)) begin
      $display("[schnizo_vlsu] WARNING: TCDM back-pressure on store ? entering STORE_ISSUE");
    end
  end
  // synthesis translate_on
  // pragma translate_on

endmodule : schnizo_vlsu
