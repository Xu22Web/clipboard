# 用 Electron 的划分读这个仓库

这个仓库是一台 Windows 10/11 的剪贴板历史工具，运行环境只有 PowerShell 5.1 与 .NET
Framework 4，没有 Node，也没有 npm 依赖。它的代码与工具链按 Electron 项目的三分法组织：
主进程、preload、渲染进程各占一个目录，构建分成「声明入口/链/文件清单」与「执行引擎」两层。

这份文档说明每个 Electron 概念落在这个仓库的哪个位置，以及哪些地方刻意不同。它不是使用
说明——命令、设置与格式在 `README.md` 与 `README.zh-CN.md`。

## 1. 总表

| Electron | 本项目 | 说明 |
|---|---|---|
| `package.json` 的 `scripts` | `package.ini` 的 `[scripts]` | 命令名 → 命令行，`cli` 只负责路由 |
| `package.json` 的 `version` | `package.ini` 的 `Version` | 版本只有这一处；包目录名由它生成 |
| `electron.vite.config.ts` | `cli.ini` | 入口、插件链、复制清单、开关 |
| `main/index.ts` | `src/clipboard.ps1` | 入口：参数绑定、工具根、模块表 |
| 主进程代码 | `src/lib/*.ps1` + `src/main/**/*.cs` | 常驻循环在 `lib/serve.ps1`，平台层在 C# |
| `preload/index.ts` | `src/preload/client.cs` | 命令行加速器，不是 IPC 桥 |
| `renderer/src/**` | `src/renderer/src/**` | 窗口层：core / store / windows |
| `ipcMain.handle` 注册表 | `src/ipc/channels.ini` | 一行一个通道，带 `Handler=` 与 `Remote=` |
| `ipcRenderer.invoke` | `Invoke-Ipc`（`src/lib/ipc.ps1`） | 窗口调用进程内函数的唯一入口 |
| pinia store | `src/renderer/src/store/` | `Define-UiStore` / `Use-UiStore` / `Patch` / `Reset` |
| Vue / React 组件 | `src/renderer/src/core/` | 盒模型、控件、组件树、视图、响应式 |
| 窗口与页面 | `src/renderer/src/windows/` | 面板、设置窗、托盘菜单、预览卡 |
| vite / rollup | `tools/bundler/bundler.ps1` + `plugins/` | 若干模块合并成一个文件 |
| 导入资源时的 asset 插件 | `tools/bundler/assets.ps1` + `assets/*.ps1` | 每种文件一个 handler |
| electron-builder 的 `files` | `cli.ini` 的 `[copy]` | 哪些文件随包、从哪算起、剔除哪些 |
| electron-builder | `tools/build.ps1` | 一个发布：合并、编译、复制、自检、zip |
| `out/` 或 `release/` | `dist/clipboard-<version>/` | 包目录；`[build] OutDir` 可改 |
| `vite dev` 的热更新 | `tools/dev.ps1` | 监视 + 重建 + 重启常驻，不是热替换 |
| 单元测试 | `tests/run.ps1` + `tests/**` | 十个分件，可指向包内副本再跑一遍 |

## 2. 三个「进程」

### 主进程：常驻循环 + 类型库

- `src/lib/serve.ps1` — 捕获循环、热键注册、托盘、崩溃后退避重启；
- `src/lib/*.ps1` — `store`（历史文件）、`clip`（剪贴板读写）、`media`（图片与富文本）、
  `config`（设置）、`query`（搜索）等，按依赖方向排列；
- `src/main/**/*.cs` — Win32 入口点、窗体、自绘列表、托盘菜单、RTF 排版；由
  `src/main/index.cs` 的 `#part` 清单决定编译集合，产物是 `main/clipboard.dll`；
- `src/clipboard.ps1` — 入口，只做参数绑定、工具根、模块表与运行时路径。

C# 是可选加速：`main/clipboard.dll` 存在且不比源码旧就加载它，否则用 `Add-Type` 现场编译。
两条路都能开面板，差别是冷启动 850 ms 与 1050 ms。

### preload：命令行加速器

`src/preload/client.cs` 编成 `preload/client.exe`，只由 `clipboard.cmd` 在启动 PowerShell
之前调用：它把一条命令行拼成请求帧，交给常驻进程，再把应答打印出来。失败时以退出码
`100` 退回脚本客户端。它不做任何桥接——窗口就在常驻进程内，不需要它。

### 渲染进程：自绘窗口层

`src/renderer/src/` 分三层：

- `core/` — 盒模型、控件、组件树、视图与响应式（`layout`、`widgets`、`component`、
  `framework`、`views`、`setup`、`reactive`、`draw`）；
- `store/` — 窗口读写的状态，pinia 形态；
- `windows/` — 面板、设置窗、托盘菜单、悬停卡与它们各自的绘制与编辑。

源码树里这些是二十多个文件；包内合并成 `renderer/app.ps1`，`clipboard.ps1` 用一次
dot-source 读完。`picker-geom.ps1` 留在包外，因为 `status` 这类不画图的命令也要用它。

## 3. 进程之间能说什么

`src/ipc/channels.ini` 是唯一的清单：一节一个通道，`Handler=` 指定常驻进程里回答它的函数，
`Remote=` 说明命令行是否也能走。`lib/proxy.ps1`（命令行一侧）与 `preload/client.cs`（管道
一侧）都读这一份文件，因此增加一个通道只改一处。

窗口一侧只有 `Invoke-Ipc`：同一通道两种传输——在常驻进程内就是一次函数调用，不在则走命名
管道。

## 4. 构建与打包

三份配置各管一件事，与 Electron 的分法一致：

| 文件 | 相当于 | 管什么 |
|---|---|---|
| `package.ini` | `package.json` | 命令表与版本 |
| `cli.ini` | `electron.vite.config.ts` + `electron-builder.yml` | 入口、插件链、复制清单、`[dev]`/`[build]`/`[test]` 开关 |
| `tools/` | 引擎本身 | 怎么合并一个入口、怎么改写一个文件、怎么编译 C# |

一个入口的产物：

| 入口 | 产物 | 进入包后的位置 |
|---|---|---|
| `[entry.app]`（`Product=renderer`，`Ship=1`） | 一个 .ps1 | `renderer/app.ps1` |
| `[entry.client]`（`Kind=cs`） | 一个 exe | `preload/client.exe` |
| `[entry.main]`（`Kind=cs`） | 一个 dll | `main/clipboard.dll` |

`Ship=1` 的入口由 `build.ps1` 合并，然后与旁边的文件走同一张压缩/改名表——一个包里只有一个
改名器，所以一个短名在包内处处同义。

文件级处理落在 `tools/bundler/assets/`：每种文件一个 handler，`assets.ps1` 里的表决定哪个
路径用哪个。`version` 那一行是链式的——先把 `lib/base.ps1` 的版本块换成常量，再交给
`script`。

包内目录因此读起来像 Electron 的产物：

```
clipboard-<version>/
  clipboard.ps1  clipboard.cmd  clipboard.sh  install.bat  uninstall.bat
  main/clipboard.dll
  preload/client.exe
  renderer/app.ps1
  renderer/src/windows/picker-geom.ps1
  lib/  utils/  schema/  plugins/  themes/  lang/  ipc/
```

## 5. 刻意不同的地方

- **没有独立的渲染进程**：窗口与常驻进程在同一个 PowerShell 进程里，通道调用是函数调用而
  不是跨进程往返。搬出去每次绘制要多一次管道往返，按现在的重绘频率不划算。
- **没有 Node**：运行时是 PowerShell 5.1 与 .NET Framework 4，只在 Windows 上跑。
- **不做 DOM / CSS**：界面是 GDI+ 直绘，「组件」封装的是盒、状态与命中测试，不是样式表。
- **没有热替换**：`dev` 是「停止常驻 → 重建受影响的产品 → 重新启动」，状态随进程一起重建。
- **preload 不桥接渲染进程**：它只服务冷启动的命令行。
- **测试跑真实程序**：分件在 `%TEMP%` 的副本里执行命令、启动常驻进程、读写真实剪贴板；
  同一个套件可以用 `-Source dist\clipboard-<version>` 对包内副本再跑一次。

## 6. 建议的阅读顺序

1. `package.ini` — 有哪些命令；
2. `cli.ini` — 有哪些入口、各自的插件链、包带哪些文件；
3. `src/clipboard.ps1` — 命令如何映射到模块分组，包内单文件与源码多文件两种加载；
4. `src/lib/serve.ps1` — 常驻循环；
5. `src/renderer/src/windows/picker.ps1` — 一个真实窗口的全貌；
6. `tools/build.ps1` — 一次发布的全部步骤。
