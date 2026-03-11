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

#define N_INSNS (N_PRNG_INSNS + N_APP_INSNS + N_COMMON_INSNS)

static inline uint32_t calculate_psum_schnizo(PRNG_T *prngs,
                                              unsigned int n_samples) {
    unsigned int result = 0;

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
        uint32_t n_iter = n_samples / 4;

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

            FREP " %[n_frep], %[n_insns], 0, 0 \n"

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
                          ft0, ft1, ft2, ft3, fa0, fa1, fa2, fa3)
#endif

            // Update the partial sums
            "add %[temp0], %[temp0], a4 \n"
            "add %[temp1], %[temp1], a5 \n"
            "add %[temp2], %[temp2], a6 \n"
            "add %[temp3], %[temp3], a7 \n"

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
              [ n_frep ] "r"(n_iter - 2), [ n_insns ] "i"(N_INSNS)
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
        result += temp0;
        result += temp1;
        result += temp2;
        result += temp3;

        return result;
    }

    return 0;
}
