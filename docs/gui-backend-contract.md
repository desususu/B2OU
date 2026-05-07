# GUI 到后端功能契约

本文把菜单栏 App 的可见入口和 B2OUCore / CLI 后端能力逐项对齐。之后新增或改动 GUI 功能时，先更新本表，再补对应测试；如果没有后端实现，必须明确标记为“界面入口”或“待实现”，不能让用户以为已经有完整业务能力。

## 产品边界

- 当前收敛源是 Bear。
- 当前稳定能力是 Bear 到文件系统的单向导出，输出 Markdown / TextBundle。
- Obsidian / Ulysses 侧文件是派生物，但可能被用户编辑，所以导出前必须检查 dirty/conflict。
- Bear ID、Bear hash、导出文件 fingerprint 只保存在 `.b2ou/state.json`，不写入正文或 front matter。
- Bear 回写、Obsidian 到 Bear 自动同步、真正的自动更新器都不是当前已实现能力。

## 状态分类

- `已接后端`：GUI 点击会调用真实后端能力，需要自动化测试覆盖。
- `界面/系统入口`：只打开 Finder、浏览器、Bear URL、外部编辑器等，没有 B2OU 业务后端。
- `待整理`：代码存在，但入口、语义或测试不完整。
- `CLI only`：后端存在，但 GUI 没有入口。
- `未实现`：文案或设计暗示存在，但没有对应能力。

## 菜单栏面板

| 功能 | GUI 入口 | 后端/系统调用 | 状态 | 必测契约 |
| --- | --- | --- | --- | --- |
| 启动后加载 profile | AppDelegate 启动 | `loadProfiles()` -> `setProfile()` -> `ExportWatcher.start()` | 已接后端 | 有 profile 时选中稳定 profile；无 profile 时进入设置向导 |
| 立即导出 | `Export Now` | `ExportWatcher.exportNow()` -> `exportNotes()` | 已接后端 | Bear source 可用且未导出中才可点；冲突要进入错误状态 |
| 暂停/继续 | `Pause/Resume` | `watcher.paused` | 已接后端 | 暂停只停自动导出，不应破坏手动导出和备份状态 |
| 打开导出目录 | `Open Folder` | `NSWorkspace.open(exportPath)` | 界面/系统入口 | 无配置时进入设置向导；有配置时打开当前 profile 的目录 |
| 更换导出目录 | `Change Folder` | `writeProfileConfig()` -> `reloadProfiles()` | 已接后端 | 只改当前 profile 的 `out`，不能重置已有格式、命名和删除策略 |
| 配置 | `Configure` | `SettingsPanel` -> `applySettings()` -> `writeProfileConfig()` | 已接后端 | 保存后 reload；取消/关闭不写入；写盘失败时保持窗口打开 |
| 编辑配置文件 | `Edit Config` | `findConfig()` + `NSWorkspace.open()` | 界面/系统入口 | 找不到配置时进入设置向导 |
| 登录启动 | toggle | `applyLoginItemToggle()` -> `addLoginItemDetailed()` / `removeLoginItemDetailed()` | 已接后端 | 状态切换失败必须弹出反馈，且 UI 必须保留实际有效状态 |
| 语言切换 | language menu | `setLanguage()` + language change notification | 已接后端 | 菜单面板、工作台、Dashboard、Note Browser、Settings 打开的窗口都要刷新文案，且不能重置窗口内草稿状态 |
| 退出 | `Quit` | stop timer/watcher + `NSApp.terminate` | 已接后端 | watcher 停止，不留下后台线程 |

## 设置面板

| 功能 | 后端字段 | 状态 | 必测契约 |
| --- | --- | --- | --- |
| Markdown/TextBundle/both | `exportFormat`, `exportPath`, `exportPathTB` | 已接后端 | `both` 必须有不同的 Markdown / TextBundle 目录 |
| YAML front matter | `yamlFrontMatter` | 已接后端 | front matter 不泄露 Bear ID/hash |
| 标签文件夹 | `makeTagFolders` | 已接后端 | 多标签笔记按规则生成多份或过滤 |
| 隐藏标签 | `hideTags` | 已接后端 | 只移除 Bear 标签行，不破坏 Markdown 标题 |
| 命名规则 | `naming` | 已接后端 | `title/slug/date-title/id` 与 CLI 行为一致 |
| 删除策略 | `onDelete` | 已接后端 | `trash/remove/keep` 只作用于 manifest 托管文件 |
| 排除标签 | `excludeTags` | 已接后端 | 不开标签文件夹时也必须生效 |
| 备份间隔/目录 | `backupInterval`, `backupPath` | 已接后端 | 备份目录不能等于任一导出目录；备份失败必须可见，且不能清掉导出错误状态 |
| 检查更新 | GitHub releases URL | 界面/系统入口 | 这是打开发布页，不是自动更新器 |

## 导出工作台

| 功能 | 后端/数据源 | 状态 | 必测契约 |
| --- | --- | --- | --- |
| 打开工作台 | `NoteStore.scan(config:)` | 已接后端 | 优先读 Bear source；失败时是否允许 fallback 必须明确 |
| 刷新 Bear | `scanAndShowWorkspace()` | 已接后端 | 文案必须与实际数据源一致；首次导出前也应可显示 Bear notes |
| 搜索/筛选/排序 | `NoteStore` + view state | 已接后端 | all/recent/images/untagged/missing images/duplicate/missing ID 与统计一致 |
| 导出所选 | `cfg.onlyNoteUUIDs` -> `exportNotes()` | 已接后端 | 没有 Bear ID 的导出文件不能局部导出；sidecar merge 不丢其他绑定 |
| 导出全部 | `triggerExportNow()` | 已接后端 | 全量导出才允许 stale cleanup/manifest rewrite |
| 重建来源关联 | `rebuildWorkspaceState()` | 已接后端 | 只在工作台实际出现 missing source link 时出现；写入前要先预检，高风险计划必须确认 |
| 打开偏好设置 | `onConfigure()` -> `SettingsPanel` | 已接后端 | 所有持久规则统一从这里修改，工作台只负责审查和导出 |
| 附件预览 | 从 Markdown/Bear 引用解析本地文件 | 已接后端 | 解析失败只能显示 unresolved，不能假装已导出 |
| 在 Finder 中显示导出文件 | `NSWorkspace.activateFileViewerSelecting([note.filePath])` | 已接后端 | 只有导出文件真实存在时才可点，不能偷偷退化成“打开导出目录” |

## 已接回的 GUI

| 模块 | 现状 | 建议 |
| --- | --- | --- |
| DashboardWindow | 已从菜单栏面板直接进入 | 保持为主入口之一，并继续覆盖到 dashboard -> note browser 链路 |
| NotePreviewWindow | 通过 Dashboard drill-down 进入 | 继续作为工作台/仪表盘的浏览器模式统一测试 |

## Dashboard / Note Browser 动作

| 功能 | 后端/系统调用 | 状态 | 必测契约 |
| --- | --- | --- | --- |
| Dashboard 打开浏览器 | `showNotePreview(store:)` | 已接后端 | 仪表盘 drill-down 必须保留筛选上下文 |
| Dashboard 打开导出文件 | `NSWorkspace.open(note.filePath)` | 已接后端 | 只有导出文件真实存在时才可点 |
| Note Browser 打开导出文件 | `NSWorkspace.open(note.filePath)` | 已接后端 | source-first 笔记在尚未导出前必须禁用 |
| Note Browser 在 Finder 中显示 | `NSWorkspace.activateFileViewerSelecting([note.filePath])` | 已接后端 | 只有导出文件真实存在时才可点 |
| Note Browser 在 Bear 中打开 | `bear://x-callback-url/open-note?id=...` | 已接后端 | 没有 Bear ID 时必须禁用 |

## 设置面板 About 动作

| 功能 | 后端/系统调用 | 状态 | 必测契约 |
| --- | --- | --- | --- |
| 检查更新 | `NSWorkspace.open(releasesURL)` | 界面/系统入口 | 明确只是打开 releases 页面 |
| 打开项目主页 | `NSWorkspace.open(projectURL)` | 界面/系统入口 | 明确只是打开项目主页 |

## CLI only 后端能力

| 能力 | CLI 入口 | GUI 状态 | 建议 |
| --- | --- | --- | --- |
| 状态查看 | `b2ou status` | 未暴露 | 可作为菜单状态详情的数据源 |
| 清理托管导出 | `b2ou clean` | 未暴露 | 高风险，若进 GUI 必须有确认和 dry-run |
| 重建 sidecar | `b2ou rebuild-state` | 工作台已条件暴露 | 只在工作台实际出现 missing source link 时出现，并保留高风险确认流 |
| watch 模式 | `b2ou export --watch` | 菜单栏 watcher 已内置 | 两套 watch 行为要保持一致测试 |

## 新功能准入规则

1. GUI 文案先写入本契约表。
2. 明确状态分类，不允许把未实现能力写成已完成能力。
3. 后端能力先进入 `B2OUCore` 或清晰的 service/protocol，再由 GUI 调用。
4. 至少补一层测试：核心逻辑用 Swift Testing，GUI 状态/动作用契约测试。
5. 涉及删除、覆盖、回写 Bear 的功能，必须先有 dry-run 或显式确认路径。
