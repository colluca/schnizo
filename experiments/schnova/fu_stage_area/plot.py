#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
import argparse
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.colors import to_rgba
from matplotlib.patches import Patch
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


# ---------------------------------------------------
# Helper to generate lighter sequential color
# ---------------------------------------------------
def lighten(color, factor=0.5):
    rgba = to_rgba(color)
    return tuple(c + (1 - c) * factor for c in rgba[:3]) + (rgba[3],)


def add_linear_fit(ax, x_values, y_values, plot_positions, label):
    """Fit y = A*x + B, plot the fit, and print A, B, and R^2."""
    x_values = np.asarray(x_values, dtype=float)
    y_values = np.asarray(y_values, dtype=float)
    plot_positions = np.asarray(plot_positions, dtype=float)

    valid = np.isfinite(x_values) & np.isfinite(y_values)
    x_fit = x_values[valid]
    y_fit = y_values[valid]
    plot_positions[valid]

    if x_fit.size < 2 or np.allclose(x_fit, x_fit[0]):
        print(f"{label}: insufficient data for a linear fit")
        return

    A, B = np.polyfit(x_fit, y_fit, 1)
    y_pred = A * x_fit + B
    ss_res = np.sum((y_fit - y_pred) ** 2)
    ss_tot = np.sum((y_fit - np.mean(y_fit)) ** 2)
    r2 = 1.0 - ss_res / ss_tot if not np.isclose(ss_tot, 0.0) else 1.0

    print(f"{label}: A = {A:.4f}, B = {B:.4f}, R^2 = {r2:.6f}")


def plot_functional_units(df, save_path="fus_fu_scalability.png"):
    df = df[
            (df["AluNofRss"] == 1) &
            (df["AluNofRss"] == 1) &
            (df["AluNofRss"] == 1)]

    fu_values = [1, 2, 3, 4]
    types = ["ALU", "LSU", "FPU"]

    x = np.arange(len(fu_values))
    total_width = 0.8
    bar_width = total_width / len(types)

    fig, ax = plt.subplots(figsize=(9, 5))
    prop_cycle = plt.rcParams['axes.prop_cycle'].by_key()['color']

    legend_handles = []

    for j, t in enumerate(types):
        color = prop_cycle[j % len(prop_cycle)]
        seq_color = lighten(color)

        comb = []
        seq = []

        for fu in fu_values:
            if fu == 1:
                # Baseline for FU scaling where everything is 1 but buffers are at 4
                row = df[(df["NofAlus"] == 1) & (df["NofLsus"] == 1) & (df["NofFpus"] == 1)].iloc[0]
            else:
                # Find the row where only the specific FU type is scaled
                if t == "ALU":
                    row = df[(df["NofAlus"] == fu) &
                             (df["NofLsus"] == 1) &
                             (df["NofFpus"] == 1)].iloc[0]
                elif t == "LSU":
                    row = df[(df["NofAlus"] == 1) &
                             (df["NofLsus"] == fu) &
                             (df["NofFpus"] == 1)].iloc[0]
                elif t == "FPU":
                    row = df[(df["NofAlus"] == 1) &
                             (df["NofLsus"] == 1) &
                             (df["NofFpus"] == fu)].iloc[0]

            comb.append(row["CombArea"])
            seq.append(row["SeqArea"])

        comb = np.asarray(comb, dtype=float)
        seq = np.asarray(seq, dtype=float)

        offset = -total_width / 2 + j * bar_width + bar_width / 2
        xpos = x + offset

        ax.bar(xpos, comb, bar_width, color=color, zorder=3)
        ax.bar(xpos, seq, bar_width, bottom=comb, color=seq_color, zorder=3)

        add_linear_fit(
            ax,
            fu_values,
            comb + seq,
            xpos,
            f"Total area vs {t}",
        )

        legend_handles.extend([
            Patch(facecolor=color, label=f"{t} (comb)"),
            Patch(facecolor=seq_color, label=f"{t} (seq)")
        ])

    ax.set_ylabel("Area [kGE]")
    ax.set_xlabel("Number of Functional Units")
    ax.set_xticks(x)
    ax.set_xticklabels(fu_values)
    ax.grid(True, axis='y', zorder=0)
    ax.legend(handles=legend_handles, ncol=3, fontsize=8, loc='upper left')

    fig.tight_layout()
    plt.savefig(save_path)
    plt.close()


# ---------------------------------------------------
# Plot 3: Varying Buffer Slots
# ---------------------------------------------------
def plot_rss(df, save_path="fus_rss.png"):
    df = df[
            (df["NofAlus"] == 1) &
            (df["NofLsus"] == 1) &
            (df["NofFpus"] == 1)]

    rss_values = [1, 2, 4, 8, 16, 32]
    types = ["ALU RSE", "LSU RSE", "FPU RSE"]

    x = np.arange(len(rss_values))
    total_width = 0.8
    bar_width = total_width / len(types)

    fig, ax = plt.subplots(figsize=(10, 5))
    prop_cycle = plt.rcParams['axes.prop_cycle'].by_key()['color']

    legend_handles = []

    for j, t in enumerate(types):
        # Offset color cycle to differentiate from the FU plot colors
        color = prop_cycle[j % len(prop_cycle)]
        seq_color = lighten(color)

        comb = []
        seq = []

        for rss in rss_values:
            if rss == 1:
                row = df[
                    (df["AluNofRss"] == 1)
                    & (df["LsuNofRss"] == 1)
                    & (df["FpuNofRss"] == 1)
                ].iloc[0]
            elif t == "ALU RSE":
                row = df[
                    (df["AluNofRss"] == rss)
                    & (df["LsuNofRss"] == 1)
                    & (df["FpuNofRss"] == 1)
                ].iloc[0]
            elif t == "LSU RSE":
                row = df[
                    (df["AluNofRss"] == 1)
                    & (df["LsuNofRss"] == rss)
                    & (df["FpuNofRss"] == 1)
                ].iloc[0]
            else:
                row = df[
                    (df["AluNofRss"] == 1)
                    & (df["LsuNofRss"] == 1)
                    & (df["FpuNofRss"] == rss)
                ].iloc[0]

            comb.append(row["CombArea"])
            seq.append(row["SeqArea"])

        comb = np.asarray(comb, dtype=float)
        seq = np.asarray(seq, dtype=float)

        offset = -total_width / 2 + j * bar_width + bar_width / 2
        xpos = x + offset

        ax.bar(xpos, comb, bar_width, color=color, zorder=3)
        ax.bar(
            xpos,
            seq,
            bar_width,
            bottom=comb,
            color=seq_color,
            zorder=3,
        )

        add_linear_fit(
            ax,
            rss_values,
            comb + seq,
            xpos,
            f"Total area vs {t}",
        )

        legend_handles.extend([
            Patch(facecolor=color, label=f"{t} (comb)"),
            Patch(facecolor=seq_color, label=f"{t} (seq)")
        ])

    ax.set_ylabel("Area [kGE]")
    ax.set_xlabel("Number of Reservation Station Entries")
    ax.set_xticks(x)
    ax.set_xticklabels(rss_values)
    ax.grid(True, axis='y', zorder=0)
    ax.legend(handles=legend_handles, ncol=3, fontsize=8, loc='upper left')

    fig.tight_layout()
    plt.savefig(save_path)
    plt.close()


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
    print(results())


def plot2():
    df = results()
    plot_functional_units(df)


def plot3():
    df = results()
    plot_rss(df)


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
