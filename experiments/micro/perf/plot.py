#!/usr/bin/env python3
# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

import argparse
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from pathlib import Path

THEORETICAL_METRICS = {
    'fpu_util':
    {
        # 4x unrolled
        'sz_axpy': 4/(4*3+3+4),
        'sz_dot': 4/(4*2+2+4)
    }
}

METRIC_LABELS = {
    'fpu_util': 'FPU Util.',
    'ipc': 'IPC',
}

APP_LABELS = {
    'sz_axpy': 'AXPY',
    'sz_dot': 'DOT',
    'exp': 'EXP',
    'log': 'LOG',
}


def fit_inverse_function(n_vals, y_vals, x_lim):
    """Fit a function of the form y = (a * n) / (b * n + c)"""
    # Linearize the model to use least squares
    # 1/y = (b/a) + (c/a) * (1/n)
    # with inv_y = 1/y and inv_n = 1/n, model becomes inv_y = k0 + k1 * inv_n
    inv_y = 1.0 / y_vals
    inv_n = 1.0 / n_vals
    A = np.column_stack([np.ones_like(inv_n), inv_n])
    params, _, _, _ = np.linalg.lstsq(A, inv_y, rcond=None)
    k0, k1 = params  # k0=b/a, k1=c/a
    a = 1.0  # this parameter could be simplified away
    b = k0
    c = k1
    n_fit = np.linspace(n_vals.min(), x_lim, 200)
    return n_fit, (a * n_fit) / (b * n_fit + c), a, b, c


def kernel_scaling_plot(df, app):
    """Plot IPC and FPU utilization vs problem size with fitted curves"""
    # Extract relevant data
    df = df[(df['app'] == app) & (df['mode'] == 'superscalar')].copy()
    df = df.sort_values('size')
    n_vals = df['size'].to_numpy(dtype=float)
    ipc_vals = df['ipc'].to_numpy(dtype=float)
    util_vals = df['fpu_util'].to_numpy(dtype=float)

    # Plot measured data
    fig, ax = plt.subplots(2, 1, sharex=True)
    ax[0].scatter(n_vals, ipc_vals, color='black', marker='o', label='Measurements', zorder=2)
    ax[1].scatter(n_vals, util_vals, color='black', marker='o', label='Measurements', zorder=2)

    # Interpolate and plot
    function_label = 'Fit: $\\frac{a*n}{b*n+c}$'
    x_lim = 8192
    n_fit, ipc_fit, a, b, _ = fit_inverse_function(n_vals, ipc_vals, x_lim)
    ax[0].plot(n_fit, ipc_fit, color='black', linestyle='--', label=function_label, zorder=1)
    ax[0].axhline(a / b, color='black', linestyle='-', label='Fit: asymptote')
    n_fit, util_fit, a, b, _ = fit_inverse_function(n_vals, util_vals, x_lim)
    ax[1].plot(n_fit, util_fit, color='black', linestyle='--', label=function_label, zorder=1)
    ax[1].axhline(a / b, color='black', linestyle='-', label='Fit: asymptote')

    # Format plot
    ax[1].set_xlabel(f'{APP_LABELS[app]} length (n)')
    ax[1].set_xticks(n_vals.tolist() + [x_lim])
    ax[1].tick_params(axis='x', labelrotation=30)
    ax[0].set_ylabel('IPC')
    ax[1].set_ylabel('FPU Utilization')
    ax[0].legend()
    ax[1].legend()
    ax[0].grid(True, color='gainsboro', linewidth=0.5)
    ax[1].grid(True, color='gainsboro', linewidth=0.5)
    fig.tight_layout()

    # Show plot
    plt.show()


def superscalar_comparison_plot(df, metric='fpu_util'):
    """Compare scalar and superscalar results across applications"""
    # Pivot data to get utilization from the run with max size per app and mode
    idx_max_size = df.groupby(['app', 'mode'])['size'].idxmax()
    plot_df = df.loc[idx_max_size].pivot(index='app', columns='mode', values=metric)
    plot_df.columns = [col.capitalize() for col in plot_df.columns]

    # Calculate asymptotes for superscalar mode
    asymptotes = []
    for app in plot_df.index:
        app_df = df[(df['app'] == app) & (df['mode'] == 'superscalar')].sort_values('size')
        n_vals = app_df['size'].to_numpy(dtype=float)
        util_vals = app_df[metric].to_numpy(dtype=float)
        _, _, a, b, _ = fit_inverse_function(n_vals, util_vals, x_lim=8192)
        asymptotes.append(a / b)

    # Create grouped bar chart
    fig, ax = plt.subplots()
    plot_df.plot(kind='bar', ax=ax)

    # Get the bar containers for each mode
    bar_containers = ax.containers
    scalar_bars = bar_containers[list(plot_df.columns).index('Scalar')]
    superscalar_bars = bar_containers[list(plot_df.columns).index('Superscalar')]

    # Add theoretical markers on top of scalar bars
    for i, (bar, app) in enumerate(zip(scalar_bars, plot_df.index)):
        if metric in THEORETICAL_METRICS:
            if app in THEORETICAL_METRICS[metric]:
                theoretical = THEORETICAL_METRICS[metric][app]
                ax.scatter(bar.get_x() + bar.get_width() / 2., theoretical,
                           color='black', marker='D', s=100, zorder=3,
                           label='Theoretical' if i == 0 else '')

    # Add asymptote markers on top of superscalar bars
    for i, (bar, asymptote) in enumerate(zip(superscalar_bars, asymptotes)):
        ax.scatter(bar.get_x() + bar.get_width() / 2., asymptote,
                   color='black', marker='*', s=200, zorder=3,
                   label='Asymptote' if i == 0 else '')

    # Format plot
    ax.set_xlabel('')
    ax.set_ylabel(METRIC_LABELS[metric], fontsize=12)
    ax.set_xticklabels(plot_df.index, rotation=0)
    ax.legend()
    ax.grid(True, axis='y', color='gainsboro', linewidth=0.5, alpha=0.7)
    fig.tight_layout()
    plt.show()


def plot1(df):
    kernel_scaling_plot(df, app="sz_axpy")


def plot2(df):
    kernel_scaling_plot(df, app="sz_dot")


def plot3(df):
    kernel_scaling_plot(df, app="exp")


def plot4(df):
    kernel_scaling_plot(df, app="log")


def plot5(df):
    superscalar_comparison_plot(df, 'fpu_util')


def plot6(df):
    superscalar_comparison_plot(df, 'ipc')


def main():
    """Load results from CSV and generate plots"""

    plots = [plot1, plot2, plot3, plot4, plot5, plot6]
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

    # Load dataframe from CSV
    results_path = Path('results.csv')
    if not results_path.exists():
        print(f"Error: Results file not found at {results_path}")
        print("Please run experiments.py first to generate results.")
        return
    df = pd.read_csv(results_path)

    # Generate selected plots
    for name in args.plots:
        plot_dict[name](df)


if __name__ == '__main__':
    main()
