# Clipboard

Windows 10 / 11 上的轻量剪贴板历史工具，单文件 PowerShell 脚本，提供可搜索的历史面板与全局热键。

数据保存在脚本目录内，不依赖 Windows 剪贴板历史服务（`cbdhsvc`），不联网，也不需要管理员权限。

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

| 深色 | 浅色 |
|---|---|
| ![深色主题的历史面板](docs/screenshot-dark.png) | ![浅色主题的历史面板](docs/screenshot-light.png) |

> 截图里是示例数据，不是真实剪贴板内容。

## 功能

- 后台轮询剪贴板，保存最近 N 条文本（默认 300 条 / 单条 200 KB / 合计 4 MB）
- 全局热键呼出搜索面板（默认 `Ctrl+Alt+V`），边打字边过滤，回车直接粘贴到原来的窗口
- Explorer 里复制的**文件列表**也能捕获（CF_HDROP），可以原样粘回
- 全键盘操作：`↑` `↓` 选择、`Ctrl+1..9` 快速选取、`Del` 删除、`Esc` 关闭
- 列表可滚动：滚轮、`PageUp`/`PageDown`，右侧是自绘的 Win11 风格细滑块（可拖动、可点轨道跳转）
- 托盘图标：显示历史 / 暂停捕获 / 恢复 / 清空 / 退出
- 深色 / 浅色主题，`ExcludePattern` 正则可以把密码类内容挡在历史之外

## 环境要求

- Windows 10 / 11
- PowerShell 5.1（系统自带，无需安装 .NET 或模块）
- 需要 **STA** 线程模型：启动器与快捷方式均带 `-Sta`，直接调用脚本时需自行加上

## 快速开始

```powershell
# 在项目目录里
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File .\clipboard.ps1 diag     # 检查运行环境
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File .\clipboard.ps1 serve    # 前台运行常驻进程
```

Git Bash / MSYS2 下直接 `./clipboard`，CMD 下 `clipboard.cmd`。

常驻运行：

```powershell
.\clipboard.cmd install     # 建开机自启 + 桌面快捷方式
.\clipboard.cmd uninstall   # 只删快捷方式，保留历史与配置
.\clipboard.cmd uninstall purge   # 连历史、配置、日志一起删
```

`install` 生成的快捷方式以 `-ExecutionPolicy RemoteSigned` 运行脚本，可覆盖目标机 `Restricted` / `AllSigned` 的评估结果；需要更宽松的策略时用 `install bypass`。

## 命令一览

| 命令 | 说明 |
|---|---|
| `diag` | 检查运行环境 |
| `restore` | 尝试恢复系统原生剪贴板历史的相关设置 |
| `serve` | 运行常驻进程（捕获 + 热键 + 托盘） |
| `stop` | 停止常驻进程 |
| `ui` | 打开历史面板（常驻进程没跑会自动拉起） |
| `list [-Count N]` | 列出条目，最新在前 |
| `put "text"` | 写入剪贴板（省略文本时读 stdin） |
| `get` | 输出剪贴板文本 |
| `pick N` | 把第 N 条放回剪贴板 |
| `del N` | 删除第 N 条 |
| `clear` | 清空历史 |
| `pause` / `resume` | 暂停 / 恢复捕获 |
| `status` | 常驻状态、自启状态、生效热键、存储路径 |
| `config [edit\|init]` | 查看配置 / 用记事本编辑 / 重写模板 |
| `install [bypass]` / `uninstall [purge]` | 增删快捷方式（`bypass` 改用 `-ExecutionPolicy Bypass`；`purge` 连数据一起删） |
| `help` | 帮助 |

## 配置

首次运行会在脚本旁生成 `clipboard.ini`（扁平 `key=value`，`#` 或 `;` 开头是注释，`[section]` 行会被忽略）。

| 键 | 默认值 | 说明 |
|---|---|---|
| `DataDir` | 空 | 写入位置；空 = 脚本旁的 `data/`。相对路径相对脚本目录，`-DataDir` 优先 |
| `Hotkey` | `Ctrl+Alt+V` | 全局热键；`Win+V` 在多数系统上被占用，注册失败会自动回退 |
| `HotkeyFallbacks` | 空 | 逗号分隔的回退链，按顺序尝试；空 = 内置 Ctrl+Alt+V / Win+V / Alt+反引号 / Win+Shift+V |
| `PasteKeys` | `^v` | 选定后用 SendKeys 发送的按键（`^+v` = Ctrl+Shift+V） |
| `ModReleaseTimeout` | `1200` | 最多等多久（毫秒）让修饰键松开再注入粘贴 |
| `PasteSettle` | `80` | 切回原窗口后、发 `PasteKeys` 前等待的时长（毫秒）；目标应用响应较慢时可增大 |
| `MaxItems` | `300` | 最多保留条数 |
| `MaxBytes` | `204800` | 单条上限，超出不入库 |
| `MaxTotal` | `4194304` | 总容量上限，超出丢最旧的 |
| `Interval` | `300` | 剪贴板轮询间隔（毫秒） |
| `NoPaste` | `0` | `1` = 只写剪贴板，不自动粘贴 |
| `Balloon` | `1` | `1` = 启动时弹托盘气泡 |
| `Theme` | `dark` | `dark` / `light` |
| `ExcludePattern` | 空 | 正则，匹配到的文本永远不会入库 |

命令行开关优先级高于配置文件，例如 `clipboard put hi -MaxItems 50`。

## 文件与数据

```
clipboard            Git Bash / MSYS2 启动器（sh 壳，负责把路径转成 Windows 形式）
clipboard.cmd        CMD 启动器
clipboard.ps1        主程序（单文件）
clipboard.ini        配置，首次运行自动生成（不入库）
data/                历史 / 日志 / 生效热键缓存（不入库）
tests/run-tests.ps1  自测套件
```

写入位置按 **`-DataDir` > `clipboard.ini` 的 `DataDir=` > 脚本旁 `data/`** 解析；`config` 的 `data dir` 与 `status` 的 `store file` 均显示实际生效位置。

不写入 `%LOCALAPPDATA%` 或其它用户目录：写入位置不可写时输出错误信息并以退出码 1 结束，不会回退到其它位置。除 `install`（两个快捷方式）与 `restore`（注册表项）外，脚本不写注册表。

## 开机自启与桌面快捷方式

`install` 会建两个快捷方式，目标均为 `powershell.exe`，不使用代理进程包装；参数中的 `-ExecutionPolicy RemoteSigned` 用于覆盖目标机 `Restricted` / `AllSigned` 的本地策略：

| 快捷方式 | 参数 | 用途 |
|---|---|---|
| `Startup\clipboard.lnk` | `-NoProfile -ExecutionPolicy RemoteSigned -Sta -WindowStyle Hidden -File "...\clipboard.ps1" serve` | 登录时静默启动常驻进程 |
| `Desktop\clipboard.lnk` | `-NoProfile -ExecutionPolicy RemoteSigned -Sta -WindowStyle Hidden -File "...\clipboard.ps1" ui` | 双击打开历史面板 |

> 本工具不作为 Windows 服务运行：服务位于 Session 0，没有桌面与托盘，`RegisterHotKey` 收不到用户输入，剪贴板也按会话隔离。

## 测试

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File tests\run-tests.ps1
```

三组用例，默认全跑，也可以单独指定：

| 组 | 开关 | 覆盖内容 |
|---|---|---|
| 单元 | `-Unit` | 纯函数与存储层：`Parse-Hotkey`、`Format-Item`、`Read-Ini`/`Write-IniTemplate`、`Add-Item`/`Get-Items`/`Save-Items`（去重、裁剪、超限、排除规则）。通过 `-Library` dot-source 主脚本，不触发命令分发 |
| 集成 | `-Integration` | 每条 CLI 能力都起子进程验证：`put`/`get`/`list`/`pick`/`del`/`clear`/`pause`/`resume`/`status`/`diag`，以及 ini 与命令行开关的优先级 |
| 端到端 | `-E2E` | 拉起真实常驻进程 → 校验热键注册 → 复制内容验证捕获链路 → 暂停后不再捕获 → `stop` 后干净退出且没有重启循环 |

全部在 `%TEMP%` 下的临时 `-DataDir` 中运行，不修改 `data/` 与 `clipboard.ini`；真实剪贴板在开始前备份、结束后还原。任一项失败时退出码为 1。

> 检测到常驻进程时会临时 `pause`，跑完先恢复剪贴板再 `resume`（原本已处于 paused 则保持不动）。

> `-E2E` 在运行期间占用全局热键并接管剪贴板；已有常驻进程时这组自动跳过。
> 图形界面（面板绘制、粘贴注入）不在自动化范围内。

## 常见问题

### 安全软件把快捷方式判为 `Trojan/LNK.Runner`

`install` 生成的快捷方式目标为 `powershell.exe`，不带 `-ExecutionPolicy Bypass`（客户端默认策略 `RemoteSigned` 已允许运行本地无签名脚本）。部分安全软件的启发式规则会把「快捷方式 + 系统代理进程（`conhost` / `rundll32`）+ 隐藏窗口 + 执行策略绕过」的组合判为 `LNK.Runner`，因此本工具不使用代理进程包装。

### 快捷方式提示「在此系统上禁止运行脚本」

快捷方式默认带 `-ExecutionPolicy RemoteSigned`。若仍被拒绝，按顺序检查：

1. 脚本带网络来源标记（从压缩包或下载目录解出）—— 执行 `Unblock-File .\clipboard.ps1`
2. 需要更宽松的进程级策略 —— `clipboard install bypass`（改用 `-ExecutionPolicy Bypass`）
3. 组策略（`MachinePolicy` / `UserPolicy`）已指定执行策略 —— 此时 `-ExecutionPolicy` 参数不生效，`install` 会打印 `group policy defines the execution policy` 提示

### 热键无响应

`status` 的 `active key` 反映实际生效的按键：

- `poll:<键>` —— 候选热键全部注册失败，退化为 `GetAsyncKeyState` 轮询
- 与 `Hotkey` 不同的键名 —— 首选键被其它程序占用，已按 `HotkeyFallbacks` 回退
- `(stopped)` / `(daemon never started)` —— 常驻进程未运行

修改 `Hotkey` 后需要重启常驻进程。

### 恢复系统自带的 Win+V

`diag` 逐项列出环境检查结果；`restore` 针对注册表项（`EnableClipboardHistory`、策略 `AllowClipboardHistory`）与 `cbdhsvc` 实例执行恢复。文件层面的缺失（如 `TextInputHost.exe`）无法通过脚本修复。

## 许可

[MIT](LICENSE) © 2026 Xu22Web
