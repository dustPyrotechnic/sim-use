<!-- SPDX-License-Identifier: Apache-2.0 -->

# 012 — HarmonyOS 第一期：执行记录

| 项目 | 结果 |
| --- | --- |
| 状态 | **人工验收通过**（用户 2026-11-06 确认）；Review Loop 的 P1 已关闭；单元全量、E2E、quick eval 结果见下节；尚未 push 或开 PR |
| 日期 | 2026-11-06 |
| 分支 | `feat/harmonyos-backend` |
| HEAD | `c02295edfd2f442249b869096dda3dc7bfcd308d` |
| 工作区 | dirty；实现未暂存、未提交；没有 commit、push 或 PR |
| 候选 CLI | `.build/debug/sim-use`，版本 `v0.16.0-1-gc02295e-dirty` |
| 二进制 SHA-256 | `d972bb8206de31f488f66a8cede04737e9b86261872c67118128128d60c0f587` |
| 主机 | macOS arm64；`/Applications/Xcode.app`，Swift 6.4.2，macOS SDK 27.2 |
| 历史真机 | ALN-AL00，HarmonyOS 6.1.0.135 / API 24；serial 已脱敏为占位值 `TESTHARMONY000001` |
| 依据 | [批准方案](000-plan.md)、[G1](002-g1-keyboard-probe.md)及任务 dispatch；G1 原文件保留未修改 |

> 2026-11-05 几何更正：Claude 对 `c34d6dc9` 的真机复测（非人工验收）确认上一轮过滤过宽。`SkinBgContent` 的 y=1570 是透明 wrapper 顶边，不是真正遮挡边界；fixture 中有色主面板从 y=1700 开始。下方上一轮记录与原始数字保留，不再作为当前几何结论；旧记录中的“表头”指各轮当时候选。修复决策见 [005](005-transparent-keyboard-geometry.md)，本轮红测、修复及验证结果如下。

## 交付前验证（2026-11-06）

用户确认人工验收完毕；具体覆盖场景未记录（`null`）。以下均基于本分支最终代码，agent 操作不算人工验收。

| 项目 | 结果 |
| --- | --- |
| 独立 Review Loop | 1 个 P1（`harmony devices --json` 的 `data` 为裸数组），先红后修已关闭；无 P0 |
| 单元全量 | 5 轮通过，1372 / 154 / 29 |
| 上游 | `upstream/main` 与 `origin/main` 均为 `c02295e`，无需 rebase |
| iOS E2E（iPhone 18 Pro，iOS 27.0） | 29 个 suite 中 28 个通过；`TypeTests` 失败 |
| Android E2E（`tabbit_api35` 只读 headless emulator） | 10 个 suite 中 9 个通过；`AndroidStreamVideoTests` 失败 |
| quick eval | iOS 2/2、Android 1/1 通过 |

两项失败均未归因到本分支，但根因未知：

- `TypeTests`：本分支 9 轮中 2 轮失败，症状是开头字符丢失（`"nitial text"`、`"lo World"`），之后连续 7 轮通过。随后与基线交替各 5 轮，均全部通过。iOS 打字路径未改动。基线样本量不足以排除差异。
- `AndroidStreamVideoTests`：`segment restart` 用例 1 次失败，stderr 为 `Android device emulator-5554 not found`，发生在 bridge 重装后不久。随后与基线交替各 3 轮，均全部通过。

环境备注：Gradle 不读取 shell 代理变量，bridge 需以 `-Dhttps.proxyHost` 传入；`tabbit_api35` 内已有不同签名的 bridge，本次在只读 emulator 中卸载后安装，未写回 AVD。`scripts/eval.sh` 在 macOS bash 3.2 下因空数组报错（`PASSTHROUGH[@]: unbound variable`），本次未修改，直接调用 `run.py`。

## 本轮 Review Loop 修复：Harmony devices JSON envelope（2026-11-06）

仅修复 `harmony devices --json` 将 `data` 编为裸数组的问题。`HarmonyDevicesCommand` 现在定义命令内 `ExecutionResult { devices: [Device] }`；设备行不变，文本 formatter 只改为读取 `result.devices`，不改变内容或空列表文案。

先在 `HarmonyDeviceListingTests.swift` 新增一个进程内测试、两个参数用例（有设备 / 空列表），使用实际命令结果类型与 `JSONEnvelopeWriter`，断言 `data.devices` 数组及其行结构与顶层 `Devices.ExecutionResult` 一致。测试夹具仅为构造旧结果类型接受裸数组，输出断言从不接受裸数组；因此恢复旧代码时不会以编译失败冒充红测。没有修改共享 hdc、进程环境或既有断言。

生产代码未改时，运行 `swift test --enable-code-coverage --filter devicesJSONEnvelope`，退出 1；测试 0.001 秒，含构建 14.310 秒。全部 237 个生产文件 hash 与基线一致，候选仍为 `6d5074c591d3849ef05c2e5858f9217d2adbeb7d6bed9f8af3763ddef897d378`。实际失败输出：

```text
Expected data.devices array; received {"data":[],"ok":true}
Expected data.devices array; received {"data":[{"deviceId":"TESTHARMONY000001","kind":"physical","name":"TESTHARMONY000001","platform":"harmony","runtime":"HarmonyOS","state":"device"}],"ok":true}
Test run with 1 test in 1 suite failed after 0.001 seconds with 2 issues.
```

| 本地运行 | 退出码 | 结果 | 墙钟秒 |
| --- | ---: | --- | ---: |
| 实施前红测 | 1 | 两个用例失败，2 issues | 14.310 |
| 最小修复后定向测试 | 0 | 两个用例通过 | 13.489 |
| 恢复裸数组变异 | 1 | 同样两个用例失败，2 issues | 12.270 |
| 恢复修复后 `make build` | 0 | 构建通过 | 15.943 |
| `swift test --enable-code-coverage --filter Harmony` | 0 | 97 项 / 9 suites 通过 | 29.733 |
| `SIM_USE_XCSIFT=0 make test` | 0 | Swift Testing 1372 / 154 / 29 项及全部 XCTest 通过 | 47.806 |

变异期间测试文件 hash 未变；恢复后全部生产 hash 与修复快照一致。相对本轮基线，生产文件仅 `Sources/HarmonyBackend/Verbs/HarmonyCommand.swift` 改变。移除新增测试及 Foundation import 后，原测试文件内容逐字节相同；无既有断言或超时变更。

离线 CLI smoke 使用 fake hdc、独立临时 HOME、`SIM_USE_NO_DAEMON=1`，共六次调用全部退出 0：

- 有设备和 `[Empty]` 两种列表，各检查 `harmony devices --json` 与 `devices --platform harmony --json`；均为 `{"ok":true,"data":{"devices":[...]}}`，行结构相同。顶层按 Harmony 限定平台，避免实际 adb / simctl / 物理 iOS 发现。
- 两种列表各检查 Harmony 文本输出；有设备行保持 `serial  name  device`，空列表仍为 `No HarmonyOS devices connected.\n`。
- fake hdc 日志只有 `list targets`，不调用真实设备工具；临时 HOME 已删除。原始 stdout/stderr 和调用结果均保留。

README 和 Skill 没有错误的 Harmony devices JSON 结构描述，按要求不改；Skill 资源副本也不改。CHANGELOG 仅在 Unreleased / Added 记录一致的设备列表结构，不将未发布功能写成已发布回归。

证据位于 `.build/harmony-devices-envelope-97d6a7fw/`：`red.log/.json`、`mutant-bare.log/.json`、`mutation-restoration.json`、构建和测试日志、`smoke-results.json`、`verification.json`。所有失败记录原样保留。

普通构建 SHA 为 `7beba5ad33334afa569c66bd8a6c610066f830db1640ed406f812d8d3df41390`；随后 coverage 重编译/重链接的最终候选为 **`d972bb8206de31f488f66a8cede04737e9b86261872c67118128128d60c0f587`**，Harmony、全量和 CLI smoke 均使用此候选。未操作手机、运行 E2E 或付费 eval，未 commit、push 或开 PR。本轮是 Review Loop 修复，候选仍**等待人工验收**，没有新增实机或人工通过证据；原有安全边界及未解决项不变。

## 上一轮：selector 缓存时序补测（2026-11-05）

独立复测方报告 `b782af0e…` 全量 5/5、压测 40/40，23 个变异杀掉 21 个；本轮不重跑这些外部结果。按批准范围，仅在 `HarmonyTargetSafetyTests.swift` 新增三个测试方法、12 个参数用例，并更新 006 和本记录；无永久生产代码变更。

- `rejectedSelectorsPreserveAliases`：三个动词 × 下边界外 / 负中心。使用不同的旧缓存布局，拒绝后字节不变、无输入，旧 `@N` 仍可操作原坐标。
- `missingSelectorsRefreshAliases`：三个动词的 selector miss 保持 no-match 错误及 describe-ui/selector hint，无输入；缓存替换后，后续 `@N` 使用当前布局坐标。
- `successfulSelectorsRefreshAliases`：三个动词的成功对照，确认缓存替换且后续 `@N` 使用新坐标。刷新不是仅靠时间戳不同来证明。

原有测试内容在移除本轮新增块后与基线逐字节相同，**未修改既有断言或超时**。首跑新增断言误要求连续短语 `outside the screen`，而下边界错误包含尺寸（`outside the 300x300 screen`），造成三个失败；只将本轮新增断言修正为分别检查 `outside` 和 `screen`。原始失败保留为 `green.log/.json`，不冒充产品红测。

| 本地运行 | 退出码 | 结果 | 墙钟秒 |
| --- | ---: | --- | ---: |
| 新测试初版 | 1 | 新增文字断言错误，3 issues | 11.257 |
| 新测试修正后 | 0 | 3 项 / 12 个参数用例通过 | 10.517 |
| `cachefirst` | 1 | 三个下边界用例失败，9 issues | 5.612 |
| `nomisscache` | 1 | 三个 miss 用例失败，6 issues | 5.856 |
| 恢复后 Harmony | 0 | 96 项 / 9 suites 通过 | 7.537 |
| 一轮全量 `make test` | 0 | Swift Testing 1371 / 154 / 29 项通过；XCTest 也通过 | 47.646 |

两个变异均只临时修改 `HarmonyTargetResolver.resolve`，每次恢复后全部 **237 个 `Sources/` 文件 SHA-256 与基线一致**。实际失败输出节选：

```text
Test "Rejected selectors preserve the cached layout and usable aliases" recorded an issue with 2 arguments verb → "tap", bounds → "[40,280][60,340]" at HarmonyTargetSafetyTests.swift:264:9: Expectation failed: try fixture.cacheData() == original
Test run with 3 tests in 1 suite failed after 0.054 seconds with 9 issues.
Test "A selector miss refreshes aliases for the current layout without input" recorded an issue with 1 argument verb → "tap" at HarmonyTargetSafetyTests.swift:293:9: Expectation failed: refreshed != original
Test run with 3 tests in 1 suite failed after 0.054 seconds with 6 issues.
```

定向命令为 `swift test --enable-code-coverage --filter 'rejectedSelectorsPreserveAliases|missingSelectorsRefreshAliases|successfulSelectorsRefreshAliases'`；恢复后运行 `swift test --enable-code-coverage --filter Harmony` 和 `SIM_USE_XCSIFT=0 make test`。本轮均未设置 `SIM_USE_HDC` 或 E2E 开关，保持默认并行；没有操作手机、E2E、付费 eval、commit、push 或 PR。

证据：`.build/harmony-selector-cache-shwqm685/`，包含各轮原始 `.log/.json`、`baseline.json`、两份 `*-restoration.json` 和 `verification.json`。本轮未再执行 40 轮压测或独立复测方的全部 23 个变异；本次批准要求的两个变异均被捕获。

基线 SHA 为 `b782af0edd4048da88a9fbf94867d26d492b14e61750fcb40b8d39baabe2c9be`；变异恢复后的 coverage 重编译/重链接使候选变为 **`6d5074c591d3849ef05c2e5858f9217d2adbeb7d6bed9f8af3763ddef897d378`**。Harmony 与全量运行使用相同恢复后候选，生产文件 hash 没有变化。没有新真机或人工验收证据，状态仍为 **等待人工验收**；原有安全边界和未解决项不变。

## 上一轮：负中心、零尺寸与缓存 HOME（2026-11-05）

批准范围和实施前决策见 [006](006-live-target-safety.md#approved-review-negative-centers-zero-size-aliases-and-cache-home)。派单报告的独立五轮全量通过是外部证据；本轮不重跑旧候选来确认它。

### 实施前红测

运行：

```sh
swift test --enable-code-coverage --filter 'negativeElementCenters|zeroSizeAliases|zeroSizeFixtureAlias'
```

红测进程同时设置独立临时 `HOME` / `CFFIXED_USER_HOME`。先用 Foundation 探针确认实际 home，再启动测试，避免旧夹具写真实用户目录。退出 1；墙钟 12.435 秒，测试执行 0.157 秒。Source hash 前后不变，候选仍为 `62439335449851622c1b4359b318f69a5242f7550c84b76f3960e913249975dd`，尚未改生产代码。

| 红测 | 失败参数用例 | issue |
| --- | ---: | ---: |
| `negativeElementCenters`：三个动词，负 y / 负 x，alias 和部分可见 selector | 9 | 81 |
| `zeroSizeAliases`：三个动词，四种零尺寸，@N / #N@S | 12 | 72 |
| `zeroSizeFixtureAlias`：真实 fixture 节点 2306，三个动词 | 3 | 9 |

负中心错误没有发输入，但错误/hint 不对，selector 还改写缓存；新缓存断言使用固定 capture time，避免同秒写入碰巧字节一致。零尺寸的无输入断言实际失败。

```text
Test "Negative element centers report screen recovery without input or cache changes" recorded an issue with 2 arguments verb → "tap", sample → ("[200,-100][300,20]", false) at HarmonyTargetSafetyTests.swift:242:13: Expectation failed: result.hint?.contains("scroll") == true
Test "Zero-area diagnostic aliases and scoped cells cannot send input" recorded an issue with 2 arguments verb → "tap", bounds → "[0,0][0,0]" at HarmonyTargetSafetyTests.swift:269:13: Expectation failed: try fixture.inputs().isEmpty
Test "The real zero-size fixture node stays diagnostic and cannot receive input" with 3 test cases failed after 0.157 seconds with 9 issues.
Test run with 3 tests in 1 suite failed after 0.157 seconds with 162 issues.
```

原始证据：`.build/harmony-target-review-j8qbaqoc/red.log`、`red.json`、`red-home-probe.log`。没有修改任何旧测试断言或超时；新 helper 的 `capturedAt` 参数默认仍为当前时间。

缓存隔离另补一项红测：先把夹具 home 改为每例临时目录，再调用真实 `describeUI` 并从该目录读取快照、使用 alias。生产代码尚未注入 home，测试因找不到 `last-outline.json` 失败：

```text
Test "An isolated describe-ui snapshot is consumed by alias input without changing the cache" recorded an issue at HarmonyTargetSafetyTests.swift:135:6: Caught error: Error Domain=NSCocoaErrorDomain Code=260 "The file “last-outline.json” couldn’t be opened because there is no such file."
Test run with 1 test in 1 suite failed after 0.014 seconds with 1 issue.
```

上面第一行省略后续 `UserInfo` 路径；完整输出在 `red-cache-home.log`。此轮墙钟 12.273 秒、退出 1，生产代码和原候选 SHA 仍不变。合计 **4 项红测、25 个参数用例、163 issues**。

### 修复与首次转绿

- 元素来源的负中心使用屏外错误和 scroll/describe-ui hint；原 `integerPoint` 以及显式坐标、`scroll --center` 路径未改。
- 缓存尺寸 `w <= 0` 或 `h <= 0` 时直接拒绝；不改 unfiltered outline。
- selector 安全校验通过后才提交 outline cache；保留 selector 匹配错误原有的缓存刷新行为。
- `HarmonyDeviceController` 持有一个 cache home；默认仍为用户 home，读 alias 和写 outline 共用。夹具注入每例临时目录，`describeUI → alias` 真实公共接口回归确认生产者/消费者一致。
- 没有新增通用陈旧别名或可见性校验。README、Skill/资源副本、共享 help 和 006 说明三个仍可能发输入的情形；CHANGELOG 只更新用户行为，不加入内部实现细节。

`HarmonyTargetSafety|HarmonyKeyboardOcclusion|HarmonyGesture` 首次修后 **26 项 / 3 suites 通过**，测试 0.823 秒、含构建 14.614 秒。见 `green.log/.json`。此轮已不设置临时进程 HOME，隔离由每个 controller/fixture 自己提供。所有旧测试断言及超时均未改动。

### 变异、恢复与构建

每个变异单独应用、运行对应公共入口红测、恢复，再处理下一个；失败均为行为断言，不是编译失败。

| 变异 | 退出码 | issues | 墙钟秒 |
| --- | ---: | ---: | ---: |
| 删除元素负中心归一守卫 | 1 | 75 | 13.997 |
| 删除完整零尺寸拒绝守卫 | 1 | 81 | 5.715 |
| 仅删除 width 条件 | 1 | 18 | 5.826 |
| 仅删除 height 条件 | 1 | 18 | 5.928 |

恢复后 12 个受监控 Source 文件的 SHA-256 与变异前冻结值逐项一致；相关 **26 项 / 3 suites 再次通过**，测试 0.759 秒、墙钟 7.702 秒。证据为 `mutant-*.log/.json`、`mutation-restoration.json` 和 `restored.log/.json`。没有改旧断言或超时，也没有增加 `.serialized` 或关闭并行。

`make build` 退出 0，墙钟 11.990 秒。普通构建的 SHA 为 `3c5996c166c658e7dab1a8e5a85da64af6f04dc06a1495afeb4a3d90002ea316`；随后 coverage 全量构建重新链接，最终候选为表头的 `b782af0e…`。这不是生产源码再次改动；三次全量、全部压测及 smoke 的最终二进制和 Source hash 一致。

### 全量三轮与默认并行压测

全量命令为 `SIM_USE_XCSIFT=0 make test`，E2E 开关未设置。每轮退出 0；Swift Testing 三组均为 **1368 / 154 / 29 项通过**（对应 231 / 29 / 3 suites）。第二、三轮不设置 `SIM_USE_HDC`，覆盖 PATH 上安装 hdc 的开发环境；未执行设备操作或 E2E。

| 轮次 | `SIM_USE_HDC` | 退出码 | 墙钟秒 |
| --- | --- | ---: | ---: |
| full01 | 指向不存在的 hdc 路径 | 0 | 64.229 |
| full02 | 未设置 | 0 | 41.527 |
| full03 | 未设置 | 0 | 42.013 |

压测命令固定为 `swift test --skip-build --filter 'TapForwarder|PlatformRouterPhysical|Harmony'`，默认并行，40 轮均不设置 `SIM_USE_HDC`，**40/40 通过，0 失败**。

| 轮次 | 退出码 | 墙钟秒 |
| --- | ---: | ---: |
| 01 | 0 | 3.372 |
| 02 | 0 | 2.642 |
| 03 | 0 | 2.581 |
| 04 | 0 | 2.607 |
| 05 | 0 | 2.956 |
| 06 | 0 | 2.604 |
| 07 | 0 | 2.936 |
| 08 | 0 | 2.600 |
| 09 | 0 | 2.582 |
| 10 | 0 | 2.652 |
| 11 | 0 | 2.610 |
| 12 | 0 | 2.595 |
| 13 | 0 | 2.583 |
| 14 | 0 | 2.557 |
| 15 | 0 | 3.301 |
| 16 | 0 | 2.721 |
| 17 | 0 | 3.346 |
| 18 | 0 | 2.606 |
| 19 | 0 | 2.637 |
| 20 | 0 | 3.378 |
| 21 | 0 | 2.740 |
| 22 | 0 | 2.696 |
| 23 | 0 | 2.641 |
| 24 | 0 | 2.681 |
| 25 | 0 | 3.419 |
| 26 | 0 | 3.349 |
| 27 | 0 | 2.617 |
| 28 | 0 | 2.605 |
| 29 | 0 | 2.599 |
| 30 | 0 | 3.290 |
| 31 | 0 | 2.576 |
| 32 | 0 | 3.381 |
| 33 | 0 | 2.713 |
| 34 | 0 | 2.729 |
| 35 | 0 | 3.329 |
| 36 | 0 | 2.747 |
| 37 | 0 | 2.634 |
| 38 | 0 | 3.210 |
| 39 | 0 | 2.635 |
| 40 | 0 | 2.633 |

逐轮原始输出为当前证据目录中的 `full01`–`full03`、`pressure01`–`pressure40` 的 `.log/.json`，不是只保留末轮。

### 离线 CLI smoke 与保留的脚本失败

使用候选二进制、独立临时 HOME、fake hdc 和 `SIM_USE_NO_DAEMON=1`；不调用真实设备工具。

- **42 次安全拒绝**：15 次负中心 alias/selector、24 次零尺寸 `@N` / `#N@S`、3 次真实 fixture 节点 2306，覆盖 tap / long-press / type。错误和恢复 hint 符合要求，全部没有 `uiInput`，缓存字节不变。
- 第一段完成 6 次 help 和 53 次业务 JSON 检查；其中三种动词的显式正坐标照常发输入，不请求布局。
- 随后的显式负坐标在参数解析阶段被拒绝，stdout 为空。脚本错误地尝试 `json.loads(stdout)`，产生 `JSONDecodeError`。**这是本轮实际脚本失败，不记为全绿，也没有修改生产代码来迎合脚本。** 原始 `explicit-negative.stdout/.stderr`、`smoke-results.json` 和脚本保留。该次 CLI 退出码未保存，记录为未知，而非猜测值。stderr 为：

```text
Error: Coordinates must be non-negative values.
Usage: sim-use tap [<options>] [<alias>]
  See 'sim-use tap --help' for more information.
```

- 后续独立控制脚本完成剩余 9 次检查，没有重跑前段已通过的 59 次：`scroll --center` 的旧错误行为、正常 selector、selector miss 的旧缓存刷新策略，以及键盘消失、页面变化、`visible=false` 诊断别名三个明确不修的情形。上述三个陈旧/隐藏别名仍按旧坐标发输入，缓存不变。
- 控制脚本还检查保存的参数解析 stdout/stderr 和原始输入日志，确认显式负坐标没有发输入。累计 **62 份业务 JSON stdout 可解析，另有 6 份 help 输出**；参数解析错误不属于业务 JSON envelope。两个 smoke 临时 HOME 都已删除。

### 最终指纹、记录与验收边界

- `cmp skills/sim-use/SKILL.md Sources/SimUse/Resources/skills/sim-use/SKILL.md` 通过。
- 新候选 SHA-256：`b782af0edd4048da88a9fbf94867d26d492b14e61750fcb40b8d39baabe2c9be`，版本 `v0.16.0-1-gc02295e-dirty`。
- 汇总为 `.build/harmony-target-review-j8qbaqoc/final-verification.json`；本轮所有失败日志保留。红测旧 controller 写错位置的快照另存为 `red-misplaced-outline.json`，随后删除本轮独立的红测进程 HOME；不是用户真实 HOME。一次性脚本退役为不可执行的 `.py.txt` 证据。
- **既有断言/超时变更清单：无。** 新增四个测试方法；现有 fixture 仅改临时缓存目录、共享 controller home 和支持新断言的默认保持不变的时间参数。
- 本轮 dump **只防键盘遮挡和屏幕边界错误，不证明目标仍在原位**。通用陈旧别名校验仍需用户另行决定；页面变化后必须重新 `ui`。dump 与输入之间的竞态仍存在。
- 未改 3 秒 membership deadline、`type --target` 追加行为、显式坐标和 `scroll --center`；没有操作手机、E2E、付费 eval、commit、push 或 PR。
- 新候选**无真机或人工验收证据**；cold 脚本“机制未知”和历史夹具时序失败未完全归因的结论保留。状态继续为 **等待人工验收**，不进入 Review Loop。

## 上一轮：实时目标安全与 3 秒探测（2026-11-05）

批准范围及决策见 [006](006-live-target-safety.md)。尚未修改生产代码时，运行：

```sh
swift test --enable-code-coverage --filter 'HarmonyTargetSafety|membershipDeadline|paintedIslands'
```

退出 1，墙钟 20.589 秒；10 项中 6 项失败、24 个失败用例、136 条 issue。二进制仍是 `a602cd6f4d8d44c540fde6506eeae586b2b7080ec2224ccffd7d493bd64ce3d2`，生产 Source hash 未变化。新建 8 项 CLI 测试，通过各自独立的 fake hdc、HOME、缓存及日志运行，没有全局环境或 probe 变更。

| 红测 | 失败用例 | issue |
| --- | ---: | ---: |
| `coveredAliases`：tap/long-press/type × 旧快照/不滤快照；每例检查 @N、#N@M | 6 | 36 |
| `failedDump`：布局失败仍发输入 | 3 | 9 |
| `screenEdges`：实际截断/四舍五入点越界仍发输入 | 12 | 84 |
| `changedScreen`：旧缓存屏幕大于当前屏幕 | 1 | 3 |
| `ambiguousKeyboardTarget`：App 与键盘角色/标签/frame 相同 | 1 | 3 |
| `membershipDeadline`：预期 3 秒，实际 1.5 秒 | 1 | 1 |

真实失败输出节录（只省略终端图标与重复上下文）：

```text
Test "Stale and unfiltered aliases cannot input into the current keyboard" recorded an issue with 2 arguments verb → "tap", unfiltered → false at HarmonyTargetSafetyTests.swift:127:13: Expectation failed: try fixture.inputs().isEmpty
Test "A failed live alias dump sends no input" recorded an issue with 1 argument verb → "tap" at HarmonyTargetSafetyTests.swift:175:9: Expectation failed: try fixture.inputs().isEmpty
Test "Element-derived input checks the actual truncated or rounded point against the live screen" recorded an issue with 2 arguments verb → "tap", sample → ("[40,280][60,320]", 50, 300, false) at HarmonyTargetSafetyTests.swift:195:13: Expectation failed: result.ok == allowed
  result.ok → true
  allowed → false
Test "Membership passes a 3-second discovery budget independent of business timeouts" recorded an issue at HarmonyBackendTests.swift:692:9: Expectation failed: budgets == [3]
  budgets → [1.5]
Test run with 10 tests in 3 suites failed after 5.302 seconds with 136 issues.
```

完整证据：`.build/harmony-live-target-z6icqrzq/red.log`、`red.json`。键盘别名、未遮挡/无键盘别名、显式坐标均通过。`paintedIslands` 新增六位黑色样本通过；该项是现有正确实现的变异覆盖缺口，不是待改生产逻辑。

相对 `a602` 基线，既有断言变化仅一条：`HarmonyTransportTests.membershipDeadline` 的 `[1.5]` 改为 `[3]`，对应本次明确批准的 deadline；独立 runner 的显式 1.5 秒测试保持不变。`paintedIslands` 只新增 `"six-digit"` 参数，保留原断言及所有原参数。
`HarmonyRoutingTests.ProbeFailure.timedOut` 的模拟错误文本从 `1.5` 更新为 `3.0`，与真实 `TimeInterval` 输出一致；其 Android 回退、警告次数和错误传播断言未变。没有放宽或删除既有断言。

### 修复与变异验证

- `HarmonyTargetResolver.resolve` 对缓存别名读取当前 dump，直接复用缓存 entry，不调用会重写缓存的 `describeUI`。tap、long-press、type 的真实 CLI 回归均覆盖成功及拒绝路径。
- `HarmonyOutlineRenderer` 共用当前屏幕、透明面板和键盘归属规则；被覆盖时要求角色、标签、完整 frame 匹配当前键盘元素，且不存在匹配的 App 元素。共享缓存没有节点 ID，未新增缓存协议。
- 别名按截断后的点、selector 按四舍五入后的点检查当前屏幕；默认 outline 的部分可见规则不变。显式坐标仍走原分支；type 的原生追加路径不变。
- 只把 membership discovery 上限改成 3 秒；业务 timeout、失败回退 Android、一次警告、无失败缓存保持原逻辑。
- README、Unreleased Added、两个命令入口的 tap/long-press/type help、Skill 与打包副本同步。兼容门槛仍为同一未发布 Harmony 功能的 `0.17.0`。

首次修后 focused 10 项全过（21.897 秒）。下表前九项在最初 CLI 测试边界、以及后续最终公开动词/fake transport 边界各独立验证一次；最后一项在最终 smoke 后单独补查。十种变异均实际编译并触发断言，不是编译失败；各轮证据均保留：

| 临时变异 | 被捕获的行为 | 最初 CLI issue | 最初墙钟秒 | 最终 transport issue | 最终墙钟秒 |
| --- | --- | ---: | ---: | ---: | ---: |
| 删除实时 alias dump/校验调用 | 旧别名、dump 失败、当前屏幕变化仍发输入 | 48 | 10.021 | 48 | 7.516 |
| 删除键盘拒绝 guard | 被遮挡目标及歧义目标被放行 | 39 | 8.699 | 39 | 8.249 |
| 删除别名屏幕边界调用 | 截断点越界或当前屏幕缩小仍被放行 | 39 | 9.314 | 39 | 6.866 |
| 删除 selector 屏幕边界调用 | 四舍五入点越界仍被放行 | 48 | 9.664 | 48 | 7.208 |
| dump 失败返回旧坐标 | 三个动词都继续发输入 | 9 | 7.829 | 9 | 38.790 |
| 删除 `!appMatch` | 同形 App/键盘候选被放行 | 3 | 8.571 | 3 | 31.654 |
| 校验时调用缓存写入版 describeUI | 缓存字节、连续别名目标变化 | 26 | 10.470 | 16 | 23.363 |
| deadline 恢复 1.5 秒 | `[3]` 预算断言失败 | 1 | 16.064 | 1 | 29.006 |
| 删除 `color.utf8.count == 9` | 六位黑色被当透明，露出 `under-popup` | 1 | 13.402 | 1 | 30.096 |
| 仅删除 `keyboardMatch` | 非当前键盘元素的缓存目标被放行 | — | — | 9 | 7.863 |

颜色变异真实输出：

```text
Test "Painted popup and image backgrounds cover only their own frames" recorded an issue with 1 argument paint → "six-digit" at HarmonyBackendTests.swift:396:9: Expectation failed: outline.entries.map(\.uniqueId) == ["near-popup", "popup-control"]
```

最初 CLI 边界恢复正式代码后，`HarmonyTargetSafety|HarmonyKeyboardOcclusion|membershipDeadline` 共 18 项通过（12.657 秒）。`mutation-restoration.json` 证明当时 Source hash 与变异前 green 一致；随后先新增 help 文本，后段的测试边界调整另记。原始日志保存在同一证据目录的 `mutant-*.log/.json`、`restored.log/.json`，未覆盖失败记录。

额外代价和限制：每次缓存别名动作多一次 dump/传输；检查与实际输入之间仍有竞态。键盘身份只能使用缓存已有的结构字段，不提供稳定节点 ID 跟踪。显式坐标有意不受布局安全检查约束。新候选仍需真机复测与人工验收；cold 脚本延迟的具体 OS 机制仍未知。

### 前段全量失败与本轮测试边界修正

首次 `make build` 通过（15.869 秒）。前七轮全量结果逐轮保留，不用后续通过替代失败证据：

| 轮次 | SIM_USE_HDC | make 退出码 | 墙钟秒 | 结果 |
| --- | --- | ---: | ---: | --- |
| full-01 | 指向不存在的 hdc | 2 | 71.365 | 既有 daemon fixture 两条断言失败 |
| full-02 | 未设置 | 0 | 46.821 | 三个 test target 通过 |
| full-03 | 未设置 | 0 | 45.725 | 三个 test target 通过 |
| full-04 | 指向不存在的 hdc | 2 | 55.302 | 异步 CLI 夹具后，既有 release-script fixture 超过 30 秒 |
| full-05 | 未设置 | 0 | 49.510 | 三个 test target 通过 |
| full-06 | 未设置 | 0 | 47.073 | 三个 test target 通过 |
| full-07 | 未设置 | 2 | 56.855 | 既有 physical-iOS root retry 两项失败 |

真实失败输出节录：

```text
Test "Matching version leaves daemon running, no restart" recorded an issue at DaemonClientTests.swift:126:9: Expectation failed: paths.readPidfile() == pidBefore
  paths.readPidfile() → nil
Test "Matching version leaves daemon running, no restart" recorded an issue at DaemonClientTests.swift:127:9: Expectation failed: FileManager.default.fileExists(atPath: paths.socketURL.path)
Test run with 1364 tests in 231 suites failed after 39.502 seconds with 2 issues.

Test "the release driver forwards the notarized mode" with 2 test cases failed after 31.579 seconds with 1 issue.
Test run with 1364 tests in 231 suites failed after 40.164 seconds with 1 issue.

Test "persistent null roots exhaust the five-read limit" recorded an issue at IOSDeviceBackendTests.swift:144:9: Expectation failed: await transport.reads == expectedReads
Test "a root that arrives on the fifth read is accepted" recorded an issue at IOSDeviceBackendTests.swift:85:6: Caught error: the foreground app exposed no root accessibility element — ensure the device is unlocked and the app is development-signed (get-task-allow=true)
Test run with 1364 tests in 231 suites failed after 41.216 seconds with 2 issues.
```

各轮 `full-*.log/.json` 有完整输出、命令及 source/SHA。full-04 的完整 timeout 和 fixture 命令在 `full-04.log:4085-4124`。这三轮 Harmony 新用例均通过，但其他墙钟敏感用例失败。full-04 与离线 smoke 并行；full-07 没有并行 smoke，因此不能把该额外负载当作已证明的唯一原因。

本轮最初 CLI 夹具使用同步 `waitUntilExit()`，之后改为 terminationHandler/continuation；与 daemon suite 同跑 12 项通过（`green-async`，20.460 秒），但后续仍出现上述失败，因此没有把异步等待声称为根因修复。

最终不再在每轮单元测试中批量启动 CLI/Python 进程：八项永久回归调用真实公开 `performTap` / `performLongPress` / `performType`，只在既有 `HarmonyTransport` 处注入带锁的内存适配器。controller 的可选 `uiTransport` 默认仍为 Hdc；三个动词的可选 controller 默认仍为 `.shared`。无全局 override，cache serial 每例唯一且结束清理，没有 `.serialized` 或 `--no-parallel`。

所有输入日志、缓存字节、坐标、错误和提示断言保留。**另一个断言迁移**：本轮新 CLI helper 的 `(terminationStatus == 0) == response.ok` 不再适用于进程内公开方法，交由离线 CLI smoke 检查，未删除行为覆盖；相对 `a602` 基线改动的断言仍只有 membership `[1.5] → [3]`。旧 daemon/release/iOS 测试和生产代码、所有原有时间上限均未改动。

最终边界首次 18 项通过，测试执行 0.622 秒（含构建墙钟 16.959 秒）；九个变异在此边界重新命中。缓存写入变异的 issue 数从 26 变为 16：公开方法直接抛出过期别名错误，终止部分参数用例，但缓存字节断言实际失败，所有原断言仍在。全部恢复后 18 项再次通过（`restored-final`，墙钟 11.904 秒），Source hash 与 `green-transport` 完全一致，见 `mutation-restoration-final.json`。最终 `make build` 通过（27.018 秒）。

以上修正去掉本轮引入的大量子进程负载；**没有证明每一次旧 fixture 失败的具体根因**。原 cold 脚本 OS 机制仍未知。

### 前一候选的实际 CLI 离线 smoke

`69d4b86f…` 的 16 次调用全部符合预期：顶层及 Harmony 的 tap/long-press/type 六个 help；10 份可解析 JSON，包括挂死探测、真实 fixture 的不滤 describe-ui、两个命名空间各三个动词的遮挡拒绝、键盘别名和显式坐标对照。六次遮挡拒绝各只有一次 dump、没有 uiInput，缓存字节不变；键盘别名仍点 `(95,1783)`；显式 `(654,1984)` 不做 dump、按原坐标发送。

挂死 fake hdc 总耗时 **3.406 秒**（与 full-04 并行），只启动一次 membership probe、只警告一次，然后实际调用 fake adb。fake adb 故意报设备不存在，因此最终退出 1，但 stdout 为合法 JSON，说明没有在 hdc 探测失败处中止路由。真实 stderr：

```text
Warning: hdc membership probe failed: hdc timed out after 3.0 seconds. Continuing with Android routing; for Harmony use `sim-use harmony keyboard-state`.
```

此 smoke 全程 `SIM_USE_NO_DAEMON=1`，只用 fake hdc/adb，没有调用真机工具；独立 HOME 已清理。证据：`cli-smoke.json`、各 `*.stdout/*.stderr`、`hang-probes.log`、`hang-adb.log` 和 `target-smoke-events.jsonl`。普通 build 与 coverage build 的重新链接会改变二进制 SHA；前七轮及此 smoke 的 SHA 均为 `69d4b86f0acb0408fad3694c2ab2f44264f3a979b1e0f2db32ce3c7ebbfd8934`。

### 最终候选验证

最终 `make build`、恢复后的九个变异验证完成后，再连续执行三次全量 `make test`：

| 轮次 | SIM_USE_HDC | 退出码 | 墙钟秒 | 结果 |
| --- | --- | ---: | ---: | --- |
| full-08 | 指向不存在的 hdc | 0 | 107.548 | 全部通过 |
| full-09 | 未设置 | 0 | 76.130 | 全部通过 |
| full-10 | 未设置 | 0 | 41.823 | 全部通过 |

每轮 XCTest 三个 target 分别 48、52、231 项通过；Swift Testing 汇总分别为 1364 / 154 / 29 项通过。E2E 开关均未设置。未设置 `SIM_USE_HDC` 的轮次保留本机已安装 hdc 的开发环境；仅允许测试的只读 `list targets`，没有设备操作。

随后执行 40 轮下列命令；全部默认并行、全部未设置 `SIM_USE_HDC`，没有新增 `.serialized` 或 `--no-parallel`：

```sh
swift test --skip-build --filter 'TapForwarder|PlatformRouterPhysical|Harmony'
```

| 轮次 | 退出码 | 墙钟秒 |
| --- | ---: | ---: |
| pressure-01 | 0 | 4.379 |
| pressure-02 | 0 | 3.266 |
| pressure-03 | 0 | 2.723 |
| pressure-04 | 0 | 2.629 |
| pressure-05 | 0 | 2.900 |
| pressure-06 | 0 | 2.728 |
| pressure-07 | 0 | 2.745 |
| pressure-08 | 0 | 2.861 |
| pressure-09 | 0 | 3.029 |
| pressure-10 | 0 | 3.209 |
| pressure-11 | 0 | 2.737 |
| pressure-12 | 0 | 3.368 |
| pressure-13 | 0 | 2.708 |
| pressure-14 | 0 | 2.782 |
| pressure-15 | 0 | 2.671 |
| pressure-16 | 0 | 3.145 |
| pressure-17 | 0 | 2.643 |
| pressure-18 | 0 | 2.636 |
| pressure-19 | 0 | 2.689 |
| pressure-20 | 0 | 2.682 |
| pressure-21 | 0 | 3.135 |
| pressure-22 | 0 | 3.245 |
| pressure-23 | 0 | 2.672 |
| pressure-24 | 0 | 3.285 |
| pressure-25 | 0 | 3.216 |
| pressure-26 | 0 | 2.767 |
| pressure-27 | 0 | 2.739 |
| pressure-28 | 0 | 3.259 |
| pressure-29 | 0 | 3.371 |
| pressure-30 | 0 | 3.401 |
| pressure-31 | 0 | 3.306 |
| pressure-32 | 0 | 2.748 |
| pressure-33 | 0 | 2.959 |
| pressure-34 | 0 | 2.853 |
| pressure-35 | 0 | 3.510 |
| pressure-36 | 0 | 2.679 |
| pressure-37 | 0 | 2.669 |
| pressure-38 | 0 | 3.258 |
| pressure-39 | 0 | 3.178 |
| pressure-40 | 0 | 2.623 |

首尾轮的 Swift Testing 汇总均为 103 项 / 10 suites、7 项 / 1 suite 通过。40 轮的命令、退出码、环境和二进制/Source hash 均有独立 JSON；三次全量和 40 轮期间，Source 指纹始终与 `restored-final` 一致。

压测结束后，独立执行最终候选的离线 CLI smoke，**16 次调用全部符合预期，10 份 JSON 可解析，退出码与 `ok` 全部一致**。覆盖与前一候选相同的六个 help、六个别名遮挡拒绝、键盘别名、显式坐标、不滤快照和挂死回退。六次拒绝均没有 uiInput，缓存保持不变；隔离 HOME 已删除。fake hdc 挂死耗时 **3.060 秒**，一次 probe、一次 stderr 警告，实际回退调用 fake adb；输出仍为合法 JSON。证据为 `final-cli-smoke.json` 及 `final-*` 日志。

最终 `.build/debug/sim-use`：

```text
version: v0.16.0-1-gc02295e-dirty
SHA-256: 62439335449851622c1b4359b318f69a5242f7550c84b76f3960e913249975dd
```

普通 `make build` 的 SHA 为 `1652ee22…`；随后 coverage build 重新链接为上述候选。最终三次全量、40 轮压测和 smoke 均使用上述同一 SHA，smoke 前后未变。`skills/sim-use/SKILL.md` 与 `Sources/SimUse/Resources/skills/sim-use/SKILL.md` 经 `cmp` 完全一致。首次比对误用了少一层目录的路径，命令退出 2；定位真实资源路径后比对通过，没有文件修改。
最终 smoke 后补查：**仅删除 `keyboardMatch` 正向身份条件**，已有 `coveredAliases` 的三个 `unfiltered=true` 用例即失败（9 issues），其中 `HarmonyTargetSafetyTests.swift:144:13` 的 `try fixture.inputs().isEmpty` 命中，未新增或修改断言。恢复后 focused 18 项全过（测试 0.594 秒，含构建 7.016 秒）；Source 指纹和二进制 SHA 与此前三次全量、40 轮及 smoke 完全相同，没有更换候选。见 `mutant-final-keyboard-identity.log`、`restored-identity.log` 和 `final-verification.json`。

任务内 `verify.py`、`smoke.py`、`target-safety-hdc.py`、`hdc-hang`、`adb-missing` 退役为同目录的非可执行 `*.txt` 证据快照；原始日志及 JSON 保留。永久回归只依赖 Swift 的公开动词和 fake transport，不再携带 CLI/Python 子进程夹具。


没有 commit、push、PR、E2E、付费 eval 或真机操作。**真机效果仍需重测，不能把 fake transport、CLI smoke 或 Claude 既往真机操作当成人工验收。** 每次缓存别名多一次 dump/传输，结构身份匹配和校验至点击之间的竞态仍是已知边界；显式坐标保持不做此安全校验；`type --target` 的追加行为未改。




## 上一轮：透明键盘背景修正（2026-11-05）

派单中的 Mate 60 Pro 结果由 Claude 操作获得，不是人工验收。本轮只修明确透明背景的覆盖区提取，保持当前中心点、缓存及不滤模式的边界；见 [005](005-transparent-keyboard-geometry.md)。**既有断言修改清单为空。** 旧 `visibleListCells` 中中心 y=1550 的 `"partial"` 仍是有效的可见子节点对照，但不能再把其 frame 与旧 y=1570 的交叠称为真实键盘遮挡证据；新真实 fixture 用例补上穿过 y=1700 的可见中心。

### 修改生产代码前的真实红测

```sh
swift test --enable-code-coverage --filter HarmonyKeyboardOcclusion
```

退出 1，墙钟 14.938 秒。新增 5 项测试，含原有 4 项共 9 项；其中 **3 项失败、9 个失败用例、13 条 issue**。真实 fixture 的 `2325/2821/2823/2832` 全部被错误过滤，第九个 cell 无法匹配；颜色、背景图、缺失颜色/图片属性四种小覆盖区用例都错误隐藏了旁边的可见目标。完全透明回退、双中心边界以及原有四项对照通过。此时生产 Source hash 未变化，候选 SHA 仍为 `c34d6dc9912170430e06af37a77ba76c2ae980bc5b25c787706da9ccf5eb005b`。

真实输出节录（仅去除终端状态图标）：

```text
Test "Real app targets in the transparent keyboard strip remain selectable and cached" recorded an issue with 3 arguments id → "2325", x → 105, y → 1606 at HarmonyBackendTests.swift:335:9: Expectation failed: outline.entries.contains { $0.uniqueId == id }
Test "Real app targets in the transparent keyboard strip remain selectable and cached" recorded an issue with 3 arguments id → "2823", x → 654, y → 1696 at HarmonyBackendTests.swift:335:9: Expectation failed: outline.entries.contains { $0.uniqueId == id }
Test "Painted popup and image backgrounds cover only their own frames" recorded an issue with 1 argument paint → "image" at HarmonyBackendTests.swift:395:9: Expectation failed: outline.entries.map(\.uniqueId) == ["near-popup", "popup-control"]
Test "The real transparent-strip cell extends the filtered list without alias gaps" recorded an issue at HarmonyBackendTests.swift:350:6: Caught error: HarmonyError(message: "No Harmony element matches the selector.", hint: Optional("Run describe-ui again for the current screen, then check the selector or use a fresh @N alias."))
Test run with 9 tests in 1 suite failed after 0.085 seconds with 13 issues.
```

原始证据：`.build/harmony-transparency-_eg69gjo/red.log`、`red.json`。原始记录不覆盖重跑。

### 最小实现与变异门禁

只在 `HarmonyLayout.swift` 的私有覆盖区提取中判断背景：有效八位 ARGB 的 alpha 为零，且 `backgroundImage` 明确为 `empty source`，才继续下探透明 wrapper。非空背景图、非零 alpha、缺失/未知属性按保守覆盖处理。每个输入法子树先收集实际有色/未知背景的 bounded frame；整个子树都没有可用结果时，复用原 bounded-panel 回退，不能对透明条逐分支回退。没有硬编码 y=1700、节点 id 或设备尺寸。

原 `isCovered` 双中心判定、可见性、全屏 wrapper 排除、List 编号算法和键盘所有权不变。既有四项键盘测试与断言均未改；新增五项覆盖真实透明条目标、第九个 cell、局部颜色/图片、缺失属性、全透明子树回退及四个奇数尺寸边界。

| 门禁 | 命令/变异 | 墙钟秒 | 结果 |
| --- | --- | ---: | --- |
| 首次转绿 | `swift test --enable-code-coverage --filter HarmonyKeyboardOcclusion` | 16.133 | 退出 0，9/9 通过 |
| 去掉 cached 中心 | 只保留 `contains(selectorX, selectorY)`；`--filter oddPixelCenters` | 16.112 | 退出 1；右/下边界两个用例失败，6 条 issue |
| 去掉 selector 中心 | 只保留 `contains(cachedX, cachedY)`；`--filter oddPixelCenters` | 9.991 | 退出 1；左/上边界两个用例失败，6 条 issue |
| 恢复完整谓词 | `swift test --enable-code-coverage --filter HarmonyKeyboardOcclusion` | 9.811 | 退出 0，9/9 通过 |

两个变异均完成编译并在断言中失败，不是用编译错误充当红测。各自都捕获 outline 错误保留、selector 可达及 cache/alias 仍指向该目标。真实输出节录：

```text
Test "Odd-sized targets cannot cross a keyboard edge through either pixel-center convention" recorded an issue with 3 arguments bounds → "[179,120][220,160]", cachedX → 199, cachedY → 140 at HarmonyBackendTests.swift:449:9: Expectation failed: outline.entries.map(\.uniqueId) == ["safe", "ime-key"]
Test "Odd-sized targets cannot cross a keyboard edge through either pixel-center convention" recorded an issue with 3 arguments bounds → "[120,79][160,120]", cachedX → 140, cachedY → 99 at HarmonyBackendTests.swift:449:9: Expectation failed: outline.entries.map(\.uniqueId) == ["safe", "ime-key"]
```

变异后已恢复完整谓词，renderer SHA 恢复为与首次绿测完全相同的 `0ad4f079acd884a0570f31ef7171b558ba3bbb908b8f7d29ccbe24519e8293f8`。证据：`mutant-cached.log`、`mutant-selector.log` 和 `mutation-restoration.json`；变异二进制不是交付候选。

### 构建与三次全量

| 轮次 | 实际命令 | SIM_USE_HDC | 墙钟秒 | 退出/结果 |
| --- | --- | --- | ---: | --- |
| build | `make build` | 未设置 | 18.404 | 0，通过 |
| full-01 | `make test` | 显式不存在的 `absent-hdc` | 81.156 | 0，通过 |
| full-02 | `make test` | 未设置，保留主机 PATH | 43.586 | 0，通过 |
| full-03 | `make test` | 未设置，保留主机 PATH | 41.041 | 0，通过 |

使用 `SIM_USE_XCSIFT=0`，不启用 E2E 环境变量。README、CHANGELOG 的 Unreleased/Added、两个入口的 help 和 Skill 已同步。`cmp` 退出 0，Skill 及 `Sources/SimUse/Resources` 副本 SHA 均为 `cf39bb934676a3262a1e0f3ea9d9e8c559136279394aa61003de2a3f9c08bd1a`。

三轮全量的 Swift Testing 均报告 1356、154、29 项通过；整体 `make test` 退出 0。仍有既有 `OrientationCalibrator.swift:43` 的 CoreGraphics import / Swift 6 警告，未修改或掩盖；`Fake hdc listing failed` 来自预期失败路径的单测输出。

### 默认并行压力循环：40/40，通过

每轮命令为 `swift test --skip-build --filter 'TapForwarder|PlatformRouterPhysical|Harmony'`，全部未设置 `SIM_USE_HDC`，未增加 `.serialized` 或使用 `--no-parallel`。逐一检查每份日志，均报告 95 项/9 suites 和 7 项/1 suite 通过。各轮源代码 hash 与恢复后的绿测一致，运行前后未变化。

| 轮次 | 墙钟秒 | 退出/结果 |
| --- | ---: | --- |
| pressure-01 | 5.204 | 0，通过 |
| pressure-02 | 2.675 | 0，通过 |
| pressure-03 | 2.816 | 0，通过 |
| pressure-04 | 2.674 | 0，通过 |
| pressure-05 | 2.650 | 0，通过 |
| pressure-06 | 2.671 | 0，通过 |
| pressure-07 | 2.704 | 0，通过 |
| pressure-08 | 2.637 | 0，通过 |
| pressure-09 | 2.751 | 0，通过 |
| pressure-10 | 2.688 | 0，通过 |
| pressure-11 | 2.637 | 0，通过 |
| pressure-12 | 2.749 | 0，通过 |
| pressure-13 | 2.726 | 0，通过 |
| pressure-14 | 2.842 | 0，通过 |
| pressure-15 | 2.638 | 0，通过 |
| pressure-16 | 2.716 | 0，通过 |
| pressure-17 | 2.771 | 0，通过 |
| pressure-18 | 2.765 | 0，通过 |
| pressure-19 | 2.695 | 0，通过 |
| pressure-20 | 2.647 | 0，通过 |
| pressure-21 | 2.732 | 0，通过 |
| pressure-22 | 2.690 | 0，通过 |
| pressure-23 | 2.679 | 0，通过 |
| pressure-24 | 2.787 | 0，通过 |
| pressure-25 | 2.682 | 0，通过 |
| pressure-26 | 2.689 | 0，通过 |
| pressure-27 | 2.777 | 0，通过 |
| pressure-28 | 2.808 | 0，通过 |
| pressure-29 | 2.715 | 0，通过 |
| pressure-30 | 2.812 | 0，通过 |
| pressure-31 | 2.791 | 0，通过 |
| pressure-32 | 2.794 | 0，通过 |
| pressure-33 | 2.723 | 0，通过 |
| pressure-34 | 2.825 | 0，通过 |
| pressure-35 | 2.759 | 0，通过 |
| pressure-36 | 2.745 | 0，通过 |
| pressure-37 | 2.701 | 0，通过 |
| pressure-38 | 2.704 | 0，通过 |
| pressure-39 | 2.815 | 0，通过 |
| pressure-40 | 2.791 | 0，通过 |

### 实际 CLI 离线 smoke

使用当前候选、fake hdc、`SIM_USE_NO_DAEMON=1`、隔离 HOME / CFFIXED_USER_HOME 和 `TESTTRANSPARENTCLI01`；adb 指向 `/usr/bin/false`，即使路由意外回退也不会接触 Android。12 条合法 CLI 检查通过：10 份 JSON stdout 可解析、2 个 help 入口通过。

| 检查 | 实际结果 |
| --- | --- |
| 不滤 / 默认 `ui` | 320 / 58 entries；默认增加透明条内的真实 `2325/2821/2823/2832`，@1..@58 连续；不滤模式不变 |
| `tap --id 2823` | fake `uiInput click 655 1697` |
| 新快照 `tap @48`，id 2325 | fake `click 105 1606` |
| 新快照 `tap @49`，id 2821 | fake `click 654 1696` |
| `tap --label VISIBLE_STRIP_RESULT` | fake `click 270 1697`；仅为消除公开 fixture 的重复脱敏标签，将临时副本中 2832 的 text/description 改为唯一值，其他属性、顺序及几何未变 |
| `tap '#9@1'` | fake `click 654 1696`；对应 List 的 cell indices 连续为 1..9 |
| `tap --id 2837` / `2851` | 返回 no match 和 describe-ui 提示，没有 uiInput 调用 |
| `tap --id KeyMenu` | fake `click 95 1783`；键盘控件仍可用 |
| 顶层 / Harmony `ui --help` | 均包含 include-offscreen 与键盘过滤诊断说明 |

另有 **1 条 smoke 脚本错误命令**原样记录，不计入上述 12 条通过：脚本最初把 `--id 2832` 与 `--label 示例文本` 合用，被既有互斥规则以退出 64 拒绝，stdout 为空，随后脚本解析 JSON 报错。真实 stderr 为 `Error: Use only one of --id, --label, --value, --label-contains, --label-regex (got: --id, --label).` 没有修改产品规则，也没有覆盖或重跑这条错误命令；后续独立 label-only 检查通过。见 `cli-harness-error.txt`、`cli-selector-label.*`、`cli-selector-label-only.*`。

### 候选身份、边界与证据

恢复谓词后的 focused test 为 `a602cd6f…`；普通 `make build` 后 SHA 为 `b6402d7ccd11cc17ddd993746a862454c6eaf0e4f7f7e7cc450c987a18d01762`；首次 coverage `make test` 重新链接后回到表头完整 SHA。后两轮全量、40 轮压测及所有离线 CLI 均保持 `a602cd6f4d8d44c540fde6506eeae586b2b7080ec2224ccffd7d493bd64ce3d2`。最后独立 `shasum -a 256 .build/debug/sim-use` 和 `--version` 再次确认；版本仍为 `v0.16.0-1-gc02295e-dirty`。

`Hdc.swift` 和 `UITestClient.swift` 的红测前/本轮最终 Source hash 一致；未改 1.5 秒 deadline 或 type 追加行为。中心超出屏幕、键盘后来弹出时的旧 alias、诊断模式生成的 alias 均不在本轮修复范围。原始测试日志、所有 CLI stdout/stderr、fake 调用和 hash 保存于 `.build/harmony-transparency-_eg69gjo/`，总表为 `verification-summary.json`。本轮隔离 HOME 已移除，未启用 daemon；一次性 runner 和 fake transport 退役为文本证据，未改旧证据。

**新候选仍等待人工验收，没有真机复验结果。** 真实皮肤键盘、spell 弹层与设置页面仅有旧候选的派单事实和本轮 fixture/合成证据。本轮未操作手机，未跑 E2E 或付费 eval，未 commit、push 或开 PR；cold 脚本机制仍未知。

本轮建议的最小复验步骤取代旧记录中依赖 y=1570 的几何判断：
1. 在同一设置搜索页唤起键盘，保存截图和默认 `ui`；从当前快照取 ID/alias，不沿用旧编号。确认采样率等可见中心仍在 outline 中。
2. 仅对用户确认无副作用的可见结果分别验证 selector 与新 alias；检查点击结果、搜索词和键盘输入，不能把 CLI 成功直接当作验收。
3. 验证被真正有色面板盖住的音频解码器、采样位深等目标仍 no match 且不发输入；收起键盘、刷新 UI 后再检查恢复。
4. 若当前环境已有皮肤键盘或 spell 弹层，核对背景图/局部不透明区域只遮挡其 frame；没有这类场景时明确记为未覆盖，不自动修改手机设置。



## 上一轮：键盘遮挡与错误提示，红测先行（2026-11-05）

用户在 Mate 60 Pro、候选 `d4b4a9da` 上确认：设置搜索结果“蓝牙音频采样率”的中心 (429,1920) 被键盘遮挡，仍列入 outline，tap 返回成功却按到 R 键。**这是派单提供的真机结果，不是本轮 agent 操作。** 它取代旧记录的“未确认”。本轮仅修键盘过滤、selector miss hint 和 Harmony 拔线建议顺序；方案与公共测试边界见 [004](004-keyboard-occlusion-and-hints.md)。

### 实际红测

先只改测试及方案文档，再执行：

```sh
swift test --enable-code-coverage --filter 'HarmonyKeyboardOcclusion|selectorMissHint|transportFailureHint|disconnectedHintGates|daemonStaleHint'
```

退出 **1**，14.925 秒；8 项测试中 **6 项失败、18 条断言失败**。当时生产代码未改，二进制 SHA 仍为 `d4b4a9dad762c970a3e2d155abd1affc720ebc1beafe33920cd6ef01af5362e7`。原始日志及运行前 Source hash：`.build/harmony-keyboard-review-vrzc2rvs/red.log`、`red.json`。以下为真实失败行摘录（去掉终端状态图标）：

```text
Test "Real keyboard panel removes covered app targets from outline, selectors and cached aliases" recorded an issue at HarmonyBackendTests.swift:233:9: Expectation failed: !outline.entries.contains { $0.uniqueId == "2851" }
Test "Real keyboard panel removes covered app targets from outline, selectors and cached aliases" recorded an issue at HarmonyBackendTests.swift:247:13: Expectation failed: target.point.x != 654 || target.point.y != 1984
Test "Covered list centers do not hide visible children or leave cell alias gaps" recorded an issue at HarmonyBackendTests.swift:270:9: Expectation failed: outline.lists.first?.cellCount == 2
Test "Keyboard coverage uses the target center and preserves keyboard controls" recorded an issue at HarmonyBackendTests.swift:300:9: Expectation failed: outline.entries.map(\.uniqueId) == ["left-visible", "right-visible", "ime-key", "bottom-visible"]
Test "A missing Harmony selector directs recovery to the current UI, not connectivity" recorded an issue at HarmonyBackendTests.swift:152:13: Expectation failed: hint.contains("describe-ui")
Test "Harmony hint preserves the original error and hint only for top-level hdc-enabled clients" recorded an issue at HarmonyRoutingTests.swift:182:17: Expectation failed: hint.hasSuffix("Keep the original reconnect advice.")
Test "Client Harmony hint survives the daemon stale-device shutdown envelope" recorded an issue at HarmonyRoutingTests.swift:235:13: Expectation failed: hint.hasSuffix(originalHint)
Test run with 8 tests in 3 suites failed after 0.072 seconds with 18 issues.
```

实际旧行为还返回了 `id=2851` 的 Entry、List cellCount=3、cell alias 顺序 `[1,3,2]`，缓存 `#2` 指向 `"covered"`。无/隐藏/无效输入法几何的 5 个对照，以及 `/usr/bin/false` 真实非零进程经过 Hdc 后仍保留连接 hint 的对照通过。

两处既有断言的批准变更：`disconnectedHintGates` 在启用 Harmony advice 时，将原 hint 的 prefix 断言改成 suffix 保留；排除路径强化为原 hint 完全相等。`daemonStaleHint` 将原 hint prefix 改为 suffix，并要求原 hint 非 nil。错误内容保留、adb/daemon 命令保留、Harmony 条件门禁等其他断言不变。这是已批准的优先级变化，不是为转绿放宽条件。

### 最小实现与保留边界

- `HarmonyLayout.swift` 从可见输入法子树提取有效、裁剪后的 panel，跳过全屏 wrapper；保留输入法和 scene-board 的键盘控件。共享 renderer 在产生 entries 前排除中心点被盖住的非键盘元素，因此 outline、实时 selector 和新 alias cache 一致。覆盖判定兼顾既有 alias 整数中心与 selector 四舍五入中心，不改变坐标约定。
- 被遮住的容器不剪掉仍可见的子节点；List 仅为过滤后保留的 cell 计数、编号。部分覆盖但目标中心可用的元素保留。没有输入法、无效/零 bounds、只有全屏 wrapper 或输入法隐藏时，对照输出与原行为一致。
- `HarmonyTapCommand.swift` 只为 selector 无匹配提供刷新 `describe-ui` / 检查 selector 的提示；真实 hdc 失败继续使用连接提示。
- `PlatformRouter.swift` 只调整已有 advice 的拼接顺序：Harmony 建议先出现，原 hint 原文作为 suffix 保留。条件门禁、JSON envelope 与 daemon wire 不变，没有新增探测。
- 当前两个 UI 入口的不滤选项均为 **`--include-offscreen`**，不是 `--all`；保持 `filterOffscreen:false`，不新增参数。更新了两处 help、README、CHANGELOG 的 Unreleased/Added 和 Skill。`make build`/`make test` 同步资源副本后，`cmp skills/sim-use/SKILL.md Sources/SimUse/Resources/skills/sim-use/SKILL.md` 退出 0；两者 SHA 均为 `0783906f20c6954da41dd4b66a367d087c41cad694fcb701d3e52273b003421a`。
- 未改 1.5 秒 membership deadline、Hdc.run 或 `type --target` 的追加实现；`Hdc.swift` 与 `UITestClient.swift` 的红测前/最终验证 Source hash 相等。未恢复 `.serialized`，未使用 `--no-parallel`，没有放宽或删除保护性断言。

### 绿测、构建与三次全量

同一红测命令转绿：退出 0，8 项测试全部通过，包含编译的墙钟时间 52.436 秒。额外加入的 `keyboardLeftButton` / `keyboardRightButton` 保留断言也通过。证据：`green.log` / `green.json`。

所有命令使用 `SIM_USE_XCSIFT=0`；不启用 E2E 环境变量。以下为进程墙钟时间，不是测试框架内部计时：

| 轮次 | 实际命令 | SIM_USE_HDC | 秒 | 退出/结果 |
| --- | --- | --- | ---: | --- |
| build | `make build` | 未设置 | 13.928 | 0，通过 |
| full-01 | `make test` | 显式不存在的 `absent-hdc` | 65.224 | 0，通过 |
| full-02 | `make test` | 未设置，保留主机 PATH | 41.249 | 0，通过 |
| full-03 | `make test` | 未设置，保留主机 PATH | 39.991 | 0，通过 |

每次全量均报告 XCTest 的 48、52、231 项零失败，以及 Swift Testing 的 1351、154、29 项通过；未启用设备 E2E。构建和首次全量仍输出既有 `OrientationCalibrator.swift:43` 的 CoreGraphics import / Swift 6 警告，本轮未修改或掩盖该无关问题。

SHA 轨迹已逐次保存：修前 `d4b4a9da…`；修复后的 focused green 为 `78d1ea34…`；同步 help/Skill 并 `make build` 后为 `7e6c5ddfff8b1f468c4f27d467c211a775844764dbd765cb0951da9eab05ba97`；首次带 coverage 的 `make test` 重新构建/链接 sim-use 后为表头的 `c34d6dc9…`。后两轮全量、40 轮 `--skip-build` 压测和所有离线 CLI 均使用并保持该最终 SHA。最后单独执行 `shasum -a 256 .build/debug/sim-use` 和 `--version` 再次确认，版本仍为 `v0.16.0-1-gc02295e-dirty`。

### 相关套件压力循环：40/40，通过

每轮实际命令：

```sh
swift test --skip-build --filter 'TapForwarder|PlatformRouterPhysical|Harmony'
```

40 轮全部未设置 `SIM_USE_HDC`，保持测试默认并行；每轮报告 90 项/9 suites 和 7 项/1 suite 通过。运行前后 Source hash 和二进制 hash 一致。没有失败后删除、重跑覆盖或只报告最后一轮。

| 轮次 | 秒 | 退出/结果 |
| --- | ---: | --- |
| pressure-01 | 4.767 | 0，通过 |
| pressure-02 | 2.598 | 0，通过 |
| pressure-03 | 2.605 | 0，通过 |
| pressure-04 | 2.597 | 0，通过 |
| pressure-05 | 2.594 | 0，通过 |
| pressure-06 | 2.593 | 0，通过 |
| pressure-07 | 2.611 | 0，通过 |
| pressure-08 | 2.629 | 0，通过 |
| pressure-09 | 2.604 | 0，通过 |
| pressure-10 | 2.764 | 0，通过 |
| pressure-11 | 2.724 | 0，通过 |
| pressure-12 | 2.875 | 0，通过 |
| pressure-13 | 2.840 | 0，通过 |
| pressure-14 | 2.789 | 0，通过 |
| pressure-15 | 2.785 | 0，通过 |
| pressure-16 | 2.737 | 0，通过 |
| pressure-17 | 2.784 | 0，通过 |
| pressure-18 | 2.892 | 0，通过 |
| pressure-19 | 3.022 | 0，通过 |
| pressure-20 | 2.765 | 0，通过 |
| pressure-21 | 2.801 | 0，通过 |
| pressure-22 | 2.742 | 0，通过 |
| pressure-23 | 2.977 | 0，通过 |
| pressure-24 | 2.736 | 0，通过 |
| pressure-25 | 2.752 | 0，通过 |
| pressure-26 | 2.726 | 0，通过 |
| pressure-27 | 2.762 | 0，通过 |
| pressure-28 | 2.734 | 0，通过 |
| pressure-29 | 2.765 | 0，通过 |
| pressure-30 | 2.691 | 0，通过 |
| pressure-31 | 2.772 | 0，通过 |
| pressure-32 | 2.753 | 0，通过 |
| pressure-33 | 2.800 | 0，通过 |
| pressure-34 | 2.829 | 0，通过 |
| pressure-35 | 2.730 | 0，通过 |
| pressure-36 | 2.747 | 0，通过 |
| pressure-37 | 2.809 | 0，通过 |
| pressure-38 | 2.750 | 0，通过 |
| pressure-39 | 2.782 | 0，通过 |
| pressure-40 | 2.817 | 0，通过 |

### 实际 CLI / daemon 离线 smoke

使用候选可执行文件、已有真实 `third-party.json`、隔离 HOME / CFFIXED_USER_HOME、明确的 fake hdc/adb 和 `TESTKEYBOARD*` 占位 serial。没有调用真实设备命令。12 次 CLI 调用的检查通过，其中 10 次 JSON stdout 均可解析、2 次 help 检查通过：

| 场景 | 实际观测 |
| --- | --- |
| `harmony ui --include-offscreen --json --no-raw` | 320 entries（298 个不同 uniqueId）；覆盖项 `id=2851` 保留，alias 为 @215 |
| 顶层默认 `ui --json --no-raw` | 54 entries，@1..@54 连续；2851 消失；部分可见 2809 为 @46，KeyMenu 为 @48，左右系统键盘控件为 @53/@54 |
| `harmony tap --id 2851 --json` | 明确无匹配，hint 引导 describe-ui / selector；无 uiInput 调用 |
| 默认快照后的 `harmony tap @215 --json` | 明确报只存在 @1..@54，无 uiInput 调用；没有把不滤快照的覆盖项留下 |
| `harmony tap @46` / `@48` | 分别发出 fake `uiInput click 654 1552` 和 `click 95 1783`；前者中心在 panel 之外，后者是有意选择的键盘按钮 |
| fake hdc 实际非零退出 | 连接失败仍给 hdc connectivity 提示 |
| 两个 UI 入口的 `--help` | 均说明 include-offscreen 和键盘诊断含义 |
| 顶层 `[Empty]` → Android → 实际 daemon stale 返回 | hint 先说 hdc/Harmony，再说 adb devices / daemon stop；原 hint 完整保留为 suffix |
| 显式 `android` / hdc 不存在，同样经过 daemon | 不追加 Harmony；替换独立占位 serial 后，两者与原 hint 完全相等 |

这次 smoke 的两处 **Python 校验/汇总错误**也保留：最初误按 `error.hint` 读取 JSON，实际 envelope 为字符串 `error` 和顶层 `hint`，触发 `TypeError: string indices must be integers`。最终核对又发现汇总误把 uniqueId 查找字典的 298 项当成 entries 数量；断言拒绝该假设，直接读取已保存数组确认实际为 320 项，默认视图仍为 54 项。原始 CLI stdout/stderr 未改；仅修正校验访问和汇总值，没有重跑已完成的命令，更没有修改生产代码来迎合脚本。证据为 `cli-harness-first-error.txt` 和 `cli-count-correction.json`。

三个离线 daemon 都在 stale 返回后自行清除 `.sock` / `.pid` / `.platform`；保存其日志后仅删除本轮占位 serial 的 log，移除隔离 HOME。没有操作其他 daemon。汇总和清理证据为 `cli-smoke-results.json`、`cli-daemon-observations.json`、`cli-cleanup.json`；每条 CLI 的命令、退出码、stdout/stderr 和 fake 调用日志分别保存。

本轮证据统一在 `.build/harmony-keyboard-review-vrzc2rvs/`：`red*`、`green*`、`build*`、`full-01..03*`、`pressure-01..40*` 和 `cli-*`。一次性 runner / fake transport 退役为文本证据，不纳入产品。**候选仍等待人工验收，真机键盘效果和拔线提示尚须重新验证。** 未执行设备 E2E、付费 eval、commit、push 或 PR；不把这轮通过解释为 cold 脚本 OS 机制已查清。


## 上一轮：全局 probe 捕获变量竞争（2026-11-05）

范围仅限测试和文档；生产实现与候选保持不变，状态仍为**等待人工验收**。独立复测报告的修前基线为：`swift test --skip-build --filter 'TapForwarder|HarmonyRouting|HarmonyGesture|PlatformRouterPhysical|HarmonyTransport'` 运行 40 轮失败 19 轮；去掉 TapForwarder 和 PlatformRouterPhysical 后 40 轮零失败。本轮引用该已复现结果，没有再次运行修前代码。此前全量通过不能排除另一种并发时序。

根因与修正：`withHarmonyRoutingProbe` 的 parser gate 只协调安装者，不能阻止 gate 外的全局 `PlatformRouter.resolve(udid:)` 调用。`topLevelDeltaRejection` 和 `failingProbeForwarding` 曾对其他测试的 Android 形状 serial 修改捕获的 `probes`，产生跨线程访问和多计数。现在两处闭包都先检查自己的 `Self.serial`，其他 serial 直接返回 `false`，不读写捕获状态；本测试的计数、返回或抛错保持原语义。其余三个 helper 用法分别安装 nil、nil 和无状态的 serial 比较，无同类修改。helper 注释补充这一约束。

保留两处 `probes == 1`、原超时与默认并行配置；不修改 `Sources/`，不恢复 `.serialized`，不用 `--no-parallel`。003 中只读真实 hdc 的授权来源更正为 **Prowl 派单指令**，不再归称为用户本人明确表态。cold 脚本延迟的具体 OS 机制仍未知，既有结论不变；详见 [003 的竞争说明](003-routing-timeout-review.md#follow-up-global-probe-counter-race-2026-11-05)。

验证前 `.build/debug/sim-use` SHA-256 实测为 `d4b4a9dad762c970a3e2d155abd1affc720ebc1beafe33920cd6ef01af5362e7`。以下为本轮逐轮结果，没有复用旧的全量通过作为本轮验证。

### 同一 filter 的 40 轮

先以 `swift test --enable-code-coverage --filter 'TapForwarder|HarmonyRouting|HarmonyGesture|PlatformRouterPhysical|HarmonyTransport'` 增量编译修改后的测试并运行，退出 0，耗时 20.176 秒；coverage 配置与 `make test` 一致。随后严格使用派单中的 `swift test --skip-build --filter 'TapForwarder|HarmonyRouting|HarmonyGesture|PlatformRouterPhysical|HarmonyTransport'` 连续运行 40 轮。全部未设置 `SIM_USE_HDC`，未加并行限制。每轮日志均包含两处被修测试的通过记录，以及 Swift Testing 的 49 + 7 项通过记录。

| 轮次 | 退出码 | 耗时（秒） |
| --- | --- | --- |
| 01 | 0 | 3.585 |
| 02 | 0 | 3.374 |
| 03 | 0 | 3.625 |
| 04 | 0 | 3.106 |
| 05 | 0 | 2.839 |
| 06 | 0 | 2.718 |
| 07 | 0 | 2.919 |
| 08 | 0 | 2.812 |
| 09 | 0 | 2.698 |
| 10 | 0 | 2.627 |
| 11 | 0 | 2.670 |
| 12 | 0 | 2.675 |
| 13 | 0 | 2.665 |
| 14 | 0 | 2.645 |
| 15 | 0 | 2.641 |
| 16 | 0 | 2.658 |
| 17 | 0 | 3.373 |
| 18 | 0 | 2.664 |
| 19 | 0 | 2.612 |
| 20 | 0 | 2.642 |
| 21 | 0 | 2.656 |
| 22 | 0 | 2.586 |
| 23 | 0 | 2.671 |
| 24 | 0 | 2.657 |
| 25 | 0 | 2.676 |
| 26 | 0 | 2.581 |
| 27 | 0 | 2.671 |
| 28 | 0 | 2.617 |
| 29 | 0 | 2.635 |
| 30 | 0 | 2.615 |
| 31 | 0 | 2.665 |
| 32 | 0 | 2.639 |
| 33 | 0 | 2.656 |
| 34 | 0 | 2.696 |
| 35 | 0 | 2.638 |
| 36 | 0 | 2.716 |
| 37 | 0 | 2.667 |
| 38 | 0 | 2.648 |
| 39 | 0 | 2.659 |
| 40 | 0 | 2.652 |

结果：修前独立复测失败 19/40；修后本地失败 **0/40**。准备阶段及每轮前后 SHA 均未改变。原始输出、命令、时间、环境与逐轮 SHA 保存在 `.build/harmony-probe-race-rkqry023/` 的 `prepare.*`、`targeted-01.*` 至 `targeted-40.*` 和 `targeted-results.json`；`baseline.json` 明确区分派单报告与本地测量。

### 三次全量与最终身份

三轮均运行 `make test`，保留默认并行与 coverage 配置；设置 `SIM_USE_XCSIFT=0` 保存原始输出，移除 `SIM_USE_E2E` 和 `SIM_USE_E2E_ANDROID`，未运行 E2E。

| 轮次 | `SIM_USE_HDC` | 退出码 | 耗时（秒） |
| --- | --- | --- | --- |
| 1 | 指向本轮证据目录内不存在的 `absent-hdc` | 0 | 48.865 |
| 2 | 未设置 | 0 | 42.623 |
| 3 | 未设置 | 0 | 40.915 |

每轮 XCTest 的 48 / 52 / 231 项均零失败；Swift Testing 的 1345 / 154 / 29 项均通过。修后 40 轮 filter 与三次全量均无失败。日志中 `Fake hdc listing failed` 的既有失败 fixture warning 保留，未掩盖或修改其他问题。

最后运行 `shasum -a 256 .build/debug/sim-use && .build/debug/sim-use --version`，结果仍为：

- SHA-256：`d4b4a9dad762c970a3e2d155abd1affc720ebc1beafe33920cd6ef01af5362e7`
- 版本：`v0.16.0-1-gc02295e-dirty`

准备阶段、40 轮 filter、三次全量的每轮前后 hash 均一致；没有生成不同的 CLI 候选。完整记录位于 `.build/harmony-probe-race-rkqry023/`，包括 `full-01.*` 至 `full-03.*`、`full-results.json` 及归档的 `verification-runner.py.txt`；临时执行入口 `verify.py` 已移除。

本轮只修改 `Tests/HarmonyGestureContractTests.swift`、`Tests/HarmonyRoutingTests.swift` 和本目录的 001 / 003 文档。不 commit、push、开 PR，不操作手机，不跑付费 eval；没有新增人工或实机验收证据。**等待人工验收**与 cold 脚本“具体 OS 机制未知”的结论均不变。

## 上一轮：Android 回退、拔线 hint 与短超时调查（2026-11-05）

用户明确修订了上一轮要求：可选 hdc 发现失败不能阻断现有 Android 用户。本轮只处理批准的三项；不改 Android namespace 的命令注册，不修改 daemon 协议或扩大探测。**新候选没有人工或实机验收证据，状态仍为等待人工验收。**

### 修改与取舍

1. **探测失败继续 Android。** 非零退出、exit-0 `[Fail]` 和 1.5 秒超时均回退原 Android shape 路由，stderr 输出一次带失败原因及 `sim-use harmony <verb>` 替代方式的 warning。`SimUseExecutableCommand.run()` 建立 TaskLocal `PlatformRouter.Invocation`，覆盖 deferred resolution、daemon 平台选择和执行；同一调用不重试失败探测、不重复警告，下一调用可重新发现。失败没有写入 Hdc membership 缓存。采用现有 stderr 输出，而非新增 JSON advisory：它是路由阶段的诊断，不需要改变成功 JSON、daemon wire 或命令结果契约。
2. **拔线提示只在客户端补充。** hdc hook 已安装且无显式 namespace override 的顶层 adb device-not-found 错误，保留原 error/hint 并追加 Harmony 连接建议；覆盖 canonical、`adb: error: device` 和已知 adb failure wrapper 形态，排除工具本身缺失、offline 和无 adb 来源的文字。daemon stale 关闭响应也保留该 hint。未增加设备探测；hdc 缺失和显式 Android 的错误文案不追加该提示。
3. **短超时调查与测试结构修正。** 保留 `Hdc.run`、原 cacheLock 范围、1.5 秒和原计时断言；移除三个 Harmony 套件上的 `.serialized`。membership/cache 与路由语义改用确定性发现接口；真实进程期限另用已安装的 `/usr/bin/printf`、`/bin/sleep` 验证。没有用加大超时、预热或串行掩盖 cold 脚本启动延迟。

README、Skill、Unreleased Added 和 `000-plan.md` 同步。新增 [003-routing-timeout-review.md](003-routing-timeout-review.md) 保存批准背景、压力方法、阶段证据及未知边界。

### 明确变更的断言

| 测试 | 旧断言 / 本轮替代 |
| --- | --- |
| `HarmonyRoutingTests.probeFailures` | 从“抛错且不得 Android 回退”改为三类失败均返回 Android，同一 invocation 三次 resolve 只 probe/warn 一次。 |
| 原 `failingProbeCLI` → `failingProbeForwarding` | 不再断言失败中止、无 adb；确定性测试验证 daemon 平台选择和命令转发共享一次失败状态并继续 Android。真实 CLI、JSON stdout、stderr warning 及 daemon 路径由本轮离线矩阵覆盖。 |
| `failedProbeDoesNotPoisonNextInvocation`、`selectedAndroidFallback` | 新增下一调用可重试，以及普通 serial、emulator、环境选择均保持 Android 回退的行为断言。 |
| `unavailableBinary` → `unavailableHookForwarding`；`emptyDiscovery` | 将 cold CLI fixture 改为同一解析/转发路径的 hook 注入；仍断言无 hdc 或成功空结果走 Android，空结果不警告。 |
| `unsupportedVerbs`、`HarmonyGestureContractTests.topLevelDeltaRejection` | 保留原不支持能力和 delta 拒绝断言，改为真实 command 解析/执行加已知 Harmony hook，不再依赖新脚本须在 1.5 秒内启动。共享 gate 只隔离被修改的全局 hook，不关闭套件并行。 |
| `disconnectedHintGates`、`disconnectedHintDiagnostics`、`daemonStaleHint` | 新增 hint 门禁、原错误/hint 保留、三类 adb 缺失正例及六类反例、stale daemon 关闭 envelope 的客户端提示。 |
| `HarmonyTransportTests.membershipCache`、`membershipFailures`、`freshListing` | 用真实缓存算法的 listing seam 断言连接/二进制隔离、正负/空结果缓存、失败传播及可重试；fresh listing 仍走实际文件 transport，但不与 1.5 秒成员探测的墙钟捆绑。 |
| `membershipDeadline`、`processDeadline`、`immediateProcess`、`timeout` | 分开验证独立 1.5 秒发现预算和真实原生进程期限。保留 `1.4 ≤ elapsed < 4`、0.05 秒业务 timeout 及 `<3s` 清理上界；不再将缓存锁等待计入进程期限断言。 |

### 压力结果与未解决项

以下是独立抽取实际前后 Hdc 代码的压力记录，不是全量测试通过率。批宽 32，实际并行峰值 12；完整方法及额外对照见 003。

| 条件 | 修前失败 / 请求 | 修后失败 / 请求 |
| --- | --- | --- |
| 新写入可执行脚本，串行 | 0 / 100 | 0 / 100 |
| 新写入可执行脚本，并发 | 494 / 512（96.48%） | 499 / 512（97.46%） |
| 已安装 `/usr/bin/printf`，并发 | 0 / 1024 | 0 / 1024 |
| listing seam，Dispatch / TaskGroup | 尚无该 seam | 两种模式分别 0 / 1024 |

所有 cold 失败都缺少首个 child-entry 标记，超时时进程仍在。修前 `Process.run` 同步调用最长 6.660ms，超时后的 terminationHandler 最长延迟 1.705ms；未观察到子进程已退出而回调迟到导致的失败。另测缓存锁等待最长 2.080 秒，说明旧外层 elapsed 混入了锁等待。**可定位到新脚本首个成功标记写入前的延迟，但具体 OS 机制仍未知；cold 压力仍失败，没有声称修复 cold 执行或生产 `Hdc.run`。**

失败记录未省略：后测预热自身也超时，harness 以 -5 退出、未采到请求，不能算 0 失败；0.05 秒 TERM 诊断有 1/128 未到达额外 trap-readiness 标记，但 128/128 都符合原 bounded-timeout 契约，该新 readiness 条件未加入永久测试。

### 构建与连续五次全量

源代码冻结后连续执行，之间没有代码修改。使用默认全量 `make test`（coverage 开启），没有 filter、`--no-parallel` 或本轮新增 suite serialization。`SIM_USE_XCSIFT=0` 仅保留完整日志；E2E opt-in 环境变量不启用。前两次将 `SIM_USE_HDC` 指向本轮证据目录下的不存在路径；后三次完全移除该变量，PATH 保留本机真实 hdc，仅允许只读发现。

| 次序 | 实际命令 | SIM_USE_HDC | 退出码 | 墙钟秒 |
| --- | --- | --- | --- | --- |
| 1 | `make build && make test` | 不存在路径 | 0 | 88.752（含 build） |
| 2 | `make test` | 不存在路径 | 0 | 40.537 |
| 3 | `make test` | 未设置 | 0 | 42.387 |
| 4 | `make test` | 未设置 | 0 | 41.154 |
| 5 | `make test` | 未设置 | 0 | 40.293 |

每次 XCTest 均为 48、52、231 tests / 0 failures；Swift Testing 均为 1345、154、29 tests passed。本轮没有全量构建/测试失败。首轮仍有既有 `OrientationCalibrator.swift:43` 的 CoreGraphics import 警告，未越界修复。

### 离线 CLI 与 daemon

- **50 个矩阵场景符合预期。** nonzero、exit-0 `[Fail]`、timeout、`[Empty]`、hdc 缺失 × 普通 Android serial / emulator / `SIM_USE_DEVICE` / Harmony namespace / Android namespace × 可用/缺失目标。每次独立解析 stdout JSON，检查 stderr warning 次数、实际 fake hdc/adb 调用及 hint 门禁。顶层/Harmony 成功使用 `app-state`；Android namespace 成功使用已有 `keyboard-state` 与本地 fake bridge。目标缺失使用 `keyboard-state`。hdc 缺失时显式 Harmony 按预期报错，而不是转 Android。
- 三个顶层 timeout 后仍成功执行 Android 的场景耗时 1.612、1.601、1.627 秒；每次一次发现、一次 warning。`[Empty]` 不警告但 adb 缺失时追加 Harmony hint；缺失 hdc 和显式 Android 均不追加。
- **7 个真实 daemon 离线场景通过。** 三类发现失败后的 Android 成功；`[Empty]` 顶层 stale hint；显式 Android 和缺失 hdc 的无追加 hint 对照；发现失败加 adb 缺失的 warning/hint 组合。均使用独立 `TESTRECOVERYDAEMON01`–`07`，启动前确认无已有 footprint。成功 daemon 显式停止，stale daemon 自动退出；结束时 socket/pid/platform 均不存在。
- 另验证普通文本输出：Android 命令成功，warning 仅在 stderr。所有 smoke 使用显式 fake hdc/adb；fake bridge 仅监听 loopback，不连接设备。
- **取证配置失败 1 次，未改生产代码掩盖。** 初次矩阵错误地调用未注册的 `android app-state`，harness 发生 JSONDecodeError；旧 helper 在持久化前解码，因此该次原始 stdout/退出码没有保留，明确记为未知。改用已注册 `android keyboard-state` 的本地 fake bridge 后完成矩阵；没有改命令注册表，也没有重跑已通过场景。

证据：`.build/harmony-routing-recovery-ok4e1wrn/` 中的 `full-run-1.log`–`full-run-5.log`、`full-runs.json`、`offline-matrix.json`、`daemon-smoke.json`、`plain-output-smoke.json`、逐场景记录、`harness-setup-failure.json`、`candidate-identity.txt`、`verification-context.json` 和 `cleanup.json`。压力原始记录另在 `.build/harmony-transport-phases-20261105/`。临时 transport/验证脚本、loopback 服务和隔离 HOME 已清理，源码保留于证据 JSON；没有创建真实 HOME 的 bridge session 文件，没有改写旧轮次证据。

### 当前限制与候选

`shasum -a 256 .build/debug/sim-use` 实测为本页顶部 `d4b4a9da…`，版本仍为 `v0.16.0-1-gc02295e-dirty`。本轮未操作手机、未运行真实 hdc 设备命令、E2E 或付费 eval；未 commit、push 或开 PR。三次无覆盖变量的全量测试使用已安装 hdc 环境，不等于真机验收。

已知未解决：cold 脚本首标记前延迟的具体 OS 机制；上一轮记录的键盘遮挡仍未确认、未改代码。新候选无人工或实机验收证据；其余初期实机/平台覆盖限制继续见下方“未覆盖与下一阶段”。

## 上一轮：十项授权复查清单（2026-11-05，候选 9d21fc26）

该轮以用户当时批准的十项清单为准。下面保留该候选的原始结果；其中“探测失败即中止”和以套件串行处理短超时的结论，已被本轮新授权及取证结果替代，不再代表当前行为。该轮没有真实 hdc 调用、手机操作、E2E、付费 eval、commit、push 或 PR，也没有人工或实机验收证据。

### 逐项处理

| 项 | 核实、修改与边界 |
| --- | --- |
| 1. 路由吞错 | 成立：`try?` 将工具失败折叠成非成员。membership hook 和 resolver 改为 throwing，调用方全部迁移；失败明确报告 `hdc membership probe failed`，不调用 adb。hdc 未安装时仍不安装 hook，保留原 Android 路由。**成功的 `[Empty]` 不是探测失败，继续按 Android 形状回退**：空列表无法识别从未见过的断连 Harmony serial，已知 Harmony 目标应使用显式 namespace。这一现象保留，不将未知身份伪装成确定的 Harmony。 |
| 2. 探测拖慢 | 成立：成员探测原先继承业务默认 30 秒。现独立使用 1.5 秒，业务 timeout 不变；补缓存、失败不缓存、挂起、缺失工具及 inline/daemon 前置失败回归。 |
| 3. swipe delta | 成立：Harmony 分支忽略显式 `--delta`。现以 `CLIError` 在输入前明确拒绝，JSON 保留具体原因；iOS/Android 分支未改变。 |
| 4. scroll 不一致 | 成立。两个入口统一默认 down、duration 秒单位及默认 0.4 秒，共用成功文案与校验。README、Skill 和 help 同步；不保留未发布的毫秒兼容别名，也没有扩大修改 swipe 的既有时长边界。 |
| 5. daemon 断连清理 | 成立：原 stale 判定没有 Harmony 诊断。仅完整匹配 hdc unknown-target transport 错误，容忍首尾换行；普通工具错误、超时、权限错误及嵌套相似文本不触发清理。补分类/dispatch 回归，并以实际 daemon + fake hdc 观察到 socket、pid、platform sidecar 自动清理。 |
| 6. devices 告警 | 成立：未安装 hdc 被视为未失败，从而挡住原有全失败告警。以 skipped/succeeded/failed 区分可选后端；hdc 缺失不参与成功判断，成功空列表仍算成功。覆盖原平台全失败、Harmony 缺失/失败/空成功和限定平台条件。 |
| 7. Changelog | 成立。未发布 Harmony app-state 能力并入 Added，不再作为已发布功能的 Fixed；未改 released 小节。 |
| 8. 无效 API/选项 | 成立。删除 `Hdc.isTargetConnected`，移除 Harmony `listUnifiedDevices(onlineOnly:)` 参数和无效 `harmony devices --online`；保留 Android 有效的同名参数。README/Skill 明确 Harmony 只列已连接设备，CLI 验证旧 flag 被拒绝。 |
| 9. 模块说明 | 成立。仅补 CLAUDE.md 中 HarmonyBackend 的模块依赖、第四个 verb surface 及注册说明。 |
| 10. 公开仓库脱敏 | 成立。Sources/Tests/docs 定向检索中的真实 serial 已替换为明显占位值 `TESTHARMONY000001`，仍满足 Android-shaped serial 路由测试条件；原始 `.build` 证据未改写。本文历史命令也仅保留脱敏表示。 |

没有因“不成立”跳过整项；第 1 项的成功空列表边界按上述依据保留。键盘遮挡仅记录为未确认项，未修改代码；最小用户复现步骤见下方“未覆盖与下一阶段”。决策同步到 `000-plan.md`。

### 实际验证与失败记录

构建和测试均设置 `SIM_USE_HDC=/Users/xiaochen/Downloads/sim-use/.build/harmony-review-checklist-p10wrpmi/not-installed-hdc`，防止测试意外使用本机 hdc；各 fake-transport 测试自行显式覆盖该路径。

| 命令/场景 | 实际结果 |
| --- | --- |
| 首次 `make build && make test` | build 成功，test 退出 2，17 issues；集中于新 1.5 秒探测下的并发 fixture 超时及计时超限。保留失败日志，未视为通过。 |
| 定向并发诊断 | `swift test --filter 'HarmonyTransportTests\|HarmonyRoutingTests\|HarmonyGestureContractTests'`：27 tests，8 issues。仍有立即输出的 fixture 超时，部分脚本未产生启动标记。 |
| 串行对照诊断 | 相同 filter 加 `--skip-build --no-parallel`：超时问题消失，剩 1 issue，揭示 `--delta` 的 runtime `ValidationError` 被 JSON 包装成通用错误。相关 Harmony fixture 套件改为套件内串行，保留生产 1.5 秒及原计时断言；delta 改用现有 `CLIError`。没有全局关闭测试并发或掩盖无关失败。 |
| 最终 `make build && make test` | **退出 0**，完整默认测试命令通过；没有 filter 或 `--no-parallel`。XCTest：48、52、231 tests，0 failures；Swift Testing：1337、154、29 tests passed。仍有既有 `OrientationCalibrator.swift:43` 的 CoreGraphics import 警告，未扩展修复。 |
| 最终 fake-hdc CLI smoke | 14 个场景通过。非零退出及 exit-0 `[Fail]` 均报告探测失败，adb 调用为 0；挂起在 1.536 秒失败。hdc 缺失和成功空列表保留 Android 回退；显式 Harmony 的断连返回 hdc 错误。 |
| swipe/scroll/help | delta 拒绝且没有设备输入调用。两个 scroll 入口省略 direction/duration 均为 down/0.4 秒；400 px 对应原生 velocity 1000，显式 0.5 秒对应 800；坐标及成功文案一致，help 显示秒单位和相同默认值。删除的 `--online` 退出 64，未调用 hdc。 |
| 实际 daemon 离线 smoke | 独立占位 serial `TESTHARMONYDAEMON0001`，启动前确认无现有 footprint；实际 CLI 经 daemon 返回 Harmony 断连原因及 hdc hint，约 0.73 秒完成。响应后 socket/pid/platform 均已删除，日志有 `cleanup complete`；未调用 adb。仅使用本轮 fake hdc，不接触其他 daemon。 |
| 候选身份 | `shasum -a 256 .build/debug/sim-use` 为本页顶部 `9d21fc26…`；`.build/debug/sim-use --version` 为 `v0.16.0-1-gc02295e-dirty`。 |

本轮证据位于 `.build/harmony-review-checklist-p10wrpmi/`：`build-test-attempt-1.log`、两个 `targeted-*-diagnostic.log`、`build-test-final.log`、`offline-cli-smoke.json`、`14-daemon-runtime.log`、`candidate-identity.txt`、`verification-context.json` 及逐场景输入/输出。前两个探索性 smoke 单独保留，不计入最终候选的 14 场景。临时 transport 可执行脚本和本轮独立 daemon 日志已清理，脚本源码随验证上下文保留；未改写旧轮次证据。

## 上一轮授权修复：进程解析与 init 测试（2026-11-05）

该轮只处理用户当时批准的三项问题：系统主进程被过滤、带空格进程名导致整表失败、恢复 `init --print` 测试。该轮没有操作手机，也没有处理后来另行授权的断线误报 Android、scroll 参数不一致或死代码；没有 commit、push 或 PR。

### 核实及修改

- 三条均成立。`parseProcesses` 原先明确排除 `com.ohos.*`，现有真实 `processes.txt` 已包含 `3229 com.ohos.sceneboard`；原测试反而将它排除在预期结果外。现已删除该前缀过滤，覆盖系统应用 running 和不存在系统应用 not_running。
- 行解析由所有空白分词改为仅在 PID 后切分一次，裁去名称首尾列填充，保留内部空格。仍要求正确的 `PID NAME` 表头、正整数 PID、名称；错误表格继续报错。仍过滤 `:` 服务/renderer 子进程及 `/` 路径，不引入前台判定或新的进程分类策略。
- 新增 `processes-whitespace.txt`，明确标为合成边界 fixture；覆盖 tabs、列填充、带空格名称、普通 native 进程和子进程。真实捕获的 `processes.txt` 内容保持不变。新增错误表头、非法/非正/溢出 PID、缺失名称及混合损坏行的回归。
- 恢复 `InitTests.printOutputsSkill`：实际执行 `init --print`，验证 frontmatter 起止、`name: sim-use` 及 `description:` 字段存在，不固定描述文本。下文已更正初次实现“仅删除断言”的不准确描述。

本轮文件：`Sources/HarmonyBackend/Verbs/HarmonyDeviceController.swift`、`Tests/HarmonyBackendTests.swift`、`Tests/InitTests.swift`、`Tests/Fixtures/harmony/processes-whitespace.txt`、`Tests/Fixtures/harmony/README.md`、`CHANGELOG.md`、`000-plan.md`、本执行记录。

### 本次验证

| 验证 | 实际结果 |
| --- | --- |
| `make build && make test` | 一次通过，退出 0；没有本轮构建/测试失败。仍有既有 `OrientationCalibrator.swift:43` 的 CoreGraphics import 警告，未扩展修复 |
| XCTest | 48、52、231 tests，0 failures |
| Swift Testing | 1318、154、29 tests passed；新增/恢复的测试全部通过。设备 E2E opt-in suites 未启用 |
| 无设备 CLI smoke | 使用临时 `SIM_USE_HDC` fixture transport 和 `SIM_USE_NO_DAEMON=1` 执行真实 CLI，不运行真实 hdc：系统应用 running、不存在应用 not_running、带空格进程不阻断其他查询、完整空格名称可查询均通过；损坏表格退出 1，`ok:false` |
| `.build/debug/sim-use init --print` | 退出 0，frontmatter 契约通过 |
| `shasum -a 256 .build/debug/sim-use` | 该轮重建与测试后的 SHA-256：`c5148efa4fd0b42db3cfa555c207276f8fcf4b196fcd7062a3969413dc1f25e2`；不再代表本页顶部的最新候选 |
| `.build/debug/sim-use --version` | `v0.16.0-1-gc02295e-dirty` |

本轮原始输出保存在 `.build/harmony-review-processes/build-test.log`、`offline-cli-smoke.json`。离线 transport 临时脚本已清理；没有永久假实现。没有执行真机、Linux 容器或最终 E2E 验证。

该轮 SHA-256 取代了初次实现的候选标识；下文保留初次实现的测量与实机证据，并明确其属于旧候选。该轮修复后也没有新增人工或实机验收证据，离线 smoke 不能替代这些验收。

## 实现结果

- 新增独立 `HarmonyBackend`。通过 host `hdc` 与设备原生 `uitest`、WMS、进程列表和截图工具实现第一期，不安装 HAP/APK。
- 支持 `devices`、`describe-ui`/`ui`、坐标/`@N`/selector tap、long-press、swipe、scroll、type、home/back/power、screenshot、app-state、keyboard-state；提供 `harmony` namespace 与顶层转发。不支持的功能明确拒绝，不伪装为 Android。
- 真实 JSON 树支持对象/数组根、隐藏祖先过滤、坐标、角色、outline、`@N`、selector 和系统 Dialog 提示。新增系统 SearchField 实测回归，保留原生子节点上的文本。
- `hdc` 发现支持覆盖路径、PATH、DevEco 路径；进程运行有超时及管道排空。设备工具退出码为 0 但输出失败时仍报错。截图校验原生结果，并按输出扩展名转换图像格式。
- 显式设备先查 hdc membership，避免 Harmony serial 被 Android 形状规则截获；隐式设备选择不探测 hdc、不选 Harmony daemon，保留 Android 优先级。
- daemon 的整数 pidfile 不变；新增 PID 绑定 `.platform` sidecar，随 daemon 生命周期清理。显式平台经 spawn 传递，连接 identity 纳入 hdc 连接域。旧客户端忽略新 sidecar。
- Linux target/dependency 图仍是 Android-only；`SimUseLinux` 仅适配共享 identity closure 参数。没有引入 Harmony 或 Apple framework 到 Linux 图。
- `type` 返回 `pasteboard_replaced` advisory；不承诺恢复剪贴板。WMS 中 `SCBKeyboardPanel` 的 ZOrd 判断显隐，无法识别/探测失败必须报错，不能谎报 hidden。
- README、Skill、Unreleased changelog、preflight 同步。Skill 的已发布版本门槛升至 0.17.0；开发构建沿用已有兼容策略，本轮没有发布或修改 binary 版本号。

## 实际命令与结果

### 主机依赖与构建

| 命令/步骤 | 实际结果 |
| --- | --- |
| `git switch -c feat/harmonyos-backend` | 成功；保留开始时已有的 012 计划/G1 和索引修改 |
| 初次 `make build` | 失败：五个 FB* XCFramework 产物缺失 |
| `brew install xcodegen` | 用户单独授权后成功，安装 2.46.0；Homebrew 自动更新至 7.0.12 |
| `./scripts/build.sh dev` | clone 失败：HTTP/2 cancel / early EOF；HTTP/1.1 全量重试仍以 curl 18 / early EOF 失败 |
| pinned idb 浅抓取 | 在新建、忽略的 `idb_checkout/` 中 `git init`、添加 facebook/idb remote、`git -c http.version=HTTP/1.1 fetch --depth=1 origin 1f6943f8a2cc1ce449f031241818032adaea2079`、`git checkout --detach FETCH_HEAD` 成功 |
| idb 项目生成 | 在该 checkout 执行 `git apply ../patches/idb/display-routing.patch ../patches/idb/display-video.patch`、`xcodegen generate` 成功 |
| `./scripts/build.sh frameworks && ./scripts/build.sh install && ./scripts/build.sh xcframeworks` | 成功生成五个 arm64/x86_64 XCFramework；没有修改业务 HEAD |
| 首次代码编译 | 失败：`CommandConfiguration` 的 abstract/aliases 参数顺序错误；已修复 |
| 最终 `make build && make test` | **成功**，退出 0；最终源码包含 SearchField 修复 |

最终构建仍有既有 `OrientationCalibrator.swift:43` 缺少显式 CoreGraphics import 的警告。本轮未扩展到该 iOS 文件。

### 单元测试与失败处理

- 首轮 `make test` 失败，实际问题包括：fixture selector 指向隐藏的旧 TextInput；旧 Skill 描述文本断言；stream-video 的 `--json` 参数验证先于平台拒绝；两个 daemon 测试套件在 parser gate 外启动进程，等待 gate 时触发 idle 退出。
- selector 改为真实可见 TextArea，并保留隐藏祖先/显式 offscreen 的行为断言。初次实现曾整条删除 `InitTests.printOutputsSkill`，并非仅删描述断言；2026-11-05 授权复查修复已恢复该测试，检查 frontmatter 边界、`name: sim-use` 和 `description:` 字段，不绑定描述措辞。stream-video 测试尊重既有不接受 `--json` 的契约，其他拒绝路径仍验证 JSON。
- `make build && swift test --filter 'Harmony|PreflightScriptTests|InitTests'`：55 tests / 7 suites 通过（当时尚未增加最后一个 SearchField 回归）。
- `swift test --filter DaemonClientConnectionIdentityTests`：2 tests 通过；`swift test --filter DaemonClientInvokeErrorRoutingTests`：9 tests 通过。随后全量仍只剩 daemon 生命周期竞态失败，未以单套件通过替代全量结果。
- 用户额外批准后，将两套测试的 daemon 启动、断言、shutdown 放到已有 parser gate 内；未增加 timeout，未弱化断言，未改生产语义。
- 该修复后的全量 `make test` 通过。随后真机发现 SearchField 被归类为 Button，补真实六节点 fixture 与 selector/readback 回归，再执行最终 `make build && make test`，再次通过。
- 最终 XCTest 三组分别报告 48、52、231 tests，0 failures；Swift Testing 三组分别报告 1315、154、29 tests passed。设备 E2E opt-in suites 未启用；这不是 live E2E 或 Linux 构建证明。
- Linux 容器验证未执行：本机没有 Docker/Podman/Colima/其他已安装容器运行时。没有擅自安装容器环境或触发 CI。macOS 中名为 Linux command surfaces 的测试通过，**不等于 Linux 编译通过**。

### 实机 smoke

以下为初次实现候选（SHA-256 `f88ab29b28706d502358cf44b6aa50d4de13864f17b1bbcc0c2a521ee180a57b`）的历史实机记录，不是复查修复后候选的实机验证。本次复查修复禁止操作手机。公开记录里的 serial 已统一替换为占位值，命令中的 `--device TESTHARMONY000001` 不是实际设备地址。原始命令、JSON、截图保存在忽略目录 `.build/harmony-smoke/`，未改写、不进入公开 fixture。

| 场景 | 命令示例与实际观察 |
| --- | --- |
| 设备/路由 | `devices --platform harmony --json` 返回真机及 `platform:harmony`；顶层 verbs 与 `harmony` namespace 均运行成功 |
| UI / aliases | `ui --json`、`ui --json --no-raw` 返回 1260×2720 outline、entries、aliases；系统输入框 `tap @11` 成功；百度输入和桌面图标也执行了 alias tap |
| 坐标 / selector | `tap --point 180,1960` 打开百度（有启动广告等待）；`tap --id hisearchSearchInput --element-type TextField` 与百度 `1322ai_SearchBox_textarea` selector tap 成功。桌面百度 TextView label 的一次 alias tap未打开应用，随后按实际图标几何点击成功；没有把出口 0 当成打开证明 |
| 系统中英文输入 | `type '鸿蒙测试abc123' --json`；截图看见完整内容和剪贴板菜单。最终重启本任务 Harmony daemon 后 `type '验证abc123'`，UI 子节点 `__SearchField__hisearchSearchInput` 的 role 为 TextField、label 为该实际文本 |
| 第三方输入 | 百度 `type '你好abc123'` 及 `harmony type '测试Harmony' --id 1322ai_SearchBox_textarea`；UI 和截图实际显示 `你好abc123测试Harmony`；没有提交搜索 |
| 剪贴板 | 两个输入 surface 均收到 `pasteboard_replaced` advisory。测试覆盖了原剪贴板；最后一次测试内容为 `验证abc123`，没有声称可恢复此前内容 |
| Long press | 系统 `hisearchSearchInput`、百度输入框长按均出现真实原生编辑菜单；未选择系统设置/USB 选项 |
| Swipe | 系统从 `630,600` 到 `630,1600` 打开全局搜索；百度执行垂直 swipe；返回成功。最终 feed swipe 后返回系统 home，未单独量化该次 swipe 的位移 |
| Scroll | 系统 `scroll --direction up --distance 350 --duration 500 --center 1050,1500` 后“搜索历史”稳定节点 y 从 715 到 960；百度 `scroll --direction down --distance 500 --duration 500 --center 1100,1600` 后稳定 feed 节点 y 从 1856 到 1188，观察到实际内容移动。此前空建议页上的 scroll 只证明调用成功，不作移动证据 |
| Keyboard | 系统搜索、百度输入中均观察到 soft/visible；Back 后观察到 hidden。关闭动画刚开始时立即探测仍 visible，等待实际收起后为 false。最后 Home 后 `keyboard-state --json` 为 `platform:harmony, visible:false` |
| Home / Back | 两个 surface 均执行；最后手机留在桌面。**未执行 power**，避免锁屏 |
| Screenshot | 系统/百度 PNG 均能解码并实际查看。跨 cwd `--output caller.png` 首次错误写入 daemon cwd；恢复截图 in-process 例外后，重新执行实际写入调用者临时目录，保留为 `caller-relative-path.png` |
| App state | `app-state --bundle-id com.baidu.baiduapp --json` 返回 `platform:harmony`、`query:{bundleId:com.baidu.baiduapp,state:running}`；这是进程存在性，不是前台判定 |
| 探测错误 | `SIM_USE_NO_DAEMON=1 ... harmony keyboard-state --device NOT-CONNECTED-HARMONY --json` 退出 1，JSON `ok:false`；识别到 hdc 自身退出 0 的 `[Fail]Not match target...`。这是错误路径，不是物理拔线试验 |
| 默认选择 | 真实 Android 与 Harmony daemon 同时存在、无 booted iOS simulator 时，不带 device 的 `keyboard-state --json` 返回 Android，不选 Harmony。六种默认选择组合另有单元测试 |
| Skill preflight | `/usr/bin/python3 skills/sim-use/scripts/preflight.py --sim-use-bin .build/debug/sim-use --device TESTHARMONY000001`（serial 已脱敏）：四项 PASS，识别 harmony。旧安装版本曾被新版门槛拒绝，属于预期兼容性失败 |

期间手机曾锁屏：停止设备操作、报告后，由用户选择“已手动解锁，继续验证”才恢复。没有尝试密码。结束时只停止本任务的 Harmony daemon；保留另一会话的 Android daemon，没有安装/卸载应用、修改系统设置或触发付费 eval。

## 决策与偏离

详细理由已同步 [000-plan.md 的 Decisions](000-plan.md#alternatives--decisions)。本轮新增/明确：

1. PID 绑定 sidecar、hdc 连接域与隐式选择隔离；Skill release floor 为 0.17.0，开发 binary 版本不变。
2. 原生 longClick 不支持自定义时长，text 不支持 clear；明确拒绝而不忽略。swipe 仅在原生速度范围内换算，不悄悄 clamp。
3. 原生 screenshot JPEG 转码到用户请求格式；截图沿用现有 daemon bypass，保证调用者相对路径语义。这是计划“通用 daemon 路径”的必要例外。
4. 实现过程中曾接入额外的自动 Harmony crash monitor，实机触发了无关系统进程退出提示。它不属于批准的第一期，已删除该额外 hook/包装；仅保留显式 app-state，未改 iOS/Android monitor。
5. 系统 SearchField 的真实类型/文本位置经实测补齐；真实 fixture 脱敏而不伪造结构和状态。
6. 额外依赖安装、框架 bootstrap 与两套既有测试的生命周期修正，均单独取得用户授权；未静默扩展生产范围。

## 未覆盖与下一阶段

- **人工验收未进行。** Agent 操作不算人工通过；必须绑定以上 dirty 候选和二进制 fingerprint 验收。
- 未运行 Linux build/test/help；需可用容器或后续授权 CI。
- 未物理拔线验证 keyboard-state；仅实际无效 serial 错误和解析/失败单测。
- 未操控其他会话 Android daemon、未启动 iOS simulator，因此未完成“仅 Harmony daemon”及“Android daemon + booted iOS simulator”的实机组合；有默认选择单元测试与现有混合 daemon 读操作证据。
- 未测试 power、真实 USB Dialog 关闭、屏幕横竖切换/折叠、模拟器、其他第三方键盘/应用。真实 Dialog fixture 有警告与不执行操作的契约测试。
- 不承诺剪贴板恢复、自定义长按 duration、type clear、phase-2 multi-touch/video/agent；保持明确能力边界。
- `make e2e-ios`、`make e2e-android`、matrix、paid agent eval 全部未运行；按授权留到人工通过与 Review Loop 收敛后的最终验证。
- **键盘遮挡：用户已确认旧候选 d4b4a9da 的真实误触；新候选等待复验。** 本轮使用已有真实 `third-party.json` 完成红测与共享 outline/alias/selector 过滤修复，没有操作手机。旧版“未确认、未修改实现”的结论已被用户这次设置搜索页证据取代。无有效输入法 panel bounds 时仍不推断遮挡；诊断不滤视图与陈旧 alias 不提供实时防误触保证。

  最小真机复验步骤（本轮未执行，由用户另行授权）：
  1. 在同一 Mate 60 Pro 设置搜索页，以新的候选 SHA 重现键盘可见状态，不输入秘密或提交有副作用的操作。保存默认 `sim-use harmony ui --device <serial> --json --no-raw` 和同状态截图。
  2. 对照诊断 `ui --include-offscreen`，确认“蓝牙音频采样率”等中心点处于键盘 panel 内的 App 元素不在默认 outline 中；键盘自身控件与中心点未被遮挡的部分可见结果仍存在。诊断模式允许保留覆盖项，不使用它生成的 alias 操作。
  3. 重新运行默认 `ui`；用该覆盖项的 identifier/selector 验证返回无匹配和重新 describe-ui 的提示，且输入框没有多出键盘字符。检查 List 的 cell 数量与连续 alias；不要沿用旧截图的 @N。
  4. 仅对用户确认无害、中心点可见的结果使用新 alias，核对实际响应；再收起键盘并刷新 UI，确认原覆盖项重新可选。保留前后文本与画面，不把离线 fixture 通过当作真机验收。

## 证据位置

- `.build/harmony-smoke/build-test-final.log`：最终成功构建和测试的完整输出。
- `.build/harmony-smoke/test-initial-failures.log`、`test-daemon-race.log`：失败记录，未删除或用成功结果覆盖。
- `.build/harmony-smoke/command-log.json`、编号 smoke JSON、`50-final-preflight.txt`：实际 CLI 输入/输出。
- `.build/harmony-smoke/system-input.png`、`app-after-gestures.png`、`system-after-scroll.png`、`baidu-feed-after-scroll.png`、`caller-relative-path.png`：本地截图证据，可能包含设备内容，不应提交。
- 临时跨 cwd 目录及误写到仓库根的 `caller.png` 已清理；构建依赖和本地证据保留在忽略目录。

## 文件清单

开始时已有 `docs/ai/README.md` 修改及未跟踪的 012 计划/G1，均予以保留；计划和索引按本任务更新，G1 不改。以下为本轮新增/修改的完整路径（不含忽略的构建和证据产物）：

```text
CHANGELOG.md
CLAUDE.md
Package.swift
README.md
Sources/HarmonyBackend/Hdc/Hdc.swift
Sources/HarmonyBackend/Normalizer/HarmonyLayout.swift
Sources/HarmonyBackend/UITest/UITestClient.swift
Sources/HarmonyBackend/Verbs/HarmonyCommand.swift
Sources/HarmonyBackend/Verbs/HarmonyDeviceController.swift
Sources/HarmonyBackend/Verbs/HarmonyScreenshotCommand.swift
Sources/HarmonyBackend/Verbs/HarmonyStateCommands.swift
Sources/HarmonyBackend/Verbs/HarmonySwipeCommand.swift
Sources/HarmonyBackend/Verbs/HarmonyTapCommand.swift
Sources/SimUse/Commands/AppState.swift
Sources/SimUse/Commands/Button.swift
Sources/SimUse/Commands/DescribeUI.swift
Sources/SimUse/Commands/Devices.swift
Sources/SimUse/Commands/Gesture.swift
Sources/SimUse/Commands/KeyboardState.swift
Sources/SimUse/Commands/LongPress.swift
Sources/SimUse/Commands/MultiTouch.swift
Sources/SimUse/Commands/Paste.swift
Sources/SimUse/Commands/RecordVideo.swift
Sources/SimUse/Commands/Screenshot.swift
Sources/SimUse/Commands/Scroll.swift
Sources/SimUse/Commands/StreamVideo.swift
Sources/SimUse/Commands/Swipe.swift
Sources/SimUse/Commands/Tap.swift
Sources/SimUse/Commands/Touch.swift
Sources/SimUse/Commands/Type.swift
Sources/SimUse/main.swift
Sources/SimUseCore/CommandAdvisory.swift
Sources/SimUseCore/Daemon/DaemonClient.swift
Sources/SimUseCore/Daemon/DaemonCommand.swift
Sources/SimUseCore/Daemon/DaemonDispatch.swift
Sources/SimUseCore/Daemon/DaemonProtocol.swift
Sources/SimUseCore/Daemon/DaemonServer.swift
Sources/SimUseCore/DaemonPaths.swift
Sources/SimUseCore/Device.swift
Sources/SimUseCore/DeviceResolver.swift
Sources/SimUseCore/ExecutionResult.swift
Sources/SimUseCore/Options/DeviceOptions.swift
Sources/SimUseCore/PlatformRouter.swift
Sources/SimUseCore/Types/SimUseExecutableCommand.swift
Sources/SimUseLinux/SimUseLinux.swift
Tests/CommandAdvisoryContractTests.swift
Tests/DaemonClientConnectionIdentityTests.swift
Tests/DaemonClientInvokeErrorRoutingTests.swift
Tests/DaemonErrorKindTests.swift
Tests/DaemonStaleSimulatorTests.swift
Tests/HarmonyBackendTests.swift
Tests/HarmonyDefaultSelectionTests.swift
Tests/HarmonyDeviceListingTests.swift
Tests/HarmonyGestureContractTests.swift
Tests/HarmonyRoutingTests.swift
Tests/InitTests.swift
Tests/PreflightScriptTests.swift
Tests/SimUseCoreTests/PlatformRouterPhysicalDeviceTests.swift
Tests/TapForwarderTests.swift
Tests/Fixtures/harmony/LICENSE.spdx
Tests/Fixtures/harmony/README.md
Tests/Fixtures/harmony/app-after-back.wms
Tests/Fixtures/harmony/app-hidden.wms
Tests/Fixtures/harmony/app-shown.wms
Tests/Fixtures/harmony/home.json
Tests/Fixtures/harmony/processes.txt
Tests/Fixtures/harmony/processes-whitespace.txt
Tests/Fixtures/harmony/system-after-back.wms
Tests/Fixtures/harmony/system-dialog.json
Tests/Fixtures/harmony/system-hidden.wms
Tests/Fixtures/harmony/system-search-input.json
Tests/Fixtures/harmony/system-shown.wms
Tests/Fixtures/harmony/third-party.json
skills/sim-use/SKILL.md
skills/sim-use/scripts/preflight.py
docs/ai/README.md
docs/ai/012-harmonyos-backend/000-plan.md
docs/ai/012-harmonyos-backend/001-action.md
docs/ai/012-harmonyos-backend/003-routing-timeout-review.md
```
