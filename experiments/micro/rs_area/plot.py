#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

import matplotlib.pyplot as plt
import numpy as np
from . import experiments

GE = 0.121


def to_ge(area_um2):
    return area_um2 / GE


def to_kge(area_um2):
    return to_ge(area_um2) / 1e3


def results(dir=None):
    df = experiments.results(dir=dir)

    df['StdCellArea'] = df['synth_results'].str['qor_summary'].str['StdCellArea']
    df['StdCellArea'] = df['StdCellArea'].map(to_kge).round(0).astype('int')
    df['hierarchy_details'] = df['synth_results'].str['hierarchy_details']
    df['CombArea'] = df['hierarchy_details'].map(lambda x: to_kge(x.tree.get_attr('CombArea')))
    df['SeqArea'] = df['hierarchy_details'].map(lambda x: to_kge(x.tree.get_attr('SeqArea')))
    df['MacroBBArea'] = df['hierarchy_details'].map(
        lambda x: to_kge(x.tree.get_attr('MacroBBArea'))
    )
    df['CombArea'] = df['CombArea'].round(0).astype('int')
    df['SeqArea'] = df['SeqArea'].round(0).astype('int')
    df['MacroBBArea'] = df['MacroBBArea'].round(0).astype('int')
    df['1BitEqSeq'] = (df['synth_results'].str['multibit'].str['1BitEqSeq']).astype('int')
    df['GE/bit'] = (1e3 * df['SeqArea'] / df['1BitEqSeq']).round(1)

    df.drop(columns=['hierarchy_details'], inplace=True)
    df.drop(columns=['synth_results'], inplace=True)

    return df


def plot(dir=None, show=False, hide_x_axis=False):
    df = results(dir=dir)
    df = df[(df['ConsumerCount'] == 64) & (df['NofConstants'] == 4)]
    print(df)

    # Pivot CombArea and SeqArea separately
    comb_df = df.pivot_table(index='NofRss', columns='NofOperands', values='CombArea')
    seq_df = df.pivot_table(index='NofRss', columns='NofOperands', values='SeqArea')

    operands = comb_df.columns
    n_groups = len(comb_df.index)
    n_bars = len(operands)
    x = np.arange(n_groups)
    width = 0.8 / n_bars

    # Use the default color cycle, darken for SeqArea
    fig, ax = plt.subplots()
    prop_cycle = plt.rcParams['axes.prop_cycle'].by_key()['color']

    for i, ops in enumerate(operands):
        base_color = prop_cycle[i % len(prop_cycle)]
        # Convert hex to RGB, create a darker shade for SeqArea
        from matplotlib.colors import to_rgba
        rgba = to_rgba(base_color)
        light = tuple(c + (1 - c) * 0.5 for c in rgba[:3]) + (rgba[3],)

        offset = (i - (n_bars - 1) / 2) * width
        ax.bar(x + offset, comb_df[ops], width, label=f'{ops} op. (comb)',
               color=base_color, zorder=3)
        ax.bar(x + offset, seq_df[ops], width, bottom=comb_df[ops],
               label=f'{ops} op. (seq)', color=light, zorder=3)

    ax.set_ylabel('Area [kGE]')
    ax.set_xticks(x)
    if hide_x_axis:
        ax.tick_params(axis='x', which='both', bottom=False, labelbottom=False)
    else:
        ax.set_xlabel('Number of RSEs')
        ax.set_xticklabels(comb_df.index)
    ax.legend()
    ax.grid(True, axis='y')
    fig.tight_layout()

    if show:
        plt.show()

    return df.pivot_table(index='NofRss', columns='NofOperands', values='StdCellArea')


def plot_constants(dir=None, show=False, hide_x_axis=False):
    df = results(dir=dir)
    df = df[(df['NofOperands'] == 3) & (df['NofRss'] == 4) & (df['ConsumerCount'] == 64)]
    df = df.drop_duplicates(subset='NofConstants').sort_values('NofConstants')

    x = np.arange(len(df))
    width = 0.8

    from matplotlib.colors import to_rgba
    prop_cycle = plt.rcParams['axes.prop_cycle'].by_key()['color']
    base_color = prop_cycle[0]
    rgba = to_rgba(base_color)
    light = tuple(c + (1 - c) * 0.5 for c in rgba[:3]) + (rgba[3],)

    fig, ax = plt.subplots()
    ax.bar(x, df['CombArea'].values, width, label='comb', color=base_color, zorder=3)
    ax.bar(x, df['SeqArea'].values, width, bottom=df['CombArea'].values,
           label='seq', color=light, zorder=3)

    ax.set_ylabel('Area [kGE]')
    ax.set_xticks(x)
    if hide_x_axis:
        ax.tick_params(axis='x', which='both', bottom=False, labelbottom=False)
    else:
        ax.set_xlabel('Number of constants')
        ax.set_xticklabels(df['NofConstants'].values)
    ax.legend()
    ax.grid(True, axis='y')
    fig.tight_layout()

    if show:
        plt.show()

    return df.set_index('NofConstants')['StdCellArea']


def linear_regression(dir=None):
    """Fit a linear model (area = slope * n_rse + intercept) for each operand count.

    Returns a dict keyed by NofOperands, with CombArea, SeqArea, StdCellArea fits,
    each containing 'slope', 'intercept', and 'r2'.
    """
    from scipy.stats import linregress
    df = results(dir=dir)
    df = df[df['ConsumerCount'] == 64]

    fits = {}
    for ops in sorted(df['NofOperands'].unique()):
        sub = df[df['NofOperands'] == ops].sort_values('NofRss')
        x = sub['NofRss'].values
        fits[ops] = {}
        for col in ['CombArea', 'SeqArea', 'StdCellArea']:
            slope, intercept, r, _, _ = linregress(x, sub[col].values)
            fits[ops][col] = {'slope': slope, 'intercept': intercept, 'r2': r**2}
    return fits


def main():
    print(results())


if __name__ == '__main__':
    main()
