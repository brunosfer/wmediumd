#!/bin/bash

# Author: Bruno Fernandes <bruno.fernandes@tum.de>
# Last update: 22.03.2026

# Topology: 4 nodes starting in a diamond, Node 1 and 4 flying apart.
# Node 1 (10.10.10.11) <---> Node 4 (10.10.10.14)
#
#  + ---- [2] ---- +
#  |       |       |
# [1]      |      [4]
#  |       |       |
#  + ---- [3] ---- +
#
# Understanding the m Parameter for your experiment with nakagami-m model
# When you run your tests, here is a short table on how you should tune that m value in the config file to represent different scenarios:
# Environment       | m Value        | Description
# Heavy Obstruction | 0.5 <= m < 1.0 | Severe fading, worse than Rayleigh. High packet loss.
# No Line-of-Sight  | m = 1.0        | Pure Rayleigh fading (classic urban/forest ground scenario).
# Partial LoS       | m = 1.5 - 3.0  | Typical for UAVs, mostly clear skies but some banking/antenna tilt issues.
# Strong LoS        | m > 5.0        | Clear Line of Sight between UAVs. Very stable signal.

num_nodes=4
subnet="10.10.10"
macfmt="02:00:00:00:%02x:00"

if [[ $UID -ne 0 ]]; then
    echo "Must be run as root! (sudo)"
    exit 1
fi

# --- ENSURE THE STAGE IS CLEAR ---
echo "Cleaning up..."
killall -9 wmediumd xterm iperf 2>/dev/null
for i in $(seq 1 $num_nodes); do ip netns del "node$i" 2>/dev/null; done
modprobe -r mac80211_hwsim 2>/dev/null
sleep 1
modprobe mac80211_hwsim radios=$num_nodes
sleep 1

# --- GENERATE NAKAGAMI CONFIG FILE WITH MOVEMENT ---
cat <<__EOM > nakagami_mobility_test.cfg
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
        (-10.0,  0.0, 0.0),  /* Node 1 - West */
        (  0.0,  5.0, 0.0),  /* Node 2 - North */
        (  0.0, -5.0, 0.0),  /* Node 3 - South */
        ( 10.0,  0.0, 0.0)   /* Node 4 - East */
    );

    /* Mobility: meters per MOVE_INTERVAL (1s) */
    directions = (
        (-2.0, 0.0),  /* Node 1 flies West at 2m/s */
        ( 0.0, 0.0),  /* Node 2 static */
        ( 0.0, 0.0),  /* Node 3 static */
        ( 2.0, 0.0)   /* Node 4 flies East at 2m/s */
    );

    tx_powers = (20.0, 20.0, 20.0, 20.0);
    model_name = "nakagami";
    m = 0.5;                   /* Moderate LoS */
    path_loss_exp = 2.5;       
    xg = 0.0;                  
};
__EOM

# --- NAMESPACE & PHY SETUP ---
echo "Waiting for hwsim to initialize radios..."
sleep 2 

for i in $(seq 1 $num_nodes); do
    NS="node$i"
    IP="$subnet.$((10+i))"
    TARGET_MAC=$(printf $macfmt $((i-1)))
    
    # Wait for device availability in user space
    DEV=""
    while [ -z "$DEV" ]; do
        DEV=$(ip -br link show | grep -i "$TARGET_MAC" | awk '{print $1}')
        [ -z "$DEV" ] && sleep 0.5
    done

    # Identify the phy interface
    PHY=$(iw dev "$DEV" info | grep wiphy | awk '{print "phy"$2}')

    # Create namespace and move the phy to the new namespace
    ip netns add "$NS"
    ip link set "$DEV" down
    iw phy "$PHY" set netns name "$NS"

    # Configuration
    # The use of 'mesh point' instead of 'ibss' is to purposely handling peers better
    ip netns exec "$NS" ip link set lo up
    ip netns exec "$NS" iw dev "$DEV" set type mesh
    ip netns exec "$NS" ip link set "$DEV" up
    ip netns exec "$NS" iw dev "$DEV" mesh join "MyMesh"
    ip netns exec "$NS" ip addr add "$IP/24" dev "$DEV"

    # Forcing ARP (Crucial for simulation)
    # This ensures that Node 1 knows exactly where Node 4 is avoiding to search for it.
    if [ $i -eq 1 ]; then
        # Node 1 needs to know Node 4 MAC
        TARGET_NODE_MAC=$(printf $macfmt 3)
        ip netns exec "$NS" arp -s 10.10.10.14 $TARGET_NODE_MAC
    fi
    if [ $i -eq 4 ]; then
        # Node 4 needs to know Node 1 MAC
        TARGET_NODE_MAC=$(printf $macfmt 0)
        ip netns exec "$NS" arp -s 10.10.10.11 $TARGET_NODE_MAC
    fi

    xterm -T "NODE $i ($IP)" -geometry 80x20+$(( (i-1)*300 ))+100 -e "ip netns exec $NS bash" &
done

# --- STARTING SIMULATION ---
echo "Starting wmediumd in background..."
../wmediumd/wmediumd -c nakagami_mobility.cfg > wmediumd.log 2>&1 &
WMEDIUMD_PID=$!

sleep 2

# --- AUTOMATED TEST BLOCK ---
echo "Launching Iperf Server on Node 4..."
ip netns exec node4 iperf -s > iperf_server.log 2>&1 &
SERVER_PID=$!

echo "Starting Ping and Iperf Client on Node 1..."
ip netns exec node1 ping -i 0.5 10.10.10.14 > ping_results.log 2>&1 &
PING_PID=$!

# Run the client and capture its PID
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
kill $PING_PID $SERVER_PID $WMEDIUMD_PID 2>/dev/null
sleep 1
killall -9 iperf wmediumd 2>/dev/null

echo "Launching visualization..."
# Check if the log actually has data before plotting
if [ -s iperf_client.log ]; then
    python3 plot_nakagami_test.py
else
    echo "Error: iperf_client.log is empty. Plotting skipped."
fi

echo "Done. Check .log files for results."