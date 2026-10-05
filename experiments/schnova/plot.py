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
from pathlib import Path
import re

import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch
from matplotlib.transforms import Bbox, TransformedBbox
import numpy as np
import pandas as pd
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
AREA_EFFICIENCY_ISSUE_WIDTHS = {'Snitch': 1, 'CVA6S+': 2, 'C910': 3}


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


# Area breakdown of the dual-issue core vs. the baseline integer core. Kept (grouped)
# instances are matched on the suffix of their cell name and assigned to a
# breakdown component. Nested instances are subtracted from their parents, so every
# component only accounts for its own logic (e.g. the FU stage is reported without the FUs
# and reservation stations it contains). All remaining logic, including the glue of the
# synthesis wrapper, is attributed to "Rest".
AREA_BREAKDOWN_BASELINE = 'Schnova-ZOL'
AREA_BREAKDOWN_DESIGN = 'GP-PW2'
AREA_BREAKDOWN_INSTANCES = {
    'IF': ['i_frontend'],
    'ID': ['i_decoder'],
    'Dispatch': ['i_dispatcher'],
    'RMT': ['i_rename'],
    'Reg. manager': ['i_refcount'],
    'RF': ['i_int_phy_regfile', 'i_fp_phy_regfile'],
    'Read operands': ['i_read_operands'],
    'Issue queues': ['alu_disp_buffer', 'lsu_disp_buffer', 'fpu_disp_buffer', 'i_res_stat'],
    'FU stage glue': ['i_fu_stage'],
    'FUs': ['i_alu', 'i_lsu', 'i_fpu'],
}
AREA_BREAKDOWN_ORDER = [*AREA_BREAKDOWN_INSTANCES, 'Rest']

# Components shown in the area breakdown bar, from bottom to top, with the breakdown
# components merged into each of them. Everything not listed here is merged into "Rest".
AREA_BAR_COMPONENTS = {
    'RF': ['RF'],
    'FUs': ['FUs'],
    'RMT': ['RMT'],
    'Reference counters': ['Reg. manager'],
    'Issue queues': ['Issue queues'],
    'Rest': ['IF', 'ID', 'Dispatch', 'Read operands', 'FU stage glue', 'Rest'],
}
# The part of each component already present in the baseline core and the increment of the
# dual-issue design are distinguished by their fill color
AREA_BAR_BASELINE_COLOR = '#d7eef4'
AREA_BAR_INCREMENT_COLOR = '#fff6d5'
# The border of a component follows the fill: each part is outlined in its own color
AREA_BAR_BASELINE_EDGE_COLOR = '#22697b'
AREA_BAR_INCREMENT_EDGE_COLOR = '#b18b00'
# Gap between neighboring components, as a fraction of the total bar length
AREA_BAR_GAP = 0.012


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


def _area_breakdown(synth_df, name, stage=core_area_experiments.FINAL_SYNTH_STAGE):
    """Return the area [kGE] of each component in AREA_BREAKDOWN_ORDER for one design.

    The areas come from the hierarchy report of a "grouped" synthesis run.
    """
    if name not in synth_df.index:
        raise ValueError(f'No grouped synthesis results for {name}')
    results = synth_df.loc[name, 'synth_results']
    # The stage is missing (NaN) if the synthesis run did not reach it yet
    if not isinstance(results, dict):
        raise ValueError(f'No results for synthesis stage {stage} of {name} (not finished '
                         f'yet?). Use an earlier stage to preview, e.g. '
                         f'"make AREA_BREAKDOWN_STAGE={core_area_experiments.EARLY_SYNTH_STAGE}".')
    if 'hierarchy_details' not in results:
        raise ValueError(f'No hierarchy report for synthesis stage {stage} of {name}')
    tree = results['hierarchy_details'].tree
    # The core itself is not kept as a separate module, so its own logic ("Rest") is
    # flattened into the root of the hierarchy, which is the scope of the breakdown
    core = tree.root

    # Map the kept instances in the core's subtree to their breakdown component
    # Generate block names are flattened into the cell name (e.g. gen_alus_0__i_alu), so
    # match instances on the name suffix
    instance_to_component = {inst: comp for comp, insts in AREA_BREAKDOWN_INSTANCES.items()
                             for inst in insts}
    component_of = {}
    for node in core.descendants:
        leaf_name = node.node_name
        for inst, comp in instance_to_component.items():
            if leaf_name == inst or leaf_name.endswith(f'_{inst}'):
                component_of[node] = comp

    # Node areas are hierarchical totals: subtract the nearest kept descendants to get the
    # area of the node's own logic
    def total(node):
        return node.StdCellArea / GE / 1000

    def nearest_kept_descendants(node):
        found = []
        for child in node.children:
            if child in component_of:
                found.append(child)
            else:
                found.extend(nearest_kept_descendants(child))
        return found

    breakdown = dict.fromkeys(AREA_BREAKDOWN_ORDER, 0.0)
    for node, comp in component_of.items():
        breakdown[comp] += total(node) - sum(total(n) for n in nearest_kept_descendants(node))
    breakdown['Rest'] = total(core) - sum(total(n) for n in nearest_kept_descendants(core))
    return pd.Series(breakdown, name=name)


def _round_outlines(fig, ax, outlines, radius_in=0.015):
    """Round the corners of rectangles drawn in data coordinates.

    The radius is given in inches, so that the corners are circular even though the x and y
    data scales differ. It must be called once the layout of the figure is final.
    """
    fig.canvas.draw()
    origin = ax.transData.transform((0, 0))
    unit = ax.transData.transform((1, 1)) - origin  # pixels per data unit
    for outline in outlines:
        outline.set_boxstyle('round', pad=0, rounding_size=radius_in * fig.dpi / unit[0])
        outline.set_mutation_aspect(unit[0] / unit[1])


def _draw_leaders(fig, ax, labels, centers, top, color='#bdbdbd', linewidth=0.6, gap_pts=2):
    """Connect each label to the component it refers to with a thin line.

    The lines go from the center of the label's baseline to the top of the component (``top``),
    horizontally centered on it. Both ends are ``gap_pts`` away from the label and the
    component, so all lines have the same vertical extent and spacing.
    """
    fig.canvas.draw()
    renderer = fig.canvas.get_renderer()
    inv = ax.transData.inverted()
    gap = gap_pts * fig.dpi / 72
    for label, center in zip(labels, centers):
        box = label.get_window_extent(renderer)
        # The text box extends below the baseline by the descent of the font
        _, _, descent = renderer.get_text_width_height_descent(
            'lp', label.get_fontproperties(), ismath=False)
        x, y = inv.transform(((box.x0 + box.x1) / 2, box.y0 + descent - gap))
        end_y = inv.transform(ax.transData.transform((center, top)) + (0, gap))[1]
        ax.plot([x, center], [y, end_y], color=color, linewidth=linewidth, zorder=2.5,
                solid_capstyle='butt', clip_on=False)


def _fit_axes_vertically(fig, ax):
    """Shrink the axes vertically to the extent of their content.

    The scale of the axes is preserved (only the unused room above and below the content is
    removed), so that nothing in the figure moves.
    """
    fig.canvas.draw()
    renderer = fig.canvas.get_renderer()
    extents = [artist.get_window_extent(renderer) for artist in ax.texts + ax.patches]
    y0 = min(box.y0 for box in extents)
    y1 = max(box.y1 for box in extents)
    inv = ax.transData.inverted()
    ax.set_ylim(inv.transform((0, y0))[1], inv.transform((0, y1))[1])
    position = ax.get_position()
    ax.set_position([position.x0, y0 / fig.bbox.height, position.width,
                     (y1 - y0) / fig.bbox.height])


def _spread_labels(fig, ax, labels, pad_pts=3, iterations=1000):
    """Shift horizontally-ordered labels apart until they no longer overlap.

    Each label is an annotation or a group (tuple) of annotations that move together.
    Overlapping neighbors are pushed apart symmetrically, so every label stays as close as
    possible to the position it is anchored to.
    """
    labels = [label if isinstance(label, tuple) else (label,) for label in labels]
    fig.canvas.draw()
    renderer = fig.canvas.get_renderer()
    pad = pad_pts * fig.dpi / 72
    extents = [[a.get_window_extent(renderer) for a in group] for group in labels]
    lows = [min(box.x0 for box in group) for group in extents]
    highs = [max(box.x1 for box in group) for group in extents]
    centers = [(low + high) / 2 for low, high in zip(lows, highs)]
    widths = [high - low for low, high in zip(lows, highs)]
    shifts = [0.0] * len(labels)
    for _ in range(iterations):
        moved = False
        for i in range(len(labels) - 1):
            gap = (centers[i + 1] + shifts[i + 1] - widths[i + 1] / 2) \
                - (centers[i] + shifts[i] + widths[i] / 2)
            if gap < pad:
                shifts[i] -= (pad - gap) / 2
                shifts[i + 1] += (pad - gap) / 2
                moved = True
        if not moved:
            break
    # Convert the pixel shifts to data units
    inv = ax.transData.inverted()
    for group, shift in zip(labels, shifts):
        dx = inv.transform((shift, 0))[0] - inv.transform((0, 0))[0]
        for label in group:
            label.xy = (label.xy[0] + dx, label.xy[1])


def plot3(show=True, dir=None, save=True, stage=core_area_experiments.FINAL_SYNTH_STAGE,
          figsize=(8, 2.4), label_fontsize=11, value_fontsize=None, share_fontsize=None,
          name_offset=7, name_pad=10):
    """Break down the area of the dual-issue core and its increment over the baseline core.

    The area of each pipeline component is taken from the hierarchy reports of the
    "grouped" synthesis runs of the baseline and the dual-issue designs. The dual-issue
    design is plotted as a single horizontal bar of components ordered by their share of the
    total area, in which each component is split into the part already present in the
    baseline core and the increment. The figure is saved to ``plots/plot3.pdf`` only if
    ``save`` is set. ``stage`` selects the synthesis stage the areas are taken from (e.g.
    ``core_area_experiments.EARLY_SYNTH_STAGE`` while the flow is still running).
    """
    # The component names and the absolute areas are slightly larger than the other labels
    if value_fontsize is None:
        value_fontsize = 1.2 * label_fontsize
    # The shares are slightly larger than the base size, but smaller than the other labels
    if share_fontsize is None:
        share_fontsize = 1.1 * label_fontsize
    synth_df = core_area_experiments.results(dir=dir, grouped=True, stage=stage)
    baseline = _area_breakdown(synth_df, AREA_BREAKDOWN_BASELINE, stage)
    design = _area_breakdown(synth_df, AREA_BREAKDOWN_DESIGN, stage)

    df = pd.DataFrame({
        AREA_BREAKDOWN_BASELINE: baseline,
        AREA_BREAKDOWN_DESIGN: design,
    })
    df['Increment'] = df[AREA_BREAKDOWN_DESIGN] - df[AREA_BREAKDOWN_BASELINE]
    df['Increment [%]'] = 100 * df['Increment'] / df[AREA_BREAKDOWN_BASELINE].sum()
    df.loc['Total'] = df.sum()
    df.index.name = 'Area [kGE]'

    # Print the breakdown to the console
    print()
    print(df.to_string(float_format=lambda x: f'{x:.1f}'))
    print()
    print(f'Synthesis stage: {stage}')
    print('Increment [%] is relative to the total area of ' + AREA_BREAKDOWN_BASELINE)

    # Merge the breakdown components into the components of the bar
    bar_df = pd.DataFrame({
        comp: df.loc[parts, [AREA_BREAKDOWN_BASELINE, 'Increment']].sum()
        for comp, parts in AREA_BAR_COMPONENTS.items()
    }).T
    assert np.isclose(bar_df.to_numpy().sum(), df.loc['Total', AREA_BREAKDOWN_DESIGN])
    # Order the components by their share of the total area of the design
    bar_df = bar_df.loc[bar_df.sum(axis=1).sort_values(ascending=False).index]

    # Single horizontal bar of components, separated by a small gap. Each component has a solid
    # border around the whole rectangle; its baseline part and increment only differ in fill
    fig, ax = plt.subplots(figsize=figsize)
    bar_height = 0.65
    total = bar_df.to_numpy().sum()
    gap = AREA_BAR_GAP * total
    left = 0
    name_labels, value_labels, outlines, centers = [], [], [], []
    for i, (comp, row) in enumerate(bar_df.iterrows()):
        base, inc = row[AREA_BREAKDOWN_BASELINE], row['Increment']
        start = left
        # The shape of the component, used to clip the fills. Its corners are rounded (as for all
        # outlines below) once the layout is final
        def component_shape(**kwargs):
            shape = FancyBboxPatch((start, -bar_height / 2), base + inc, bar_height,
                                   boxstyle='round,pad=0,rounding_size=0', **kwargs)
            ax.add_patch(shape)
            outlines.append(shape)
            return shape

        shape = component_shape(fill=False, edgecolor='none')
        parts = [(w, f, e) for w, f, e in [
            (base, AREA_BAR_BASELINE_COLOR, AREA_BAR_BASELINE_EDGE_COLOR),
            (inc, AREA_BAR_INCREMENT_COLOR, AREA_BAR_INCREMENT_EDGE_COLOR)] if w > 0]
        for j, (width, color, edge_color) in enumerate(parts):
            bars = ax.barh(0, width, left=left, height=bar_height, color=color, linewidth=0,
                           zorder=2)
            for bar in bars:
                bar.set_clip_path(shape)
            # Outline only the extent of this part: draw the border of the whole component,
            # clipped to the part. The outer sides are not clipped (beyond a small margin).
            outline = component_shape(fill=False, edgecolor=edge_color, linewidth=0.5, zorder=3)
            outline.set_clip_path(None)
            x0 = start - 2 * gap if j == 0 else left
            x1 = start + base + inc + 2 * gap if j == len(parts) - 1 else left + width
            outline.set_clip_box(TransformedBbox(
                Bbox([[x0, -2 * bar_height], [x1, 2 * bar_height]]), ax.transData))
            left += width
        left += gap
        # Names above the bar; below it the area and its share of the total area of the design
        # (one value per line, so that labels of narrow neighboring components don't collide)
        center = start + (base + inc) / 2
        centers.append(center)
        name_labels.append(ax.annotate(
                    comp.replace(' ', '\n'), (center, bar_height / 2), xytext=(0, name_offset),
                    textcoords='offset points', ha='center', va='bottom',
                    fontsize=value_fontsize, linespacing=1.1, annotation_clip=False))
        # The area is larger than the share, which is placed right below it
        value_labels.append((
            ax.annotate(f'{base + inc:.0f}', (center, -bar_height / 2), xytext=(0, -3),
                        textcoords='offset points', ha='center', va='top',
                        fontsize=value_fontsize, annotation_clip=False),
            ax.annotate(f'({100 * (base + inc) / total:.0f}%)', (center, -bar_height / 2),
                        xytext=(0, -3 - 1.25 * value_fontsize), textcoords='offset points',
                        ha='center', va='top', fontsize=share_fontsize,
                        annotation_clip=False)))
    ax.set_xlim(0, left - gap)
    # Vertical room above and below the bar for the labels
    ax.set_ylim(-1.9, 2.0)
    # The areas are given by the labels, so no axis is needed
    ax.set_axis_off()

    fig.tight_layout()
    _round_outlines(fig, ax, outlines)
    _spread_labels(fig, ax, name_labels, pad_pts=name_pad)
    _draw_leaders(fig, ax, name_labels, centers, top=bar_height / 2)
    _spread_labels(fig, ax, value_labels)
    # The unit is given once, at the side of the bar and aligned with the areas. It is placed
    # to the right of the right-most label (which can stick out of the bar)
    renderer = fig.canvas.get_renderer()
    unit_x_px = max(a.get_window_extent(renderer).x1 for group in value_labels for a in group)
    unit_x = ax.transData.inverted().transform((unit_x_px, 0))[0]
    ax.annotate('kGE', (unit_x, -bar_height / 2), xytext=(4, -3), textcoords='offset points',
                ha='left', va='top', fontsize=value_fontsize, annotation_clip=False)
    _fit_axes_vertically(fig, ax)
    if save:
        Path('plots').mkdir(exist_ok=True)
        fig.savefig('plots/plot3.pdf', dpi=300, bbox_inches='tight', pad_inches=0.1)
    if show:
        plt.show()
    else:
        plt.close(fig)
    return fig, bar_df


def main():
    """Parse command-line options and generate the requested plots."""

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
