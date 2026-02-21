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

// --------------------------
// FREP helpers
// --------------------------

/**
 * @brief Wait until all FPU and LSU instructions have retired.
 * 
 * @note This works only in regular mode.
 */
inline void szrt_total_fence() {
    unsigned volatile tmp;
    // We cannot use szrt_fpu_fence because the compiler does not strictly enforce the order.
    asm volatile(
        "fmv.x.w %0, fa0\n"
        "mv      %0, %0\n"
        "fence"
        : "+r"(tmp)::"memory");
    asm volatile("" ::: "memory");  // compile memory barrier
}

// --------------------------
// FREP CSR STATE helpers
// --------------------------

/**
 * @brief Reads out details about the superscalar capabilities.
 */
inline uint32_t szrt_frep_state() {
    uint32_t volatile capabilities;
    asm volatile("csrr %[reg], 0x7C4" : [ reg ] "=r"(capabilities)::);
    return capabilities;
}

#define FREP_NOF_FU_BITS 4
#define FREP_NOF_FU_MASK ((1 << FREP_NOF_FU_BITS) - 1)
#define FREP_NOF_SLOTS_BITS 5
#define FREP_NOF_SLOTS_OFFSET FREP_NOF_FU_BITS
#define FREP_NOF_SLOTS_MASK ((1 << FREP_NOF_SLOTS_BITS) - 1)
#define FREP_FU_OFFSET (FREP_NOF_FU_BITS + FREP_NOF_SLOTS_BITS)

/**
 * @brief Reads out number of ALUs for FREP mode.
 */
inline unsigned szrt_nof_alus() { return szrt_frep_state() & FREP_NOF_FU_MASK; }

/**
 * @brief Reads out number of slots per ALU for FREP mode.
 */
inline unsigned szrt_nof_alu_slots() {
    return (szrt_frep_state() >> FREP_NOF_SLOTS_OFFSET) & FREP_NOF_SLOTS_MASK;
}

/**
 * @brief Reads out number of LSUs for FREP mode.
 */
inline unsigned szrt_nof_lsus() {
    return (szrt_frep_state() >> (1 * FREP_FU_OFFSET)) & FREP_NOF_FU_MASK;
}

/**
 * @brief Reads out number of slots per LSU for FREP mode.
 */
inline unsigned szrt_nof_lsu_slots() {
    return (szrt_frep_state() >> (1 * FREP_FU_OFFSET + FREP_NOF_SLOTS_OFFSET)) &
           FREP_NOF_SLOTS_MASK;
}

/**
 * @brief Reads out number of FPUs for FREP mode.
 */
inline unsigned szrt_nof_fpus() {
    return (szrt_frep_state() >> (2 * FREP_FU_OFFSET)) & FREP_NOF_FU_MASK;
}

/**
 * @brief Reads out number of slots per FPU for FREP mode.
 */
inline unsigned szrt_nof_fpu_slots() {
    return (szrt_frep_state() >> (2 * FREP_FU_OFFSET + FREP_NOF_SLOTS_OFFSET)) &
           FREP_NOF_SLOTS_MASK;
}

// --------------------------
// FREP CSR CONFIG helpers
// --------------------------

#define FREP_MEM_CONS_BITS 3
#define FREP_MEM_CONS_OFFSET 0
#define FREP_MEM_CONS_MASK ((1 << FREP_MEM_CONS_BITS) - 1)

typedef enum {
    FREP_MEM_NO_CONSISTENCY = 0,
    FREP_MEM_SERIALIZED = 1
} frep_mem_consistency_e;

inline uint32_t szrt_frep_config() {
    uint32_t volatile config;
    asm volatile("csrr %[reg], 0x7C5" : [ reg ] "=r"(config)::);
    return config;
}

/**
 * @brief Reads out the current FREP memory consistency mode.
 */
inline frep_mem_consistency_e szrt_frep_mem_consistency() {
    return (frep_mem_consistency_e)(
        (szrt_frep_config() >> FREP_MEM_CONS_OFFSET) & FREP_MEM_CONS_MASK);
}

/**
 * @brief Sets the FREP memory consistency mode.
 */
inline void szrt_set_frep_mem_consistency(frep_mem_consistency_e mode) {
    uint32_t volatile config = 0;

    config = szrt_frep_config();
    config &= ~(FREP_MEM_CONS_MASK << FREP_MEM_CONS_OFFSET);
    config |= (mode & FREP_MEM_CONS_MASK) << FREP_MEM_CONS_OFFSET;
    asm volatile("csrw 0x7C5, %[reg]" : : [ reg ] "r"(config) :);
}
