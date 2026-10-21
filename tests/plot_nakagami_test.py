# Author: Bruno Fernandes <bruno.fernandes@tum.de>
# Last update: 17.10.2026
#
# For further details please check /wmediumd/tests/test_nakagami_mobility.sh
# This plot_nakagami_test.py evaluates and plots the log files after the test, second by second:
# * top left: the topology, Node 1 and Node 4 flying apart (mobility);
# * top right: the received signal of every broadcast frame from Node 1 at Node 4
#   (fading_frames.log): the path loss lowers it as the nodes fly apart, the fading moves every
#   single frame around it;
# * bottom left: the iperf throughput between Node 1 and Node 4;
# * bottom right: the signal difference between frames received within 0.1 s, which cancels the
#   path loss and leaves the fading, against the difference of two Nakagami-m gains.
# It prints PASS or FAIL for each fading check, saves the last frame as nakagami_test.png and the
# animation as nakagami_test.gif, and plays the animation live when a display is available.
# The exit code is 0 when all fading checks pass.

import math
import os
import re
import sys

import matplotlib
if not os.environ.get('DISPLAY'):
    matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.animation as animation
import numpy as np
from scipy import stats

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
                    # iperf switches to Kbits/sec for low rates; plot everything in Mbits/sec
                    scale = 0.001 if match.group(4) == 'Kbits' else 1.0
                    throughput.append(float(match.group(3)) * scale)
    except FileNotFoundError:
        print("Log file not found.")

    return intervals, throughput, unit


KS = np.arange(-60, 16)      # fading gains considered, whole dB
PAIR_GAP = 0.1               # [s] frames this close share the same distance (moves every 3 s)
STRONG = -72                 # [dBm] local median signal above which no fade can drop a frame
WINDOW = 0.5                 # [s] half width of the window for the local median signal


def read_m(filename='nakagami_mobility.cfg'):
    text = re.sub(r'/\*.*?\*/', '', open(filename).read(), flags=re.S)
    return float(re.search(r'\bm\s*=\s*([-\d.]+)', text).group(1))


def nakagami_pmf(m):
    """P(round(10*log10(G)) = k) for G ~ Gamma(m, 1/m): the gain in whole dB, as wmediumd draws it."""
    g = stats.gamma(a=m, scale=1.0 / m)
    pmf = np.array([g.cdf(10 ** ((k + 0.5) / 10)) - g.cdf(10 ** ((k - 0.5) / 10)) for k in KS])
    return pmf / pmf.sum()


def difference_pmf(pmf):
    """Distribution of k1 - k2 for two independent gains k1, k2 (in whole dB)."""
    diffs = np.arange(KS[0] - KS[-1], KS[-1] - KS[0] + 1)
    return diffs, np.convolve(pmf, pmf[::-1])


def read_frames(filename='fading_frames.log'):
    """Seconds since the first frame and signal [dBm] of every broadcast frame from Node 1 at Node 4."""
    rows = []
    for line in open(filename):
        ts, sig = re.match(r'(\d+\.\d+)', line), re.search(r'(-?\d+)dBm signal', line)
        if ts and sig:
            rows.append((float(ts.group(1)), int(sig.group(1))))
    rows = np.array(rows, dtype=float).reshape(-1, 2)
    if len(rows):
        rows[:, 0] -= rows[0, 0]
    return rows


def local_median(frames):
    t, sig = frames[:, 0], frames[:, 1]
    return np.array([np.median(sig[(t >= x - WINDOW) & (t <= x + WINDOW)]) for x in t])


def fading_checks(frames, median, diffs, dpmf):
    """Checks on the strong part of the run, where no fade can drop a frame."""
    t, sig = frames[:, 0], frames[:, 1]
    strong = median >= STRONG
    idx = [i for i in range(len(t) - 1)
           if strong[i] and strong[i + 1] and t[i + 1] - t[i] <= PAIR_GAP]
    d = np.array([sig[i + 1] - sig[i] for i in idx])
    n = len(d)
    pair_t = np.array([t[i + 1] for i in idx])
    if n < 100:
        return [('enough strong frame pairs', False, '%d pairs (need 100)' % n)], d, pair_t
    p_change = 1 - dpmf[diffs == 0][0]
    se = math.sqrt(p_change * (1 - p_change) / n)
    observed = np.array([np.sum(d == k) for k in diffs], dtype=float)
    expected = dpmf * n
    obs, exp, acc_o, acc_e = [], [], 0.0, 0.0      # merge bins with < 5 expected pairs
    for o, e in zip(observed, expected):
        acc_o, acc_e = acc_o + o, acc_e + e
        if acc_e >= 5:
            obs.append(acc_o); exp.append(acc_e); acc_o = acc_e = 0.0
    obs[-1] += acc_o; exp[-1] += acc_e
    p = stats.chisquare(obs, exp)[1]
    resid = sig - median
    r1 = np.corrcoef([resid[i] for i in idx], [resid[i + 1] for i in idx])[0, 1] if np.std(d) > 0 else 1.0
    return [('signal changes from frame to frame', abs(np.mean(d != 0) - p_change) < 4 * se,
             '%.0f%% of pairs differ (theory %.0f%%)' % (100 * np.mean(d != 0), 100 * p_change)),
            ('differences follow Nakagami m = %g' % M, p > 0.01, 'chi-square p = %.3f (%d pairs)' % (p, n)),
            ('consecutive frames uncorrelated', abs(r1) < 3 / math.sqrt(n), 'lag 1 r = %+.3f' % r1)], d, pair_t


# --- EVALUATION ---
M = read_m()
PMF = nakagami_pmf(M)
DIFFS, DPMF = difference_pmf(PMF)
FRAMES = read_frames()
MEDIAN = local_median(FRAMES) if len(FRAMES) else np.array([])

print('Fading per frame, broadcast frames from Node 1 at Node 4, m = %g: %d frames' % (M, len(FRAMES)))
FADING_OK = True
CHECKS, PAIR_D, PAIR_T = (fading_checks(FRAMES, MEDIAN, DIFFS, DPMF) if len(FRAMES) > 1
                          else ([('frames recorded', False, '0 frames')], np.array([]), np.array([])))
for name, passed, detail in CHECKS:
    print('  %-36s %-40s %s' % (name, detail, 'PASS' if passed else 'FAIL'))
    FADING_OK &= passed
VERDICT = 'all fading checks PASS' if FADING_OK else 'fading checks FAIL'

i_time, i_bw, i_unit = parse_iperf('iperf_client.log')

if not i_time:
    i_time = np.linspace(1, 30, 30)
    i_bw = [26.0] * 30
    i_unit = "Mbits/sec"
    print("Warning: Using fallback data. Check regex if logs are populated.")

fig = plt.figure(figsize=(15, 9.5), constrained_layout=True)
ax_topo = plt.subplot(221)
ax_sig = plt.subplot(222)
ax_perf = plt.subplot(223)
ax_hist = plt.subplot(224)


def animate(i):
    for ax in (ax_topo, ax_sig, ax_perf, ax_hist):
        ax.clear()

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

    ax_perf.set_title(f"Throughput vs. Time, Node 1 -> Node 4 (Nakagami m={M:g})")
    ax_perf.set_ylabel(i_unit) # Dynamic Label
    ax_perf.set_xlabel("Seconds")
    ax_perf.grid(True, linestyle=':')

    # Received signal of every broadcast frame from Node 1 at Node 4 up to time t
    f, med = FRAMES[FRAMES[:, 0] <= t], MEDIAN[FRAMES[:, 0] <= t]
    ax_sig.plot(f[:, 0], f[:, 1], lw=0.5, color='tab:blue', label=f"each frame ({len(f)} so far)")
    ax_sig.plot(f[:, 0], med, lw=2, color='k', label="local median (path loss)")
    ax_sig.axhline(STRONG, color='tab:red', ls='--', lw=1, label=f"checks use frames above {STRONG} dBm")
    ax_sig.set_xlim(0, 31)
    ax_sig.set_ylim(-92, -50)
    ax_sig.set_title("Received signal of each broadcast frame, Node 1 -> Node 4")
    ax_sig.set_xlabel("Seconds")
    ax_sig.set_ylabel("signal [dBm]")
    ax_sig.legend(fontsize=8, loc='upper right')
    ax_sig.grid(True, linestyle=':')

    # Signal difference of frame pairs (fading only) against theory, strong part of the run
    if len(PAIR_D):
        d = PAIR_D[PAIR_T <= t] if i < len(i_time) - 1 else PAIR_D
        ax_hist.bar(DIFFS, [np.mean(d == k) for k in DIFFS], width=0.8, color='tab:blue',
                    alpha=0.7, label=f"measured ({len(d)} frame pairs)")
    ax_hist.plot(DIFFS, DPMF, 'k.-', lw=1, label=f"Nakagami m = {M:g} (theory)")
    ax_hist.set_xlim(-20, 20)
    ax_hist.set_ylim(0, max(DPMF) * 1.5)
    ax_hist.set_title("Signal difference between frames within 0.1 s (fading only)"
                      + (f": {VERDICT}" if i == len(i_time) - 1 else ""))
    ax_hist.set_xlabel("difference [dB]")
    ax_hist.set_ylabel("share of frame pairs")
    ax_hist.legend(fontsize=8, loc='upper left')


fig.suptitle(f"Test Nakagami-m (m = {M:g})")
ani = animation.FuncAnimation(fig, animate, frames=len(i_time), interval=200, repeat=False)
ani.save('nakagami_test.gif', writer=animation.PillowWriter(fps=5))
animate(len(i_time) - 1)
fig.savefig('nakagami_test.png', dpi=100)
print('Saved nakagami_test.png and nakagami_test.gif')

if os.environ.get('DISPLAY'):
    ani = animation.FuncAnimation(fig, animate, frames=len(i_time), interval=200, repeat=False)
    plt.show()

sys.exit(0 if FADING_OK else 1)
