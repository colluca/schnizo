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

    return 0;
}
