#!/usr/bin/env python3
# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

import argparse
from turtle import width
import matplotlib.pyplot as plt
import numpy as np
import re
from scipy.stats import gmean

try:
    from . import experiments
    from . import model
    from . import pw1_experiments
    from . import pw2_experiments
    from . import pw4_experiments
    from . import pw8_experiments
except ImportError:
    import experiments
    import model
    import pw1_experiments
    import pw2_experiments
    import pw4_experiments
    import pw8_experiments


METRIC_LABELS = {
    'fpu_util': 'FPU Util.',
    'ipc': 'IPC',
}

APP_LABELS = {
    'sz_axpy': 'axpy',
    'sz_dot': 'dot',
    'exp': 'exp',
    'log': 'log',
}

SCHNIZO_HW = '3x32_3x32_1x64'
SCHNOVA_ZOL_HW = 'schnova_zol'

# Manual fallback values for the Schnizo GP-L AXPY result.
SCHNIZO_GPL_AXPY_IPC = 6.794368196876479
SCHNIZO_GPL_AXPY_FPU_UTIL = 0.9784997611084567

SCHNOVA_PIPELINE_CONFIGS = {
    'GP-PW1': {
        'label': 'Schnova FW1',
        'cfg': model.SCHNOVA_S,
        'pipe_width': 1,
    },
    'GP-PW2': {
        'label': 'Schnova FW2',
        'cfg': model.SCHNOVA_M,
        'pipe_width': 2,
    },
    'GP-PW4': {
        'label': 'Schnova FW4',
        'cfg': model.SCHNOVA_XL,
        'pipe_width': 4,
    },
    'GP-PW8': {
        'label': 'Schnova FW8',
        'cfg': model.SCHNOVA_XL,
        'pipe_width': 8,
    },
}


def format_metric(val, metric):
    if metric == 'fpu_util':
        return f'{round(100 * val, 1)}%'
    elif metric == 'ipc':
        return f'{round(val, 2)}'
    else:
        raise ValueError(f'Unsupported metric {metric}')


def _largest_size_pivot(plot_data, metric):
    """Keep the largest input size per application/config and pivot for plotting."""
    if plot_data.empty:
        raise ValueError('No rows match the requested plot configurations.')

    idx_max_size = plot_data.groupby(['app', 'config'])['size'].idxmax()
    return plot_data.loc[idx_max_size].pivot(
        index='app', columns='config', values=metric
    )


def _print_plot_geomeans(plot_df, metric):
    """Print a geometric mean for every displayed configuration."""
    print(f"\n--- Geomean {metric} Performance ---")
    for config in plot_df.columns:
        values = plot_df[config].dropna()
        values = values[values > 0]
        if values.empty:
            print(f"{config:22}: N/A")
        else:
            print(f"{config:22}: {format_metric(gmean(values), metric)}")


def _add_ideal_ipc_lines(ax, plot_df, ideal_models):
    """
    Add per-bar ideal IPC markers using the model assigned to each config.

    Optional ideal-model fields:
        ipc_type: ``'scalar'`` or ``'superscalar'``. Defaults to ``'scalar'``.
        line_color: marker color
        ideal_label: legend label
    """
    for container, config in zip(ax.containers, plot_df.columns):
        ideal_model = ideal_models.get(config)
        if ideal_model is None:
            continue

        ipc_type = ideal_model.get('ipc_type', 'scalar')
        if ipc_type not in {'scalar', 'superscalar'}:
            raise ValueError(
                f"Unsupported IPC type {ipc_type!r} for configuration {config!r}"
            )

        theoretical_data = model.theoretical_metrics(
            cfg=ideal_model['cfg'],
            pipe_width=ideal_model.get('pipe_width'),
        )['ipc'][ipc_type]

        line_color = ideal_model.get('line_color', 'tab:red')
        ideal_label = ideal_model.get('ideal_label', 'Ideal IPC')
        label_used = False

        for bar, app in zip(container, plot_df.index):
            ideal = theoretical_data.get(app)
            if ideal is None or np.isnan(bar.get_height()):
                continue

            ax.plot(
                [bar.get_x(), bar.get_x() + bar.get_width()],
                [ideal, ideal],
                color=line_color,
                linewidth=2.2,
                zorder=5,
                label=ideal_label if not label_used else None,
            )
            label_used = True


def _finish_bar_plot(
    fig,
    ax,
    plot_df,
    metric,
    filename,
    show,
):
    """Apply common formatting, save the plot, and print geomeans."""
    ax.axhline(y=1, color='black', linewidth=0.8, zorder=2.5)
    ax.set_ylabel(METRIC_LABELS.get(metric, metric.upper()))
    ax.set_xlabel('')

    clean_labels = [
        APP_LABELS.get(app, app.replace('xoshiro128p', 'xoshiro'))
        for app in plot_df.index
    ]
    ax.set_xticklabels(clean_labels, rotation=15, ha='right')

    ax.legend(
        loc='upper right',
        ncol=2,
        columnspacing=1.0,
        handletextpad=0.5,
    )
    ax.grid(True, axis='y', color='gray', linewidth=0.5, alpha=1.0)

    if metric == 'ipc':
        measured_max = plot_df.max().max()
        ax.set_ylim(bottom=0, top=max(measured_max * 1.15, 8.5))
    elif metric == 'fpu_util':
        ax.set_ylim(bottom=0, top=1.3)

    fig.tight_layout()
    fig.savefig(filename, dpi=300, bbox_inches='tight')
    _print_plot_geomeans(plot_df, metric)

    if show:
        plt.show()
    else:
        plt.close(fig)



def _apply_schnizo_gpl_axpy_override(plot_df, metric):
    """Insert a manual Schnizo GP-L AXPY value."""
    if 'Schnizo Superscalar' not in plot_df.columns:
        return plot_df
    axpy_key = next((app for app in ('sz_axpy', 'axpy') if app in plot_df.index), None)
    if axpy_key is None:
        return plot_df
    value = SCHNIZO_GPL_AXPY_IPC if metric == 'ipc' else SCHNIZO_GPL_AXPY_FPU_UTIL
    plot_df.loc[axpy_key, 'Schnizo Superscalar'] = value
    return plot_df


def _style_metric_axis(ax, plot_df, metric, show_xlabels):
    """Apply shared subplot formatting without saving or printing."""
    ax.axhline(y=1, color='black', linewidth=0.8, zorder=2.5)
    ax.set_ylabel(METRIC_LABELS.get(metric, metric.upper()))
    ax.set_xlabel('')
    ax.grid(True, axis='y', color='gray', linewidth=0.5, alpha=1.0)
    clean_labels = [APP_LABELS.get(app, app.replace('xoshiro128p', 'xoshiro')) for app in plot_df.index]
    if show_xlabels:
        ax.set_xticklabels(clean_labels, rotation=15, ha='right')
    else:
        ax.tick_params(axis='x', which='both', labelbottom=False)
    if metric == 'ipc':
        measured_max = plot_df.max().max()
        ax.set_ylim(bottom=0, top=max(measured_max * 1.15, 8.5))
    elif metric == 'fpu_util':
        ax.set_ylim(bottom=0, top=1.3)


def _plot_metric_bars(ax, plot_df, color_pairs, metric, ideal_models=None, show_xlabels=True):
    """Draw one metric panel using light bars and dark ideal markers."""
    bar_colors = [color_pairs[config]['bar'] for config in plot_df.columns]
    plot_df.plot(kind='bar', ax=ax, zorder=3, width=0.85, color=bar_colors,
                 edgecolor='black', linewidth=0.35, legend=True)
    if metric == 'ipc' and ideal_models:
        _add_ideal_ipc_lines(ax, plot_df, ideal_models)
    _style_metric_axis(ax, plot_df, metric, show_xlabels=show_xlabels)


def _subplot_legend(ax, include_ideal=False):
    """
    Add a compact two-column legend to one subplot.

    The FPU-utilization panel contains only measured configurations.
    The IPC panel also contains the ideal-IPC marker entries.
    """
    handles, labels = ax.get_legend_handles_labels()

    unique_handles = []
    unique_labels = []
    for handle, label in zip(handles, labels):
        if not label or label in unique_labels:
            continue
        if not include_ideal and label.startswith('Ideal '):
            continue
        unique_handles.append(handle)
        unique_labels.append(label)

    if unique_handles:
        ax.legend(
            unique_handles,
            unique_labels,
            loc='upper right',
            ncol=4,
            columnspacing=1.0,
            handletextpad=0.5,
        )


def architecture_comparison_combined_plot(df, show=True, filename='architecture_comparison_combined.png'):
    """Plot FPU utilization above IPC for the architecture comparison."""
    schnizo_mask = df['hw'].eq(SCHNIZO_HW)
    schnova_fw8_mask = df['hw'].eq('GP-PW8') & df['mode'].eq('superscalar')
    schnova_zol_mask = df['hw'].eq(SCHNOVA_ZOL_HW)
    plot_data = df[schnizo_mask | schnova_fw8_mask | schnova_zol_mask].copy()

    def identify_config(row):
        if row['hw'] == SCHNOVA_ZOL_HW:
            return 'Schnova Scalar'
        if row['hw'] == SCHNIZO_HW:
            return 'Schnizo Superscalar'
        return 'Schnova Superscalar'

    plot_data['config'] = plot_data.apply(identify_config, axis=1)
    ordered_cols = ['Schnova Scalar', 'Schnova Superscalar', 'Schnizo Superscalar']
    fpu_df = _largest_size_pivot(plot_data, 'fpu_util')
    ipc_df = _largest_size_pivot(plot_data, 'ipc')
    fpu_df = fpu_df[[c for c in ordered_cols if c in fpu_df.columns]]
    ipc_df = ipc_df[[c for c in ordered_cols if c in ipc_df.columns]]
    common_apps = ipc_df.index.intersection(fpu_df.index, sort=False)
    ipc_df = ipc_df.reindex(common_apps)
    fpu_df = fpu_df.reindex(common_apps)
    fpu_df = _apply_schnizo_gpl_axpy_override(fpu_df, 'fpu_util')
    ipc_df = _apply_schnizo_gpl_axpy_override(ipc_df, 'ipc')

    color_pairs = {
        'Schnova Scalar': {'bar': '#a8ddb5', 'line': '#006d2c'},
        'Schnova Superscalar': {'bar': '#9ecae1', 'line': '#08519c'},
        'Schnizo Superscalar': {'bar': '#fdd0a2', 'line': '#a63603'},
    }

    ideal_models = {
        'Schnizo Superscalar': {'cfg': model.SCHNOVA_XL, 'pipe_width': None, 'ipc_type': 'superscalar',
                         'line_color': color_pairs['Schnizo Superscalar']['line'], 'ideal_label': 'Ideal IPC Schnizo'},
        'Schnova Superscalar': {'cfg': model.SCHNOVA_XL, 'pipe_width': 8, 'ipc_type': 'superscalar',
                                'line_color': color_pairs['Schnova Superscalar']['line'], 'ideal_label': 'Ideal IPC Schnova'},
    }
    fig, (ax_fpu, ax_ipc) = plt.subplots(2, 1, figsize=(14, 10), sharex=True, gridspec_kw={'hspace': 0.08})
    _plot_metric_bars(ax_fpu, fpu_df, color_pairs, 'fpu_util', show_xlabels=False)
    _plot_metric_bars(ax_ipc, ipc_df, color_pairs, 'ipc', ideal_models=ideal_models, show_xlabels=True)
    _subplot_legend(ax_fpu, include_ideal=False)
    _subplot_legend(ax_ipc, include_ideal=True)
    fig.tight_layout()
    fig.savefig(filename, dpi=300, bbox_inches='tight')
    _print_plot_geomeans(fpu_df, 'fpu_util')
    _print_plot_geomeans(ipc_df, 'ipc')
    if show:
        plt.show()
    else:
        plt.close(fig)
    return {'fpu_util': fpu_df, 'ipc': ipc_df}


def fetch_width_comparison_combined_plot(df, show=True, filename='fetch_width_comparison_combined.png'):
    """Plot FPU utilization above IPC for the fetch-width comparison."""
    plot_data = df[df['hw'].isin(SCHNOVA_PIPELINE_CONFIGS) & df['mode'].eq('superscalar')].copy()
    plot_data['config'] = plot_data['hw'].map({hw: p['label'] for hw, p in SCHNOVA_PIPELINE_CONFIGS.items()})
    ordered_cols = ['Schnova FW1', 'Schnova FW2', 'Schnova FW4', 'Schnova FW8']
    fpu_df = _largest_size_pivot(plot_data, 'fpu_util')
    ipc_df = _largest_size_pivot(plot_data, 'ipc')
    fpu_df = fpu_df[[c for c in ordered_cols if c in fpu_df.columns]]
    ipc_df = ipc_df[[c for c in ordered_cols if c in ipc_df.columns]]
    common_apps = ipc_df.index.intersection(fpu_df.index, sort=False)
    ipc_df = ipc_df.reindex(common_apps)
    fpu_df = fpu_df.reindex(common_apps)
    color_pairs = {
        'Schnova FW1': {'bar': '#a8ddb5', 'line': '#006d2c'},
        'Schnova FW2': {'bar': '#9ecae1', 'line': '#08519c'},
        'Schnova FW4': {'bar': '#fdd0a2', 'line': '#a63603'},
        'Schnova FW8': {'bar': '#dadaeb', 'line': '#54278f'},
    }
    ideal_models = {
        p['label']: {'cfg': p['cfg'], 'pipe_width': p['pipe_width'],
                     'ipc_type': 'superscalar' if p['pipe_width'] in {4, 8} else 'scalar',
                     'line_color': color_pairs[p['label']]['line'],
                     'ideal_label': f"Ideal IPC {p['label'].split()[-1]}"}
        for p in SCHNOVA_PIPELINE_CONFIGS.values()
    }
    fig, (ax_fpu, ax_ipc) = plt.subplots(2, 1, figsize=(14, 10), sharex=True, gridspec_kw={'hspace': 0.08})
    _plot_metric_bars(ax_fpu, fpu_df, color_pairs, 'fpu_util', show_xlabels=False)
    _plot_metric_bars(ax_ipc, ipc_df, color_pairs, 'ipc', ideal_models=ideal_models, show_xlabels=True)
    _subplot_legend(ax_fpu, include_ideal=False)
    _subplot_legend(ax_ipc, include_ideal=True)
    fig.tight_layout()
    fig.savefig(filename, dpi=300, bbox_inches='tight')
    _print_plot_geomeans(fpu_df, 'fpu_util')
    _print_plot_geomeans(ipc_df, 'ipc')
    if show:
        plt.show()
    else:
        plt.close(fig)
    return {'fpu_util': fpu_df, 'ipc': ipc_df}


def architecture_comparison_plot(
    df,
    metric='ipc',
    show=True,
    filename='architecture_comparison.png',
):
    """
    Compare Schnova ZOL, Schnizo scalar/superscalar, and Schnova PW8.

    Ideal IPC markers are shown for the superscalar configurations. Schnova
    PW8 uses SCHNOVA_XL with an explicit pipeline width of eight.
    """
    schnizo_mask = df['hw'].eq(SCHNIZO_HW)
    schnova_pw8_mask = df['hw'].eq('GP-PW8') & df['mode'].eq('superscalar')
    schnova_zol_mask = df['hw'].eq(SCHNOVA_ZOL_HW)

    plot_data = df[
        schnizo_mask | schnova_pw8_mask | schnova_zol_mask
    ].copy()

    def identify_config(row):
        if row['hw'] == SCHNOVA_ZOL_HW:
            return 'Schnova Scalar'
        if row['hw'] == SCHNIZO_HW:
            return 'Schnizo Superscalar'
        return 'Schnova Superscalar'

    plot_data['config'] = plot_data.apply(identify_config, axis=1)
    plot_df = _largest_size_pivot(plot_data, metric)

    ordered_cols = [
        'Schnova Scalar',
        'Schnova Superscalar',
        'Schnizo Superscalar',
    ]
    plot_df = plot_df[[c for c in ordered_cols if c in plot_df.columns]]

    # Match the fetch-width plot style: light measured bars and darker
    # ideal-IPC markers from the same color family.
    color_pairs = {
        # Use the same first three color pairs as the fetch-width plot.
        'Schnova Scalar': {
            'bar': '#a8ddb5',
            'line': '#006d2c',
        },
        'Schnova Superscalar': {
            'bar': '#9ecae1',
            'line': '#08519c',
        },
        'Schnizo Superscalar': {
            'bar': '#fdd0a2',
            'line': '#a63603',
        },
    }

    bar_colors = [
        color_pairs[config]['bar']
        for config in plot_df.columns
    ]

    fig, ax = plt.subplots(figsize=(14, 7))
    plot_df.plot(
        kind='bar',
        ax=ax,
        zorder=3,
        width=0.85,
        color=bar_colors,
        edgecolor='black',
        linewidth=0.35,
    )

    if metric == 'ipc':
        _add_ideal_ipc_lines(
            ax,
            plot_df,
            {
                'Schnizo Superscalar': {
                    'cfg': model.SCHNOVA_XL,
                    'pipe_width': None,
                    'ipc_type': 'superscalar',
                    'line_color': color_pairs['Schnizo Superscalar']['line'],
                    'ideal_label': 'Ideal IPC Schnizo',
                },
                'Schnova Superscalar': {
                    'cfg': model.SCHNOVA_XL,
                    'pipe_width': 8,
                    'ipc_type': 'superscalar',
                    'line_color': color_pairs['Schnova Superscalar']['line'],
                    'ideal_label': 'Ideal IPC Schnova',
                },
            },
        )

    _finish_bar_plot(
        fig,
        ax,
        plot_df,
        metric,
        filename,
        show,
    )
    return plot_df


def fetch_width_comparison_plot(
    df,
    metric='ipc',
    show=True,
    filename='fetch_width_comparison.png',
):
    """Compare Schnova FW1, FW2, FW4, and FW8."""
    plot_data = df[
        df['hw'].isin(SCHNOVA_PIPELINE_CONFIGS)
        & df['mode'].eq('superscalar')
    ].copy()

    plot_data['config'] = plot_data['hw'].map(
        {
            hw: properties['label']
            for hw, properties in SCHNOVA_PIPELINE_CONFIGS.items()
        }
    )

    plot_df = _largest_size_pivot(plot_data, metric)
    ordered_cols = [
        'Schnova FW1',
        'Schnova FW2',
        'Schnova FW4',
        'Schnova FW8',
    ]
    plot_df = plot_df[[c for c in ordered_cols if c in plot_df.columns]]

    color_pairs = {
        'Schnova FW1': {'bar': '#a8ddb5', 'line': '#006d2c'},
        'Schnova FW2': {'bar': '#9ecae1', 'line': '#08519c'},
        'Schnova FW4': {'bar': '#fdd0a2', 'line': '#a63603'},
        'Schnova FW8': {'bar': '#dadaeb', 'line': '#54278f'},
    }

    bar_colors = [
        color_pairs[config]['bar']
        for config in plot_df.columns
    ]

    fig, ax = plt.subplots(figsize=(14, 7))
    plot_df.plot(
        kind='bar',
        ax=ax,
        zorder=3,
        width=0.85,
        color=bar_colors,
        edgecolor='black',
        linewidth=0.35,
    )

    if metric == 'ipc':
        ideal_models = {
            properties['label']: {
                'cfg': properties['cfg'],
                'pipe_width': properties['pipe_width'],
                # FW1 and FW2 use unrolled kernels and therefore use the
                # scalar instruction counts. FW4 and FW8 remain superscalar.
                'ipc_type': (
                    'superscalar'
                    if properties['pipe_width'] in {4, 8}
                    else 'scalar'
                ),
                'line_color': color_pairs[properties['label']]['line'],
                'ideal_label': f"Ideal {properties['label'].split()[-1]}",
            }
            for properties in SCHNOVA_PIPELINE_CONFIGS.values()
        }
        _add_ideal_ipc_lines(ax, plot_df, ideal_models)

    _finish_bar_plot(
        fig,
        ax,
        plot_df,
        metric,
        filename,
        show,
    )
    return plot_df


def pipeline_width_comparison_plot(
    df,
    metric='ipc',
    show=True,
    filename='fetch_width_comparison.png',
):
    """Backward-compatible alias."""
    return fetch_width_comparison_plot(
        df,
        metric=metric,
        show=show,
        filename=filename,
    )


def superscalar_comparison_plot(df, metric='fpu_util', show=True):
    """Backward-compatible alias for the focused architecture comparison."""
    return architecture_comparison_plot(
        df,
        metric=metric,
        show=show,
        filename=f'architecture_comparison_{metric}.png',
    )

def print_all_geomeans(df, metric='fpu_util'):
    """
    Dynamically groups by ALL hardware configurations and modes present in the
    dataframe, calculates the geometric mean across applications, and prints them.
    """
    print(f"--- Geometric Mean for {metric.upper()} (All Present Configs) ---")

    # 1. Filter out rows where the metric or size might be missing
    clean_df = df.dropna(subset=[metric, 'size']).copy()

    # 2. Get the max size per application for every unique (hw, mode) combination
    #    This mirrors your logic of looking at the largest problem size run.
    idx_max_size = clean_df.groupby(['app', 'hw', 'mode'])['size'].idxmax()
    reduced_df = clean_df.loc[idx_max_size]

    # 3. Group by the configurations themselves to calculate the geomean across apps
    config_groups = reduced_df.groupby(['hw', 'mode'])

    for (hw, mode), group in config_groups:
        # Extract the series of metrics across all applications for this config
        values = group[metric]

        if not values.empty:
            gm_value = gmean(values)

            # Label string combining both the hardware name and its mode
            config_label = f"HW: {hw} ({mode})"

            # Format output based on the metric type
            if metric == 'ipc':
                print(f"{config_label:50}: {gm_value:.2f}")
            elif metric == 'fpu_util':
                print(f"{config_label:50}: {gm_value:.2%}")
            else:
                print(f"{config_label:50}: {gm_value:.4f}")


def geomean_plot(df, width=3, vary_by="slots", metric="ipc", show=True):
    """
    Plot geomean of `metric` for configurations with fixed pipeline width
    while varying one hardware parameter.

    Supported vary_by values:
        - "slots"       -> number of issue slots (same for ALU/LSU/FPU)
        - "phys_regs"   -> number of physical registers
        - "rob_entries" -> number of ROB entries

    Expected config format:
        sv_width_nofAlusxnofAluSlots_nofLsusxnofLsuSlots_nofFpusxnofFpuSlots_NofPhysRegs_NofRobEntries

    Example:
        sv_3_3x4_3x4_1x4_128_64
    """

    def extract_config_value(hw_name):
        """
        Parse configuration string and return the selected value to vary.

        Returns None if:
        - format does not match
        - pipeline width does not match
        - unsupported FU structure
        - for vary_by='slots', slot counts are not identical
        """

        pattern = r"^sv_(\d+)_(\d+)x(\d+)_(\d+)x(\d+)_(\d+)x(\d+)_(\d+)_(\d+)_(\d+)_(\d+)_(\d+)_(\d+)$"  # noqa: E501
        match = re.match(pattern, hw_name)

        if not match:
            return None

        (
            parsed_width,
            nof_alus,
            alu_slots,
            nof_lsus,
            lsu_slots,
            nof_fpus,
            fpu_slots,
            alu_buf_slots,
            lsu_buf_slots,
            fpu_buf_slots,
            gpr,
            fpr,
            rob_entries,
        ) = map(int, match.groups())

        # Keep only requested pipeline width
        if parsed_width != width:
            return None

        # Keep only expected FU structure

        if vary_by == "alu_slots":
            return alu_slots
        elif vary_by == "lsu_slots":
            return lsu_slots
        elif vary_by == "fpu_slots":
            return fpu_slots
        elif vary_by == "alus":
            return nof_alus
        elif vary_by == "lsus":
            return nof_lsus
        elif vary_by == "fpus":
            return nof_fpus
        elif vary_by == "alu_buf_slots":
            return alu_buf_slots
        elif vary_by == "lsu_buf_slots":
            return lsu_buf_slots
        elif vary_by == "fpu_buf_slots":
            return fpu_buf_slots
        elif vary_by == "gpr":
            return gpr
        elif vary_by == "fpr":
            return fpr
        elif vary_by == "rob_entries":
            return rob_entries
        return None

    xlabel_map = {
        "alus": "Number of ALUs",
        "lsus": "Number of LSUs",
        "fpus": "Number of FPUs",
        "alu_slots": "Number of ALU Slots",
        "lsu_slots": "Number of LSU Slots",
        "fpu_slots": "Number of FPU Slots",
        "alu_buf_slots": "Number of ALU dispatch buffer slots",
        "lsu_buf_slots": "Number of LSU dispatch buffer slots",
        "fpu_buf_slots": "Number of FPU dispatch buffer slots",
        "gpr": "Number of Physical General Purpose Registers",
        "fpr": "Number of Physical General Floating Point Registers",
        "rob_entries": "Number of ROB Entries",
    }

    plot_df = df[df["mode"] == "superscalar"].copy()

    plot_df[vary_by] = plot_df["hw"].apply(extract_config_value)
    plot_df = plot_df[plot_df[vary_by].notna()].copy()

    if plot_df.empty:
        print(
            f"No matching configurations found for width={width}, vary_by={vary_by}"
        )
        return None

    plot_df[vary_by] = plot_df[vary_by].astype(int)

    # Keep only largest input size per app/config
    idx_max_size = plot_df.groupby(["app", "hw"])["size"].idxmax()
    plot_df = plot_df.loc[idx_max_size].copy()

    geomean_data = {}

    for value in sorted(plot_df[vary_by].unique()):
        vals = plot_df.loc[
            plot_df[vary_by] == value, metric
        ].dropna()

        if len(vals) > 0:
            geomean_data[value] = gmean(vals)

    if not geomean_data:
        print("No valid values found for geomean calculation.")
        return None

    fig, ax = plt.subplots(figsize=(10, 6))

    x = list(geomean_data.keys())
    y = list(geomean_data.values())

    ax.plot(
        x,
        y,
        marker="o",
        linewidth=2,
        color="black",
        linestyle="--",
    )

    ax.set_xlabel(xlabel_map[vary_by])
    ax.set_ylabel(METRIC_LABELS.get(metric, metric.upper()))

    ax.grid(True, axis="both", alpha=0.4)
    ax.set_xticks(x)

    # Y limits
    if len(y) > 1:
        ax.set_ylim(
            bottom=min(y) * 0.85,
            top=max(y) * 1.15,
        )

    fig.tight_layout()

    print(
        f"\n--- Geomean {metric} for Width={width}, varying {vary_by} ---"
    )
    for value, gm in geomean_data.items():
        print(
            f"{format_metric(gm, metric)}"
        )

    if show:
        plt.show()

    return geomean_data


def print_geomean_ipc(cfg_name, cfg_data, use_unrolling=False, app_filter=None, width=None):
    """
    Calculates and prints the geomean of IPC for a given config,
    followed by the individual Ideal IPC for each app.
    """
    # 1. Fetch base superscalar metrics
    metrics = model.theoretical_metrics(cfg=cfg_data, pipe_width=width)
    ipc_map = metrics['ipc']['superscalar'].copy()

    # 2. Swap 'sz_axpy' if unrolled/scalar value is requested
    if use_unrolling:
        for app in ['sz_axpy', 'add', 'mul', 'div', 'neg']:
            insns = model.BENCHMARK_INSNS['scalar'][app]
            ipc = model.ideal_ipc(insns, cfg_data, pipe_width=width)
            ipc_map[app] = ipc

    # 3. Apply App Filter
    if app_filter is not None:
        ipc_map = {app: ipc for app, ipc in ipc_map.items() if app in app_filter}

    # 4. Calculate Geomean
    ipc_values = list(ipc_map.values())

    if ipc_values:
        avg_ipc = gmean(ipc_values)

        status = "(Axpy Unrolled/Scalar)" if use_unrolling else "(Default)"
        filter_status = f" | Filter: {', '.join(app_filter)}" if app_filter else ""

        print(f"--- Geomean Analysis: {cfg_name} {status}{filter_status} ---")
        print(f"Geomean IPC: {avg_ipc:.4f}")
        print("-" * 40)

        # 5. Print individual Ideal IPCs
        print(f"{'App Name':<20} | {'Ideal IPC':<10}")
        print("-" * 33)
        for app, ipc in ipc_map.items():
            print(f"{app:<20} | {ipc:<10.4f}")
        print("-" * 40 + "\n")

    else:
        print(f"No IPC data found for {cfg_name} with the provided filter.\n")


def balanced_comparison_plot(df, metric='fpu_util', show=True):
    """ Compare Normal Software vs. Balanced Instruction Mix Software """

    # Copy data to avoid modifying the original dataframe
    plot_df = df.copy()

    # Identify whether the app name represents the balanced version
    plot_df['is_bal'] = plot_df['app'].str.endswith('_bal')

    # Strip the '_bal' suffix to get the common base app name for grouping
    plot_df['base_app'] = plot_df.apply(
        lambda row: row['app'][:-4] if row['is_bal'] else row['app'], axis=1
    )

    # Map the suffix flag to clean display categories
    plot_df['config'] = plot_df['is_bal'].map({True: 'Balanced', False: 'Normal'})

    # Find the row with the largest problem size for each base app group
    idx_max_size = plot_df.groupby(['base_app', 'config'])['size'].idxmax()
    plot_df = plot_df.loc[idx_max_size].pivot(index='base_app', columns='config', values=metric)

    # Order the columns so 'Normal' always plots before 'Balanced'
    ordered_cols = ['Normal', 'Balanced']
    plot_df = plot_df[[c for c in ordered_cols if c in plot_df.columns]]

    # Initialize the plot layout (reduced bar width to 0.6 since we only have 2 bars per app)
    fig, ax = plt.subplots(figsize=(14, 7))
    plot_df.plot(kind='bar', ax=ax, zorder=3, width=0.6)

    # --- Optional: Ideal IPC Lines ---
    # Since you now have a single cfg, if you still want to overlay ideal IPC metrics,
    # you can uncomment this block and replace 'your_cfg_name' with your actual hardware config.
    if metric == 'ipc':
        labeled = False
        theoretical_data = model.theoretical_metrics(cfg=model.SCHNOVA_XL)['ipc']['superscalar']

        for i, col_name in enumerate(plot_df.columns):
            container = ax.containers[i]
            for bar, base_app in zip(container, plot_df.index):
                # Ensure you map to the correct key name expected by your model
                if base_app in theoretical_data:
                    ideal = theoretical_data[base_app]
                    ax.plot([bar.get_x(), bar.get_x() + bar.get_width()],
                            [ideal, ideal],
                            color='tab:red', linewidth=2.0, zorder=5,
                            label='Ideal IPC' if not labeled else '')
                    labeled = True

    # Apply the styling parameters matching your original configuration
    ax.axhline(y=1, color='black', linewidth=0.8, zorder=2.5)
    ax.set_ylabel(METRIC_LABELS.get(metric, metric.upper()))
    ax.set_xlabel('')

    # Clean up and rotate the base app labels for the x-axis
    clean_labels = [app.replace('xoshiro128p', 'xoshiro') for app in plot_df.index]
    ax.set_xticklabels(clean_labels, rotation=15, ha='right')

    ax.legend(title="Software Version", loc='upper left', bbox_to_anchor=(1, 1))
    ax.grid(True, axis='y', color='gray', linewidth=0.5, alpha=1.0)

    # Set appropriate y-axis boundaries based on the selected metric
    if metric == 'ipc':
        ax.set_ylim(bottom=0, top=max(plot_df.max().max() * 1.15, 8.5))
    elif metric == 'fpu_util':
        ax.set_ylim(bottom=0, top=1.3)

    fig.tight_layout()

    # Print the Geometric Mean performance summary
    print(f"\n--- Geomean {metric} Performance ---")
    for col in plot_df.columns:
        gm = gmean(plot_df[col].dropna())
        print(f"{col:18}: {format_metric(gm, metric)}")

    if show:
        plt.show()

    return plot_df


def plot1(show=True, dir=None):
    """Backward-compatible architecture comparison entry point."""
    df = experiments.results(dir=dir)
    return architecture_comparison_combined_plot(df, show=show, filename='architecture_comparison_combined.png')


def plot2(show=True, dir=None):
    """Combined architecture FPU-utilization and IPC comparison."""
    df = experiments.results(dir=dir)
    return architecture_comparison_combined_plot(df, show=show, filename='architecture_comparison_combined.png')


def plot7(show=True, dir=None):
    """Combined fetch-width FPU-utilization and IPC comparison."""
    df = experiments.results(dir=dir)
    return fetch_width_comparison_combined_plot(df, show=show, filename='fetch_width_comparison_combined.png')


def plot8(show=True, dir=None):
    """Backward-compatible fetch-width comparison entry point."""
    df = experiments.results(dir=dir)
    return fetch_width_comparison_combined_plot(df, show=show, filename='fetch_width_comparison_combined.png')


def plot3(show=True, dir=None, width=1, vary_by='slots', use_rob=False, use_bal=False, spec=False, metric='ipc'):
    if width == 1:
        df = pw1_experiments.results(vary_by=vary_by, use_rob=use_rob, use_bal=use_bal, spec=spec, dir=dir)
    elif width == 2:
        df = pw2_experiments.results(vary_by=vary_by, use_rob=use_rob, use_bal=use_bal, spec=spec, dir=dir)
    elif width == 4:
        df = pw4_experiments.results(vary_by=vary_by, use_rob=use_rob, use_bal=use_bal, spec=spec, dir=dir)
    if width == 8:
        df = pw8_experiments.results(vary_by=vary_by, use_rob=use_rob, use_bal=use_bal, spec=spec, dir=dir)
    return geomean_plot(df, width, vary_by, metric, show)


def plot4(width=1):
    if width == 1:
        print_geomean_ipc("Schnova SV1", model.SCHNOVA_S, True, None, width)
    elif width == 2:
        print_geomean_ipc("Schnova SV2", model.SCHNOVA_M, True, None, width)
    elif width == 4:
        print_geomean_ipc("Schnova SV4", model.SCHNOVA_XL, False, None, width)
    elif width == 8:
        print_geomean_ipc("Schnova SV8", model.SCHNOVA_XL, False, None, width)


def plot5(show=True, dir=None):
    df = experiments.results(dir=dir)
    return balanced_comparison_plot(df, 'ipc', show=show)


def plot6(dir=None):
    df = experiments.results(dir=dir)
    print_all_geomeans(df, 'ipc')


def main():
    """Load results from CSV and generate plots"""

    plots = [plot1, plot2, plot3, plot4, plot5, plot6, plot7, plot8]
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

    parser.add_argument(
        "--width",
        type=int,
        default=1,
        help="Pipeline width for plot3 (default: 1)"
    )

    parser.add_argument(
        "--use_rob",
        action="store_true",  # Sets to True if present, False if absent
        help="Use a ROB instead of reference counting for the register size experiments."
    )
    
    parser.add_argument(
        "--use_bal",
        action="store_true",  # Sets to True if present, False if absent
        help="Use a balanced instruction mix for the software kernels."
    )

    parser.add_argument(
        "--spec",
        action="store_true",  # Sets to True if present, False if absent
        help="Wether the specialized configuration should be evaluated."
    )

    parser.add_argument(
        "--vary",
        choices=["alus",
                 "lsus",
                 "fpus",
                 "alu_slots",
                 "lsu_slots",
                 "fpu_slots",
                 "alu_buf_slots",
                 "lsu_buf_slots",
                 "fpu_buf_slots",
                 "gpr",
                 "fpr",
                 "rob_entries"],
        default="slots",
        help="Hardware parameter to vary for plot3 "
             "(default: slots)"
    )

    parser.add_argument(
        "--metric",
        type=str,
        choices=["ipc", "fpu_util"],
        default="ipc",
        help="Metric to plot for plot3 (default: ipc)"
    )

    args = parser.parse_args()

    # Generate selected plots
    for name in args.plots:
        if name == "plot3":
            _ = plot_dict[name](
                width=args.width,
                vary_by=args.vary,
                use_rob=args.use_rob,
                use_bal=args.use_bal,
                spec=args.spec,
                metric=args.metric,
            )
        elif name == "plot4":
            _ = plot_dict[name](
                width=args.width,
            )
        else:
            _ = plot_dict[name]()


if __name__ == '__main__':
    main()