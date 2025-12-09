#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# install_unitree_beyondmimic.sh
# Installs legged_control2 + Unitree packages + builds
# the motion_tracking_controller (BeyondMimic inference controller).
# Target: Ubuntu + ROS 2 Humble
# ------------------------------------------------------------------

# Basic checks
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run as: sudo $0"
  exit 1
fi

ROS_DISTRO="${ROS_DISTRO:-humble}"
if [[ "$ROS_DISTRO" != "humble" ]]; then
  echo "❌ Script intended for ROS 2 Humble. Detected: $ROS_DISTRO"
  exit 1
fi
echo "➡️ Using ROS_DISTRO=$ROS_DISTRO"

# Helpful vars
SUDO_USER="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
USER_HOME="/home/$SUDO_USER"
COLCON_WS="${COLCON_WS:-$USER_HOME/colcon_ws}"
CONDA_ENV_NAME="isaacLab"

# -------------------------------
# 0. Install core APT packages
# -------------------------------
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl wget gnupg lsb-release \
  build-essential git cmake pkg-config python3-pip python3-venv \
  python3-colcon-common-extensions python3-vcstool python3-rosdep \
  python3-rosinstall-generator python3-osrf-pycommon

# -------------------------------
# 1. Add Qiayuan buildfarm repos
# -------------------------------
echo "➡️ Adding Qiayuan buildfarm repositories..."
cat <<EOF > /etc/apt/sources.list.d/qiayuanl_legged_buildfarm.list
deb [trusted=yes] https://github.com/qiayuanl/legged_buildfarm/raw/jammy-humble-amd64/ ./
EOF
cat <<EOF > /etc/ros/rosdep/sources.list.d/1-qiayuanl_legged_buildfarm.list
yaml https://github.com/qiayuanl/legged_buildfarm/raw/jammy-humble-amd64/local.yaml humble
EOF

cat <<EOF > /etc/apt/sources.list.d/qiayuanl_simulation_buildfarm.list
deb [trusted=yes] https://github.com/qiayuanl/simulation_buildfarm/raw/jammy-humble-amd64/ ./
EOF
cat <<EOF > /etc/ros/rosdep/sources.list.d/1-qiayuanl_simulation_buildfarm.list
yaml https://github.com/qiayuanl/simulation_buildfarm/raw/jammy-humble-amd64/local.yaml humble
EOF

cat <<EOF > /etc/apt/sources.list.d/qiayuanl_unitree_buildfarm.list
deb [trusted=yes] https://github.com/qiayuanl/unitree_buildfarm/raw/jammy-humble-amd64/ ./
EOF
cat <<EOF > /etc/ros/rosdep/sources.list.d/1-qiayuanl_unitree_buildfarm.list
yaml https://github.com/qiayuanl/unitree_buildfarm/raw/jammy-humble-amd64/local.yaml humble
EOF

apt-get update

# -------------------------------
# 2. Install Unitree + Legged packages (force reinstall if version mismatch)
# -------------------------------
echo "➡️ Installing ros-humble-unitree-sdk2-ament (force reinstall if needed)..."

# Get installed version (empty if not installed)
INSTALLED_VER=$(dpkg -s ros-humble-unitree-sdk2-ament 2>/dev/null | grep '^Version:' | awk '{print $2}' || true)
# Get candidate version from apt
CANDIDATE_VER=$(apt-cache policy ros-humble-unitree-sdk2-ament | grep 'Candidate:' | awk '{print $2}' || true)

if [ "$INSTALLED_VER" != "$CANDIDATE_VER" ]; then
  echo "⚠️ Installed version ($INSTALLED_VER) differs from candidate ($CANDIDATE_VER) → reinstalling..."
  
  # Download the .deb first
  apt-get download ros-humble-unitree-sdk2-ament

  DEB_FILE=$(ls ros-humble-unitree-sdk2-ament_0-*.deb 2>/dev/null || \
             ls /var/cache/apt/archives/ros-humble-unitree-sdk2-ament_0-*.deb 2>/dev/null || true)

  if [ -z "$DEB_FILE" ]; then
    echo "❌ Could not find downloaded .deb for ros-humble-unitree-sdk2-ament"
    exit 1
  fi

  # Install with overwrite if CycloneDDS is present
  if dpkg -l | grep -q "ros-humble-cyclonedds"; then
    echo "⚠️ CycloneDDS detected → forcing overwrite..."
    dpkg -i --force-overwrite "$DEB_FILE" || true
    apt-get -f install -y
  else
    dpkg -i "$DEB_FILE" || apt-get -f install -y
  fi

  echo "✔️ ros-humble-unitree-sdk2-ament reinstalled (candidate version)"
else
  echo "✔️ ros-humble-unitree-sdk2-ament up-to-date ($INSTALLED_VER)"
fi

# Install the rest of the prebuilt packages needed
apt-get install -y \
  ros-humble-legged-control-base \
  ros-humble-mujoco-ros2-control \
  ros-humble-unitree-description \
  ros-humble-unitree-systems \
  ros-humble-rosbag2-storage-mcap \
  ros-humble-realsense2-description

# Ensure rosdep is up-to-date
if ! command -v rosdep >/dev/null 2>&1; then
  pip3 install -U rosdep
fi
rosdep update || true

# -------------------------------
# 3. Workspace: clone & build motion_tracking_controller
# -------------------------------
echo "➡️ Preparing colcon workspace at: $COLCON_WS"
sudo -u "$SUDO_USER" bash -c "
  mkdir -p $COLCON_WS/src
  cd $COLCON_WS/src

  # Clone unitree_bringup if missing
  if [ ! -d unitree_bringup ]; then
    git clone https://github.com/qiayuanl/unitree_bringup.git
  else
    echo '✔ unitree_bringup already cloned'
  fi

  # Clone motion_tracking_controller if missing
  if [ ! -d motion_tracking_controller ]; then
    git clone https://github.com/HybridRobotics/motion_tracking_controller.git
  else
    echo '✔ motion_tracking_controller already cloned'
  fi
"

# rosdep install for workspace (resolves apt/ros deps automatically)
echo "➡️ Running rosdep install --from-paths (may require network)"
cd "$COLCON_WS"
rosdep install --from-paths src --ignore-src -r -y || {
  echo "⚠️ rosdep install failed or had missing entries — please inspect output"
}

# Build in two steps as recommended upstream (first unitree_bringup, then controller)
echo "➡️ Building unitree_bringup (colcon)"
cd "$COLCON_WS"
colcon build --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=RelWithDebInfo --packages-up-to unitree_bringup

echo "➡️ Building motion_tracking_controller (colcon)"
colcon build --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=RelWithDebInfo --packages-up-to motion_tracking_controller

# Source the install workspace for convenience (append to user rc if not present)
INSTALL_SETUP="$COLCON_WS/install/setup.bash"
if ! grep -Fq "$INSTALL_SETUP" "$USER_HOME/.bashrc" 2>/dev/null; then
  echo "source $INSTALL_SETUP" >> "$USER_HOME/.bashrc"
  chown "$SUDO_USER":"$SUDO_USER" "$USER_HOME/.bashrc"
fi

# -------------------------------
# 4. Conda + wandb (optional)
# -------------------------------
echo "➡️ Attempting to install wandb into conda environment $CONDA_ENV_NAME (if conda available)..."
if [ -f "$USER_HOME/miniconda3/etc/profile.d/conda.sh" ]; then
  CONDA_PATH="$USER_HOME/miniconda3"
elif [ -f "$USER_HOME/anaconda3/etc/profile.d/conda.sh" ]; then
  CONDA_PATH="$USER_HOME/anaconda3"
elif [ -f "/opt/conda/etc/profile.d/conda.sh" ]; then
  CONDA_PATH="/opt/conda"
else
  CONDA_PATH=""
fi

if [ -n "$CONDA_PATH" ]; then
  sudo -u "$SUDO_USER" bash -c "
    source $CONDA_PATH/etc/profile.d/conda.sh || true
    if conda env list | grep -q \"$CONDA_ENV_NAME\"; then
      conda activate $CONDA_ENV_NAME
      pip install --upgrade pip
      pip install wandb || true
    else
      echo '⚠️ Conda env $CONDA_ENV_NAME not found — skipping wandb install'
    fi
  "
else
  echo "⚠️ No conda found for user $SUDO_USER — skipping wandb installation"
fi

echo "======================================"
echo "✅ Installation & build finished."
echo "Next steps for sim/real usage (examples):"
echo "  source /opt/ros/humble/setup.bash"
echo "  source $COLCON_WS/install/setup.bash"
echo "  # Run simulation (example):"
echo "  # ros2 launch motion_tracking_controller mujoco.launch.py wandb_path:=<run>"
echo "  # Run on real robot (example):"
echo "  # ros2 launch motion_tracking_controller real.launch.py network_interface:=<ifname> wandb_path:=<run>"
echo "======================================"

exit 0
