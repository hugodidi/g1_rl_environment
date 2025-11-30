#!/usr/bin/env python

import time
import os
import argparse

import mujoco
import mujoco.viewer
import numpy as np
import yaml

import rclpy
from rclpy.node import Node

from sensor_msgs.msg import JointState
from std_msgs.msg import Float64MultiArray

from legged_gym import LEGGED_GYM_ROOT_DIR

# --------- MUJOCO / EGL BACKEND ----------
# Force MuJoCo to use EGL (headless GPU) if available
os.environ["MUJOCO_GL"] = "egl"
os.environ["EGL_DEVICE_ID"] = "0"
os.environ["DRI_PRIME"] = "1"


def get_gravity_orientation(quaternion):
    """
    Compute gravity orientation in body frame from a unit quaternion.
    (Kept here for completeness; not used directly in the ROS bridge.)
    """
    qw = quaternion[0]
    qx = quaternion[1]
    qy = quaternion[2]
    qz = quaternion[3]

    gravity_orientation = np.zeros(3)
    gravity_orientation[0] = 2 * (-qz * qx + qw * qy)
    gravity_orientation[1] = -2 * (qz * qy + qw * qx)
    gravity_orientation[2] = 1 - 2 * (qw * qw + qz * qz)
    return gravity_orientation


def pd_control(target_q, q, kp, target_dq, dq, kd):
    """Simple PD control: tau = Kp (q* - q) + Kd (dq* - dq)."""
    return (target_q - q) * kp + (target_dq - dq) * kd


class MujocoRosBridge(Node):
    """
    ROS 2 bridge for a MuJoCo G1 simulation.

    Compared to the original deploy_mujoco.py:
      - it does NOT load a Torch policy.
      - it subscribes to /mujoco/joint_torque_cmd (Float64MultiArray) which
        carries the normalized RL actions (joint position offsets).
      - it applies a PD controller to convert target joint positions into torques.
      - it publishes JointState messages on /mujoco/joint_states for the policy node.
    """

    def __init__(self, config_file: str):
        super().__init__("mujoco_ros_bridge")

        # --------- Load YAML config ----------
        config_path = f"{LEGGED_GYM_ROOT_DIR}/deploy/deploy_mujoco/configs/{config_file}"
        with open(config_path, "r") as f:
            config = yaml.load(f, Loader=yaml.FullLoader)
            # we ignore policy_path here: the policy comes from ROS / ONNX
            xml_path = config["xml_path"].replace("{LEGGED_GYM_ROOT_DIR}", LEGGED_GYM_ROOT_DIR)

            self.simulation_duration = config["simulation_duration"]
            self.simulation_dt = config["simulation_dt"]
            self.control_decimation = config["control_decimation"]

            self.kps = np.array(config["kps"], dtype=np.float32)
            self.kds = np.array(config["kds"], dtype=np.float32)
            self.default_angles = np.array(config["default_angles"], dtype=np.float32)

            self.ang_vel_scale = config["ang_vel_scale"]
            self.dof_pos_scale = config["dof_pos_scale"]
            self.dof_vel_scale = config["dof_vel_scale"]
            self.action_scale = config["action_scale"]
            self.cmd_scale = np.array(config["cmd_scale"], dtype=np.float32)

            self.num_actions = config["num_actions"]
            self.num_obs = config["num_obs"]
            self.cmd = np.array(config["cmd_init"], dtype=np.float32)

        # --------- Context variables ----------
        self.action = np.zeros(self.num_actions, dtype=np.float32)
        # Target joint positions (q*) start at the default pose
        self.target_dof_pos = self.default_angles.copy()
        self.obs = np.zeros(self.num_obs, dtype=np.float32)
        self.counter = 0

        # --------- Load MuJoCo model ----------
        self.m = mujoco.MjModel.from_xml_path(xml_path)
        self.d = mujoco.MjData(self.m)
        self.m.opt.timestep = self.simulation_dt

        # DEBUG: print the joint names and qpos indices so we can align default_angles
        print("\n[DEBUG] MuJoCo joints and qpos indices (including floating base):")
        for j_id in range(self.m.njnt):
            name = mujoco.mj_id2name(self.m, mujoco.mjtObj.mjOBJ_JOINT, j_id)
            qpos_adr = self.m.jnt_qposadr[j_id]
            print(f"  joint {j_id:2d}: name={name:35s} qpos_index={qpos_adr}")
        print()

        # Sanity check: inferred number of actuated DOFs from the model
        # For a floating-base model, 7 qpos are for the base (3 pos + 4 quat).
        # We assume remaining DOFs correspond to actuated joints.
        inferred_num_dofs = self.m.nq - 7
        if inferred_num_dofs != self.num_actions:
            self.get_logger().warn(
                f"[DEBUG] Inferred DOFs from model = {inferred_num_dofs}, "
                f"but num_actions from YAML = {self.num_actions}. "
                "This is not necessarily fatal (some joints may not be controlled), "
                "but check that the ordering and sizes are consistent."
            )

        # --------- ROS I/O ----------
        # /mujoco/joint_torque_cmd carries the normalized RL action vector
        self.last_action = np.zeros(self.num_actions, dtype=np.float32)

        self.sub_action = self.create_subscription(
            Float64MultiArray,
            "/mujoco/joint_torque_cmd",
            self.action_callback,
            10,
        )

        self.pub_js = self.create_publisher(JointState, "/mujoco/joint_states", 10)

        # Purely cosmetic joint names for the JointState message
        self.joint_names = [f"joint_{i}" for i in range(self.num_actions)]

        self.get_logger().info(
            f"✅ MujocoRosBridge initialized with config '{config_file}'\n"
            f"  config_path={config_path}\n"
            f"  xml_path={xml_path}\n"
            f"  num_actions={self.num_actions}, num_obs={self.num_obs}\n"
            f"  simulation_dt={self.simulation_dt}, control_decimation={self.control_decimation}"
        )

    # -------------------- ROS callbacks ------------------------

    def action_callback(self, msg: Float64MultiArray):
        """
        Receive the latest RL action vector from the policy node.
        If the size does not match num_actions, we clamp or pad with zeros.
        """
        data = np.array(msg.data, dtype=np.float32)
        if data.shape[0] != self.num_actions:
            self.get_logger().warn(
                f"Received action size {data.shape[0]} != num_actions {self.num_actions}. "
                "Clamping/padding."
            )
            if data.shape[0] > self.num_actions:
                data = data[: self.num_actions]
            else:
                tmp = np.zeros(self.num_actions, dtype=np.float32)
                tmp[: data.shape[0]] = data
                data = tmp
        self.last_action = data

    # -------------------- Simulation loop ------------------------

    def run(self):
        """
        Main simulation loop with MuJoCo viewer and ROS bridge.
        MuJoCo runs forward dynamics, PD generates torques, and actions are
        updated periodically from self.last_action.
        """
        with mujoco.viewer.launch_passive(self.m, self.d) as viewer:
            start = time.time()
            while viewer.is_running() and time.time() - start < self.simulation_duration:
                step_start = time.time()

                # PD control towards target_dof_pos
                # For a floating-base model:
                #   - qpos[0:7]  = base pose (3 pos + 4 quat)
                #   - qpos[7:]   = joint positions
                #   - qvel[0:6]  = base velocities
                #   - qvel[6:]   = joint velocities
                q_joint = self.d.qpos[7:]
                dq_joint = self.d.qvel[6:]

                # Ensure we only use the first num_actions DOFs
                q_joint = q_joint[: self.num_actions]
                dq_joint = dq_joint[: self.num_actions]

                tau = pd_control(
                    self.target_dof_pos,
                    q_joint,
                    self.kps,
                    np.zeros_like(self.kds),
                    dq_joint,
                    self.kds,
                )

                # Clamp torques to avoid NaN / Inf explosions
                max_torque = 300.0
                tau = np.clip(tau, -max_torque, max_torque)

                self.d.ctrl[:] = tau

                mujoco.mj_step(self.m, self.d)
                self.counter += 1

                # Update target positions from RL action every "control_decimation" steps
                if self.counter % self.control_decimation == 0:
                    self.action = self.last_action.copy()
                    self.target_dof_pos = self.action * self.action_scale + self.default_angles

                # Publish JointState to ROS
                self.publish_joint_state()

                # Let ROS process callbacks
                rclpy.spin_once(self, timeout_sec=0.0)

                # Sync viewer
                viewer.sync()

                # Keep real-time pace if possible
                time_until_next_step = self.m.opt.timestep - (time.time() - step_start)
                if time_until_next_step > 0:
                    time.sleep(time_until_next_step)

            self.get_logger().info("⏹ Simulation finished (duration reached or viewer closed).")

    def publish_joint_state(self):
        """
        Publish joint positions and velocities as a ROS2 JointState message.
        Only the first num_actions DOFs are exposed (those controlled by the policy).
        """
        msg = JointState()
        msg.header.stamp = self.get_clock().now().to_msg()
        msg.name = self.joint_names

        qj = self.d.qpos[7 : 7 + self.num_actions]
        dqj = self.d.qvel[6 : 6 + self.num_actions]

        msg.position = qj.tolist()
        msg.velocity = dqj.tolist()
        self.pub_js.publish(msg)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "config_file",
        type=str,
        help="config file name in the config folder (e.g. g1.yaml, g1_29.yaml)",
    )
    args = parser.parse_args()
    config_file = args.config_file

        # ALIAS: if the user / launch passes "g1.yaml", redirect to "g1_29.yaml"
    if config_file == "g1.yaml":
        print("[INFO] Remapping config 'g1.yaml' → 'g1_29.yaml' for 29-DoF G1 policy.")
        config_file = "g1_29.yaml"

    rclpy.init()
    node = MujocoRosBridge(config_file)

    try:
        node.run()
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
