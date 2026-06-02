#!/usr/bin/env python3
# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

import pandas as pd
import math

SCHNIZO_XL = {
    'alu': 3,
    'lsu': 3,
    'fpu': 1
}
SCHNIZO_LA = SCHNIZO_XL
SCHNIZO_TR = {
    'alu': 2,
    'lsu': 1,  # 2 LSUs would be beneficial, but can't be used for memory consistency issues
    'fpu': 2
}
SCHNIZO_MC = {
    'alu': 3,
    'lsu': 1,
    'fpu': 2
}

SCHNOVA_S = {
    'alu': 1,
    'lsu': 1,
    'fpu': 1
}

SCHNOVA_M = {
    'alu': 2,
    'lsu': 2,
    'fpu': 1
}

SCHNIZO_CFGS = [
    ('Schnizo-LA', SCHNIZO_LA, None),
    ('Schnizo-TR', SCHNIZO_TR, None),
    ('Schnizo-MC', SCHNIZO_MC, None),
    ('Schnova-S', SCHNOVA_S, 1),
    ('Schnova-M', SCHNOVA_M), 2,
]

BENCHMARK_INSNS = {
    'superscalar': {
        'sz_axpy':          {'alu':  3, 'fpu':  1, 'lsu':  3},
        'sz_dot':           {'alu':  2, 'fpu':  4, 'lsu':  8},
        'exp':              {'alu': 22, 'fpu': 40, 'lsu': 28},
        'log':              {'alu': 34, 'fpu': 40, 'lsu': 16},
        'pi_lcg':           {'alu': 20, 'fpu': 28, 'lsu':  0},
        'pi_xoshiro128p':   {'alu': 84, 'fpu': 28, 'lsu':  0},
        'poly_lcg':         {'alu': 20, 'fpu': 40, 'lsu':  0},
        'poly_xoshiro128p': {'alu': 84, 'fpu': 40, 'lsu':  0},
    }
}
BENCHMARK_INSNS['scalar'] = BENCHMARK_INSNS['superscalar'].copy()
BENCHMARK_INSNS['scalar']['sz_axpy'] = {'alu':  3, 'fpu':  4, 'lsu':  12}


def insns_per_fu(insns, cfg, fu):
    return math.ceil(insns[fu] / cfg[fu])


def ideal_ipc(insns, cfg, pipe_width=None):
    """
    Compute ideal IPC considering both FU bottlenecks AND pipeline width.
    """
    total_insns = sum(insns.values())
    
    # 1. Back-end bottleneck: Cycles limited by specific Functional Units
    fu_cycles = [math.ceil(insns[fu] / cfg[fu]) for fu in cfg if insns.get(fu, 0)]
    
    # 2. Front-end bottleneck: Cycles limited by Fetch/Dispatch width
    if pipe_width is not None:
        dispatch_cycles = math.ceil(total_insns / pipe_width)
    else:
        dispatch_cycles = 0 # Assume infinite width if None
        
    # The slowest stage determines the total cycles
    total_cycles = max(max(fu_cycles), dispatch_cycles)
    
    return total_insns / total_cycles


def ideal_fpu_util(insns):
    return insns['fpu'] / sum(insns.values())


def theoretical_metrics(cfg=None, pipe_width=None):
    d = {
        'fpu_util': {
            'scalar': {
                app: ideal_fpu_util(BENCHMARK_INSNS['scalar'][app])
                for app in ['sz_axpy', 'sz_dot']
            }
        }
    }
    if cfg is not None:
        d['ipc'] = {
                'superscalar': {
                    app: ideal_ipc(BENCHMARK_INSNS['superscalar'][app], cfg, pipe_width)
                    for app in BENCHMARK_INSNS['superscalar']
                }
            }
    return d


def main():
    rows = {}

    for app, insns in BENCHMARK_INSNS['superscalar'].items():
        row = {}

        for cfg_name, cfg in SCHNIZO_CFGS:
            row[(cfg_name, 'ipc')] = ideal_ipc(insns, cfg)
            for fu in cfg:
                row[(cfg_name, fu)] = insns_per_fu(insns, cfg, fu)

        rows[app] = row

    df = pd.DataFrame.from_dict(rows, orient='index')

    # Turn tuple columns into a proper MultiIndex
    df.columns = pd.MultiIndex.from_tuples(df.columns, names=['config', 'metric'])

    # Optional: enforce metric order inside each config
    metric_order = ['alu', 'lsu', 'fpu', 'ipc']
    config_order = [name for name, _ in SCHNIZO_CFGS]
    df = df.reindex(
        columns=pd.MultiIndex.from_product(
            [config_order, metric_order],
            names=['config', 'metric']
        )
    )

    print(df)


if __name__ == '__main__':
    main()
