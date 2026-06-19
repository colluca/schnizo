#!/usr/bin/env python3
# Copyright 2025 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

import argparse
import matplotlib.pyplot as plt
import numpy as np
import re
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
    """ Compare Schnizo (Scalar/Superscalar) vs. Schnova Core """

    # Define the configs that are used for the comparison
    schnizo_cfg = '3x32_3x32_1x64'
    schnova_cfgs = ['sv_1_3x32_3x32_1x32_32_128_128_256',
                    'sv_2_3x32_3x32_1x32_32_128_128_256',
                    'sv_4_3x32_3x32_1x32_32_128_128_256',
                    'sv_8_3x32_3x32_1x32_32_128_128_256',]

    schnizo_df = (df['hw'] == schnizo_cfg)
    schnova_df = (df['hw'].isin(schnova_cfgs)) & (df['mode'] == 'superscalar')
    plot_df = df[schnizo_df | schnova_df].copy()

    def identify_config(row):
        if row['hw'] == schnizo_cfg:
            return f"Schnizo {row['mode'].capitalize()}"
        width = row['hw'].split('_')[1]
        return f"Schnova Width {width}"

    plot_df['config'] = plot_df.apply(identify_config, axis=1)

    idx_max_size = plot_df.groupby(['app', 'config'])['size'].idxmax()
    plot_df = plot_df.loc[idx_max_size].pivot(index='app', columns='config', values=metric)

    ordered_cols = [
        'Schnizo Scalar', 'Schnizo Superscalar',
        'Schnova Width 1', 'Schnova Width 2', 'Schnova Width 4', 'Schnova Width 8'
    ]
    plot_df = plot_df[[c for c in ordered_cols if c in plot_df.columns]]

    fig, ax = plt.subplots(figsize=(14, 7))
    plot_df.plot(kind='bar', ax=ax, zorder=3, width=0.85)

    # Add Ideal IPC lines (using Schnizo XL theoreticals for all superscalar)
    if metric == 'ipc':
        labeled = False
        theoretical_data = model.theoretical_metrics(cfg=model.SCHNIZO_XL)['ipc']['superscalar']

        for i, col_name in enumerate(plot_df.columns):
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

    ax.axhline(y=1, color='black', linewidth=0.8, zorder=2.5)
    ax.set_ylabel(METRIC_LABELS.get(metric, metric.upper()))
    ax.set_xlabel('')

    clean_labels = [app.replace('xoshiro128p', 'xoshiro') for app in plot_df.index]
    ax.set_xticklabels(clean_labels, rotation=15, ha='right')

    ax.legend(title="Core Architecture", loc='upper left', bbox_to_anchor=(1, 1))
    ax.grid(True, axis='y', color='gray', linewidth=0.5, alpha=1.0)

    if metric == 'ipc':
        ax.set_ylim(bottom=0, top=max(plot_df.max().max() * 1.15, 8.5))
    elif metric == 'fpu_util':
        ax.set_ylim(bottom=0, top=1.3)

    fig.tight_layout()

    print(f"\n--- Geomean {metric} Performance ---")
    for col in plot_df.columns:
        gm = gmean(plot_df[col].dropna())
        print(f"{col:18}: {format_metric(gm, metric)}")

    if show:
        plt.show()

    return plot_df


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


def print_geomean_ipc(cfg_name, cfg_data, is_axpy_unrolled=False, app_filter=None, width=None):
    """
    Calculates and prints the geomean of IPC for a given config,
    followed by the individual Ideal IPC for each app.
    """
    # 1. Fetch base superscalar metrics
    metrics = model.theoretical_metrics(cfg=cfg_data, pipe_width=width)
    ipc_map = metrics['ipc']['superscalar'].copy()

    # 2. Swap 'sz_axpy' if unrolled/scalar value is requested
    if is_axpy_unrolled:
        axpy_scalar_insns = model.BENCHMARK_INSNS['scalar']['sz_axpy']
        axpy_scalar_ipc = model.ideal_ipc(axpy_scalar_insns, cfg_data, pipe_width=width)
        ipc_map['sz_axpy'] = axpy_scalar_ipc

    # 3. Apply App Filter
    if app_filter is not None:
        ipc_map = {app: ipc for app, ipc in ipc_map.items() if app in app_filter}

    # 4. Calculate Geomean
    ipc_values = list(ipc_map.values())

    if ipc_values:
        avg_ipc = gmean(ipc_values)

        status = "(Axpy Unrolled/Scalar)" if is_axpy_unrolled else "(Default)"
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
        theoretical_data = model.theoretical_metrics(cfg=model.SCHNIZO_XL)['ipc']['superscalar']

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


def plot8(show=True, dir=None, width=1, vary_by='slots', metric='ipc'):
    df = experiments.results(dir=dir)
    return geomean_plot(df, width, vary_by, metric, show)


def plot9(width=1):
    if width == 1:
        print_geomean_ipc("Schnova SV1", model.SCHNOVA_S, True, None, width)
    elif width == 2:
        print_geomean_ipc("Schnova SV2", model.SCHNOVA_M, True, None, width)
    elif width == 4:
        print_geomean_ipc("Schnova SV1", model.SCHNIZO_XL, False, None, width)
    elif width == 8:
        print_geomean_ipc("Schnova SV1", model.SCHNIZO_XL, False, None, width)


def plot10(show=True, dir=None):
    df = experiments.results(dir=dir)
    return balanced_comparison_plot(df, 'ipc', show=show)


def plot11(dir=None):
    df = experiments.results(dir=dir)
    print_all_geomeans(df, 'ipc')


def main():
    """Load results from CSV and generate plots"""

    plots = [plot1, plot2, plot3, plot4, plot5, plot6, plot8, plot9, plot10, plot11]
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
        help="Pipeline width for plot8 (default: 1)"
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
        help="Hardware parameter to vary for plot8 "
             "(default: slots)"
    )

    parser.add_argument(
        "--metric",
        type=str,
        choices=["ipc", "fpu_util"],
        default="ipc",
        help="Metric to plot for plot8 (default: ipc)"
    )

    args = parser.parse_args()

    # Generate selected plots
    for name in args.plots:
        if name == "plot8":
            _ = plot_dict[name](
                width=args.width,
                vary_by=args.vary,
                metric=args.metric,
            )
        elif name == "plot9":
            _ = plot_dict[name](
                width=args.width,
            )
        else:
            _ = plot_dict[name]()


if __name__ == '__main__':
    main()
