#!/usr/bin/env python3
# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

import argparse
import matplotlib.pyplot as plt
import numpy as np
from scipy.stats import gmean
try:
    from . import experiments
    from . import model
except ImportError:
    import experiments
    import model


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
    df = df[(df['hw'] == '3x32_3x32_1x64') & (df['app'] == app) &
            (df['mode'] == 'superscalar')].copy()
    df = df.sort_values('size')
    n_vals = df['size'].to_numpy(dtype=float)
    ipc_vals = df['ipc'].to_numpy(dtype=float)
    util_vals = df['fpu_util'].to_numpy(dtype=float)

    # Plot measured data
    fig, ax = plt.subplots(1, 2)
    ax[0].scatter(n_vals, ipc_vals, color='black', marker='o', label='Measurements', zorder=2)
    ax[1].scatter(n_vals, util_vals, color='black', marker='o', label='Measurements', zorder=2)

    # Interpolate and plot
    function_label = 'Fit: $\\frac{a*n}{b*n+c}$'
    x_lim = 6000
    n_fit, ipc_fit, a, b, _ = fit_inverse_function(n_vals, ipc_vals, x_lim)
    ax[0].plot(n_fit, ipc_fit, color='black', linestyle='--', label=function_label, zorder=1)
    ax[0].axhline(a / b, color='tab:red', linestyle='-', label='Fit: asymptote')
    n_fit, util_fit, a, b, _ = fit_inverse_function(n_vals, util_vals, x_lim)
    ax[1].plot(n_fit, util_fit, color='black', linestyle='--', label=function_label, zorder=1)
    ax[1].axhline(a / b, color='tab:red', linestyle='-', label='Fit: asymptote')

    # Format plot
    fig.supxlabel(f'{APP_LABELS[app]} vector length (in multiples of 256 elements)')
    xticks = n_vals.tolist()
    for a in ax:
        a.set_xticks(xticks)
        a.set_xticklabels([str(int(v) // 256) for v in xticks])
    # ax[0].set_ylabel('IPC')
    # ax[1].set_ylabel('FPU Utilization')
    if app == 'sz_axpy':
        ax[0].set_yticks(sorted({t for t in set(ax[0].get_yticks()) | {7} if t == int(t)}))
    ax[0].legend()
    ax[1].legend()
    ax[0].grid(True, color='gainsboro', linewidth=0.5)
    ax[1].grid(True, color='gainsboro', linewidth=0.5)
    fig.tight_layout()

    if show:
        plt.show()

    return df


def superscalar_comparison_plot(df, metric='fpu_util', show=True):
    """
    Compare Schnizo (Scalar/Superscalar) vs. Schnvoa Widths (1, 2, 4, 8)
    with shared Ideal IPC lines.
    """
    schnizo_hw = '3x32_3x32_1x64'
    schnvoa_widths = ['sv_1_3x1_3x1_1x1', 'sv_2_3x1_3x1_1x1', 
                      'sv_4_3x1_3x1_1x1', 'sv_8_3x1_3x1_1x1']
    
    # 1. Filter: Schnizo (both modes) + Schnvoa (superscalar only)
    mask_schnizo = (df['hw'] == schnizo_hw)
    mask_schnvoa = (df['hw'].isin(schnvoa_widths)) & (df['mode'] == 'superscalar')
    plot_df = df[mask_schnizo | mask_schnvoa].copy()

    def identify_config(row):
        if row['hw'] == schnizo_hw:
            return f"Schnizo {row['mode'].capitalize()}"
        # Extract width and label as Schnvoa
        width = row['hw'].split('_')[1]
        return f"Schnvoa Width {width}"

    plot_df['config'] = plot_df.apply(identify_config, axis=1)
    
    # Pivot for plotting
    idx_max_size = plot_df.groupby(['app', 'config'])['size'].idxmax()
    plot_df = plot_df.loc[idx_max_size].pivot(index='app', columns='config', values=metric)

    # Force logical ordering: Schnizo first, then Schnvoa scaling
    ordered_cols = [
        'Schnizo Scalar', 'Schnizo Superscalar', 
        'Schnvoa Width 1', 'Schnvoa Width 2', 'Schnvoa Width 4', 'Schnvoa Width 8'
    ]
    plot_df = plot_df[[c for c in ordered_cols if c in plot_df.columns]]

    # 2. Create the Bar Chart
    fig, ax = plt.subplots(figsize=(14, 7))
    plot_df.plot(kind='bar', ax=ax, zorder=3, width=0.85)

    # 3. Add Ideal IPC lines (using Schnizo XL theoreticals for all superscalar)
    if metric == 'ipc':
        labeled = False
        theoretical_data = model.theoretical_metrics(cfg=model.SCHNIZO_XL)['ipc']['superscalar']
        
        for i, col_name in enumerate(plot_df.columns):
            # Apply to all Superscalar/Schnvoa columns, skip Schnizo Scalar
            if 'Scalar' in col_name:
                continue
                
            container = ax.containers[i]
            for bar, app in zip(container, plot_df.index):
                if app in theoretical_data:
                    ideal = theoretical_data[app]
                    ax.plot([bar.get_x(), bar.get_x() + bar.get_width()], 
                            [ideal, ideal],
                            color='tab:red', linewidth=2.0, zorder=5,
                            label='Ideal IPC' if not labeled else '')
                    labeled = True

    # 4. Final Formatting
    ax.axhline(y=1, color='black', linewidth=0.8, zorder=2.5)
    ax.set_ylabel(METRIC_LABELS.get(metric, metric.upper()))
    ax.set_xlabel('')
    
    clean_labels = [app.replace('xoshiro128p', 'xoshiro') for app in plot_df.index]
    ax.set_xticklabels(clean_labels, rotation=15, ha='right')
    
    ax.legend(title="Core Architecture", loc='upper left', bbox_to_anchor=(1, 1))
    ax.grid(True, axis='y', color='gainsboro', linewidth=0.5, alpha=0.7)
    
    # Set Y-limits
    if metric == 'ipc':
        ax.set_ylim(bottom=0, top=max(plot_df.max().max() * 1.15, 8.5))
    elif metric == 'fpu_util':
        ax.set_ylim(bottom=0, top=1.3)

    fig.tight_layout()

    # Console Output for quick verification
    print(f"\n--- Geomean {metric} Performance ---")
    for col in plot_df.columns:
        gm = gmean(plot_df[col].dropna())
        print(f"{col:18}: {format_metric(gm, metric)}")

    if show:
        plt.show()

    return plot_df


def rsp_ports_tradeoff_plot(df, show=True):
    """Compare IPC across hw configs for superscalar mode, at max problem size"""
    df = df[df['mode'] == 'superscalar']
    idx_max_size = df.groupby(['app', 'hw'])['size'].idxmax()
    plot_df = df.loc[idx_max_size].pivot(index='app', columns='hw', values='ipc')

    fc_ipc = plot_df['3x32_3x32_1x64']
    plot_df = plot_df[['3x32_3x32_1x64_1port', '3x32_3x32_1x64_2ports', '3x32_3x32_1x64_3ports']]
    plot_df = plot_df.rename(columns={
        '3x32_3x32_1x64': 'fc', '3x32_3x32_1x64_1port': '1 port',
        '3x32_3x32_1x64_2ports': '2 ports', '3x32_3x32_1x64_3ports': '3 ports'
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
                label='Idealized' if not labeled else '')
        labeled = True

    ax.axhline(y=1, color='black', linewidth=0.5, zorder=2.5)
    ax.set_xlabel('')
    ax.set_ylabel(METRIC_LABELS['ipc'])
    labels = [app.replace('xoshiro128p', 'xoshiro') for app in plot_df.index]
    ax.set_xticklabels(labels, rotation=15, ha='right')
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
