#!/usr/bin/env python3

import os
import csv
import sys

# directory to search (default: current directory)
root_dir = sys.argv[1] if len(sys.argv) > 1 else "."

totals = {
    "dual_issue_ctr": 0,
    "dual_fp_wb_ctr": 0,
    "remote_flw_ctr": 0,
    "fp_op_fp_wb_ctr": 0,
}

file_count = 0

for root, dirs, files in os.walk(root_dir):
    for fname in files:
        if fname.endswith("dual_issue_perf_cnt.txt"):
            path = os.path.join(root, fname)

            with open(path, newline="") as f:
                reader = csv.DictReader(f)
                for row in reader:
                    for key in totals:
                        totals[key] += int(row[key])

            file_count += 1

print(f"Processed {file_count} files\n")

for key, value in totals.items():
    print(f"{key}: {value}")