import gymnasium as gym

from isaaclab_tasks.utils.hydra import hydra_task_config
from isaaclab.envs import DirectRLEnvCfg, ManagerBasedRLEnvCfg, DirectMARLEnvCfg
from isaaclab.envs import multi_agent_to_single_agent
from isaaclab_rl.rsl_rl import RslRlOnPolicyRunnerCfg, RslRlVecEnvWrapper

TASK_NAME = "Tracking-Flat-G1-v0"

@hydra_task_config(TASK_NAME, "rsl_rl_cfg_entry_point")
def load_cfg(env_cfg: DirectRLEnvCfg | ManagerBasedRLEnvCfg | DirectMARLEnvCfg,
             agent_cfg: RslRlOnPolicyRunnerCfg):
    return env_cfg, agent_cfg

def main():
    env_cfg, agent_cfg = load_cfg()
    env_cfg.scene.num_envs = 1

    env = gym.make(TASK_NAME, cfg=env_cfg, render_mode=None)
    if hasattr(env.unwrapped, "num_actions"):
        print("num_actions from env:", env.unwrapped.num_actions)

    # Si c'est un env multi-agent
    if hasattr(env.unwrapped, "agents"):
        print("Multi-agent env, you may need to inspect each agent’s action space.")

    # Essai d'imprimer des noms de joints / actions si exposés
    # (à adapter suivant ton env, parfois env.unwrapped.cfg.control.joint_names existe)
    try:
        ctrl_cfg = env.unwrapped.cfg.control
        if hasattr(ctrl_cfg, "joint_names"):
            print("Action joint_names (order):")
            for name in ctrl_cfg.joint_names:
                print("  -", name)
    except Exception as e:
        print("Could not access control joint names:", e)

    env.close()

if __name__ == "__main__":
    main()
