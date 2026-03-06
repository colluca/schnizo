// Copyright 2024 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Luca Colagrande <colluca@iis.ee.ethz.ch>

#include "math.h"
#include "snrt.h"

#include "data.h"
#include "vlogf.h"

double b_golden[len];

int main() {
    uint32_t tstart, tend;

#ifdef BIST
    // Calculate logarithm of input array using reference implementation
    if (snrt_cluster_core_idx() == 0) {
        for (int i = 0; i < len; i++) {
            b_golden[i] = (double)logf(a[i]);
        }
    }
#endif

    // Synchronize cores
    snrt_cluster_hw_barrier();

    // Calculate logarithm of input array using vectorized implementation
    vlogf_kernel(a, b);

#ifdef BIST
    // Check if the results are correct
    if (snrt_cluster_core_idx() == 0) {
        uint32_t n_err = len;
        for (int i = 0; i < len; i++) {
            if ((float)b_golden[i] != (float)b[i])
                printf("Error: b_golden[%d] = %f, b[%d] = %f\n", i,
                       (float)b_golden[i], i, (float)b[i]);
            else
                n_err--;
        }
        return n_err;
    } else
#endif
        return 0;
}
