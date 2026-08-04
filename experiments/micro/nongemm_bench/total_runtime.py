#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

import json
import warnings
import pandas as pd
from pathlib import Path

from . import registry as reg
from .experiments import results as _sim_results

PER_MODEL_CSV = Path(__file__).parent / 'registry.csv'

# Ops that are intentionally not benchmarked (not DNN compute kernels).
_IGNORED_OPS = {
    'aten::__and__', 'aten::adaptive_avg_pool1d', 'aten::adaptive_avg_pool2d',
    'aten::all', 'aten::arange', 'aten::bitwise_not', 'aten::cat', 'aten::clamp',
    'aten::contiguous', 'aten::copy_', 'aten::cos', 'aten::cumsum', 'aten::detach',
    'aten::detach_', 'aten::dropout', 'aten::embedding', 'aten::empty', 'aten::eq',
    'aten::exp', 'aten::expand', 'aten::expand_as', 'aten::fill_', 'aten::flatten',
    'aten::floor', 'aten::full', 'aten::full_like', 'aten::ge', 'aten::group_norm',
    'aten::gt', 'aten::index', 'aten::index_put_', 'aten::is_nonzero',
    'aten::lift_fresh', 'aten::log2', 'aten::masked_fill', 'aten::max_pool2d',
    'aten::meshgrid', 'aten::ne', 'aten::new_empty', 'aten::new_full',
    'aten::new_zeros', 'aten::ones', 'aten::pad', 'aten::permute', 'aten::pow',
    'aten::repeat', 'aten::reshape', 'aten::roll', 'aten::rsub',
    'aten::select', 'aten::sigmoid', 'aten::sin', 'aten::slice', 'aten::split',
    'aten::split_with_sizes', 'aten::sqrt', 'aten::squeeze', 'aten::stack',
    'aten::sub', 'aten::to', 'aten::topk', 'aten::transpose', 'aten::type_as',
    'aten::unbind', 'aten::unflatten', 'aten::unsqueeze', 'aten::upsample_bilinear2d',
    'aten::upsample_nearest2d', 'aten::view', 'aten::where', 'aten::zeros',
    'aten::zeros_like', 'cudadevicesynchronize', 'torchvision::roi_align',
}

# Reverse map: op_name -> kernel (e.g., 'aten::add' -> 'add')
_OP_TO_KERNEL = {
    op: kernel
    for kernel, ops in reg.KERNEL_TO_OPS.items()
    for op in ops
}

# For eltwise kernels, derive_axes does experiment['op'].lower() where op is
# e.g. 'ELTWISE_ADD', giving 'eltwise_add'.
_ELTWISE_KERNELS = set(reg.ELTWISE_OP.keys())
_KERNEL_TO_APP = {
    k: reg.ELTWISE_OP[k].lower() if k in _ELTWISE_KERNELS else k
    for k in reg.KERNELS + list(_ELTWISE_KERNELS)
}
_ELTWISE_APPS = frozenset(_KERNEL_TO_APP[k] for k in _ELTWISE_KERNELS)


def _registry_size_key(kernel, clamped):
    """JSON key derived from clamped params for a registry entry."""
    if kernel in _ELTWISE_KERNELS:
        # strip 'op' — eltwise op distinction is captured in 'app', not size_key
        d = {k: v for k, v in clamped.items() if k != 'op'}
    else:
        d = clamped
    return json.dumps(d, sort_keys=True)


def _sim_size_key(app, row):
    """JSON key reconstructed from sim_df axis columns."""
    if app in ('relu', 'gelu', 'silu') or app in _ELTWISE_APPS:
        return json.dumps({'size': int(row['size'])}, sort_keys=True)
    if app == 'layernorm':
        return json.dumps(
            {'input_dim': {'batch_size': 1, 'seq_len': 1, 'embeddings': int(row['embeddings'])}},
            sort_keys=True)
    if app == 'rms_norm':
        return json.dumps(
            {'input_dim': {'batch_size': 1, 'seq_len': 1, 'hidden_dim': int(row['hidden_dim'])}},
            sort_keys=True)
    if app == 'softmax':
        return json.dumps(
            {'input_dim': {'batch_size': 1, 'seq_len': 1,
                           'input_samples': int(row['input_samples'])},
             'reduce_dim': -1},
            sort_keys=True)
    if app == 'batchnorm':
        return json.dumps({'CI': 1, 'IH': int(row['IH']), 'IW': int(row['IW'])}, sort_keys=True)
    return None


def _is_broadcast(shape_str, kernel):
    """True for binary eltwise ops where the two tensor shapes differ (incl. scalar)."""
    if kernel not in reg.BINARY_KERNELS:
        return False
    try:
        tensors = json.loads(shape_str)
        t0 = tensors[0] if tensors else []
        t1 = tensors[1] if len(tensors) > 1 else []
        return not t1 or t1 != t0
    except Exception:
        return False


def _build_lookup(sim_df):
    """Build lookup: (app, variant, size_key) -> cycles."""
    lookup = {}
    for _, row in sim_df.iterrows():
        if pd.isna(row.get('tstart')) or pd.isna(row.get('tend')):
            continue
        app = row['app']
        variant = row['variant']
        key = _sim_size_key(app, row)
        if key is not None:
            lookup[(app, variant, key)] = int(row['cycles'])
    return lookup


def layer_df(dir=None):
    """Return a DataFrame with one row per (registry layer, variant).

    Columns: model, batch_size, seq_len, op_name, shape, kernel, count,
             scale, cycles_<variant>, total_cycles_<variant>
    """
    sim_df = _sim_results(dir=dir, mode='registry')
    sim_df['cycles'] = sim_df['tend'] - sim_df['tstart']
    lookup = _build_lookup(sim_df)
    variants = sorted(sim_df['variant'].unique().tolist())

    registry = pd.read_csv(PER_MODEL_CSV)
    rows = []

    for _, row in registry.iterrows():
        op_name = row['op_name']
        kernel = _OP_TO_KERNEL.get(op_name)
        if kernel is None:
            if op_name not in _IGNORED_OPS:
                warnings.warn(f"No kernel for op '{op_name}', skipping.")
            continue

        params = reg.shape_to_params(row['shape'], kernel)
        if params is None:
            if not _is_broadcast(row['shape'], kernel):
                warnings.warn(f"No params for op '{op_name}' shape {row['shape']!r}, skipping.")
            continue

        clamped, scale = reg.clamp_params(params, kernel)
        app = _KERNEL_TO_APP[kernel]
        key = _registry_size_key(kernel, clamped)

        entry = {
            'model':      row['model'],
            'batch_size': row['batch_size'],
            'seq_len':    row['seq_len'],
            'op_name':    op_name,
            'shape':      row['shape'],
            'kernel':     kernel,
            'count':      row['count'],
            'scale':      scale,
        }
        found = False
        for variant in variants:
            cycles = lookup.get((app, variant, key))
            if cycles is not None:
                entry[f'cycles_{variant}'] = cycles
                entry[f'total_cycles_{variant}'] = cycles * scale * row['count']
                found = True
            else:
                entry[f'cycles_{variant}'] = None
                entry[f'total_cycles_{variant}'] = None

        if not found:
            warnings.warn(
                f"No simulation result for op '{op_name}' app='{app}' key={key}, skipping.")
        else:
            rows.append(entry)

    df = pd.DataFrame(rows)
    _add_speedup(df, prefix='cycles_')
    return df


def _add_speedup(df, prefix='total_cycles_'):
    """Add a speedup column (superscalar / zol) in-place if both variants are present."""
    if f'{prefix}superscalar' in df.columns and f'{prefix}zol' in df.columns:
        df['speedup'] = df[f'{prefix}zol'] / df[f'{prefix}superscalar']


def summary_df(ldf=None, dir=None):
    """Total cycles per (model, batch_size, seq_len), one column per variant."""
    if ldf is None:
        ldf = layer_df(dir=dir)
    variants = [c.removeprefix('total_cycles_')
                for c in ldf.columns if c.startswith('total_cycles_')]
    sdf = (ldf
           .groupby(['model', 'batch_size', 'seq_len'], dropna=False)
           [[f'total_cycles_{v}' for v in variants]]
           .sum()
           .reset_index())
    _add_speedup(sdf, prefix='total_cycles_')
    return sdf


def main():
    import argparse
    parser = argparse.ArgumentParser(
        description="Total DNN kernel runtime across ML models: superscalar vs zol")
    parser.add_argument('--save-layers', metavar='CSV',
                        help="Save per-layer DataFrame to CSV for inspection")
    parser.add_argument('--dir', help="Override results directory")
    args = parser.parse_args()

    dir_ = Path(args.dir) if args.dir else None

    ldf = layer_df(dir=dir_)
    sdf = summary_df(ldf=ldf)
    print(sdf.to_string(index=False))

    if args.save_layers:
        ldf.to_csv(args.save_layers, index=False)
        print(f"\nPer-layer data saved to {args.save_layers}")


if __name__ == '__main__':
    main()
