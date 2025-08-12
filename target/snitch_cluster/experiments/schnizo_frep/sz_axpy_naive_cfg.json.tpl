// Copyright 2023 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

{
    // If we use the "each array on a separate bank" approach we must ensure that the TCDM is big enough..
    "n_tiles": ${experiment['n_tiles']},
    "n": ${experiment['n']},
    "funcptr": "axpy_naive_unrolled" // only effective if axpy_job() and not axpy_job_distributed()
}
