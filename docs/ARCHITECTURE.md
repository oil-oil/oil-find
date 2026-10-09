# Oil Find 架构

> 本文记录设计约束。性能目标不是实测结论；除非有可复现的基准记录，不应据此宣称百万条索引下的延迟或 macOS 14/15 实机验证。

## 目标

| 维度 | 要求 |
| --- | --- |
| 覆盖 | 默认索引启动卷上的个人文件与应用；依赖目录、包内部、`~/Library`、系统目录可在设置里打开，全开即整盘 |
| 速度 | 3 个字符以上的查询在 1000 万条目上 p95 ≤ 30 ms；单字符查询 ≤ 80 ms |
| 实时 | 文件新增、删除、改名、移动在 1 秒内反映到索引 |
| 启动 | 从磁盘加载已有索引 ≤ 1.5 秒，随后用 FSEvents 历史补齐离线期间的变动 |
| 内存 | 平均每条目 ≤ 70 字节（含哈希表） |
| 交互 | ⌘Space 默认唤起，面板在屏幕正中，键盘即可完成全部操作 |

不做的事：文件内容搜索、网络卷与外接磁盘索引、沙盒化上架。

## 工程结构

```
oil-find/
  Package.swift
  Sources/
    COilFind/                 C：SIMD 子串扫描、目录批量读取、名称比较
      include/coilfind.h
      coilfind.c
    OilFindCore/              Swift：既有索引与文件搜索引擎，不依赖 AppKit
      Classifier.swift     条目分类：kind、包、噪声、隐藏
      IndexStore.swift     SoA 存储、读 API、路径还原
      IndexStore+Build.swift      由扫描结果构建
      IndexStore+Mutation.swift   哈希表、增删改、清扫、压实
      IndexStore+Persistence.swift
      Scanner.swift        并行目录遍历
      Pinyin.swift         汉字转拼音、备用搜索键
      Query.swift          查询语法解析
      Searcher.swift       搜索执行、打分、排序
      FSWatcher.swift      FSEvents 封装
      IndexManager.swift   加载、扫描、监听、保存的编排
      IndexConfig.swift    根路径、排除规则、指纹
      Coverage.swift       未覆盖统计与单路径检查
      SearchCache.swift    增量收窄与结果缓存
      Update/              版本检查、下载、校验与安装
    OilFind/                  AppKit 应用、语言管理与 SwiftUI 设置
    oilfind-cli/              命令行工具，用于验证引擎
  Tests/OilFindCoreTests/
  Tests/OilFindUITests/
  Tests/Scripts/
  site/                       Next.js 官网与更新静态资源
  Resources/Info.plist
  Resources/AppIcon.icns
  scripts/build-app.sh
  docs/
```

`Package.swift`：`swift-tools-version:5.10`，`platforms: [.macOS(.v14)]`，四个 target（`COilFind`、`OilFindCore`、`OilFind`、`oilfind-cli`）加两个测试 target（核心引擎与应用界面）。应用 bundle id 为 `com.oiloil.find`。

## 索引存储 IndexStore

全部数组用 `malloc/realloc` 管理，按条目下标并列存放（SoA）。

| 数组 | 类型 | 长度 | 含义 |
| --- | --- | --- | --- |
| `nameOff` | UInt32 | count + 1 | 名称在 `names` 中的起始偏移；`nameOff[count] == namesLen` |
| `parent` | UInt32 | count | 父条目下标；根条目指向自己 |
| `sizeC` | UInt32 | count | 压缩后的文件大小 |
| `mtime` | UInt32 | count | 修改时间，Unix 秒，越界截断到 0...UInt32.max |
| `flags` | UInt8 | count | 标志位 |
| `depth` | UInt8 | count | 绝对路径的组件数，`/` 为 0，上限 255 |
| `kind` | UInt8 | count | 类型分类 |
| `names` | UInt8 | namesLen | 全部名称的 UTF-8 字节，按条目顺序首尾相接，无分隔符 |
| `altOff` | UInt32 | altCount + 1 | 备用搜索键的偏移 |
| `altOwner` | UInt32 | altCount | 备用搜索键所属的条目下标 |
| `altNames` | UInt8 | altLen | 备用搜索键字节 |
| `table` | UInt32 | max(1024, count × 5 / 4) | (父下标, 名称) → 条目下标 的开放寻址哈希表，空槽为 0xFFFFFFFF |

另有标量：`caseSensitiveNames`（扫描卷的名称比较方式）、`configFingerprint`（配置指纹）、`fsEventsUUID`（FSEvents 流 UUID）、`rootPath`（扫描根的绝对路径，整盘索引为 `/`）、`homeIndex`（当前用户主目录的条目下标，不存在为 0xFFFFFFFF）、`liveCount`、`deletedCount`、`version`（每批变更加一）、`lastEventId`、`scanFinishedAt`。

### 不变量

1. 条目 0 是扫描根，名称为空。
2. 对所有 i > 0，`parent[i] < i`。
3. 条目 i 的名称正好是 `names[nameOff[i] ..< nameOff[i+1]]`。
4. 一个 store 对象生命周期内下标不变。删除只打墓碑标志；压实会生成新的 store 对象。
5. 名称统一为 NFC。含非 ASCII 字节的名称入库前做 `precomposedStringWithCanonicalMapping`。
6. 读操作持读锁，写操作持写锁（`pthread_rwlock_t`）。持锁期间不做文件 I/O。

### 标志位

| 位 | 名称 | 含义 |
| --- | --- | --- |
| 0x01 | dir | 目录 |
| 0x02 | symlink | 符号链接（不跟随） |
| 0x04 | hidden | 名称以 `.` 开头，或带 `UF_HIDDEN` |
| 0x08 | deleted | 墓碑 |
| 0x10 | noise | 位于噪声区域内（从祖先继承） |
| 0x20 | inPackage | 位于某个包的内部（从祖先继承） |
| 0x40 | package | 自身是包（目录且扩展名在包列表里） |
| 0x80 | userArea | 位于当前用户主目录之下（从祖先继承） |

「干净条目」定义：`userArea && !noise && !inPackage && !hidden`。

### 大小压缩

```
encode(size): size < 0x8000_0000 ? UInt32(size) : 0x8000_0000 | min(size >> 12, 0x7FFF_FFFF)
decode(c):    c & 0x8000_0000 == 0 ? UInt64(c) : UInt64(c & 0x7FFF_FFFF) << 12
```

目录的大小记 0。

### kind 取值

| 值 | 名称 | 判定 |
| --- | --- | --- |
| 0 | other | 其余 |
| 1 | folder | 目录且不是包 |
| 2 | app | 扩展名 `app` 的包 |
| 3 | document | pdf doc docx xls xlsx ppt pptx pages numbers key txt md markdown rtf rtfd csv tsv epub mobi odt ods odp tex log |
| 4 | image | png jpg jpeg gif heic heif webp bmp tiff tif svg psd ai sketch fig raw cr2 cr3 nef arw dng ico icns avif |
| 5 | video | mp4 mov mkv avi wmv flv webm m4v mpg mpeg 3gp rmvb |
| 6 | audio | mp3 wav flac aac m4a ogg wma aiff aif opus mid midi caf |
| 7 | code | swift c h m mm cpp hpp cc js jsx mjs cjs ts tsx py rb go rs java kt php html htm css scss less vue svelte astro sh zsh bash json yaml yml toml xml sql lua dart cs r pl gradle plist ipynb |
| 8 | archive | zip rar 7z tar gz bz2 xz tgz zst dmg iso pkg jar war apk ipa |

扩展名取最后一个 `.` 之后的部分，长度 1...8，ASCII 小写后打包成一个 UInt64 作为查表键。包（除 app 外）的 kind 按扩展名查表，查不到为 other。

### 包扩展名

```
app bundle framework plugin kext appex xpc prefpane qlgenerator mdimporter saver component
vst vst3 photoslibrary musiclibrary tvlibrary fcpbundle imovielibrary xcodeproj xcworkspace
playground xcarchive dsym rtfd scptd lproj logicx band screenstudio pages numbers key
```

`pages`、`numbers`、`key` 只在条目是目录时才算包。`lproj` 算包是为了让本地化资源不干扰结果。

### 噪声规则

目录 D 满足以下任一条件时，D 的所有后代带 `noise`：

- D 的名称在此列表中：`node_modules .git .svn .hg __pycache__ .venv venv site-packages Pods DerivedData .gradle .npm .pnpm-store .yarn .cache .cargo .rustup .Trash Caches Cache .next .nuxt bower_components .idea .build .swiftpm CMakeFiles .tox .mypy_cache .pytest_cache .terraform`
- D 带 `hidden`
- D 的深度为 1 且名称是 `System private usr bin sbin opt Library cores` 之一
- D 的名称是 `Library`，深度为 3，且祖父目录名称是 `Users`

`noise`、`inPackage`、`userArea` 都沿父子关系向下继承。主目录条目自身不带 `userArea`，它的后代带。

## 默认排除

排除的目录不进索引、不下探，FSEvents 中位于其下的事件直接丢弃。

绝对路径（`~` 为当前用户主目录）：

```
/System/Volumes
/Volumes
/dev
/cores
/.vol
/private/var/folders
/private/var/db
/private/var/vm
/private/var/run
/Library/Caches
~/Library/Caches
~/.Trash
```

任意层级的目录名：

```
.Spotlight-V100 .fseventsd .DocumentRevisions-V100 .TemporaryItems .Trashes .MobileBackups
```

默认索引范围由四个默认关闭的设置开关控制：

- `indexDependencyDirs`：依赖与构建目录，按 `IndexConfig.dependencyNames` 的目录名集合排除。
- `indexPackageContents`：包自身可搜索，默认不深入包内部。
- `indexUserLibrary`：默认跳过用户 `Library` 的直属文件和大部分子目录；`Mobile Documents` 与 `CloudStorage` 保留，但受限模式仍排除它们。
- `indexSystemDirs`：默认跳过 `/Library`、`/usr`、`/bin`、`/sbin`、`/private`、`/opt` 及 `/System` 的直属文件和大部分子目录；`/System/Applications` 保留。

这些开关不取消默认的固定排除或设备规则。

设备规则：只下探 `st_dev` 属于 {`/` 的设备, `/System/Volumes/Data` 的设备} 的目录。扫描根不是 `/` 时，只允许扫描根自身的设备。

云端占位目录：带 `SF_DATALESS` 标志的目录入索引但不下探，避免触发下载。

受限模式（没有完全磁盘访问权限时）额外排除：

```
~/Library/Containers
~/Library/Group Containers
~/Library/Daemon Containers
~/Library/Mobile Documents
~/Library/CloudStorage
```

`IndexConfig` 持有根路径、两类排除列表、四个索引范围开关、是否受限模式、用户追加的排除路径，并提供 `fingerprint: UInt64`（对上述内容做稳定哈希）。指纹变化意味着已保存的索引作废。

## 线程模型

| 线程 | 职责 |
| --- | --- |
| 主线程 | 界面、结果渲染（读锁内取单行数据） |
| 搜索队列 | 串行，userInteractive；内部用 `DispatchQueue.concurrentPerform` 分块并行 |
| 扫描线程 | `activeProcessorCount` 个，utility 优先级 |
| 事件队列 | 串行，utility；FSEvents 回调与批量应用变更 |
| 保存队列 | 串行，background |

新查询到来时取消正在执行的旧查询：搜索函数接收 `isCancelled: () -> Bool`，每处理完一个分块检查一次。

## 结果的有效性

`SearchResult` 强引用它所来自的 store。全量重扫或压实后 `IndexManager` 换上新的 store 对象，界面收到通知后重新执行当前查询，旧 store 随旧结果一起释放。

## 查询语法与诊断

空格是 AND，`|` 是同一子句里的 OR，OR 两侧可以有空白；不支持括号布尔表达式。含 `/` 的词按路径组件匹配，可组合名称、操作符。`src/` 匹配目录后代，`/src/main` 匹配 src 下以 main 开头的条目。

输入先执行粘贴归一化（去整体引号、file URL 百分号解码、Shell 转义、扩展名后的行列后缀）。含空格的整段路径只在实际存在时作为一个路径词：先查当前索引，未命中时在读锁外最多 stat 一次；不存在时按空格分词。`Query.raw` 是归一化文本。

`!词` 排除文件名包含该词的条目，以及任意上级文件夹名称与该词完全相同（不区分大小写）的条目；上级检查在正向条件通过后执行，使用字节与 parent 链，不创建 String 或逐项分配。单名称保持原有 C 批量评分；名称加 ASCII 名称否定也批量评分，再只检查匹配候选的否定条件。`!path:词` 仍按路径包含匹配，`!src/` 按路径组件排除；拼音匹配用于名称，上级名称按实际名称精确比较。`file:词` / `folder:词` 正向单原子展开为名称 AND 类型筛选，OR 和取反时保持组合原子。

类型为 folder、app、doc、image、video、audio、code、archive；CLI 的 `--kind` 还接受 0…8，非法值报错并非零退出。其余语法：双引号、`*` / `?`、`ext:`、`file:`、`folder:`、`size:`、`dm:`、`path:`、`case:`、`regex:`，见 README。

解析返回可执行 Query 与结构化诊断。无效 regex、kind、size、dm 原子不阻断其他条件；仅无效条件时保留不可匹配的名称条件，不显示最近文件。编辑器通过 UTF-16 光标范围和组字状态延迟诊断，光标仍在词内（含词末）或组字时不报告。诊断、结果与当前查询一起提交；无结果时显示诊断空状态，有结果时底栏显示第一条诊断。⌘/ 打开/关闭语法速查，Esc 先关闭速查；内容与官网语法表逐字一致。

## 未覆盖统计

扫描与增量更新按权限（EPERM/EACCES）、四个范围开关、用户排除、SF_DATALESS 云端目录、/Volumes 下真实挂载点聚合。统计单位是实际遇到的被跳过入口，不枚举其后代；增量更新累加观察次数，重扫重置。每类最多 5 个不同示例，满额后只增加计数，路径不写日志。受限配置的额外权限排除归入没有权限。范围排除以配置检查优先匹配的原因计一次；包自身保持可搜索，其未深入内部计作包入口。

统计归属 IndexStore，跟随扫描替换、压实与版本保存；索引格式 3 在原数组后附加有长度上限的统计 JSON，兼容读取格式 2（统计为空），只保留一份索引。设置只展示非零行，范围行展开后按开关显示示例。单路径检查先查索引，再区分外置卷、用户排除、范围排除、权限、云端和等待加入；磁盘检查在索引锁外执行。

## 更新

发布说明唯一来源为 `site/content/releases.ts`，版本倒序排列，官网 `/changelog` 与 `/en/changelog` 直接读取。`scripts/package.sh` 必须使用已有的「Oil Find Self-Signed」证书签名，从 zip 的实际大小、SHA-256 与当前发布说明生成 `site/public/updates/latest.json`；缺少说明或证书时失败。清单为静态 HTTPS 资源，`Cache-Control: no-cache`，zip 沿用下载目录缓存。应用不使用 Apple Developer ID、Sparkle 或第三方更新包。

`OilFindCore/Update` 提供语义版本、清单、偏好、网络、安装与重启类型。版本遵守 SemVer，预发布版本低于正式版，忽略版本元数据；仅语义版本相同时比较 build。最低系统要求高于当前系统时不提示。`automaticUpdates` 默认为 true；启动 30 秒后检查一次，随后每 24 小时检查。`skippedUpdateVersion` 仅阻止该版本的自动提示，不影响手动检查。网络失败自动检查静默，手动检查报告原因。

版本检查只有一个 GET 请求，使用临时 URLSession，禁用缓存、cookie 和凭证，不携带设备标识、语言或本机路径；User-Agent 为 `OilFind/<版本>`。正式应用清单地址固定为 `https://find.oiloil.org/updates/latest.json`，仅接受 HTTPS 下载与清单同一主机的 zip，不跟随重定向。调试版不执行更新检查；快照与临时目录端到端演练入口仅在 DEBUG 编译，正式版没有清单地址覆盖入口。

用户确认安装后，URLSession 下载到临时目录并报告进度；流式校验大小与 SHA-256。在当前应用旁建立同卷、0700 权限的临时工作目录，检查压缩包路径与符号链接后用 `ditto -x -k` 解压。Security 从 `SecCodeCopySelf` 取得当前运行代码，再取得其 designated requirement；新包必须签名有效且满足该要求（同一 bundle id 与证书 leaf 哈希），Info.plist 的 bundle id 必须为 `com.oiloil.find`，版本高于当前并与清单一致。

安装先记录收据，移动当前应用到工作目录的 `previous.app`，再把新应用移到原位置。第二次移动失败立即还原备份；如果还原本身发生文件系统错误，则保留备份，不删除工作目录。当前应用或所在目录不可写时停止，不尝试提权。文件操作与签名校验通过协议注入，所有校验发生在替换之前。

替换后启动分离的等待进程，以位置参数传入路径，等待当前进程退出再用 `open -n -W` 打开原位置的新应用；当前进程正常退出时仍执行索引保存。新进程尽早记录 PID，启动完成后按匹配目标路径、版本和 build 的收据写入独立的 `launch-confirmed` 标记，等待进程收到确认后删除备份与临时目录。清理失败不影响已确认启动的新应用，下次启动再清理。等待进程启动失败时应用还原旧包；`open` 失败、新进程提前退出或 60 秒内没有启动确认时，等待进程停止未完成启动的新进程，还原并重开旧包。旧包按失败标记显示原因并清理临时目录。下载与校验失败清理临时文件，替换失败保留可用应用与必要备份。

`UpdateManager` 在主线程拥有检查、可更新、下载、安装、最新和失败状态；网络与安装不阻塞界面，重复操作在处理中禁用。下载与安装期间禁止提前退出，启动等待进程后才允许正常退出；下载文件在退出前显式清理，不依赖异步任务的 defer。菜单显示可用版本与下载进度，更新窗口复用同一状态，设置通用区域提供自动检查开关、提示、手动检查和当前版本。双语界面文案集中在 `Sources/OilFind/L10n.swift`。


## 应用与官网

### 统一搜索与来源边界

`SearchCoordinator`、`SearchScope` 与 `SearchSnapshot` 都位于 `Sources/OilFind/` 的应用层，不属于 `Sources/OilFindCore/`。协调器是搜索面板与各来源之间的编排层，接收当前范围、输入、编辑光标和组字状态，将文件请求送入串行文件队列，将应用、设置、剪贴板及本地工具请求送入来源队列，并以 `SearchSnapshot` 交回 UI。文件查询与来源查询有各自的请求代次和取消判断。快照保留文件结果及其紧凑条目下标，只把有限的应用、设置和工具结果提升为行对象；来源结果不复制或展开整份文件索引。协调器不拥有索引存储，也不把其他来源写入 `IndexStore`。

此次扩展沿用现有 `Sources/OilFindCore/` 文件引擎，不改变其公共接口。紧凑文件来源适配既有 `IndexManager`、`SearchCache` 和 `Searcher`；应用层负责组合不同来源、展示结果和处理范围切换。不得把新增应用能力描述成 Core 文件引擎 API 的变化。

| 来源 | 输入与职责 | 生命周期及边界 |
| --- | --- | --- |
| 文件 | 紧凑文件来源包装现有 `IndexManager` / `IndexStore`，提供名称查询、文件类型筛选、Quick Look 和现有文件操作 | 索引加载、扫描、FSEvents、保存沿用索引生命周期；只读取名称、大小、修改时间等索引字段，不读文件内容 |
| 应用 | `ApplicationCatalog` 枚举可启动应用并按查询排序 | 应用启动时后台枚举并观察目录，应用退出时停止；目录变化合并刷新并更新修订号，不改变文件索引范围 |
| 剪贴板 | `ClipboardHistory` 监视获准的纯文本、链接及本地文件/文件夹路径引用，搜索与管理历史；一组多文件作为一条记录 | 默认关闭，首次启用后开始记录，保留已有开启状态和偏好并兼容已有文本历史。默认保留 7 天和 500 条，可设为 1…365 天和 1…10,000 条。每条文本 UTF-8 最多 256 KiB；每条文件记录最多 1,000 个路径，所有路径 UTF-8 总计最多 256 KiB；合计最多 32 MiB（含有界来源元数据）。不读取或备份文件正文，不采集图片内容和文件承诺中尚未生成的内容；concealed、transient、autogenerated 标记及来源应用排除继续生效，默认排除已知密码管理器。CryptoKit AES-GCM 加密本机归档（含文件路径引用），密钥保存在仅此设备使用的钥匙串项目；暂停、清空、失效密钥和应用退出都由该来源管理 |
| 计算与单位 | `LauncherTools` 在当前输入满足语法时解析算式与单位换算 | 不创建网络请求；与文件索引和剪贴板存储无关 |
| 网页搜索与网址 | `LauncherTools` 识别网址与 `web:` 显式搜索；统一范围下也可显示普通查询的网页搜索候选 | 键入过程不发网络请求。默认 DuckDuckGo，可选 Google 或 Bing；仅当用户执行候选操作时打开 HTTPS URL |
| 设置 | `SystemSettingsCatalog` 匹配系统设置条目与别名 | 仅在设置范围或全部范围查询时生成候选；打开系统设置的入口按系统支持的 URL 与回退地址处理 |

文件来源是应用层 `SearchCoordinator.refreshFiles` 对现有 `IndexManager`、`SearchCache` 和 `Searcher` 的紧凑适配；它沿用原来的索引生命周期。应用目录和剪贴板由独立来源对象管理；计算、网址与网页搜索是纯输入解析工具，并不维持后台服务。切换到仅来源范围时旧文件查询会被新代次取消，结果快照只暴露所选范围；全部范围可以并列组合文件和其他来源。应用启动时启动来源生命周期；用户启用的剪贴板记录在面板隐藏后继续运行，退出应用时停止并提交待保存数据。提供方错误只影响对应来源，不得使文件索引失效。

应用与文件的重复项使用共同的文件路径身份去重。少量已提升的应用先解析成文件 ID，随后对结果的紧凑 ID 数组做一次 SIMD 批量扫描，生成有限的移除位置；扫描不创建逐文件行对象。可见行按需解析路径。后续来源发布按稳定身份恢复用户选择，文件来源暂时不可用时保留文件身份与视口，文件返回后恢复；用户再次导航会取消旧恢复锚点。

剪贴板默认关闭，首次启用是开始记录的入口；启动监视时先记录 pasteboard change count 基线，不收集启用前的内容。升级保留已有开启状态和偏好，归档兼容已有文本历史。历史接收获准的单项纯文本（链接作为普通文本保存），以及本地文件和文件夹的路径引用；采集时只解析实际 file URL / legacy filenames 路径引用，不为每次采集逐个 stat 文件。一组多文件保存为一条历史，列表显示名称和数量，搜索匹配文件名与路径。归档只保存文件路径，不备份或读取文件正文，也不扩展文件索引的读取范围。图片内容、文件承诺中尚未生成的内容，以及 concealed、transient、autogenerated 标记排除。默认排除密码管理器来源，并可在设置中选择其他应用排除；这些规则同样约束文件引用。暂停后不接收新项目；清空后删除本地密文记录。

后台钥匙串读取同时禁止 LAContext 和传统 macOS Keychain 的交互，传统接口的进程内交互状态在串行请求后恢复。访问失败时保留原密文并显示错误，新增记录只留在内存；设置中的「授权保存历史」是唯一请求交互授权的入口。该入口创建新的存储实例，只有成功读取原归档后才合并当前记录并恢复保存；拒绝授权或损坏归档都不能覆盖原文件。等待显式授权时退出应用不会同步等待系统安全对话框。

用户对文件历史项执行 ⌘C 时，将整组路径恢复为真正的文件 URL pasteboard 项，使用户回 Finder 按 ⌘V 能复制文件。Return 沿用直接粘贴流程：在用户明确选择粘贴后验证原目标应用仍在运行、窗口焦点与辅助功能权限，再发送 ⌘V；不会读取目标应用内容。权限或焦点等检查失败时只复制到系统剪贴板，并明确提示仅完成复制。无论使用 ⌘C 还是 Return，整组文件存在性校验都在专用后台队列执行，逐项检查取消状态；2 秒失败期限防止网络位置一直等待。后台系统调用不能强行中断，但超时或取消后的完成回调不能修改剪贴板。写入前重新检查查询代次、分类、选中条目的身份和内容，以及面板的显示、焦点与隐藏状态；修改查询、切换选中项、删除历史或关闭面板取消旧操作。任一路径失效时不替换当前剪贴板、不继续粘贴，并提示重新复制文件。路径移动或删除后无法从历史恢复文件。

默认全局快捷键为 ⌘Space，默认注册值来自 UserDefaults 注册域；已保存的 `hotKeyCode` 与 `hotKeyModifiers`（包括用户自定义值）会覆盖注册默认值。若默认 ⌘Space 注册失败，AppDelegate 会临时尝试注册旧快捷键 ⇧⌘F，并显示实际绑定状态；该回退不写入或覆盖保存的快捷键。设置页提供 Spotlight 系统快捷键入口、路径提示、重试及自定义录制。快捷键录制器的 Delete 重置为新的 ⌘Space。⌘0…⌘4 按应用层 `SearchScope.allCases` 顺序切换全部、应用、文件、设置、剪贴板范围；⌥⌘1…9 选择文件类型。Tab 在文件范围切换文件类型；数字快捷键按修饰键和面板上下文分发。

### 官网边界

Oil Find 是 MIT 许可证下的免费开源软件，搜索始终可用。应用不包含试用、付款、激活、设备身份或授权网络请求。启动时静默尽力删除旧版授权文件、偏好与试用钥匙串项，失败不影响使用。

`AppLanguage` 管理系统默认、简体中文和英文三种语言选择；语言偏好保存在 UserDefaults，`L10n.swift` 是应用界面文案的唯一来源。语言变化通知搜索面板、菜单、欢迎页、设置及更新窗口即时重新显示文案。

`site/` 是 Next.js App Router、React 和 TypeScript 官网，使用 pnpm 开发，运行时依赖只有 `next`、`react`、`react-dom`。中文首页为 `/`，英文首页为 `/en`；首页包含可交互的文件查询演示及搜索范围演示。演示数据必须是代码中定义的合成样例；不得访问访问者剪贴板、文件系统、输入历史或调用搜索引擎 API。网页搜索演示只在提交后导航到所选引擎。中文、英文页面均说明剪贴板默认关闭、加密存储和用户控制。更新日志位于 `/changelog` 与 `/en/changelog`。旧 `/activated`、`/recover` 及对应英文路径永久重定向到各自语言首页。官网没有付款或授权接口，本地开发不需要环境变量。

网站演示的固定样例数、状态和交互反馈不是应用索引内容，也不能被描述成真实设备上的性能测量。范围演示使用人工定义的文件、应用、设置和剪贴板样例；计算与换算显示示例结果，不在浏览器执行真实计算。网站输入期间不联网；只有用户提交网页搜索表单时才按所选引擎导航。项目的 macOS 部署目标不等于 macOS 14 或 15 实机验证；百万级索引和延迟描述只有在对应机器、索引、命令、样本及结果可复现时才可作为实测结论。

版本与 build 来自 `Resources/Info.plist`。`scripts/build-app.sh --debug` 打包的调试版提供 `--snapshot` 界面快照；正式版没有该入口。正式版在签名前移除包含本机源码路径的调试符号；调试版保留调试信息。`scripts/package.sh` 生成版本安装包、通用下载包与更新清单，不执行部署。

构建要求包含 macOS 15.4 及以上 SDK，运行部署目标仍为 macOS 14。CI 使用 macos-15 和显式 Xcode 16.4（SDK 15.5），同时检查 Release 编译、正式应用签名和 ZIP 解压后的产物。应用先在临时目录构建并验签，成功后替换旧产物；失败保留旧产物并清理临时目录。
