#!/usr/bin/env python3
"""
LinuxGuardian — Schedule Analyzer Helper
Analyzes historical CPU metrics to find optimal backup windows and detect sustained idle.
No external dependencies. Uses only Python standard library.
"""

import sys
import csv
import json
from collections import defaultdict
from datetime import datetime

def analyze(log_file):
    hourly_idle = defaultdict(list)
    try:
        with open(log_file, 'r') as f:
            reader = csv.reader(f)
            for row in reader:
                if not row or len(row) < 2:
                    continue
                try:
                    ts = int(row[0])
                    idle_cpu = float(row[1])
                    hour = datetime.fromtimestamp(ts).hour
                    hourly_idle[hour].append(idle_cpu)
                except ValueError:
                    continue
    except FileNotFoundError:
        return {"error": "Log file not found"}

    if not hourly_idle:
        return {"error": "No valid data found"}

    # Find hours with highest average idle CPU (need at least 5 samples)
    avg_by_hour = {h: sum(v)/len(v) for h, v in hourly_idle.items() if len(v) >= 5}
    
    if not avg_by_hour:
        # Fallback if not enough samples: use all available
        avg_by_hour = {h: sum(v)/len(v) for h, v in hourly_idle.items()}

    best_hours = sorted(avg_by_hour.items(), key=lambda x: -x[1])
    top_3_hours = [h for h, _ in best_hours[:3]]
    
    # Calculate a simple confidence score based on amount of data
    total_samples = sum(len(v) for v in hourly_idle.values())
    confidence = min(1.0, total_samples / 1000)

    recommendation = "Insufficient data"
    if top_3_hours:
        recommendation = f"Optimal backup window: {top_3_hours[0]:02d}:00"

    return {
        "optimal_hours": top_3_hours,
        "confidence": round(confidence, 2),
        "recommendation": recommendation
    }

def check_recent_idle(log_file, window_minutes=5, threshold=80.0):
    try:
        with open(log_file, 'r') as f:
            rows = list(csv.reader(f))
    except FileNotFoundError:
        return {"is_idle": False, "error": "Log file not found"}

    if not rows:
        return {"is_idle": False, "error": "No data"}

    recent = []
    # Read backward to get recent N samples (assuming 1 sample ~ 1 minute or similar)
    for row in reversed(rows):
        if not row or len(row) < 2:
            continue
        try:
            recent.append(float(row[1]))
            if len(recent) >= window_minutes:
                break
        except ValueError:
            continue

    if not recent:
        return {"is_idle": False, "error": "No valid recent data"}

    avg_idle = sum(recent) / len(recent)
    is_idle = avg_idle >= threshold

    return {
        "is_idle": is_idle,
        "recent_avg_idle": round(avg_idle, 2),
        "samples_checked": len(recent)
    }

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Missing log file argument"}))
        sys.exit(1)
        
    cmd = sys.argv[1]
    
    if cmd == "analyze":
        if len(sys.argv) < 3:
            print(json.dumps({"error": "Missing log file"}))
            sys.exit(1)
        print(json.dumps(analyze(sys.argv[2])))
    elif cmd == "check_idle":
        if len(sys.argv) < 3:
            print(json.dumps({"error": "Missing log file"}))
            sys.exit(1)
        window = int(sys.argv[3]) if len(sys.argv) > 3 else 5
        threshold = float(sys.argv[4]) if len(sys.argv) > 4 else 80.0
        print(json.dumps(check_recent_idle(sys.argv[2], window, threshold)))
    else:
        print(json.dumps({"error": f"Unknown command: {cmd}"}))
        sys.exit(1)
