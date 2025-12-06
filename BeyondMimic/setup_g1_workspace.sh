#!/usr/bin/env bash
set -e

###############################################################################
#  G1 WORKSPACE SETUP SCRIPT
#  - Creates a colcon workspace (~/colcon_ws by default)
#  - Clones:
#       - qiayuanl/unitree_bringup
#       - HybridRobotics/motion_tracking_controller
#  - Runs rosdep to install dependencies
#  - Builds the workspace with colcon
#
#  Usage:
#    1) Make executable:  chmod +x setup_g1_workspace.sh
#    2) Run as normal user (NOT sudo):
#         ./setup_g1_workspace.sh
#
#  Note:
#    - ROS 2 Humble must be installed.
#    - The Qiayuan buildfarm packages should already be installed
#      (run install_g1_stack.sh first).
#    - Recommended: run this inside your conda env (with wandb installed).
###############################################################################

# -------------------------------
# 0. Basic checks
# -------------------------------
if [ "$EUID" -eq 0 ]; then
  echo "❌ Please DO NOT run this script with sudo."
  echo "   Run it as a normal user:"
  echo "   ./setup_g1_workspace.sh"
  exit 1
fi

if [ -z "$ROS_DISTRO" ]; then
  echo "⚠️  ROS_DISTRO is not set. Assuming 'humble'."
  ROS_DISTRO=humble
fi

if [ "$ROS_DISTRO" != "humble" ]; then
  echo "❌ This script is designed for ROS 2 Humble. Detected: $ROS_DISTRO"
  exit 1
fi

echo "➡️ Using ROS_DISTRO=$ROS_DISTRO"


# -------------------------------
# 1. Define workspace path
# -------------------------------
COLCON_WS=${COLCON_WS:-"$HOME/colcon_ws"}

echo "➡️ Workspace will be: $COLCON_WS"

mkdir -p "$COLCON_WS/src"
cd "$COLCON_WS/src"


# -------------------------------
# 2. Clone required repositories
# -------------------------------
echo "=========================================================="
echo " Cloning required repositories into $COLCON_WS/src"
echo "=========================================================="

if [ ! -d "$COLCON_WS/src/unitree_bringup" ]; then
  echo "➡️ Cloning unitree_bringup..."
  git clone https://github.com/qiayuanl/unitree_bringup.git
else
  echo "✔️ unitree_bringup already exists, skipping clone."
fi

if [ ! -d "$COLCON_WS/src/motion_tracking_controller" ]; then
  echo "➡️ Cloning motion_tracking_controller..."
  git clone https://github.com/HybridRobotics/motion_tracking_controller.git
else
  echo "✔️ motion_tracking_controller already exists, skipping clone."
fi


# -------------------------------
# 3. rosdep dependencies
# -------------------------------
echo "=========================================================="
echo " Running rosdep to install dependencies"
echo "=========================================================="

cd "$COLCON_WS"

# rosdep update (may need sudo once to init system-wide)
echo "➡️ rosdep update..."
rosdep update

echo "➡️ rosdep install from src (this may ask for sudo password)..."
rosdep install --from-paths src --ignore-src -r -y || {
  echo "⚠️ rosdep install encountered errors."
  echo "   If permissions issues appear, try:"
  echo "   sudo rosdep init  (only once, if not already done)"
  echo "   rosdep update"
  exit 1
}


# -------------------------------
# 4. Source ROS and build workspace
# -------------------------------
echo "=========================================================="
echo " Building the workspace with colcon"
echo "=========================================================="

# Detect current shell (user's login shell, e.g. /usr/bin/zsh or /bin/bash)
CURRENT_SHELL=$(basename "$SHELL")
echo "➡️ Detected shell: $CURRENT_SHELL"

# Helper: source a file if it exists
source_if_exists() {
    if [ -f "$1" ]; then
        # shellcheck disable=SC1090
        source "$1"
        echo "✔️  Sourced: $1"
        return 0
    else
        return 1
    fi
}

# Choose appropriate ROS setup according to shell
if [ "$CURRENT_SHELL" = "zsh" ]; then
    # Prefer setup.zsh for zsh
    if ! source_if_exists "/opt/ros/humble/setup.zsh"; then
        echo "⚠️ /opt/ros/humble/setup.zsh not found. Falling back to setup.bash…"
        if ! source_if_exists "/opt/ros/humble/setup.bash"; then
            echo "❌ Could not find /opt/ros/humble/setup.zsh or setup.bash. Is ROS 2 Humble installed?"
            exit 1
        fi
    fi
elif [ "$CURRENT_SHELL" = "bash" ] || [ "$CURRENT_SHELL" = "sh" ]; then
    # Prefer setup.bash for bash/sh
    if ! source_if_exists "/opt/ros/humble/setup.bash"; then
        echo "⚠️ /opt/ros/humble/setup.bash not found. Trying setup.zsh…"
        if ! source_if_exists "/opt/ros/humble/setup.zsh"; then
            echo "❌ Could not find /opt/ros/humble/setup.bash or setup.zsh. Is ROS 2 Humble installed?"
            exit 1
        fi
    fi
else
    # Unknown shell → try both
    echo "⚠️ Unknown shell. Trying both setup.zsh and setup.bash…"
    if ! source_if_exists "/opt/ros/humble/setup.zsh" &&
       ! source_if_exists "/opt/ros/humble/setup.bash"; then
        echo "❌ Could not find any ROS 2 Humble setup file in /opt/ros/humble."
        exit 1
    fi
fi

cd "$COLCON_WS"

echo "➡️ First build: unitree_bringup (and its deps)..."
colcon build --symlink-install \
  --cmake-args -DCMAKE_BUILD_TYPE=RelwithDebInfo \
  --packages-up-to unitree_bringup

echo "➡️ Second build: motion_tracking_controller (and its deps)..."
colcon build --symlink-install \
  --cmake-args -DCMAKE_BUILD_TYPE=RelwithDebInfo \
  --packages-up-to motion_tracking_controller

echo "=========================================================="
echo " ✅ Workspace built successfully!"
echo ""
echo " To use it in a new terminal, run:"
echo "   conda activate YOUR_CONDA_ENV_NAME   # if you use conda"
if [ "$CURRENT_SHELL" = "zsh" ]; then
  echo "   source /opt/ros/humble/setup.zsh"
  echo "   source $COLCON_WS/install/setup.zsh"
else
  echo "   source /opt/ros/humble/setup.bash"
  echo "   source $COLCON_WS/install/setup.bash"
fi
echo ""
echo " Then you can launch, for example:"
echo "   ros2 launch motion_tracking_controller real.launch.py"
echo "=========================================================="