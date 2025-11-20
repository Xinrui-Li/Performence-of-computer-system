#!/bin/bash

# Check and install required Python libraries
check_and_install_python_libs() {
    echo "=== Checking Python Dependencies ==="
    if ! command -v pip3 &> /dev/null; then
        echo "pip3 not found, installing python3-pip..."
        sudo apt-get update && sudo apt-get install -y python3-pip
    fi

    required_libs=("scipy" "pandas" "numpy")
    for lib in "${required_libs[@]}"; do
        if ! python3 -c "import $lib" &> /dev/null; then
            echo "$lib not found, installing..."
            pip3 install $lib --quiet
        else
            echo "$lib installed"
        fi
    done
}

check_and_install_python_libs

if [ $# -ne 3 ] || [ "$1" != "all" ] || [ "$2" != "RED" ] || [ "$3" -ne 5 ]; then
    echo "Usage: $0 all RED 5"
    exit 1
fi

QUEUE="RED"
NUM_RUNS="$3"
ALGOS=("cubic" "reno" "vegas" "yeah")
BANDWIDTH="1000Mb"

echo "=== Starting ${NUM_RUNS} Repeated Experiments for All Four Algorithms with RED Queue ==="
for ((run=1; run<=NUM_RUNS; run++)); do
    echo -e "\n--- Run ${run}/${NUM_RUNS} ---"
    
    SEED=$(( $(date +%s) + run * 1000 ))
    echo "Shared Random Seed for This Run: ${SEED}"
    
    for ALGO in "${ALGOS[@]}"; do
        echo -e "\n===== Processing Algorithm: ${ALGO} ====="
        SCENARIO="${ALGO}_${QUEUE}"
        OUT_DIR="repeat_runs_${SCENARIO}_${NUM_RUNS}times"
        RUN_LOG="${OUT_DIR}/run_logs"
        RESULTS_CSV="${OUT_DIR}/${SCENARIO}_runs_summary.csv"
        mkdir -p "${OUT_DIR}" "${RUN_LOG}"

        if [ $run -eq 1 ]; then
            echo "run_id,throughput_Mbps,plr_pct,cov_stability,jain_fairness" > "${RESULTS_CSV}"
        fi

        TCL_SCRIPT="${ALGO}Code_${QUEUE}.tcl"
        if [ ! -f "${TCL_SCRIPT}" ]; then
            echo "Error: Script ${TCL_SCRIPT} not found, skipping ${ALGO} for this run"
            continue
        fi

        if [ ! -f "${TCL_SCRIPT}.bak" ]; then
            cp "${TCL_SCRIPT}" "${TCL_SCRIPT}.bak"
            echo "Backed up original script as ${TCL_SCRIPT}.bak"
        fi

        sed -i "s/^set bw.*/set bw \"${BANDWIDTH}\"/" "${TCL_SCRIPT}"
        sed -i "s/DropTail/${QUEUE}/g" "${TCL_SCRIPT}"
        sed -i "s/^set seed.*/set seed ${SEED}/" "${TCL_SCRIPT}"

        echo "Running Simulation for ${ALGO}: ns ${TCL_SCRIPT}"
        SEED=${SEED} ns "${TCL_SCRIPT}" > "${RUN_LOG}/run_${run}_${ALGO}_sim.log" 2>&1
        if [ $? -ne 0 ]; then
            echo "Warning: ${ALGO} Run ${run} simulation failed, log: ${RUN_LOG}/run_${run}_${ALGO}_sim.log"
            continue
        fi

        TRACE_FILE=$(find . -maxdepth 1 -type f -name "*${ALGO}*.tr" | sort -r | head -n 1)
        if [ -z "${TRACE_FILE}" ]; then
            echo "Warning: No trace file generated for ${ALGO} Run ${run}, skipping analysis"
            continue
        fi
        TRACE_DEST="${OUT_DIR}/${SCENARIO}_run${run}.tr"
        mv "${TRACE_FILE}" "${TRACE_DEST}"
        echo "Trace file for ${ALGO} saved to: ${TRACE_DEST}"

        echo "Analyzing ${ALGO} Run ${run} Results..."
        ANALYSIS_DIR="${OUT_DIR}/run${run}_analysis"
        mkdir -p "${ANALYSIS_DIR}"
        python3 analyser3.py "${TRACE_DEST}" "${ANALYSIS_DIR}" > "${RUN_LOG}/run_${run}_${ALGO}_analysis.log" 2>&1

        SUMMARY_CSV="${ANALYSIS_DIR}/algo_summary.csv"
        if [ -f "${SUMMARY_CSV}" ]; then
            line=$(grep "${ALGO}" "${SUMMARY_CSV}")
            if [ -n "$line" ]; then
                THROUGHPUT=$(echo "$line" | cut -d',' -f2)
                PLR=$(echo "$line" | cut -d',' -f3)
                COV=$(echo "$line" | cut -d',' -f4)
                JAIN=$(echo "$line" | cut -d',' -f5)
                echo "${run},${THROUGHPUT},${PLR},${COV},${JAIN}" >> "${RESULTS_CSV}"
                echo "${ALGO} Run ${run} Metrics: Throughput=${THROUGHPUT} Mb/s, PLR=${PLR}%, CoV=${COV}, Jain=${JAIN}"
            else
                echo "Warning: No metric row found for ${ALGO}"
            fi
        else
            echo "Warning: ${ALGO} Run ${run} analysis failed, ${SUMMARY_CSV} not found"
        fi
    done
done

# 恢复所有TCL脚本
for ALGO in "${ALGOS[@]}"; do
    TCL_SCRIPT="${ALGO}Code_${QUEUE}.tcl"
    if [ -f "${TCL_SCRIPT}.bak" ]; then
        mv "${TCL_SCRIPT}.bak" "${TCL_SCRIPT}"
    fi
done
echo -e "\nRestored All Original TCL Scripts"

echo -e "\n=== Calculating Statistical Results for Each Algorithm ==="
for ALGO in "${ALGOS[@]}"; do
    SCENARIO="${ALGO}_${QUEUE}"
    OUT_DIR="repeat_runs_${SCENARIO}_${NUM_RUNS}times"
    RESULTS_CSV="${OUT_DIR}/${SCENARIO}_runs_summary.csv"
    if [ -f "${RESULTS_CSV}" ]; then
        python3 - <<END
import pandas as pd
import scipy.stats as stats
import numpy as np

ALGO = "${ALGO}"
NUM_RUNS = int('${NUM_RUNS}')
RESULTS_CSV = '${RESULTS_CSV}'
OUT_DIR = '${OUT_DIR}'

df = pd.read_csv(RESULTS_CSV)
valid_runs = len(df.dropna())
print(f"\n===== Statistical Results for {ALGO} =====")
print(f"Valid Runs: {valid_runs}/{NUM_RUNS}")

if valid_runs < 2:
    print("Warning: Insufficient valid runs to calculate confidence intervals")
else:
    metrics = {
        "throughput_Mbps": "Throughput (Mb/s)",
        "plr_pct": "Packet Loss Rate (%)",
        "cov_stability": "Stability CoV (Lower is Better)",
        "jain_fairness": "Jain Fairness"
    }
    with open(f"{OUT_DIR}/summary_stats.csv", "w") as f:
        f.write("metric,mean,ci_lower,ci_upper\n")
        for col, name in metrics.items():
            data = df[col].dropna()
            mean = data.mean().round(4)
            std = data.std()
            if std == 0:
                ci_lower = mean
                ci_upper = mean
            else:
                ci = stats.t.interval(0.95, len(data)-1, loc=mean, scale=stats.sem(data))
                ci_lower = round(ci[0], 4)
                ci_upper = round(ci[1], 4)
            f.write(f"{col},{mean},{ci_lower},{ci_upper}\n")
            print(f"{name}:")
            print(f"  Mean: {mean}")
            print(f"  95% CI: [{ci_lower}, {ci_upper}]")
    print(f"Statistical Results Saved to: {OUT_DIR}/summary_stats.csv")
END
    else
        echo "Warning: No results CSV found for ${ALGO}, skipping statistical analysis"
    fi
done

echo -e "\n=== All Experiments Completed ==="
