# Legado iOS

把 Android 阅读器 [LegadoTeam/legado](https://github.com/LegadoTeam/legado) 的核心能力移植到 iOS：SwiftUI + CoreData + SwiftSoup/Kanna/JavaScriptCore，无 macOS 也能用 GitHub Actions 云端编译出未签名 IPA。

[![iOS CI](https://github.com/RagnarosXD/legado-ios/actions/workflows/ios-ci.yml/badge.svg)](https://github.com/RagnarosXD/legado-ios/actions/workflows/ios-ci.yml)
[![Type Check](https://github.com/RagnarosXD/legado-ios/actions/workflows/typecheck.yml/badge.svg)](https://github.com/RagnarosXD/legado-ios/actions/workflows/typecheck.yml)

> 不是 Android 代码的逐行翻译，而是按 Legado 的数据模型与书源规则语义重写；书源 JSON 可直接导入，规则语法按 Legado 3.x 实现。

| 项 | 值 |
| --- | --- |
| 语言 / UI | Swift 5.9 + SwiftUI（阅读器翻页用 UIKit 承载） |
| 基线 | iOS 16.0+ |
| 依赖 | SwiftSoup（HTML）、Kanna（XPath）、ZIPFoundation（EPUB） |
| 持久化 | CoreData（Book / BookChapter / BookSource / Bookmark / BookGroup …） |
| 构建 | GitHub Actions（macos-14 + Xcode 15.4），产物为未签名 `.ipa` |

---

## 1. 与 Android 版的对应关系

| Android (Legado) | iOS (本仓库) |
| --- | --- |
| `BookSource` / `Book` / `BookChapter` / `Bookmark` | `Core/Persistence/*+CoreDataClass.swift` |
| `AnalyzeUrl`（搜索/发现 URL + `,{method,body,charset,headers}`） | `Core/Network/AnalyzeUrl.swift` |
| `AnalyzeRule` / `RuleAnalyzer` / `SourceRule` | `Core/RuleEngine/`（`RuleEngine`、`RuleSplitter`、`TemplateEngine`） |
| `JsExtensions`（`java.ajax` 等） | `Core/RuleEngine/JSBridge.swift` |
| `WebBook`（搜索→详情→目录→正文） | `Core/Model/WebBook.swift` |
| `ReadBook` / 分页与排版 | `Features/Reader/`（`PageSplitter` 用 CoreText 真实分页） |
| `BookSourceService` / `SearchService` | `Features/Source`、`Features/Search` |
| `ReplaceRule` | `Core/RuleEngine/ReplaceEngine.swift` |
| `ReadAloudService`（TTS） | `Core/Audio`、`Core/TTS` |
| WebDAV 备份 | `Core/Sync` |
| RSS 订阅 | `Features/RSS` |
| 书源/替换规则/备份导入导出 | `Core/Migration/DataMigrationManager.swift` |

## 2. 书源规则支持情况

规则引擎按「一条规则 = 选择器 + 属性 + 后处理」实现，字段规则、列表规则、正文规则走同一套求值：

| 语法 | 状态 | 说明 |
| --- | --- | --- |
| CSS 选择器 `div.book p` | ✅ | SwiftSoup |
| Legado 默认语法 `class.` `id.` `tag.` `text.` `children` | ✅ | 转成 CSS 后执行 |
| 属性 `@text` `@textNodes` `@html` `@outerHtml` `@href` `@src` `@abs:href` `@任意属性` | ✅ | 相对 URL 自动补全 |
| 级联 `div#list@tag.li`、索引 `class.item!0` / `!-1` | ✅ | 可多级 |
| XPath `//div[@class='book']` | ✅ | Kanna；文档以字符串形态提供 |
| JSONPath `$.a.b` `$.list[*].name` `$..name` `[0:2]` `[?(@.k=='v')]` | ✅ | `Core/RuleEngine/RuleSplitter.swift` 内 `JSONPathEvaluator` |
| 正则 `regex:` / `##正则##替换` / `##正则##替换##$1` | ✅ | 多个 `##` 段按 Legado 语义解析 |
| 组合 `&&`（拼接）、`\|\|`（取首个非空）、`%%`（格式化） | ✅ | |
| `@css:` `@xpath:` `@json:` `@js:` 前缀，`<js>` 块 | ✅ | |
| 模板 `{{key}}` `{{page}}` `{{$.path}}` `{{key,默认值}}` | ✅ | |
| 变量 `@put:{...}` / `@get:{...}` / `java.put` / `java.get` | ✅ | 同一次解析内共享；跨章节持久化见「已知差距」 |
| JS：`java.ajax` `getString` `getElements` `post` `ajaxAll` `base64Encode/Decode` `md5Encode/16` `encodeURI/decodeURI` `timeFormat` `htmlFormat` `toast` `log`，`source.*`，`cookie.get/set/remove` | ✅ | JavaScriptCore，同步桥接 |
| `ruleBookInfo.init` 预执行 | ✅ | 详情页先跑 init，再解字段 |
| 目录/正文翻页 `nextTocUrl` / `nextContentUrl` | ✅ | 带环检测与页数上限 |
| `loginCheckJs`、`jsLib`、`webJs`、书源级 `variable` 持久化 | ⚠️ 未接入 | 具体见下表 |

## 3. 本次提交修复的问题

之前版本引擎写得很全，但**字段规则没走引擎**，导致真实书源大面积失效。本次逐项修好：

1. **字段规则分派**（最关键）：`RuleEngine.getString` 原来只做「CSS + @attr」，现在统一走 `executeSingle`，`##` 净化、`@js:`、`@css:`、`@xpath:`、`@json:`、`&&`/`||`/`%%`、`@put/@get` 全部生效。
2. **作用域**：列表项解析出的元素现在能作为根继续求值字段规则（`scopedElement`），而不是每次都拿整篇文档查。
3. **Legado 默认语法**：新增 `LegadoSelector`，支持 `class.` / `id.` / `tag.` / `text.` / `children` / `@tag.` 级联 / `!index`。
4. **JSONPath**：新增 `JSONPathEvaluator`，支持通配、递归下降、切片、过滤器、数组根节点。
5. **XPath 修复**：原来要求 `document` 是字符串，实际传的是 `SwiftSoup.Document`，所有 XPath 书源必抛 `noDocument`；现在从 `htmlString` 取文档，并支持 `@attr`。
6. **正文段落**：`@text` 改为按块级标签换行（`HTMLTextExtractor`），正文不再被压成一行；正文规则命中多个节点时全部拼接。
7. **正文兜底**：正文规则为空时不再把章节 URL 当正文返回，改为抛错。
8. **JSBridge**：补齐 `java.post` / `ajaxAll` / `base64` / `md5` / `encodeURI` / `timeFormat` / `htmlFormat` / `getString(rule)` / `getElements(rule)`；给出 `undefined` 参数也不会崩（JS 包装层做类型兜底）。
9. **深链导入**：`legado://import/bookSource?json=...` 原来只写入 URL/名称/分组，规则被丢弃 → 导入的书源永远搜不到书；现在完整写入 `searchUrl`、`exploreUrl`、`header`、`ruleSearch`、`ruleExplore`、`ruleBookInfo`、`ruleToc`、`ruleContent`。
10. **详情页 init 规则**：`ruleBookInfo.init` 现在会在解字段前执行。

## 4. 功能状态

| 模块 | 状态 |
| --- | --- |
| 书架（网格/列表、分组、进度、排序、删除） | ✅ |
| 书源管理（导入/导出/订阅/启用禁用/调试器/二维码） | ✅ |
| 聚合搜索（多源并发） | ✅ |
| 书籍详情 / 目录 / 正文（含翻页与缓存） | ✅ |
| 阅读器（CoreText 分页与同源渲染、仿真/覆盖/滑动翻页、自动翻页、主题、书签） | ✅ |
| 排版精度（字距、首行缩进、行高倍数、段距、两端对齐） | ✅ 1.1 新增 |
| 本地书籍（TXT / EPUB / PDF / MOBI / AZW3 / HTML / Markdown / CBZ） | ✅ 1.1 起支持；UMD 暂不支持 |
| 替换净化规则 | ✅ 引擎可用（正文链路已接入 `replaceRegex`） |
| TTS 朗读、WebDAV 同步、阅读统计 | ✅ 有实现，未做逐项回归 |
| RSS 订阅 | ⚠️ 列表与阅读有实现；`legado://import/rssSource` 深链导入仍是占位 |
| 漫画阅读 | ⚠️ CBZ 按页纵向看图，实验性 |
| 云端/多设备同步（除 WebDAV） | ❌ 未实现 |

## 5. 1.2.0：书源管理与搜索重构

### 书源管理

- **按声明自动分类**：导入后按 `bookSourceType` 归入「文本 / 有声 / 漫画 / 文件」四个独立 Section，不混排，标题右侧显示数量
- **批量管理**（编辑模式）：多选 + 一键全选，支持批量启用、停用、**校验**、删除
- **批量校验**（对标 Android 版校验书源）：
  - 文本源：用 `checkKeyWord`（缺省「我的」）跑一次真实搜索，能解析出结果即算可用，耗时回写 `respondTime`
  - 有声 / 漫画 / 文件源：只校验站点可达（本版本不支持其阅读）
  - 并发执行（复用搜索并发数），实时显示 `已校验/总数` 进度
  - 结果明细：每源的可用性、耗时、失败原因（超时 / ATS 拦截 / 无结果 / 规则报错）
  - 支持「一键停用全部失败书源」

### 搜索

- **并发搜索**：并发数 1–8 可调（我的 → 搜索 → 搜索设置），默认 4；任务在主线程发起，网络请求并发，解析仍在主线程串行，既不跨线程碰 Core Data 又能把网络等待叠起来
- **进度条**：`已搜索书源数 / 书源总数` + 百分比，边搜边出结果
- **结果聚合**：书名与作者都相同视为同一本书，列表显示「源名 等 N 个源」，点开弹出书源选择（对标 Android 的换源入口）；只有一个源时直接加入书架
- 保留 90 秒总时限，超时后使用已完成的结果

## 5.1 1.1.4：按书源类型分流（崩溃根因）

书源 JSON 顶层有 `bookSourceType`：`0`=文本、`1`=音频（有声书）、`2`=图片（漫画）、`3`=文件。导入时已经落库（`URLSchemeHandler` / `SourceSubscriptionManager` / `SourceViewModel`），但**搜索链路只把它写进日志，没有拿它分流**——有声源、漫画源被当成文本源解析，这就是上个版本日志里崩在 `type=1` 源上的原因。

1.1.4 起：

- 搜索只跑 `bookSourceType == 0` 的源，其余直接跳过（不请求、不解析、不创建 JS 上下文）
- 日志记录 `跳过 N 个非文本书源（有声/漫画/图片）`
- 若启用的源全是非文本类型，提示「当前版本只支持电子书文本源」
- 书源选择器里给非文本源打上「有声 / 漫画 / 文件」标签并置灰，点击无效
- 书源管理列表沿用类型图标（🎧 / 🖼）

> `bookSourceGroup` 里的「🔊有声书源」只是分组标题，不能作为判据；`bookSourceType` 才是权威声明。若某源声明 `0` 但实际是有声/漫画站，仍可能出问题——下个版本会加「解析失败自动禁用该源」的兜底。

## 5.2 1.1.3：根据实测日志修复

你提供的 `app.log` 已经把范围缩小到解析阶段：

```
10:09:21.041 Search 书源开始 🔊Hi歌曲音乐网 type=1
10:09:23.462 HTTP status=200 bytes=25877 耗时=2420ms
10:09:25.237 App 启动 …            ← 中间没有 WebBook「搜索解析」，说明崩在解析里
```

同时日志暴露了两个非崩溃但致命的可用性问题：

| 现象 | 原因 | 1.1.3 处理 |
| --- | --- | --- |
| `http://…` 源全部 `-1022 ATS` 失败 | Info.plist 没有 ATS 例外 | 加 `NSAllowsArbitraryLoads` / `NSAllowsArbitraryLoadsInWebContent` |
| `搜索URL https://www.min-yuan.com/@js:` | `searchUrl` 整条是规则时没执行 | 支持 `@js:` / `<js>` / `{{…}}` 形式的 searchUrl，先算出真实地址 |
| 835 个源串行搜索极慢 | 无超时上限，请求 30s 超时 | 请求超时降到 12s，整体 90s 上限 |
| 崩在哪条规则看不出来 | 日志太粗 | `bookList` 规则、元素个数、每个字段的规则与失败原因全部记录 |

解析侧加固：

- **XPath 预检**：括号/引号不配平、超长表达式直接判为非法并抛错，不再交给 libxml2（非法 XPath 可能直接崩）
- **JSONPath 递归深度上限 64**：`$..` 遇到畸形/超深结构不会把栈打爆
- **字段级隔离**：单个字段解析失败只记日志并返回空串，不再整源失败
- **上次崩溃栈并入 app.log**：下次启动时把 `crash-*.log` 的调用栈写进主日志，导出一次就够

## 5.3 1.1.2 更新：日志版 + 精简入口 + 版本化产物

### 1) 闪退日志（重点）

装上新版本后如果仍然闪退，按下面步骤取日志发我即可定位：

1. 闪退后重新打开 App（不要先杀进程）
2. 设置 → 诊断 → **导出运行日志** → 存到「文件」或直接发微信/AirDrop
3. 崩溃当次的记录在 `crash-*.log` 里，运行轨迹在 `app.log` 里

日志内容包含：App 版本、系统版本、崩溃类型（NSException / 信号）、调用栈、崩溃前 200 条运行日志（搜索关键词、每个书源的 URL / HTTP 状态 / 响应长度 / 耗时 / 解析条数 / 失败原因）。

实现：`Core/Logging/AppLogger.swift`（滚动日志，单文件 2MB 保留 3 份）+ `Core/Logging/CrashReporter.swift`（`NSSetUncaughtExceptionHandler` + `SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGFPE`）。

### 2) 移除「发现」和「RSS 订阅」

- 首页 Tab 从 4 个减少为 2 个：书架 / 我的
- 删除 `Features/Discovery/DiscoveryView.swift`、`Features/RSS/RSSSubscriptionView.swift`、`RssSourceEditView.swift`、`RssFavoritesView.swift`，以及旧的 `Legado/ContentView.swift`
- RSS 数据表与 `legado://import/rssSource` 深链保留（避免旧数据异常），但没有界面入口

### 3) 产物命名与版本同步

- Release 产物：`Legado-1.1.2.ipa`（文件名以版本号结尾）
- Artifact：`Legado-iOS-IPA-1.1.2`、`Legado-iOS-App-1.1.2`、`Legado-xcresult-1.1.2`
- 打包时用 tag 名覆盖 `CFBundleShortVersionString`，`CFBundleVersion` 用 CI 构建号，**IPA 内版本与 Release 标签一致**

## 5.4 1.1.1 修复：搜索闪退

**现象**：订阅一批书源后，一搜索就闪退。

**根因**：`ExecutionContext.jsContext` 里写的是 `let context = JSContext()!`。`JSContext()` 是可失败初始化器，在多书源并发搜索、首次创建 JS VM 时可能返回 `nil`，强解包必崩。而订阅来的书源普遍带 `@js:` / `<js>` 规则，所以「只有订阅后才会崩」。

**修复**：

- `JSContext` 改为可选创建：全局锁串行化 + 失败重试 3 次 + 失败时抛 `RuleError.executionFailed`，不再崩溃
- 搜索从 `withTaskGroup` 并发改为串行：书源是 Core Data 对象、规则解析会创建 JavaScriptCore 上下文，两者都不允许被并发触碰
- 结果改为边搜边显示；单个源失败不再中断整体搜索，失败原因会带上源名显示出来
- 顺带修掉 `WebBook` 里两处 `body.data(using: .utf8)!` 强解包

## 5.5 1.1 更新：本地格式 + 排版精度

### 本地书籍格式

| 格式 | 说明 |
| --- | --- |
| TXT | 自动识别 UTF-8 / UTF-16 / GB18030 / Big5；分章支持 `第X章/回/节/卷`、`Chapter N`、序章/楔子/番外；识别不到标题时按长度切块 |
| EPUB | 复用自实现 `EPUBParser`（OPF + spine + 目录 + 封面） |
| PDF | PDFKit 逐页抽取文字，每 8 页一章，首页渲染封面；扫描版（无文字层）会明确提示不支持 OCR |
| MOBI / AZW3 | 自解析 PalmDB + MOBI Header + EXTH（书名/作者），PalmDOC 解压；HUFF/CDIC 压缩提示转 EPUB |
| HTML / XHTML | 按 h1~h3 分章，标签清洗后保留段落换行 |
| Markdown | 按 `#` 标题分章，去掉强调/链接/列表标记 |
| CBZ | 自实现 zip（stored + deflate）解压到 `Documents/Manga/`，按页图片纵向阅读 |

导入时每章正文会落盘到 `Documents/LocalChapters/<bookId>/`，翻页直接读缓存，不再每次重新解析整本。

### 排版精度

之前分页用 CoreText、显示却用 SwiftUI `Text`，两边行高/段距算法不同，导致「分页边界」和「屏幕显示」对不上，字距、首行缩进、段距设置也基本不生效。1.1 把两者统一：

- 分页与渲染共用同一份 `NSAttributedString`（`PageSplitter.attributedText`），正文改为 CoreText 直绘（`PageTextView`）
- 新增排版项：字距（kern）、首行缩进（0–4 字）、行高倍数（0.8–2.0）、两端对齐
- 行末断行策略改为 `pushOut`（允许标点挤压，中文行尾更整齐）
- 滚动模式把行高倍数折算成行距，保持与分页模式视觉一致

## 6. 构建

### 云端（无需 Mac）

推送到 `main` 或手动触发 `Actions → iOS CI → Run workflow`，完成后在 Artifacts 下载 `Legado-iOS-IPA`（`Legado-unsigned.ipa`），用 ESign / Feather / Sideloadly 自签安装。

构建失败时，`error:` 行会以 **annotation** 形式贴在运行页面（不需要登录也能看），同时日志末尾 80 行会打印在 Build 之后的步骤里。

> macOS runner 有时会因容量不足直接报 `The job was not acquired by Runner`，这是 GitHub 侧排队失败，与代码无关，重新触发即可。

### 本地（有 Mac）

```bash
xcodebuild -resolvePackageDependencies -project Legado.xcodeproj -scheme Legado
open Legado.xcodeproj    # ⌘R
```

真机需要把 `PRODUCT_BUNDLE_IDENTIFIER` 改成自己的，并选个人 Team 签名。

### 没有 Mac 时怎么验证规则引擎

`Type Check` workflow 用 Linux 上的 Swift 编译器做两件事，1 分钟内出结果：

1. `swiftc -typecheck` 检查纯 Foundation 的 `LegadoSelector` / `JSONPathEvaluator` / `HTMLTextExtractor`；
2. 用**真实 SwiftSoup** + JavaScriptCore/Kanna/CryptoKit 的桩，编译 `RuleEngine.swift`、`RuleSplitter.swift`、`TemplateEngine.swift`、`JSBridge.swift`；
3. `LocalBookParser.swift`（TXT/HTML/Markdown 分章与编码识别）也会一起编译，EPUB/PDF/MOBI/CBZ 用桩顶替。

本地还可以跑括号/字符串配平自检：

```bash
python tools/check_swift_balance.py Core
```

## 7. 已知差距（需要继续做）

- **书源变量持久化**：`java.put` / `@put` 只在单次解析内有效，未写回 `BookSource.variable`；依赖登录态变量的书源需要补这一层。
- **`loginCheckJs` / `jsLib`**：字段存在，尚未在 JS 上下文里预置。
- **`webJs` / `sourceRegex`**：正文规则里的这两个字段尚未执行。
- **单元测试未接线**：`Tests/Unit/RuleEngineTests.swift` 是规则引擎回归测试（覆盖 `class.` 语法、`##`、`||`、JSONPath 通配/递归、XPath、`java.*`），但 Xcode 工程里没有测试 target，该文件不参与编译；目前靠 `Type Check` workflow 做类型检查、靠 `tools/check_swift_balance.py` 做结构自检。把它接成真正的测试 target 是下一步。
- **RSS 深链导入**：仍是占位实现。
- **UMD**：仅有格式识别，解析未实现（会提示先转成 TXT/EPUB）。
- **PDF 扫描版**：无文字层时无法提取正文，未做 OCR。
- **CBZ 漫画**：按页纵向阅读，暂无双页/左右翻页/预加载。
- **合规**：本项目不含任何书籍内容、不内置书源；请只导入你有权使用的内容。

## 8. 技术栈

- UI：SwiftUI + UIKit（阅读器）
- 架构：MVVM
- 持久化：CoreData
- 网络：URLSession（含 GBK/Big5 编码探测、WKWebView 兜底）
- HTML：SwiftSoup｜XPath：Kanna｜JS：JavaScriptCore｜ZIP：ZIPFoundation

## 9. 链接

- 原项目：[gedoor/legado](https://github.com/gedoor/legado) / [LegadoTeam/legado](https://github.com/LegadoTeam/legado)
- 帮助文档：<https://www.legado.top/>
- 书源规则教程：<https://mgz0227.github.io/The-tutorial-of-Legado/>

## 10. 免责声明

仅供学习交流，请勿用于商业用途；使用时请遵守当地法律法规并尊重版权。
