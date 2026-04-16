import ast
import sys

def sort_dasm(input_file, output_file):
    lines_with_cycles = []
    
    print(f"Reading {input_file}...")
    with open(input_file, 'r') as f:
        for line in f:
            if not line.strip(): continue
            try:
                # ast.literal_eval is safe for string-to-dict conversion
                data = ast.literal_eval(line.strip())
                lines_with_cycles.append((data['cycle'], data['time'], line))
            except Exception as e:
                print(f"Skipping malformed line: {e}")

    # Sort primarily by cycle, secondarily by time (to keep events stable)
    print("Sorting...")
    lines_with_cycles.sort(key=lambda x: (x[0], x[1]))

    print(f"Writing to {output_file}...")
    with open(output_file, 'w') as f:
        for _, _, original_line in lines_with_cycles:
            f.write(original_line)

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python sort_dasm.py <input.dasm> <output.dasm>")
    else:
        sort_dasm(sys.argv[1], sys.argv[2])