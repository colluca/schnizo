// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "snrt.h"

#include "dot.h"
#include "data.h"

#define NUM_RUNS 2

int main() {
    // Preheat the instruction cache
    for (volatile int run = 0; run < NUM_RUNS; run++) {
        dot(n, x, y, &result, args.funcptr);
    }

// TODO: currently only works for single cluster otherwise need to
//       synchronize all cores here
#ifdef BIST
    uint32_t nerr = 1;

    // Check computation is correct
    if (snrt_global_core_idx() == 0) {
        if (result == g) nerr--;
        return nerr;
    }

#endif

    return 0;
}
