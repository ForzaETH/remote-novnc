#! /bin/bash

USER_ID="${USER_ID:-$(id -u)}"
if [[ "$(uname)" == "Darwin" ]]; then
    PORT=$((20000 + USER_ID))

    ports=(6000 10000 20000)
    args=()
    for port in "${ports[@]}"; do
        PORTU=$((port + USER_ID))
        args+=("-p" "$PORTU:$PORTU")
    done

    echo "Running on macOS, starting with Docker"
    echo "You can access it under http://$(hostname):$PORT/vnc.html"
    docker run --rm "${args[@]}" -e USER_ID=$USER_ID --name novnc novnc:latest
    exit 1
fi

# Get resolution from the first CLI argument, default to 1920x1080
RESOLUTION="${1:-1920x1080}"

if [ -f /.dockerenv ]; then
    DOCKER=true
else
    DOCKER=false
fi
# Get hostname one-liner :D
# - Grabs default route interface (eg. eno1)
# - Fetches the IP of the interface 192.168.x.x
# - uses nslookup to check what the NAC entry for that IP is on the network
# - Filter out stupid dot at the end
HOSTNAME=$(nslookup $(ip route show default | awk '{print $5}' | xargs -I {} ip addr show {} | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 | head -n 1)  | grep -w 'name' | awk '{print $4}' | sed 's/\.$//')


if [ -z "$HOSTNAME" ]; then
    HOSTNAME=$(hostname)
fi

# Adjust DISPLAY and VNC_PORT based on USER_ID
export DISPLAY_NUM="$((1 + (USER_ID % 16)))"   # DISPLAY will be USER_ID % 16
export DISPLAY=":$USER_ID"
export VNC_PORT=$((10000 + USER_ID)) # VNC_PORT will be 10000 + USER_ID
export NOVNC_PORT=$((20000 + USER_ID)) # VNC_PORT will be 20000 + USER_ID

# Kill any lingering processes from before
pkill -u $USER_ID Xvfb
pkill -u $USER_ID xfce4-session
pkill -u $USER_ID websockify
pkill -u $USER_ID x11vnc

trap 'kill 0' SIGINT

if $DOCKER; then
    echo "Starting DISPLAY=$DISPLAY"
else
    echo "Starting DISPLAY=$DISPLAY VNC on http://$HOSTNAME:$NOVNC_PORT/vnc.html"
fi

# Create new virtual frame buffer
Xvfb $DISPLAY -screen 0 ${RESOLUTION}x24 -listen tcp -ac &>> xvfb.log &
XVFB_PID=$!

# Wait briefly to let it initialize
sleep 1

# Check if Xvfb is still running (i.e., it didn't crash)
if ! kill -0 $XVFB_PID 2>/dev/null; then
    echo "❌ Failed to start Xvfb on display $DISPLAY"
    exit 1
fi

# Start the XFCE4 session
echo "Starting XFCE4"
xfce4-session &>> xfce.log &

if $DOCKER; then
    # Wait briefly to let it initialize
    sleep 5
        # Disable screensaver
    xfconf-query -c xfce4-screensaver -p /saver/enabled --create -t bool -s false || true

    # Disable lock screen
    xfconf-query -c xfce4-screensaver -p /lock/enabled --create -t bool -s false || true
    xfconf-query -c xfce4-session -p /shutdown/LockScreen --create -t bool -s false || true

    # Disable DPMS and screen blanking
    xset s off || true
    xset -dpms || true
    xset s noblank || true

    # Set wallpaper
    WALLPAPER=/usr/share/backgrounds/wallpaper.png
    if [ -f "$WALLPAPER" ]; then
        for prop in $(xfconf-query -c xfce4-desktop -l | grep 'last-image$'); do
            xfconf-query -c xfce4-desktop -p "$prop" -s "$WALLPAPER" || true
        done
    fi

    echo "[INFO] XFCE screensaver and lock screen disabled."
fi

# Start the X11 VNC
echo "Starting X11"
if $DOCKER; then
    x11vnc -display $DISPLAY -forever -shared -rfbport $VNC_PORT &>> x11.log &
else 
    x11vnc -display $DISPLAY -forever -shared -rfbport $VNC_PORT -usepw &>> x11.log &
fi

# Start the webserver
echo "Starting Webserver"
websockify --web /usr/share/novnc $NOVNC_PORT localhost:$VNC_PORT &>> websockify.log &

wait


