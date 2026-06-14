## Copyright 2026 ETH Zurich and University of Bologna.
## Licensed under the Apache License, Version 2.0, see LICENSE for details.
## SPDX-License-Identifier: Apache-2.0

{
    "size": ${experiment['data_cfg']['size']},
    "n_tiles": 1,
    "approximate": "sigmoid",
    "funcptr": "gelu_fp32_sigmoid_schnizo"
}
