#!/usr/bin/env python3
"""
SystemBackup — Storage Predictor Helper
Calculates weighted linear regression for storage prediction.
No external dependencies. Uses only Python standard library.
"""

import sys
import csv
import math
import json

def predict(data_file, total_capacity_bytes):
    xs = []
    ys = []
    
    try:
        with open(data_file, 'r') as f:
            for line in f:
                parts = line.strip().split(',')
                if len(parts) >= 3:
                    try:
                        # Format: timestamp,repo_path,size_bytes
                        xs.append(float(parts[0]))
                        ys.append(float(parts[2]))
                    except ValueError:
                        continue
    except FileNotFoundError:
        return {"error": "Data file not found"}

    if len(xs) < 3:
        return {"error": "Need at least 3 data points"}

    # Normalize x to days from start
    x0 = xs[0]
    xs = [(x - x0) / 86400.0 for x in xs]
    
    # Exponential weights: give more weight to recent data
    n = len(xs)
    weights = [math.exp(0.1 * i) for i in range(n)]
    
    # Weighted least squares
    sw = sum(weights)
    swx = sum(w * x for w, x in zip(weights, xs))
    swy = sum(w * y for w, y in zip(weights, ys))
    swxx = sum(w * x * x for w, x in zip(weights, xs))
    swxy = sum(w * x * y for w, x, y in zip(weights, xs, ys))
    
    denom = sw * swxx - swx * swx
    if denom == 0:
        return {"error": "Cannot compute regression (zero variance in time)"}
        
    m = (sw * swxy - swx * swy) / denom  # slope (bytes/day)
    
    current_usage = ys[-1]
    remaining = total_capacity_bytes - current_usage
    
    days_until_full = -1
    if m > 0:
        days_until_full = remaining / m
        
    usage_pct = (current_usage / total_capacity_bytes) * 100.0 if total_capacity_bytes > 0 else 0
    growth_mb_day = m / (1024 * 1024)
    
    return {
        "slope_bytes_per_day": m,
        "days_until_full": max(-1, int(days_until_full)),
        "current_usage_pct": round(usage_pct, 2),
        "growth_per_day_mb": round(growth_mb_day, 2),
        "current_usage_bytes": current_usage
    }

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(json.dumps({"error": "Usage: predict.py <data_file> <total_capacity_bytes>"}))
        sys.exit(1)
        
    data_file = sys.argv[1]
    try:
        total_capacity = float(sys.argv[2])
    except ValueError:
        print(json.dumps({"error": "Invalid capacity value"}))
        sys.exit(1)
        
    result = predict(data_file, total_capacity)
    print(json.dumps(result))
