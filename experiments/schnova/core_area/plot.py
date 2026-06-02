#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

import argparse
import matplotlib.patches as patches
import matplotlib.path as mpath
from area_row import AreaRow
from plot_util import PULP_COLORS_BASE, smooth_polygon
import numpy as np
import matplotlib.pyplot as plt
import pandas as pd
import pprint
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
    baseline = 106

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
            },
            "Schnova-GP-1-opt1": {
                "IPC": 1.0,
                "CLK": 1.05,
                "area": 325
            },
            "Schnova-GP-2-opt1": {
                "IPC": 1.71,
                "CLK": 1.07,
                "area": 379
            },
            "Schnova-GP-4-opt1": {
                "IPC": 2.17,
                "CLK": 1.17,
                "area": 479
            },
            "Schnova-GP-8-opt1": {
                "IPC": 2.38,
                "CLK": 1.34,
                "area": 668
            },"Schnova-GP-1-opt-c": {
                "IPC": 0.99,
                "CLK": 1.00,
                "area": 172
            },
            "Schnova-GP-2-opt-c": {
                "IPC": 1.62,
                "CLK": 1.03,
                "area": 252
            },
            "Schnova-GP-4-opt-c": {
                "IPC": 3.44,
                "CLK": 1.06,
                "area": 328
            },
            "Schnova-GP-8-opt-c": {
                "IPC": 6.75,
                "CLK": 1.30,
                "area": 493
            },"Schnova-GP-1-opt-p": {
                "IPC": 0.99,
                "CLK": 1.00,
                "area": 176
            },
            "Schnova-GP-2-opt-p": {
                "IPC": 1.62,
                "CLK": 1.05,
                "area": 236
            },
            "Schnova-GP-4-opt-p": {
                "IPC": 3.44,
                "CLK": 1.17,
                "area": 304
            },
            "Schnova-GP-8-opt-p": {
                "IPC": 6.75,
                "CLK": 1.35,
                "area": 456
            }, "Schnova-GP-1-refcnt": {
                "IPC": 0.99,
                "CLK": 1.00,
                "area": 168
            },
            "Schnova-GP-2-refcnt": {
                "IPC": 1.62,
                "CLK": 1.05,
                "area": 209
            },
            "Schnova-GP-4-refcnt": {
                "IPC": 3.44,
                "CLK": 1.15,
                "area": 315
            },
            "Schnova-GP-8-refcnt": {
                "IPC": 6.75,
                "CLK": 1.25,
                "area": 469
            }, 
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
                "CLK": 1.0,
                "area": 559
            },
            "Schnova-GP-8": {
                "IPC": 2.38,
                "CLK": 1.0,
                "area": 808
            },
            "Schnova-GP-1-opt1": {
                "IPC": 1.0,
                "CLK": 1.0,
                "area": 325
            },
            "Schnova-GP-2-opt1": {
                "IPC": 1.71,
                "CLK": 1.0,
                "area": 379
            },
            "Schnova-GP-4-opt1": {
                "IPC": 2.17,
                "CLK": 1.0,
                "area": 479
            },
            "Schnova-GP-8-opt1": {
                "IPC": 2.38,
                "CLK": 1.0,
                "area": 668
            },"Schnova-GP-1-opt-c": {
                "IPC": 0.99,
                "CLK": 1.00,
                "area": 172
            },
            "Schnova-GP-2-opt-c": {
                "IPC": 1.62,
                "CLK": 1.00,
                "area": 252
            },
            "Schnova-GP-4-opt-c": {
                "IPC": 3.44,
                "CLK": 1.00,
                "area": 328
            },
            "Schnova-GP-8-opt-c": {
                "IPC": 6.75,
                "CLK": 1.00,
                "area": 493
            },
            "Schnova-GP-1-opt-p": {
                "IPC": 0.98,
                "CLK": 1.00,
                "area": 176
            },
            "Schnova-GP-2-opt-p": {
                "IPC": 1.60,
                "CLK": 1.00,
                "area": 236
            },
            "Schnova-GP-4-opt-p": {
                "IPC": 3.44,
                "CLK": 1.00,
                "area": 304
            },
            "Schnova-GP-8-opt-p": {
                "IPC": 6.75,
                "CLK": 1.00,
                "area": 456
            }, "Schnova-GP-1-refcnt": {
                "IPC": 0.99,
                "CLK": 1.00,
                "area": 168
            },
            "Schnova-GP-2-refcnt": {
                "IPC": 1.62,
                "CLK": 1.00,
                "area": 209
            },
            "Schnova-GP-4-refcnt": {
                "IPC": 3.44,
                "CLK": 1.00,
                "area": 315
            },
            "Schnova-GP-8-refcnt": {
                "IPC": 6.75,
                "CLK": 1.00,
                "area": 469
            },
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
        "Schnova-GP-1-opt1": ("tab:green", "o"),
        "Schnova-GP-2-opt1": ("tab:green", "^"),
        "Schnova-GP-4-opt1": ("tab:green", "s"),
        "Schnova-GP-8-opt1": ("tab:green", "D"),
        "Schnova-GP-1-opt-c": ("tab:red", "o"),
        "Schnova-GP-2-opt-c": ("tab:red", "^"),
        "Schnova-GP-4-opt-c": ("tab:red", "s"),
        "Schnova-GP-8-opt-c": ("tab:red", "D"),
        "Schnova-GP-1-opt-p": ("tab:purple", "o"),
        "Schnova-GP-2-opt-p": ("tab:purple", "^"),
        "Schnova-GP-4-opt-p": ("tab:purple", "s"),
        "Schnova-GP-8-opt-p": ("tab:purple", "D"),
        "Schnova-GP-1-refcnt": ("tab:pink", "o"),
        "Schnova-GP-2-refcnt": ("tab:pink", "^"),
        "Schnova-GP-4-refcnt": ("tab:pink", "s"),
        "Schnova-GP-8-refcnt": ("tab:pink", "D"),
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
    plt.ylim(0, 7)

    plt.grid(True, alpha=0.35)

    plt.legend(
        loc="upper right",
        ncol=2,
        frameon=True
    )

    plt.tight_layout()
    plt.savefig(
    "plot.png",
    bbox_inches="tight",
    pad_inches=0.1,
    dpi=300
    )

def extract_hierarchy(tree):
        rows = []

        def visit(node, path=""):
            name = getattr(node, "name", "")
            full_path = f"{path}/{name}" if path else name

            rows.append({
                "path": full_path,
                "level": full_path.count("/"),
                "CombArea": getattr(node, "CombArea", None),
                "SeqArea": getattr(node, "SeqArea", None),
                "StdCellArea": getattr(node, "StdCellArea", None),
                "MacroBBArea": getattr(node, "MacroBBArea", None),
            })

            for child in node.children:
                visit(child, full_path)

        visit(tree)
        return pd.DataFrame(rows)

def connect(ax, gA, idxA, gB, idxB, bar_h, color="gray", alpha=0.2):
    labelsA, widthsA, leftsA, yA = gA.values()
    labelsB, widthsB, leftsB, yB = gB.values()

    x1_left = leftsA[idxA]
    x1_right = leftsA[idxA] + widthsA[idxA]

    x2_left = leftsB[idxB]
    x2_right = leftsB[idxB] + widthsB[idxB]

    p1 = (x1_left,  yA + bar_h/2)
    p2 = (x1_right, yA + bar_h/2)
    p3 = (x2_right, yB - bar_h/2)
    p4 = (x2_left,  yB - bar_h/2)

    path = smooth_polygon(p1, p2, p3, p4)

    ax.add_patch(
        patches.PathPatch(path, facecolor=color, edgecolor='none', alpha=alpha)
    )

def plot_core_breakdown(dir=None, name='gp_sv1'):
    df = experiments.results(dir=dir)
    df['hierarchy_details'] = df['synth_results'].str['hierarchy_details']
    # Extract the smallest and biggest general purpose configuration
    obj = df['hierarchy_details'].loc[name]

    df = extract_hierarchy(obj.tree)
    df['CombArea'] = df['CombArea'].map(to_kge)
    df['SeqArea'] = df['SeqArea'].map(to_kge)
    df['StdCellArea'] = df['StdCellArea'].map(to_kge)
    df['area'] = df['StdCellArea']

    print(df)
    
    # -----------------------------
    # Helper
    # -----------------------------
    def get_area(path):
        row = df[df['path'] == path]
        return row['area'].values[0] if len(row) else 0.0
    
    
    # -----------------------------
    # Build synthetic rows
    # -----------------------------
    root_area = get_area('.')
    schnova_area = get_area('./i_schnova')
    fu_stage_area = get_area('./i_schnova/i_fu_stage')
    
    # ---- Row 1
    row1_names = ["Schnova", "Rest"]
    row1_vals = [
        schnova_area,
        root_area - schnova_area
    ]
    
    # ---- Row 2
    blocks_lvl2 = {
        "FU Stage": "./i_schnova/i_fu_stage",
        "FP RF": "./i_schnova/gen_fp_rf_i_fp_phy_regfile",
        "Int RF": "./i_schnova/i_int_phy_regfile",
    }

    blocks_rename = {
        "Rename": "./i_schnova/i_rename",
        "ROB": "./i_schnova/i_rob",
        "Scoreboard": "./i_schnova/i_scoreboard",
    }
    
    row2_names = list(blocks_lvl2.keys())
    row2_vals = [get_area(p) for p in blocks_lvl2.values()]

    rename_vals = [get_area(p) for p in blocks_rename.values()]

    row2_names.append("Rename")
    row2_vals.append(sum(rename_vals))
    
    row2_names.append("Rest")
    row2_vals.append(schnova_area - sum(row2_vals))
    
    
    # ---- Row 3 (FU stage)
    alu_area = df[
        df['path'].str.contains('gen_alus_') &
        df['path'].str.endswith('i_alu')
    ]['area'].sum()
    
    fpu_area = df[
        df['path'].str.contains('gen_fpus_0__i_fpu/i_fpu')
    ]['area'].sum()
    
    lsu_area = df[
        df['path'].str.contains('gen_lsus_') &
        df['path'].str.endswith('i_lsu')
    ]['area'].sum()
    
    fu_block_area = df[
        df['path'].str.endswith('i_fu_block')
    ]['area'].sum()
    
    row3_names = ["FPU", "FU Blocks", "3 ALUs", "3 LSUs"]
    row3_vals = [fpu_area, fu_block_area, alu_area,  lsu_area]
    
    row3_names.append("Rest")
    row3_vals.append(fu_stage_area - sum(row3_vals))
    
    
    # -----------------------------
    # Build AreaRow objects
    # -----------------------------
    rows = [
        AreaRow(row1_names, total_area=root_area, threshold=0.0, color_source=PULP_COLORS_BASE),
        AreaRow(row2_names, total_area=schnova_area, threshold=0.0, color_source=PULP_COLORS_BASE),
        AreaRow(row3_names, total_area=fu_stage_area, threshold=0.0, color_source=PULP_COLORS_BASE),
    ]
    
    row1 = rows[0].build(row1_vals, row1_names)
    row2 = rows[1].build(row2_vals, row2_names)
    row3 = rows[2].build(row3_vals, row3_names)
    
    fig, ax = plt.subplots(figsize=(10, 4), dpi=300)
    
    BAR_H = 0.3
    Y_OFF = 1.0
    POS1_OFF = 0.65
    POS2_OFF = 0.95
    
    if name == 'gp_sv1': 
        specs = [
            (rows[0], 0, None),
            (rows[1], Y_OFF, [4]),
            (rows[2], 2 * Y_OFF, [4]),
        ]
    else:
        specs = [
            (rows[0], 0, None),
            (rows[1], Y_OFF, [4]),
            (rows[2], 2 * Y_OFF, [2,4]),
        ]
    
    ax.set_xlim(0, 1)
    ax.invert_yaxis()
    ax.axis('off')
    
    geom = []

    for i, (row_obj, y, off) in enumerate(specs):
        labels, widths, lefts, y_out = row_obj.plot(
            ax,
            y,
            offset_indices=off,
            bar_height=BAR_H,
            pos1=POS1_OFF,
            pos2=POS2_OFF
        )
        geom.append({
            "labels": labels,
            "widths": widths,
            "lefts": lefts,
            "y": y_out
        })

    g0 = geom[0]
    g1 = geom[1]
    g2 = geom[2]

    bar2_idx = [g1["labels"].index(i) for i in row2_names]
    bar3_idx = [g2["labels"].index(i) for i in row3_names]

    schnova_idx = g0["labels"].index("Schnova")
    schnova_left = g0["lefts"][schnova_idx]
    schnova_right = schnova_left + g0["widths"][schnova_idx]
    fu_idx = g1["labels"].index("FU Stage")
    fu_left = g1["lefts"][fu_idx]
    fu_right = fu_left + g1["widths"][fu_idx]

    bar2_left = min(g1["lefts"][i] for i in bar2_idx)
    bar2_right = max(
        g1["lefts"][i] + g1["widths"][i] for i in bar2_idx
    )
    bar3_left = min(g2["lefts"][i] for i in bar3_idx)
    bar3_right = max(
        g2["lefts"][i] + g2["widths"][i] for i in bar3_idx
    )

    p1 = (schnova_left, g0["y"] + BAR_H/2)
    p2 = (schnova_right, g0["y"] + BAR_H/2)
    p3 = (bar2_right, g1["y"] - BAR_H/2)
    p4 = (bar2_left,  g1["y"] - BAR_H/2)

    path = smooth_polygon(p1, p2, p3, p4)
    ax.add_patch(
        patches.PathPatch(path, facecolor="gray", edgecolor="none", alpha=0.2)
    )

    p1 = (fu_left,  g1["y"] + BAR_H/2)
    p2 = (fu_right, g1["y"] + BAR_H/2)
    p3 = (bar3_right, g2["y"] - BAR_H/2)
    p4 = (bar3_left,  g2["y"] - BAR_H/2)

    path = smooth_polygon(p1, p2, p3, p4)
    ax.add_patch(
        patches.PathPatch(path, facecolor="gray", edgecolor="none", alpha=0.2)
    )
    
    plt.tight_layout()
    plt.savefig(
    "plot.png",
    bbox_inches="tight",
    pad_inches=0.1,
    dpi=300
    )
    plt.show()
    

def plot1():
    area_efficiency_plot()


def plot2():
    area_efficiency_plot(clk=True)


def plot3():
    plot_core_breakdown(name='gp_sv1')


def plot4():
    plot_core_breakdown(name='gp_sv8')

def plot5():
    print(results())
    

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
