#!/usr/bin/env bash
# ============================================================
# Launcher for ROS2 + MuJoCo + Policy (WandB / ONNX)
#
# Usage examples:
#   ./run_mujoco_ros.sh wandb_path:=ENTITY/PROJECT/RUN_ID
#   ./run_mujoco_ros.sh policy_path:=/path/to/policy.onnx
#
# Environment variables (optional):
#   ROS2ROB_WS   : path to the ROS2 workspace (default: $HOME/ros2rob_ws)
#   MUJOCO_VENV  : path to the MuJoCo virtualenv (default: $HOME/mujoco-rl)
#   RL_ROOT      : root folder that contains RL/LeggGym (auto-detected otherwise)
#   LEGGM_PATH   : full path to unitree_rl_gym (overrides auto-detection)
# ============================================================

set -e

echo "=============================================="
echo "  ROS2 + MuJoCo + Policy Launcher"
echo "=============================================="
echo "[INFO] Script running under: $(ps -p $$ -o comm=)"
echo "[INFO] Login shell (SHELL): ${SHELL:-unknown}"
echo "----------------------------------------------"

# ------------------------------------------------------------
# 1) Source ROS 2 Humble (BASH version)
# ------------------------------------------------------------
if [ ! -f /opt/ros/humble/setup.bash ]; then
  echo "[ERROR] /opt/ros/humble/setup.bash not found."
  echo "       Is ROS2 Humble installed correctly?"
  exit 1
fi

echo "[INFO] Sourcing ROS2 Humble: /opt/ros/humble/setup.bash"
# This script is executed by /usr/bin/env bash, so bash syntax is safe here.
source /opt/ros/humble/setup.bash

# ------------------------------------------------------------
# 2) Source ROS workspace
# ------------------------------------------------------------
WS="${ROS2ROB_WS:-$HOME/ros2rob_ws}"
echo "[INFO] Using ROS2 workspace: ${WS}"

if [ ! -d "$WS" ]; then
  echo "[ERROR] Workspace directory not found: $WS"
  echo "        Set ROS2ROB_WS or create ~/ros2rob_ws."
  exit 1
fi

if [ ! -f "$WS/install/setup.bash" ]; then
  echo "[ERROR] Workspace is not built."
  echo "        Please run:"
  echo "          cd $WS"
  echo "          colcon build"
  exit 1
fi

echo "[INFO] Sourcing workspace: $WS/install/setup.bash"
source "$WS/install/setup.bash"

# ------------------------------------------------------------
# 3) Activate the Python virtual environment (mujoco-rl)
#    (MUST be AFTER ROS so that venv's python is first in PATH)
# ------------------------------------------------------------
VENV_PATH="${MUJOCO_VENV:-$HOME/mujoco-rl}"

if [ -d "$VENV_PATH" ]; then
  echo "[INFO] Activating venv: $VENV_PATH"
  # shellcheck disable=SC1090
  source "$VENV_PATH/bin/activate"
else
  echo "[ERROR] Virtual environment not found at: $VENV_PATH"
  echo "        Create it or set MUJOCO_VENV to the correct path."
  exit 1
fi

export ROS_PYTHON_EXECUTABLE="$(which python3)"
echo "[INFO] ROS_PYTHON_EXECUTABLE set to: $ROS_PYTHON_EXECUTABLE"

PYTHON_BIN="$(command -v python3 || command -v python)"
echo "[INFO] Python interpreter used by nodes: $PYTHON_BIN"

# ------------------------------------------------------------
# 4) Detect RL root and configure LeggedGym Python path
# ------------------------------------------------------------

# Try to auto-detect RL/ root if not provided
find_rl_root() {
  local candidates=(
    "$HOME/RL"
    "$HOME/Documents/RL"
    "$HOME/Documentos/RL"
  )
  for c in "${candidates[@]}"; do
    if [ -d "$c" ]; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

if [ -z "$RL_ROOT" ]; then
  RL_ROOT="$(find_rl_root || true)"
fi

if [ -z "$RL_ROOT" ]; then
  echo "[WARN] Could not automatically find RL root folder."
  echo "       You can set it manually with:"
  echo "         export RL_ROOT=/path/to/RL"
fi

# LEGGM_PATH can be overridden; otherwise use RL_ROOT if available
if [ -z "$LEGGM_PATH" ]; then
  if [ -n "$RL_ROOT" ]; then
    LEGGM_PATH="$RL_ROOT/LeggGym/unitree_rl_gym"
  else
    LEGGM_PATH="$HOME/RL/LeggGym/unitree_rl_gym"
  fi
fi

if [ -d "$LEGGM_PATH" ]; then
  echo "[INFO] LeggedGym path: $LEGGM_PATH"
  export LEGGM_PATH
  export PYTHONPATH="$LEGGM_PATH:${PYTHONPATH:-}"
  echo "[INFO] PYTHONPATH configured for LeggedGym."
else
  echo "[WARN] LeggedGym not found at: $LEGGM_PATH"
  echo "       deploy_mujoco_ros.py may fail to import legged_gym."
fi

# ------------------------------------------------------------
# 5) Forward arguments to ros2 launch
# ------------------------------------------------------------
echo "----------------------------------------------"
echo "[INFO] Running:"
echo "       ros2 launch motion_tracking_controller mujoco.launch.py $*"
echo "=============================================="

ros2 launch motion_tracking_controller mujoco.launch.py "$@"
