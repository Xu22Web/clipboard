# Clipboard

给「精简版 / 离线」Windows 10/11 用的轻量剪贴板历史，一个能替代 Win+V 的单文件 PowerShell 脚本。

系统镜像把 `cbdhsvc` 精简掉了、Win+V 打不开，或者只是不想让剪贴板内容上云 —— 这个脚本不装服务、不要管理员、不联网，丢一个目录就能用。

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## 功能

- 后台轮询剪贴板，保存最近 N 条文本（默认 300 条 / 单条 200 KB / 合计 4 MB）
- 全局热键呼出搜索面板（默认 `Ctrl+Alt+V`），边打字边过滤，回车直接粘贴到原来的窗口
- Explorer 里复制的**文件列表**也能捕获（CF_HDROP），可以原样粘回
- 全键盘操作：`↑` `↓` 选择、`Ctrl+1..9` 快速选取、`Del` 删除、`Esc` 关闭
- 托盘图标：显示历史 / 暂停捕获 / 恢复 / 清空 / 退出
- 深色 / 浅色主题，`ExcludePattern` 正则可以把密码类内容挡在历史之外

## 环境要求

- Windows 10 / 11
- PowerShell 5.1（系统自带，不需要装 .NET 或任何模块）
- 必须以 **STA** 启动 —— 脚本里已经带了 `-Sta`，自己调用时别漏掉

## 快速开始

```powershell
# 在项目目录里
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File .\clipboard.ps1 diag     # 先探一下环境
powershell -NoProfile -ExecutionPolicy Bypass -Sta -File .\clipboard.ps1 serve    # 前台跑守护进程
```

Git Bash / MSYS2 下直接 `./clipboard`，CMD 下 `clipboard.cmd`。

想常驻的话：

```powershell
.\clipboard.cmd install     # 建开机自启 + 桌面快捷方式
.\clipboard.cmd uninstall   # 只删快捷方式，保留历史与配置
.\clipboard.cmd uninstall purge   # 连历史、配置、日志一起删
```

## 命令一览

| 命令 | 说明 |
|---|---|
| `diag` | 探测环境（先跑这个） |
| `restore` | 尝试修复系统原生的 Win+V 历史 |
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
| `install` / `uninstall [purge]` | 增删快捷方式（`purge` 连数据一起删） |
| `help` | 帮助 |

## 配置

首次运行会在脚本旁生成 `clipboard.ini`（扁平 `key=value`，`#` 或 `;` 开头是注释，`[section]` 行会被忽略）。

| 键 | 默认值 | 说明 |
|---|---|---|
| `Hotkey` | `Ctrl+Alt+V` | 全局热键；`Win+V` 在多数系统上被占用，注册失败会自动回退 |
| `PasteKeys` | `^v` | 选定后用 SendKeys 发送的按键（`^+v` = Ctrl+Shift+V） |
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

数据默认放在脚本旁的 `data/`；脚本目录不可写时自动回退到 `%LOCALAPPDATA%\clipboard`。也可以用 `-DataDir <路径>` 显式指定（测试就是这么隔离的）。

## 开机自启与桌面快捷方式

`install` 会建两个快捷方式，两者的目标都是 `powershell.exe`，参数里不带任何「代理进程」或执行策略绕过：

| 快捷方式 | 参数 | 用途 |
|---|---|---|
| `Startup\clipboard.lnk` | `... clipboard.ps1 serve` | 登录时静默启动常驻进程 |
| `Desktop\clipboard.lnk` | `... clipboard.ps1 ui` | 双击打开历史面板 |

> 真正做成 Windows 服务是不可行的：服务跑在 Session 0，没有桌面和托盘、`RegisterHotKey` 收不到用户按键、剪贴板也是按会话隔离的。

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

全部用 `%TEMP%` 下的临时 `-DataDir` 跑，不碰 `data/` 和 `clipboard.ini`；真实剪贴板会在开始前备份、结束后还原。任何一项失败时退出码为 1。

> 跑之前建议先 `clipboard pause`：集成分组会写真实剪贴板，正在运行的常驻进程会把测试文本记进历史。

> `-E2E` 会在运行期间占用全局热键并短暂接管剪贴板；如果已经有常驻进程在跑，这组会自动跳过。
> 图形界面（面板的实际绘制、粘贴注入）仍需手动确认，自动化覆盖不到。

## 常见问题

**杀软把 `clipboard.lnk` 报成 `Trojan/LNK.Runner`**

启发式误报，原因是「快捷方式 + 代理进程 + 隐藏窗口 + 绕过执行策略」这几个特征凑在一起。本项目已经刻意避开：目标直接是 `powershell.exe`，不带 `-ExecutionPolicy Bypass`（客户端默认的 `RemoteSigned` 本来就允许跑本地无签名脚本）。如果你改了 `install` 的生成逻辑，别把 `conhost`/`rundll32` 包装或 `Bypass` 加回去。

**热键没反应**

`status` 看 `active key`：显示 `poll:...` 说明注册被拒、退化成了轮询；显示别的键名说明被其它程序占用后自动回退了。改 `clipboard.ini` 里的 `Hotkey` 后需要重启常驻进程。

**想用回系统的 Win+V**

先 `clipboard diag`，缺服务/缺文件它会给出下一步；`clipboard restore` 能修的只有注册表和 `cbdhsvc` 实例那部分。

## 许可

[MIT](LICENSE) © 2026 Xu22Web
