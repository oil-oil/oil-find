# Oil Find 架构

## 目标

| 维度 | 要求 |
| --- | --- |
| 覆盖 | 默认索引启动卷上的个人文件与应用；依赖目录、包内部、`~/Library`、系统目录可在设置里打开，全开即整盘；核心也支持独立的本地卷索引与离线目录，由可选扩展提供来源 |
| 速度 | 单来源：3 个字符以上的查询在 1000 万条目上 p95 ≤ 30 ms，单字符 ≤ 80 ms；多来源：85 万 + 两份各 100 万条目时，3 字符以上 p95 ≤ 15 ms，单字符 ≤ 80 ms（验收目标） |
| 实时 | 在线来源的文件新增、删除、改名、移动在 1 秒内反映到索引；卷退出前取消扫描与监听，离线来源保留最后目录 |
| 启动 | 启动盘已有索引加载 ≤ 1.5 秒，随后用 FSEvents 历史补齐变动；其他来源在后台载入，不阻塞搜索面板 |
| 内存 | 平均每条目 ≤ 70 字节（含哈希表） |
| 交互 | ⇧⌘F 唤起，面板在屏幕正中，键盘即可完成全部操作 |

免费核心提供文件名与路径搜索。可选私有扩展的产品能力由其独立仓库定义。

### 不做的事

不索引网络卷，不做沙盒化上架或图片内容识别。公开核心不负责外置卷发现、产品开关或功能可用状态；磁盘映像只在调试和测试中作为卷索引验证对象。

## 工程结构

```
oil-find/
  Package.swift
  Sources/
    COilFind/                 C：SIMD 子串扫描、目录批量读取、名称比较
      include/coilfind.h
      coilfind.c
    OilFindCore/              Swift：索引与搜索引擎，不依赖 AppKit
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
    OilFindApp/               应用库：AppKit、语言管理、SwiftUI 设置与中性扩展点
    OilFind/main.swift        可执行应用的组装入口
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

`Package.swift`：`swift-tools-version:5.10`，`platforms: [.macOS(.v14)]`。公开 target 为 `COilFind`、`OilFindCore`、`OilFindApp`（library）、`OilFind`（executable）与 `oilfind-cli`，另有核心与应用界面两个测试 target；应用界面测试依赖 `OilFindApp`。应用 bundle id 为 `com.oiloil.find`。

## 开放核心与应用扩展

`Pro/` 是可选的独立私有仓库，不在本公开仓库内，公开 Git 通过 `/Pro/` 忽略它。manifest 用 `Context.packageDirectory` 检测私有模块目录，并通过 `Context.environment` 读取 `OILFIND_FREE=1`，决定是否加入私有 target 与其测试。没有私有模块或显式设置该变量时构建免费版；免费目标的编译标记防止旧构建缓存中的模块影响条件导入。

依赖方向是私有扩展依赖公开应用库与核心。公开库不得依赖或引用私有模块；只有 `Package.swift` 与 `Sources/OilFind/main.swift` 可以提及私有 target。入口只导入模块并调用 `Application.run`，根据构建条件传入可选扩展。

`ApplicationExtension` 提供启动、退出、设置分区、URL、语言及额外搜索来源接口；`searchSources()` 返回来源快照，`onSearchSourcesChange` 通知来源增减、上下线与索引变动。DEBUG 下另有参数预处理方法，让扩展解析并移除自己的调试参数。应用库不理解私有功能状态。扩展设置分区放在「索引范围」之后、「排除的文件夹」之前；语言变化即时传递，URL 交给扩展处理，无扩展时无操作。扩展只在主线程提交来源快照，功能状态判断不进入扫描或搜索热路径。

免费版验证使用 `OILFIND_FREE=1 swift build` 与按需筛选的 `swift test`。`Tests/Scripts/test_open_core.py` 检查公开 Git 未追踪 Pro 文件、代码中的私有 target 名称只出现在 manifest 和组装入口，并在 CI 执行。

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

## 多来源与任意卷索引

`SearchSource` 以稳定的 `id` 标识来源，携带显示名、在线状态和 store。`SearchHit` 保存来源下标与条目下标，另有可选的命中原因字段；条目下标只在对应 store 内有效。`MultiSearchResult` 强引用所有来源及各来源的 `SearchResult`。各来源并行执行原搜索器，各自保留结果缓存和完整的增量收窄候选；合并在读锁内比较分数、名称字节、时间或大小，平分时按来源顺序与条目下标决定顺序。只有启动盘时，应用直接执行原 `Searcher` 和缓存路径。

应用提交查询、来源快照、结果和统计时使用同一查询代次。来源更新使过期查询失效；选择通过来源 ID 和 store 内下标保持，store 替换时才按原路径解析。离线行名称变淡、路径标注未连接；打开、Finder 定位和预览提示来源未连接，复制仍可用，拖动和移到废纸篓禁用。操作开始前再次核对实时来源，避免旧结果执行到刚拔掉的卷。

`IndexManager` 的可选 `volumeUUID` 使配置指纹与卷身份绑定，不因挂载路径变化作废；载入时重设 store 根路径。每个来源使用独立的本机索引文件，`startOffline()` 只后台载入目录，不启动扫描或 FSEvents。在线卷使用 `FSEventStreamCreateRelativeToDevice`，将设备相对事件路径还原到当前挂载点，并兼容本机回调返回的绝对挂载路径；保存该设备的事件位置与日志 UUID。日志 UUID 不同、游标超出设备历史或日志不可用时重新扫描；事件丢失和根变化也触发恢复扫描。没有历史日志时先启动实时流，再扫描，并将扫描期间的事件缓冲后补齐，避免慢盘扫描漏掉变动。扫描器与事件子树更新器都支持取消，文件描述符关闭与系统调用同步，避免句柄重用竞态。卷发现与推出前通知由扩展实现，核心只负责取消、停止和保存。

## 查询语法与诊断

空格是 AND，`|` 是同一子句里的 OR，OR 两侧可以有空白；不支持括号布尔表达式。含 `/` 的词按路径组件匹配，可组合名称、操作符。`src/` 匹配目录后代，`/src/main` 匹配 src 下以 main 开头的条目。

输入先执行粘贴归一化（去整体引号、file URL 百分号解码、Shell 转义、扩展名后的行列后缀）。含空格的整段路径只在实际存在时作为一个路径词：先查当前索引，未命中时在读锁外最多 stat 一次；不存在时按空格分词。`Query.raw` 是归一化文本。

`!词` 排除文件名包含该词的条目，以及任意上级文件夹名称与该词完全相同（不区分大小写）的条目；上级检查在正向条件通过后执行，使用字节与 parent 链，不创建 String 或逐项分配。单名称保持原有 C 批量评分；名称加 ASCII 名称否定也批量评分，再只检查匹配候选的否定条件。`!path:词` 仍按路径包含匹配，`!src/` 按路径组件排除；拼音匹配用于名称，上级名称按实际名称精确比较。`file:词` / `folder:词` 正向单原子展开为名称 AND 类型筛选，OR 和取反时保持组合原子。

类型为 folder、app、doc、image、video、audio、code、archive；CLI 的 `--kind` 还接受 0…8，非法值报错并非零退出。其余语法：双引号、`*` / `?`、`ext:`、`file:`、`folder:`、`size:`、`dm:`、`path:`、`case:`、`regex:`，见 README。

解析返回可执行 Query 与结构化诊断。无效 regex、kind、size、dm 原子不阻断其他条件；仅无效条件时保留不可匹配的名称条件，不显示最近文件。编辑器通过 UTF-16 光标范围和组字状态延迟诊断，光标仍在词内（含词末）或组字时不报告。诊断、结果与当前查询一起提交；无结果时显示诊断空状态，有结果时底栏显示第一条诊断。⌘/ 打开/关闭语法速查，Esc 先关闭速查；内容与官网语法表逐字一致。

## 未覆盖统计

扫描与增量更新按权限（EPERM/EACCES）、四个范围开关、用户排除、SF_DATALESS 云端目录、/Volumes 下真实挂载点聚合。统计单位是实际遇到的被跳过入口，不枚举其后代；增量更新累加观察次数，重扫重置。每类最多 5 个不同示例，满额后只增加计数，路径不写日志。受限配置的额外权限排除归入没有权限。范围排除以配置检查优先匹配的原因计一次；包自身保持可搜索，其未深入内部计作包入口。

统计归属 IndexStore，跟随扫描替换、压实与版本保存；索引格式 3 在原数组后附加有长度上限的统计 JSON，兼容读取格式 2（统计为空），只保留一份索引。设置只展示非零行，范围行展开后按开关显示示例；卷统计按当前挂载点刷新，排除在线且已有索引的来源根路径，不改写 store 中的统计。单路径检查优先交给在线来源的中性 `SearchSource.explain(path:)` 回调，限定在该来源根路径内并使用自身索引配置；其余路径由启动卷解释，未接入的外置磁盘和网络卷归为不在索引范围内。磁盘检查在索引锁外执行。

## 更新

发布说明唯一来源为 `site/content/releases.ts`，版本倒序排列，官网 `/changelog` 与 `/en/changelog` 直接读取。`scripts/package.sh` 必须使用已有的「Oil Find Self-Signed」证书签名，从 zip 的实际大小、SHA-256 与当前发布说明生成 `site/public/updates/latest.json`；缺少说明或证书时失败。清单为静态 HTTPS 资源，`Cache-Control: no-cache`，zip 沿用下载目录缓存。应用不使用 Apple Developer ID、Sparkle 或第三方更新包。

`OilFindCore/Update` 提供语义版本、清单、偏好、网络、安装与重启类型。版本遵守 SemVer，预发布版本低于正式版，忽略版本元数据；仅语义版本相同时比较 build。最低系统要求高于当前系统时不提示。`automaticUpdates` 默认为 true；启动 30 秒后检查一次，随后每 24 小时检查。`skippedUpdateVersion` 仅阻止该版本的自动提示，不影响手动检查。网络失败自动检查静默，手动检查报告原因。

版本检查只有一个 GET 请求，使用临时 URLSession，禁用缓存、cookie 和凭证，不携带设备标识、语言或本机路径；User-Agent 为 `OilFind/<版本>`。正式应用清单地址固定为 `https://find.oiloil.org/updates/latest.json`，仅接受 HTTPS 下载与清单同一主机的 zip，不跟随重定向。调试版不执行更新检查；快照与临时目录端到端演练入口仅在 DEBUG 编译，正式版没有清单地址覆盖入口。

用户确认安装后，URLSession 下载到临时目录并报告进度；流式校验大小与 SHA-256。在当前应用旁建立同卷、0700 权限的临时工作目录，检查压缩包路径与符号链接后用 `ditto -x -k` 解压。Security 从 `SecCodeCopySelf` 取得当前运行代码，再取得其 designated requirement；新包必须签名有效且满足该要求（同一 bundle id 与证书 leaf 哈希），Info.plist 的 bundle id 必须为 `com.oiloil.find`，版本高于当前并与清单一致。

安装先记录收据，移动当前应用到工作目录的 `previous.app`，再把新应用移到原位置。第二次移动失败立即还原备份；如果还原本身发生文件系统错误，则保留备份，不删除工作目录。当前应用或所在目录不可写时停止，不尝试提权。文件操作与签名校验通过协议注入，所有校验发生在替换之前。

替换后启动分离的等待进程，以位置参数传入路径，等待当前进程退出再用 `open -n -W` 打开原位置的新应用；当前进程正常退出时仍执行索引保存。新进程尽早记录 PID，启动完成后按匹配目标路径、版本和 build 的收据写入独立的 `launch-confirmed` 标记，等待进程收到确认后删除备份与临时目录。清理失败不影响已确认启动的新应用，下次启动再清理。等待进程启动失败时应用还原旧包；`open` 失败、新进程提前退出或 60 秒内没有启动确认时，等待进程停止未完成启动的新进程，还原并重开旧包。旧包按失败标记显示原因并清理临时目录。下载与校验失败清理临时文件，替换失败保留可用应用与必要备份。

`UpdateManager` 在主线程拥有检查、可更新、下载、安装、最新和失败状态；网络与安装不阻塞界面，重复操作在处理中禁用。下载与安装期间禁止提前退出，启动等待进程后才允许正常退出；下载文件在退出前显式清理，不依赖异步任务的 defer。菜单显示可用版本与下载进度，更新窗口复用同一状态，设置通用区域提供自动检查开关、提示、手动检查和当前版本。双语界面文案集中在 `Sources/OilFindApp/L10n.swift`。


## 应用与官网

Oil Find 的公开核心与应用库使用 MIT 许可证，免费搜索始终可用。公开应用库不包含私有产品状态、设备身份或授权网络请求，可选功能通过 ApplicationExtension 接入。旧版授权清理启动时静默尽力执行一次，失败不影响免费功能。

`AppLanguage` 管理系统默认、简体中文和英文三种语言选择；语言偏好保存在 UserDefaults，`Sources/OilFindApp/L10n.swift` 是免费应用界面文案的唯一来源。语言变化通知搜索面板、菜单、欢迎页、设置及更新窗口即时重新显示文案。

`site/` 是 Next.js App Router、React 和 TypeScript 官网，使用 pnpm 开发，运行时依赖为 `next`、`react`、`react-dom`、`stripe`；Stripe SDK 用于官网授权接口。npm 与 pnpm 锁文件保持一致。中文首页为 `/`，英文首页为 `/en`，更新日志位于 `/changelog` 与 `/en/changelog`。官网的授权相关页面与接口由官网任务维护，公开应用库不依赖其内部实现。

版本与 build 来自 `Resources/Info.plist`。`scripts/build-app.sh --debug` 打包的调试版提供 `--snapshot` 界面快照；正式版没有该入口。正式版在签名前移除包含本机源码路径的调试符号；调试版保留调试信息。`scripts/package.sh` 生成版本安装包、通用下载包与更新清单，不执行部署。
