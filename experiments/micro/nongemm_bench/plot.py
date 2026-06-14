#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

import argparse
import matplotlib.pyplot as plt

import experiments


APP_LABELS = {
    'eltwise_add': 'ADD',
    'eltwise_mul': 'MUL',
    'eltwise_div': 'DIV',
    'eltwise_neg': 'NEG',
    'relu':        'ReLU',
    'rms_norm':    'RMSNorm',
}

VARIANT_LABELS = {
    'zol':         'ZOL',
    'superscalar': 'Superscalar',
}


def ipc_comparison_plot(df, show=True):
    """IPC of ZOL vs. superscalar variants for each kernel."""
    plot_df = df.pivot(index='app', columns='variant', values='ipc')
    plot_df = plot_df[['zol', 'superscalar']]
    plot_df = plot_df.rename(columns=VARIANT_LABELS)
    plot_df = plot_df.rename(index=APP_LABELS)
    print(df)

    fig, ax = plt.subplots()
    plot_df.plot(kind='bar', ax=ax, zorder=3)
    ax.axhline(y=1, color='black', linewidth=0.5, zorder=2.5)
    ax.set_xlabel('')
    ax.set_ylabel('IPC')
    ax.set_xticklabels(plot_df.index, rotation=15, ha='right')
    ax.legend(ncol=2, handlelength=1.0)
    ax.set_axisbelow(True)
    ax.grid(True, axis='y', color='gainsboro', linewidth=0.5, alpha=0.7)
    fig.tight_layout()

    if show:
        plt.show()

    return plot_df


def plot1(show=True, dir=None):
    df = experiments.results(dir=dir)
    return ipc_comparison_plot(df, show=show)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dir', default=None, help='Experiment results directory')
    args = parser.parse_args()
    plot1(dir=args.dir)


if __name__ == '__main__':
    main()
