# Legado iOS 2.0 移植计划（以 Android 为唯一规范）

> 原则：**能照搬语义就照搬，不能照搬（语言/运行时不同）才重写，且必须记录差异原因。**
> Android 基线：`LegadoTeam/legado` master（本地对照副本 `legado_kt/`）。

## 一、分期

| 阶段 | 范围 | 对应 Android | 验收 |
| --- | --- | --- | --- |
| **P1 规则引擎** | 规则切分、取值/取列表分派、URL 构建、`java.*` 桥 | `AnalyzeRule.kt`、`RuleAnalyzer.kt`、`AnalyzeUrl.kt`、`AnalyzeByXPath/CSS/JSoup/JSonPath.kt`、`JsExtensions.kt` | 移植 Android 单测；你提供的失败源全部通过 |
| **P2 阅读器** | 排版、分页、翻页、菜单、目录、朗读入口 | `ui/book/read/ReadView.kt`、`ContentTextView.kt`、`PageFactory.kt`、`ReadConfig.kt`、`TextChapterLayout.kt` | 同屏字数/行距/边距与 Android 默认值一致 |
| **P3 书架/详情/搜索/书源** | 列表交互、分组、批量、换源、进度 | `ui/main/bookshelf/*`、`ui/book/*`、`ui/book/source/*`、`ui/main/search/*` | 功能点逐条对照勾选 |
| **P4 外围** | 缓存、WebDAV、TTS、统计、导入导出 | `service/*`、`ui/config/*` | 逐条对照 |

每个阶段产出：`docs/porting/Pn-*.md` 差异清单（Android 行为 / 当前实现 / 处理方式 / 是否重写）。

## 二、P1 已确认差异（基于源码阅读，逐条修）

| # | Android 行为 | 当前实现 | 状态 |
| --- | --- | --- | --- |
| 1 | 规则以 `/` 开头**一律**按 XPath 解析（不只 `//`） | 只认 `//` | ✅ 已修（1.3.5） |
| 2 | `@@` 前缀 = 转义，后续按默认（CSS）解析 | 未实现 | ✅ 已修（1.3.5） |
| 3 | `$.` / `$[` 开头都按 JSONPath | 只认 `$.` | ✅ 已修（1.3.5） |
| 4 | `getString` 结果默认做 HTML 实体反转义（`unescape=true`） | 字段未反转义 | ✅ 已修（1.3.5，正文除外） |
| 5 | `isUrl=true` 时：结果为空返回 `baseUrl`，否则相对地址绝对化 | 字段层各自处理，不统一 | ⬜ 待办 |
| 6 | `@put` 在规则切分前抽取并写回变量 | 已实现，但顺序需核对 | ⬜ 待核对 |
| 7 | `{{...}}` / `@get` 走 `makeUpRule` 参数替换（不是"或"语义） | 自己实现的模板替换 | ⬜ 待核对 |
| 8 | `-` 前缀反转列表、`!index` 取下标 | 已实现 | ✅ |
| 9 | `##` 正则替换（含 `##pattern##replacement`、`$1`） | 已实现 | ✅ 待补 `replaceFirst` |
| 10 | `@js:` / `<js>` / `{{js}}` 统一走 Rhino | 走 JavaScriptCore，API 面需对齐 | ⬜ 待补（`java.*` 全量） |

## 三、已知需要重写而非照搬的部分

| 能力 | Android | iOS 重写原因 |
| --- | --- | --- |
| JS 引擎 | Rhino | 系统仅提供 JavaScriptCore；需在 JSBridge 补齐 `java.*` 语义 |
| HTML 解析 | jsoup | SwiftSoup，选择器支持范围不同，需在 `LegadoSelector` 里做语法转换 |
| 网络 | OkHttp | URLSession，需自行实现 cookie/重试/编码探测 |
| 本地书解析 | 自研 + 第三方库 | PDFKit / 自研 PalmDOC / zip，格式覆盖面需逐项对齐 |

## 四、版本策略

- 重构期间保持 `1.3.x` 递增，**P1~P4 全部完成且验收通过后**升级到 `2.0`。
- 每个 P 阶段完成打一次 tag，便于回滚对比。

## 五、P1 第二批（1.3.6）已完成

基于 `AnalyzeRule.kt` / `AnalyzeByJSoup.kt` / `BookList.kt` / `BookChapterList.kt` / `BookInfo.kt` 精读结果：

| # | Android 行为 | 位置 | iOS 改动 |
| --- | --- | --- | --- |
| 1 | `getSearchRule()/getTocRule()/getContentRule()/getBookInfoRule()` 永不为 null，缺失返回空对象 | BookSource.kt:122-155 | `WebBook` 4 处 `guard let … else throw` 改为 `?? BookSource.XxxRule()`；规则结构体字段补 `= nil` 默认值 |
| 2 | 列表项只要求 `name` 非空（`bookUrl` 可空） | BookList.kt:187,222 | `parseBookList` 保留条件从 `name && bookUrl` 改为仅 `name` |
| 3 | 章节 `chapterUrl` 为空时回落 `baseUrl`；仅 `title` 为空才丢弃 | BookChapterList.kt:262-277 | 首屏与 nextToc 两处改为「title 空跳过；链接空 → redirectUrl」；仅过滤 `javascript:`/`about:`/`#` |
| 4 | `@html` = 删除 script/style 后的 **outerHtml** | AnalyzeByJSoup.kt:255-262 | `CSSParser` 拆出 `html`（outerHtml+stripScripts）与 `innerhtml`（innerHtml） |
| 5 | BookInfo 的书名/作者仅在原值为空或 `canReName` 为真时覆盖 | BookInfo.kt:68-81 | 加 `canRename` 判断；`tocUrl` 解析为空回落详情页地址 |
| 6 | 规则结构缺字段：`TocRule.isVolume/formatJs/preUpdateJs`、`ContentRule.subContent/callBackJs`、`BookInfoRule.kind/canReName` | rule/*.kt | 补齐字段（解码兼容，暂未消费的标 TODO） |

### P1 剩余（下一轮）

1. `isUrl=true` 统一语义（空 → baseUrl，非空 → `getAbsoluteURL(redirectUrl)`）
2. `@put` 抽取时机、`{{n}}`/`@get` 的 `makeUpRule` 参数替换（不是"或"语义）
3. `AnalyzeByJSoup` 的 `[]` 索引语法族（`[-1]`、`[0:2:1]`、`[!..]`、`[-1:0]` 反转、`tag.div.-1`）
4. `text.` = 自有文本包含匹配（当前误当 CSS 标签）
5. `@ownText` / `@textNodes` 的 trim 与去空语义
6. XPath 元素保持节点身份（当前转 HTML 字符串二次解析）
7. `AnalyzeUrl.analyzeJs()`（`<js>`/`@js:`/`@result`）与 `{{...}}` 的 JS 表达式语义
8. `java.*` 桥全量对齐 `JsExtensions.kt`