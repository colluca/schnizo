import csv
import matplotlib.pyplot as plt
from pathlib import Path

# --- Configuration ---
# Path to the CSV file you want to plot. 
# You can edit this path or the content of the CSV file before running this script.
CSV_FILE = Path("results_similar_sizes.csv")
OUTPUT_PLOT = CSV_FILE.with_suffix(".png")

def main():
    if not CSV_FILE.exists():
        print(f"Error: CSV file {CSV_FILE} not found.")
        return

    print(f"Reading data from {CSV_FILE}...")
    results_table = []
    
    try:
        with open(CSV_FILE, 'r') as f:
            # Handle potential whitespace in headers if manually edited
            reader = csv.DictReader(f, skipinitialspace=True)
            for row in reader:
                # Convert numeric types
                try:
                    row['Vector Length'] = float(row['Vector Length'])
                    row['Cycles'] = int(row['Cycles'])
                    row['Utilization'] = float(row['Utilization'])
                    results_table.append(row)
                except ValueError as e:
                    print(f"Skipping invalid row: {row} ({e})")
    except Exception as e:
        print(f"Error reading CSV: {e}")
        return

    if not results_table:
        print("No data found to plot.")
        return

    # Group data by config
    configs = {}
    for row in results_table:
        # Use Config as label. 
        label = row['Config']
        
        if label not in configs:
            configs[label] = {'x': [], 'y': []}
        configs[label]['x'].append(row['Vector Length'])
        configs[label]['y'].append(row['Utilization'])

    # Plotting
    plt.figure(figsize=(10, 6))
    
    for label, data in configs.items():
        # Sort by X (Vector Length) to ensure lines are drawn correctly
        points = sorted(zip(data['x'], data['y']))
        x = [p[0] for p in points]
        y = [p[1] for p in points]
        
        plt.plot(x, y, marker='o', label=label)
    
    plt.xlabel('Vector Length')
    plt.ylabel('Utilization')
    plt.title(f'Utilization vs Vector Length')
    plt.legend()
    plt.grid(True)
    
    plt.savefig(OUTPUT_PLOT)
    plt.close()
    print(f"Graph saved to {OUTPUT_PLOT}")

if __name__ == "__main__":
    main()
