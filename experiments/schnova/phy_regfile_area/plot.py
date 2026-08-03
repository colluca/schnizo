#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
import argparse
import colorsys
import matplotlib.colors as mc
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


def lighten(color, amount=0.4):
    """Lightens a given color for the sequential area stacked components."""
    try:
        c = mc.cnames[color]
    except KeyError:
        c = color
    c = mc.to_rgb(c)
    h, l, s = colorsys.rgb_to_hls(*c)
    return colorsys.hls_to_rgb(h, 1 - amount * (1 - l), s)


def add_linear_fit(ax, x_values, y_values, plot_positions, label):
    """Fit y = A*x + B, plot the fit, and print A, B, and R^2."""
    x_values = np.asarray(x_values, dtype=float)
    y_values = np.asarray(y_values, dtype=float)
    plot_positions = np.asarray(plot_positions, dtype=float)

    valid = np.isfinite(x_values) & np.isfinite(y_values)
    x_fit = x_values[valid]
    y_fit = y_values[valid]

    if x_fit.size < 2 or np.allclose(x_fit, x_fit[0]):
        print(f"{label}: insufficient data for a linear fit")
        return

    A, B = np.polyfit(x_fit, y_fit, 1)
    y_pred = A * x_fit + B
    ss_res = np.sum((y_fit - y_pred) ** 2)
    ss_tot = np.sum((y_fit - np.mean(y_fit)) ** 2)
    r2 = 1.0 - ss_res / ss_tot if not np.isclose(ss_tot, 0.0) else 1.0

    print(f"{label}: A = {A:.4f}, B = {B:.4f}, R^2 = {r2:.6f}")


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


def plot_pipeline_width(
    df, baseline_num_regs=64, save_path="regfile_pipe_width_scalability.png"
):
    # Filter: Scale PipeWidth while keeping everything else at baseline
    subset = df[
        (df["NumRegs"] == baseline_num_regs)
        & (df["NofAlus"] == 1)
        & (df["NofLsus"] == 1)
        & (df["NofFpus"] == 1)
    ]

    pipe_widths = sorted(subset["PipeWidth"].unique())
    x = np.arange(len(pipe_widths))
    bar_width = 0.35

    fig, ax = plt.subplots(figsize=(8, 5))
    prop_cycle = plt.rcParams["axes.prop_cycle"].by_key()["color"]

    color_gpr = prop_cycle[0]
    color_fpr = prop_cycle[1]

    # Isolate data frames mapped exactly onto the axis positions
    gpr_data = (
        subset[subset["IsGpr"] == 1]
        .drop_duplicates(subset=["PipeWidth"])
        .set_index("PipeWidth")
        .reindex(pipe_widths)
    )
    fpr_data = (
        subset[subset["IsGpr"] == 0]
        .drop_duplicates(subset=["PipeWidth"])
        .set_index("PipeWidth")
        .reindex(pipe_widths)
    )

    gpr_comb = gpr_data["CombArea"].fillna(0).values
    gpr_seq = gpr_data["SeqArea"].fillna(0).values
    fpr_comb = fpr_data["CombArea"].fillna(0).values
    fpr_seq = fpr_data["SeqArea"].fillna(0).values

    # Plot GPR (Shifted Left)
    ax.bar(
        x - bar_width / 2,
        gpr_comb,
        bar_width,
        color=color_gpr,
        zorder=3,
        label="GPR Combinational",
    )
    ax.bar(
        x - bar_width / 2,
        gpr_seq,
        bar_width,
        bottom=gpr_comb,
        color=lighten(color_gpr),
        zorder=3,
        label="GPR Sequential",
    )

    # Plot FPR (Shifted Right)
    ax.bar(
        x + bar_width / 2,
        fpr_comb,
        bar_width,
        color=color_fpr,
        zorder=3,
        label="FPR Combinational",
    )
    ax.bar(
        x + bar_width / 2,
        fpr_seq,
        bar_width,
        bottom=fpr_comb,
        color=lighten(color_fpr),
        zorder=3,
        label="FPR Sequential",
    )

    add_linear_fit(
        ax,
        pipe_widths,
        gpr_comb + gpr_seq,
        x - bar_width / 2,
        "GPR total area vs fetch width",
    )
    add_linear_fit(
        ax,
        pipe_widths,
        fpr_comb + fpr_seq,
        x + bar_width / 2,
        "FPR total area vs fetch width",
    )

    ax.set_ylabel("Area [kGE]")
    ax.set_xlabel("Fetch Width")
    ax.set_xticks(x)
    ax.set_xticklabels(pipe_widths)
    ax.grid(True, axis="y", zorder=0)
    ax.legend(loc="upper left")

    fig.tight_layout()
    plt.savefig(save_path)
    plt.close()


# -----------------------------------------------------------------------------
# Plot 2: Varying Number of Registers (GPR vs FPR Side-by-Side)
# -----------------------------------------------------------------------------
def plot_num_registers(
    df, baseline_pipe_width=1, save_path="regfile_depth_scalability.png"
):
    # Filter: Scale NumRegs while keeping everything else at baseline
    subset = df[
        (df["PipeWidth"] == baseline_pipe_width)
        & (df["NofAlus"] == 1)
        & (df["NofLsus"] == 1)
        & (df["NofFpus"] == 1)
    ]

    num_regs_axis = sorted(subset["NumRegs"].unique())
    x = np.arange(len(num_regs_axis))
    bar_width = 0.35

    fig, ax = plt.subplots(figsize=(8, 5))
    prop_cycle = plt.rcParams["axes.prop_cycle"].by_key()["color"]

    color_gpr = prop_cycle[0]
    color_fpr = prop_cycle[1]

    # Isolate data frames mapped exactly onto the axis positions
    gpr_data = (
        subset[subset["IsGpr"] == 1]
        .drop_duplicates(subset=["NumRegs"])
        .set_index("NumRegs")
        .reindex(num_regs_axis)
    )
    fpr_data = (
        subset[subset["IsGpr"] == 0]
        .drop_duplicates(subset=["NumRegs"])
        .set_index("NumRegs")
        .reindex(num_regs_axis)
    )

    gpr_comb = gpr_data["CombArea"].fillna(0).values
    gpr_seq = gpr_data["SeqArea"].fillna(0).values
    fpr_comb = fpr_data["CombArea"].fillna(0).values
    fpr_seq = fpr_data["SeqArea"].fillna(0).values

    # Plot GPR (Shifted Left)
    ax.bar(
        x - bar_width / 2,
        gpr_comb,
        bar_width,
        color=color_gpr,
        zorder=3,
        label="GPR Combinational",
    )
    ax.bar(
        x - bar_width / 2,
        gpr_seq,
        bar_width,
        bottom=gpr_comb,
        color=lighten(color_gpr),
        zorder=3,
        label="GPR Sequential",
    )

    # Plot FPR (Shifted Right)
    ax.bar(
        x + bar_width / 2,
        fpr_comb,
        bar_width,
        color=color_fpr,
        zorder=3,
        label="FPR Combinational",
    )
    ax.bar(
        x + bar_width / 2,
        fpr_seq,
        bar_width,
        bottom=fpr_comb,
        color=lighten(color_fpr),
        zorder=3,
        label="FPR Sequential",
    )

    add_linear_fit(
        ax,
        num_regs_axis,
        gpr_comb + gpr_seq,
        x - bar_width / 2,
        "GPR total area vs number of registers",
    )
    add_linear_fit(
        ax,
        num_regs_axis,
        fpr_comb + fpr_seq,
        x + bar_width / 2,
        "FPR total area vs number of registers",
    )

    ax.set_ylabel("Area [kGE]")
    ax.set_xlabel("Number of Physical Registers")
    ax.set_xticks(x)
    ax.set_xticklabels(num_regs_axis)
    ax.grid(True, axis="y", zorder=0)
    ax.legend(loc="upper left")

    fig.tight_layout()
    plt.savefig(save_path)
    plt.close()


# -----------------------------------------------------------------------------
# Plot 3: Varying Functional Units (Separated Plots, 3 Bars per Point)
# -----------------------------------------------------------------------------
def plot_functional_units(
    df,
    is_gpr=1,
    baseline_num_regs=64,
    baseline_pipe_width=1,
    save_path="regfile_fu_scalability.png",
):
    # Filter data for specific regfile type and structural baselines
    base_subset = df[
        (df["IsGpr"] == is_gpr)
        & (df["NumRegs"] == baseline_num_regs)
        & (df["PipeWidth"] == baseline_pipe_width)
    ]

    # Grab the unique port scaling counts (1, 2, 3, 4)
    fu_counts = sorted(
        list(
            set(base_subset["NofAlus"])
            .union(base_subset["NofLsus"])
            .union(base_subset["NofFpus"])
        )
    )

    x = np.arange(len(fu_counts))
    bar_width = 0.25

    fig, ax = plt.subplots(figsize=(9, 5))
    prop_cycle = plt.rcParams["axes.prop_cycle"].by_key()["color"]

    color_alu = prop_cycle[0]
    color_lsu = prop_cycle[1]  # Explicitly different color indices
    color_fpu = prop_cycle[2]

    alu_comb, alu_seq = [], []
    lsu_comb, lsu_seq = [], []
    fpu_comb, fpu_seq = [], []

    # Map the unique execution port points manually based on sweep structures
    for k in fu_counts:
        # ALU Scales
        row_alu = base_subset[
            (base_subset["NofAlus"] == k)
            & (base_subset["NofLsus"] == 1)
            & (base_subset["NofFpus"] == 1)
        ]
        alu_comb.append(
            row_alu["CombArea"].values[0] if not row_alu.empty else 0
        )
        alu_seq.append(row_alu["SeqArea"].values[0] if not row_alu.empty else 0)

        # LSU Scales
        row_lsu = base_subset[
            (base_subset["NofAlus"] == 1)
            & (base_subset["NofLsus"] == k)
            & (base_subset["NofFpus"] == 1)
        ]
        lsu_comb.append(
            row_lsu["CombArea"].values[0] if not row_lsu.empty else 0
        )
        lsu_seq.append(row_lsu["SeqArea"].values[0] if not row_lsu.empty else 0)

        # FPU Scales
        row_fpu = base_subset[
            (base_subset["NofAlus"] == 1)
            & (base_subset["NofLsus"] == 1)
            & (base_subset["NofFpus"] == k)
        ]
        fpu_comb.append(
            row_fpu["CombArea"].values[0] if not row_fpu.empty else 0
        )
        fpu_seq.append(row_fpu["SeqArea"].values[0] if not row_fpu.empty else 0)

    # Convert lists to NumPy arrays for safe additions/manipulation
    alu_comb, alu_seq = np.array(alu_comb), np.array(alu_seq)
    lsu_comb, lsu_seq = np.array(lsu_comb), np.array(lsu_seq)
    fpu_comb, fpu_seq = np.array(fpu_comb), np.array(fpu_seq)

    # Plot ALU Bars (Shifted Left)
    ax.bar(
        x - bar_width,
        alu_comb,
        bar_width,
        color=color_alu,
        zorder=3,
        label="ALU Combinational",
    )
    ax.bar(
        x - bar_width,
        alu_seq,
        bar_width,
        bottom=alu_comb,
        color=lighten(color_alu),
        zorder=3,
        label="ALU Sequential",
    )

    # Plot LSU Bars (Centered)
    ax.bar(
        x,
        lsu_comb,
        bar_width,
        color=color_lsu,
        zorder=3,
        label="LSU Combinational",
    )
    ax.bar(
        x,
        lsu_seq,
        bar_width,
        bottom=lsu_comb,
        color=lighten(color_lsu),
        zorder=3,
        label="LSU Sequential",
    )

    # Plot FPU Bars (Shifted Right)
    ax.bar(
        x + bar_width,
        fpu_comb,
        bar_width,
        color=color_fpu,
        zorder=3,
        label="FPU Combinational",
    )
    ax.bar(
        x + bar_width,
        fpu_seq,
        bar_width,
        bottom=fpu_comb,
        color=lighten(color_fpu),
        zorder=3,
        label="FPU Sequential",
    )

    add_linear_fit(
        ax,
        fu_counts,
        alu_comb + alu_seq,
        x - bar_width,
        "ALU-port total area",
    )
    add_linear_fit(
        ax,
        fu_counts,
        lsu_comb + lsu_seq,
        x,
        "LSU-port total area",
    )
    add_linear_fit(
        ax,
        fu_counts,
        fpu_comb + fpu_seq,
        x + bar_width,
        "FPU-port total area",
    )

    ax.set_ylabel("Area [kGE]")
    ax.set_xlabel("Number of Functional Units")
    ax.set_xticks(x)
    ax.set_xticklabels(fu_counts)
    ax.grid(True, axis="y", zorder=0)
    ax.legend(loc="upper left")
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
    plot_pipeline_width(results())


def plot3():
    plot_num_registers(results())


def plot4():
    plot_functional_units(results(), is_gpr=1)


def plot5():
    plot_functional_units(results(), is_gpr=0)


def main():
    plots = [plot1, plot2, plot3, plot4, plot5]
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
