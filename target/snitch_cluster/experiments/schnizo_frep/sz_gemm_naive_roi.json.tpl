// Copyright 2025 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

[
    // Compute cores
    % for j in range(8):
    {
        "thread": "${f'hart_{j}'}",
        // specify which perf.json region we are interested in.
        // Only valid for no double buffering and not tiling (only one compute iteration)
        "roi": [
            {"idx": 0, "label": "init"},
            {"idx": 1, "label": "iter_setup1"},
            {"idx": 2, "label": "compute"},
            {"idx": 3, "label": "reduction"},
            {"idx": 4, "label": "iter_setup2"},
            {"idx": 5, "label": "end"},
        ]
    },
    % endfor
]