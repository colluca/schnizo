// Copyright 2026 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Minimal VLSU for Schnizo.  Replaces spatz_vlsu with a low-latency pipeline
// that exploits the combinational vregfile and eliminates all spill-registers.
//
// Aligned fast path (rs1[2:0] == 0):
//   Load  latency: 2 cycles  (cycle 0: issue all NrMemPorts reads;
//                              cycle 1: all responses -> combinational VRF write -> done)
//   Store latency: 1 cycle   (VRF read combinational; stores fire-and-forget)
//                              Falls back to STORE_ISSUE when TCDM back-pressures.
//
// Unaligned slow path (rs1[2:0] != 0), modeled after spatz_vlsu:
//   Processes one element per cycle using port 0 only.
//   Address aligned down to 8-byte boundary; byte strobe selects the valid bytes.
//   Load data barrel-rotated right by offset to extract element; written with wbe.
//   Store data barrel-rotated left by offset, written with per-element strobe.
//   Latency: 3 cycles/element for loads (issue -> rsp -> VRF write),
//             1 cycle/element for stores (one port, fire-and-forget).

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
  output logic spatz_mem_str_finished_o,

  // High whenever the VLSU has an instruction in flight (not IDLE).
  // Does NOT pulse for fast aligned stores that complete without leaving IDLE.
  output logic busy_o
);

`include "common_cells/registers.svh"

  // VRF word address = reg_number << $clog2(NrWordsPerVector).
  // For VLEN=256, N_FU=4, ELEN=64 -> NrWordsPerVector=1 -> shift=0.
  localparam int unsigned VrfAddrShift = $clog2(NrWordsPerVector);

  // Total bytes transferred per vector operation.
  localparam int unsigned TotalBytes = NrMemPorts * ELENB; // 4 * 8 = 32

  ////////////
  //  State //
  ////////////

  typedef enum logic [2:0] {
    IDLE,
    LOAD_WAIT,            // fast aligned load: waiting for all port responses
    STORE_ISSUE,          // fast aligned store: retry on TCDM back-pressure
    UNALIGNED_LOAD_ISSUE, // unaligned load: issuing single-element read on port 0
    UNALIGNED_LOAD_RSP,   // unaligned load: waiting for response, then writing VRF
    UNALIGNED_STORE       // unaligned store: issuing one element per cycle on port 0
  } state_e;

  state_e state_q, state_d;
  `FF(state_q, state_d, IDLE)

  ////////////////////////////
  //  Registered state      //
  ////////////////////////////

  spatz_req_t             req_q;          // latched request
  vrf_data_t              store_data_q;   // latched VRF data for store
  logic [NrMemPorts-1:0]  store_sent_q;   // which fast-store ports accepted so far

  // Fast load response accumulation
  elen_t [NrMemPorts-1:0] rsp_data_q,  rsp_data_d;
  logic  [NrMemPorts-1:0] rsp_valid_q, rsp_valid_d;

  // Unaligned operation state
  logic [5:0] ua_byte_q;    // byte offset of current element within the vector (0..TotalBytes-1)
  elen_t      ua_rsp_q;     // latched TCDM response for current unaligned load element
  logic       ua_rsp_vld_q; // response received for current element

  spatz_req_t            req_d;
  vrf_data_t             store_data_d;
  logic [NrMemPorts-1:0] store_sent_d;
  logic [5:0]            ua_byte_d;
  elen_t                 ua_rsp_d;
  logic                  ua_rsp_vld_d;

  ///////////////////////////////////////////
  //  Unaligned helper signals             //
  ///////////////////////////////////////////

  // Misalignment detection
  logic is_unaligned_i; // from incoming request (combinational, used in IDLE)
  logic is_unaligned_q; // from latched request (used in UNALIGNED_* states)
  assign is_unaligned_i = spatz_req_i.rs1[2:0] != '0;
  assign is_unaligned_q = req_q.rs1[2:0] != '0;

  // Element size in bytes from latched request vsew field
  logic [3:0]     elem_bytes_q; // 1, 2, or 4
  logic [ELENB-1:0] elem_mask_q; // byte-enable mask for one element (within an 8B TCDM word)
  always_comb begin
    elem_bytes_q = 4'h1 << req_q.vtype.vsew;
    elem_mask_q  = '0;
    case (req_q.vtype.vsew)
      EW_8:    elem_mask_q = 8'h01;
      EW_16:   elem_mask_q = 8'h03;
      default: elem_mask_q = 8'h0F; // EW_32 (and EW_64 treated as aligned)
    endcase
  end

  // Address of the current unaligned element
  elen_t ua_byte_addr;
  elen_t ua_aligned_addr;
  logic [2:0] ua_offset;
  assign ua_byte_addr    = req_q.rs1 + elen_t'(ua_byte_q);
  assign ua_aligned_addr = {ua_byte_addr[63:3], 3'b0}; // snap to 8-byte boundary
  assign ua_offset       = ua_byte_addr[2:0];           // byte offset within that word

  // Last-element flag: will we be done after processing the current element?
  logic ua_last_elem;
  assign ua_last_elem = (ua_byte_q + 6'(elem_bytes_q) >= 6'(TotalBytes));

  // Unaligned load: current element at LSB (barrel-shifted from memory response)
  elen_t ua_load_elem;
  assign ua_load_elem = ua_rsp_q >> ({3'b0, ua_offset} * 8);

  // Unaligned store: element extracted from VRF word, rotated into memory position
  elen_t          ua_store_mem_data;
  logic [ELENB-1:0] ua_store_strb;
  elen_t ua_vrf_elem;
  assign ua_vrf_elem         = ELEN'(store_data_q >> ({1'b0, ua_byte_q} * 8));
  assign ua_store_mem_data   = (ua_vrf_elem & ELEN'(elem_mask_q)) << ({3'b0, ua_offset} * 8);
  assign ua_store_strb       = ELENB'(elem_mask_q) << ua_offset;

  // Completion conditions for unaligned states
  logic ua_load_elem_done;   // current load element's VRF write accepted
  logic ua_store_req_done;   // current store element's TCDM request accepted
  assign ua_load_elem_done = (state_q == UNALIGNED_LOAD_RSP) && ua_rsp_vld_q && vrf_wvalid_i;
  assign ua_store_req_done = (state_q == UNALIGNED_STORE) &&
                             spatz_mem_req_valid_o[0] && spatz_mem_req_ready_i[0];

  ///////////////////////////////////////////
  //  Registered state next-value logic    //
  ///////////////////////////////////////////

  always_comb begin : proc_registered_state_d
    req_d         = req_q;
    store_data_d  = store_data_q;
    store_sent_d  = store_sent_q;
    rsp_data_d    = rsp_data_q;
    rsp_valid_d   = rsp_valid_q;
    ua_byte_d     = ua_byte_q;
    ua_rsp_d      = ua_rsp_q;
    ua_rsp_vld_d  = ua_rsp_vld_q;

    // Capture new request when accepted in IDLE
    if (state_q == IDLE && spatz_req_valid_i &&
        (spatz_req_i.op_mem.is_load || vrf_rvalid_i[0])) begin
      req_d = spatz_req_i;
      if (spatz_req_i.op_mem.is_load) begin
        rsp_valid_d  = '0;
        ua_byte_d    = '0;
        ua_rsp_vld_d = 1'b0;
      end else begin
        store_data_d = vrf_rdata_i[0];
        ua_byte_d    = '0;
        // For aligned fast store: track which ports accepted in IDLE
        store_sent_d = is_unaligned_i ? '0 : spatz_mem_req_ready_i;
      end
    end

    // Fast aligned load: accumulate responses (possibly out of order)
    if (state_q == LOAD_WAIT) begin
      for (int p = 0; p < NrMemPorts; p++) begin
        if (spatz_mem_rsp_valid_i[p] && !rsp_valid_q[p]) begin
          rsp_data_d[p]  = spatz_mem_rsp_i[p].data;
          rsp_valid_d[p] = 1'b1;
        end
      end
    end

    // Fast aligned store: track newly-accepted ports in STORE_ISSUE
    if (state_q == STORE_ISSUE) begin
      for (int p = 0; p < NrMemPorts; p++) begin
        if (spatz_mem_req_valid_o[p] && spatz_mem_req_ready_i[p])
          store_sent_d[p] = 1'b1;
      end
    end

    // Unaligned load: latch TCDM response when it arrives
    if (state_q == UNALIGNED_LOAD_RSP && !ua_rsp_vld_q && spatz_mem_rsp_valid_i[0]) begin
      ua_rsp_d     = spatz_mem_rsp_i[0].data;
      ua_rsp_vld_d = 1'b1;
    end

    // Unaligned load: advance byte counter after VRF write is accepted
    if (ua_load_elem_done) begin
      ua_byte_d    = ua_byte_q + 6'(elem_bytes_q);
      ua_rsp_vld_d = 1'b0;
    end

    // Unaligned store: advance byte counter after TCDM request is accepted
    if (ua_store_req_done) begin
      ua_byte_d = ua_byte_q + 6'(elem_bytes_q);
    end
  end

  `FF(req_q,        req_d,        '0, clk_i, rst_ni)
  `FF(store_data_q, store_data_d, '0, clk_i, rst_ni)
  `FF(store_sent_q, store_sent_d, '0, clk_i, rst_ni)
  `FF(rsp_data_q,   rsp_data_d,   '0, clk_i, rst_ni)
  `FF(rsp_valid_q,  rsp_valid_d,  '0, clk_i, rst_ni)
  `FF(ua_byte_q,    ua_byte_d,    '0, clk_i, rst_ni)
  `FF(ua_rsp_q,     ua_rsp_d,     '0, clk_i, rst_ni)
  `FF(ua_rsp_vld_q, ua_rsp_vld_d, '0, clk_i, rst_ni)

  ////////////////////////////////////////////////////////
  //  Combinatorial response accumulation (same-cycle)  //
  ////////////////////////////////////////////////////////

  // Combine already-latched responses with those arriving this very cycle so
  // the fast load can complete without an extra register stage.
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

  // Aligned store that completes immediately in IDLE (all ports accept, VRF ready)
  logic idle_store_done;
  assign idle_store_done = spatz_req_valid_i && !spatz_req_i.op_mem.is_load &&
                           !is_unaligned_i && vrf_rvalid_i[0] && &spatz_mem_req_ready_i;

  always_comb begin
    state_d = state_q;
    unique case (state_q)
      IDLE: begin
        if (spatz_req_valid_i) begin
          if (spatz_req_i.op_mem.is_load) begin
            if (is_unaligned_i)
              state_d = UNALIGNED_LOAD_ISSUE;
            else
              // Only advance when all ports accepted (valid stays high until then)
              state_d = &spatz_mem_req_ready_i ? LOAD_WAIT : IDLE;
          end else if (vrf_rvalid_i[0]) begin
            if (is_unaligned_i)
              state_d = UNALIGNED_STORE;
            else
              state_d = idle_store_done ? IDLE : STORE_ISSUE;
          end
        end
      end

      LOAD_WAIT:
        if (all_rsp_done && vrf_wvalid_i)
          state_d = IDLE;

      STORE_ISSUE:
        if (all_store_done)
          state_d = IDLE;

      UNALIGNED_LOAD_ISSUE:
        // Wait until port 0 accepts the request
        if (spatz_mem_req_valid_o[0] && spatz_mem_req_ready_i[0])
          state_d = UNALIGNED_LOAD_RSP;

      UNALIGNED_LOAD_RSP:
        // Wait for response and VRF write; then either next element or done
        if (ua_load_elem_done)
          state_d = ua_last_elem ? IDLE : UNALIGNED_LOAD_ISSUE;

      UNALIGNED_STORE:
        // Each accepted request advances; last one returns to IDLE
        if (ua_store_req_done)
          state_d = ua_last_elem ? IDLE : UNALIGNED_STORE;

      default: state_d = IDLE;
    endcase
  end

  ///////////////////////////
  //  Request handshake    //
  ///////////////////////////

  // For aligned loads: stall until all NrMemPorts TCDM ports accept simultaneously.
  // For unaligned loads: accept immediately (no TCDM ports fired in IDLE).
  // For stores (aligned or not): stall until VRF data is ready.
  assign spatz_req_ready_o = (state_q == IDLE) &&
      (!spatz_req_valid_i ||
       (spatz_req_i.op_mem.is_load  && (is_unaligned_i || &spatz_mem_req_ready_i)) ||
       (!spatz_req_i.op_mem.is_load && vrf_rvalid_i[0]));

  /////////////////////
  //  Memory requests //
  /////////////////////

  // Port 0 gets its own always_comb so the unaligned path (which exclusively uses
  // port 0) is driven from a single process.  Ports 1+ share a separate loop.
  // Mixing a genvar `if (p==0)` guard inside one always_comb causes vsim-7033
  // (multiple-driver) because the elaborator sees spatz_mem_req_o[0] referenced
  // in every loop instance's always_comb block.

  always_comb begin : gen_mem_req_port0
    spatz_mem_req_o[0]       = '0;
    spatz_mem_req_valid_o[0] = 1'b0;

    // Fast aligned load
    if (state_q == IDLE && spatz_req_valid_i && !is_unaligned_i &&
        spatz_req_i.op_mem.is_load) begin
      spatz_mem_req_o[0].addr  = spatz_req_i.rs1;
      spatz_mem_req_o[0].write = 1'b0;
      spatz_mem_req_o[0].amo   = reqrsp_pkg::AMONone;
      spatz_mem_req_o[0].strb  = '1;
      spatz_mem_req_o[0].user  = '0;
      spatz_mem_req_valid_o[0] = 1'b1;
    end

    // Fast aligned store
    if (state_q == IDLE && spatz_req_valid_i && !is_unaligned_i &&
        !spatz_req_i.op_mem.is_load && vrf_rvalid_i[0]) begin
      spatz_mem_req_o[0].addr  = spatz_req_i.rs1;
      spatz_mem_req_o[0].write = 1'b1;
      spatz_mem_req_o[0].amo   = reqrsp_pkg::AMONone;
      spatz_mem_req_o[0].data  = vrf_rdata_i[0][ELEN*0 +: ELEN];
      spatz_mem_req_o[0].strb  = '1;
      spatz_mem_req_o[0].user  = '0;
      spatz_mem_req_valid_o[0] = 1'b1;
    end

    // Fast aligned store retry
    if (state_q == STORE_ISSUE && !store_sent_q[0]) begin
      spatz_mem_req_o[0].addr  = req_q.rs1;
      spatz_mem_req_o[0].write = 1'b1;
      spatz_mem_req_o[0].amo   = reqrsp_pkg::AMONone;
      spatz_mem_req_o[0].data  = store_data_q[ELEN*0 +: ELEN];
      spatz_mem_req_o[0].strb  = '1;
      spatz_mem_req_o[0].user  = '0;
      spatz_mem_req_valid_o[0] = 1'b1;
    end

    // Unaligned load: single 8-byte-aligned read for current element
    if (state_q == UNALIGNED_LOAD_ISSUE) begin
      spatz_mem_req_o[0].addr  = ua_aligned_addr;
      spatz_mem_req_o[0].write = 1'b0;
      spatz_mem_req_o[0].amo   = reqrsp_pkg::AMONone;
      spatz_mem_req_o[0].strb  = '1;
      spatz_mem_req_o[0].user  = '0;
      spatz_mem_req_valid_o[0] = 1'b1;
    end

    // Unaligned store: single write with element rotated into position
    if (state_q == UNALIGNED_STORE) begin
      spatz_mem_req_o[0].addr  = ua_aligned_addr;
      spatz_mem_req_o[0].write = 1'b1;
      spatz_mem_req_o[0].amo   = reqrsp_pkg::AMONone;
      spatz_mem_req_o[0].data  = ua_store_mem_data;
      spatz_mem_req_o[0].strb  = ua_store_strb;
      spatz_mem_req_o[0].user  = '0;
      spatz_mem_req_valid_o[0] = 1'b1;
    end
  end : gen_mem_req_port0

  for (genvar p = 1; p < NrMemPorts; p++) begin : gen_mem_req
    always_comb begin
      spatz_mem_req_o[p]       = '0;
      spatz_mem_req_valid_o[p] = 1'b0;

      // Fast aligned load
      if (state_q == IDLE && spatz_req_valid_i && !is_unaligned_i &&
          spatz_req_i.op_mem.is_load) begin
        spatz_mem_req_o[p].addr  = spatz_req_i.rs1 + elen_t'(p * ELENB);
        spatz_mem_req_o[p].write = 1'b0;
        spatz_mem_req_o[p].amo   = reqrsp_pkg::AMONone;
        spatz_mem_req_o[p].strb  = '1;
        spatz_mem_req_o[p].user  = '0;
        spatz_mem_req_valid_o[p] = 1'b1;
      end

      // Fast aligned store
      if (state_q == IDLE && spatz_req_valid_i && !is_unaligned_i &&
          !spatz_req_i.op_mem.is_load && vrf_rvalid_i[0]) begin
        spatz_mem_req_o[p].addr  = spatz_req_i.rs1 + elen_t'(p * ELENB);
        spatz_mem_req_o[p].write = 1'b1;
        spatz_mem_req_o[p].amo   = reqrsp_pkg::AMONone;
        spatz_mem_req_o[p].data  = vrf_rdata_i[0][ELEN*p +: ELEN];
        spatz_mem_req_o[p].strb  = '1;
        spatz_mem_req_o[p].user  = '0;
        spatz_mem_req_valid_o[p] = 1'b1;
      end

      // Fast aligned store retry
      if (state_q == STORE_ISSUE && !store_sent_q[p]) begin
        spatz_mem_req_o[p].addr  = req_q.rs1 + elen_t'(p * ELENB);
        spatz_mem_req_o[p].write = 1'b1;
        spatz_mem_req_o[p].amo   = reqrsp_pkg::AMONone;
        spatz_mem_req_o[p].data  = store_data_q[ELEN*p +: ELEN];
        spatz_mem_req_o[p].strb  = '1;
        spatz_mem_req_o[p].user  = '0;
        spatz_mem_req_valid_o[p] = 1'b1;
      end
      // Ports 1+ are idle during UNALIGNED_* states.
    end
  end : gen_mem_req

  ///////////////////////
  //  VRF read (stores) //
  ///////////////////////

  // Read VRF combinatorially when a store arrives in IDLE (aligned or unaligned).
  // For aligned stores the data is used immediately; for unaligned it is latched
  // into store_data_q and consumed element-by-element in UNALIGNED_STORE.
  assign vrf_raddr_o[0] = spatz_req_i.vd << VrfAddrShift;
  assign vrf_re_o[0]    = (state_q == IDLE && spatz_req_valid_i && !spatz_req_i.op_mem.is_load);
  assign vrf_raddr_o[1] = '0;   // vs2 indexed loads: not used in schnizo
  assign vrf_re_o[1]    = '0;

  ////////////////////////
  //  VRF write (loads) //
  ////////////////////////

  always_comb begin
    vrf_we_o    = 1'b0;
    vrf_waddr_o = '0;
    vrf_wdata_o = '0;
    vrf_wbe_o   = '0;

    // Fast aligned load: write all NrMemPorts words at once when all responses in
    if (state_q == LOAD_WAIT && all_rsp_done) begin
      vrf_we_o    = 1'b1;
      vrf_waddr_o = req_q.vd << VrfAddrShift;
      for (int p = 0; p < NrMemPorts; p++)
        vrf_wdata_o[ELEN*p +: ELEN] = rsp_data_now[p];
      vrf_wbe_o = '1;
    end

    // Unaligned load: write one element with byte-enable when response is available.
    // ua_load_elem = response >> (offset*8) places the element at the LSB.
    // Shifting left by ua_byte_q*8 positions it at the correct byte in the VRF word.
    if (state_q == UNALIGNED_LOAD_RSP && ua_rsp_vld_q) begin
      vrf_we_o    = 1'b1;
      vrf_waddr_o = req_q.vd << VrfAddrShift;
      vrf_wdata_o = vrf_data_t'(ua_load_elem) << ({1'b0, ua_byte_q} * 8);
      vrf_wbe_o   = vrf_be_t'(elem_mask_q) << ua_byte_q;
    end
  end

  ////////////////////////
  //  Response          //
  ////////////////////////

  assign vlsu_rsp_valid_o =
    // Fast aligned load done
    (state_q == LOAD_WAIT          && all_rsp_done    && vrf_wvalid_i      ) ||
    // Fast aligned store done immediately in IDLE
    (state_q == IDLE               && idle_store_done                       ) ||
    // Fast aligned store done after STORE_ISSUE retry
    (state_q == STORE_ISSUE        && all_store_done                        ) ||
    // Unaligned load: last element's VRF write accepted
    (state_q == UNALIGNED_LOAD_RSP && ua_load_elem_done && ua_last_elem     ) ||
    // Unaligned store: last element's TCDM request accepted
    (state_q == UNALIGNED_STORE    && ua_store_req_done && ua_last_elem     );

  assign vlsu_rsp_o = '{id: (state_q == IDLE ? spatz_req_i.id : req_q.id), default: '0};

  assign spatz_mem_finished_o     = vlsu_rsp_valid_o;
  assign spatz_mem_str_finished_o = vlsu_rsp_valid_o &&
                                    ((state_q == IDLE           && !spatz_req_i.op_mem.is_load) ||
                                      state_q == STORE_ISSUE    ||
                                      state_q == UNALIGNED_STORE);
  assign busy_o = (state_q != IDLE);

  // Unused
  assign vrf_id_o = '0;

  ////////////////
  // Assertions //
  ////////////////

  // pragma translate_off
  if (NrMemPorts != N_FU)
    $error("[schnizo_vlsu] NrMemPorts must equal N_FU (%0d)", N_FU);

  // synthesis translate_off
  always @(posedge clk_i) begin
    if (rst_ni && (state_d == STORE_ISSUE) && (state_q == IDLE))
      $display("[schnizo_vlsu] WARNING: TCDM back-pressure on aligned store -> entering STORE_ISSUE");
    if (rst_ni && (state_d == UNALIGNED_LOAD_ISSUE) && (state_q == IDLE))
      $display("[schnizo_vlsu] INFO: unaligned load at 0x%08x", spatz_req_i.rs1);
    if (rst_ni && (state_d == UNALIGNED_STORE) && (state_q == IDLE))
      $display("[schnizo_vlsu] INFO: unaligned store at 0x%08x", spatz_req_i.rs1);
  end
  // synthesis translate_on
  // pragma translate_on

endmodule : schnizo_vlsu
