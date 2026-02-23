// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"

// The CSR module which hosts all CSR, handles all CSR instructions,
// and handles counters as well as interrupts.
//
// The fu_data_i must hold the following data:
//   - operand a = rs1 value or rs1 address
//   - operand b = rs2 value which is invalid for CSR instructions
//   - imm = CSR Address. CAVE: It is sign extended, use only first 12 bits!
//
// This CSR module has its own simple logic for the bit clear and set instructions.
// It probably could be improved by using the ALU for the bit manipulation.
// However, for simplicity (especially in regard to the superscalar loop execution) it was decided
// to implement the bit manipulation in the CSR module with additional logic.
//
// The CSR module is also directly connected to the dispatcher and has no reservation station.
//
// This module implements all machine level CSRs defined by the RISC-V standard version 20240411.
// It also implements a few of the supervisor level CSRs (incomplete) and custom CSRs to be
// compatible with the original snitch implementation.
//
// Deviations from the RISC-V standard:
// - fcsr:       This CSR contains additional fmode bits not specified in the standard.
// - m/sepc:     The last 1 or 2 bits are not fixed to zero.
// - mconfigptr: Is not implemented despite it should be read only zero. Snitch & we raise an
//               illegal instruction exception.
// - mcycle:     Is read only instead of RW
// - satp:       When reading this CSR, the ASID bits are neglected. As of this the mode bit
//               is not at the specified location. However, when writing, the mode bit is written
//               at the correct location. TODO: This is actually a bug in the snitch design.
//               For now, we keep this deviation to ensure compatibility with the Snitch runtime.
//
// Additional custom CSR registers:
// - CSR_BARRIER: Custom cluster barrier register.
//     This register is used to synchronize all cores in a cluster. The current snitch runtime
//     performs a csrr pseudo instruction to start the waiting (see sync.h).
//     This csrr defined as "csrr rd, csr_addr" is encoded as "csrrs rd, csr_addr, x0".
//     The CSRRS instruction however does not write the CSR if rs1 = x0.
//     Therefore, the side effect is implemented in the READ part of the CSR module.
//     Reading this CSR sets the barrier_stall signal. It is reset when the core external
//     signal "barrier_stall_i" is set.
// - FREP_STATE (R): Custom register to read current HW configuration for superscalar FREP mode
//    This register contains information about the number of functional units and slots per FU.
//    It contains the information for ALUs, LSUs and FPUs. Each FU has (5,4) bits for number of
//    slots and number of functional units. The 32-bit format is:
//  |    31:27 |         26:22 |    21:18 |         17:13 |     12:9 |           8:4 |      3:0 |
//  | Reserved | Nof FPU Slots | Nof FPUs | Nof LSU Slots | Nof LSUs | Nof ALU Slots | Nof ALUs |
// - FREP_CONFIG (RW): Custom register for fine grained control over the dispatch process.
//     Bits 2:0: Memory consistency mode.
//       - 3'b000: No memory consistency. Use all available LSUs in increasing order
//       - 3'b001: Serialize all memory operations by using only one LSU. This allows to keep
//                 memory consistency but less performance.
//       - 3'b010: Separate load and store streams onto separate LSUs. Not yet implemented.
//                 Probably needs another field to configure which LSU is for what stream.
//       - Other values are reserved.
//     Bits 31:3: Reserved
//
// Deviations from the Snitch design:
// - CsrMseg: Is not implemented as it is SSR (stream sematic register) specific.
//
// Counters:
// - None implemented.
//
// Interrupts:
// Next to the standard interrupts, there are two custom interrupts implemented:
// - mcip (19) and scip (17). These originate from the original Snitch design.
//
// !!! CAVE !!!
// CSRRW & CSRRWI: If rd = x0, don't read the CSR / don't cause any side effects!
//                 As long as there is no CSR with a read side effect, we can ignore this.
//                 All other CSR instructions always read from rd and cause side effects
//                 (even if rd = x0).
module schnizo_csr import schnizo_pkg::*; #(
  parameter int unsigned XLEN         = 32,
  parameter bit          DebugSupport = 0,
  // F extension enabled
  parameter bit          RVF          = 0,
  // D extension enabled
  parameter bit          RVD          = 0,
  /// Enable Snitch DMA as accelerator.
  parameter bit          Xdma         = 0,
  /// Enable virtual memory support.
  parameter bit          VMSupport    = 0,
  parameter type         issue_req_t  = logic,
  parameter type         result_tag_t = logic,
  // Parameter for custom FREP CSR
  parameter int unsigned NofAlus      = 3,
  parameter int unsigned AluNofRss    = 2,
  parameter int unsigned NofLsus      = 3,
  parameter int unsigned LsuNofRss    = 3,
  parameter int unsigned NofFpus      = 3,
  parameter int unsigned FpuNofRss    = 3
) (
  input  logic      clk_i,
  input  logic      rst_i,

  // Dispatcher handshake
  input  issue_req_t issue_req_i,
  input  logic       issue_req_valid_i,
  output logic       issue_req_ready_o,

  // Asserted if the CSR instruction causes an exception
  // (i.e., illegal address, insufficient privileges).
  output logic illegal_csr_instr_o,

  // Register file write back handshake
  output logic [XLEN-1:0] result_o,
  output result_tag_t     result_tag_o,
  output logic            result_valid_o,
  input  logic            result_ready_i,

  /// Core & cluster specific signals
  // Exception, interrupt and privilege transition control signals
  // External interrupts
  input  snitch_pkg::interrupts_t irq_i,
  input  logic                    enter_wfi_i,
  input  logic[31:0]              pc_i,
  input  logic                    illegal_instr_i,
  input  logic                    ecall_i,
  input  logic                    ebreak_i,
  input  logic                    instr_addr_misaligned_i,
  input  logic                    load_addr_misaligned_i,
  input  logic                    store_addr_misaligned_i,
  input  logic                    exception_i,
  input  logic                    mret_i,
  input  logic                    sret_i,
  // If an interrupt is served
  output logic                    interrupt_o,
  output logic[31:0]              mtvec_o,
  output logic[31:0]              mepc_o,
  output logic[31:0]              sepc_o,
  output logic                    wfi_o,
  output priv_lvl_t               priv_lvl_o,
  // The hart currently running
  input  logic [XLEN-1:0]         hart_id_i,
  // Custom cluster barrier stall signals
  input  logic                    barrier_i,
  output logic                    barrier_o,
  output logic                    barrier_stall_o,
  // FREP configuration
  output frep_mem_cons_mode_e     frep_mem_cons_mode_o,
  // FPU state update from the retiring FPU instruction
  input  fpnew_pkg::status_t      fpu_status_i,
  input  logic                    fpu_status_valid_i,
  // Current FPU configuration
  output fpnew_pkg::roundmode_e   fpu_rnd_mode_o,
  output fpnew_pkg::fmt_mode_t    fpu_fmt_mode_o,

  /// Performance counters
  // Asserted if the current cycle retires an instruction
  input  logic                     instr_retired_i
);
  // Exception causes codes
  localparam logic [30:0] InstrAddrMisaligned  = 0;
  localparam logic [30:0] InstrAccessFault     = 1;
  localparam logic [30:0] IllegalInstr         = 2;
  localparam logic [30:0] Breakpoint           = 3;
  localparam logic [30:0] LoadAddrMisaligned   = 4;
  localparam logic [30:0] LoadAccessFault      = 5;
  localparam logic [30:0] StoreAddrMisaligned  = 6;
  localparam logic [30:0] StoreAccessFault     = 7;
  localparam logic [30:0] EnvCallUMode         = 8;  // environment call from user mode
  localparam logic [30:0] EnvCallSMode         = 9;  // environment call from supervisor mode
  localparam logic [30:0] EnvCallMMode         = 11; // environment call from machine mode
  localparam logic [30:0] InstrPageFault       = 12; // Instruction page fault
  localparam logic [30:0] LoadPageFault        = 13; // Load page fault
  localparam logic [30:0] StorePageFault       = 15; // Store page fault

  // Interrupt codes
  localparam logic [30:0] IrqMsi = 3;
  localparam logic [30:0] IrqMti = 7;
  localparam logic [30:0] IrqMei = 11;
  localparam logic [30:0] IrqMci = 19;
  localparam logic [30:0] IrqSsi = 1;
  localparam logic [30:0] IrqSti = 5;
  localparam logic [30:0] IrqSei = 9;
  localparam logic [30:0] IrqSci = 17;

  // The 12bit CSR addresses are defined in the generated riscv_instr.sv file.
  // These are snitch / schnizo specific due to custom CSRs.
  typedef struct packed {
    logic [1:0] rw;
    priv_lvl_t  priv_lvl;
    logic [7:0] address;
  } csr_addr_t;

  typedef union packed {
    logic [11:0] address;
    csr_addr_t   csr_decoded;
  } csr_t;

  // Extension state.
  typedef enum logic [1:0] {
    XOff = 2'b00,
    XInitial = 2'b01,
    XClean = 2'b10,
    XDirty = 2'b11
  } x_state_e;

  typedef struct packed {
    logic       sd;    // signal dirty - read-only - hardwired zero for non FP and to one for FP.
    logic [7:0] wpri3; // writes preserved reads ignored
    logic       tsr;   // trap sret
    logic       tw;    // timeout wait
    logic       tvm;   // trap virtual memory
    logic       mxr;   // make executable readable
    logic       sum;   // permit supervisor user memory access
    logic       mprv;  // modify privilege - privilege level for ld/st
    x_state_e   xs;    // extension register - hardwired to zero
    x_state_e   fs;    // extension register - hardwired to zero for non FP and to Dirty for FP.
    priv_lvl_t  mpp;   // holds the previous privilege mode up to machine
    x_state_e   vs;    // status of the vector extension state
    logic       spp;   // holds the previous privilege mode up to supervisor
    logic       mpie;  // machine interrupts enable bit active prior to trap
    logic       ube;   // U Mode big endian
    logic       spie;  // supervisor interrupts enable bit active prior to trap
    logic       wpri2; // ? user interrupts enable bit active prior to trap - hardwired to zero
    logic       mie;   // machine interrupts enable
    logic       wpri1; // writes preserved reads ignored
    logic       sie;   // supervisor interrupts enable
    logic       wpri0; // writes preserved reads ignored
  } mstatus_rv32_t;

  typedef struct packed {
    logic [25:0] wpri5; // writes preserved reads ignored
    logic        mbe;   // M Mode big endian
    logic        sbe;   // S Mode big endian
    logic [3:0]  wpri4; // writes preserved reads ignored
  } mstatush_rv32_t;

  // contains only the default interrupts
  // keep mip_t and mie_t in sync for easier handling.
  typedef struct packed {
    // custom interrupts
    logic [XLEN-1:20] zero10; // unused platform specific interrupts, hardwired zero
    logic mcip;  // Sntich custom interrupt ?
    logic         zero9; // hardwired zero
    logic scip;   // Snitch custom interrupt.. ?
    logic         zero8; // hardwired zero
    // default interrupts
    logic [15:14] zero7; // hardwired zero
    logic lcofip; // local counter-overflow interrupts, for Sscofpmf extension. Else readonly zero.
    logic         zero6;  // hardwired zero
    logic meip;   // machine-level external interrupt pending, read only
    logic         zero5;  // hardwired zero
    logic seip;   // supervisor-level external interrupt pending writeable. Zero if no S mode.
    logic         zero4;  // hardwired zero
    logic mtip;   // machine timer interrupt pending, read only
    logic         zero3;  // hardwired zero
    logic stip;   // supervisor-level timer interrupts pending, writeable. Zero if no S mode.
    logic         zero2;  // hardwired zero
    logic msip;   // machine-level software interrupt pending, read only
    logic         zero1;  // hardwired zero
    logic ssip;   // supervisor-level software interrupts pending, writeable. Zero if no S mode.
    logic         zero0;  // hardwired zero
  } mip_t;

  typedef struct packed {
    // custom interrupts
    logic [XLEN-1:20] zero10; // unused platform specific interrupts, hardwired zero
    logic mcie;   // Snitch custom interrupt ?
    logic         zero9; // hardwired zero
    logic scie;   // Snitch custom interrupt ?
    logic         zero8; // hardwired zero
    // default interrupts
    logic [15:14] zero7;     // hardwired zero
    logic lcofie; // local counter-overflow interrupts, for Sscofpmf extension. Else readonly zero.
    logic         zero6;  // hardwired zero
    logic meie;   // machine-level external interrupt enabled
    logic         zero5;  // hardwired zero
    logic seie;   // supervisor-level external interrupt enabled. Zero if no S mode
    logic         zero4;  // hardwired zero
    logic mtie;   // machine timer interrupt enabled
    logic         zero3;  // hardwired zero
    logic stie;   // supervisor-level timer interrupts enabled. Zero if no S mode
    logic         zero2;  // hardwired zero
    logic msie;   // machine-level software interrupt enabled
    logic         zero1;  // hardwired zero
    logic ssie;   // supervisor-level software interrupts enabled. Zero if no S mode
    logic         zero0;  // hardwired zero
  } mie_t;

  typedef struct packed {
    logic interrupt;
    logic [XLEN-2:0] exception_code;
  } mcause_t;

  // This typedef is not according to the standard!
  typedef struct packed {
    logic mode;
    logic [21:0] ppn;
  } satp_t;

  // The format of the FREP STATE CSR
  typedef struct packed {
    logic [4:0] FpuSlots;
    logic [3:0] Fpus;
    logic [4:0] LsuSlots;
    logic [3:0] Lsus;
    logic [4:0] AluSlots;
    logic [3:0] Alus;
  } frep_state_t;

  typedef struct packed {
    logic [31:3]         reserved;
    frep_mem_cons_mode_e mem_constistency_mode;
  } frep_config_t;

  // ---------------------------
  // CSR control signals
  // ---------------------------
  logic csr_read_en;
  logic csr_write_en, csr_write_en_int;
  logic [XLEN-1:0] csr_wdata, csr_rdata;
  logic illegal_csr_read;

  csr_t csr_addr;
  assign csr_addr = issue_req_i.fu_data.imm[11:0];

  // ---------------------------
  // CSR registers
  // ---------------------------
  // Machine status
  mstatus_rv32_t mstatus_d, mstatus_q, mstatus_reset;
  mstatush_rv32_t mstatush_d, mstatush_q;
  assign mstatus_reset = '{
    sd    : '1, // hardwired if FPU is present
    wpri3 : '0,
    tsr   : '0,
    tw    : '0,
    tvm   : '0,
    mxr   : '0,
    sum   : '0,
    mprv  : '0,
    xs    : XOff,
    fs    : XDirty, // Hardwired if FPU is present
    mpp   : PrivLvlU, // snitch: own FF. Reset to PrivLvlU
    vs    : XOff,
    spp   : '0, // snitch: own FF. Reset to 0
    mpie  : '0, // snitch: own FF -> pie_q[M]. Reset to 0
    ube   : '0,
    spie  : '0,
    wpri2 : '0,
    mie   : '0, // snitch: own FF -> ie_q[M]. Reset to 0
    wpri1 : '0,
    sie   : '0,
    wpri0 : '0
  };

  `FFAR(mstatus_q, mstatus_d, mstatus_reset, clk_i, rst_i);
  `FFAR(mstatush_q, mstatush_d, '0, clk_i, rst_i); // TODO: are these reset values correct?

  // we dont support the vectorized trap base -> last two bits are always zero.
  logic [31:2] mtvec_q, mtvec_d;
  `FFAR(mtvec_q, mtvec_d, '0, clk_i, rst_i);

  // Interrupts
  logic meip, mtip, msip, mcip;
  logic seip, stip, ssip, scip;
  logic interrupts_enabled;
  logic any_interrupt_pending;
  mip_t mip_q, mip_d;
  mie_t mie_q, mie_d;
  `FFAR(mip_q, mip_d, '0, clk_i, rst_i);
  `FFAR(mie_q, mie_d, '0, clk_i, rst_i);

  // Scratch register
  logic [XLEN-1:0] mscratch_q, mscratch_d;
  `FFAR(mscratch_q, mscratch_d, '0, clk_i, rst_i);
  logic [XLEN-1:0] sscratch_q, sscratch_d;
  `FFAR(sscratch_q, sscratch_d, '0, clk_i, rst_i);

  // Exception program counter
  logic [XLEN-1:0] mepc_q, mepc_d;
  `FFAR(mepc_q, mepc_d, '0, clk_i, rst_i);
  logic [XLEN-1:0] sepc_q, sepc_d;
  `FFAR(sepc_q, sepc_d, '0, clk_i, rst_i);

  // Exception cause
  mcause_t mcause_q, mcause_d;
  `FFAR(mcause_q, mcause_d, '0, clk_i, rst_i);

  // Supervisor only CSRs
  // Supervisor Address Translation and Protection
  satp_t satp_q, satp_d;
  `FFAR(satp_q, satp_d, '0, clk_i, rst_i);

  // Extension CSRs
  // Floating point control and status register
  typedef struct packed {
    fpnew_pkg::fmt_mode_t  fmode; // Non RISC-V mode? Maybe for alternate floating point formats?
    fpnew_pkg::roundmode_e frm;
    fpnew_pkg::status_t    fflags;
  } fcsr_t;
  fcsr_t fcsr_d, fcsr_q;
  `FFAR(fcsr_q, fcsr_d, '0, clk_i, rst_i)

  // Custom cluster barrier
  logic barrier_stall_d, barrier_stall_q;
  `FFAR(barrier_stall_q, barrier_stall_d, '0, clk_i, rst_i)

  // Privileges
  priv_lvl_t priv_lvl_q, priv_lvl_d;
  `FFAR(priv_lvl_q, priv_lvl_d, PrivLvlM, clk_i, rst_i);

  // Wait for interrupt
  logic wfi_d, wfi_q;
  `FFAR(wfi_q, wfi_d, '0, clk_i, rst_i)

  // ---------------------------
  // Performance Counters
  // ---------------------------
  logic [63:0] cycle_q;
  logic [63:0] instret_q;
  `FFAR(cycle_q, cycle_q + 1, '0, clk_i, rst_i)
  `FFLAR(instret_q, instret_q + 1, instr_retired_i, '0, clk_i, rst_i)

  // ---------------------------
  // FREP Config
  // ---------------------------
  frep_state_t frep_state;

  assign frep_state = '{
    FpuSlots: FpuNofRss[4:0],
    Fpus:     NofFpus[3:0],
    LsuSlots: LsuNofRss[4:0],
    Lsus:     NofLsus[3:0],
    AluSlots: AluNofRss[4:0],
    Alus:     NofAlus[3:0]
  };

  // FREP config
  frep_config_t frep_config_d, frep_config_q;
  frep_config_t frep_config_default;
  assign frep_config_default = '{
    reserved: '0,
    mem_constistency_mode: FrepMemNoConsistency
  };
  `FFAR(frep_config_q, frep_config_d, frep_config_default, clk_i, rst_i);

  // ---------------------------
  // CSR operand control
  // ---------------------------
  // This part controls if a CSR is read and/or written and also computes the write data.
  // Feed through the tag (contains rd address).
  assign result_tag_o = issue_req_i.tag;

  always_comb begin : csr_control
    csr_wdata = csr_rdata; // Per default change nothing
    csr_read_en = 1'b1;
    csr_write_en = 1'b1;

    unique case (issue_req_i.fu_data.csr_op)
      CsrOpSwap:  csr_wdata = issue_req_i.fu_data.operand_a;
      CsrOpWrite: begin
        csr_read_en = 1'b0;
        csr_wdata = issue_req_i.fu_data.operand_a;
      end
      CsrOpSet:   csr_wdata = csr_rdata | issue_req_i.fu_data.operand_a;
      CsrOpClear: csr_wdata = csr_rdata & ~issue_req_i.fu_data.operand_a;
      CsrOpRead:  csr_write_en = 1'b0;
      default: begin
        csr_read_en = 1'b0;
        csr_write_en = 1'b0;
      end
    endcase
  end

  // ---------------------------
  // Read CSR
  // ---------------------------
  // This part reads the desired CSR and handles read side effects.
  always_comb begin : csr_read
    illegal_csr_read = 1'b0;
    csr_rdata = '0;

    // Cluster barrier control
    barrier_stall_d = barrier_stall_q;
    // Reset the barrier when signaled from cluster
    if (barrier_i) begin
      barrier_stall_d = 1'b0;
    end
    // Never signal that we have encountered a barrier stall except in the cycle where we enter
    // the barrier stall. Entering the stall happens when reading the barrier CSR.
    barrier_o = 1'b0;

    if (csr_read_en) begin
      unique case (csr_addr.address)
        /// Machine level CSRs
        riscv_instr::CSR_MISA: begin
          csr_rdata =
                    // A - Atomic instructions enabled
                      (0 << 0) // TODO: Snitch supports this
                    // C - Compressed instructions enabled
                    | (0 << 2)
                    // D - Double precision floating point enabled
                    | (RVD << 3)
                    // E - RV32E base ISA enabled
                    | (0 << 4)
                    // F - Single precision floating point enabled
                    | (RVF << 5)
                    // I - RV32I/64I/128I base ISA enabled
                    | (1 << 8)
                    // M - Integer multiplication and division enabled
                    | (0 << 12) // TODO: Snitch supports this
                    // N - User-level interrupts supported
                    | (0 << 13)
                    // S - Supervisor mode implemented
                    | (0 << 18)
                    // U - User mode implemented
                    | (0 << 20)
                    // X - Non-standard extensions present
                    | (Xdma << 23) // TODO: add new FREP and DMA
                    // XLEN - RV32
                    | (1 << 30);
        end
        riscv_instr::CSR_MVENDORID: begin
          csr_rdata = '0; // no vendor ID
        end
        riscv_instr::CSR_MARCHID: begin
          csr_rdata = '0; // no architecture ID
        end
        riscv_instr::CSR_MIMPID: begin
          csr_rdata = '0; // no implementation ID
        end
        riscv_instr::CSR_MHARTID: begin
          csr_rdata = hart_id_i; // feed through from cluster
        end
        riscv_instr::CSR_MSTATUS: begin
          csr_rdata = mstatus_q;
        end
        riscv_instr::CSR_MSTATUSH: begin
          csr_rdata = mstatush_q;
        end
        riscv_instr::CSR_MTVEC: begin
          // We don't support vectorized trap bases
          csr_rdata = {mtvec_q, 2'b00};
        end
        // We don't support delegation. Snitch does not crash, so we also don't.
        // In the standard, this CSR would not exist without S mode.
        riscv_instr::CSR_MEDELEG: ;
        riscv_instr::CSR_MIP: begin
          // read the external asynchronous interrupt pending bits for machine level
          automatic mip_t mip_r;
          mip_r = '{
            lcofip: '0,
            meip: irq_i.meip, // feed through combinatorially to allow WFI
            mtip: irq_i.mtip, // feed through combinatorially to allow WFI
            msip: irq_i.msip, // feed through combinatorially to allow WFI
            mcip: irq_i.mcip, // feed through combinatorially to allow WFI
            seip: mip_q.seip,
            stip: mip_q.stip,
            ssip: mip_q.ssip,
            scip: mip_q.scip,
            default: '0
          };
          csr_rdata = mip_r;
        end
        riscv_instr::CSR_MIE: begin
          automatic mie_t mie_r;
          mie_r = '{
            lcofie: '0,
            meie: mie_q.meie,
            mtie: mie_q.mtie,
            msie: mie_q.msie,
            mcie: mie_q.mcie,
            seie: mie_q.seie,
            stie: mie_q.stie,
            ssie: mie_q.ssie,
            scie: mie_q.scie,
            default: '0
          };
          csr_rdata = mie_r;
        end
        riscv_instr::CSR_MCOUNTINHIBIT: ; // tied-off - no counter control implemented
        riscv_instr::CSR_MSCRATCH: begin
          csr_rdata = mscratch_q;
        end
        riscv_instr::CSR_MEPC: begin
          csr_rdata = mepc_q;
        end
        riscv_instr::CSR_MCAUSE: begin
          csr_rdata = mcause_q;
        end
        riscv_instr::CSR_MTVAL: ; // tied-off - no exception sets this CSR
        /// Supervisior level CSRs (incomplete, based on Snitch)
        riscv_instr::CSR_SSTATUS: begin
          // subset of mstatus. Only return spp flag. This 1:1 the Snitch implementation.
          automatic mstatus_rv32_t sstatus;
          sstatus = '0;
          sstatus.spp = mstatus_q.spp;
          csr_rdata = sstatus;
        end
        riscv_instr::CSR_SSCRATCH: begin
          csr_rdata = sscratch_q;
        end
        riscv_instr::CSR_SEPC: begin
          csr_rdata = sepc_q;
        end
        riscv_instr::CSR_SIP, riscv_instr::CSR_SIE: ; // tied-off - no delegation
        riscv_instr::CSR_SCAUSE: ; // tied-off - no delegation
        riscv_instr::CSR_STVAL: ; // tied-off - no delegation
        riscv_instr::CSR_STVEC: ; // tied-off - no delegation
        riscv_instr::CSR_SATP: begin
          // THIS DEVIATES FROM THE STANDARD! The ASID bits are neglected and thus the mode bits
          // are not at the specified bit locations. They are shifted down.
          // This is a deviation existing in the original Snitch implementation and we keep it to
          // ensure compatibility with the Snitch runtime.
          csr_rdata = {{XLEN-$bits(satp_t){1'b0}}, satp_q};
          // correct assignment would be:
          // csr_rdata = {satp_q.mode, {XLEN-$bits(satp_t){1'b0}}, satp_q.ppn};
        end
        /// Floating point CSRs for F/D ISA extension
        riscv_instr::CSR_FFLAGS: begin
          csr_rdata = {{XLEN - $bits(fpnew_pkg::status_t){1'b0}}, fcsr_q.fflags};
        end
        riscv_instr::CSR_FRM: begin
          csr_rdata = {{XLEN - $bits(fpnew_pkg::roundmode_e){1'b0}}, fcsr_q.frm};
        end
        riscv_instr::CSR_FMODE: begin // Custom CSR
          csr_rdata = {{XLEN - $bits(fpnew_pkg::fmt_mode_t){1'b0}}, fcsr_q.fmode};
        end
        riscv_instr::CSR_FCSR: begin
          // This is not perfectly matching the RISC-V standard. The fmode bits are additional.
          csr_rdata = {{XLEN - $bits(fcsr_t){1'b0}}, fcsr_q};
        end
        /// Custom cluster barrier
        riscv_instr::CSR_BARRIER: begin
          // This is a read only CSR. The side effect is the barrier stall signal.
          // May only be set once and when the CSR instruction is valid.
          // TODO: Rework the CSR module such that the actual reads / writes are separated from
          //       the illegal CSR check.
          if (issue_req_valid_i) begin
            barrier_stall_d = 1'b1;
            barrier_o = 1'b1; // Signal that we entered the barrier stall.
          end
        end
        // Custom FREP config register
        // TODO(colluca): move to riscv-opcodes
        schnizo_pkg::CsrFrepState: begin
          csr_rdata = {{XLEN - $bits(frep_state_t){1'b0}}, frep_state};
        end
        schnizo_pkg::CsrFrepConfig: begin
          csr_rdata = {{XLEN - $bits(frep_config_t){1'b0}}, frep_config_q};
        end
        riscv_instr::CSR_MCYCLE: begin
          csr_rdata = cycle_q[31:0];
        end
        riscv_instr::CSR_MCYCLEH: begin
          csr_rdata = cycle_q[63:32];
        end
        riscv_instr::CSR_MINSTRET: begin
          csr_rdata = instret_q[31:0];
        end
        riscv_instr::CSR_MINSTRETH: begin
          csr_rdata = instret_q[63:32];
        end
        default: illegal_csr_read = 1'b1;
      endcase
    end
  end

  // ---------------------------
  // Write & update CSR
  // ---------------------------
  // This part updates the CSR with the new value and handles write side effects.
  always_comb begin : csr_write_update
    // TODO: update here all counters?

    // All default values
    mstatus_d = mstatus_q;
    mstatush_d = mstatush_q;
    fcsr_d = fcsr_q;
    mtvec_d = mtvec_q;
    mip_d = mip_q;
    mie_d = mie_q;
    mscratch_d = mscratch_q;
    mepc_d = mepc_q;
    mcause_d = mcause_q;
    sscratch_d = sscratch_q;
    sepc_d = sepc_q;
    satp_d = satp_q;
    priv_lvl_d = priv_lvl_q;
    frep_config_d = frep_config_q;

    // If we have a write operation, update the CSR only if the request is valid.
    // Any invalid request (illegal CSR address or insufficient privileges) will cause an
    // exception which in turn will de-assert the issue_req_valid_i signal.
    if (csr_write_en_int) begin
      unique case (csr_addr.address)
        riscv_instr::CSR_MSTATUS: begin
          automatic mstatus_rv32_t mstatus_w;
          mstatus_w = mstatus_rv32_t'(csr_wdata);
          // Only update fields required for the designed extension support.
          mstatus_d.mpp = mstatus_w.mpp;
          mstatus_d.spp = mstatus_w.spp;
          mstatus_d.mpie = mstatus_w.mpie;
          mstatus_d.mie = mstatus_w.mie;
          // no supervisor and user mode. hardwiring following fields to zero:
          // - spp, upp, mprv, mxr, sum, sbe, ube, tvm, tw, tsr
          // Exceptions, which we still update because snitch implements it:
          //  - spp (used for virtual memory support. Schnizo does not support VM)
          // Other hard wired signals:
          // - mbe: always use little endian
          // - fs is hardwired to Dirty if FPU is present, else zero.
          // - We don't support V extension -> vs is hardwired to zero.
          // - xs is hardwired to zero. TODO: change if we add DMA & FREP
          // - sd is always set as we always set the FPU to dirty.
        end
        riscv_instr::CSR_MSTATUSH: ; // all bits are hardwired to zero or WPRI
        riscv_instr::CSR_MTVEC: begin
          mtvec_d = csr_wdata[31:2];
        end
        // We don't support delegation. Snitch does not crash, so we also don't.
        // In the standard, this CSR would only exist if S mode is implemented.
        riscv_instr::CSR_MEDELEG: ;
        riscv_instr::CSR_MIP: begin
          automatic mip_t mip_w = mip_t'(csr_wdata);
          // update only settable interrupts. M interrupts must remain combinatorial for WFI.
          mip_d.seip = mip_w.seip;
          mip_d.stip = mip_w.stip;
          mip_d.ssip = mip_w.ssip;
          mip_d.scip = mip_w.scip;
        end
        riscv_instr::CSR_MIE: begin
          automatic mie_t mie_w = mie_t'(csr_wdata);
          // update only settable interrupts
          mie_d.meie = mie_w.meie;
          mie_d.mtie = mie_w.mtie;
          mie_d.msie = mie_w.msie;
          mie_d.mcie = mie_w.mcie;
          mie_d.seie = mie_w.seie;
          mie_d.stie = mie_w.stie;
          mie_d.ssie = mie_w.ssie;
          mie_d.scie = mie_w.scie;
        end
        riscv_instr::CSR_MCOUNTINHIBIT: ; // tied-off - no counter control implemented
        riscv_instr::CSR_MSCRATCH: begin
          mscratch_d = csr_wdata;
        end
        riscv_instr::CSR_MEPC: begin
          // RISC-V standard: mepc[0] is always zero. If only IALIGN=32, mepc[1:0] are zero.
          // To be compatbile to Snitch: route all new bits to the CSR.
          mepc_d = csr_wdata;
        end
        riscv_instr::CSR_MCAUSE: begin
          mcause_d = mcause_t'(csr_wdata);
          // Clear reserved & unused custom use exception code bits (values >=32).
          // This allows to optimize away the unused FFs but to keep the 32bit struct.
          mcause_d[XLEN-2:5] = '0;
        end
        riscv_instr::CSR_MTVAL: ; // tied-off - no exception sets this CSR
        /// Supervisior level CSRs (incomplete, based on Snitch)
        riscv_instr::CSR_SSTATUS: begin
          // subset of mstatus
          // Do simply keep the value? This is 1:1 the Snitch implementation. Reason is unkown.
          mstatus_d.spp = mstatus_q.spp;
        end
        riscv_instr::CSR_SSCRATCH: begin
          sscratch_d = csr_wdata;
        end
        riscv_instr::CSR_SEPC: begin
          // RISC-V standard: sepc[0] is always zero. If only IALIGN=32, sepc[1:0] are zero.
          // To be compatbile to Snitch: route all new bits to the CSR.
          sepc_d = csr_wdata;
        end
        riscv_instr::CSR_SIP, riscv_instr::CSR_SIE: ; // tied-off - no delegation
        riscv_instr::CSR_SCAUSE: ; // tied-off - no delegation
        riscv_instr::CSR_STVAL: ; // tied-off - no delegation
        riscv_instr::CSR_STVEC: ; // tied-off - no delegation
        riscv_instr::CSR_SATP: begin
          automatic satp_t satp_w = satp_t'(csr_wdata);
          satp_w = '0; // always zero ASID bits. TODO: ensure that static FFs are optimized away.
          satp_d.ppn = satp_w.ppn;
          satp_d.mode = VMSupport ? satp_w.mode : '0;
        end
        /// Floating point CSRs for F/D ISA extension
        riscv_instr::CSR_FFLAGS: begin
          fcsr_d.fflags = fpnew_pkg::status_t'(csr_wdata[$bits(fpnew_pkg::status_t)-1:0]);
        end
        riscv_instr::CSR_FRM: begin
          fcsr_d.frm = fpnew_pkg::roundmode_e'(csr_wdata[$bits(fpnew_pkg::roundmode_e)-1:0]);
        end
        riscv_instr::CSR_FMODE: begin
          // This is a non standard field in the CSR_FCSR register.
          fcsr_d.fmode = fpnew_pkg::fmt_mode_t'(csr_wdata[$bits(fpnew_pkg::fmt_mode_t)-1:0]);
        end
        riscv_instr::CSR_FCSR: begin
          // This is not perfectly matching the RISC-V standard. The fmode bits are additional.
          fcsr_d = fcsr_t'(csr_wdata[$bits(fcsr_t)-1:0]);
        end
        /// Custom cluster barrier
        riscv_instr::CSR_BARRIER: begin
          // Do nothing because the barrier side effect is read only. See read side effect.
          // TODO: Maybe we should raise an illegal instruction exception? We did not because it is
          // unknown how the snitch runtime interacts with this CSR and in snitch this CSR never
          // causes an exception.
        end
        schnizo_pkg::CsrFrepConfig: begin
          automatic frep_config_t frep_config = frep_config_t'(csr_wdata);
          // Only update valid values
          if (frep_config.mem_constistency_mode inside
              {FrepMemNoConsistency, FrepMemSerialized}) begin
            frep_config_d.mem_constistency_mode = frep_config.mem_constistency_mode;
          end
        end
        default: ;
      endcase
    end

    // Update FP CSR with current state if its valid. This is on top of any write.
    fcsr_d.fflags = fpu_status_valid_i ? (fpu_status_i | fcsr_d.fflags) : fcsr_d.fflags;

    // Handle current exceptions, wfi and privilege transitions.
    // For this we need some informations from the frontend and decoder.

    // Wait for interrupt. Add "|| debug_q" if debug is supported.
    wfi_d = ((DebugSupport && irq_i.debug) || any_interrupt_pending) ? 1'b0 : wfi_q;
    if (enter_wfi_i) begin
      wfi_d = 1'b1;
    end

    // The exception handling gets prio from other writes (above).
    // The priority is same as in Snitch.
    if (illegal_instr_i || illegal_csr_instr_o) begin
      mcause_d.interrupt = 1'b0;
      mcause_d.exception_code = IllegalInstr;
    end

    if (ecall_i) begin
      mcause_d.interrupt = 1'b0;
      unique case (priv_lvl_q)
        PrivLvlM: mcause_d.exception_code = EnvCallMMode;
        PrivLvlS: mcause_d.exception_code = EnvCallSMode;
        PrivLvlU: mcause_d.exception_code = EnvCallUMode;
        default:  mcause_d.exception_code = EnvCallMMode;
      endcase
    end

    if (ebreak_i) begin
      mcause_d.interrupt = 1'b0;
      mcause_d.exception_code = Breakpoint;
    end

    // We don't support VM / page faults

    if (instr_addr_misaligned_i) begin
      mcause_d.interrupt = 1'b0;
      mcause_d.exception_code = InstrAddrMisaligned;
    end

    if (load_addr_misaligned_i) begin
      mcause_d.interrupt = 1'b0;
      mcause_d.exception_code = LoadAddrMisaligned;
    end

    if (store_addr_misaligned_i) begin
      mcause_d.interrupt = 1'b0;
      mcause_d.exception_code = StoreAddrMisaligned;
    end

    if (interrupt_o) begin
      // Prio: MEI, MSI, MTI, mcip, SEI, SSI, STI, LCOFI, scip
      // lower case interrupts are non standard.
      mcause_d.interrupt = 1'b1;
      if      (meip) mcause_d.exception_code = IrqMei;
      else if (mtip) mcause_d.exception_code = IrqMti;
      else if (msip) mcause_d.exception_code = IrqMsi;
      else if (mcip) mcause_d.exception_code = IrqMci;
      else if (seip) mcause_d.exception_code = IrqSei;
      else if (stip) mcause_d.exception_code = IrqSti;
      else if (ssip) mcause_d.exception_code = IrqSsi;
      else if (scip) mcause_d.exception_code = IrqSci;
    end

    // Go to exception handler if an exception is raised
    if (exception_i) begin
      mepc_d = pc_i;
      mcause_d.interrupt = interrupt_o;
      priv_lvl_d = PrivLvlM;

      // manipulate exception stack
      mstatus_d.mpp = priv_lvl_q;
      mstatus_d.mpie = mstatus_q.mie;
      mstatus_d.mie = 1'b0;
    end

    // Return from environments
    if (mret_i) begin
      priv_lvl_d = mstatus_q.mpp;
      mie_d.meie = mstatus_q.mpie;
      mstatus_d.mpie = 1'b1;
      mstatus_d.mpp = PrivLvlU; // set default back to U mode. Snitch specific (?)
    end

    if (sret_i) begin
      priv_lvl_d = priv_lvl_t'({1'b0, mstatus_q.spp});
      mstatus_d.spp = 1'b0;
    end
  end

  // ---------------------------
  // Interrupts
  // ---------------------------
  // Directly use input interrupt signals for machine interrupts
  assign meip = irq_i.meip & mie_q.meie;
  assign mtip = irq_i.mtip & mie_q.mtie;
  assign msip = irq_i.msip & mie_q.msie;
  assign mcip = irq_i.mcip & mie_q.mcie;

  assign seip = mip_q.seip & mie_q.seie;
  assign stip = mip_q.stip & mie_q.stie;
  assign ssip = mip_q.ssip & mie_q.ssie;
  assign scip = mip_q.scip & mie_q.scie;

  assign interrupts_enabled = ((priv_lvl_q == PrivLvlM) & mstatus_q.mie) ||
                              (priv_lvl_q != PrivLvlM);
  assign any_interrupt_pending = meip | mtip | msip | mcip | seip | stip | ssip | scip;
  assign interrupt_o = interrupts_enabled & any_interrupt_pending;

  // ---------------------------
  // Check write permission and privilege level
  // ---------------------------
  logic illegal_csr_priv;
  logic illegal_csr_write;
  assign illegal_csr_priv   = (csr_addr.csr_decoded.priv_lvl > priv_lvl_q);
  assign illegal_csr_write  = (csr_addr.csr_decoded.rw == 2'b11) & csr_write_en;

  assign illegal_csr_instr_o = illegal_csr_read | illegal_csr_priv | illegal_csr_write;

  // Only update the CSRs if the instruction is valid.
  assign csr_write_en_int = csr_write_en & ~illegal_csr_instr_o & issue_req_valid_i;

  // CSR FU is ready to execute instruction depending whether we have to write to the RF.
  // We have to write to the RF (read CSR) only if the csr instruction is valid. In this case,
  // feed through the RF ready signal. If it is only a write, we always accept the request.
  // If there is an exception, always block the dispatch request.
  // In all cases: only accept the request if it is valid.
  assign issue_req_ready_o = issue_req_valid_i &
                             (illegal_csr_instr_o ? 1'b0           :
                              csr_read_en         ? result_ready_i :
                                                    1'b1);

  // Signal the result to the register file if we have to write it and the instruction is valid.
  assign result_valid_o = issue_req_valid_i & (csr_read_en ? ~illegal_csr_instr_o : 1'b0);
  assign result_o = csr_rdata;

  // Output some registers directly to the frontend
  assign mtvec_o = {mtvec_q, 2'b00};
  assign mepc_o = mepc_q;
  assign sepc_o = sepc_q;
  assign wfi_o = wfi_q;
  // Send current priv level to the decoder
  assign priv_lvl_o = priv_lvl_q;
  assign barrier_stall_o = barrier_stall_q;

  // Send FREP memory consistency mode to dispatcher
  assign frep_mem_cons_mode_o = frep_config_q.mem_constistency_mode;
  // FPU update
  assign fpu_rnd_mode_o = fcsr_q.frm;
  assign fpu_fmt_mode_o = fcsr_q.fmode;

endmodule
