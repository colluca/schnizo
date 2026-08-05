#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
import argparse
try:
    from . import experiments
except ImportError:
    import experiments

GE = 0.121


def to_ge(area_um2):
    return area_um2 / GE


def to_kge(area_um2):
    return to_ge(area_um2) / 1e3


def results(dir=None):
    df = experiments.results(dir=dir)

    df['timestamp'] = df['synth_results'].str['qor_summary'].str['timestamp']
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


def plot(dir=None, show=False, hide_x_axis=False, rs_type=0):
    import numpy as np
    import pandas as pd
    import matplotlib.pyplot as plt
    from matplotlib.colors import to_rgba
    from matplotlib.patches import Patch

    # Load datasets
    df_opt = results(dir=dir)
    df_base = pd.read_pickle("initial_rs_design.pkl")

    # Filter RS type
    df_opt = df_opt[df_opt["RsType"] == rs_type]

    # Group
    opt = df_opt.groupby("NofRss")[["CombArea", "SeqArea"]].sum()
    base = df_base.groupby("NofRss")[["CombArea", "SeqArea"]].sum()

    df = opt.join(base, lsuffix="_opt", rsuffix="_base").dropna()

    x = np.arange(len(df.index))
    width = 0.35

    fig, ax = plt.subplots()

    prop_cycle = plt.rcParams['axes.prop_cycle'].by_key()['color']

    legend_handles = []

    for i, idx in enumerate(df.index):

        # -----------------------------
        # BASE COLOR = DESIGN TYPE
        # -----------------------------
        base_color = prop_cycle[0]   # baseline fixed color family
        opt_color = prop_cycle[1]   # optimized fixed color family

        # lighten helper
        def lighten(color, factor=0.5):
            rgba = to_rgba(color)
            return tuple(c + (1 - c) * factor for c in rgba[:3]) + (rgba[3],)

        base_seq_color = lighten(base_color)
        opt_seq_color = lighten(opt_color)

        # -----------------------------
        # BASELINE (left bar)
        # -----------------------------
        ax.bar(
            x[i] - width/2,
            df.loc[idx, "CombArea_base"],
            width,
            color=base_color,
            zorder=3
        )

        ax.bar(
            x[i] - width/2,
            df.loc[idx, "SeqArea_base"],
            width,
            bottom=df.loc[idx, "CombArea_base"],
            color=base_seq_color,
            zorder=3
        )

        # -----------------------------
        # OPTIMIZED (right bar)
        # -----------------------------
        ax.bar(
            x[i] + width/2,
            df.loc[idx, "CombArea_opt"],
            width,
            color=opt_color,
            zorder=3
        )

        ax.bar(
            x[i] + width/2,
            df.loc[idx, "SeqArea_opt"],
            width,
            bottom=df.loc[idx, "CombArea_opt"],
            color=opt_seq_color,
            zorder=3
        )

        # -----------------------------
        # LEGEND (only once)
        # -----------------------------
        if i == 0:
            legend_handles = [
                Patch(facecolor=base_color, label="Baseline (comb)"),
                Patch(facecolor=base_seq_color, label="Baseline (seq)"),
                Patch(facecolor=opt_color, label="Optimized (comb)"),
                Patch(facecolor=opt_seq_color, label="Optimized (seq)")
            ]

    # -----------------------------
    # AXES
    # -----------------------------
    ax.set_ylabel("Area [kGE]")
    ax.set_xticks(x)

    if hide_x_axis:
        ax.tick_params(axis='x', which='both', bottom=False, labelbottom=False)
    else:
        ax.set_xlabel("Number of RSEs")
        ax.set_xticklabels(df.index)

    ax.grid(True, axis='y', zorder=0)
    ax.legend(handles=legend_handles, ncol=2, fontsize=8)

    fig.tight_layout()

    # -----------------------------
    # AREA SAVING COMPUTATION
    # -----------------------------
    baseline_total = df["CombArea_base"] + df["SeqArea_base"]
    optimized_total = df["CombArea_opt"] + df["SeqArea_opt"]

    saving_pct = (baseline_total - optimized_total) / baseline_total * 100

    print("\nArea savings per NofRss:")
    for idx, val in saving_pct.items():
        print(f"NofRss = {idx}: {val:.2f}%")

    print(f"On average: {np.mean(saving_pct)}%")
    if show:
        plt.show()

    return df


def linear_regression(dir=None):
    """Fit a linear model (area = slope * n_rse + intercept) for each port count.

    Returns a dict keyed by NofResRspIfs, with CombArea, SeqArea, StdCellArea fits,
    each containing 'slope', 'intercept', and 'r2'.
    """
    from scipy.stats import linregress
    df = results(dir=dir)
    df = df[(df['ConsumerCount'] == 64) & (df['NofConstants'] == 4) & (df['NofOperands'] == 3)]

    fits = {}
    for p in sorted(df['NofResRspIfs'].unique()):
        sub = df[df['NofResRspIfs'] == p].sort_values('NofRss')
        x = sub['NofRss'].values
        fits[p] = {}
        for col in ['CombArea', 'SeqArea', 'StdCellArea']:
            slope, intercept, r, _, _ = linregress(x, sub[col].values)
            fits[p][col] = {'slope': slope, 'intercept': intercept, 'r2': r**2}
    return fits


def linear_regression_constants(dir=None):
    """Fit a linear model (area = slope * n_constants + intercept) for each port count.

    Returns a dict keyed by NofResRspIfs, with CombArea, SeqArea, StdCellArea fits,
    each containing 'slope', 'intercept', and 'r2'.
    """
    from scipy.stats import linregress
    df = results(dir=dir)
    df = df[(df['ConsumerCount'] == 64) & (df['NofRss'] == 4) & (df['NofOperands'] == 3)]

    fits = {}
    for p in sorted(df['NofResRspIfs'].unique()):
        sub = df[df['NofResRspIfs'] == p].sort_values('NofConstants')
        x = sub['NofConstants'].values
        fits[p] = {}
        for col in ['CombArea', 'SeqArea', 'StdCellArea']:
            slope, intercept, r, _, _ = linregress(x, sub[col].values)
            fits[p][col] = {'slope': slope, 'intercept': intercept, 'r2': r**2}
    return fits


def plot1():
    plot(show=True, rs_type=0)


def plot2():
    plot(show=True, rs_type=1)


def plot3():
    plot(show=True, rs_type=2)


def main():
    plots = [plot1, plot2, plot3]
    plot_dict = {f.__name__: f for f in plots}

    # Parse command line arguments
    parser = argparse.ArgumentParser()
    parser.add_argument(
        'plots',
        nargs='+',
        choices=plot_dict.keys(),
        default=plot_dict.keys(),
        help='Select which plots to show (default: all)'
    )
    args = parser.parse_args()

    # Generate selected plots
    for name in args.plots:
        _ = plot_dict[name]()


if __name__ == '__main__':
    main()
