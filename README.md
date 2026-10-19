# 本机私有大模型部署包（Windows）

**目标：模型跑在自己的电脑上，推理过程不出网。** 装完你就有一个能离线对话的 AI，聊天内容不上传任何服务器。

全程 30~60 分钟，主要时间花在下载模型上。

---

## 第 0 步：先看硬件，再决定下哪个模型

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\detect-hardware.ps1
```

它会告诉你显卡型号、显存、内存、磁盘剩余，并直接给出推荐档位。

**关键：不要只看权重体积。** 显存里还要装 KV 缓存和计算缓冲，只算权重会下到跑不动的模型。

大致档位（详细见 `SKILL.md`）：

| 显存 | 推荐 |
|---|---|
| 6–8 GB | 8B 参数 Q4（约 5.2 GB）—— 最快最省事 |
| 6–8 GB + 32 GB 内存 | 也可以用 26–30B 的 MoE 模型（15–18 GB），慢一倍但聪明得多 |
| 12 GB | 12–14B |
| 16 GB | 14B 宽裕，或 27B 混合 |
| 24 GB | 27–32B |
| 40 GB+ | 70B |

**基座选择**：默认优先非中文基座（数据来源和供应商更分散，单一厂商看到的东西更少）；中文基座作为备选，中文能力更强。

模型迭代很快，**不要凭印象选**。查当前有什么：

```
https://hf-mirror.com/api/models?author=<厂商>&sort=createdAt&direction=-1&limit=15
https://hf-mirror.com/api/models?search=<名字>-GGUF&sort=downloads&direction=-1
```

---

## 第 1 步：装 Ollama

```powershell
# 先把模型目录钉到非系统盘（必须在拉模型之前！否则模型会堆满 C 盘）
New-Item -ItemType Directory -Force -Path "D:\ollama\models" | Out-Null
[Environment]::SetEnvironmentVariable("OLLAMA_MODELS","D:\ollama\models","User")
$env:OLLAMA_MODELS = "D:\ollama\models"

# 下载安装包（约 1.5 GB）
curl.exe -L -C - --retry 5 -o "$env:TEMP\OllamaSetup.exe" "https://ollama.com/download/OllamaSetup.exe"

# 验签（应该是 Valid / Ollama Inc.）
Get-AuthenticodeSignature "$env:TEMP\OllamaSetup.exe" | Select-Object Status,SignerCertificate

# 静默安装
cmd /c '"%TEMP%\OllamaSetup.exe" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
```

装完程序在 `%LOCALAPPDATA%\Programs\Ollama`（安装器不支持改目录）。

**注意**：`ollama` 命令在你**当前**的终端里认不到（PATH 是终端启动时的快照）。**新开一个终端窗口**再用。

---

## 第 2 步：拿模型

**大模型不要用 `ollama pull`。** 官方 CDN 对大文件会限速，还会出现"文件长度对了但内容缺块"的情况，无限重试也下不完。

正确做法：**直接下 GGUF 文件，再挂载进去。**

```powershell
# 例：从 ModelScope 下（中国大陆速度最好）
$u='https://modelscope.cn/api/v1/models/<厂商>/<仓库>/repo?Revision=master&FilePath=<文件>.gguf'
curl.exe -L -C - --retry 8 --retry-delay 3 -o "D:\ollama\gguf\<文件>.gguf" "$u"

# 下完必须验哈希（HF 的 lfs.oid 就是 sha256）
(Get-FileHash "D:\ollama\gguf\<文件>.gguf" -Algorithm SHA256).Hash.ToLower()
```

三个源实测速度（同一文件、中国大陆）：**ModelScope 40–110 MB/s ＞ hf-mirror 8–100 MB/s ＞ Ollama 官方 0.86 MB/s**。

写一个 Modelfile（模板要抄，不要自己拼）：

```
FROM D:/ollama/gguf/<文件>.gguf

PARAMETER num_ctx 32768
PARAMETER temperature 0.7
PARAMETER top_p 0.95
```

```powershell
ollama create mymodel -f D:\ollama\gguf\Modelfile
```

> `num_ctx` 是上下文长度。**设大了每轮都会变慢**，按实际需要设：
> 只是聊天 → 8192 够；要喂长文档 → 32768；不缺内存再往上加。

---

## 第 3 步：断网加固（**这一步才是隐私的关键**）

Ollama 默认**开着云功能**，并且**每小时向官方查一次更新**。两步都要关。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\harden-ollama.ps1
```

脚本会（需要管理员，会弹 UAC 点"是"）：

1. 设 `OLLAMA_NO_CLOUD=1`
2. 在 hosts 里把 `ollama.com` / `registry.ollama.ai` / `ollama.ai` 指向 `127.0.0.1`
3. 给 `ollama.exe` 和 `ollama app.exe` 建出网阻断防火墙规则
4. 打印验证结果

**为什么这样不会把推理弄坏**：Windows 防火墙**不过滤回环流量**，所以 `127.0.0.1:11434` 上的本地推理照常工作。

**副作用**：收不到自动更新提示。想升级时手动下安装包。

---

## 第 4 步：验证（不做这步等于没做完）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\verify-local-only.ps1 -Model mymodel
```

逐项检查：服务只监听本机、hosts 生效、防火墙规则在、无登录凭据、**无外部连接**、本地推理能出结果。

全绿就说明：**模型在本机、推理在本机、对话不出机器。**

---

## 怎么用

- **图形界面**：托盘图标 → Ollama 自带聊天窗口（不用敲命令）
- **命令行**：`ollama run mymodel`
- **当别的程序的后端**：OpenAI 兼容地址 `http://127.0.0.1:11434/v1`

---

---

## 两个必须提前知道的事实

### 1. 知识会永久冻结

部署完之后，模型知道的东西就停在训练数据截止日，**不会再更新**。

- **发布时间 ≠ 数据截止日**：2026 年 10 月发布的模型，数据可能只到 2025 年 1 月
- 更新知识只有三条路：微调（普通显卡做不到）、换更新的模型（只能追到它的截止日）、外挂搜索（那是"查"不是"知道"）
- **所有模型都是"过去的快照 + 需要时去查"**，云端也一样

**所以：离线问答用它，时效性问题去搜。**

### 2. 慢通常是"加载"，不是"推理"

同一个模型，实测差距 **10 倍**：

| 状态 | 一次简单问答 |
|---|---|
| 冷（模型未加载） | **33 秒** |
| 热（模型已加载） | **3 秒** |

30 秒全花在加载权重上。想快就让模型常驻：

```powershell
[Environment]::SetEnvironmentVariable("OLLAMA_KEEP_ALIVE","-1","User")
```

代价是空闲时也占着全部内存（26B 约 17 GB）。设 `5m` 则省内存，但每次要重新加载。

---

## 别把它接进 agent 框架

如果你打算把这个本地模型接到某个 agent 框架里当"电脑助手"，**先看这组实测数据**：

- 每轮简单问答 **60~90 秒**
- 调用搜索工具拿到 4,751 字结果，**然后不读，直接说"预计是 X"**
- 同一个问题追问 4 次，**4 次都用"预计 / 应该"填空**
- 会话历史一长，表现更差

**原因**：agent 框架是为云端大模型设计的——云端吞 3 万 token 还保持聪明，本地中小模型吃不下。

**结论：本地模型适合"直接对话"，不适合"当 agent"。**

---

## 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| `ollama` 命令找不到 | PATH 是旧快照，**新开终端** |
| 下载到 90% 卡住不动 | 官方 CDN 的问题。换 ModelScope 直下 GGUF（见第 2 步） |
| 模型跑起来极慢 | 模型太大溢到内存了。换小一档，或开大内存 |
| 上下文一长就变慢 | 就是 KV 缓存的开销。**降 `num_ctx`** |
| 加固后更新不了 | 预期行为。需要更新时手动下安装包 |
| 内存被吃了十几 GB 不放 | 可能残留了 `llama-server.exe`。`Get-Process llama-server` 看一下，手动结束 |

完整的踩坑清单（含 `.ps1` 必须带 BOM、请求体不能带 BOM 等）在 `SKILL.md` 末尾。

---

## 文件说明

```
README.md                       ← 你在看的这份，给人看
SKILL.md                        ← 完整技术文档，给 AI 助手看
scripts/detect-hardware.ps1     ← 测硬件 + 推荐模型档位
scripts/harden-ollama.ps1       ← 断网加固（需管理员）
scripts/verify-local-only.ps1   ← 验证零外连
```
