// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "snrt.h"

#include "axpy.h"
#include "data.h"
#include "math.h"

#define NUM_RUNS 2

int main() {
    for (volatile int run = 0; run < NUM_RUNS; run++) {
        axpy_job(&args);
    }

// TODO: currently only works for single cluster otherwise need to
//       synchronize all cores here
#ifdef BIST
    uint32_t n = args.n;
    double* z = args.z;
    uint32_t nerr = 0;

    // Check computation is correct
    if (snrt_global_core_idx() == 0) {
        printf("Checking results for %d iterations...\n", n);
        for (int i = 0; i < n; i++) {
            if (fabs(z[i] - g[i]) > 1e-10) {
                nerr++;
                printf("Error: Index %d -> Result = %f, Expected = %f\n", i,
                       (float)z[i], (float)g[i]);
            }
            // printf("%d %d\n", z[i], g[i]);
        }
    }

    return nerr;
#endif

    return 0;
}
