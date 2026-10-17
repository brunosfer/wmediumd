#!/bin/bash

# Author: Bruno Fernandes <bruno.fernandes@tum.de>
# Last update: 17.10.2026

# Topology: 4 nodes starting in a diamond, Node 1 and 4 flying apart.
# Node 1 (10.10.10.11) <---> Node 4 (10.10.10.14)
#
#  + ---- [2] ---- +
#  |       |       |
# [1]      |      [4]
#  |       |       |
#  + ---- [3] ---- +
#
# This test validates the Nakagami-m fading model under mobility, in three parts:
#
# 1. Configuration: wmediumd must load an integer m ("m = 3;") and must refuse to start with
#    m < 0.5 or without m.
# 2. Fading per frame from Node 1 to Node 4: Node 1 sends broadcast pings (fixed multicast rate)
#    and a monitor interface on Node 4 records the received signal of every frame that reaches it
#    directly (fading_frames.log). Two frames received within 0.1 s share the same distance, so
#    the difference of their signals cancels the path loss and leaves the difference of two
#    fading gains. While the mean signal stays strong (no fade can drop a frame), the plot script
#    checks that the signal changes from frame to frame, that these differences follow the
#    difference of two independent round(10*log10(G)) with G ~ Gamma(m, 1/m) (chi-square goodness
#    of fit), and that the fading of consecutive frames is uncorrelated. It prints PASS or FAIL
#    for each check.
# 3. Mobility: Node 1 and Node 4 fly apart while iperf (iperf_client.log) and ping
#    (ping_results.log) run between them. The per frame fading appears as single lost pings and a
#    wider RTT spread on top of the deterministic SNR decline; the per second iperf throughput
#    averages it out.
#
# plot_nakagami_test.py animates the topology, the throughput, the signal of every broadcast frame
# from Node 1 at Node 4 and the fading distribution second by second, saves the last frame as nakagami_test.png and the
# animation as nakagami_test.gif, and plays it live when a display is available.
#
# Usage: make && cd tests && sudo DISPLAY=$DISPLAY ./test_nakagami_mobility.sh
#        (without DISPLAY the test runs headless and only writes the image files)
# Requires: iw, iperf, tcpdump, xterm (optional), python3 with matplotlib, numpy and scipy.
#
# Understanding the m Parameter for your experiment with nakagami-m model
# When you run your tests, here is a short table on how you should tune that m value in
# the config file to represent different scenarios:
#
# Environment       | m Value        | Description
# Heavy Obstruction | 0.5 <= m < 1.0 | Severe fading, worse than Rayleigh. High packet loss.
# No Line-of-Sight  | m = 1.0        | Pure Rayleigh fading (classic urban/forest ground scenario).
# Partial LoS       | m = 1.5 - 3.0  | Typical for UAVs, mostly clear skies but some banking/antenna tilt issues.
# Strong LoS        | m > 5.0        | Clear Line of Sight between UAVs. Very stable signal.
#
# Quick reminder on the path_loss_exp for reference:
# 2.0 - 2.5 | Free space / outdoor LoS
# 2.5 - 3.5 | Suburban / light obstruction
# 3.5 - 4.0 | Dense urban  (recommended range for visible fading without link collapse)
# 4.5+      | Heavy obstruction (risks sustained TCP stall across a 30s test)
#
# MOVE_INTERVAL = 3s (wmediumd constant). Direction values are meters per interval (e.g. 3.0 = 1 m/s).

num_nodes=4
subnet="10.10.10"
macfmt="02:00:00:00:%02x:00"

# --- PREREQUISITE CHECK ---
if [[ $UID -ne 0 ]]; then
    echo "Must be run as root! (sudo)"
    exit 1
fi

# --- CLEANUP FUNCTION IN CASE OF INTERRUPTION ---
_cleanup() {
    echo "Interrupted, cleaning up..."
    kill $PING_PID $SERVER_PID $CLIENT_PID $WMEDIUMD_PID $BCAST_PID $CAP_PID 2>/dev/null
    sleep 1
    killall -9 iperf wmediumd tcpdump 2>/dev/null
    for ns in $(ip netns list | awk '{print $1}'); do
        ip netns del "$ns" 2>/dev/null
    done
    modprobe -r mac80211_hwsim 2>/dev/null
}
trap _cleanup INT TERM HUP

# --- ENSURE THE STAGE IS CLEAR ---
echo "Preparing the environment for testing..."
killall -9 wmediumd xterm iperf 2>/dev/null
# Remove any 'zombie' namespaces
for ns in $(ip netns list | awk '{print $1}'); do
    ip netns exec "$ns" ip link set lo down 2>/dev/null
    ip netns del "$ns" 2>/dev/null
done
# Specific to clean up the directory where WSL2 locks namespaces
rm -rf /var/run/netns/* 2>/dev/null

# Reload the wireless stack so each run starts from a clean kernel state.
modprobe -r mac80211_hwsim 2>/dev/null
modprobe -r mac80211 2>/dev/null
modprobe -r cfg80211 2>/dev/null
sleep 2

echo "Waiting for virtual radios to initialize..."
modprobe cfg80211
modprobe mac80211_hwsim radios=$num_nodes
sleep 2
timeout=10
count=0
while ! iw dev | grep -q "wlan3"; do
    sleep 0.5
    count=$((count+1))
    if [ $count -ge $((timeout*2)) ]; then
        echo "Error: Radios failed to initialize after ${timeout}s"
        exit 1
    fi
done

# Ensure interfaces are in a known state (usually DOWN for wmediumd)
ip link set wlan0 down
ip link set wlan1 down
ip link set wlan2 down
ip link set wlan3 down

echo "Radios ready."

# --- PART 1: CONFIGURATION CHECKS ---
# wmediumd parses the configuration before it starts; a refused configuration exits at once.
CONFIG_OK=1
_config_check() {   # $1 = description, $2 = m line, $3 = expect "start" or "refuse"
    cat <<__EOM > nakagami_config_check.cfg
ifaces : { ids = [ "02:00:00:00:00:00", "02:00:00:00:01:00" ]; };
model : { type = "path_loss"; positions = ( (0.0, 0.0, 0.0), (10.0, 0.0, 0.0) );
          tx_powers = (20.0, 20.0); model_name = "nakagami"; $2 path_loss_exp = 4; xg = 0; };
__EOM
    timeout 2 ../wmediumd/wmediumd -c nakagami_config_check.cfg > nakagami_config_check.log 2>&1
    local rc=$? got
    [ $rc -eq 124 ] && got=start || got=refuse
    # a start that only works by ignoring m (older versions fell back to m = 1.0) is not a start
    grep -q "m parameter not found" nakagami_config_check.log && got="start with m ignored"
    if [ "$got" = "$3" ]; then
        echo "  config: $1 -> $got  PASS"
    else
        echo "  config: $1 -> $got (expected $3)  FAIL"; CONFIG_OK=0
    fi
    grep -h "Nakagami" nakagami_config_check.log | sed 's/^/    wmediumd: /'
}
echo "Checking the Nakagami configuration parsing..."
_config_check "integer m (m = 3;)" "m = 3;" start
_config_check "m below 0.5 (m = 0.3;)" "m = 0.3;" refuse
_config_check "missing m" "" refuse
rm -f nakagami_config_check.cfg nakagami_config_check.log

# --- GENERATE NAKAGAMI CONFIG FILE WITH MOVEMENT ---
cat <<__EOM > nakagami_mobility.cfg
ifaces :
{
    ids = [
        "02:00:00:00:00:00",
        "02:00:00:00:01:00",
        "02:00:00:00:02:00",
        "02:00:00:00:03:00"
    ];
};

model :
{
    type = "path_loss";
    positions = (
        (-10.0,  0.0, 0.0),  /* Node 1 - West  */
        (  0.0,  5.0, 0.0),  /* Node 2 - North */
        (  0.0, -5.0, 0.0),  /* Node 3 - South */
        ( 10.0,  0.0, 0.0)   /* Node 4 - East  */
    );

    /* Mobility: 1 m/s. Multi-hop distance increases from ~11 m to ~40 m over 30 s */
    directions = (
        (-3.0, 0.0),  /* Node 1 flies West  at 1 m/s */
        ( 0.0, 0.0),  /* Node 2 static               */
        ( 0.0, 0.0),  /* Node 3 static               */
        ( 3.0, 0.0)   /* Node 4 flies East  at 1 m/s */
    );

    tx_powers = (20.0, 20.0, 20.0, 20.0);
    model_name = "nakagami";
    m = 1.5;             /* Partial LoS (Typical UAV fading) Deep-fade probability ~15% */
    path_loss_exp = 4.0; /* Dense urban; SNR ~39 dB (t=0s) -> ~17 dB (t=30s)            */
    xg = 0.0;
};
__EOM


# Force regulatory domain so the 20 dBm TX power configured above is permitted on 2.4 GHz.
iw reg set US
sleep 1

# --- NAMESPACE & PHY SETUP (STEP 1) ---
# Move each PHY to its namespace and configure the interface type, while keeping interfaces DOWN.
echo "Setting up network namespaces..."
declare -A NODE_DEVS NODE_PHYS
for i in $(seq 1 $num_nodes); do
    NS="node$i"
    TARGET_MAC=$(printf $macfmt $((i-1)))

    DEV=""
    while [ -z "$DEV" ]; do
        DEV=$(ip -br link show | grep -i "$TARGET_MAC" | awk '{print $1}')
        [ -z "$DEV" ] && sleep 0.5
    done
    NODE_DEVS[$i]=$DEV

    PHY=$(iw dev "$DEV" info | grep wiphy | awk '{print "phy"$2}')
    NODE_PHYS[$i]=$PHY
    ip netns add "$NS"
    ip link set "$DEV" down
    iw phy "$PHY" set netns name "$NS"
    # IBSS (Ad-Hoc): no L2 routing protocol overhead; compatible with WSL2.
    ip netns exec "$NS" ip link set lo up
    ip netns exec "$NS" iw dev "$DEV" set type ibss
done

# --- STARTING SIMULATION ---
echo "Starting wmediumd in background..."
../wmediumd/wmediumd -c nakagami_mobility.cfg > wmediumd.log 2>&1 &
WMEDIUMD_PID=$!

echo "Waiting for wmediumd to initialize..."
timeout=10
count=0
while ! grep -q "Added station 3" wmediumd.log 2>/dev/null; do
    sleep 0.1
    count=$((count+1))
    if ! kill -0 $WMEDIUMD_PID 2>/dev/null; then
        echo "Error: wmediumd terminated unexpectedly"
        cat wmediumd.log >&2
        exit 1
    fi
    if [ $count -ge $((timeout*10)) ]; then
        echo "Error: wmediumd failed to initialize after ${timeout}s"
        exit 1
    fi
done

# --- NAMESPACE & PHY SETUP (STEP 2) ---
# Now that wmediumd is registered, we bring the interfaces up and join IBSS.
echo "Joining IBSS network..."
JOIN_PIDS=()
for i in $(seq 1 $num_nodes); do
    NS="node$i"
    IP="$subnet.$((10+i))"
    DEV=${NODE_DEVS[$i]}
    BSSID="02:00:00:00:00:A1"

    {
        ip netns exec "$NS" ip link set "$DEV" up
        # fixed-freq + fixed BSSID: keeps all nodes in one IBSS cell even when Node1/4 lose direct range.
        # NOHT: 802.11g-only rates for predictable minstrel_ht behaviour, specially in WSL2.
        ip netns exec "$NS" iw dev "$DEV" ibss join "Adhoc" 2412 NOHT fixed-freq $BSSID basic-rates 6,12,24 mcast-rate 6
        ip netns exec "$NS" ip addr add "$IP/24" dev "$DEV"
        ip netns exec "$NS" sysctl -wq net.ipv4.ip_forward=1
    } &
    JOIN_PIDS+=($!)

    xterm -fn fixed -T "NODE $i ($IP)" -geometry 80x20+$(( (i-1)*300 ))+100 -e "ip netns exec $NS bash" &
done
for pid in "${JOIN_PIDS[@]}"; do wait "$pid"; done

# --- WEIGHTED STATIC MULTI-HOP ROUTES ---
# Static ARP entries prevent ARP broadcasts from failing across the multi-hop paths.
echo "Configuring weighted routes (Node 1 <-> Node 2/3 <-> Node 4)..."
MAC1=$(printf $macfmt 0)
MAC2=$(printf $macfmt 1)
MAC3=$(printf $macfmt 2)
MAC4=$(printf $macfmt 3)

# Node 1: Primary path via Node 2 (metric 100), Secondary via Node 3 (metric 200)
ip netns exec node1 ip route add 10.10.10.14 via 10.10.10.12 metric 100
ip netns exec node1 ip route add 10.10.10.14 via 10.10.10.13 metric 200

# Node 4: Primary path via Node 2 (metric 100), Secondary via Node 3 (metric 200)
ip netns exec node4 ip route add 10.10.10.11 via 10.10.10.12 metric 100
ip netns exec node4 ip route add 10.10.10.11 via 10.10.10.13 metric 200

# Neighbor ARPs (Direct links only)
ip netns exec node1 arp -s 10.10.10.12 $MAC2
ip netns exec node1 arp -s 10.10.10.13 $MAC3
ip netns exec node2 arp -s 10.10.10.11 $MAC1
ip netns exec node2 arp -s 10.10.10.14 $MAC4
ip netns exec node3 arp -s 10.10.10.11 $MAC1
ip netns exec node3 arp -s 10.10.10.14 $MAC4
ip netns exec node4 arp -s 10.10.10.12 $MAC2
ip netns exec node4 arp -s 10.10.10.13 $MAC3

# --- AUTOMATED TEST BLOCK ---
# The iperf measures sustained TCP throughput over 30s, capturing the combined
# effect of increasing path loss and Nakagami fading on application layer performance.
# The ping runs concurrently to track packet RTT and loss independently of TCP,
# distinguishing between fading induced loss and TCP congestion backoff.
echo "Launching Iperf Server on Node 4..."
ip netns exec node4 iperf -s > iperf_server.log 2>&1 &
SERVER_PID=$!

echo "Starting Ping and Iperf Client on Node 1..."
ip netns exec node1 ping -i 0.5 10.10.10.14 > ping_results.log 2>&1 &
PING_PID=$!

# Part 2: broadcast frames from Node 1, recorded on a monitor interface of Node 4.
echo "Recording the received signal of every broadcast frame from Node 1 at Node 4..."
ip netns exec node4 iw phy "${NODE_PHYS[4]}" interface add mon0 type monitor
ip netns exec node4 ip link set mon0 up
ip netns exec node4 tcpdump -tt -i mon0 -e -nn -l "wlan addr2 $MAC1 and type data and wlan addr1 ff:ff:ff:ff:ff:ff" \
    2>/dev/null > fading_frames.log &
CAP_PID=$!
ip netns exec node1 ping -b -q -i 0.01 -w 30 10.10.10.255 >/dev/null 2>&1 &
BCAST_PID=$!

ip netns exec node1 iperf -c 10.10.10.14 -t 30 -i 1 > iperf_client.log 2>&1 &
CLIENT_PID=$!

echo "--------------------------------------------------"
echo "SIMULATION RUNNING (30 Seconds)"
echo "Wait for the plot showing the results"
echo "--------------------------------------------------"

# Wait specifically for the client to finish 30 seconds of work
wait $CLIENT_PID 2>/dev/null

# --- POST-PROCESSING & CLEANUP ---
echo "Simulation finished. Closing log files..."

# Killing remaining background tasks. Soft kill first, Hard kill if soft didn't work
kill $PING_PID $SERVER_PID $WMEDIUMD_PID $BCAST_PID 2>/dev/null
pkill -f "tcpdump -i mon0" 2>/dev/null
sleep 1
killall -9 iperf wmediumd tcpdump 2>/dev/null
for ns in $(ip netns list | awk '{print $1}'); do
    ip netns del "$ns" 2>/dev/null
done
modprobe -r mac80211_hwsim 2>/dev/null

echo "Launching visualization..."
# Check if the log actually has data before plotting
if [ -s iperf_client.log ]; then
    python3 plot_nakagami_test.py
    PLOT_OK=$?
else
    echo "Error: iperf_client.log is empty. Plotting skipped."
    PLOT_OK=1
fi

echo "Done. Check .log files for results."
if [ $CONFIG_OK -eq 1 ] && [ $PLOT_OK -eq 0 ]; then
    echo "TEST RESULT: PASS"
else
    echo "TEST RESULT: FAIL"
    exit 1
fi
