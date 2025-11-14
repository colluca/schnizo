// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "snrt.h"

#include "axpy.h"
#include "data.h"
#include "math.h"

#define NUM_RUNS 2

#define PROBLEM_SIZE 1000




int main() {
    
    #ifndef BENCHMARK
    for (volatile int run = 0; run < NUM_RUNS; run++) {
        axpy_job(&args);
    }
    #endif

    return 0;
}
