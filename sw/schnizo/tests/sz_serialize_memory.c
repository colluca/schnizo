// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Pascal Etterli <petterli@student.ethz.ch>

#include "snrt.h"
#include "szrt.h"

// Test the serialized memory consistency mode.
// We update an array and immediately after we want to copy it.
// In non-consistency mode this will fail.

// asm volatile(
//     ""
//     /* outputs: [ asm-name ] "constraint" (c-name)
//        To use value use: %asm-name
//        If no asm-name use %0, %1, ... in the order specified
//        constraints (many more, = or + is required for outputs):
//        "=": this variable is overwritten, dont assume previous value is there, except when tied to input.
//        "+": this variable is read and written.
//        "r": this value must reside in a register 
//        "m": this value must reside in memory */
//     : 
//     /* inputs: same as outputs except = and + are not allowed*/
//     :
//     /* clobbers - modified registers beyond the outputs */
//     :
// );

#define LEN 10

int main() {
    const uint32_t n_reps = LEN;
    const uint32_t initial = 2;

    if (snrt_cluster_core_idx() == 0) {
        uint32_t source[LEN];
        uint32_t destination[LEN] = {0};

        for (int i = 0; i < LEN; i++) {
            source[i] = i;
        }

        uint32_t* src_addr = source;
        uint32_t* dst_addr = destination;

        uint32_t tmp;

        // There must be at least 2 LSUs
        if (szrt_nof_lsus() < 2) {
            return 1;
        }
        if (szrt_nof_alus() < 2) {
            return 2;
        }

        // With FREP_MEM_SERIALIZED it should give correct values.
        // With the default mode (FREP_MEM_NO_CONSISTENCY) the loop will produce wrong values.
        szrt_set_frep_mem_consistency(FREP_MEM_SERIALIZED);

        asm volatile(
            // Wait until all FPU & LSU instructions have retired to have a clean register and
            // pipeline state. Note, the cache is not yet synchronized.
            // We must place the fence in the same asm block as otherwise FPU instructions are placed
            // in between.
            "fmv.x.w t0, fa0 \n"
            "mv      t0, t0  \n"
            "fence           \n"
            // loop
            "frep.o %[n_frep],   7,             0, 0  \n"
            "lw     t0,          0(%[src_addr])       \n"
            "addi   %[src_addr], %[src_addr],   %[inc]\n"
            "addi   t0,          t0,            3     \n"
            "sw     t0,          0(%[tmp_addr])       \n"
            // In the non-consistent mode the next load will execute in parallel to the store because
            // there is no register dependency.
            "lw     t1,          0(%[tmp_addr])       \n"
            "sw     t1,          0(%[dst_addr])       \n"
            "addi   %[dst_addr], %[dst_addr],   %[inc]\n"
            // outputs
            : [src_addr]"+r"(src_addr), [dst_addr]"+r"(dst_addr)
            // inputs - FREP repeats n_frep+1 times..
            : [n_frep]"r"(LEN-1), [inc]"i"(sizeof(uint32_t)), [tmp_addr]"r"(&tmp)
            // clobbers - modified registers beyond the outputs
            : "t0", "t1", "memory"
        );

        for (int i = 0; i < LEN; i++) {
            if ((source[i]+3) != destination[i]) {
                printf("Error: index %d does not match.", i);
                return 3;
            }
        }
    }
    return 0;
}