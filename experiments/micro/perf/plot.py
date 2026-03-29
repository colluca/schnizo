#!/usr/bin/env python3
# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

import argparse
import matplotlib.pyplot as plt
import numpy as np
from scipy.stats import gmean
from . import experiments
from . import model


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


def format_metric(val, metric):
    if metric == 'fpu_util':
        return f'{round(100 * val, 1)}%'
    elif metric == 'ipc':
        return f'{round(val, 2)}'
    else:
        raise ValueError(f'Unsupported metric {metric}')


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


def kernel_scaling_plot(df, app, show=True):
    """Plot IPC and FPU utilization vs problem size with fitted curves"""
    # Extract relevant data
    df = df[(df['hw'] == 'fc') & (df['app'] == app) & (df['mode'] == 'superscalar')].copy()
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

    if show:
        plt.show()

    return df


def superscalar_comparison_plot(df, metric='fpu_util', show=True):
    """Compare scalar and superscalar results across applications"""
    df = df[((df['mode'] == 'superscalar') & (df['hw'] == 'fc')) |
            ((df['mode'] == 'scalar') & (df['hw'] == '1port'))]
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
    plot_df.plot(kind='bar', ax=ax, zorder=3)

    # Get the bar containers for each mode
    bar_containers = ax.containers
    scalar_bars = bar_containers[list(plot_df.columns).index('Scalar')]
    superscalar_bars = bar_containers[list(plot_df.columns).index('Superscalar')]

    # Add theoretical markers on top of scalar bars
    labeled = False
    for bar, app in zip(scalar_bars, plot_df.index):
        if metric == 'fpu_util':
            if app in model.theoretical_metrics()[metric]['scalar']:
                theoretical = model.theoretical_metrics()[metric]['scalar'][app]
                ax.scatter(bar.get_x() + bar.get_width() / 2., theoretical,
                           color='black', marker='D', zorder=4,
                           label='Theoretical' if not labeled else '')
                labeled = True

    # Add asymptote markers on top of superscalar bars
    for i, (bar, asymptote) in enumerate(zip(superscalar_bars, asymptotes)):
        ax.scatter(bar.get_x() + bar.get_width() / 2., asymptote,
                   color='black', marker='*', zorder=4,
                   label='Asymptote' if i == 0 else '')

    # Add ideal IPC lines on top of superscalar bars
    labeled = False
    if metric == 'ipc':
        for bar, app in zip(superscalar_bars, plot_df.index):
            if app in model.theoretical_metrics(cfg=model.SCHNIZO_XL)['ipc']['superscalar']:
                ideal = model.theoretical_metrics(cfg=model.SCHNIZO_XL)['ipc']['superscalar'][app]
                ax.plot([bar.get_x(), bar.get_x() + bar.get_width()], [ideal, ideal],
                        color='tab:red', zorder=3,
                        label='Ideal' if not labeled else '')
                labeled = True

    # Reference line at y=1
    ax.axhline(y=1, color='black', linewidth=0.5, zorder=2.5)

    # Format plot
    ax.set_xlabel('')
    ax.set_ylabel(METRIC_LABELS[metric])
    ax.set_xticklabels(plot_df.index, rotation=30, ha='right')
    ax.legend(ncol=len(ax.get_legend_handles_labels()[0]), handlelength=1.0)
    ax.set_axisbelow(True)
    ax.grid(True, axis='y', color='gainsboro', linewidth=0.5, alpha=0.7)
    ax.set_yticks(sorted(set(ax.get_yticks()) | {1}))
    fig.tight_layout()

    geomean_superscalar_metric = format_metric(gmean(plot_df['Superscalar']), metric)
    print(f'Geomean superscalar {metric}: {geomean_superscalar_metric}')

    if show:
        plt.show()

    return plot_df


def rsp_ports_tradeoff_plot(df, show=True):
    """Compare IPC across hw configs for superscalar mode, at max problem size"""
    df = df[df['mode'] == 'superscalar']
    idx_max_size = df.groupby(['app', 'hw'])['size'].idxmax()
    plot_df = df.loc[idx_max_size].pivot(index='app', columns='hw', values='ipc')

    fc_ipc = plot_df['fc']
    plot_df = plot_df.drop(columns='fc').rename(columns={
        '1port': '1 port', '2ports': '2 ports', '3ports': '3 ports'
    })

    fig, ax = plt.subplots()
    plot_df.plot(kind='bar', ax=ax, zorder=3)

    # Draw fc IPC as a horizontal line spanning all bars in each app group
    labeled = False
    for app_idx, app in enumerate(plot_df.index):
        bars = [c.patches[app_idx] for c in ax.containers]
        x_left = bars[0].get_x()
        x_right = bars[-1].get_x() + bars[-1].get_width()
        ax.plot([x_left, x_right], [fc_ipc[app], fc_ipc[app]],
                color='tab:red', zorder=4,
                label='Fully connected' if not labeled else '')
        labeled = True

    ax.axhline(y=1, color='black', linewidth=0.5, zorder=2.5)
    ax.set_xlabel('')
    ax.set_ylabel(METRIC_LABELS['ipc'])
    ax.set_xticklabels(plot_df.index, rotation=30, ha='right')
    ax.legend(ncol=len(ax.get_legend_handles_labels()[0]), handlelength=1.0)
    ax.set_axisbelow(True)
    ax.grid(True, axis='y', color='gainsboro', linewidth=0.5, alpha=0.7)
    ax.set_yticks(sorted(set(ax.get_yticks()) | {1}))
    fig.tight_layout()

    if show:
        plt.show()

    return plot_df


def plot1(show=True, dir=None):
    df = experiments.results(dir=dir)
    return kernel_scaling_plot(df, app="sz_axpy", show=show)


def plot2(show=True, dir=None):
    df = experiments.results(dir=dir)
    return kernel_scaling_plot(df, app="sz_dot", show=show)


def plot3(show=True, dir=None):
    df = experiments.results(dir=dir)
    return kernel_scaling_plot(df, app="exp", show=show)


def plot4(show=True, dir=None):
    df = experiments.results(dir=dir)
    return kernel_scaling_plot(df, app="log", show=show)


def plot5(show=True, dir=None):
    df = experiments.results(dir=dir)
    return superscalar_comparison_plot(df, 'fpu_util', show=show)


def plot6(show=True, dir=None):
    df = experiments.results(dir=dir)
    return superscalar_comparison_plot(df, 'ipc', show=show)


def plot7(show=True, dir=None):
    df = experiments.results(dir=dir)
    return rsp_ports_tradeoff_plot(df, show=show)


def main():
    """Load results from CSV and generate plots"""

    plots = [plot1, plot2, plot3, plot4, plot5, plot6, plot7]
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
