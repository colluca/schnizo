#!/usr/bin/env python3
# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

"""Generate comparison and parameter-sweep plots for Schnova experiments.

The module contains shared plotting helpers, architecture comparisons,
parameter-sweep plots, and command-line entry points. Experimental data is
loaded through the project-specific ``experiments`` modules.
"""

import argparse
import re

import matplotlib.pyplot as plt
import numpy as np
from scipy.stats import gmean

try:
    from . import core_area_experiments
    from . import perf_experiments as experiments
    from . import model
except ImportError:
    import core_area_experiments
    import perf_experiments as experiments
    import model


APP_LABELS = {
    'sz_axpy': 'axpy',
    'sz_dot': 'dot',
    'exp': 'exp',
    'log': 'log',
    'pi_xoshiro128p': 'pi_xoshiro',
    'poly_xoshiro128p': 'poly_xoshiro',
}

SCHNOVA_PIPELINE_CONFIGS = {
    'GP-PW1': {
        'label': 'Issue Width 1',
        'cfg': model.SCHNOVA_S,
        'pipe_width': 1,
    },
    'GP-PW2': {
        'label': 'Issue Width 2',
        'cfg': model.SCHNOVA_M,
        'pipe_width': 2,
    },
    'GP-PW4': {
        'label': 'Issue Width 4',
        'cfg': model.SCHNOVA_XL,
        'pipe_width': 4,
    },
    'GP-PW8': {
        'label': 'Issue Width 8',
        'cfg': model.SCHNOVA_XL,
        'pipe_width': 8,
    },
}


# Standard-cell gate-equivalent area in um^2
GE = 0.121

# Schnova design families: area/CLK come from the synthesis results and IPC from the
# performance results, using the config name as key in both. IPC is averaged over the
# family's apps (None: all apps). LA configs are only evaluated on dot and axpy.
GP_PIPELINE_CONFIGS = list(SCHNOVA_PIPELINE_CONFIGS)
LA_PIPELINE_CONFIGS = ['LA-PW1', 'LA-PW2', 'LA-PW4', 'LA-PW8']
LA_APPS = ['sz_dot', 'sz_axpy']
AREA_EFFICIENCY_FAMILIES = {
    'Schnova-GP': (GP_PIPELINE_CONFIGS, None),
    'Schnova-LA': (LA_PIPELINE_CONFIGS, LA_APPS),
}

# Core-level design points for the performance vs. area efficiency plot. Designs
# listed here have hardcoded values (external designs); the Schnova families above
# are added programmatically. Areas are in kGE.
AREA_EFFICIENCY_DESIGNS = {
    'Snitch': {'IPC': 0.85, 'CLK': 1.022, 'area': 129},
    'CVA6S+': {'IPC': 2, 'CLK': 1.164, 'area': 851},
    'C910': {'IPC': 3, 'CLK': 0.757, 'area': 2674},
    'Spatz-LA': {'IPC': 2.14, 'CLK': 1.0, 'area': 583},
}

AREA_EFFICIENCY_BASELINE = 'Snitch'

# Issue widths annotated next to the external superscalar design points
AREA_EFFICIENCY_ISSUE_WIDTHS = {'CVA6S+': 2, 'C910': 3}


AREA_EFFICIENCY_MARKERS = {
    'Snitch': ('tab:blue', 'o'),
    'Schnizo-LA': ('tab:red', 'd'),
    'Schnizo-GP-L': ('tab:cyan', 'd'),
    'CVA6S+': ('tab:pink', 'o'),
    'Spatz-LA': ('tab:orange', '^'),
    'C910': ('tab:red', 'o'),
    'GP-PW1': ('tab:purple', 'H'),
    'GP-PW2': ('tab:purple', 'H'),
    'GP-PW4': ('tab:purple', 'H'),
    'GP-PW8': ('tab:purple', 'H'),
    'LA-PW1': ('tab:green', '*'),
    'LA-PW2': ('tab:green', '*'),
    'LA-PW4': ('tab:green', '*'),
    'LA-PW8': ('tab:green', '*'),
}


def format_metric(val, metric):
    """Format a metric value for human-readable console output."""
    if metric == 'fpu_util':
        return f'{round(100 * val, 1)}%'
    if metric == 'ipc':
        return f'{round(val, 2)}'
    raise ValueError(f'Unsupported metric {metric}')


def _largest_size_pivot(plot_data, metric):
    """Keep the largest input size per application/config and pivot for plotting."""
    if plot_data.empty:
        raise ValueError('No rows match the requested plot configurations.')

    idx_max_size = plot_data.groupby(['app', 'config'])['size'].idxmax()
    return plot_data.loc[idx_max_size].pivot(
        index='app', columns='config', values=metric
    )


def _geomean_ipc(df, hw, apps=None):
    """Geometric-mean IPC across applications (largest size) for one hw config.

    If ``apps`` is given, only those applications are averaged, and all of them
    must have results.
    """
    plot_data = df[df['hw'].eq(hw) & df['mode'].eq('superscalar')].copy()
    if apps is not None:
        plot_data = plot_data[plot_data['app'].isin(apps)]
        missing = set(apps) - set(plot_data['app'])
        if missing:
            raise ValueError(f'Missing performance results for {hw}: {sorted(missing)}')
    if plot_data.empty:
        raise ValueError(f'No performance results for {hw}')
    plot_data['config'] = hw
    return gmean(_largest_size_pivot(plot_data, 'ipc')[hw].dropna())


def _synth_area_clk(synth_df, name):
    """Return (area [kGE], clock period [ns]) of a design from its synthesis results."""
    if name not in synth_df.index:
        raise ValueError(f'No synthesis results for {name}')
    qor = synth_df.loc[name, 'synth_results']['qor_summary']
    return qor['StdCellArea'] / GE / 1000, 1 - qor['WNS']


def plot1(show=True, dir=None, save=True, figsize=(14, 10), ideal_linewidth=2.2):
    """Plot FPU utilization and IPC for various fetch widths.

    Returns the figure and a dictionary with the plotted data. The figure is saved to
    ``plots/plot1.pdf`` only if ``save`` is set.
    """
    # Filter the data
    df = experiments.results(dir=dir)
    plot_data = df[
        df['hw'].isin(SCHNOVA_PIPELINE_CONFIGS)
        & df['mode'].eq('superscalar')
    ].copy()

    # Use the labels from the config dictionary for the plot legend
    plot_data['config'] = plot_data['hw'].map(
        {
            hw: properties['label']
            for hw, properties in SCHNOVA_PIPELINE_CONFIGS.items()
        }
    )

    # Filter data to the largest problem size per application/config and pivot for plotting
    fpu_df = _largest_size_pivot(plot_data, 'fpu_util')
    ipc_df = _largest_size_pivot(plot_data, 'ipc')

    # Fix the order of the bars in the plot (for different fetch-width configurations)
    ordered_cols = ['Issue Width 1', 'Issue Width 2', 'Issue Width 4', 'Issue Width 8']
    fpu_df = fpu_df[[c for c in ordered_cols if c in fpu_df.columns]]
    ipc_df = ipc_df[[c for c in ordered_cols if c in ipc_df.columns]]

    # Fix the order of the bars in the plot (for different apps)
    common_apps = ipc_df.index.intersection(fpu_df.index, sort=False)
    ipc_df = ipc_df.reindex(common_apps)
    fpu_df = fpu_df.reindex(common_apps)

    # Create subfigures
    fig, (ax_fpu, ax_ipc) = plt.subplots(
        2,
        1,
        figsize=figsize,
        sharex=True,
        gridspec_kw={'hspace': 0.08},
    )

    # Create bar plots for FPU utilization and IPC
    fpu_df.plot(kind='bar', ax=ax_fpu, zorder=2, width=0.85,
                linewidth=0.35, legend=True)
    ipc_df.plot(kind='bar', ax=ax_ipc, zorder=2, width=0.85,
                linewidth=0.35, legend=True)

    # Add ideal IPC lines
    configs = {p['label']: p for p in SCHNOVA_PIPELINE_CONFIGS.values()}
    for container, config in zip(ax_ipc.containers, ipc_df.columns):
        properties = configs[config]
        ipc_type = 'superscalar' if properties['pipe_width'] in {4, 8} else 'scalar'
        ideal_ipc = model.theoretical_metrics(
            cfg=properties['cfg'],
            pipe_width=properties['pipe_width'],
        )['ipc'][ipc_type]
        for bar, app in zip(container, ipc_df.index):
            ideal = ideal_ipc.get(app)
            if ideal is None or np.isnan(bar.get_height()):
                continue
            ax_ipc.plot(
                [bar.get_x(), bar.get_x() + bar.get_width()],
                [ideal, ideal],
                color='black',
                linewidth=ideal_linewidth,
                zorder=5,
            )

    # Streamline app labels
    clean_labels = [APP_LABELS.get(app, app) for app in ipc_df.index]

    # Configure plot style
    for ax in fig.axes:
        ax.set_xlabel('')
        ax.minorticks_off()
        ax.grid(True, axis='y', color='gainsboro', linewidth=0.5)
    ax_fpu.axhline(y=1, color='black', linewidth=0.8, zorder=1.75)
    ax_ipc.set_yticks([1, 2, 4, 8])
    ax_fpu.tick_params(axis='x', which='both', labelbottom=False)
    ax_ipc.set_xticklabels(clean_labels, rotation=15, ha='right')
    ax_fpu.set_ylabel('FPU Util.')
    ax_fpu.set_ylim(bottom=0, top=1.3)
    ax_ipc.set_ylabel('IPC')
    ax_ipc.set_ylim(bottom=0, top=max(ipc_df.max().max() * 1.15, 8.5))
    ax_fpu.legend(loc='upper right', ncol=4, columnspacing=1.0, handletextpad=0.5)
    ax_ipc.legend(loc='upper right', ncol=5, columnspacing=1.0, handletextpad=0.5)
    fig.tight_layout()
    if save:
        fig.savefig('plots/plot1.pdf', dpi=300, bbox_inches='tight')
    if show:
        plt.show()
    else:
        plt.close(fig)
    return fig, {'fpu_util': fpu_df, 'ipc': ipc_df}


def plot2(show=True, dir=None, save=True, figsize=(10, 4.2), label_fontsize=12,
          marker_size=130):
    """Plot 1/area vs. performance for the core-level design points.

    Returns the figure and a dictionary with the plotted design points. The figure is
    saved to ``plots/plot2.pdf`` only if ``save`` is set.
    """
    df = experiments.results(dir=dir)
    synth_df = core_area_experiments.results(dir=dir)
    designs = {name: dict(d) for name, d in AREA_EFFICIENCY_DESIGNS.items()}

    # Schnova designs take area and clock period from the synthesis results and IPC
    # from the performance results
    for configs, apps in AREA_EFFICIENCY_FAMILIES.values():
        for name in configs:
            area, clk = _synth_area_clk(synth_df, name)
            designs[name] = {'IPC': _geomean_ipc(df, name, apps=apps),
                             'CLK': clk, 'area': area}

    # Calculate performance and area efficiency
    for d in designs.values():
        d['performance_gips'] = d['IPC'] / d['CLK']
        d['area_efficiency'] = 1000 * d['performance_gips'] / d['area']
        d['inv_area'] = 1 / (1000 * d['area'])
    baseline = designs[AREA_EFFICIENCY_BASELINE]

    # Print the current values to the console
    print()
    print(f"{'Configuration':<18}{'Area [kGE]':>12}{'IPC':>8}{'Perf. [GIPS]':>15}"
          f"{'Perf. Increase':>17}{'Eff. [MIPS/kGE]':>19}{'Eff. Increase':>16}")
    print('-' * 105)
    for name, d in designs.items():
        perf_increase = 100 * (d['performance_gips'] / baseline['performance_gips'] - 1)
        eff_increase = 100 * (d['area_efficiency'] / baseline['area_efficiency'] - 1)
        print(f"{name:<18}{d['area']:>12.0f}{d['IPC']:>8.2f}{d['performance_gips']:>15.3f}"
              f"{perf_increase:>16.1f}%{d['area_efficiency']:>19.3f}{eff_increase:>15.1f}%")
    print()
    print(f'Baseline: {AREA_EFFICIENCY_BASELINE}')

    # Scatter plot of performance vs. inverse area
    fig, ax = plt.subplots(figsize=figsize)
    for name, d in designs.items():
        color, marker = AREA_EFFICIENCY_MARKERS[name]
        in_family = any(name in configs for configs, _ in AREA_EFFICIENCY_FAMILIES.values())
        ax.scatter(d['performance_gips'], d['inv_area'], s=marker_size, color=color,
                   marker=marker, label=None if in_family else name,
                   zorder=3 if name == 'Spatz-LA' else 1)
        if in_family or name in AREA_EFFICIENCY_ISSUE_WIDTHS:
            issue_width = (name.rsplit('PW', 1)[1] if in_family
                           else AREA_EFFICIENCY_ISSUE_WIDTHS[name])
            ax.annotate(issue_width, (d['performance_gips'], d['inv_area']),
                        xytext=(2, 2), textcoords='offset points',
                        fontsize=label_fontsize, color=color)
    # Connect the points of each family; the line is a single legend entry per family
    for label, (configs, _) in AREA_EFFICIENCY_FAMILIES.items():
        color, marker = AREA_EFFICIENCY_MARKERS[configs[0]]
        ax.plot([designs[n]['performance_gips'] for n in configs],
                [designs[n]['inv_area'] for n in configs],
                color=color, marker=marker, markersize=marker_size ** 0.5, linewidth=1.2,
                zorder=0.5, label=label)
    # Iso-(performance/area) contours: performance * area^-1 = const is a hyperbola
    ax.set_xlim(left=0.5)
    ax.set_ylim(bottom=0)
    xlim, ylim = ax.get_xlim(), ax.get_ylim()
    x = np.linspace(xlim[0], xlim[1], 500)
    x = x[x > 0]
    for name in ['Snitch', 'CVA6S+', 'C910', 'Spatz-LA']:
        d = designs[name]
        ax.plot(x, d['performance_gips'] * d['inv_area'] / x,
                color=AREA_EFFICIENCY_MARKERS[name][0], linestyle='--',
                linewidth=1.0, alpha=0.6, zorder=0.5)
    ax.set_xlim(xlim)
    ax.set_ylim(ylim)
    ax.set_xlabel('Performance [GIPS]', fontsize=label_fontsize)
    ax.set_ylabel(r'$\text{Area}^{-1}\,\left[\text{GE}^{-1}\right]$', fontsize=label_fontsize)
    ax.grid(True, alpha=0.35)
    ax.legend(loc='upper right', ncol=2, frameon=True)
    fig.tight_layout()
    if save:
        fig.savefig('plots/plot2.pdf', dpi=300, bbox_inches='tight', pad_inches=0.1)
    if show:
        plt.show()
    else:
        plt.close(fig)
    return fig, designs


def main():
    """Parse command-line options and generate the requested plots."""

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
