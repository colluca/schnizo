## Copyright 2026 ETH Zurich and University of Bologna.
## Licensed under the Apache License, Version 2.0, see LICENSE for details.
## SPDX-License-Identifier: Apache-2.0

{
    "input_dim": {"batch_size": 1, "seq_len": 1, "input_samples": ${experiment['data_cfg']['size']}},
    "reduce_dim": -1,
    "funcptr": "softmax_fp32_schnizo"
}