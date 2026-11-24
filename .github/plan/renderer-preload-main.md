# renderer / preload / main 三层拆分与打包器改造

状态：待确认（P0 未开工）。本文件是实现计划，不是交付物，不进包、不进 README。

## 0. 对齐术语（Electron → 本项目）

| Electron | 本项目 | 现状 |
|---|---|---|
| main process | 常驻进程（`cli serve`）＋ `main/clipboard.dll` | `src/lib/*.ps1` + `src/lib/assembly/cb.native.cs` 混在一起 |
| renderer（窗口） | 设置窗、历史面板、预览、编辑器、托盘菜单 | `src/lib/panel/*.ps1`，各自手写 GDI+ |
| preload（胶水层） | `preload/client.exe` | 已有，但只做 CLI 快速代理，不是 IPC 桥 |
| ipcMain / ipcRenderer | `channels.ini` + 生成的 Router 与分发桩 | 无，全部同进程直接调函数 |
| Vite / Rollup | `tools/bundler/`（本计划新增） | `tools/build.ps1` 走 `pipeline.ps1` 一张表，无入口概念 |
| Pinia | `renderer/src/store/`（本计划新增） | `lib/ui/reactive.ps1` 只有信号与 effect，没有 store |

关键现实：**窗口今天全在常驻进程里**（托盘、设置、面板同进程；`Raise-Settings` 读同进程的 `$script:SetWantGroup` 就是证据）。所以三层拆分是**契约分层**，不是必须引入进程边界。传输层允许两种实现，见 §3。

## 1. 三条必须先定的决策

| # | 问题 | 建议 | 影响 |
|---|---|---|---|
| D1 | renderer 到底几个入口包 | **3 个**：`app.ps1`（主界面 + 预览 + 编辑器共用一套 surface）、`settings.ps1`、`tray-menu.ps1` | 若要 5 个只是 ini 多两节，不返工 |
| D2 | 设置窗是否搬出常驻进程 | **不搬**。`app`/`settings`/`tray-menu` 走 Local 传输；`preload/client.exe` 只服务冷启动 CLI 与未来独立窗口 | 搬出去每次绘制多一次命名管道往返（约 0.3–1 ms/次），现在悬停重绘是按脏矩形做的（8.4 ms），会退化 |
| D3 | `src/renderer/src/` 里再套一层 `src` | **保留**（electron-vite 惯例，用户指定）。代价是路径长一层 | 无 |

未收到反对即按上表执行。

## 2. 目标目录

```
src/
  clipboard.ps1                 入口：解析参数 → 定传输 → 载 renderer 入口 → 调 main
  clipboard.ini  clipboard.cmd  clipboard.sh
  ipc/
    channels.ini                唯一事实源：通道 → 处理器 → 传输/返回类型
  main/
    index.cs                    装配清单：#part 引入各层，只有它被编译器当根
    ipc/        router.cs  frame.cs  pipe-server.cs  events.cs  gen.router.cs(生成)
    store/      records.cs  blobs.cs  gate.cs  store-version.cs
    clip/       reader.cs  writer.cs  formats.cs  modifiers.cs
    media/      png.cs  cfhtml.cs  rtf.cs  image-cache.cs
    search/     search.cs
    ui/         win32.cs  fluent-form.cs  hot-window.cs  pin-list.cs  tray.cs  tray-skin.cs
    reactivity/ reactive-bag.cs  reactive.cs  computed-cell.cs
    utils/      paths.cs  log.cs  hashing.cs  time.cs  json.cs
  preload/
    client.cs                   单文件：CLI 代理 + `--call/--watch` IPC 桥（生成区由 channels.ini 填充）
  renderer/src/
    core/                       框架层，不放业务（用户 4 个目录之外新增，理由见下）
      layout.ps1  widgets.ps1  views.ps1  framework.ps1  component.ps1  reactive.ps1  setup.ps1
    components/
      icon.ps1  button.ps1  tag.ps1  switch.ps1  scroll-view.ps1  skeleton.ps1
      input.ps1  dropdown.ps1  multiselect.ps1  path-picker.ps1
      hotkey-input.ps1  hotkey-list.ps1
      context-menu.ps1  preview-popup.ps1          （业务组件）
    store/
      index.ps1（New-StoreHost = createPinia）  define.ps1（defineStore/storeToRefs）
      settings-store.ps1  history-store.ps1  ui-store.ps1  plugin-store.ps1
      plugins/persist.ps1（写 clipboard.ini）  plugins/logger.ps1
    windows/
      app.ps1  preview.ps1  editor.ps1  settings.ps1  tray-menu.ps1
    utils/
      ipc.ps1（Invoke-Ipc，两种传输）  theme.ps1  i18n.ps1（Get-UiText 包装）  geo.ps1  log.ps1
  utils/  schema/  lang/  themes/  plugins/    （保留原位：纯函数与数据不属三层）
tools/
  bundler/
    bundler.ini                 入口 + 每个产品的插件链
    bundler.ps1                 编排：读配置 → 解析图 → 跑插件钩子 → 写 dist
    plugins/
      resolve.ps1     ps1-load 的模块解析（读 #requires 与模块表）
      ps-treeshake.ps1  ps-minify.ps1  ps-rename.ps1
      cs-part.ps1     main/index.cs 的 #part 图
      cs-inject.ps1   把生成区写进 client.cs / router.cs
      ipc-gen.ps1     读 channels.ini，产出三种胶水
      cs-compile.ps1  cs-verify.ps1  ps-verify.ps1
      assets.ps1      ini / lang / themes / bat
      manifest.ps1  zip.ps1  verify.ps1（跑打包副本自检）
```

`core/` 为什么单开：用户列的 4 个目录里没有「框架」。`layout/widgets/framework/views/reactive/setup` 不是组件而是运行环境，塞进 `components/` 会让 13 个组件与 7 个框架文件混在一起，也不要塞进 `store/`。若坚持只要 4 个目录，退路是 `renderer/src/core` → `renderer/src/utils/framework/`。

## 3. 三层契约（先定契约，再搬文件）

### 3.1 `src/ipc/channels.ini`

```ini
# 一行一个通道。渲染层能调的方法全部在这里，其余三处产物由 ipc-gen 插件生成。
[channel.store.get]
Handler=store/records.cs:GetRecord        ; C# 侧入口，用于 Router 与漂移检查
Returns=json                              ; json | text | void | stream
Transport=local,remote                    ; local 同进程直调，remote 走 preload
Async=0

[channel.clip.put]
Handler=clip/writer.cs:Put
Returns=json
Transport=local
```

生成物（三份 + 一份测试，全部写在 `//@gen-begin <name>` / `//@gen-end` 之间）：

1. `src/main/ipc/gen.router.cs`：`Router.Dispatch(string channel, string json)` 的 switch
2. `src/preload/client.cs` 的生成区：`--call` 的通道表与参数校验
3. `src/renderer/src/utils/ipc-channels.ps1`：`$script:IpcChannels` 哈希表（通道 → 传输/返回）
4. `tests/unit/ipc-channels.ps1`：**漂移断言**——ini 里的每个通道都能在 main、preload、renderer 三处找到；三处没有多余的。

`utils/ipc.ps1` 暴露一个函数：

```powershell
$r = Invoke-Ipc 'store.get' @{ Id = 3 }     # -> @{ Ok = $true; Value = ...; Error = '' }
```

`Test-IpcLocal` 判断 `Cb.Main.Router` 是否已加载：在内则直调（亚微秒），不在则拼帧给 `preload\client.exe --call`。**同一通道两种传输都必须在**，漂移测试守着。

### 3.2 传输取舍

| 场景 | 传输 | 代价 |
|---|---|---|
| 常驻进程内的窗口（今天全部） | local | 函数调用 |
| `clipboard get` 等命令行 | remote（现有 client.exe 快路径） | ~150 ms，已达成 |
| 未来拆出去的窗口 | remote（`--call` / `--watch`） | 0.3–1 ms/次，需按脏矩形绘制 |

## 4. bundler 设计（参考 rollup 的钩子，vite 的入口）

### 4.1 `tools/bundler/bundler.ini`

```ini
[bundler]
OutDir=dist
Verify=1
Zip=0
Overwrite=1
VersionFrom=package.ini

# 每个产品的插件链，按列出的顺序挂载；插件自身也有 Order，冲突时以本表为准
# merge 必须排在 rename/minify 之前：合并出一个 AST，再改写，再压缩
[product.renderer]
Plugins=resolve,ps1-treeshake,ps1-merge,ps1-rename,ps1-minify,ps1-verify

[product.main]
Plugins=cs-part,cs-inject,cs-compile,cs-verify

[product.preload]
Plugins=cs-inject,cs-compile,cs-verify

[product.host]
Plugins=ipc-gen,ps1-minify,ps1-rename,ps1-verify

# 一个 [entry.<name>] 就是一节构建：From 可以有多个，#part 由 cs-part 解析
[entry.app]
Product=renderer
From=renderer/src/windows/app.ps1
To=renderer/app.ps1
Chunk=inline
Keep=components/**,store/**,utils/**,core/**

[entry.settings]
Product=renderer
From=renderer/src/windows/settings.ps1
To=renderer/settings.ps1
Chunk=inline
Keep=components/**,store/**,utils/**,core/**

[entry.tray]
Product=renderer
From=renderer/src/windows/tray-menu.ps1
To=renderer/tray-menu.ps1
Chunk=inline

[entry.main]
Product=main
From=main/index.cs
To=main/clipboard.dll
Compiler=csc
Optimize=1
Target=library

[entry.preload]
Product=preload
From=preload/client.cs
To=preload/client.exe
Compiler=csc
Optimize=1
Target=exe

[entry.host]
Product=host
From=clipboard.ps1
To=clipboard.ps1
Inject=channels
```

键全部进 `tools/schema/bundler.ps1`，与 `tools/schema/cli.ps1` 同一套 `Test-ToolConfigMap`，拼错即停。

### 4.2 插件接口

```powershell
# tools/bundler/plugins/ps1-treeshake.ps1 只导出 $Plugin 一个变量
$Plugin = @{
  Name  = 'ps1-treeshake'
  Order = 20
  Options        = { param($ctx) }
  BuildStart     = { param($ctx) }
  ResolveId      = { param($ctx, $id) }        # 返回绝对路径或 $null
  Load           = { param($ctx, $path) }      # 返回 @{ Id; Code; Ast; Kind }
  Transform      = { param($ctx, $mod) }       # 返回 @{ Code; Ast } 或 $null
  ModuleParsed   = { param($ctx, $mod) }
  RenderChunk    = { param($ctx, $chunk) }
  GenerateBundle = { param($ctx, $bundle) }
  WriteBundle    = { param($ctx, $out) }
  CloseBundle    = { param($ctx) }
}
```

`$ctx` 带 `Entry`（当前节）、`Config`（整份 ini）、`Modules`（id → module）、`Graph`、`Log`、`Tmp`。

模块记录：`@{ Id; Path; Kind = 'ps1'|'cs'|'ini'; Code; Ast; Tokens; Calls; Opaque; SideEffects }`。
**`ps1-merge` 的输出不是字符串而是 `@{ Nodes; Using; Param }`**，下一级（rename）拿到节点再改写，emit 只在链尾做一次。

**现有逻辑的落点**：
- `tools/utils/pipeline.ps1` 的 `LibraryRules`/`Products`/`FlattenRules` → `assets.ps1` + `cs-compile.ps1` 里的规则表，pipeline.ps1 保留给 `dev.ps1` 的监视器过渡一版，P6 删。
- `tools/utils/minify.ps1`（844 行）原样搬进 `plugins/ps-minify.ps1`，其中的 rename 三段（函数名/脚本变量/共享作用域变量）拆到 `ps-rename.ps1`，并用 `RenderStart` 做全局预扫——这就是现在的 `New-FunctionMap`/`New-ScriptVariableMap`/`New-GlobalVariableMap`。
- `tools/build-assembly.ps1` / `build-client.ps1` 变成 `cs-compile.ps1` 里的两行参数，脚本本身保留（`cli assembly` / `cli client` 两个命令还用）。

### 4.3 合并必须是 AST 节点级，不是文本拼接

硬规则：**打包路径上不允许出现「读文件 → 字符串相加 → 写文件」**。模块边界、函数边界、变量改写全部由解析器给出的节点与 token 决定；不得用正则找 `function `、不得按空行/注释头切分、不得用 `-replace` 摘 `#region`。

PowerShell 没有 AST 写出器（节点只读），所以「AST 合并」的落地方式是：**用 AST 决定一切边界，只在节点 extent 上做切片与改写，最后整体过一次压缩并重新解析校验**。现有 `tools/utils/minify.ps1` 已经是这个模型（`Get-ParsedScript` → `Apply-Edits` → `Merge-Statements` → `Compress-Whitespace` → 复查解析），bundler 复用同一套，只是从「逐文件」改成「合并后一次」。

#### 4.3.1 合并管线

| 阶段 | 输入 | 用到的 AST 事实 | 产物 |
|---|---|---|---|
| **parse** | 每个模块的源码 | `Parser::ParseInput` → `ScriptBlockAst` + `Tokens` + `Errors` | module = `@{ Id; Ast; Tokens; Code }` |
| **classify** | `ScriptBlockAst.EndBlock` | `UsingStatementAst` / `ParamBlockAst` / `FunctionDefinitionAst` / 其余 `StatementAst`；`BeginBlock`·`ProcessBlock`·`EndBlock`·`DynamicParam`·`TrapStatementAst` 是否存在 | 拒绝清单命中即 Fail，见 §4.3.3 |
| **link** | 各模块的 `FunctionDefinitionAst` 名 | 定义表 + `CommandAst.GetCommandName()` 的调用表；`& $var`·`Get-Command`·`Invoke-Expression` 即 `Opaque` | 函数级可达集合 |
| **rewrite** | 每个 `VariableExpressionAst` / 标识符 token | `VariablePath.IsScript` / `UserPath` / `IsDriveQualified`；`$PSScriptRoot`·`$PSCommandPath` 单独识别 | 与今天相同的 `Apply-Edits` 偏移改写：函数名、`$script:` 名、脚本作用域名 |
| **hoist** | `UsingStatementAst` 与入口的 `ParamBlockAst` | 语句种类，不靠位置猜 | 只能出现在合并结果最前，且各至多一份 |
| **emit** | 有序的节点列表 | `node.Extent.StartOffset/Length`（或 `Tokens[i].Extent`） | 一段文本：节点原样切片 + 单换行分隔 |
| **minify** | 合并后的文本 | 整个 bundle 一棵 AST | 一次 `Compress-Whitespace` + `Merge-Statements` |
| **verify** | 最终文本 | 重新解析 + 指纹比对（§4.5） | 通过或带节点名 Fail |

**顺序由配置决定，不由文件系统决定**：合并顺序取 `resolve` 插件解析出的模块序列（等于今天 `$baseModules` + 分组表的顺序）。dot-source 是「后者覆盖前者」，同序合并保持完全相同的覆盖语义。

**每个模块的「正文」怎么取**（全部来自 AST，无启发式）：

```
body = $ast.EndBlock.Statements            # 顶层语句序列
       - ParamBlockAst（只允许来自入口）
       - UsingStatementAst（统一提升）
       - FunctionDefinitionAst 中不可达者（§4.4）
用 EndBlock.Statements 逐项取 extent，而不是「读全文去掉头注释」
```

`#region` / 文件头注释 / 空行都在语句的 extent 之外，天然不入包，不需要剥离代码。

#### 4.3.2 必须做的 AST 改写（否则语义会变）

1. **`$PSScriptRoot` / `$PSCommandPath`**：合并后全部指向 `renderer\app.ps1`，与今天指向 `lib\` 不同。`rewrite` 阶段把每个这样的 `VariableExpressionAst` 换成 `$script:<bundle root 变量>`，并在合并结果顶部注入一次由入口算出的根。有专门用例：一个模块里的 `Join-Path $PSScriptRoot 'x'` 在包内与源码内结果一致。
2. **函数重名**：同作用域下后者覆盖前者，与 dot-source 一致。合并时保留全部定义并**记一条警告**（今天静默覆盖，包里不该继续静默）。
3. **`$script:` 名**：一个 bundle 一个作用域，所以 `New-ScriptVariableMap` / `New-GlobalVariableMap` 从「共享文件集」改成「本 bundle 的模块集」，一次算完再改写——比今天更准。
4. **`Set-StrictMode` / `$ErrorActionPreference` 等顶层语句**：属于 `StatementAst`，按序保留，语义自然一致。

#### 4.3.3 无法合并的构造 → 直接失败，不要糊过去

`BeginBlock` / `ProcessBlock` / `EndBlock` 命名块、`DynamicParam`、`TrapStatementAst`、`AttributeAst`（`[CmdletBinding()]` 之类附在脚本块上）、模块自带的 `ParamBlockAst`、`#Requires` 不一致。命中即 `Fail` 并指出「模块 X 的第 N 个顶层语句是 <节点类型>，该模块不能被内联进入口」。这几类只能留作独立文件，由 ini 里的 `Chunk=shared` 或 `External=` 处理。

### 4.4 tree-shaking：PowerShell 侧的可达性

PS1 没有 ESM，也没有可静态判定的导出。定义**可达性**，丢弃发生在**节点层**（不选进 `emit` 列表），不做第二遍文本删除：

1. 节点 = `FunctionDefinitionAst`（定义）+ 其余 `StatementAst`（顶层副作用）。
2. 根 = 入口的顶层语句 + `Keep=` 命中的文件 + （`-Library` 模式下）全部。
3. 边 = 静态可识别的调用：`Foo-Bar args`、`Foo-Bar(...)`、`& Foo-Bar`、`CommandAst` 里的名字。
4. **不可静态识别即整文件保守保留**：`& $var`、`Get-Command`、`Invoke-Expression`、`Set-Item Function:`、`Get-ChildItem plugins\*.ps1 | .`。命中即给该模块打 `Opaque`，整份进包并在日志里点名。
5. 被丢弃的定义按模块汇总成一行日志；`Opaque` 与丢弃数一起进 `manifest.json`。
6. 安全网：每入口的「函数名集合」写进 `dist/<name>/.bundle.json`；下次构建对比，消失的函数若出现在 `tests/` 的任何字符串里，直接失败（拦「测试按名字点函数」，`-Library` 场景）。

保守策略的收益仍可观：`settings.ps1` 入口不需要 `picker.ps1`（1778 行）、`media-render.ps1`（695）、`transfer`、`migrate`、`usage`。

### 4.5 验收：AST 指纹，而不是「跑起来没报错」

合并不出错的判据不能只是「打包副本自检绿」。`ps1-verify` 在每个 bundle 上做四条指纹比对：

| 检查 | 期望 | 拦的是 |
|---|---|---|
| 函数定义多重集 | = 各模块 AST 的并集 − 不可达集合 | 切片漏掉/重复了一段 |
| `UsingStatementAst` 与 `ParamBlockAst` | 各至多 1，且在最前 | 顺序错误 |
| 顶层 `StatementAst` 顺序 | = 模块序列 × 各自顺序 | 合并顺序错导致覆盖语义变 |
| 命令名集合 | ⊇ 原文所有 `CommandAst` 名字（减去已改写的内部函数） | 一段 extent 切片切进了字符串/注释 |

另外两条静态自检，跑在 bundler 自己的源码上：

- bundler 源码里出现 `-replace` / `-split` / `Split(` 作用在模块源码上 → 失败（把「不许文本拼接」变成可执行的约束）
- `emit` 阶段产出的分隔符只能是换行；出现 `;` 拼接语句即失败（`Merge-Statements` 之后才允许）

### 4.6 C# 侧：词法级指令解析 + 编译器接收文件列表

`src/main/index.cs` 是唯一编译根：

```csharp
// #part ipc/router.cs
// #part ipc/frame.cs
// #part store/records.cs
```

`cs-part.ps1` 做传递闭包得到**编译文件列表**，csc 直接接收这个列表——**从不生成拼接后的 .cs**。所以 C# 侧不存在文本合并问题，语法解析由 csc 自己完成。

唯一需要自己解析的是 `#part` 指令本身，且必须用**词法扫描**而非正则：跳过 `//` 行注释、`/* */` 块注释、`"..."`、`@"..."`（`""` 转义）、`$"..."`、`$@"..."`、字符字面量与预处理行 `#if/#region`。只有落在「顶层代码位置」的 `// #part <path>` 才算指令；出现在字符串或注释里的同样文本必须被忽略——这条有专门用例（构造一份含 `// #part` 字样的字符串常量，断言不被当成指令）。

`#part` 一律相对当前文件解析，禁止 `..` 越出 `src\main\`（防跨区耦合）。没进闭包的文件不参与编译，等于从 IL 里不存在——.NET Framework 上最接近 treeshaking 的做法（csc 没有 ILLink）。再加 `/optimize+ /debug-`，`cs-verify.ps1` 断言产物中不含被排除类型的名字（`strings` 或 `ildasm` 等价手段）。

### 4.7 声明式导入导出（已实现：P0 的一部分）

PS1 没有 `import`/`export` 关键字，而「谁依赖谁」现在是靠调用名反推的，反推不出「不能调」这类错误。所以每个模块可以用两条注释指令把自己的边界说清楚：

```powershell
#@use lib/ui/component, utils/dpi        # 我调用哪些模块
#@export New-UiBox, Get-UiStack           # 别处可以调我的哪些函数
```

为什么是注释而不是真语句：声明描述的是**构建**而不是程序本身。发布出去的副本仍旧按今天的方式 dot-source，一个声明对它必须是零成本的，也不能要求运行时去理解它。读取走的是 `Tokens` 里的 `Comment` 节点——字符串、here-string、块注释里的同样文本都不算声明，这条有用例守着。

有了声明就能在构建前做纯静态检查（`Get-BundleSurfaceReport`）：

| 检查 | 拦的是 |
|---|---|
| 调用方用到的名字，所属模块未 `#@export` | 没对外公开的内部函数被别处调用 |
| 调用方用到的名字，所属模块不在本入口的 `Modules=` 里 | 「module group too small」那类只在运行时才暴露的缺失 |
| `#@export` 写了本模块没定义的函数 | 改名/删除后忘了改声明 |
| 同一个名字被两个模块导出 | 调用有歧义 |
| `#@use` 指向不在入口里、或不存在的模块 | 模块清单漏项 |
| 入口带着但没有任何 `#@use` 指向的模块 | **警告**：这正是 shake 会删掉的东西 |

未写声明的模块不参与跨模块校验（逐步迁移），但它们会让「会被丢弃」的结论失效，所以那种情况下只报「有多少模块没声明」。`cli bundle -Inspect -Suggest` 会按真实调用关系打印每个模块该写的 `#@use` / `#@export`，复制即可。

到 P1 结束后，每个入口应当满足 `Declared == Total`；那之后 `Treeshake=1` 才改为默认，且模块级可达性直接取 `#@use` 闭包，不再依赖调用名反推。

## 5. dist 布局

```
dist/clipboard-0.5.0/
  clipboard.ps1      clipboard.cmd      clipboard.sh
  renderer/app.ps1   renderer/settings.ps1   renderer/tray-menu.ps1
  preload/client.exe
  main/clipboard.dll
  lang/*.ini  themes/*.ini  scripts/install.bat  scripts/uninstall.bat  plugins/*.ps1
```

对照现在的包（91 个文件，`lib\`、`utils\`、`schema\` 平铺）：
- `lib\panel\*.ps1` 12 个文件 → 3 个入口包
- `lib\ui\*.ps1` 7 个 + `lib\settings-*.ps1` 3 个 → 内联进 3 个入口包
- `lib\assembly\clipboard.dll` → `main\clipboard.dll`
- `client.exe` → `preload\client.exe`
- 入口 `clipboard.ps1` 从 224 行缩到约 120 行：解析参数 → 选传输 → 载入口 → 调 main

`Chunk=inline` 是默认（每个窗口一个进程，只读一个文件）。若某天框架代码显著大于业务代码，改成 `Chunk=shared` 产出 `renderer/chunk-framework.ps1`，入口用 `. $PSScriptRoot\chunk-*.ps1` 引入——ini 换一个值，插件已有分支。

## 6. 现有文件搬迁映射

| 现有 | 去向 | 说明 |
|---|---|---|
| `lib/ui/layout.ps1` `widgets.ps1` `views.ps1` `framework.ps1` `component.ps1` `reactive.ps1` `setup.ps1` | `renderer/src/core/` | 原样搬，文件名不变 |
| `lib/ui/widgets.ps1` 里的 `Draw-UiButton`/`Draw-UiIconButton`/`Draw-UiKeyChip`/`Draw-UiToggle`/`Draw-UiScrollbar` | `components/{button,icon,tag,switch,scroll-view}.ps1` | 由 `Register-UiView` 注册为组件，widgets 只留绘制原语 |
| `lib/panel/preview.ps1`（673） | `components/preview-popup.ps1` + `windows/preview.ps1` | 先拆「弹窗本体」与「入口」 |
| `lib/panel/picker.ps1`（1778）里的右键菜单段 | `components/context-menu.ps1` | 托盘菜单不动 |
| `lib/hotkey-record.ps1`（94） | `components/hotkey-input.ps1` | 多键录制新增 `hotkey-list.ps1` |
| `lib/settings-types.ps1`（399）里的 combo/多选/路径类型 | `components/{dropdown,multiselect,path-picker}.ps1` | 类型校验留原处，绘制与交互搬走 |
| `lib/panel/picker-edit.ps1` `settings-edit.ps1` 的 Edit 创建与滚动 | `components/input.ps1` | 两处现在各写一遍 |
| `lib/panel/anim.ps1`（79） | `components/skeleton.ps1` 的驱动 | 加载态才画 |
| `lib/panel/settings.ps1`（1673） | `windows/settings.ps1` | `$script:Set*` 信号迁进 `store/settings-store.ps1` |
| `lib/panel/tray-menu.ps1`（222） | `windows/tray-menu.ps1` | `Cb.TrayMenu` 已是 C#，只搬 PS 侧组装 |
| `lib/panel/picker*.ps1` 其余 | `windows/app.ps1` | 与 preview/editor 共用 surface |
| `lib/settings-model.ps1` `settings-vm.ps1` | `store/settings-store.ps1` + `core/framework.ps1` 的 keyed diff | 行 diff 已由 `Sync-UiTree` 承担 |
| `lib/assembly/cb.native.cs`（2309） | `src/main/**` 13–16 个 .cs | 按 §2 分区，`namespace Cb.Main.<Area>` |
| `lib/client/client.cs`（321） | `preload/client.cs` | 加生成区与 `--call/--watch` |
| `lib/proxy.ps1` `dispatch.ps1` `serve.ps1` | 原位 | 属 main 的 PS 侧，不在本次搬迁 |

## 7. 分阶段实施

每阶段的**退出条件**都是同一套：`cli test -Unit -Integration` 全绿 → `cli build` 通过且打包副本自检绿 → 设置窗截图像素差 ≤ 上一轮噪声（2–31 px）→ 一次提交。

| 阶段 | 规模 | 内容 | 风险 |
|---|---|---|---|
| **P0 骨架 + AST 合并** | M | 建空目录与 `bundler.ini`/`channels.ini` 雏形；`bundler.ps1` 只做一件事但做对：`resolve → ps1-treeshake → ps1-merge → ps1-rename → ps1-minify → ps1-verify` 全链跑通，产物等价今天的逐文件 minify；同时把现有全部模块过一遍§4.3.3 的拒绝清单，先拿到「不能内联」的真实名单；`clipboard.ps1` 改成双根解析 | 中。合并语义错误会静默生效，靠§4.5 四条指纹拦 |
| **P1 main 拆分** | L | `cb.native.cs` 按分区拆成 `src/main/**`，`index.cs` 写 `#part`；`cs-part` + `cs-compile` 插件跑通；`Add-Type` 回退路径同步改 | 中。`Add-Native` 的类型可见性、`InternalsVisibleTo`、静态构造顺序 |

P1 已落地（2026-11-24）：机制就位并可增量搬迁。

- `tools/bundler/plugins/50-cs-part.ps1` 逐字符扫描 `// #part x.cs`（字符串、verbatim、插值、块注释里的同样文本不算），`60-cs-compile.ps1` 把闭包交给 csc；**从不生成拼接后的 .cs**。
- `[entry.main]` 的 `Append=src/lib/assembly/*.cs` 承载尚未搬走的类型，`cli assembly` 与 `cli build` 都走它。
- 首个搬迁：`Cb.Search` → `src/main/search/search.cs`（`cb.native.cs` 减少 41 行）。
- `native.ps1` 的回退改成按文件列表 `Add-Type -Path`，并把 `main\**\*.cs` 的时间戳纳入新鲜度判断（否则改了新文件仍会用旧 dll）。
- `pipeline.ps1` 的产品表支持 `Dir = 'lib\assembly,main'`；`cli.ini` 两份 Includes 带上 `src/main/**/*.cs`。
- **剩余 15 个类型按同一手法逐个搬迁**；全部搬完后删掉 `Append=` 那一行与 `cb.native.cs`，再把 `native.ps1` 的 `lib\assembly` 目录扫描改成只认 `main\`。
| **P2 通道与 preload** | M | `channels.ini` 填 30–40 条（覆盖 renderer 与 CLI 今天真正用到的）；`ipc-gen` 产出三处胶水 + 漂移测试；`utils/ipc.ps1` 两种传输 | 中。通道粒度太粗会把绘制也塞进 IPC |
| **P3 store** | M | `New-StoreHost`/`defineStore`/`state·getters·actions`/`$subscribe`/`$patch`/`$reset`/`storeToRefs`；`plugins/persist.ps1` 负责写 ini；设置窗的 `Set*` 信号迁入 | 中。`$script:` 共享作用域一旦并成一个文件，变量名冲突会暴露（`$RS` 那类） |
| **P4 组件** | L | 13 个组件按复用度排：tag/switch/icon/button → input/dropdown/multiselect/path/hotkey/hotkey-list → scroll-view/skeleton → context-menu/preview-popup。每个都有 `Draw/Measure/Hit` 三件套 + 一条单元用例 | 高。这是全部界面代码的再写法 |
| **P5 windows** | M | 5 个窗口源 + 3 个入口包；`clipboard.ps1` 按命令选入口 | 中。单实例锁与 doorbell 的同进程假设要复核 |
| **P6 bundler 完整** | L | 插件拆齐、`docs`/`lang`/`themes` 走 assets 插件、`dev.ps1` 监视器改读 bundler 图、`shot.ps1` 找新路径、`tests/pkg/build.ps1` 34 条断言改写、README×2 | 中。断言改写量大但机械 |

P0–P2 可以连续做，P3/P4 之间建议停一版（store 先落地，组件再吃它）。

## 8. pinia 式 store 的 API 面

```powershell
# store/define.ps1
$SettingsStore = Define-UiStore 'settings' {
  param($ctx)
  $ctx.State   = @{ Page = ''; Pending = 0; Msg = '' }
  $ctx.Getter('HasPending') { $ctx.State.Pending -gt 0 }
  $ctx.Action('SetPage', { param($p) $ctx.State.Page = [string]$p })
  return $ctx
}
# 使用
$s = Use-UiStore 'settings'
$s.SetPage('General')
$s.HasPending          # getter，读时求值并缓存
$s.$subscribe({ param($mutation) })   # 写之后
$s.$onAction({ param($name, $args) }) # action 之前/之后，可包装
```

与现有 `core/reactive.ps1` 的关系：store 的 `State` 就是 `Cb.ReactiveBag`，`getter` 用 `New-UiComputed`，`$subscribe` 用 `Add-UiRender`。**不新造响应式**，只加一层命名与生命周期（`New-StoreHost` = `New-UiApp` + 注册表 + 插件）。

## 9. 必须同步的清单（漏一处就红）

1. `src/clipboard.ps1` 的模块表 → 改成入口表（`$rendererEntries`）
2. `tests/unit/unit.ps1` 的 `$requiredLib` → 新路径清单
3. `cli.ini` `[build] Includes/Excludes` → 换成 `bundler.ini` 的入口；`[dev]` 同步
4. `tools/dev.ps1`（406 行）的监视器与产品识别 → 改读 bundler 图
5. `tools/shot.ps1`（559 行）里窗口脚本路径
6. `tests/pkg/build.ps1` 34 条断言（布局、`lib\` 前缀、docs 分节、`client.exe` 位置）
7. `README.md` + `README.zh-CN.md` 文件树与模块清单（两份必须一致）
8. `src/lang/*.ini`：新组件的 `settings.*` / `mark.*` 键两种语言同时加
9. 压缩器：新代码里**任何实参位置的 `[类型]` 转换都要先赋变量**（已踩两次）
10. `tools/bundler/` 新增时：`docs`/`tools` 不进包，但「打包器本身」要不要跟包走由 `bundler.ini` 的 `ShipTools=0` 显式写出

## 10. 明确的非目标

- 不引入进程边界（D2）
- 不改 `package.ini` 版本、不重打 `v0.5.0`
- 不做 CSS/HTML：renderer 仍是 GDI+ 直绘，组件只封装「盒 + 状态 + 命中」
- **打包路径上不做文本拼接**：模块边界一律取 AST 节点 extent（§4.3）
- 不把 `schema/`、`lang/`、`themes/`、`plugins/` 搬进三层：它们是数据与纯函数
- `core/reactive.ps1` 仍不提供 `ref()` / `watch(source, cb)`（标量信号即 ref，`Add-UiHook 'updated'` 即 watch）
- 不删 `New-UiStore` / `New-UiAsync` / `Sync-UiChildren` 三处死代码（另一次独立提交）

## 11. 风险与止损

| 风险 | 表现 | 止损 |
|---|---|---|
| 单个入口包把多文件的 `$script:` 并成一个作用域 | 变量互撞（`$RS`/`$US` 这类历史事故） | P0 就定命名前缀规则：`$script:<领域><名>`；`ps1-verify` 加一条「同包内 `$script:` 赋值重复」断言 |
| 合并改变 `$PSScriptRoot` 含义 | 模块里算出的路径在包里指到 `renderer\` | §4.3.2 的根注入改写 + 一条专门用例；P0 先做全仓 `$PSScriptRoot` 用量盘点 |
| 合并不了的东西被发现得太晚 | 到了 P5 才发现某个模块带 `ParamBlock` | §4.3.3 的拒绝清单在 P0 就实现，并在现有全部模块上跑一次，先知道名单 |
| `GetNewClosure()` 与压缩器改名交互 | 包内某组件静默失效，开发态正常 | 每阶段必跑 `cli build` + 打包副本自检，不只看单测 |
| 通道粒度太细 | 绘制期间 IPC 往返拖慢 | 只有「取数据/写数据」进通道；绘制全部在 renderer |
| C# 拆分后类型可见性 | `Add-Type` 回退路径编译失败 | P1 保留 `cb.native.cs` 一份到 P1 结束，`git revert` 即回滚 |
| 34 条打包断言同时红 | 分不清是改造错还是断言过时 | P6 单独一个阶段，之前不改 dist 布局 |
