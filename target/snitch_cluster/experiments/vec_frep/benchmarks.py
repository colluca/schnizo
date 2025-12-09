import os
import json
import subprocess
import shutil
import re
import sys
import csv
import matplotlib.pyplot as plt
from pathlib import Path

# --- Configuration ---

# Path to the root of the workspace (relative to this script or absolute)
# Assuming this script is in target/snitch_cluster/experiments/vec_frep/
WORKSPACE_ROOT = Path("../../../..").resolve()
TARGET_DIR = WORKSPACE_ROOT / "target/snitch_cluster"
LOGS_ROOT = TARGET_DIR / "logs" # Where make benchmark outputs files
RESULTS_DIR = Path("results_256_frep_max_slots_big_K").resolve() # Where we save artifacts

# List of LMUL values to test
LMULS = [1, 2, 4, 8]

# Benchmark Definitions
BENCHMARKS = [
    {
        "name": "sz_gemm",
        "path": WORKSPACE_ROOT / "sw/schnizo/sz_gemm",
        "params_file": "data/params.json",
        "configs": [
            # Example configuration 1
            {
                "m": 2, "n": 8, "k": 256,
                "gemm_fp": "gemm_fp64_vec_base"
            },
            {
                "m": 2, "n": 8, "k": 256,
                "gemm_fp": "gemm_fp64_vec_base_unrolled"
            },
            {
                "m": 2, "n": 8, "k": 256,
                "gemm_fp": "gemm_fp64_vec_frep"
            },
            {
                "m": 2, "n": 8, "k": 256,
                "gemm_fp": "gemm_fp64_vec_frep_unrolled"
            },
            # {
            #     "m": 4, "n": 32, "k": 64,
            #     "gemm_fp": "gemm_fp64_vec_base"
            # },
            # {
            #     "m": 4, "n": 32, "k": 64,
            #     "gemm_fp": "gemm_fp64_vec_base_unrolled"
            # },
            # {
            #     "m": 4, "n": 32, "k": 64,
            #     "gemm_fp": "gemm_fp64_vec_frep"
            # },
            # {
            #     "m": 4, "n": 32, "k": 64,
            #     "gemm_fp": "gemm_fp64_vec_frep_unrolled"
            # },
        ]
    },
    # You can add other kernels here, e.g., sz_axpy
    # {
    #     "name": "sz_axpy",
    #     "path": WORKSPACE_ROOT / "sw/schnizo/sz_axpy",
    #     "params_file": "data/params.json",
    #     "configs": [ ... ]
    # }
]

# --- Helper Functions ---

def update_params(file_path, config):
    """Updates the JSON parameter file with the given configuration."""
    with open(file_path, 'r') as f:
        content = f.read()

    # Handle relaxed JSON (comments and unquoted keys)
    # 1. Remove comments
    content_clean = re.sub(r"//.*", "", content)
    # 2. Quote unquoted keys (simple heuristic for alphanumeric keys at start of line)
    content_clean = re.sub(r'(?m)^(\s*)([a-zA-Z0-9_]+)(\s*):', r'\1"\2"\3:', content_clean)

    try:
        data = json.loads(content_clean)
    except json.JSONDecodeError as e:
        print(f"Error parsing {file_path}: {e}")
        raise
    
    # Update keys
    for key, value in config.items():
        if key in data:
            data[key] = value
        else:
            print(f"Warning: Key '{key}' not found in {file_path}")

    with open(file_path, 'w') as f:
        json.dump(data, f, indent=4)

def parse_cycles(trace_file):
    """Parses the trace file to find cycles in Section 2."""
    if not trace_file.exists():
        print(f"Error: Trace file {trace_file} not found.")
        return None

    try:
        with open(trace_file, 'r') as f:
            content = f.read()
        
        # Find section 2 metrics and extract cycles
        # re.DOTALL allows . to match newlines, so we search across lines from the header
        match = re.search(r"Performance metrics for section 2.*?cycles\s+(\d+)", content, re.DOTALL)
        if match:
            return int(match.group(1))
            
    except Exception as e:
        print(f"Error parsing trace file: {e}")

    return None

def run_make_benchmark(cwd, lmul):
    """Runs 'make benchmark' with specific env vars."""
    env = os.environ.copy()
    env["LMUL"] = str(lmul)
    
    result = subprocess.run(
        ["make", "benchmark"],
        cwd=cwd,
        env=env,
        text=True
    )
    
    if result.returncode != 0:
        print(f"Make benchmark failed: {result.stderr}")
        return False
    return True

def calculate_ops(bench_name, config):
    """Calculates the number of operations based on the benchmark type."""
    if "gemm" in bench_name:
        # GEMM: 2 * M * N * K
        return config.get('m', 0) * config.get('n', 0) * config.get('k', 0) / 4 #Divide by the number of functional units
    elif "axpy" in bench_name:
        # AXPY: 2 * N (1 mul + 1 add per element)
        return 2 * config.get('n', 0)
    return 0

# --- Main Script ---

def main():
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    
    results_table = []

    for bench in BENCHMARKS:
        print(f"Processing Benchmark: {bench['name']}")
        params_path = bench['path'] / bench['params_file']
        
        for config in bench['configs']:
            # Construct a config ID string
            config_str = "_".join([f"{k}{v}" for k, v in config.items() if k in ['m', 'n', 'k', 'gemm_fp']])
            
            for lmul in LMULS:
                # 1. Update Configuration (Touch file to trigger recompile)
                print(f"  Configuring {config} with LMUL={lmul}")
                update_params(params_path, config)

                print(f"    Running with LMUL={lmul}...")
                
                # 2. Run Benchmark
                success = run_make_benchmark(TARGET_DIR, lmul)
                if not success:
                    continue
                
                # 3. Collect Artifacts
                run_id = f"{bench['name']}_{config_str}_lmul{lmul}"
                run_dir = RESULTS_DIR / run_id
                run_dir.mkdir(parents=True, exist_ok=True)
                
                trace_src = LOGS_ROOT / "sz_trace_hart_00000.txt"
                perfetto_src = LOGS_ROOT / "sz_perfetto_hart_00000.tb"
                
                if trace_src.exists():
                    shutil.copy(trace_src, run_dir / "trace.txt")
                if perfetto_src.exists():
                    shutil.copy(perfetto_src, run_dir / "perfetto.tb")
                
                # 4. Parse Performance
                # Note: Ideally we parse the stdout from the make command if the app prints cycles there,
                # or parse the trace file as requested.
                cycles = parse_cycles(trace_src)
                
                utilization = 0.0
                if cycles and cycles > 0:
                    ops = calculate_ops(bench['name'], config)
                    if ops > 0:
                        utilization = ops / cycles
                
                results_table.append({
                    "Benchmark": bench['name'],
                    "Config": config_str,
                    "LMUL": lmul,
                    "Cycles": cycles,
                    "Utilization": utilization
                })

    # 5. Report
    print("\n" + "="*80)
    print(f"{'Benchmark':<15} | {'Config':<30} | {'LMUL':<5} | {'Cycles':<10} | {'Utilization':<10}")
    print("-" * 80)
    for row in results_table:
        print(f"{row['Benchmark']:<15} | {row['Config']:<30} | {row['LMUL']:<5} | {row['Cycles']:<10} | {row['Utilization']:<10.2f}")

    # 6. Save to CSV
    csv_path = RESULTS_DIR / "results.csv"
    with open(csv_path, 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=["Benchmark", "Config", "LMUL", "Cycles", "Utilization"])
        writer.writeheader()
        writer.writerows(results_table)
    print(f"\nResults saved to {csv_path}")

    # 7. Graph Results
    plot_path = RESULTS_DIR / "utilization.png"
    plt.figure(figsize=(10, 6))
    
    # Group data by config
    configs = {}
    for row in results_table:
        label = f"{row['Benchmark']} - {row['Config']}"
        if label not in configs:
            configs[label] = {'x': [], 'y': []}
        configs[label]['x'].append(row['LMUL'])
        configs[label]['y'].append(row['Utilization'])
    
    for label, data in configs.items():
        plt.plot(data['x'], data['y'], marker='o', label=label)
    
    plt.xlabel('LMUL')
    plt.ylabel('Utilization')
    plt.title('Utilization vs LMUL')
    plt.legend()
    plt.grid(True)
    plt.xticks(LMULS)
    plt.savefig(plot_path)
    print(f"Graph saved to {plot_path}")

if __name__ == "__main__":
    main()