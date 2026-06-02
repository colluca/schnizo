#!/usr/bin/env python3
# Copyright 2026 ETH Zurich and University of Bologna.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0


# Defines the AreaRow class for constructing and plotting rows of an area breakdown.

from plot_util import PULP_COLORS_BASE
import re


class AreaRow:
    """
    Represents one row of the stacked bar chart, including data building and plotting.
    """
    def __init__(self, keys, total_area, threshold, color_source,
                 preferred=None, merge_rules=None, extra=None,
                 remainder_threshold=None, lift_label=None):
        self.keys = keys
        self.total = total_area
        self.threshold = threshold
        # allow separate threshold for including 'Other'
        self.remainder_threshold = (
            remainder_threshold if remainder_threshold is not None else threshold)
        self.color_source = color_source
        self.preferred = preferred or {}
        self.merge = merge_rules or {}
        self.extra = extra  # (name, area, color)
        self.items = {}  # name -> {'area': _, 'color': _}
        self.lift_label = lift_label or []

    def build(self, values, names, sort_by_number=False):
        cnt = 0
        for key in self.keys:
            # merge entries
            if key in self.merge:
                merged = sum(
                    values[names.index(sub)]
                    for sub in self.merge[key]
                    if sub in names
                )
                if merged / self.total >= self.threshold:
                    self.items[key] = {'area': merged, 'color': self._get_color(key, cnt)}
                    cnt += 1
            # individual entries
            elif key in names:
                idx = names.index(key)
                area_val = values[idx]
                if area_val / self.total >= self.threshold:
                    color = self.preferred.get(key, self._get_color(key, cnt))
                    self.items[key] = {'area': area_val, 'color': color}
                    cnt += 1

        if self.extra:
            name, area_val, col = self.extra
            self.items[name] = {'area': area_val, 'color': col}

        # sorting
        if sort_by_number:
            def sort_key(item):
                name, data = item
                m = re.search(r"\d+", name)
                num = int(m.group()) if m else float('inf')
                # sort by number ascending, then area descending
                return (num, -data['area'])

            sorted_items = sorted(self.items.items(), key=sort_key)
            self.items = dict(sorted_items)

        # catch-all remainder
        rem = self.total - sum(v['area'] for v in self.items.values())
        if rem > 0 and (rem / self.total >= self.remainder_threshold):
            self.items['Other'] = {'area': rem, 'color': PULP_COLORS_BASE[-1]}

        return self.items

    def _get_color(self, key, cnt):
        """
        Determine a color for a given item, cycling if needed.
        """
        if isinstance(self.color_source, list):
            return self.color_source[cnt % len(self.color_source)]
        return self.color_source(key, cnt)

    def plot(self, ax, y, offset_indices=None,
             bar_height=0.3, pos1=0.6, pos2=0.8, is_visible=True):
        """
        Render the stacked bar for this row onto ax at vertical position y.

        Args:
            ax (Axes): matplotlib Axes object
            y (float): vertical position
            offset_indices (list[int], optional): which labels to shift
            bar_height (float): bar thickness
            pos1, pos2 (float): text vertical offsets
        Returns:
            tuple: (labels, norm_row, left_positions)
        """
        labels, areas, colors = zip(
            *[(k, v['area'], v['color']) for k, v in self.items.items()]
        )
        row_total = sum(areas)
        norm_row = [a / row_total for a in areas]
        norm_tot = [a / self.total for a in areas]
        left = [sum(norm_row[:i]) for i in range(len(norm_row))]

        x = 0
        for i, (lbl, a, fr, clr, pct) in enumerate(zip(labels, areas, norm_row, colors, norm_tot)):
            off = 0.1 if offset_indices and i in offset_indices else 0
            ax.barh(y, fr, left=x, height=bar_height, color=clr,
                    edgecolor='white', linewidth=2, visible=is_visible)
            ax.text(x + fr/2, y - pos1*bar_height - off, lbl,
                    ha='center', va='center', fontsize=10, visible=is_visible)
            ax.text(x + fr/2, y + pos1*bar_height, f"{a:.1f}" if self.total < 10 else f"{a:.0f}",
                    ha='center', va='center', fontsize=10, weight='bold', visible=is_visible)
            ax.text(x + fr/2, y + pos2*bar_height, f"{pct*100:.0f}",
                    ha='center', va='center', fontsize=10, visible=is_visible)
            x += fr

        # side labels
        ax.text(1.005, y,  f"{row_total:.1f}" if self.total < 10 else f"{row_total:.0f}",
                ha='left', va='center', fontsize=10, weight='bold', visible=is_visible)
        ax.text(1.02, y + pos1*bar_height, 'kGE', ha='left', va='center', fontsize=10,
                weight='bold', visible=is_visible)
        ax.text(1.02, y + pos2*bar_height, '%', ha='left', va='center', fontsize=10,
                weight='bold', visible=is_visible)

        return labels, norm_row, left, y
