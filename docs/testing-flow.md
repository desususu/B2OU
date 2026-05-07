# B2OU 测试流程

本文定义项目的测试分层和执行顺序。目标是让每个 GUI 功能都能追溯到后端能力，并且每个后端能力都有可重复的自动化验证。

## 标准入口

当前环境入口：

```bash
swift build --product B2OUCoreSmokeTests
swift build --product B2OUCoreRegressionTests
swift build --product B2OUCoreContractTests
swift build --product B2OUWorkflowTests
swift build --product b2ou
swift build --product B2OUMenuBar
./scripts/run-test-suite.sh
```

当前机器只安装了 Command Line Tools，`Testing` 和 `XCTest` 模块都不可用，所以 `swift test` 不能作为真实测试入口。项目暂时沿用无测试框架依赖的 SwiftPM executable tests，并通过已构建二进制统一执行；新增 workflow 契约测试放在 `Sources/B2OUWorkflowTests`。等环境提供完整 Xcode/Swift Testing 后，再迁移到标准 `Tests/` + `swift test`。

## 分层

### L0 构建验证

每次提交至少运行：

```bash
swift build --product b2ou
swift build --product B2OUMenuBar
swift build --product B2OUCoreSmokeTests
swift build --product B2OUCoreRegressionTests
swift build --product B2OUCoreContractTests
swift build --product B2OUWorkflowTests
./scripts/run-test-suite.sh
```

覆盖目标：

- CLI 能编译。
- 菜单栏 App 能编译。
- 四个 SwiftPM 测试可执行入口存在且通过。

### L1 核心库测试

位置：`Sources/B2OUCoreSmokeTests`、`Sources/B2OUCoreRegressionTests`、`Sources/B2OUCoreContractTests`

覆盖范围：

- config/profile 解析。
- Markdown 标准化、标签提取、文件命名。
- Markdown / TextBundle 分流。
- manifest、sidecar state、fingerprint。
- dirty-file conflict guard。
- stale cleanup。
- Bear CLI JSON 解析和 fake bearcli 失败路径。

原则：

- 全部用临时目录和 fixture SQLite。
- 不读真实 Bear 数据。
- 不写用户目录。
- 不依赖 Finder、Bear、Obsidian、Ulysses。

### L2 后端集成测试

位置：仍放在测试可执行 target 中，但按领域分组；后续迁移到标准 `Tests/` 时保持相同分组。

推荐矩阵：

| 场景 | SQLite source | fake Bear CLI | 预期 |
| --- | --- | --- | --- |
| 首次导出 | 必测 | 必测 | 生成目标文件、manifest、sidecar |
| 无变化二次导出 | 必测 | 必测 | `changedCount == 0` |
| 外部编辑 | 必测 | 必测 | 返回 conflict，不覆盖文件 |
| 删除源笔记 | 必测 | 可选 | stale 文件按 `trash/remove/keep` 处理 |
| 局部导出 | 必测 | 必测 | `onlyNoteUUIDs` 合并 sidecar，不清理全量 manifest |
| both 格式 | 必测 | 可选 | Markdown 和 TextBundle 目录独立 |
| 附件失败 | 可选 | 必测 | 保留原引用，不生成坏文件 |

### L3 GUI 到后端契约测试

这层先测试“状态和动作”，不要一开始就做脆弱的全 GUI 点击测试。

建议后续把菜单栏 app 的后端依赖抽成协议：

- `ProfileStore`
- `ExportRunning`
- `SourceHealthChecking`
- `LoginItemManaging`
- `FolderOpening`

测试目标：

- `Export Now` 只在配置存在、source 可用、未导出中时启用。
- `Pause` 只改变 watcher paused，不改变配置。
- 设置面板保存只改当前 profile，保留其他 profile 和未知键。
- `Change Folder` 只改当前 profile 的导出目录，不能把其余规则重置回默认值。
- 工作台 `Export Selected` 设置 `onlyNoteUUIDs`，且无 Bear ID 时禁用。
- 工作台不直接写持久配置；所有 profile 规则修改统一从设置面板进入。
- source 不可用时状态文案、按钮禁用、错误提示一致。
- 空白错误消息不能把菜单栏状态误判为 Error；多行错误摘要只显示第一行，tooltip 保留完整细节。
- 定时备份失败必须进入可见错误状态，且备份成功不能清掉未恢复的导出错误。
- 登录启动切换失败必须弹出反馈，且菜单 toggle 只能反映系统实际状态，不能假成功。
- source-first 的 Dashboard / Note Browser 里，依赖导出文件的动作只能在文件真实存在时启用；依赖 Bear ID 的动作只在 Bear ID 存在时启用。
- `missing source link` 相关筛选和修复动作只能在当前工作台数据里真的存在缺失关联时出现。

### L4 人工发布验收

发布前用真实 macOS 用户环境做一次短流程：

1. 备份真实 Bear 数据。
2. 新建临时导出目录。
3. 启动菜单栏 App，选择 profile。
4. 手动导出一次，确认 Markdown/TextBundle 文件、图片、manifest、sidecar。
5. 在导出文件里做一次外部编辑，确认下一次导出会阻止覆盖。
6. 删除或归档一篇 Bear note，确认 stale cleanup 行为。
7. 切换语言、暂停/继续、退出重启，确认状态恢复。

## PR 验收清单

- 新增 GUI 控件时，更新 `docs/gui-backend-contract.md`。
- 新增后端能力时，至少有一个 SwiftPM 测试可执行入口覆盖成功路径和失败路径。
- 涉及文件覆盖、删除、清理、回写时，必须有冲突/边界测试。
- 不能只更新临时脚本；新测试必须进入 `B2OUCoreSmokeTests`、`B2OUCoreRegressionTests` 或 `B2OUCoreContractTests`。
- `swift build --product b2ou`、`swift build --product B2OUMenuBar` 和三个测试可执行入口必须通过。

## 当前已知整理项

- 因当前 CLT 缺少 `Testing` / `XCTest`，测试入口暂时保持为 SwiftPM executable tests。
- Dashboard / Note Browser 已接回主菜单，后续重点是保持 dashboard -> note browser 链路测试稳定。
- 工作台现在只负责审查和导出，持久 profile 编辑统一走设置面板。
- `rebuild-state` 和 `clean` 是 CLI only 能力；如果进入 GUI，必须先设计确认流和 dry-run 测试。
