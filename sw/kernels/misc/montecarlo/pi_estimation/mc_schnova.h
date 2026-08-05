// Copyright 2026 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#ifdef FORCE_HW_LOOP
#define FREP "frep.i"
#else
#define FREP "frep.o"
#endif

#if PRNG == PRNG_LCG
#define N_PRNG_INSNS 24
#elif PRNG == PRNG_XOSHIRO128P
#define N_PRNG_INSNS 88
#endif

#define N_COMMON_INSNS (8 + 4)

#if APPLICATION == APPLICATION_PI
#define N_APP_INSNS 12
#elif APPLICATION == APPLICATION_POLY
#define N_APP_INSNS 24
#endif

#define N_INSNS_SV (N_PRNG_INSNS + N_APP_INSNS + N_COMMON_INSNS)

static inline uint32_t calculate_psum_schnova(PRNG_T *prngs,
                                              unsigned int n_samples) {
    // Accumulators for partial sums
    int temp0 = 0;
    int temp1 = 0;
    int temp2 = 0;
    int temp3 = 0;

#if PRNG == PRNG_LCG
    // LCG state
    uint32_t lcg_state_x0 = prngs[0].state;
    uint32_t lcg_state_x1 = prngs[1].state;
    uint32_t lcg_state_x2 = prngs[2].state;
    uint32_t lcg_state_x3 = prngs[3].state;
    uint32_t lcg_state_y0 = prngs[4].state;
    uint32_t lcg_state_y1 = prngs[5].state;
    uint32_t lcg_state_y2 = prngs[6].state;
    uint32_t lcg_state_y3 = prngs[7].state;
    uint32_t lcg_Ap = prngs->A;
    uint32_t lcg_Cp = prngs->C;
#elif PRNG == PRNG_XOSHIRO128P
    // xoshiro128p state
    uint32_t xoshiro128p_state_0 = prngs->s[0];
    uint32_t xoshiro128p_state_1 = prngs->s[1];
    uint32_t xoshiro128p_state_2 = prngs->s[2];
    uint32_t xoshiro128p_state_3 = prngs->s[3];
    uint32_t xoshiro128p_tmp;
#endif

    if (snrt_cluster_core_idx() < N_CORES) {
        snrt_mcycle();

        // Unrolled by 4
        uint32_t n_iter = n_samples >> 2;

        // clang-format off
        asm volatile(
            // We pull an additional iteration outside the loop
            // so that we can better overlap instructions within
            // the loop.

            // Generate next 4 pseudo-random integer (X,Y) pairs
            // and convert to doubles
#if PRNG == PRNG_LCG
            EVAL_LCG_UNROLL4
            FCVT_UNROLL_8(%[int_x0], %[int_y0], %[int_x1], %[int_y1],
                          %[int_x2], %[int_y2], %[int_x3], %[int_y3],
                          ft0, fa0, ft1, fa1, ft2, fa2, ft3, fa3)
#elif PRNG == PRNG_XOSHIRO128P
            EVAL_XOSHIRO128P_UNROLL4
            FCVT_UNROLL_8(t0, t1, t2, t3, a0, a1, a2, a3,
                          ft0, fa0, ft1, fa1, ft2, fa2, ft3, fa3)
#endif
// Naive unrolling does not work well for schnova, for example if you pack all floating point instructions 
// after each other then schnova can only dispatch one per cycle if it has 1 FPU. Because it has to
// dispatch these instructions in order. For performance 
// it is better to group different types of instructions (ALU, LSU and FPU) together in order to 
// maximize the amount of instructions that can be dispatched per cycle
// // Note: This optimized for a config with 3 ALUs, 3 LSUs, 1 FPU
// In essence the same instructions as for the schnizo kernel but reshuffled
// in some cases nop were added to maximize performance with via alignment
// schnova is most performant if it always can fetch the maximum amount of instructions
// that is only possible if the instructions inside the frep body are aligned

// Note on performance xoshiro vs lcg
// Xoshiro will achieve a higher IPC since the amount of Arithmetic operations is better balanced
// in compairson to the amount of floating point operations

#if (APPLICATION == APPLICATION_PI) && (PRNG == PRNG_LCG)
            "nop \n"
            "nop \n"
            FREP " %[n_frep], %[n_insns], 0, 0 \n"
#ifdef BALANCE_INSTRUCTION_MIX
            "fmul.d  ft0, ft0, %[div]          \n" 
            "mul %[int_x0], %[int_x0], %[Ap]   \n" 
            "fmul.d  ft1, ft1, %[div]          \n" 
            "mul %[int_x1], %[int_x1], %[Ap]   \n" 
            "fmul.d  ft2, ft2, %[div]          \n" 
            "mul %[int_x2], %[int_x2], %[Ap]   \n" 
            "fmul.d  ft3, ft3, %[div]          \n" 
            "mul %[int_x3], %[int_x3], %[Ap]   \n" 
            "fmul.d  fa0, fa0, %[div]          \n" 
            "add %[int_x0], %[int_x0], %[Cp]   \n" 
            "fmul.d  fa1, fa1, %[div]          \n" 
            "mul %[int_y0], %[int_y0], %[Ap]   \n" 
            "fmul.d  fa2, fa2, %[div]          \n" 
            "add %[int_x1], %[int_x1], %[Cp]   \n" 
            "fmul.d  fa3, fa3, %[div]          \n" 
            "mul %[int_y1], %[int_y1], %[Ap]   \n" 
            "fmul.d  ft0, ft0, ft0             \n" 
            "add %[int_x2], %[int_x2], %[Cp]   \n" 
            "fmul.d  ft1, ft1, ft1             \n" 
            "mul %[int_y2], %[int_y2], %[Ap]   \n" 
            "fmul.d  ft2, ft2, ft2             \n" 
            "add %[int_x3], %[int_x3], %[Cp]   \n" 
            "fmul.d  ft3, ft3, ft3             \n" 
            "mul %[int_y3], %[int_y3], %[Ap]   \n" 
            "fmadd.d ft0, fa0, fa0, ft0        \n" 
            "add %[int_y0], %[int_y0], %[Cp]   \n" 
            "fmadd.d ft1, fa1, fa1, ft1        \n" 
            "add %[int_y1], %[int_y1], %[Cp]   \n" 
            "fmadd.d ft2, fa2, fa2, ft2        \n" 
            "add %[int_y2], %[int_y2], %[Cp]   \n" 
            "fmadd.d ft3, fa3, fa3, ft3        \n" 
            "add %[int_y3], %[int_y3], %[Cp]   \n" 
            "flt.d   a4, ft0, %[one]           \n" 
            "fcvt.d.wu ft0, %[int_x0]          \n" 
            "flt.d   a5, ft1, %[one]           \n" 
            "fcvt.d.wu fa0, %[int_y0]          \n" 
            "flt.d   a6, ft2, %[one]           \n" 
            "fcvt.d.wu ft1, %[int_x1]          \n" 
            "flt.d   a7, ft3, %[one]           \n" 
            "fcvt.d.wu fa1, %[int_y1]          \n" 
            "add %[temp0], %[temp0], a4        \n" 
            "fcvt.d.wu ft2, %[int_x2]          \n" 
            "add %[temp1], %[temp1], a5        \n" 
            "fcvt.d.wu fa2, %[int_y2]          \n" 
            "add %[temp2], %[temp2], a6        \n" 
            "fcvt.d.wu ft3, %[int_x3]          \n" 
            "add %[temp3], %[temp3], a7        \n" 
            "fcvt.d.wu fa3, %[int_y3]          \n"
#else
            // Normalize PRNs to [0, 1] range
            "fmul.d ft0, ft0, %[div] \n"
            "fmul.d ft1, ft1, %[div] \n"
            "fmul.d ft2, ft2, %[div] \n"
            "fmul.d ft3, ft3, %[div] \n"
            "fmul.d fa0, fa0, %[div] \n"
            "fmul.d fa1, fa1, %[div] \n"
            "fmul.d fa2, fa2, %[div] \n"
            "fmul.d fa3, fa3, %[div] \n"
            // x^2 + y^2
            EVAL_X2_PLUS_Y2_UNROLL4(ft0, ft1, ft2, ft3, fa0, fa1, fa2, fa3,
                                    ft0, ft1, ft2, ft3)
            // (x^2 + y^2) < 1
            FLT_UNROLL_4(ft0, ft1, ft2, ft3, %[one], %[one], %[one], %[one],
                         a4, a5, a6, a7)
            EVAL_LCG_UNROLL4
            FCVT_UNROLL_8(%[int_x0], %[int_y0], %[int_x1], %[int_y1],
                          %[int_x2], %[int_y2], %[int_x3], %[int_y3],
                          ft0, fa0, ft1, fa1, ft2, fa2, ft3, fa3)
                        // Update the partial sums
            "add %[temp0], %[temp0], a4 \n"
            "add %[temp1], %[temp1], a5 \n"
            "add %[temp2], %[temp2], a6 \n"
            "add %[temp3], %[temp3], a7 \n"
#endif
#elif (APPLICATION == APPLICATION_PI) && (PRNG == PRNG_XOSHIRO128P)
            // Note: Here the aligment has even more importance
            // if it is not aligned this code will use 8 cachelines in the I$
            // (rather than 7) however the L0 cache fits exactly 8 cachelines
            // the prefetcher will then lead to a trashing of the cache such 
            // that even after the first loop iterations there are the same amount of
            // misses as in the first iteration.
            "nop                               \n"
            "nop                               \n"
            FREP " %[n_frep], %[n_insns], 0, 0 \n"
#ifdef BALANCE_INSTRUCTION_MIX
            "fmul.d ft0, ft0, %[div]           \n"
            "add t0, %[s_0], %[s_3]            \n"
            "sll t4, %[s_1], 9                 \n"
            "xor %[s_2], %[s_2], %[s_0]        \n"
            "fmul.d ft1, ft1, %[div]           \n"
            "xor %[s_3], %[s_3], %[s_1]        \n"
            "xor %[s_1],%[s_1], %[s_2]         \n"
            "xor %[s_0],%[s_0], %[s_3]         \n"
            "fmul.d ft2, ft2, %[div]           \n"
            "xor %[s_2], %[s_2], t4            \n"
            "sll t4, %[s_3], 11                \n"
            "srl %[s_3], %[s_3], 21            \n"
            "fmul.d ft3, ft3, %[div]           \n"
            "or %[s_3], %[s_3], t4             \n"
            "add t1, %[s_0], %[s_3]            \n"
            "sll t4, %[s_1], 9                 \n"
            "fmul.d fa0, fa0, %[div]           \n"
            "xor %[s_2], %[s_2], %[s_0]        \n"
            "xor %[s_3], %[s_3], %[s_1]        \n"
            "xor %[s_1],%[s_1], %[s_2]         \n"
            "fmul.d fa1, fa1, %[div]           \n"
            "xor %[s_0],%[s_0], %[s_3]         \n"
            "xor %[s_2], %[s_2], t4            \n"
            "sll t4, %[s_3], 11                \n"
            "fmul.d fa2, fa2, %[div]           \n"
            "srl %[s_3], %[s_3], 21            \n"
            "or %[s_3], %[s_3], t4             \n"
            "add t2, %[s_0], %[s_3]            \n"
            "fmul.d fa3, fa3, %[div]           \n"
            "sll t4, %[s_1], 9                 \n"
            "xor %[s_2], %[s_2], %[s_0]        \n"
            "xor %[s_3], %[s_3], %[s_1]        \n"                                                           
            "fmul.d ft0, ft0, ft0              \n"
            "xor %[s_1],%[s_1], %[s_2]         \n"
            "xor %[s_0],%[s_0], %[s_3]         \n"
            "xor %[s_2], %[s_2], t4            \n"
            "fmul.d ft1, ft1, ft1              \n"
            "sll t4, %[s_3], 11                \n"
            "srl %[s_3], %[s_3], 21            \n"
            "or %[s_3], %[s_3], t4             \n"
            "fmul.d ft2, ft2, ft2              \n"
            "add t3, %[s_0], %[s_3]            \n"
            "sll t4, %[s_1], 9                 \n"
            "xor %[s_2], %[s_2], %[s_0]        \n"
            "fmul.d ft3, ft3, ft3              \n"
            "xor %[s_3], %[s_3], %[s_1]        \n"
            "xor %[s_1],%[s_1], %[s_2]         \n"
            "xor %[s_0],%[s_0], %[s_3]         \n"                                                    
            "fmadd.d ft0, fa0, fa0, ft0        \n"
            "xor %[s_2], %[s_2], t4            \n"
            "sll t4, %[s_3], 11                \n"
            "srl %[s_3], %[s_3], 21            \n"
            "fmadd.d ft1, fa1, fa1, ft1        \n"
            "or %[s_3], %[s_3], t4             \n"
            "add a0, %[s_0], %[s_3]            \n"
            "sll t4, %[s_1], 9                 \n"
            "fmadd.d ft2, fa2, fa2, ft2        \n"
            "xor %[s_2], %[s_2], %[s_0]        \n"
            "xor %[s_3], %[s_3], %[s_1]        \n"
            "xor %[s_1],%[s_1], %[s_2]         \n"
            "fmadd.d ft3, fa3, fa3, ft3        \n"
            "flt.d a4, ft0, %[one]             \n"
            "xor %[s_0],%[s_0], %[s_3]         \n"
            "xor %[s_2], %[s_2], t4            \n"
            "sll t4, %[s_3], 11                \n"
            "flt.d a5, ft1, %[one]             \n"
            "srl %[s_3], %[s_3], 21            \n"
            "or %[s_3], %[s_3], t4             \n"
            "add a1, %[s_0], %[s_3]            \n"
            "flt.d a6, ft2, %[one]             \n"
            "sll t4, %[s_1], 9                 \n"
            "xor %[s_2], %[s_2], %[s_0]        \n"
            "xor %[s_3], %[s_3], %[s_1]        \n"
            "flt.d a7, ft3, %[one]             \n"
            "xor %[s_1],%[s_1], %[s_2]         \n"
            "xor %[s_0],%[s_0], %[s_3]         \n"
            "xor %[s_2], %[s_2], t4            \n"
            "fcvt.d.wu ft0, t0                 \n"
            "sll t4, %[s_3], 11                \n"
            "srl %[s_3], %[s_3], 21            \n"
            "or %[s_3], %[s_3], t4             \n"
            "fcvt.d.wu ft1, t1                 \n"
            "add a2, %[s_0], %[s_3]            \n"
            "sll t4, %[s_1], 9                 \n"
            "xor %[s_2], %[s_2], %[s_0]        \n"
            "fcvt.d.wu ft2, t2                 \n"
            "xor %[s_3], %[s_3], %[s_1]        \n"
            "xor %[s_1],%[s_1], %[s_2]         \n"
            "xor %[s_0],%[s_0], %[s_3]         \n"
            "fcvt.d.wu ft3, t3                 \n"
            "xor %[s_2], %[s_2], t4            \n"
            "sll t4, %[s_3], 11                \n"
            "srl %[s_3], %[s_3], 21            \n"
            "fcvt.d.wu fa0, a0                 \n"
            "or %[s_3], %[s_3], t4             \n"
            "add a3, %[s_0], %[s_3]            \n"
            "sll t4, %[s_1], 9                 \n"
            "fcvt.d.wu fa1, a1                 \n"
            "xor %[s_2], %[s_2], %[s_0]        \n"
            "xor %[s_3], %[s_3], %[s_1]        \n"
            "xor %[s_1],%[s_1], %[s_2]         \n"
            "fcvt.d.wu fa2, a2                 \n"
            "xor %[s_0],%[s_0], %[s_3]         \n"
            "xor %[s_2], %[s_2], t4            \n"
            "sll t4, %[s_3], 11                \n"
            "fcvt.d.wu fa3, a3                 \n"
            "srl %[s_3], %[s_3], 21            \n"
            "or %[s_3], %[s_3], t4             \n"
            // Update the partial sums
            "add %[temp0], %[temp0], a4        \n"
            "add %[temp1], %[temp1], a5        \n"
            "add %[temp2], %[temp2], a6        \n"
            "add %[temp3], %[temp3], a7        \n"
#else
            // Normalize PRNs to [0, 1] range
            "fmul.d ft0, ft0, %[div] \n"
            "fmul.d ft1, ft1, %[div] \n"
            "fmul.d ft2, ft2, %[div] \n"
            "fmul.d ft3, ft3, %[div] \n"
            "fmul.d fa0, fa0, %[div] \n"
            "fmul.d fa1, fa1, %[div] \n"
            "fmul.d fa2, fa2, %[div] \n"
            "fmul.d fa3, fa3, %[div] \n"
            // x^2 + y^2
            EVAL_X2_PLUS_Y2_UNROLL4(ft0, ft1, ft2, ft3, fa0, fa1, fa2, fa3,
                                    ft0, ft1, ft2, ft3)
            // (x^2 + y^2) < 1
            FLT_UNROLL_4(ft0, ft1, ft2, ft3, %[one], %[one], %[one], %[one],
                         a4, a5, a6, a7)
            EVAL_XOSHIRO128P_UNROLL4
            FCVT_UNROLL_8(t0, t1, t2, t3, a0, a1, a2, a3,
                          ft0, ft1, ft2, ft3, fa0, fa1, fa2, fa3)
            // Update the partial sums
            "add %[temp0], %[temp0], a4 \n"
            "add %[temp1], %[temp1], a5 \n"
            "add %[temp2], %[temp2], a6 \n"
            "add %[temp3], %[temp3], a7 \n"
#endif
#elif (APPLICATION == APPLICATION_POLY) && (PRNG == PRNG_LCG)
            "nop                               \n"
            "nop                               \n"
            FREP " %[n_frep], %[n_insns], 0, 0 \n"
#ifdef BALANCE_INSTRUCTION_MIX
            "fmul.d  ft0, ft0, %[div]          \n" 
            "mul %[int_x0], %[int_x0], %[Ap]   \n"
            "fmul.d  ft1, ft1, %[div]          \n" 
            "mul %[int_x1], %[int_x1], %[Ap]   \n"
            "fmul.d  ft2, ft2, %[div]          \n" 
            "mul %[int_x2], %[int_x2], %[Ap]   \n"
            "fmul.d  ft3, ft3, %[div]          \n" 
            "mul %[int_x3], %[int_x3], %[Ap]   \n"
            "fmul.d  fa0, fa0, %[div]          \n" 
            "add %[int_x0], %[int_x0], %[Cp]   \n"
            "fmul.d  fa1, fa1, %[div]          \n" 
            "add %[int_x1], %[int_x1], %[Cp]   \n"
            "fmul.d  fa2, fa2, %[div]          \n" 
            "add %[int_x2], %[int_x2], %[Cp]   \n"
            "fmul.d  fa3, fa3, %[div]          \n" 
            "add %[int_x3], %[int_x3], %[Cp]   \n"
            "fmul.d  fa0, fa0, %[three]        \n" 
            "mul %[int_y0], %[int_y0], %[Ap]   \n"
            "fmul.d  fa1, fa1, %[three]        \n" 
            "mul %[int_y1], %[int_y1], %[Ap]   \n"
            "fmul.d  fa2, fa2, %[three]        \n" 
            "mul %[int_y2], %[int_y2], %[Ap]   \n"
            "fmul.d  fa3, fa3, %[three]        \n" 
            "mul %[int_y3], %[int_y3], %[Ap]   \n"
            "fmul.d  ft4, ft0, ft0             \n" 
            "add %[int_y0], %[int_y0], %[Cp]   \n"
            "fmul.d  ft5, ft1, ft1             \n" 
            "add %[int_y1], %[int_y1], %[Cp]   \n"
            "fmul.d  ft6, ft2, ft2             \n" 
            "add %[int_y2], %[int_y2], %[Cp]   \n"
            "fmul.d  ft7, ft3, ft3             \n" 
            "add %[int_y3], %[int_y3], %[Cp]   \n"
            "fmadd.d ft4, ft4, ft0, ft4        \n" 
            "fmadd.d ft5, ft5, ft1, ft5        \n"
            "fmadd.d ft6, ft6, ft2, ft6        \n"
            "fmadd.d ft7, ft7, ft3, ft7        \n"
            "fsub.d  ft0, ft4, ft0             \n" 
            "fsub.d  ft1, ft5, ft1             \n" 
            "fsub.d  ft2, ft6, ft2             \n" 
            "fsub.d  ft3, ft7, ft3             \n" 
            "fadd.d  ft0, ft0, %[two]          \n" 
            "fadd.d  ft1, ft1, %[two]          \n" 
            "fadd.d  ft2, ft2, %[two]          \n" 
            "fadd.d  ft3, ft3, %[two]          \n"
            "flt.d   a4, fa0, ft0              \n" 
            "add %[temp0], %[temp0], a4        \n"
            "flt.d   a5, fa1, ft1              \n" 
            "add %[temp1], %[temp1], a5        \n"
            "flt.d   a6, fa2, ft2              \n" 
            "add %[temp2], %[temp2], a6        \n"
            "flt.d   a7, fa3, ft3              \n" 
            "add %[temp3], %[temp3], a7        \n"
            "fcvt.d.wu ft0, %[int_x0]          \n"
            "fcvt.d.wu fa0, %[int_y0]          \n"
            "fcvt.d.wu ft1, %[int_x1]          \n"
            "fcvt.d.wu fa1, %[int_y1]          \n"
            "fcvt.d.wu ft2, %[int_x2]          \n"
            "fcvt.d.wu fa2, %[int_y2]          \n"
            "fcvt.d.wu ft3, %[int_x3]          \n"
            "fcvt.d.wu fa3, %[int_y3]          \n"
#else
            // Normalize PRNs to [0, 1] range
            "fmul.d ft0, ft0, %[div] \n"
            "fmul.d ft1, ft1, %[div] \n"
            "fmul.d ft2, ft2, %[div] \n"
            "fmul.d ft3, ft3, %[div] \n"
            "fmul.d fa0, fa0, %[div] \n"
            "fmul.d fa1, fa1, %[div] \n"
            "fmul.d fa2, fa2, %[div] \n"
            "fmul.d fa3, fa3, %[div] \n"
            // y * 3
            // x^3 + x^2 - x + 2
            EVAL_POLY_UNROLL4(ft0, ft1, ft2, ft3, fa0, fa1, fa2, fa3, ft4, ft5,
                              ft6, ft7, ft0, ft1, ft2, ft3)
            // y * 3 < x^3 + x^2 - x + 2
            FLT_UNROLL_4(fa0, fa1, fa2, fa3, ft0, ft1, ft2, ft3, a4, a5, a6,
                         a7)
            EVAL_LCG_UNROLL4
            FCVT_UNROLL_8(%[int_x0], %[int_y0], %[int_x1], %[int_y1],
                          %[int_x2], %[int_y2], %[int_x3], %[int_y3],
                          ft0, fa0, ft1, fa1, ft2, fa2, ft3, fa3)
            // Update the partial sums
            "add %[temp0], %[temp0], a4 \n"
            "add %[temp1], %[temp1], a5 \n"
            "add %[temp2], %[temp2], a6 \n"
            "add %[temp3], %[temp3], a7 \n"
#endif
#elif (APPLICATION == APPLICATION_POLY) && (PRNG == PRNG_XOSHIRO128P)
            // Align the frep body to make sure we only touch 8 cache lines
            // otherwise we would have a conflict miss for every instruction
            // Note even if aligned the prefetcher will trash the cache
            // leading to misses even for iterations other than the first
            // To avoid this, for maximum performance the amount of cachelines
            // in the L0 cache should be increased to 16 (default is 8)
            "nop                               \n"
            "nop                               \n"
            "nop                               \n"
            "nop                               \n"
            "nop                               \n"
            "nop                               \n"
            "nop                               \n"
            FREP " %[n_frep], %[n_insns], 0, 0 \n"
#ifdef BALANCE_INSTRUCTION_MIX
            "fmul.d ft0, ft0, %[div]           \n"
            "add t0, %[s_0], %[s_3]            \n"
            "sll t4, %[s_1], 9                 \n"
            "xor %[s_2], %[s_2], %[s_0]        \n"
            "fmul.d ft1, ft1, %[div]           \n"
            "xor %[s_3], %[s_3], %[s_1]        \n"
            "xor %[s_1],%[s_1], %[s_2]         \n"
            "xor %[s_0],%[s_0], %[s_3]         \n"
            "fmul.d ft2, ft2, %[div]           \n"
            "xor %[s_2], %[s_2], t4            \n"
            "sll t4, %[s_3], 11                \n"
            "srl %[s_3], %[s_3], 21            \n"
            "fmul.d ft3, ft3, %[div]           \n"
            "or %[s_3], %[s_3], t4             \n"
            "add t1, %[s_0], %[s_3]            \n"
            "sll t4, %[s_1], 9                 \n"
            "fmul.d fa0, fa0, %[div]           \n"
            "xor %[s_2], %[s_2], %[s_0]        \n"
            "xor %[s_3], %[s_3], %[s_1]        \n"
            "xor %[s_1],%[s_1], %[s_2]         \n"
            "fmul.d fa1, fa1, %[div]           \n"
            "xor %[s_0],%[s_0], %[s_3]         \n"
            "xor %[s_2], %[s_2], t4            \n"
            "sll t4, %[s_3], 11                \n"
            "fmul.d fa2, fa2, %[div]           \n"
            "srl %[s_3], %[s_3], 21            \n"
            "or %[s_3], %[s_3], t4             \n"
            "add t2, %[s_0], %[s_3]            \n"
            "fmul.d fa3, fa3, %[div]           \n"
            "sll t4, %[s_1], 9                 \n"
            "xor %[s_2], %[s_2], %[s_0]        \n"
            "xor %[s_3], %[s_3], %[s_1]        \n"                                         
            "fmul.d fa0, fa0, %[three]         \n"
            "xor %[s_1],%[s_1], %[s_2]         \n"
            "xor %[s_0],%[s_0], %[s_3]         \n"
            "xor %[s_2], %[s_2], t4            \n"                                  
            "fmul.d fa1, fa1, %[three]         \n" 
            "sll t4, %[s_3], 11                \n"
            "srl %[s_3], %[s_3], 21            \n"
            "or %[s_3], %[s_3], t4             \n"                                 
            "fmul.d fa2, fa2, %[three]         \n" 
            "add t3, %[s_0], %[s_3]            \n"
            "sll t4, %[s_1], 9                 \n"
            "xor %[s_2], %[s_2], %[s_0]        \n"                                 
            "fmul.d fa3, fa3, %[three]         \n"
            "xor %[s_3], %[s_3], %[s_1]        \n"
            "xor %[s_1],%[s_1], %[s_2]         \n"
            "xor %[s_0],%[s_0], %[s_3]         \n"                                                                                           
            "fmul.d ft4, ft0, ft0              \n"  
            "xor %[s_2], %[s_2], t4            \n"
            "sll t4, %[s_3], 11                \n"
            "srl %[s_3], %[s_3], 21            \n"                               
            "fmul.d ft5, ft1, ft1              \n"    
            "or %[s_3], %[s_3], t4             \n"
            "add a0, %[s_0], %[s_3]            \n"
            "sll t4, %[s_1], 9                 \n"                             
            "fmul.d ft6, ft2, ft2              \n"  
            "xor %[s_2], %[s_2], %[s_0]        \n"
            "xor %[s_3], %[s_3], %[s_1]        \n"
            "fmul.d ft7, ft3, ft3              \n"                                                                  
            "fmadd.d ft4, ft4, ft0, ft4        \n" 
            "xor %[s_1],%[s_1], %[s_2]         \n"      
            "xor %[s_0],%[s_0], %[s_3]         \n"         
            "fmadd.d ft5, ft5, ft1, ft5        \n" 
            "xor %[s_2], %[s_2], t4            \n"
            "sll t4, %[s_3], 11                \n"                  
            "fmadd.d ft6, ft6, ft2, ft6        \n"  
            "srl %[s_3], %[s_3], 21            \n"
            "or %[s_3], %[s_3], t4             \n"                 
            "fmadd.d ft7, ft7, ft3, ft7        \n"   
            "add a1, %[s_0], %[s_3]            \n"
            "sll t4, %[s_1], 9                 \n"                                                  
            "fsub.d ft0, ft4, ft0              \n"   
            "xor %[s_2], %[s_2], %[s_0]        \n"
            "xor %[s_3], %[s_3], %[s_1]        \n"                           
            "fsub.d ft1, ft5, ft1              \n"  
            "xor %[s_1],%[s_1], %[s_2]         \n"
            "xor %[s_0],%[s_0], %[s_3]         \n"
            "fsub.d ft2, ft6, ft2              \n"
            "xor %[s_2], %[s_2], t4            \n" 
            "sll t4, %[s_3], 11                \n"                       
            "fsub.d ft3, ft7, ft3              \n"
            "srl %[s_3], %[s_3], 21            \n"
            "or %[s_3], %[s_3], t4             \n"                                                                       
            "fadd.d ft0, ft0, %[two]           \n"  
            "add a2, %[s_0], %[s_3]            \n"
            "sll t4, %[s_1], 9                 \n"                          
            "fadd.d ft1, ft1, %[two]           \n"
            "xor %[s_2], %[s_2], %[s_0]        \n"  
            "xor %[s_3], %[s_3], %[s_1]        \n"                           
            "fadd.d ft2, ft2, %[two]           \n"  
            "xor %[s_1],%[s_1], %[s_2]         \n"
            "xor %[s_0],%[s_0], %[s_3]         \n"                         
            "fadd.d ft3, ft3, %[two]           \n"
            "xor %[s_2], %[s_2], t4            \n"
            "sll t4, %[s_3], 11                \n"       
            "flt.d a4, fa0, ft0                \n"
            "srl %[s_3], %[s_3], 21            \n"    
            "or %[s_3], %[s_3], t4             \n" 
            "flt.d a5, fa1, ft1                \n"
            "add a3, %[s_0], %[s_3]            \n"
            "sll t4, %[s_1], 9                 \n"      
            "flt.d a6, fa2, ft2                \n"
            "xor %[s_2], %[s_2], %[s_0]        \n"
            "xor %[s_3], %[s_3], %[s_1]        \n"
            "flt.d a7, fa3, ft3                \n"
            "xor %[s_1],%[s_1], %[s_2]         \n"     
            "xor %[s_0],%[s_0], %[s_3]         \n"
            // Generate next 4 pseudo-random integer (X,Y) pairs
            // and convert to doubles
            "fcvt.d.wu ft0, t0                 \n"
            "xor %[s_2], %[s_2], t4            \n"
            "sll t4, %[s_3], 11                \n"   
            "fcvt.d.wu ft1, t1                 \n"
            "srl %[s_3], %[s_3], 21            \n"
            "or %[s_3], %[s_3], t4             \n"
            "fcvt.d.wu ft2, t2                 \n"
            "add %[temp0], %[temp0], a4        \n"
            "add %[temp1], %[temp1], a5        \n"
            "fcvt.d.wu ft3, t3                 \n"
            "add %[temp2], %[temp2], a6        \n"
            "add %[temp3], %[temp3], a7        \n"
            "fcvt.d.wu fa0, a0                 \n"
            "fcvt.d.wu fa1, a1                 \n"
            "fcvt.d.wu fa2, a2                 \n"
            "fcvt.d.wu fa3, a3                 \n"
#else
            // y * 3
            // x^3 + x^2 - x + 2
            EVAL_POLY_UNROLL4(ft0, ft1, ft2, ft3, fa0, fa1, fa2, fa3, ft4, ft5,
                              ft6, ft7, ft0, ft1, ft2, ft3)
            // y * 3 < x^3 + x^2 - x + 2
            FLT_UNROLL_4(fa0, fa1, fa2, fa3, ft0, ft1, ft2, ft3, a4, a5, a6,
                         a7)
            EVAL_XOSHIRO128P_UNROLL4
            FCVT_UNROLL_8(t0, t1, t2, t3, a0, a1, a2, a3,
                          ft0, ft1, ft2, ft3, fa0, fa1, fa2, fa3)
            // Update the partial sums
            "add %[temp0], %[temp0], a4 \n"
            "add %[temp1], %[temp1], a5 \n"
            "add %[temp2], %[temp2], a6 \n"
            "add %[temp3], %[temp3], a7 \n"            
#endif
#endif
            // Terminate final iteration
            // Normalize PRNs to [0, 1] range
            "fmul.d ft0, ft0, %[div] \n"
            "fmul.d ft1, ft1, %[div] \n"
            "fmul.d ft2, ft2, %[div] \n"
            "fmul.d ft3, ft3, %[div] \n"
            "fmul.d fa0, fa0, %[div] \n"
            "fmul.d fa1, fa1, %[div] \n"
            "fmul.d fa2, fa2, %[div] \n"
            "fmul.d fa3, fa3, %[div] \n"

#if APPLICATION == APPLICATION_PI
            // x^2 + y^2
            EVAL_X2_PLUS_Y2_UNROLL4(ft0, ft1, ft2, ft3, fa0, fa1, fa2, fa3,
                                    ft0, ft1, ft2, ft3)
            // (x^2 + y^2) < 1
            FLT_UNROLL_4(ft0, ft1, ft2, ft3, %[one], %[one], %[one], %[one],
                         a4, a5, a6, a7)
#elif APPLICATION == APPLICATION_POLY
            // y * 3
            // x^3 + x^2 - x + 2
            EVAL_POLY_UNROLL4(ft0, ft1, ft2, ft3, fa0, fa1, fa2, fa3, ft4, ft5,
                              ft6, ft7, ft0, ft1, ft2, ft3)
            // y * 3 < x^3 + x^2 - x + 2
            FLT_UNROLL_4(fa0, fa1, fa2, fa3, ft0, ft1, ft2, ft3, a4, a5, a6,
                         a7)
#endif

            // Update the partial sums
            "add %[temp0], %[temp0], a4 \n"
            "add %[temp1], %[temp1], a5 \n"
            "add %[temp2], %[temp2], a6 \n"
            "add %[temp3], %[temp3], a7 \n"

            : [ temp0 ] "+r"(temp0), [ temp1 ] "+r"(temp1),
              [ temp2 ] "+r"(temp2), [ temp3 ] "+r"(temp3)
#if PRNG == PRNG_LCG
              , ASM_LCG_OUTPUTS
#elif PRNG == PRNG_XOSHIRO128P
              , ASM_XOSHIRO128P_OUTPUTS
#endif
            : [ div ] "f"(max_uint_plus_1_inverse),
              [ n_frep ] "r"(n_iter - 2), [ n_insns ] "i"(N_INSNS_SV)
#if PRNG == PRNG_LCG
              , ASM_LCG_INPUTS
#endif
#if APPLICATION == APPLICATION_PI
              , ASM_PI_CONSTANTS(one)
#elif APPLICATION == APPLICATION_POLY
              , ASM_POLY_CONSTANTS(two, three)
#endif
            : "ft0", "ft1", "ft2", "ft3",
              "fa0", "fa1", "fa2", "fa3",
              "t0", "t1", "t2", "t3", "t4",
              "a0", "a1", "a2", "a3",
              "a4", "a5", "a6", "a7",
              "memory"
#if APPLICATION == APPLICATION_POLY
              , ASM_POLY_CLOBBERS
#endif
        );
        // clang-format on

        // Reduce partial sums
        temp0 += temp1;
        temp0 += temp2;
        temp0 += temp3;

        return temp0;
    }

    return 0;
}
