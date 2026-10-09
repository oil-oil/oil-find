# Oil Find

免费开源的 macOS 原生文件搜索工具（苹果版的 Everything），按 ⇧⌘F 唤起搜索面板。架构与索引不变量见 `docs/ARCHITECTURE.md`。

## 目录

- `Sources/COilFind/`：C 批量目录读取、名称比较与搜索评分。
- `Sources/OilFindCore/`：扫描、索引、查询、实时更新、持久化和应用更新。
- `Sources/OilFindApp/`：AppKit 应用库与 SwiftUI 设置；免费界面文案集中在 `L10n.swift`，中性扩展点为 `ApplicationExtension`。
- `Sources/OilFind/main.swift`：可执行应用的组装入口。
- `Sources/oilfind-cli/`：命令行验证工具。
- `Tests/`：核心引擎、应用界面与脚本测试。
- `Resources/`：应用元数据和图标。
- `scripts/`：构建、打包、安装与卸载。
- `site/`：Next.js App Router 官网、搜索演示、更新日志与静态更新清单。

## 构建与测试

部署目标 macOS 14，面向 Apple 芯片。

```sh
swift build -c release
swift test
python3 Tests/Scripts/test_uninstall.py
python3 Tests/Scripts/test_open_core.py
scripts/build-app.sh
scripts/build-app.sh --debug
scripts/package.sh
```

`Pro/` 是工作区内可选的独立私有仓库，不属于本公开仓库，由 `/Pro/` 忽略规则排除。缺少私有模块时构建免费版；本机存在私有模块时可强制验证免费版：

```sh
OILFIND_FREE=1 swift build
OILFIND_FREE=1 swift test --filter '<受影响的测试>'
```

官网使用 Node.js 22 与 pnpm：

```sh
cd site
pnpm install --frozen-lockfile
pnpm dev
pnpm test
pnpm build
```

## 约定

- 应用使用 Swift 5 语言模式与一个 C target，只用系统框架，不引入第三方包。
- 公开应用库与核心不得依赖私有模块，只通过中性的 `ApplicationExtension` 接入。仅 `Package.swift` 和 `Sources/OilFind/main.swift` 可提及私有 target，分别用于条件构建与组装；入口不解析私有功能状态或参数。扩展提供启动、退出、设置分区、URL、语言接口，DEBUG 下可预处理并移除自身参数。
- 扫描、搜索、事件处理热路径使用 Unsafe 指针和 SoA 布局，不创建 String，不逐项堆分配。
- 代码注释用英文。修改界面文案时维护 `L10n.swift` 中的中英文对应项。
- 索引文件只保留一份，临时文件用完即删。没有完全磁盘访问权限时静默跳过 EPERM 目录。
- 界面验证使用调试版 `--snapshot`；正式版不包含该入口。
- 官网使用 TypeScript、React 和 Next.js，运行时依赖为 `next`、`react`、`react-dom`、`stripe`（授权接口用）；npm 与 pnpm 锁文件保持一致。
- 不提交环境文件、密钥、下载包、索引或构建产物。CI 通过 `CI=true` 跳过时间敏感或依赖本机真实索引的测试，本地照常运行。
