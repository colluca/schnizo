#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
import argparse
import matplotlib.pyplot as plt
import numpy as np
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


def plot_operand_ifs(show=False, hide_x_axis=False):
    import numpy as np
    import matplotlib.pyplot as plt
    from matplotlib.colors import to_rgba
    from matplotlib.patches import Patch
    df = results()
    # ---------------------------------------------------
    # Prepare dataframe
    # ---------------------------------------------------
    grouped = (
        df.groupby(["NumRegs", "NofOperandIfs"])[["CombArea", "SeqArea"]]
        .sum()
        .reset_index()
    )

    num_regs = sorted(grouped["NumRegs"].unique())
    operand_ifs = sorted(grouped["NofOperandIfs"].unique())

    x = np.arange(len(num_regs))

    # total width occupied by all bars at one x-position
    total_width = 0.8
    bar_width = total_width / len(operand_ifs)

    fig, ax = plt.subplots(figsize=(9, 5))

    prop_cycle = plt.rcParams['axes.prop_cycle'].by_key()['color']

    # ---------------------------------------------------
    # Helper for lighter seq color
    # ---------------------------------------------------
    def lighten(color, factor=0.5):
        rgba = to_rgba(color)
        return tuple(c + (1 - c) * factor for c in rgba[:3]) + (rgba[3],)

    legend_handles = []

    # ---------------------------------------------------
    # Plot grouped stacked bars
    # ---------------------------------------------------
    for j, nof_if in enumerate(operand_ifs):

        color = prop_cycle[j % len(prop_cycle)]
        seq_color = lighten(color)

        subset = grouped[grouped["NofOperandIfs"] == nof_if]

        comb = []
        seq = []

        for nr in num_regs:
            row = subset[subset["NumRegs"] == nr]

            if len(row) == 0:
                comb.append(0)
                seq.append(0)
            else:
                comb.append(row["CombArea"].values[0])
                seq.append(row["SeqArea"].values[0])

        # center grouped bars around x-position
        offset = (
            -total_width / 2
            + j * bar_width
            + bar_width / 2
        )

        xpos = x + offset

        # combinational
        ax.bar(
            xpos,
            comb,
            bar_width,
            color=color,
            zorder=3
        )

        # sequential stacked on top
        ax.bar(
            xpos,
            seq,
            bar_width,
            bottom=comb,
            color=seq_color,
            zorder=3
        )

        # legend
        legend_handles.extend([
            Patch(facecolor=color,
                  label=f"{nof_if} op ports (comb)"),
            Patch(facecolor=seq_color,
                  label=f"{nof_if} op ports (seq)")
        ])

    # ---------------------------------------------------
    # Axes styling
    # ---------------------------------------------------
    ax.set_ylabel("Area [kGE]")
    ax.set_xticks(x)

    if hide_x_axis:
        ax.tick_params(axis='x', which='both',
                       bottom=False, labelbottom=False)
    else:
        ax.set_xlabel("Number of GPR")
        ax.set_xticklabels(num_regs)

    ax.grid(True, axis='y', zorder=0)

    ax.legend(
        handles=legend_handles,
        ncol=3,
        fontsize=8
    )

    fig.tight_layout()

    if show:
        plt.show()

    return grouped


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
    plot_operand_ifs(show=True)

def main():
    plots = [plot1, plot2]
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
