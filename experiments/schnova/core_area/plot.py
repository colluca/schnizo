#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

import argparse
import numpy as np
import matplotlib.pyplot as plt
try:
    from . import experiments
except ImportError:
    import experiments


GE = 0.121


def to_ge(area_um2):
    return area_um2 / GE


def to_kge(area_um2):
    return to_ge(area_um2) / 1e3


def to_mm2(area_kge):
    return area_kge * 1e3 * GE / 1e6


def results(dir=None):
    df = experiments.results(dir=dir)

    df['timestamp'] = df['synth_results'].str['qor_summary'].str['timestamp']
    df['hierarchy_details'] = df['synth_results'].str['hierarchy_details']
    df['CombArea'] = df['hierarchy_details'].map(lambda x: to_kge(x.tree.get_attr('CombArea')))
    df['SeqArea'] = df['hierarchy_details'].map(lambda x: to_kge(x.tree.get_attr('SeqArea')))
    df['CombArea'] = df['CombArea'].round(0).astype('int')
    df['SeqArea'] = df['SeqArea'].round(0).astype('int')
    df['StdCellArea'] = df['synth_results'].str['qor_summary'].str['StdCellArea']
    df['StdCellArea'] = df['StdCellArea'].map(to_kge).round(0).astype('int')
    # ---- Add AreaIncrease column ----
    baseline = df.loc['scalar+mul+fpu', 'StdCellArea']

    df['AreaIncrease'] = (
        df['StdCellArea']/ baseline
    ).round(1)
    df['CLK'] = 1 - df['synth_results'].str['qor_summary'].str['WNS']
    df['1BitEqSeq'] = (df['synth_results'].str['multibit'].str['1BitEqSeq']).astype('int')
    df['GE/bit'] = (1e3 * df['SeqArea'] / df['1BitEqSeq']).round(1)

    df.drop(columns=['hierarchy_details'], inplace=True)
    df.drop(columns=['synth_results'], inplace=True)

    return df

def area_efficiency_plot(clk=False):
    import numpy as np
    import matplotlib.pyplot as plt

    if clk:
        designs = {
            "Schnizo-Scalar-GP": {
                "IPC": 0.87,
                "CLK": 1.0,
                "area": 106
            },
            "Schnizo-GP-S": {
                "IPC": 1.38,
                "CLK": 2.65,
                "area": 988
            },
            "Schnizo-GP-L": {
                "IPC": 2.39,
                "CLK": 2.02,
                "area": 1307
            },
            "Schnova-GP-1": {
                "IPC": 1.0,
                "CLK": 1.0,
                "area": 353
            },
            "Schnova-GP-2": {
                "IPC": 1.71,
                "CLK": 1.09,
                "area": 437
            },
            "Schnova-GP-4": {
                "IPC": 2.17,
                "CLK": 1.3,
                "area": 559
            },
            "Schnova-GP-8": {
                "IPC": 2.38,
                "CLK": 1.34,
                "area": 808
            }
        }
    else:
        designs = {
            "Schnizo-Scalar-GP": {
                "IPC": 0.87,
                "CLK": 1.0,
                "area": 106
            },
            "Schnizo-GP-S": {
                "IPC": 1.38,
                "CLK": 1.0,
                "area": 988
            },
            "Schnizo-GP-L": {
                "IPC": 2.39,
                "CLK": 1.0,
                "area": 1307
            },
            "Schnova-GP-1": {
                "IPC": 1.0,
                "CLK": 1.0,
                "area": 353
            },
            "Schnova-GP-2": {
                "IPC": 1.71,
                "CLK": 1.0,
                "area": 437
            },
            "Schnova-GP-4": {
                "IPC": 2.17,
                "CLK": 1.3,
                "area": 559
            },
            "Schnova-GP-8": {
                "IPC": 2.38,
                "CLK": 1.0,
                "area": 808
            }
        }

    # ----------------------------------------
    # Performance calculation
    # GIPS = IPC / CLK(ns)
    # ----------------------------------------

    for d in designs.values():
        d["performance_gips"] = d["IPC"] / d["CLK"]

    # ----------------------------------------
    # Same color per family, different markers
    # ----------------------------------------

    marker_map = {
        "Schnizo-Scalar-GP": ("tab:orange", "o"),
        "Schnizo-GP-S":      ("tab:orange", "^"),
        "Schnizo-GP-L":      ("tab:orange", "s"),
        "Schnova-GP-1":      ("tab:blue", "o"),
        "Schnova-GP-2":      ("tab:blue", "^"),
        "Schnova-GP-4":      ("tab:blue", "s"),
        "Schnova-GP-8":      ("tab:blue", "D"),
    }

    efficiency_levels = [1, 2, 5, 10, 20, 50]

    max_area = max(d["area"] for d in designs.values())

    plt.figure(figsize=(10, 4.2))

    # ----------------------------------------
    # Contour lines like your example
    # labels near the top / side of the line
    # ----------------------------------------

    x = np.linspace(1, 3000, 500)

    for eff in efficiency_levels:
        y = (eff * x) / 1000.0

        plt.plot(
            x,
            y,
            linestyle="--",
            linewidth=1.2,
            color="gray",
            alpha=0.9
        )


        if eff == 1:
            y_text = 2.9
        else:
            y_text = 4.6

        x_text = y_text * 1000.0 / eff -60
        
        plt.text(
            x_text,
            y_text + 0.05,
            f"{eff}",
            fontsize=10,
            color="gray"
        )

    # ----------------------------------------
    # Scatter points with full legend entries
    # ----------------------------------------

    for name, d in designs.items():
        area = d["area"]
        perf = d["performance_gips"]
        color, marker = marker_map[name]

        plt.scatter(
            area,
            perf,
            s=130,
            color=color,
            marker=marker,
            label=name
        )

    # ----------------------------------------
    # Styling similar to reference image
    # ----------------------------------------

    plt.xlabel("Area [kGE]", fontsize=12)
    plt.ylabel("Performance [GIPS]", fontsize=12)

    plt.xlim(0, 3000)
    plt.ylim(0, 5)

    plt.grid(True, alpha=0.35)

    plt.legend(
        loc="upper right",
        ncol=2,
        frameon=True
    )

    plt.tight_layout()
    plt.show()

def plot1():
    print(results())

def plot2():
    area_efficiency_plot()
def plot3():
    area_efficiency_plot(clk=True)

def main():
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
