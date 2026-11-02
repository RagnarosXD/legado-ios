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
## 六、P1 完成状态（截至 1.3.9）

### 已完成（按 Android 语义对齐）

| 类别 | 项目 |
| --- | --- |
| 规则切分 | `:` → Regex（allInOne）、`<js>`/`@js:` 切段、`@@` 转义、`@css:`/`@xpath:`/`@json:` 前缀、`/` 开头 XPath、`$.`/`$[` JSONPath、省略 `$.` 的路径 |
| 取值 | `@html`（去 script/style 的 outerHtml）、`@innerhtml`、`@textNodes`（trim+去空）、`@ownText`、`@text`（保留段落）、`@href/@src`（绝对化 + data-* 回退）、字段结果 HTML 实体反转义 |
| 索引 | `.N`（选择）、`!N`（排除）、`!0,2` 多值、负数倒数、`[a]`、`[a:b]`、`[a:b:c]`、`[-1:0]` 反转、越界裁剪、规则首 `-` 反转 |
| 简写 | `class.` / `id.` / `tag.` / `children` / `text.`（自有文本包含）、`@tag.`/`@class.` 级联、空前置规则 → children |
| 变量与参数 | `@put:{...}` 任意位置抽取（括号配平）、`{{n}}` 列表索引、`@get:key`、`{{表达式}}` JS 求值（page/key/baseUrl）、变量表跨规则共享 |
| URL | `<1,2,3>` 页数规则、`{{...}}` JS 表达式、相对地址按最终响应 URL 补全、`javascript:` 过滤、`##` 残留清洗、`&amp;` 解码 |
| 兜底 | 规则对象永不为 null（空对象）、列表只要求书名、`bookUrl`/章节链接为空回落 baseUrl、`tocUrl` 空回落详情页、BookInfo 覆盖策略、封面相对地址补全 |
| JS 桥 | `java.ajax/connect/ajaxAll/post/getString/getElements/put/get/log/base64/md5/decodeURI/encodeURI/timeFormat/htmlFormat/toast/longToast` |

验证：`Type Check`（Linux + 真实 SwiftSoup + JSC 桩）全绿。

### P1 遗留（不阻塞 P2，按需补）

| 项 | 影响 | 计划 |
| --- | --- | --- |
| XPath 元素身份（当前转 HTML 二次解析） | 表格类结构可能变形 | P2 后按样本处理 |
| `java.webView/startBrowser/downloadFile/cookie/cacheFile/aes/des/digest` | 少数源依赖 | 按失败源逐个补 |
| `setLocal` 语义 | Android 源码未在本轮核实 | 核实后再实现 |
| `@regex` 的 replaceFirst 细节 | 少量源 | P1.1 |

## 七、P1 收尾（1.3.10）

### 新增对齐项

| 项 | Android 依据 | 实现 |
| --- | --- | --- |
| `##` 全量替换 / `###` 只替换首个 | `AnalyzeRule.kt:541-566` | `parseReplace` 识别 `###`，`applyReplace` 的 `replaceFirstMatch` 取首个匹配整段替换；无匹配返回空串 |
| XPath 节点身份 | `AnalyzeByXPath.kt:17-50` | `ElementContext.xpathNode` 保留 Kanna 节点；纯取值规则直接读节点，不再 `toHTML` 二次解析；属性/文本节点不再因 `toHTML == nil` 被丢弃 |
| `@xpath:` 列表统一入口 | 同上 | `getHtmlElements` 的 XPath 分支改为复用 `getXPathElements` |
| `java.setLocal` | `AnalyzeRule.kt` setLocal | 写入当前规则链 `variables`，不持久化 |
| `java.hexEncodeToString / hexDecodeToString / strToBytes / bytesToStr` | `JsEncodeUtils` | 新增 |
| `java.digestHex / digestBase64Str / HMacHex / HMacBase64` | `JsEncodeUtils` | CryptoKit（SHA1/256/384/512）+ CommonCrypto 兜底（MD5/SHA1） |
| `java.aes* / des* / tripleDES*` | `JsEncodeUtils` | CommonCrypto：AES/DES/3DES，ECB/CBC + PKCS7，hex 或 Base64 输入输出 |
| `java.timeFormatUTC / toNumChapter / randomUUID / logType / getCookie` | `JsExtensions` | 新增 |
| `java.readTxtFile / writeTxtFile / deleteFile` | `JsExtensions` 文件能力 | `FileSandbox`（限定 Documents、防目录穿越） |
| `java.getStringList / getElement` | `AnalyzeRule` | JS 包装复用 `__getElements` |
| `java.log` 返回入参 | `JsExtensions` | 包装后 `return msg`，支持链式 |

### P1 判定

规则引擎部分（切分、取值、索引、变量、URL、兜底、JS 桥高频 API）已按 Android 语义对齐，`Type Check` 通过。

仍属「未实现但已知」的能力（不阻塞 P2，按失败源补）：

- `java.webView / webViewGetSource / startBrowser / showBrowser`（需要 WKWebView 后台加载）
- `java.downloadFile / cacheFile / importScript / 解压系列`
- `java.queryTTF / replaceFont`（字体反混淆）
- `java.createAsymmetricCrypto / createSign`（RSA/证书）
- `java.singleFlight / lock / tick`（书源级并发控制）
- `java.getReadBookConfig / getThemeConfig`（阅读界面配置）
- `BaseSource` 的登录态方法（`getLoginInfo / login / getHeaderMap`）
## 八、批 1：规则分段与组合符（已对齐）

| # | Android 行为 | 位置 | iOS 实现 |
| --- | --- | --- | --- |
| 1 | 规则按 `<js>...</js>` / `@js:...` 切成 N 段，前段结果作为后段输入 | `AnalyzeRule.kt:593-636`、`341-364` | `RuleSplitter.splitByJSSegments` + `RuleEngine.executeJSSegments`（普通段重新 parse 上一段结果，JS 段注入 `result` 后执行） |
| 2 | 组合符种类由「最先出现」的分隔符决定 | `RuleAnalyzer.kt:165-179` | `RuleSplitter.splitCombination` + `firstTopLevelSeparator` |
| 3 | `[...]`、`(...)`、引号内的分隔符不参与切分 | `RuleAnalyzer.kt:163`、`185-217` | `splitTopLevel` 的深度/引号状态机 |
| 4 | `%%` 按下标交叉合并 | `AnalyzeByJSoup.kt:106-113` | `RuleEngine.executeCross` |
| 5 | `&&` 结果按 `\n` 连接 | `AnalyzeByJSoup.kt:44-56` | `executeAnd` 改为 `joined(separator: "\n")` |
| 6 | `$\d` 取当前结果列表下标 | `AnalyzeRule.kt:783-792` | `TemplateEngine.replaceDollarIndexes` |

验证：`Type Check` ✅（提交 `1c23edb`）。

### 批 1 未覆盖（归入批 2/3）

- `isUrl` 语义与 `getStringList` 的拆分规则（批 3）
- `@html` 集合整体输出、属性空值不回退（批 3）
- URL 层的 `analyzeJs`、11 项 URL 选项、`{{}}` 绑定补全（批 2）