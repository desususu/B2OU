# B2OU

[English README](README.md)

![B2OU hero](docs/hero.png)

Bear → Obsidian / Ulysses 导出工具（macOS）。
运行逻辑使用 Swift 实现，菜单栏 UI 和各个工具窗口使用 SwiftUI 构建。

最新版本：[v6.1.0](https://github.com/desususu/B2OU/releases/tag/v6.1.0) · 下载：[B2OU.app.zip](https://github.com/desususu/B2OU/releases/download/v6.1.0/B2OU.app.zip)

---

## macOS 提示“已损坏，无法打开”

如果从 GitHub 下载后出现“B2OU.app 已损坏，无法打开”，这是 macOS 的 Gatekeeper 限制。
在没有 Apple Developer ID 的情况下，App **未签名/未公证**，其它 Mac 默认会拦截。

请在目标 Mac 上任选其一：
- 移除隔离属性（最稳妥）：
  `xattr -dr com.apple.quarantine "/Applications/B2OU.app"`
- 系统设置 → 隐私与安全性 → 在首次打开失败后点击 `仍要打开`。
- Finder 中右键 `B2OU.app` → `打开` → 确认。

---

## 首次使用前务必备份（重要）

在第一次运行本工具之前，请先备份 Bear 数据。
B2OU 会优先使用 Bear 2.8+ 自带的官方 `bearcli` 读取笔记；如果本机没有
`bearcli`，会回退到旧的只读 SQLite 快照方案。旧方案仍会使用 SQLite
**backup API** 做快照，以减少对 Bear 运行时写入的干扰。

建议备份方式（任选其一）：
- 退出 Bear 后，手动备份数据库文件。
- 使用 Time Machine / 其他系统级备份方案。
- 通过 Bear 自带的导出功能进行全量导出备份。

默认数据库位置（可能因系统/版本不同而变化）：
- `~/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data/database.sqlite`

默认 Bear CLI 位置：
- `/Applications/Bear.app/Contents/MacOS/bearcli`

---

## 简介

B2OU 用于把 Bear 笔记导出为 **Markdown** 或 **TextBundle**（适配 Ulysses）。
支持增量导出、标签组织、YAML Front Matter，以及可选的监听模式。

---

## 工作原理

- 优先通过 Bear 官方 `bearcli` 读取活动笔记、时间戳、标签和附件。
- 在 `bearcli` 不可用或显式选择 `sqlite` 时，以只读模式打开 Bear 的 SQLite 数据库。
- SQLite 路径使用 **backup API** 生成快照副本，减少对 Bear 写入的影响。
- 解析 Bear 笔记并规范化 Markdown。
- 根据命名策略生成文件名。
- 写出 Markdown 或 TextBundle 文件。
- 将 Bear 来源 ID 和 hash 写入 `.b2ou/state.json`，不写入笔记正文。
- 增量导出：只处理修改时间更新的笔记，未变更内容直接跳过。
- 清理已不存在的旧文件，并通过清单文件避免误删用户自建文件。
- 可选 `--watch` 模式：基于内容签名检测数据库变更，带防抖与最小间隔。

---

## 使用方式

### CLI（推荐）

快速导出到指定文件夹：
```bash
swift run b2ou export --out ~/Notes
```

导出为 TextBundle：
```bash
swift run b2ou export --out ~/Notes --format tb
```

按标签建立子文件夹：
```bash
swift run b2ou export --out ~/Notes --tag-folders
```

监听 Bear 数据库变更并自动导出：
```bash
swift run b2ou export --out ~/Notes --watch
```

强制使用 Bear 官方 CLI：
```bash
swift run b2ou export --out ~/Notes --source bearcli
```

强制使用旧 SQLite 兼容路径：
```bash
swift run b2ou export --out ~/Notes --source sqlite
```

查看当前导出状态（不会修改任何内容）：
```bash
swift run b2ou status --out ~/Notes
```

为现有导出预览安全的 sidecar 状态重建：
```bash
swift run b2ou rebuild-state --out ~/Notes
```

确认预览结果后写入 `.b2ou/state.json`：
```bash
swift run b2ou rebuild-state --out ~/Notes --write
```

清理导出目录并重置状态：
```bash
swift run b2ou clean --out ~/Notes
```

---

## 构建 macOS App

项目内置菜单栏 App，便于快速使用。在 macOS 上执行：
```bash
swift run B2OUBundler
```

输出：
- `dist/B2OU.app`
- `dist/b2ou`

清理构建产物：
```bash
swift run B2OUBundler clean
```

只构建 CLI：
```bash
swift run B2OUBundler cli
```

---

## 可选：`b2ou.toml` 配置

你可以在 `b2ou.toml` 中定义多个 profile 以导出到不同目标。

配置文件搜索路径：
- `./b2ou.toml`
- `~/.config/b2ou/b2ou.toml`
- `~/b2ou.toml`

示例：
```toml
[profile.obsidian]
out = "~/Vaults/Bear"
format = "md"
tag-folders = true
yaml-front-matter = true
naming = "date-title"

[profile.ulysses]
out = "~/Ulysses/Inbox"
format = "tb"
```

使用：
```bash
swift run b2ou export --profile obsidian
```

---

## 常见选项速览

- `--format md|tb|both`：导出格式
- `--source auto|bearcli|sqlite`：读取来源，默认 `auto`（优先 Bear CLI，回退 SQLite）
- `--bearcli PATH`：指定 `bearcli` 可执行文件路径
- `--yaml-front-matter`：添加 YAML 元数据
- `--hide-tags`：隐藏正文内的 Bear 标签
- `--exclude-tag TAG`：跳过指定标签（可重复）
- `--naming title|slug|date-title|id`：文件命名策略
- `--on-delete trash|remove|keep`：导出目录内旧文件处理策略

关于 Obsidian CLI、Obsidian Sync 和安全双向同步的设计备注：
- `docs/obsidian-cli-sync-notes.md`
