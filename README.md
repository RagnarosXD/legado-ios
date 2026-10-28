# Legado iOS

把 Android 阅读器 [LegadoTeam/legado](https://github.com/LegadoTeam/legado) 的核心能力移植到 iOS：SwiftUI + CoreData + SwiftSoup/Kanna/JavaScriptCore，无 macOS 也能用 GitHub Actions 云端编译出未签名 IPA。

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
| 阅读器（CoreText 分页、仿真翻页、自动翻页、主题、字号行距、进度、书签） | ✅ |
| 本地书籍（TXT / EPUB） | ✅ 基础可用（EPUB 为自实现解析，复杂排版可能降级） |
| 替换净化规则 | ✅ 引擎可用（正文链路已接入 `replaceRegex`） |
| TTS 朗读、WebDAV 同步、阅读统计 | ✅ 有实现，未做逐项回归 |
| RSS 订阅 | ⚠️ 列表与阅读有实现；`legado://import/rssSource` 深链导入仍是占位 |
| 漫画阅读 | ⚠️ 单页竖屏，实验性 |
| 云端/多设备同步（除 WebDAV） | ❌ 未实现 |

## 5. 构建

### 云端（无需 Mac）

推送到 `main` 或手动触发 `Actions → iOS CI → Run workflow`，完成后在 Artifacts 下载 `Legado-iOS-IPA`（`Legado-unsigned.ipa`），用 ESign / Feather / Sideloadly 自签安装。

构建失败时 workflow 会自动创建（或追加到）一个 Issue 并把 `error:` 行贴出来，方便定位。

### 本地（有 Mac）

```bash
xcodebuild -resolvePackageDependencies -project Legado.xcodeproj -scheme Legado
open Legado.xcodeproj    # ⌘R
```

真机需要把 `PRODUCT_BUNDLE_IDENTIFIER` 改成自己的，并选个人 Team 签名。

## 6. 已知差距（需要继续做）

- **书源变量持久化**：`java.put` / `@put` 只在单次解析内有效，未写回 `BookSource.variable`；依赖登录态变量的书源需要补这一层。
- **`loginCheckJs` / `jsLib`**：字段存在，尚未在 JS 上下文里预置。
- **`webJs` / `sourceRegex`**：正文规则里的这两个字段尚未执行。
- **单元测试未接线**：`Tests/Unit/*.swift` 是规则引擎的回归测试（覆盖 `class.` 语法、`##`、`||`、JSONPath 通配/递归、XPath、`java.*`），但 Xcode 工程里没有测试 target，CI 目前只验证「能编译 + 能打包」。接测试 target 是下一步。
- **RSS 深链导入**：仍是占位实现。
- **合规**：本项目不含任何书籍内容、不内置书源；请只导入你有权使用的内容。

## 7. 技术栈

- UI：SwiftUI + UIKit（阅读器）
- 架构：MVVM
- 持久化：CoreData
- 网络：URLSession（含 GBK/Big5 编码探测、WKWebView 兜底）
- HTML：SwiftSoup｜XPath：Kanna｜JS：JavaScriptCore｜ZIP：ZIPFoundation

## 8. 链接

- 原项目：[gedoor/legado](https://github.com/gedoor/legado) / [LegadoTeam/legado](https://github.com/LegadoTeam/legado)
- 帮助文档：<https://www.legado.top/>
- 书源规则教程：<https://mgz0227.github.io/The-tutorial-of-Legado/>

## 9. 免责声明

仅供学习交流，请勿用于商业用途；使用时请遵守当地法律法规并尊重版权。
