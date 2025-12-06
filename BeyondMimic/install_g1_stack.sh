#!/usr/bin/env bash
set -e

echo "==============================="
echo "  Install G1 / legged_control2"
echo "  (Qiayuan buildfarms + deps)"
echo "==============================="

# ------------------------------------------
# Basic checks
# ------------------------------------------
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run this script with: sudo $0"
  exit 1
fi

if [ -z "$ROS_DISTRO" ]; then
  echo "⚠️  ROS_DISTRO not set. Assuming 'humble'."
  ROS_DISTRO=humble
fi

if [ "$ROS_DISTRO" != "humble" ]; then
  echo "❌ This setup is intended for ROS 2 Humble. Detected: $ROS_DISTRO"
  exit 1
fi

echo "➡️ Using ROS_DISTRO=$ROS_DISTRO"

##############################################
# 1. Add Qiayuan buildfarm APT sources
##############################################

echo "➡️ Adding legged_buildfarm repository..."
echo "deb [trusted=yes] https://github.com/qiayuanl/legged_buildfarm/raw/jammy-humble-amd64/ ./" \
  > /etc/apt/sources.list.d/qiayuanl_legged_buildfarm.list

echo "yaml https://github.com/qiayuanl/legged_buildfarm/raw/jammy-humble-amd64/local.yaml humble" \
  > /etc/ros/rosdep/sources.list.d/1-qiayuanl_legged_buildfarm.list

echo "➡️ Adding simulation_buildfarm repository..."
echo "deb [trusted=yes] https://github.com/qiayuanl/simulation_buildfarm/raw/jammy-humble-amd64/ ./" \
  > /etc/apt/sources.list.d/qiayuanl_simulation_buildfarm.list

echo "yaml https://github.com/qiayuanl/simulation_buildfarm/raw/jammy-humble-amd64/local.yaml humble" \
  > /etc/ros/rosdep/sources.list.d/1-qiayuanl_simulation_buildfarm.list

echo "➡️ Adding unitree_buildfarm repository..."
echo "deb [trusted=yes] https://github.com/qiayuanl/unitree_buildfarm/raw/jammy-humble-amd64/ ./" \
  > /etc/apt/sources.list.d/qiayuanl_unitree_buildfarm.list

echo "yaml https://github.com/qiayuanl/unitree_buildfarm/raw/jammy-humble-amd64/local.yaml humble" \
  > /etc/ros/rosdep/sources.list.d/1-qiayuanl_unitree_buildfarm.list

##############################################
# 2. Update APT
##############################################

echo "➡️ Updating APT..."
apt-get update

##############################################
# 3. Install ros-humble-unitree-sdk2-ament
#    - normal install if no CycloneDDS
#    - forced overwrite if CycloneDDS present
##############################################

echo "➡️ Checking if ros-humble-unitree-sdk2-ament is already installed..."

if dpkg -l | grep -q "ros-humble-unitree-sdk2-ament"; then
  echo "✔️ ros-humble-unitree-sdk2-ament already installed, skipping."
else
  echo "➡️ ros-humble-unitree-sdk2-ament not installed yet."

  # Check for CycloneDDS
  if dpkg -l | grep -q "ros-humble-cyclonedds"; then
    echo "⚠️ ros-humble-cyclonedds is installed."
    echo "   Installing ros-humble-unitree-sdk2-ament with --force-overwrite on dds/config.h..."

    # Download the .deb
    apt-get download ros-humble-unitree-sdk2-ament

    # Find the downloaded file (current dir first, then cache as fallback)
    DEB_FILE=$(ls ros-humble-unitree-sdk2-ament_0-*.deb 2>/dev/null || \
               ls /var/cache/apt/archives/ros-humble-unitree-sdk2-ament_0-*.deb 2>/dev/null || true)

    if [ -z "$DEB_FILE" ]; then
      echo "❌ Could not find downloaded ros-humble-unitree-sdk2-ament .deb file."
      exit 1
    fi

    echo "➡️ Installing $DEB_FILE with dpkg --force-overwrite..."
    dpkg -i --force-overwrite "$DEB_FILE" || true

    echo "➡️ Running apt-get -f install to fix dependencies..."
    apt-get -f install -y

    echo "✔️ ros-humble-unitree-sdk2-ament installed (forced overwrite mode)."

  else
    echo "✔️ ros-humble-cyclonedds is NOT installed."
    echo "   Installing ros-humble-unitree-sdk2-ament normally via apt-get..."
    apt-get install -y ros-humble-unitree-sdk2-ament
    echo "✔️ ros-humble-unitree-sdk2-ament installed (normal mode)."
  fi
fi

##############################################
# 4. Install remaining ROS packages
##############################################

echo "➡️ Installing remaining G1-related ROS packages..."
apt-get install -y \
  ros-humble-legged-control-base \
  ros-humble-mujoco-ros2-control \
  ros-humble-unitree-description \
  ros-humble-unitree-systems \
  ros-humble-rosbag2-storage-mcap \
  ros-humble-realsense2-description \
  python3-pip

##############################################
# 5. Detect shell (.bashrc or .zshrc)
##############################################

echo "➡️ Detecting user shell..."

USER_SHELL=$(sudo -u $SUDO_USER echo $SHELL)

if [[ $USER_SHELL == *"zsh"* ]]; then
  RC_FILE="/home/$SUDO_USER/.zshrc"
  echo "✔️ Detected zsh → using .zshrc"
elif [[ $USER_SHELL == *"bash"* ]]; then
  RC_FILE="/home/$SUDO_USER/.bashrc"
  echo "✔️ Detected bash → using .bashrc"
else
  RC_FILE="/home/$SUDO_USER/.bashrc"
  echo "⚠️ Unknown shell, defaulting to .bashrc"
fi

##############################################
# 6. Activate conda environment
#    and install wandb if missing
##############################################

CONDA_ENV_NAME="isaacLab"

echo "======================================================"
echo " Activating conda env inside: $RC_FILE"
echo "======================================================"

# Load conda base
if [ -f /home/$SUDO_USER/miniconda3/etc/profile.d/conda.sh ]; then
  source /home/$SUDO_USER/miniconda3/etc/profile.d/conda.sh
elif [ -f /home/$SUDO_USER/anaconda3/etc/profile.d/conda.sh ]; then
  source /home/$SUDO_USER/anaconda3/etc/profile.d/conda.sh
elif [ -f /opt/conda/etc/profile.d/conda.sh ]; then
  source /opt/conda/etc/profile.d/conda.sh
else
  echo "❌ Could not find conda installation."
  exit 1
fi

# Run commands as the real user
sudo -u $SUDO_USER bash -c "
  source $RC_FILE
  conda activate $CONDA_ENV_NAME

  echo '➡️ Checking wandb in conda environment...'
  python3 -c 'import wandb' 2>/dev/null
  if [ \$? -ne 0 ]; then
    echo '⚠️ wandb NOT found. Installing...'
    pip install --upgrade pip
    pip install wandb
    echo '✔️ wandb installed.'
  else
    echo '✔️ wandb already installed.'
  fi
"

echo "======================================================"
echo "  ✅ System installation complete!"
echo ""
echo "  Next steps:"
echo "    conda activate $CONDA_ENV_NAME"
echo "    source /opt/ros/humble/setup.bash"
echo "    # Then run the G1 WORKSPACE SETUP SCRIPT to:"
echo "    #   - Create colcon workspace"
echo "    #   - Clone unitree_bringup + motion_tracking_controller"
echo "    #   - Run rosdep"
echo "    #   - Build with colcon"
echo "======================================================"
