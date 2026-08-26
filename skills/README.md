# skills

本目录存放帮助 AI Agent 掌握 `radare2-for-agent` 使用方法的 Skill 定义。

## 使用方式

- 如果使用 DSH：将 `radare2-for-agent` 目录放到 `~/.dsh/skills/` 下，或在该位置创建软链：

  ```bash
  ln -s "$PWD/skills/radare2-for-agent" ~/.dsh/skills/radare2-for-agent
  ```

- 如果使用其他 Agent 框架：按该框架的 Skill 规范加载 `radare2-for-agent/SKILL.md`。

## 内容

- `radare2-for-agent/SKILL.md`：面向 AI Agent 的完整使用说明、触发场景、命令示例、能力边界和故障排查。
