# entry-actions —— 看清条目，再对它动手

[← 回到主说明](../README.md) · [插件契约](../README.md#插件)

一个插件同时管两件事，因为它们本来就是一件事：**先判断这条是什么，再按类型对它操作**。

- **判断**：`kind` 给出类型、大小、目标拆解（域名 / 路径 / 邮箱 / 文件清单）以及嗅探到的格式（JSON、XML、Base64、颜色、IP、UUID、哈希…）；`kinds` 统计整个历史里各类型的分布。
- **动手**：`open` 按类型打开——链接丢给浏览器、文件路径在资源管理器里定位、文件清单打开第一个。

## 启用

```ini
# clipboard.ini
Plugins=entry-actions
```

不启用时：`kind` / `kinds` / `open` 都是未知命令，面板没有 `Ctrl+O`，右键没有 `Open link or path`。

## 命令

### `clipboard kind N` —— 分析一条

```
$ clipboard kind 3
entry 3   kind link
  size    : 41 chars   1 line(s)   3 word(s)
  target  : https   example.com   /docs/start   ?q=1
  format  : (none)
  state   : pinned, age 4m
  preview : https://example.com/docs/start?q=1
```

`target` 一行按类型变化：

| 类型 | `target` 内容 |
|---|---|
| `link` | 协议、主机、路径、查询串 |
| `mail` | `user` / `domain` |
| `path` | 文件名、扩展名、所在目录、是否存在 |
| `files` | 文件数量 + 前 5 个文件名 |
| `code` | 语法猜测（C / C# / Python / PowerShell / JavaScript / Java / Go / SQL） |

`format` 一行由多个嗅探器叠加而成，例如 `json, colour #FF6600, rgb(255,102,0)`、`base64 128 bytes`、`hash sha256`、`uuid`、`ipv4`、`date`、`version`、`number 1234.5`、`yaml-like`。

### `clipboard kinds` —— 看整体分布

```
$ clipboard kinds
kinds in 42 entries:
  link     12    29%
  path      5    12%
  files     3     7%
  code      2     5%
  multi     6    14%
  text     14    33%
  1 pinned   1 starred   chars 18422
```

### `clipboard open N` —— 按类型打开

| 条目类型 | 动作 |
|---|---|
| 链接（`http` / `https` / `ftp` / `file`） | 用 `Browser` 指定的浏览器打开，留空则用系统默认 |
| 文件路径 | `Reveal=1` 在资源管理器里定位该文件，`0` 直接运行 |
| 文件清单（资源管理器里多选复制得到） | 取第一个文件，行为同上 |
| 其他 | `Start-Process` 交给 shell |

```
$ clipboard open 4
opened: https://example.com/docs/start
```

## 面板与右键

| 位置 | 行为 |
|---|---|
| `Ctrl+O` | 打开当前选中的链接 / 路径（对不支持的条目自动不响应） |
| 右键 `Open link or path` | 同上，仅对链接 / 路径 / 文件清单显示 |

`Ctrl+O` 与右键项共用同一套判断与执行逻辑，所以两者行为永远一致。

两个入口都调用插件里的共享块，不是各自复制一份：

| 块 | 作用 |
|---|---|
| `KindOf` | 条目 → 类型（命令、菜单、按键、`kinds` 统计都用它） |
| `CanOpen` | 这一行能不能打开（右键项与 `Ctrl+O` 的 `Test`） |
| `OpenPayload` | 真正执行打开（命令、右键项、`Ctrl+O` 都调它） |
| `Sniff` | 格式嗅探（只返回结果，不管输出格式） |

## 设置项（`clipboard.ini`）

| 键 | 默认 | 说明 |
|---|---|---|
| `entry-actions.Detail` | `full` | `kind` 的输出形式：`short` = 单行摘要，`full` = 完整分块 |
| `entry-actions.PreviewChars` | `100` | `kind` 预览保留的字符数（20–400） |
| `entry-actions.Detect` | `json,xml,yaml,base64,color,ip,uuid,number,version,date,hash` | 启用的嗅探器，逗号分隔；写不认识的名称会被忽略 |
| `entry-actions.ShowTargets` | `1` | `1` = 打印 `target` 行（链接 / 路径 / 邮箱 / 文件清单拆解） |
| `entry-actions.Browser` | 空 | 打开 http(s) 链接用的浏览器 exe，空 = 系统默认 |
| `entry-actions.Reveal` | `1` | `1` = 文件在资源管理器里定位，`0` = 直接运行 |

```powershell
clipboard config set entry-actions.Detail short
clipboard config set entry-actions.Detect json,base64,hash
clipboard config set entry-actions.Reveal 0
```

## 说明

- 基础工具只区分**文本**与**文件列表**（`Get-EntryKind`，用于存储、行图标与粘贴往返）；本插件自带更细的分类器（`KindOf`），命令、右键与 `Ctrl+O` 都用它判断条目类型，不存在第二份分类规则。
- 条目上的标记（置顶 / 收藏 / 高亮）不写在本插件里：`kind` 的 `state` 行向基础层要标记名称（`Get-RecordMarkWords`），`kinds` 的尾行用同源计数，所以装不装 `item-marks` 都不会出错。
- 嗅探只取前 8000 个字符，避免大段文本拖慢输出；`json` 用 `ConvertFrom-Json` 真正解析一次，解析失败会显示 `json-like (invalid)`。
- 嗅探会读取条目内容但不会写入任何东西，也不会修改历史。
