# AGENTS.md

本仓库是「本机私有部署大模型（Ollama）」的操作手册，面向 Windows。

**执行部署时，完整步骤看 `SKILL.md`。** 对照表：

| 阶段 | SKILL.md 对应章节 |
|---|---|
| 测硬件、选模型档位 | §0 |
| 安装 Ollama | §1 |
| 下载 / 导入模型 | §2 |
| 隐私加固（断网） | §3 |
| 验证零外连 | §4 |
| 使用方法 | §5 |
| 知识时效的边界 | §6 |
| 速度的真实构成 | §7 |
| 为什么别接进 agent 框架 | §8 |
| 踩坑清单 | 文末 |

## 硬约束（先读，别踩）

1. **脚本是 PowerShell，只在 Windows 可用。** Linux/macOS 需自行改写。
2. **模型目录必须在拉模型之前设好**（`OLLAMA_MODELS`），否则模型会堆满 C 盘。
3. **大模型不要用 `ollama pull`** —— 官方 CDN 会限速并出现"下洞"（长度对、哈希错）。改用 GGUF 直下 + `ollama create`。
4. **隐私加固不影响本地推理** —— Windows 防火墙不过滤回环流量。
5. **不要把本地模型接进 agent 框架** —— 实测每轮 60~90 秒且会编造，原因见 §8。

## 一次成功部署的判据

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify-local-only.ps1 -Model <模型名>
```

全部 PASS 即完成。若失败，逐条看输出里的说明。

## 给人看的版本

`README.md` 是同一套流程的人话版，适合直接照着做。