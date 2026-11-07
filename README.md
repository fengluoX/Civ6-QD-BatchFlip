# QD 批量倒卖

文明 6 模组：挂在 **[Quick Deals（快速交易）](https://steamcommunity.com/sharedfiles/filedetails/?id=2460661464)** 弹窗上的「批量倒卖」页签，按原版 `DealManager` / AI 估价自动批量成交两类套利：

1. **外交支持套利**（需风云变幻）
2. **战略资源套利**（马、铁、硝石、煤、石油、铝、铀等）

不改 AI 报价公式，只按游戏已允许的交易反复询价（`EQUALIZE`）并提交。

---

## 依赖

| 模组 | Steam Workshop |
|------|----------------|
| Quick Deals | [2460661464](https://steamcommunity.com/sharedfiles/filedetails/?id=2460661464) |

本模组 `modinfo` 中声明了对 Quick Deals（`5aceed03-8639-4a81-8cbf-03f54d543502`）的依赖；**未启用 Quick Deals 时不会出现可用入口**。

---

## 安装

### Steam 创意工坊（推荐）

订阅本模组 + Quick Deals，在附加内容中同时启用即可。

### 手动安装（本地 / GitHub Release）

1. 从 [Releases](https://github.com/fengluoX/Civ6-QD-BatchFlip/releases) 下载 `Civ6-QD-BatchFlip-vNN.zip`
2. 解压到：  
   `Documents\My Games\Sid Meier's Civilization VI\Mods\Civ6-QD-BatchFlip\`  
   （解压后该目录下应直接看到 `.modinfo`）
3. 启用本模组与 Quick Deals  
4. **完整退出并重启** 文明 6（改 Lua/XML 后必须杀进程再开）

本地开发可用仓库根目录的 `_link_to_mods.ps1` 做目录联接；**请勿与工坊订阅同 ID 并存**。

---

## 使用

1. 打开 **快速交易** → 切到 **批量倒卖**
2. 勾选要跑的引擎：外交支持 / 战略资源
3. 可调参数：
   - **AI 留金**：成交后 AI 至少保留的现金（默认 `100`，避免 AI 金库被掏到 0 引发异常）
   - **自己留金**：自己至少保留的现金
   - **成交上限**：单次点击最多成交笔数
4. **开始倒卖**：立即按勾选项执行一轮（顺序：战略资源 → 外交支持）
5. **自动执行**：每回合开始时按同一勾选再跑一遍；跑完会自动关掉弹窗。自动开关不写入存档，进档默认关闭。

结果区可看按 AI 汇总或详细流水。排障日志：

`%LOCALAPPDATA%\Firaxis Games\Sid Meier's Civilization VI\Logs\Lua.log`

---

## 执行原理

### 公共机制

- 通过替换 Quick Deals 弹窗脚本注入页签（`ReplaceUIScript` + `AddUserInterfaces`）。
- 每一笔真实交易前都会：清工作交易 → 放入物品 → `INSPECT` / `EQUALIZE` 拿 AI **当次**报价 → 校验安全线 → 再提交。
- 金币折算：`价值 ≈ 一次性金 + 回合金 × GOLD_RATIO`（沿用 Quick Deals 的比率；战略引擎用它做盈亏判断）。
- AI 付钱时通常优先给 **回合金（GPT）**，现金不足时才用库存金；本模组**不限制**掏空回合金，只靠「AI 留金」保底现金。

### 1. 外交支持套利（`BatchFlipFavor`）

社区经验：多数 AI 对「外交支持」存在廉价窗，且每回合与同一 AI 买卖各有约 **20** 点额度。

流程概要：

1. **买入扫掠**：向已会面的 AI 询价；仅当整堆出价为 **1～2 一次性金**、无回合金、且单价严格低于「卖出底价」时买入。
2. **卖出分配**：只卖给「本回合曾卖给我们」的 AI（双向，避免单向倾销给囤货方）；每次只卖 **1 点**，并重新 `EQUALIZE`（AI 持有支持越多，买价会下降）。
3. **再买再卖**：在额度内循环，最多若干轮；每 AI 本回合 `买入≤20`、`卖出≤20`（按游戏回合记账，同回合多次点击共用额度）。
4. 卖出价须 ≥ 配置的「每点最低卖价」；成交后仍保证 AI 留金。

需要风云变幻（存在外交支持资源）；否则引擎会直接提示并结束。

### 2. 战略资源套利（`BatchFlipStrategic`）

利用 AI 对战略资源库存阈值的估值差异（社区常见归纳）：

| AI 库存 | 行为 |
|---------|------|
| **≥ 40** | 视为过剩，愿意**贱卖整堆** |
| **恰好 0** | 愿意以约**双倍**价买进，单笔最多约 **40** |
| **1～39** | 通常**不肯卖**给你 |

因此对每个「资源 × AI」配对，按状态机推进（每步一笔交易）：

```text
库存 ≥40  →  buy：买空其库存（落到 0）
库存 =0   →  sell：一次卖满 40（溢价，常为回合金）→ AI 回到 40
库存 1..39 →  topup：先卖给它 (40−持有)，补到 40，再进入 buy
```

之后循环：`buy → sell → buy → …`，把该 AI 的现金 / 回合金尽量榨到「留金」线附近。

额外规则：

- **卖给 0 库存 AI 必须整手 40**：不够就「等补货」，不零散卖。
- **多轮扫掠（最多 20 pass）**：本轮从 A 买到的资源，下一 pass 可卖给之前因缺货跳过的 B。
- **盈亏熔断**：任意一对完成一轮「买+卖」后若净价值 `< 0`，本回合**立刻停掉该 AI 配对**（部分 AI 不支持这种价差）。
- **报价门槛**：卖出价须覆盖成本（按本轮买入或跨 AI 均摊成本）+ 最低利润（默认 5）；后续买回价也不可明显高于上一笔卖出价。
- 买卖都受双方**库存上限**约束，不会试图让任一方超 cap。

### 调度（`BatchFlipRunner`）

一次运行固定顺序：

1. 若勾选战略资源 → 跑完战略引擎  
2. 若勾选外交支持 → 再跑外交引擎  
3. 合并日志 → 关掉外交会话 UI（弹窗本身手动点开时保留；自动跑完会关弹窗）

---

## 打包 / 上传创意工坊

仓库内脚本会生成 **Steam Workshop Uploader 可直接选取的干净目录**，以及便于分发的 zip：

```powershell
# Windows（推荐）
powershell -ExecutionPolicy Bypass -File .\scripts\pack-workshop.ps1

# 或 Git Bash
bash ./scripts/pack-workshop.sh
```

产物：

| 路径 | 用途 |
|------|------|
| `dist/workshop/Civ6-QD-BatchFlip/` | 给 **Steam Workshop Uploader** 选其中的 `.modinfo` |
| `dist/steam/preview-512.jpg` | Uploader **Select Image...** 预览图 |
| `dist/steam/STEAM_DESCRIPTION.txt` | 上传后粘贴到工坊简介 |
| `dist/steam/UPLOAD.txt` | 上传步骤速查 |
| `dist/Civ6-QD-BatchFlip-vNN.zip` | GitHub Release / 手动安装 |

源素材在仓库 `workshop/`（预览图 + 简介文案）；打包时复制到 `dist/steam/`，**不会**打进游戏模组目录。

上传步骤简述：

1. 安装 Steam 工具 **Sid Meier's Civilization VI Development Tools**（`steam://install/404350`）
2. 运行打包脚本，再启动 → **Steam Workshop Uploader**
3. Upload → 选 `dist/workshop/Civ6-QD-BatchFlip\Civ6-QD-BatchFlip.modinfo`
4. Select Image → 选 `dist/steam\preview-512.jpg`；标签建议 `UI` / `Gameplay` / `Gathering Storm`
5. 上传后到工坊页编辑简介，粘贴 `dist/steam\STEAM_DESCRIPTION.txt`；依赖挂上 Quick Deals
6. 可见性可先「仅好友 / 不公开」，测完再公开

**注意：** 更新工坊时不要改 `.modinfo` 里的 `Mod id`；只需提高 `version` 后重新打包上传。

---

## 仓库结构

```text
Civ6-QD-BatchFlip.modinfo   # 模组清单（版本号、依赖、加载项）
ui/                         # Lua / 页签 XML
text/                       # 本地化
workshop/                   # Steam 预览图 + 简介文案（源）
scripts/pack-workshop.*     # 生成上传产物
```

主要脚本：

| 文件 | 职责 |
|------|------|
| `qd_dealpopup_bf.lua` | 注入「批量倒卖」页签 |
| `bf_popuptab_batch.*` | 页签 UI、自动执行、结果日志 |
| `BatchFlipRunner.lua` | 战略 → 外交 串联 |
| `BatchFlipStrategic.lua` | 战略资源对倒状态机 |
| `BatchFlipFavor.lua` | 外交支持廉价窗套利 |
| `BatchFlipDealSession.lua` | 战略交易会话 / EQUALIZE / 提交 |
| `BatchFlipDealUtil.lua` | 交易与日志工具 |
| `BatchFlipConfig.lua` | 可持久化配置 |

---

## 兼容与风险提示

- `AffectsSavedGames = 0`：不改档结构；关闭模组不影响存档可读。
- 大量 30 回合 GPT 合约可能让部分 AI 净回合金为负；默认 AI 留金 100 是为降低「金库为 0」类异常。若仍遇过回合卡住，先关掉本模组再观察。
- 仅建议单机 / 自愿启用的环境使用；属于利用原版交易与 AI 估价差异的自动化，不修改游戏规则文件。
