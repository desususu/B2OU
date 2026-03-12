# B2OU

[English README](README.md)

![B2OU hero](docs/hero.png)

Bear → Obsidian / Ulysses 导出工具（macOS）。

---

## 首次使用前务必备份（重要）

在第一次运行本工具之前，请先备份 Bear 数据库。
B2OU 以**只读**方式访问数据库，并优先使用 SQLite **backup API** 做快照，
以减少对 Bear 运行时写入的干扰，但任何直接读取生产数据的工具都应在
备份之后使用。

建议备份方式（任选其一）：
- 退出 Bear 后，手动备份数据库文件。
- 使用 Time Machine / 其他系统级备份方案。
- 通过 Bear 自带的导出功能进行全量导出备份。

默认数据库位置（可能因系统/版本不同而变化）：
- `~/Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data/database.sqlite`

---

## 简介

B2OU 用于把 Bear 笔记导出为 **Markdown** 或 **TextBundle**（适配 Ulysses）。
支持增量导出、标签组织、YAML Front Matter，以及可选的监听模式。

---

## 工作原理

- 以只读模式打开 Bear 的 SQLite 数据库。
- 使用 SQLite **backup API** 生成快照副本，减少对 Bear 写入的影响。
- 解析 Bear 笔记并规范化 Markdown。
- 根据命名策略生成文件名。
- 写出 Markdown 或 TextBundle 文件。
- 增量导出：只处理修改时间更新的笔记，未变更内容直接跳过。
- 清理已不存在的旧文件，并通过清单文件避免误删用户自建文件。
- 可选 `--watch` 模式：基于内容签名检测数据库变更，带防抖与最小间隔。

---

## 使用方式

### CLI（推荐）

快速导出到指定文件夹：
```bash
python -m b2ou export --out ~/Notes
```

导出为 TextBundle：
```bash
python -m b2ou export --out ~/Notes --format tb
```

按标签建立子文件夹：
```bash
python -m b2ou export --out ~/Notes --tag-folders
```

监听 Bear 数据库变更并自动导出：
```bash
python -m b2ou export --out ~/Notes --watch
```

查看当前导出状态（不会修改任何内容）：
```bash
python -m b2ou status --out ~/Notes
```

清理导出目录并重置状态：
```bash
python -m b2ou clean --out ~/Notes
```

---

## 构建 macOS App

项目内置菜单栏 App，便于快速使用。在 macOS 上执行：
```bash
./build_app.sh
```

输出：
- `dist/B2OU.app`

清理构建产物：
```bash
./build_app.sh clean
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
python -m b2ou export --profile obsidian
```

---

## 常见选项速览

- `--format md|tb|both`：导出格式
- `--yaml-front-matter`：添加 YAML 元数据
- `--hide-tags`：隐藏正文内的 Bear 标签
- `--exclude-tag TAG`：跳过指定标签（可重复）
- `--naming title|slug|date-title|id`：文件命名策略
- `--on-delete trash|remove|keep`：导出目录内旧文件处理策略
