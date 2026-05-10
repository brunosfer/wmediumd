# Author: Bruno Fernandes <bruno.fernandes@tum.de>
# Last update: 10.05.2026
#
# For further details please check /wmediumd/tests/test_nakagami_mobility.sh
# This plot_nakagami_test.py is for the sole purpose of printing out the log files after the test.

import matplotlib.pyplot as plt
import matplotlib.animation as animation
import re
import numpy as np

IPS = ["10.10.10.11", "10.10.10.12", "10.10.10.13", "10.10.10.14"]

def parse_iperf(filename):
    intervals, throughput = [], []
    unit = "Mbits/sec"

    pattern = re.compile(r'\]\s+(\d+\.\d+)-\s*(\d+\.\d+)\s+sec\s+[\d.]+\s+[KMG]Bytes\s+([\d.]+)\s+([KM]bits)/sec')

    try:
        with open(filename, 'r') as f:
            for line in f:
                # Skip the summary line at the very end
                if "0.0000-" in line and float(line.split('-')[1].split()[0]) > 29.5:
                    if len(intervals) > 5: continue

                match = pattern.search(line)
                if match:
                    intervals.append(float(match.group(2)))
                    throughput.append(float(match.group(3)))
                    unit = f"{match.group(4)}/sec"
    except FileNotFoundError:
        print("Log file not found.")

    return intervals, throughput, unit

i_time, i_bw, i_unit = parse_iperf('iperf_client.log')

if not i_time:
    i_time = np.linspace(1, 30, 30)
    i_bw = [26.0] * 30
    i_unit = "Mbits/sec"
    print("Warning: Using fallback data. Check regex if logs are populated.")

fig = plt.figure(figsize=(10, 8))
ax_topo = plt.subplot(211)
ax_perf = plt.subplot(212)

def animate(i):
    ax_topo.clear()
    ax_perf.clear()

    t = i_time[i]

    # Coordinates (Diamond moves based on 1m/s velocity)
    n1 = [-10 - t, 0]
    n2 = [0, 5]
    n3 = [0, -5]
    n4 = [10 + t, 0]
    pos = np.array([n1, n2, n3, n4])

    # Plot Nodes
    ax_topo.scatter(pos[:,0], pos[:,1], s=200, c=['#ff7f0e', '#1f77b4', '#1f77b4', '#2ca02c'])

    # Draw Mesh Connections
    links = [[0,1], [0,2], [1,3], [2,3]]
    for l in links:
        ax_topo.plot([pos[l[0],0], pos[l[1],0]], [pos[l[0],1], pos[l[1],1]], 'k--', alpha=0.3)

    # Labels Node IPs
    for j in range(4):
        label = f"Node {j+1}\n({IPS[j]})"
        ax_topo.annotate(label, (pos[j,0], pos[j,1]), textcoords="offset points", xytext=(0,10), ha='center')

    ax_topo.set_title(f"Simulation Topology | Time: {t:.1f}s | Distance 1-4: {20+(2*t):.1f}m")
    ax_topo.set_xlim(-50, 50)
    ax_topo.set_ylim(-15, 15)
    ax_topo.set_xlabel("X (meters)")
    ax_topo.grid(True, alpha=0.2)

    # Plot Performance (Dynamic Scale)
    ax_perf.plot(i_time[:i+1], i_bw[:i+1], color='green', linewidth=2, marker='o', markersize=4)
    ax_perf.set_xlim(0, 31)

    # Dynamic Y-Limit: Adds 20% padding to the highest recorded value
    y_limit = max(i_bw) * 1.2 if i_bw else 40
    ax_perf.set_ylim(0, y_limit)

    ax_perf.set_title(f"Throughput vs. Time (Nakagami m=1.5)")
    ax_perf.set_ylabel(i_unit) # Dynamic Label
    ax_perf.set_xlabel("Seconds")
    ax_perf.grid(True, linestyle=':')

ani = animation.FuncAnimation(fig, animate, frames=len(i_time), interval=200, repeat=False)
plt.tight_layout()
plt.show()
