#!/usr/bin/env python3
"""Draw the three README figures from exported results (no analysis here).

    python scripts/make_figures.py

Inputs : results/portfolio/a3_budget_vs_actual.csv
         results/portfolio/a6_offhours_savings_summary.csv
         benchmark/results/benchmark_summary.csv
Outputs: figures/budget_vs_actual.png, figures/offhours_savings.png,
         figures/query_performance.png
"""

import csv
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.lines import Line2D  # noqa: E402
from matplotlib.patches import Patch  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
FIG = ROOT / "figures"

SURFACE = "#fcfcfb"
TEXT = "#0b0b0b"
TEXT_2 = "#52514e"
GRID = "#e4e3df"
BLUE = "#2a78d6"
ORANGE = "#eb6834"
NEUTRAL = "#a3a29c"
MONTH_RAMP = ["#86b6ef", "#3987e5", "#184f95"]   # ordinal: Jan, Feb, Mar

plt.rcParams.update({
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
    "text.color": TEXT, "axes.labelcolor": TEXT_2, "xtick.color": TEXT_2, "ytick.color": TEXT,
    "axes.edgecolor": GRID, "font.size": 10, "axes.titlesize": 12, "axes.titleweight": "bold",
})


def read(path):
    with path.open() as fh:
        return list(csv.DictReader(fh))


def style(ax):
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)
    ax.grid(axis="x", color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    ax.tick_params(axis="y", length=0)


def budget_vs_actual():
    rows = read(ROOT / "results" / "portfolio" / "a3_budget_vs_actual.csv")
    depts = sorted({r["department_name"] for r in rows},
                   key=lambda d: -sum(float(r["actual_usd"]) for r in rows if r["department_name"] == d))
    months = sorted({r["month"] for r in rows})
    labels = {"2025-01-01": "Jan", "2025-02-01": "Feb", "2025-03-01": "Mar"}
    fig, ax = plt.subplots(figsize=(9, 6.2))
    bar_h = 0.26
    for i, dept in enumerate(depts):
        for j, month in enumerate(months):
            r = next(x for x in rows if x["department_name"] == dept and x["month"] == month)
            y = i + (j - 1) * bar_h
            actual = float(r["actual_usd"])
            if actual == 0 and r["has_no_servers"] == "t" and j == 1:
                ax.text(80, y, "no servers, 0 spend", va="center", fontsize=8, color=TEXT_2)
            ax.barh(y, actual, height=bar_h, color=MONTH_RAMP[j], edgecolor=SURFACE, linewidth=1.5)
            if r["budget_status"] == "no_budget":
                ax.text(actual + 80, y, "no budget", va="center", fontsize=8, color=TEXT_2)
            else:
                budget = float(r["budget_usd"])
                ax.plot([budget, budget], [y - bar_h / 2, y + bar_h / 2], color=TEXT, linewidth=2)
                if r["budget_status"] == "zero_budget":
                    ax.text(actual + 80, y, "budget = 0", va="center", fontsize=8, color=TEXT_2)
    ax.set_yticks(range(len(depts)), depts)
    ax.invert_yaxis()
    ax.set_xlabel("USD per month (simulated compute cost)")
    ax.xaxis.set_major_formatter(matplotlib.ticker.StrMethodFormatter("{x:,.0f}"))
    style(ax)
    handles = [Patch(color=c, label=f"{labels[m]} actual") for c, m in zip(MONTH_RAMP, months)]
    handles.append(Line2D([0], [0], color=TEXT, linewidth=2, label="Budget"))
    ax.legend(handles=handles, loc="lower right", frameon=False)
    ax.set_title("Monthly spend vs budget by department (Jan-Mar 2025, simulated)", loc="left")
    fig.tight_layout()
    fig.savefig(FIG / "budget_vs_actual.png", dpi=150)
    plt.close(fig)


def offhours_savings():
    rows = [r for r in read(ROOT / "results" / "portfolio" / "a6_offhours_savings_summary.csv")
            if r["department_name"] != "ALL"]
    total = next(r for r in read(ROOT / "results" / "portfolio" / "a6_offhours_savings_summary.csv")
                 if r["department_name"] == "ALL")
    rows.sort(key=lambda r: -float(r["eligible_cost_usd"]))
    fig, ax = plt.subplots(figsize=(9, 4.8))
    for i, r in enumerate(rows):
        savings = float(r["potential_savings_usd"])
        workday = float(r["eligible_cost_usd"]) - savings
        ax.barh(i, workday, color=BLUE, height=0.6, edgecolor=SURFACE, linewidth=2)
        ax.barh(i, savings, left=workday, color=ORANGE, height=0.6, edgecolor=SURFACE, linewidth=2)
        ax.text(workday + savings + 80, i,
                f"{savings:,.0f} USD ({float(r['savings_share_of_eligible']):.0%})",
                va="center", fontsize=9, color=TEXT)
    ax.set_yticks(range(len(rows)), [r["department_name"] for r in rows])
    ax.invert_yaxis()
    ax.set_xlabel("USD, Jan-Mar 2025 (eligible: development, non-critical servers)")
    ax.xaxis.set_major_formatter(matplotlib.ticker.StrMethodFormatter("{x:,.0f}"))
    ax.set_xlim(0, max(float(r["eligible_cost_usd"]) for r in rows) * 1.28)
    style(ax)
    ax.legend(handles=[Patch(color=BLUE, label="Cost inside workday (kept)"),
                       Patch(color=ORANGE, label="Cost in proposed shutdown window (potential)")],
              loc="lower right", frameon=False)
    ax.set_title(f"Off-hours scenario (simulated): {float(total['potential_savings_usd']):,.0f} USD potential "
                 f"of {float(total['eligible_cost_usd']):,.0f} USD eligible", loc="left")
    fig.text(0.01, 0.01, "Shutdown window: weekends and weekdays outside 07:00-20:00 UTC. "
             "Potential under assumptions, not a measured saving.", fontsize=8, color=TEXT_2)
    fig.tight_layout(rect=(0, 0.04, 1, 1))
    fig.savefig(FIG / "offhours_savings.png", dpi=150)
    plt.close(fig)


def query_performance():
    rows = read(ROOT / "benchmark" / "results" / "benchmark_summary.csv")
    titles = {
        "q1_server_week_metrics": "Q1 one server, one week",
        "q2_monthly_cost_joins": "Q2 monthly cost with joins",
        "q3_dev_utilization_march": "Q3 dev utilization, March",
    }
    fig, axes = plt.subplots(1, 3, figsize=(11, 3.6))
    for ax, (qid, title) in zip(axes, titles.items()):
        qs = [r for r in rows if r["query"] == qid]
        med = [float(r["median_ms"]) for r in qs]
        lo = [m - float(r["min_ms"]) for m, r in zip(med, qs)]
        hi = [float(r["max_ms"]) - m for m, r in zip(med, qs)]
        colors = [NEUTRAL if r["variant"] == "baseline" else BLUE for r in qs]
        y = range(len(qs))
        ax.barh(y, med, color=colors, height=0.55, edgecolor=SURFACE, linewidth=2)
        ax.errorbar(med, y, xerr=[lo, hi], fmt="none", ecolor=TEXT_2, elinewidth=1, capsize=3)
        for i, (m, r) in enumerate(zip(med, qs)):
            ax.text(m + max(med) * 0.04 + hi[i], i,
                    f"{m:.2f} ms\n{int(r['shared_hit_blocks']) + int(r['shared_read_blocks']):,} buffers",
                    va="center", fontsize=8, color=TEXT)
        ax.set_yticks(list(y), [r["variant"].replace("_", " ") for r in qs])
        ax.invert_yaxis()
        ax.set_xlim(0, max(med) * 1.75)
        ax.set_xlabel("median execution time, ms")
        ax.set_title(title, loc="left", fontsize=10)
        style(ax)
    fig.suptitle("Measured query time (7 runs, warm cache; bars = median, whiskers = min-max)",
                 x=0.01, ha="left", fontsize=11, fontweight="bold")
    fig.tight_layout()
    fig.savefig(FIG / "query_performance.png", dpi=150)
    plt.close(fig)


def main():
    FIG.mkdir(exist_ok=True)
    budget_vs_actual()
    offhours_savings()
    query_performance()
    print("Figures written to figures/")


if __name__ == "__main__":
    main()
