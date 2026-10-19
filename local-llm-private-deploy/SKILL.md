---
name: local-llm-private-deploy
description: "在 Windows 上从零部署一个完全本地、不外传数据的大模型：按显存/内存推荐模型档位、装 Ollama、绕开官方 CDN 下模型、断网加固、验证零外连。适合想要隐私优先本地方案的人。当用户说「想在自己电脑上跑大模型」「不想让对话上传云端」「本地部署 AI 但不要联网」「显卡能跑多大模型」「Ollama 怎么装/下载卡住/怎么彻底断网」时用。"
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [windows]
metadata:
  hermes:
    tags: [ollama, local-llm, privacy, windows, gguf, quantization, offgrid]
---

# 本机私有大模型部署（Windows）

一句话目标：**模型跑在自己机器上，推理过程一个字节都不出网。**

本 skill 只做「部署 + 隐私加固 + 验证」，不谈别的。全程约 30–60 分钟，取决于网速。

## 0. 先测硬件，再选模型（顺序错了会白下 20 GB）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/detect-hardware.ps1
```

会输出：显卡型号 / 显存 / 内存 / 磁盘剩余 / 推荐档位。

### 选型公式（**权重 + KV + 计算缓冲**一起算，别只看权重）

```
可用显存 = 总显存 − 桌面占用（约 1 GB）
权重额度 = 可用显存 − KV cache − 计算缓冲（约 0.3 GB）

Q4_K_M 权重      ≈ 0.63 GB / 10 亿参数
KV cache / token ≈ 0.1 MB（常规 dense 模型）
                 ≈ 0.004 MB（滑窗注意力的模型，如 Gemma 4 —— 几乎不随上下文涨）
```

### 档位对照（实测值，可直接照抄）

| 显存 | 内存 | 推荐 | 说明 |
|---|---|---|---|
| 4–6 GB | 16 GB | **7–8B dense** Q4_K_M（约 4.5 GB） | 全在显存，速度最快 |
| **6–8 GB** | 16 GB | **8B dense** Q4_K_M（约 5.2 GB） | 实测 43 tok/s，甜点 |
| **6–8 GB** | **≥32 GB** | **MoE 26–30B** Q4（15–18 GB） | 显存放 5–6 GB，其余进内存；实测 27–29 tok/s |
| 10–12 GB | 16 GB | **12–14B dense** Q4 | |
| 16 GB | 32 GB | 14B dense 宽裕 / 27B MoE 混合 | |
| 24 GB | 32 GB+ | 27–32B dense Q4 | |
| 40 GB+ | 64 GB+ | 70B Q4 | |

### 基座优先级：**默认优先非中文基座**

理由（与内容无关，只说隐私与工程）：不同基座来自不同训练数据与不同辖区，**数据来源越分散，单一供应商的可见面越小**。
中文基座作为备选——中文能力更强，适合主要以中文长文为主的场景。

**怎么查当前有什么（别凭记忆，模型迭代以月计）：**

```
https://hf-mirror.com/api/models?author=<org>&sort=createdAt&direction=-1&limit=15
https://hf-mirror.com/api/models?search=<name>-GGUF&sort=downloads&direction=-1
```

命名陷阱：`qwen3:8b` 的 `8b` 是**参数量标签**，`qwen3.5`/`qwen3.8` 才是**代际**。两者不是一回事。

**选型必查三件事（缺一件就会白下 10 GB）：**

1. **体积** —— 权重 + KV + 缓冲一起算（见上面的公式），别只看权重
2. **数据截止日** —— 查模型卡；不写就实测。**发布时间 ≠ 截止日**（详见 §6）
3. **支持语言** —— 模型卡写 `language: [en]` 的，中文场景直接排除

经验：**中文场景优先 Qwen 系**；**英文/多语场景优先 Gemma / Llama / Mistral**。

**推荐组合**（2026-10 实测可用，按硬件自己挑尺寸）：

| 场景 | 首选 | 备选 |
|---|---|---|
| 8 GB 显存 + 大内存 | 非中文 MoE（如 Gemma-4 26B-A4B） | 中文 MoE（Qwen3-30B-A3B） |
| 8 GB 显存 + 小内存 | 非中文 8B（Llama / Gemma 8–12B） | 中文 8B（Qwen3-8B） |

## 1. 装 Ollama

```powershell
# ① 先把模型目录钉到非系统盘（必须在拉模型之前！）
New-Item -ItemType Directory -Force -Path "D:\ollama\models" | Out-Null
[Environment]::SetEnvironmentVariable("OLLAMA_MODELS","D:\ollama\models","User")
$env:OLLAMA_MODELS = "D:\ollama\models"

# ② 下载安装包（约 1.5 GB）
curl.exe -L -C - --retry 5 -o "$env:TEMP\OllamaSetup.exe" "https://ollama.com/download/OllamaSetup.exe"

# ③ 验签（应为 Valid / Ollama Inc.）
Get-AuthenticodeSignature "$env:TEMP\OllamaSetup.exe" | Select-Object Status,SignerCertificate

# ④ 静默安装（Inno Setup）
cmd /c '"%TEMP%\OllamaSetup.exe" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART'
```

- 程序本体固定装 `%LOCALAPPDATA%\Programs\Ollama`（**不能改目录**）
- 装完自动注册 PATH 和开机自启（启动文件夹 `Ollama.lnk`）
- **`ollama` 命令当前终端认不到**（PATH 是终端启动时的快照）→ 新开终端，或用全路径 `%LOCALAPPDATA%\Programs\Ollama\ollama.exe`

## 2. 拿模型（**不要用 `ollama pull` 下大模型**）

官方 registry 的 CDN 对大文件会限速并且分片会"下洞"——文件长度对、哈希不对，无限重试。

**正确做法：直接下 GGUF，再 `ollama create` 挂载。**

```powershell
$u='https://modelscope.cn/api/v1/models/<org>/<repo>/repo?Revision=master&FilePath=<file>.gguf'
curl.exe -L -C - --retry 8 --retry-delay 3 -o "D:\ollama\gguf\<file>.gguf" "$u"

# 下完必须验（HF API 的 lfs.oid 就是 sha256，加 ?blobs=true 才有）
(Get-FileHash "D:\ollama\gguf\<file>.gguf" -Algorithm SHA256).Hash.ToLower()
```

三个源实测速度（同一文件、中国大陆）：**ModelScope ≈ 40–110 MB/s ＞ hf-mirror ≈ 8–100 MB/s ＞ Ollama registry 0.86 MB/s**。

**Modelfile**（模板一定要抄，不要自己拼）：

```
FROM D:/ollama/gguf/<file>.gguf

PARAMETER num_ctx 8192
PARAMETER temperature 0.7
PARAMETER top_p 0.95
```

```powershell
ollama create <name> -f D:\ollama\gguf\Modelfile
```

视觉模型要加第二行 `FROM <mmproj>.gguf`，`ollama show` 的 Capabilities 里出现 `vision` 才算挂上。

## 3. 隐私加固（**本 skill 的重点**）

默认状态下，Ollama 会做两件事：**开着云功能**、**每小时向 ollama.com 查更新**。两步都关掉。

```powershell
# ① 关云功能（免管理员，重启服务生效）
[Environment]::SetEnvironmentVariable("OLLAMA_NO_CLOUD","1","User")
```

```powershell
# ② hosts 屏蔽 + ③ 防火墙阻断（需管理员）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/harden-ollama.ps1
```

脚本会：备份 hosts → 追加 `127.0.0.1 ollama.com` / `registry.ollama.ai` / `ollama.ai` → 给 `ollama.exe` 和 `ollama app.exe` 建出网阻断规则 → 打印验证结果。

**关键原理，必须知道**：**Windows 防火墙不过滤回环流量**，所以阻断出网**不会**影响 `127.0.0.1:11434` 的本地推理。加固后推理照常。

**副作用**：收不到自动更新提示。想升级手动下安装包。

## 4. 验证（不做这步等于没做完）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify-local-only.ps1 -Model <name>
```

逐项检查：
- 服务只监听 `127.0.0.1`（不是 `0.0.0.0`）
- 本地推理能出结果
- **Ollama 进程零外部连接**
- `ollama.com` 解析到 `127.0.0.1`
- 无登录凭据（`~/.ollama` 下只有本地签名密钥，不是 token）

## 5. 怎么用

**图形界面**：托盘图标 → Ollama 自带聊天窗口（不用敲命令）
**命令行**：`ollama run <name>`
**当外部程序的后端**：OpenAI 兼容端点 `http://127.0.0.1:11434/v1`

## 6. 知识时效：这是本地方案的天花板

**权重不变，知识就不变。** 部署完之后，模型知道的东西永久冻结在训练数据截止那一天。

### 三条铁律

**① 发布时间 ≠ 数据截止时间。** 2026-10 发布的模型，数据可能只到 2025-01。**必须查模型卡**，不要按发布日期推断。

**② 很多模型卡根本不写截止日。** 查不到就只能实测：问几个「某年某月发生的具体事件」，答得出来说明截止更晚。

**③ 只支持英文的模型不能给中文用。** 模型卡里 `language: [en]` 是硬伤——不是开关，是没在中文语料上训练过。它会吐中文字符，但语法错乱、术语乱译。

### 想更新知识，只有三条路，两条走不通

| 路 | 结果 |
|---|---|
| **微调 / 继续预训练** | 改权重。8 GB 显存做不了 20B 以上，差一个数量级 |
| **换截止日更晚的模型** | 只能追到目标模型的截止日；而且新出的小尺寸模型多是**编码专用或纯英文** |
| **外挂检索（搜索 / RAG）** | ✅ 唯一能拿到「当代信息」的办法 —— 但那是**「查」不是「知道」** |

### 一个必须认清的事实

**所有模型都是「过去的快照 + 需要时去查」**，包括云端大模型。云端也得靠搜索，区别只是快照新几个月。

所以正确的心态不是「怎么让它知道今天」，而是**「离线问答用它，时效性问题去搜」**。

## 7. 速度的真实构成（别把加载时间算成推理慢）

同一个模型，实测差距可以到 **10 倍**：

| 状态 | 耗时（26B MoE，一次简单问答） |
|---|---|
| **冷**（模型未加载） | **33 秒** |
| **热**（模型已加载） | **3 秒** |

**30 秒全在加载权重，不是推理。** 用户抱怨「慢」时，先分清是哪一种。

### 三个决定速度的因素

**① `keep_alive` 决定热不热。**
```powershell
[Environment]::SetEnvironmentVariable("OLLAMA_KEEP_ALIVE","-1","User")   # 永不卸载
```
设为 `-1` 后模型常驻，每次都是秒级；代价是空闲时也占着全部内存（26B 约 17 GB）。
设短（如 `5m`）则省内存，但每次都要重新加载。
**验收方法**：`curl /api/ps` 看 `expires_at`——显示几百年后就是常驻生效了。

**② MoE 看「激活参数」，不看总参数。**
`26B-A4B` = 26B 总参数但**每次只算 4B**。所以它的生成速度和 4B 模型同档，知识量却是 26B 的。选型时别被总参数量骗。

**③ 滑窗注意力让长上下文几乎免费。**
常规模型 KV 约 **0.1 MB/token**（65536 上下文要 6 GB+）；
滑窗注意力的模型（如 Gemma 4）实测 **约 0.004 MB/token**，上下文从 8K 拉到 128K，内存只多 0.5 GB。

### 关于 `num_ctx`

`ollama create` 会把 `num_ctx` **固化进模型**，覆盖全局 `OLLAMA_CONTEXT_LENGTH`；客户端未必能改。
**必须用 `/api/ps` 的 `context_length` 核对实际值**，不要假设。

设大了不会明显变慢（见上面 ③），但**KV cache 是预分配的，加载就占满**。

## 8. 边界：不要把这个模型接进 agent 框架

**这一节是实测教训，不是理论推演。**

把 26B 本地模型接到一个 agent 框架（27 个工具、上万 token 系统提示词、几十条会话历史）里跑，实测结果：

| 问题 | 表现 |
|---|---|
| **每轮极慢** | 简单问答 **60~90 秒** |
| **调用工具但不读结果** | 搜到 4,751 字搜索结果，然后说「预计是 X」 |
| **反复编造** | 同一个问题追问 4 次，4 次都用「预计 / 应该」填空 |
| **把无关文件当证据** | 搜到一个不相干的模板文件，就说「说明我具备该能力」 |
| **越聊越乱** | 历史越长，上下文越重，表现越差 |

**根因**：agent 框架是为云端大模型设计的——云端吞 3 万 token 还能保持聪明。本地中小模型吃不下这么大的上下文还保持能力。

**结论：本地模型只适合「直接对话」（Ollama 自带界面 / `ollama run`），不要塞进 agent 框架。**

需要「读文件 + 调工具 + 多步任务」时，用云端模型；本地模型的价值是**离线 + 隐私**，不是**能力**。



1. **`.ps1` 脚本必须带 UTF-8 BOM** —— PowerShell 5.1 读无 BOM 文件会按 GBK 解码，中文变乱码，乱码字节吃掉引号 → 语法报错，且**脚本静默不产出任何结果**。
   ```powershell
   $t=[IO.File]::ReadAllText($p,[Text.Encoding]::UTF8)
   [IO.File]::WriteAllText($p,$t,(New-Object System.Text.UTF8Encoding($true)))   # $true = 写 BOM
   ```
2. **curl 的 JSON 请求体必须无 BOM** —— 有 BOM 会被判非法 JSON，返回空 body 且不报错。
3. **`if (...) {} else {} | Out-File` 在 PowerShell 里是解析错误**（"An empty pipe element is not allowed"），管道要放进每个分支里。
4. **`ollama stop` 可能卡住**；**直接杀 `ollama.exe` 会留下孤儿 `llama-server.exe`**，白占几 GB 到 20 GB 内存，而 `/api/ps` 看不到它。重启前先 `ollama stop <模型>`；事后 `Get-Process llama-server` 检查。
5. **`ollama create` 会把 `num_ctx` 固化进模型**，覆盖全局 `OLLAMA_CONTEXT_LENGTH`。要用 `/api/ps` 的 `context_length` 核对实际值。
6. **hosts 追加注意换行** —— 字符串拼接出错会让注释和记录挤成一行，那条屏蔽就失效了。写完 `Get-Content hosts -Tail` 复核。
7. **测速时不要同时跑重 I/O**（比如递归扫模型目录）—— 实测能把结果压低近一倍。脚本独占机器，监控只用轻量查询。
8. **模型加载比想象中快**（18 GB 约 20 s，靠磁盘缓存），别按"GB 数 ÷ 磁盘速度"报 ETA。
9. **`pip install` 在国内会被重置**（`ConnectionResetError 10054`）→ 换镜像：
   ```powershell
   python -m pip install -i https://pypi.tuna.tsinghua.edu.cn/simple <包名>
   ```
10. **Python 的 TLS 指纹会被中间设备切断**（`SSL: UNEXPECTED_EOF_WHILE_READING`），而 **curl 能过**。
    抓网页时不要让 Python 直接发请求，**用 `curl.exe` 子进程**：
    ```python
    subprocess.run(["curl.exe","-s","-L","--max-time","30","-A",UA,url], capture_output=True)
    ```
    实测同一地址：Python urllib 失败，curl 返回 200 —— **这不是网络问题，是 TLS 栈的差异**。
11. **Ollama 服务必须常驻**。关掉开机自启后，重启电脑再调用会报 `Connection error`，**错误信息完全看不出是"服务没开"**。
    排查顺序：`curl /api/version` → 没响应就是服务没起。
12. **模型卡经常不写数据截止日**。查不到就实测，别用发布日期推断。


## 完成标志

```powershell
ollama list                      # 模型在
curl http://127.0.0.1:11434/api/version    # 服务活着
# verify-local-only.ps1 全绿
```

到这一步：**模型在本机、推理在本机、对话不出机器。**
唯一还会出网的是你自己主动发起的联网请求（如果有的话）——那些请求里带什么，由你控制。
