## Copyright 2025 ETH Zurich and University of Bologna.
## Licensed under the Apache License, Version 2.0, see LICENSE for details.
## SPDX-License-Identifier: Apache-2.0

[
    // Compute cores
    % for j in range(8):
    {
        "thread": "${f'hart_{j}'}",
        // specify which perf.json region we are interested in.
        // There is a preheating run
        "roi": [
            {"idx": 0, "label": "start_preheat"},
            {"idx": 1, "label": "compute_preheat"},
            {"idx": 2, "label": "reduction_preheat"},
            {"idx": 3, "label": "end_preheat"},
            {"idx": 4, "label": "compute"},
            {"idx": 5, "label": "reduction"},
            {"idx": 6, "label": "end"},
        ]
    },
    % endfor
]