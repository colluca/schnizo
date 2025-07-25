// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Pascal Etterli <petterli@student.ethz.ch>

#include "snrt.h"

// Test that multi cycle instructions issued before we enter LCP still can retire.
// In LCP we switch the writeback path to the RSS. But there can still be an instruction
// in flight (in the pipeline) of a FU.


int main() {
    if (!snrt_is_compute_core()) {
        return 0;
    }

    const uint32_t n_reps = 10;
    register volatile uint32_t res asm("t1") = 0;
    register double start asm("fa0") = 8.0;

    asm volatile(
        // loop - fill each ALU with at least 2 instructions
        "fmv.x.w t0, fa0   \n" // 4 cycles latency
        "frep.o %[n_frep], 2,      0, 0\n" // "Disconnects" writeback of FU
        "add    %[res],    t0,     t0  \n" // depends on the result of the fmv.x.w instruction
        "add    %[res],    %[res], t0  \n"
        // outputs
        : [res]"+r"(res)
        // inputs - FREP repeats n_frep+1 times
        : [n_frep]"r"(n_reps-1)
        // clobbers - modified registers beyond the outputs
        : "t0", "memory"
    );

    // Test passes if we don't deadlock on the add instruction.
    return 0;
}
