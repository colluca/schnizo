// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Helper functions for working with Schnizo superscalar FREP.

#pragma once

/**
 * @brief Synchronize the integer and float pipelines.
 * because FPU instructions can still be optimized after this block..
 * 
 * @note THIS IS NOT COMPILE SAVE! This works only in regular mode.
 */
inline void szrt_fpu_fence() {
    unsigned volatile tmp;
    // The fmv passes the FPU and thus clears the pipeline as the succeeding mv stalls on the
    // scoreboard.
    asm volatile(
        "fmv.x.w %0, fa0\n"
        "mv      %0, %0\n"
        : "+r"(tmp)::"memory");
}

/**
 * @brief Wait until all FPU and LSU instructions have retired.
 * 
 * @note This works only in regular mode.
 */
inline void szrt_total_fence() {
    unsigned tmp;
    // We cannot use szrt_fpu_fence because the compiler does not strictly enforce the order.
    asm volatile(
        "fmv.x.w %0, fa0\n"
        "mv      %0, %0\n"
        "fence"
        : "+r"(tmp)::"memory"
    );
    asm volatile ("":::"memory"); // compile memory barrier
}

/**
 * @brief Reads out details about the superscalar capabilities.
 */
inline uint32_t szrt_frep_config() {
    uint32_t volatile capabilities;
    asm volatile("csrr %[reg], 0x7C4" :[reg]"=r"(capabilities)::);
    return capabilities;
}

#define FREP_NOF_FU_BITS 4
#define FREP_NOF_FU_MASK ((1 << FREP_NOF_FU_BITS) - 1)
#define FREP_NOF_SLOTS_BITS 5
#define FREP_NOF_SLOTS_OFFSET FREP_NOF_FU_BITS
#define FREP_NOF_SLOTS_MASK ((1 << FREP_NOF_SLOTS_BITS) - 1)
#define FREP_FU_OFFSET (FREP_NOF_FU_BITS + FREP_NOF_SLOTS_BITS)

inline unsigned szrt_nof_alus() {
    return szrt_frep_config() & FREP_NOF_FU_MASK;
}

inline unsigned szrt_nof_alu_slots() {
    return (szrt_frep_config() >> FREP_NOF_SLOTS_OFFSET) & FREP_NOF_SLOTS_MASK;
}

inline unsigned szrt_nof_lsus() {
    return (szrt_frep_config() >> (1 * FREP_FU_OFFSET)) & FREP_NOF_FU_MASK;
}

inline unsigned szrt_nof_lsu_slots() {
    return (szrt_frep_config() >> (1 * FREP_FU_OFFSET + FREP_NOF_SLOTS_OFFSET)) & FREP_NOF_SLOTS_MASK;
}

inline unsigned szrt_nof_fpus() {
    return (szrt_frep_config() >> (2 * FREP_FU_OFFSET)) & FREP_NOF_FU_MASK;
}

inline unsigned szrt_nof_fpu_slots() {
    return (szrt_frep_config() >> (2 * FREP_FU_OFFSET + FREP_NOF_SLOTS_OFFSET)) & FREP_NOF_SLOTS_MASK;
}
