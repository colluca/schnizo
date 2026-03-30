// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "snrt.h"

int main() {
    const uint32_t n_reps = 10;
    volatile uint32_t init = 5;
    uint32_t exp = (1 << n_reps) * init;

    // Calculates (2^n_reps)*init
    asm volatile(
        "frep.o %[n_frep], 1, 0, 0        \n"
        "add    %[init], %[init], %[init] \n"
        : [ init ] "+r"(init)
        : [ n_frep ] "r"(n_reps - 1)
        : );

    return init - exp;
}
