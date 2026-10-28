# transform —— 粘贴前改写文本

[← 回到主说明](../../README.md) · [插件契约](../../README.md#插件)

选中条目按 `Enter` 粘贴时，先把内容按指定模式改写：纯文本、全大写、全小写、驼峰、蛇形、烤肉串、标题式。适合往 IDE / 终端 / 数据库里粘"格式要求不同"的同一段内容。

## 启用

```ini
# clipboard.ini — 默认已经包含本插件；删掉这一名字才会关闭
Plugins=entry-actions,item-marks,retention,transform
```

不加载时粘贴走原始文本，`transform` 是未知命令。

## 命令

| 命令 | 作用 |
|---|---|
| `clipboard transform N` | 用配置里的 `Mode` 改写第 N 条，并写入剪贴板 |
| `clipboard transform "N mode"` | 临时指定模式（整体要加引号） |

```
$ clipboard transform 1 upper
[upper] HELLO WORLD DEMO

$ clipboard transform "1 snake"
[snake] hello_world_demo
```

## 模式

| `Mode` | 效果 | 示例（输入 `Hello World demo`） |
|---|---|---|
| `keep` | 不改写（默认） | `Hello World demo` |
| `text` | 纯文本：换行与连续空格压成单个空格 | `Hello World demo` |
| `upper` | 全大写 | `HELLO WORLD DEMO` |
| `lower` | 全小写 | `hello world demo` |
| `camel` | 驼峰 | `helloWorldDemo` |
| `snake` | 蛇形 | `hello_world_demo` |
| `kebab` | 烤肉串 | `hello-world-demo` |
| `title` | 标题式 | `Hello World Demo` |

驼峰 / 蛇形 / 烤肉串 / 标题式会先按空格、下划线、连字符以及小写→大写的边界切词，再按目标格式拼接。

## 右键菜单

右键菜单里每个**配置的模式**各占一项：`Transform as snake_case`、`Transform as UPPER`……点哪项就用哪个模式改写这一条，**写进剪贴板后直接把结果粘贴回原来的窗口**（不用再点一次条目），同时记入历史。项目多少由 `transform.Modes` 决定：

```ini
# clipboard.ini：右键给这三个模式各开一项（顺序即菜单顺序）
transform.Modes=snake,kebab,upper
```

- `transform.Modes` 默认就是**全部七个模式**；留空等同于默认值。
- 名字不区分大小写、空格与逗号都可以当分隔符；重复的名字会被丢掉，写错的名字会让整个值回到默认值，并在 `clipboard config` / `status` 里报一行提示。
- 文件清单条目不显示（同粘贴路径，不改写路径）；空条目也不显示。
- `Mode` 只管**粘贴**用哪个模式；`Modes` 只管**菜单列**哪些模式，两者互不影响（可以 `Mode=keep` + `Modes=snake,upper`，即粘贴不改写、只在需要时手动转）。
- 右键项由插件自己声明（`ContextMenu` 写成脚本块，自己算出要多少项）；基础层按插件分组显示：每组开头一行插件名，组间一条分隔线。

## 设置项（`clipboard.ini`）

| 键 | 默认 | 说明 |
|---|---|---|
| `transform.Mode` | `keep` | 粘贴时使用的改写模式（`keep` / `text` / `upper` / `lower` / `camel` / `snake` / `kebab` / `title`） |
| `transform.Modes` | `text,upper,lower,camel,snake,kebab,title` | 右键菜单列出的模式，逗号分隔；只接受上表七个模式，其余值会被拒绝 |
| `transform.Trim` | `1` | `1` = 去掉结果首尾空白 |

```powershell
clipboard config set transform.Mode snake
clipboard config set transform.Modes 'snake,kebab,upper'
clipboard config set transform.Trim 0
```

## 说明

- **改写规则只有一份**：粘贴钩子、`transform` 命令与右键项都调用插件里的 `Apply` / `CopyAs` 块，不存在两套容易走偏的实现；命令行只是多了一步「取第 N 条 → 写剪贴板 → 记入历史」。
- **文件清单条目不会被改写**：粘贴的是一批文件路径，改写会破坏路径。
- 改写只发生在**粘贴路径**上；`clipboard get` / `clipboard put` 与历史里存的内容保持原样。
- 常驻进程在跑时，`config set transform.Mode ...` 会自动重启常驻进程使新值生效。
- 一次性模式（`clipboard transform "3 upper"`）不改配置，只影响这一次调用。
