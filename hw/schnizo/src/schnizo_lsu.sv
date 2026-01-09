// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// TODO(colluca): review differences with Snitch LSU, in particular w.r.t. AWUSER field.

`include "common_cells/assertions.svh"

// An adapted Snitch LSU which supports dynamic NaN boxing.
//
// Can handle `NumOutstandingLoads` outstanding loads and `NumOutstandingMem` requests in total
// and optionally NaNBox if used in a floating-point setting. It expects its memory subsystem to
// keep order (as if issued with a single ID).
module schnizo_lsu import schnizo_pkg::*, schnizo_tracer_pkg::*; #(
  parameter int unsigned XLEN                = 32,
  parameter type         issue_req_t         = logic,
  parameter int unsigned AddrWidth           = 32,
  parameter int unsigned DataWidth           = 32,
  parameter type         dreq_t              = logic,
  parameter type         drsp_t              = logic,
  /// Tag passed from input to output. All transactions are in-order.
  parameter type         tag_t               = logic [4:0],
  /// Number of outstanding memory transactions.
  parameter int unsigned NumOutstandingMem   = 1,
  /// Number of outstanding loads.
  parameter int unsigned NumOutstandingLoads = 1,
  /// Whether to instantiate a consistency address queue (CAQ). The CAQ enables
  /// consistency with another LSU in the same hart (i.e. in the FPSS) strictly
  /// *downstream* of the issuing Snitch core. For all offloaded accesses, the
  /// word address LSBs are pushed into the Snitch core's CAQ on offload and
  /// popped when completed by the downstream LSU. Incoming accesses possibly
  /// overtaking pending downstream accesses in the CAQ are stalled.
  parameter bit          Caq                 = 0,
  /// CAQ Depth; should match the number of downstream LSU outstanding requests.
  parameter int unsigned CaqDepth            = 0,
  /// Size of CAQ address LSB tags; provides a pessimism-complexity tradeoff.
  parameter int unsigned CaqTagWidth         = 0,
  /// Whether this LSU is a source of CAQ responses (e.g. FPSS).
  parameter bit          CaqRespSrc          = 0,
  /// Whether the LSU should track repeated instructions issued by a sequencer
  /// and accordingly filter them from its CAQ responses as is necessary.
  parameter bit          CaqRespTrackSeq     = 0,
  localparam type addr_t = logic [AddrWidth-1:0],
  localparam type data_t = logic [DataWidth-1:0]
) (
  input  logic clk_i,
  input  logic rst_i,

  // Trace output
  // pragma translate_off
  output issue_lsu_trace_t trace_o,
  // pragma translate_on

  // Instruction stream
  input  issue_req_t issue_req_i,
  input  logic       issue_req_valid_i,
  input  logic       issue_commit_i,
  output logic       issue_req_ready_o,
  output data_t      result_o,
  output tag_t       tag_o,
  output logic       result_error_o,
  output logic       result_valid_o,
  input  logic       result_ready_i,
  output logic       busy_o,
  // High if there is currently no transaction pending.
  output logic       empty_o,
  output logic       addr_misaligned_o,

  // LSU memory interface
  output dreq_t data_req_o,
  input  drsp_t data_rsp_i,

  // Consistency address queue snoop channel. Only some address bits will be read.
  // Fork offloaded loads/stores to here iff `Caq` is 1.
  input  addr_t caq_addr_i,
  // Whether the CAQ should track this write of the other LSU. (was named `caq_is_fp_store_i`).
  input  logic  caq_track_write_i,
  input  logic  caq_req_valid_i,
  output logic  caq_req_ready_o,
  // Incoming CAQ response snoop channel.
  // Fork responses to offloaded loads/stores to here iff `Caq` is 1.
  input  logic caq_rsp_valid_i,
  // Outgoing CAQ response snoop channel.
  // Signals whether access response was handshaked iff `CaqResp` is 1.
  // Unconnected for the integer LSU
  output logic caq_rsp_valid_o
);

  localparam int unsigned DataAlign = $clog2(DataWidth/8);

  // -------------------------------
  // Decoding
  // -------------------------------
  logic [XLEN-1:0]     address; // 32 bit address
  addr_t               address_sys; // Address in system type
  data_t               store_data;
  logic                is_store;
  logic                is_signed;
  logic                do_nan_boxing;
  lsu_size_e           ls_size;
  reqrsp_pkg::amo_op_e ls_amo;

  // Compute the address
  // For the superscalar case we cannot use the ALU for this computation.
  // Therefore, we create a separate adder.
  // !! We may only take the lower XLEN bits as the operands are NOT sign extended
  // to OpLen (OpLen = FLEN > XLEN ? FLEN : XLEN)
  assign address = issue_req_i.fu_data.operand_a[XLEN-1:0] + issue_req_i.fu_data.imm[XLEN-1:0];

  // Convert the 32bit address to a system address.
  always_comb begin
    address_sys = '0;
    address_sys[XLEN-1:0] = address;
  end

  // Sign extend the data to be stored to the appropriate length
  assign store_data = $unsigned(issue_req_i.fu_data.operand_b);

  // Control signals
  assign is_store  = issue_req_i.fu_data.lsu_op inside {LsuOpStore, LsuOpFpStore};
  // All FP loads are signed to NaN box narrower values than FLEN
  assign is_signed = issue_req_i.fu_data.lsu_op inside {LsuOpLoad, LsuOpAmoLr, LsuOpAmoSc,
                                                        LsuOpAmoSwap, LsuOpAmoAdd, LsuOpAmoXor,
                                                        LsuOpAmoAnd, LsuOpAmoOr, LsuOpAmoMin,
                                                        LsuOpAmoMax, LsuOpAmoMinU, LsuOpAmoMaxU,
                                                        LsuOpFpLoad};

  // Whether to apply NaN boxing or not
  assign do_nan_boxing = issue_req_i.fu_data.lsu_op inside {LsuOpFpLoad, LsuOpFpStore};
  assign ls_size       = issue_req_i.fu_data.lsu_size;

  always_comb begin
    unique case (issue_req_i.fu_data.lsu_op)
      LsuOpAmoLr:   ls_amo = reqrsp_pkg::AMOLR;
      LsuOpAmoSc:   ls_amo = reqrsp_pkg::AMOSC;
      LsuOpAmoSwap: ls_amo = reqrsp_pkg::AMOSwap;
      LsuOpAmoAdd:  ls_amo = reqrsp_pkg::AMOAdd;
      LsuOpAmoXor:  ls_amo = reqrsp_pkg::AMOXor;
      LsuOpAmoAnd:  ls_amo = reqrsp_pkg::AMOAnd;
      LsuOpAmoOr:   ls_amo = reqrsp_pkg::AMOOr;
      LsuOpAmoMin:  ls_amo = reqrsp_pkg::AMOMin;
      LsuOpAmoMax:  ls_amo = reqrsp_pkg::AMOMax;
      LsuOpAmoMinU: ls_amo = reqrsp_pkg::AMOMinu;
      LsuOpAmoMaxU: ls_amo = reqrsp_pkg::AMOMaxu;
      default:      ls_amo = reqrsp_pkg::AMONone;
    endcase
  end

  // Unaligned Address Check
  always_comb begin
    addr_misaligned_o = 1'b0;
    unique case (ls_size)
      HalfWord: if (address_sys[0] != 1'b0)     addr_misaligned_o = 1'b1;
      Word:     if (address_sys[1:0] != 2'b00)  addr_misaligned_o = 1'b1;
      Double:   if (address_sys[2:0] != 3'b000) addr_misaligned_o = 1'b1;
      default:  addr_misaligned_o = 1'b0;
    endcase
  end

  // The LSU is busy as long as it is not empty.
  assign busy_o = !empty_o;

  // --------------------
  // Snitch compatibility
  // --------------------
  // To keep the similarity / compatibility to the Snitch LSU we reuse the same "interface".

  // Request channel
  tag_t lsu_qtag_i;
  logic lsu_qwrite_i;
  logic lsu_qsigned_i;
  // Whether to NaN Box values. Used for floating-point load/stores.
  logic                 lsu_nan_box_i;
  addr_t                lsu_qaddr_i; // Address to load from / store to
  data_t                lsu_qdata_i; // The data to store
  logic [1:0]           lsu_qsize_i;
  reqrsp_pkg::amo_op_e  lsu_qamo_i;
  logic                 lsu_qrepd_i; // If it is a sequencer repetition
  logic                 lsu_qvalid_i;
  logic                 lsu_qready_o;
  // Response channel
  data_t lsu_pdata_o; // The loaded data
  tag_t  lsu_ptag_o;
  logic  lsu_perror_o; // Ignored for the moment
  logic  lsu_pvalid_o;
  logic  lsu_pready_i;
  logic  lsu_empty_o;
  // CAQ
  addr_t caq_qaddr_i;
  logic  caq_qwrite_i;
  logic  caq_qvalid_i;
  logic  caq_qready_o;
  logic  caq_pvalid_i;
  logic  caq_pvalid_o;

  // Request
  assign lsu_qtag_i        = issue_req_i.tag;
  assign lsu_qwrite_i      = is_store;
  assign lsu_qsigned_i     = is_signed;
  assign lsu_nan_box_i     = do_nan_boxing;
  assign lsu_qsize_i       = ls_size;
  assign lsu_qamo_i        = ls_amo;
  assign lsu_qrepd_i       = 1'b0;
  assign lsu_qaddr_i       = address_sys;
  assign lsu_qdata_i       = store_data;
  // Only pass the request downstream when we commit to the issue request.
  assign lsu_qvalid_i      = issue_req_valid_i & issue_commit_i;
  assign issue_req_ready_o = lsu_qready_o;
  // Response
  assign result_o       = lsu_pdata_o;
  assign tag_o          = lsu_ptag_o;
  assign result_error_o = lsu_perror_o;
  assign result_valid_o = lsu_pvalid_o;
  assign lsu_pready_i   = result_ready_i;
  assign empty_o        = lsu_empty_o;

  // Consistency address queue
  assign caq_qaddr_i     = caq_addr_i;
  assign caq_qwrite_i    = caq_track_write_i;
  assign caq_qvalid_i    = caq_req_valid_i;
  assign caq_req_ready_o = caq_qready_o;
  assign caq_pvalid_i    = caq_rsp_valid_i;
  assign caq_rsp_valid_o = caq_pvalid_o; // unconnected for the integer LSU
  // The actual memory interface (data_req_o, data_rsp_i) is the same

  // -------------------------------
  // Consistency Address Queue (CAQ)
  // -------------------------------

  // TODO: What about exceptions? We *should* get a response for all offloaded
  // loads/stores anyways as already issued instructions should conclude, but
  // if this is not the case, things go south!

  logic lsu_postcaq_qvalid, lsu_postcaq_qready;

  if (Caq) begin : gen_caq

    logic caq_lsu_gnt, caq_lsu_exists;
    logic caq_out_valid, caq_out_gnt;
    logic caq_pass, caq_alters_mem;

    // CAQ passes requests to downstream LSU only once they are known not to collide.
    // This is assumed to be *stable* once given as the Snitch core is stalled on a
    // load/store and elements can only be popped from the queue, not pushed.
    assign caq_pass = caq_lsu_gnt & ~caq_lsu_exists;

    // We need to stall on collisions with anything altering memory, including atomics
    assign caq_alters_mem = lsu_qwrite_i | (lsu_qamo_i != reqrsp_pkg::AMONone);

    // Gate downstream LSU on CAQ pass
    assign lsu_postcaq_qvalid = caq_pass & lsu_qvalid_i;
    assign lsu_qready_o = caq_pass & lsu_postcaq_qready;

    id_queue #(
      .data_t    ( logic [CaqTagWidth:0] ), // Store address tag *and* write enable
      .ID_WIDTH  ( 1 ),                     // De facto 0: no reorder capability here
      .CAPACITY  ( CaqDepth ),
      .FULL_BW   ( 1 )
    ) i_caq (
      .clk_i,
      .rst_ni   ( ~rst_i ),
      // Push in snooped accesses offloaded to downstream LSU
      .inp_id_i   ( '0 ),
      .inp_data_i ( {caq_qwrite_i, caq_qaddr_i[CaqTagWidth+DataAlign-1:DataAlign]} ),
      .inp_req_i  ( caq_qvalid_i ),
      .inp_gnt_o  ( caq_qready_o ),
      // Check if currently presented request collides with any snooped ones.
      // Check address tag in any case. Check the write enable only when it
      // is necessary. If we receive a write, stall on any address match
      // (i.e. exclude MSB from the collision check, can be 0 or 1). If we
      // receive a non-altering access, we stall only if a write collides.
      .exists_mask_i  ( {~caq_alters_mem, {(CaqTagWidth){1'b1}}} ),
      .exists_data_i  ( {1'b1, lsu_qaddr_i[CaqTagWidth+DataAlign-1:DataAlign]} ),
      .exists_req_i   ( lsu_qvalid_i ),
      .exists_gnt_o   ( caq_lsu_gnt ),
      .exists_o       ( caq_lsu_exists ),
      // Pop output whenever we get a response for a snooped request.
      // This has no backpressure as we should snoop as many responses as requests.
      .oup_id_i         ( '0 ),
      .oup_pop_i        ( caq_pvalid_i ),
      .oup_req_i        ( caq_pvalid_i ),
      .oup_data_o       (  ),
      .oup_data_valid_o ( caq_out_valid ),
      .oup_gnt_o        ( caq_out_gnt )
    );

    // Check that we do not pop more snooped responses than we pushed requests.
    `ASSERT(CaqPopEmpty, (caq_pvalid_i |-> caq_out_gnt && caq_out_valid), clk_i, rst_i)

    // Check that once asserted, `caq_pass` is stable until we handshake the load/store
    `ASSERT(CaqPassStable, ($rose(caq_pass) |->
        (caq_pass until_with lsu_qvalid_i & lsu_qready_o)), clk_i, rst_i)

  end else begin : gen_no_caq

    // No CAQ can stall us; forward request handshake to LSU logic
    assign lsu_postcaq_qvalid = lsu_qvalid_i;
    assign lsu_qready_o = lsu_postcaq_qready;

    // Tie CAQ interface
    assign caq_qready_o = '1;

  end

  // --------------
  // Downstream LSU
  // --------------

  logic [63:0] ld_result;
  logic [63:0] lsu_qdata, data_qdata;

  typedef struct packed {
    tag_t                  tag;
    logic                  sign_ext;
    logic                  nan_box;
    logic [DataAlign-1:0] offset;
    logic [1:0]            size;
  } laq_t;

  // Load Address Queue (LAQ)
  laq_t laq_in, laq_out;
  logic mem_out;
  logic laq_full, mem_full;
  logic laq_push;

  fifo_v3 #(
    .FALL_THROUGH ( 1'b0                ),
    .DEPTH        ( NumOutstandingLoads ),
    .dtype        ( laq_t               )
  ) i_fifo_laq (
    .clk_i,
    .rst_ni (~rst_i),
    .flush_i (1'b0),
    .testmode_i(1'b0),
    .full_o (laq_full),
    .empty_o (/* open */),
    .usage_o (/* open */),
    .data_i (laq_in),
    .push_i (laq_push),
    .data_o (laq_out),
    .pop_i (data_rsp_i.p_valid & data_req_o.p_ready & ~mem_out)
  );

  // For each memory transaction save whether this was a load or a store. We
  // need this information to suppress stores.
  logic [CaqRespTrackSeq:0] req_queue_in, req_queue_out;

  assign req_queue_in[0] = lsu_qwrite_i;
  assign mem_out = req_queue_out[0];

  if (CaqRespTrackSeq) begin : gen_caq_resp_track_seq
    assign req_queue_in[1] = lsu_qrepd_i;
    // When tracking a sequencer, repeated accesses are masked as the core issues them only once.
    // Thus, for sequenced loads or stores, only the *first issue* is popped in the CAQ.
    // This means that the first issue will block on collisions and subsequent repeats will not.
    // Like SSRs, loads or stores in sequencer loops (i.e. FREP) do *not* guarantee consistency.
    assign caq_pvalid_o = data_rsp_i.p_valid & data_req_o.p_ready & ~req_queue_out[1];
  end else begin : gen_no_caq_resp_track_seq
    // When not tracking a sequencer, simply signal the response handshake.
    assign caq_pvalid_o = data_rsp_i.p_valid & data_req_o.p_ready;
  end

  fifo_v3 #(
    .FALL_THROUGH (1'b0),
    .DEPTH (NumOutstandingMem),
    .DATA_WIDTH (1 + CaqRespTrackSeq)
  ) i_fifo_mem (
    .clk_i,
    .rst_ni (~rst_i),
    .flush_i (1'b0),
    .testmode_i (1'b0),
    .full_o (mem_full),
    .empty_o (lsu_empty_o),
    .usage_o ( /* open */ ),
    .data_i (req_queue_in),
    .push_i (data_req_o.q_valid & data_rsp_i.q_ready),
    .data_o (req_queue_out),
    .pop_i (data_rsp_i.p_valid & data_req_o.p_ready)
  );

  assign laq_in = '{
    tag:      lsu_qtag_i,
    sign_ext: lsu_qsigned_i,
    nan_box:  lsu_nan_box_i,
    offset:   lsu_qaddr_i[DataAlign-1:0],
    size:     lsu_qsize_i
  };

  // Only make a request when we got a valid request and if it is a load also
  // check that we can actually store the necessary information to process it in
  // the upcoming cycle(s).
  assign data_req_o.q_valid = lsu_postcaq_qvalid & (lsu_qwrite_i | ~laq_full) & ~mem_full;
  assign data_req_o.q.write = lsu_qwrite_i;
  assign data_req_o.q.addr = lsu_qaddr_i;
  assign data_req_o.q.amo  = lsu_qamo_i;
  assign data_req_o.q.size = lsu_qsize_i;

  // Generate byte enable mask.
  always_comb begin
    unique case (lsu_qsize_i)
      2'b00: data_req_o.q.strb = ('b1 << lsu_qaddr_i[DataAlign-1:0]);
      2'b01: data_req_o.q.strb = ('b11 << lsu_qaddr_i[DataAlign-1:0]);
      2'b10: data_req_o.q.strb = ('b1111 << lsu_qaddr_i[DataAlign-1:0]);
      2'b11: data_req_o.q.strb = '1;
      default: data_req_o.q.strb = '0;
    endcase
  end

  // Re-align write data.
  /* verilator lint_off WIDTH */
  assign lsu_qdata = $unsigned(lsu_qdata_i);
  always_comb begin
    unique case (lsu_qaddr_i[DataAlign-1:0])
      3'b000: data_qdata = lsu_qdata;
      3'b001: data_qdata = {lsu_qdata[55:0], lsu_qdata[63:56]};
      3'b010: data_qdata = {lsu_qdata[47:0], lsu_qdata[63:48]};
      3'b011: data_qdata = {lsu_qdata[39:0], lsu_qdata[63:40]};
      3'b100: data_qdata = {lsu_qdata[31:0], lsu_qdata[63:32]};
      3'b101: data_qdata = {lsu_qdata[23:0], lsu_qdata[63:24]};
      3'b110: data_qdata = {lsu_qdata[15:0], lsu_qdata[63:16]};
      3'b111: data_qdata = {lsu_qdata[7:0],  lsu_qdata[63:8]};
      default: data_qdata = lsu_qdata;
    endcase
  end
  assign data_req_o.q.data = data_qdata[DataWidth-1:0];
  /* verilator lint_on WIDTH */

  // The interface didn't accept our request yet
  assign lsu_postcaq_qready = ~(data_req_o.q_valid & ~data_rsp_i.q_ready)
                      & (lsu_qwrite_i | ~laq_full) & ~mem_full;
  assign laq_push = ~lsu_qwrite_i & data_rsp_i.q_ready & data_req_o.q_valid & ~laq_full;

  // Return Path
  // shift the load data back
  logic [63:0] shifted_data;
  assign shifted_data = data_rsp_i.p.data >> {laq_out.offset, 3'b000};
  always_comb begin
    unique case (laq_out.size)
      2'b00: begin
        ld_result =
          {{56{(shifted_data[7] | laq_out.nan_box) & laq_out.sign_ext}}, shifted_data[7:0]};
      end
      2'b01: begin
        ld_result =
          {{48{(shifted_data[15] | laq_out.nan_box) & laq_out.sign_ext}}, shifted_data[15:0]};
      end
      2'b10: begin
        ld_result =
          {{32{(shifted_data[31] | laq_out.nan_box) & laq_out.sign_ext}}, shifted_data[31:0]};
      end
      2'b11: begin
        ld_result = shifted_data;
      end
      default: ld_result = shifted_data;
    endcase
  end

  assign lsu_perror_o = data_rsp_i.p.error;
  assign lsu_pdata_o = ld_result[DataWidth-1:0];
  assign lsu_ptag_o = laq_out.tag;
  // In case of a write, don't signal a valid transaction. Stores are always
  // without ans answer to the core.
  assign lsu_pvalid_o = data_rsp_i.p_valid & ~mem_out;
  assign data_req_o.p_ready = lsu_pready_i | mem_out;

  ////////////
  // Tracer //
  ////////////

  // pragma translate_off
  assign trace_o = '{
    valid:          issue_req_valid_i && issue_req_ready_o,
    instr_iter:     '0, // does not apply in regular execution
    producer:       "", // will be set by fu_stage
    lsu_store_data: longint'(store_data),
    lsu_is_float:   longint'(do_nan_boxing),
    lsu_is_load:    longint'(!is_store),
    lsu_is_store:   longint'(is_store),
    lsu_addr:       longint'(address_sys),
    lsu_size:       longint'(ls_size),
    lsu_amo:        longint'(ls_amo)
  };
  // pragma translate_on

endmodule
