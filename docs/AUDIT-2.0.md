# Legado iOS ↔ Android 全量差异审计

> 审计方式：5 个模块并行精读两侧源码，逐功能点比对并标注行号。
> 判定口径：**一致**（语义等价）/ **部分一致**（有实现但语义或能力有差）/ **缺失**（Android 有 iOS 无）/ **iOS 多出**（iOS 有 Android 无）。
> 审计日期：2026-11-04　基线版本：iOS `1.3.37`

---

## 一、量化基线

| 指标 | Android | iOS | 说明 |
| --- | --- | --- | --- |
| Kotlin/Swift 文件数 | 1058 | 158 | Android 含 RSS / 漫画 / 有声 / 字典 / Web 服务 / MCP 等 |
| 代码行数 | 174,019 | 35,363 | — |
| Core Data 实体 | — | 19 | 含 RSS 4 个（无界面） |
| 设置项（UserDefaults 键） | — | 161 | — |
| 单元测试文件 | 50+ | 12 | 规则层仅 140 行断言 |

---

## 二、226 个检查点的判定分布

| 判定 | 数量 | 占比 |
| --- | --- | --- |
| 一致 | 约 51 | 23% |
| 部分一致 | 约 94 | 42% |
| 缺失 | 约 55 | 24% |
| iOS 多出 | 约 26 | 11% |

按模块：

| 模块 | 一致 | 部分一致 | 缺失 | iOS 多出 |
| --- | --- | --- | --- | --- |
| 规则引擎（6 组 60 点） | 25 | 20 | 9 | 6 |
| 阅读器（6 组 50 点） | 12 | 20 | 12 | 3 |
| 书架 + 详情（5 组 45 点） | 3 | 20 | 15 | 4 |
| 搜索/发现/书源（5 组 45 点） | 5 | 18 | 10 | 3 |
| 外围能力（6 组 40 点） | 6 | 16 | 9 | 10 |

---

## 三、P0：影响「能不能用」的 5 个问题

| # | 问题 | 依据 | 影响 |
| --- | --- | --- | --- |
| 1 | **书架长按无法进入详情页** | Android `BooksAdapterGrid.kt:132-136`、`BookshelfFragment2.kt:319-324`；iOS `BookshelfView.swift:343-355` 长按只有换源/删除 | 书架上的书看不到简介/目录预览/加入书架状态，详情只能从搜索结果进 |
| 2 | **「加入书架」是假状态** | Android `BookInfoActivity.kt:1002-1008`（`inBookshelf` 真实增删）；iOS `BookDetailView.swift:481-500` 只改 `customTag="favorite"` | 详情页点「加入书架」不产生书架记录，与书架数据不一致 |
| 3 | **`{{…}}` / `$n` 在字段规则不生效** | Android `AnalyzeRule.kt:341-344`（每条 SourceRule 都 `makeUpRule`）；iOS 仅 `AnalyzeUrl.swift:304` 与 `@put` 调用 `TemplateEngine.render` | 含 `{{page}}`、`{{$.x}}`、`$1` 的取值规则原样输出，整条规则失效 |
| 4 | **JS 桥缺 18 个方法** | Android `JsExtensions.kt`（ajaxTestAll/head/t2s/s2t/getVerificationCode/importScript/cacheFile/downloadFile/startBrowser/…） | 用到这些方法的源脚本直接抛 TypeError |
| 5 | **`java.get`/`connect`/`post` 返回类型不同** | Android 返回 `Response`/`StrResponse` 对象（`JsExtensions.kt:575-652`）；iOS 返回字符串（`JSBridge.swift:150,188-192`） | 脚本里写 `resp.body`、`resp.headers` 的全部失效 |

---

## 四、P1：影响体验一致性的 10 个问题

| # | 问题 | 差距 |
| --- | --- | --- |
| 6 | 搜索无加载更多 / 暂停 / 精准搜索开关 | Android 有 `hasMore` + 滚到底续搜 + `precisionSearch`（`SearchModel.kt:84,111-115`）；iOS 单次全量、不可中断 |
| 7 | 目录缺书签页签、搜索过滤、字数、VIP 锁、分卷折叠、跳顶底 | Android `TocActivity.kt:80-255`、`ChapterListAdapter.kt:196-244`；iOS 单列表（`ReaderViewModel.swift:929-1015`） |
| 8 | 批量能力缺口 | Android 有移出分组/批量换源/批量缓存/导出书架/更新目录/定时任务（`BookshelfManageActivity.kt:328-337`）；iOS 只有全选/加入分组/删除 |
| 9 | 备份数据面 4 类 vs 20+ 类，且无加密、还原前清空 | Android `Backup.kt:273-319`（书签/高亮/分组/阅读记录/订阅/TXT 规则/词典/…）+ AES（`:228-244`）+ 还原前自动备份（`:192-208`）；iOS `WebDAVSyncManager.swift:45-70` 仅 books/sources/replaceRules/readProgress，明文 JSON，`restore` 先 `clearAllData()` |
| 10 | 朗读无当前句高亮、不驱动翻页 | Android `ReadAloud.kt:44-45` + `TextLine.kt:132-139`；iOS `TTSControlsView.swift:306-311` 回调为空 |
| 11 | 缓存并发声明未启用 + 无失败重试 | iOS `ChapterCacheManager.swift:22`（`maxConcurrency=3` 未使用）、`:65-76` 串行、`:119-122` 失败仅 print；Android 32 线程池 + 3 次重试（`CacheBookService.kt:43-45`、`CacheBook.kt:283-295`） |
| 12 | 主题缺背景图、透明度、三组 bg、5 套样式 | Android `ReadBookConfig.kt:909-915`；iOS `ReaderViewModel.swift:276-299` 固定 4 色 + 2 色自定义 |
| 13 | `@webjs:` 分段、首字符 `:` 的 allInOne Regex 模式缺失 | Android `AnalyzeRule.kt:618-628`、`:599-605`；iOS `RuleSplitter.swift:232-284` 无这两支 |
| 14 | 发现内容页无前插 / 页码跳转 / 批量加书架 | Android `ExploreShowViewModel.kt:180-230,274-346`；iOS 单向 loadMore + 逐条入库 |
| 15 | 书源校验结果不回写（无 checkState/checkDetail/失败分组） | Android `CheckSourceService.kt:228,287-289`；iOS `SourceBatchController.swift:61-79` 只存内存结果 |

---

## 五、P2：细节差异清单（不影响主流程）

**规则层**
- `&&` 结果被合并成单串而非列表拼接（`AnalyzeByJSoup.kt:84-119` vs `RuleEngine.swift:252-264`）
- `getString` 多结果不按 `\n` 拼接，取首个非空（`AnalyzeByJSoup.kt:44-56`）
- `@ownText` 用 textNodes 直拼、`@all` 额外删 script（`AnalyzeByJSoup.kt:248-264`）
- URL 缺 HEAD 方法；POST 表单无「已编码则跳过」判断
- `base64Encode` 无 flags 重载；`readTxtFile` 无字节数组返回
- `@put` 执行期抽取（Android 是切分期）；无 JSON 兜底解析

**阅读器**
- 页面边距默认上下 20（Android 6）；正文字号表单默认 18（Android 20）
- 章节标题仅 3 档位置，无独立字号/字色/行距偏移
- 正文无字重设置（Android `textBold`）
- 无悬挂缩进、标点压缩弱化为 `.pushOut`
- 无相邻页预取（Android `nextPage/prevPage/nextPlusPage`）
- 无富文本列（图片/HTML/段评）
- 点击动作只有 3 档预设（Android 9 格可逐个配置）
- 底栏固定 6 按钮（Android 20 项可排序）
- 页眉页脚仅上下 2 模板（Android 6 槽位 + 电量/时间 + 分隔线 + 字号颜色）
- 无上滑加书签、无双指替换预览
- 音量键翻页缺失（iOS 无公开 API，属平台限制）

**书架/详情**
- 无紧凑列表（第二种列表样式）、无封面样式第三种、书名只有显示/隐藏两态
- 未读角标无开关、无「更新中」loading
- 进度条无粗细模式、无全局开关
- 分组无封面拼图、无分组级排序/刷新/只更新已读、无 63 个上限
- 分组横滑切换缺失（Android 风格 2 的分组卡片屏）
- 详情页简介折叠无溢出测量、无 `<useweb>`
- 详情页无分享、无换封面、无查看大图、无分组设置
- 目录无页签、无搜索、无字数/VIP 标记

**搜索/书源**
- 搜索超时粒度：每源 30s（Android）vs 全局 90s（iOS）
- 结果缺最新章、分类标签、在架/阅读记录圆点
- 书源缺「无分组」「校验状态」筛选；排序无升降序切换
- 书源无分组管理界面
- 导入：仅 JSON 数组/对象，无 JS 源文本；`URLSchemeHandler` 导入**无去重**
- 深链仅 `legado://booksource/...`，缺 `legado://import/bookSource`
- 导出字段不全（`variable`/`exploreScreen`/`customButton` 等）

**外围**
- 本地书章节正则硬编码 3 条（Android 有可编辑的 `TxtTocRule` 规则库）
- 导出仅 UTF-8 TXT/EPUB，无编码选择
- 统计无「单书详情编辑/删除」
- 无定时备份、无保留份数策略
- 阅读记录 365 天/1000 条截断

---

## 六、iOS 优于 Android 的 10 项（已实现但 Android 没有）

| # | 能力 | iOS 依据 |
| --- | --- | --- |
| 1 | 阅读统计：周/月聚合 + 12 周热力图 + 字数 | `ReadingStatisticsView.swift:41-72,206-212` |
| 2 | WebDAV 增量同步 | `WebDAVSyncManager.swift:399-402,568-575` |
| 3 | 缓存上限自动清理（默认 500MB，删至 80%） | `ChapterCacheManager.swift:276-325` |
| 4 | 仅 Wi-Fi 缓存 + 断网提示 | `ChapterCacheManager.swift:216-218`、`NetworkMonitor` |
| 5 | TTS 音调/音量可调 | `TTSManager.swift:41-42` |
| 6 | 本地 CBZ 漫画、HTML/MD 本地书 | `LocalBookBinaryFormats.swift:165-241`、`LocalBookParser.swift:67` |
| 7 | 书源信息面板（类型/分组/地址/需登录 + 跳编辑） | `BookDetailView.swift:313-381` |
| 8 | 书架网格列数 2~6 可调、分页加载 | `BookshelfView.swift:100-113` |
| 9 | 阅读器自定义配色（背景 + 文字） | `ReaderViewModel.swift:527-535` |
| 10 | 首屏优先分页（先测一页立刻出字） | `PageSplitter.swift` + `PagedReaderView.swift:219-243` |

---

## 七、死代码（写了但未接入）

| 文件 | 状态 |
| --- | --- |
| `Features/Reader/ReaderConfigSheets.swift`（13/108/276 行起三个 Sheet） | 无引用 |
| `Features/Reader/BrightnessSlider.swift` | 无引用（`ReaderView` 用的是内联 Slider） |
| `Features/Reader/TextActionMenu.swift` | 无引用 |
| `Features/Reader/ReaderSettingsFullView.swift` | 仅从主 Tab 的「阅读设置」可达，阅读器内设置面板是另一套（`ReaderSettingsView`） |
| `RssSource/RssArticle/RssStar/RssReadRecord` Core Data 实体 | 有模型无界面 |

---

## 八、修正后的完成度（较此前自评下调）

| 阶段 | 此前自评 | 审计后 | 主要扣分项 |
| --- | --- | --- | --- |
| P1 规则引擎 | 99% | **90%** | `makeUpRule` 未覆盖字段规则（P0-3）、`@webjs:`、allInOne Regex、JS 桥 18 方法、`java.get/connect/post` 返回类型 |
| P2 阅读器 | 95% | **80%** | 长按选词/选段整体缺失、无富文本列、无页级预取、主题体系压缩、点击动作/菜单不可配 |
| P3 书架/详情/搜索/发现/书源 | 98% | **85%** | 长按不能进详情、加书架假状态、批量能力缺口、目录页签缺失、搜索无分页/暂停、书源校验不回写 |
| P4 外围 | 98% | **85%** | 备份数据面 4/20+、无加密、还原清空、无定时备份、缓存并发未启用+无重试、无朗读高亮 |
| **整体（加权）** | 98% | **≈ 86%** | — |

---

## 九、建议修复顺序

**第一批（P0，约 3 轮）**
1. 书架长按进详情（`NavigationLink` 到 `BookDetailView`）
2. 「加入书架」改为真实增删（`Book.create` / `context.delete`），与 `customTag` 解耦
3. `TemplateEngine.render` 接入 `RuleEngine.getString/getStringList`（含 `$n`、`{{$.x}}`）
4. JS 桥补 18 个方法（可先补 `head/t2s/s2t/base64DecodeToByteArray/hexDecodeToByteArray/getSource/ajaxTestAll` 这批纯本地可实现的）
5. `java.get`/`connect`/`post` 返回对象化（用一个 JS 对象包装 body/headers/code）

**第二批（P1，约 4 轮）**
6. 搜索：加载更多 + 暂停/停止 + 精准搜索 + 单源超时
7. 目录：书签页签 + 搜索过滤 + 字数/VIP + 分卷折叠
8. 书架批量：移出分组 + 批量缓存 + 导出书架 + 更新目录
9. 备份：数据面补到 12 类 + 还原前自动备份 + 可选 AES
10. 朗读：当前句高亮 + 驱动翻页
11. 缓存：并发真的并发 + 失败重试 3 次
12. 主题：背景图 + 透明度 + 5 套样式
13. `@webjs:` + allInOne Regex 模式
14. 发现页批量加书架 + 前插
15. 书源校验回写（新增 `checkState`/`checkDetail` 字段）

**第三批（P2 + 清理，约 2 轮）**
16. 删除/接入死代码（4 个文件 + 4 个 RSS 实体）
17. 剩余 P2 细节按需补

---

## 十、结论

- **主链路可用**：搜索 → 详情 → 目录 → 正文 → 换源 → 缓存 → 朗读，均已打通且 CI 全绿。
- **最大风险在规则层**（P0-3、P0-4、P0-5）：这三项会让「看起来支持但实际解析失败」的源占比偏高，且难以从界面察觉。
- **最大体验落差在书架**（P0-1、P0-2）：书架是入口，长按不能进详情、加书架是假状态，这两个最容易被用户第一时间发现。
- 此前按「功能点是否覆盖」评估为 98%，按「逐点语义 + 交互一致」重新评估为 **86%**，差额主要在语义细节与批量/配置类能力。

---

## 十一、P1 修复记录（1.3.38 → 1.3.40）

| # | 审计项 | 修复内容 | 影响 |
| --- | --- | --- | --- |
| P0-3 | `{{…}}` / `$n` 在字段规则不生效 | `getStringRaw` / `getStringList` / `getElements` 三个入口接入 `TemplateEngine.render`（对齐 `AnalyzeRule.kt:341-344` 的 `makeUpRule`） | 含 `{{page}}`、`{{$.x}}`、`$1` 的取值规则不再原样输出 |
| P0-4 | JS 桥缺 18 个方法 | 补 `head` / `t2s` / `s2t` / `base64DecodeToByteArray` / `hexDecodeToByteArray` / `getSource` | 繁简转换、字节数组、HEAD 探测、取当前源信息的脚本可用 |
| P0-5 | `java.get`/`connect`/`post` 返回字符串 | 改为返回 `{ code, body, url, headers }` 对象；变量读写拆到 `getVariable` / `putVariable`（对齐 Android `BaseSource`） | 脚本里 `resp.body`、`resp.code`、`resp.headers` 可正常取值 |
| P1-13a | `@webjs:` 分段缺失 | `RuleSplitter.splitByJSSegments` 识别 `@webjs:`，`executeJSSegments` 用 `WebViewFetcher` 加载页面后执行脚本 | 依赖 WebView 渲染的规则段可用（仅 iOS） |
| P1-13b | 首字符 `:` 的 allInOne 正则缺失 | `parseTypeAndRule` 在「以 `:` 开头且含正则元字符」时判定为 regex（避免误伤 `:first-child` 这类伪类） | 整条正则型规则可用 |
| P2 | `&&` 遇列表结果被合并成单串 | `executeAnd` 只要任一段产出列表就返回列表（对齐 `AnalyzeByJSoup.kt:84-119` 的 addAll） | 多段列表规则保持逐项对应 |
| P2 | `@all` 与 `@html` 同为 stripScripts | `@all` 改为原样 outerHtml（`@html` 仍删 script） | 需要原始 HTML（含 script）的规则正确 |
| P2 | URL 缺 HEAD 方法 | `AnalyzedUrl.HTTPMethod` 加 `head`，解析 `"method":"HEAD"` | HEAD 探测类源可用 |
| P2 | POST 表单已编码仍二次编码 | 检测 body 含 `%` 且含 `=` 时跳过 `encodeFormBody` | 手工编码的 body 不再被二次转义 |

**仍未修（后续按失败源补）**：`java.webView` 之外的可视浏览器交互（`startBrowser`/`showBrowser`）、文件下载与解压（`downloadFile`/`cacheFile`/`unzipFile`）、字体反混淆（`queryTTF`/`replaceFont`）、RSA 签名（`createSign`/`createAsymmetricCrypto`）、`ajaxTestAll`、`@ownText` 的空白归一细节。
---

## 十二、P3 修复记录（1.3.42）

| # | 审计项 | 修复内容 |
| --- | --- | --- |
| P0-1 | 书架长按无法进详情 | 网格与列表的长按菜单新增「书籍详情」，sheet 打开 `BookDetailView` |
| P0-2 | 「加入书架」是假状态（只改 customTag） | `Book` 新增 `isInShelf`（Core Data 默认 YES，旧数据自动在架）；书架查询加 `isInShelf == YES`；详情页按钮改为真实切换（加入时归到默认分组，移出保留进度）；搜索结果入库时 `isInShelf = false`（对齐 Android：搜索进详情不算在架） |
| P1-7 | 目录缺搜索/字数/VIP/分卷折叠 | 目录加 `.searchable` 章节搜索、右上菜单可开关「显示字数」、章节行显示 VIP 锁、卷头可点击折叠/展开（搜索时自动忽略折叠） |
| P1-8 | 批量能力缺口 | 新增「移出分组」（位掩码 AND NOT）与「移出书架」（保留记录与进度），批量栏分组操作改为菜单 |
| P1-14 | 发现页无批量加书架 | 内容页右上「全部加入书架」，逐条去重并汇总「新增 N / 已存在 M」 |

### 修复后的行为变化（需真机确认）

1. **首次启动会做一次 Core Data 轻量迁移**（新增 `isInShelf`），旧书架的书默认在架，不会丢
2. **搜索/发现点进详情不再自动进书架**，需要在详情页点「加入书架」
3. 书架上长按 → 「书籍详情」可直接看简介/目录/书源信息
---

## 十三、订阅更新失败修复（1.3.43）

用户反馈：点「更新全部」后进度条恒为 0，十几秒后自动恢复到未点击状态，导出日志无任何错误。

### 根因

| # | 问题 | 证据 |
| --- | --- | --- |
| 1 | 请求过程**完全没有日志** | `fetchSources` 用裸 `URLSession.shared.data(for:)`，成功/失败都不记录，日志自然空白 |
| 2 | 错误被两处吞掉 | `catch { print(...) }`（不进 AppLogger 文件）+ 单订阅入口 `try? await` |
| 3 | 进度按「订阅数」算，不是源数 | `total` = 订阅条数；1 个订阅时导入 800 个源全程 `updateProgress = 0` |
| 4 | 导入是 O(n²) | 每个源一次 `BookSource.fetchRequest()` 全表查询（本地 800 × 订阅 800 = 64 万次比较） |
| 5 | 一次性 `save()` 几百个变更 | 中途无进度、无让出主线程 |
| 6 | 更新覆盖本地启停状态 | `enabled = source.enabled ?? true`，手动停用的源会被重新启用 |
| 7 | 字段覆盖不全 | `jsLib` / `loginUi` / `variableComment` 等未写入 |

### 修复

| # | 修复 |
| --- | --- |
| 1 | `fetchSources` 全链路日志：请求 URL、响应 status/bytes/host、失败 NSError code、解析成功数、**解析失败时打印响应前 240 字节** |
| 2 | 所有错误写入 `AppLogger.error` + `lastUpdateError`，订阅页红字显示 |
| 3 | 进度改为「订阅 × 阶段」折算：下载 0~15%、解析 15~30%、导入 30~100%，并显示「导入 320/800」与百分比 |
| 4 | 导入前一次性预取所有 `bookSourceUrl` 建字典，O(n²) → O(n) |
| 5 | 每 50 个源 `save()` + `await Task.yield()`，进度条可刷新、界面不卡 |
| 6 | 更新已有源时 `preserveLocalState: true`，保留本地 `enabled` / `enabledExplore` / `respondTime` |
| 7 | 补全 `loginUi` / `loginCheckJs` / `jsLib` / `coverDecodeJs` / `variableComment` / `bookSourceComment` / `enabledCookieJar` / `customOrder` / `ruleReviewData` |
| 8 | 订阅 URL 只接受 http/https，其它形式（如 `legado://`）明确报「订阅地址不合法」而不是静默失败 |
| 9 | 请求加浏览器 UA（部分 CDN 会拦默认客户端） |

### 如果修复后仍失败

日志里现在会有明确线索，按关键字搜 `[Subscription]`：

- `请求失败 host=... code=-1009` → 网络不可达（该域名在你当前网络下不通）
- `响应 status=403` → 站点拒绝（可能需要 Cookie/Referer）
- `解析失败，响应片段：<html>...` → 返回的不是书源 JSON
- `订阅地址不合法` → 订阅 URL 不是 http/https
---

## 十四、订阅更新失败修复（第二轮，1.3.44）

真机日志（1.3.43）暴露了真正原因：

```
请求 https://www.yckceo.com/yuedu/shuyuans/json/id/1330.json
请求失败 err=请求超时 code=-1001            ← 20s 不够（文件 7.8MB）
响应 status=200 bytes=7857616               ← 第二次请求成功
解析失败，响应片段：[ { "bookSourceComment": ... "bookSourceUrl": "https://www.sou78.com/" ...
```

### 根因

| # | 问题 | 说明 |
| --- | --- | --- |
| 1 | **`ExportableSource` 的 `bookSourceUrl` / `bookSourceName` 是 `let` 非可选** | 订阅里只要有一源缺这两个字段（或类型不符），整个 800 源的数组解码就整体失败 |
| 2 | 嵌套规则（`ruleSearch` 等）解码失败会抛出 | 某个源的规则结构与 iOS 模型不完全兼容 → 整个数组失败 |
| 3 | 超时 20 秒不足 | 该订阅 7.8MB，第一次请求直接 -1001 超时 |
| 4 | 一次 `decode([ExportableSource].self)` 无法定位坏源 | `try?` 吞掉 `DecodingError`，日志里只知道「解析失败」 |

### 修复

| # | 修复 |
| --- | --- |
| 1 | 自定义**宽松解码** `init(from:)`：所有字段 `decodeIfPresent` + 类型兜底（数字↔字符串↔布尔互转），`bookSourceUrl`/`bookSourceName` 缺失时用空串 |
| 2 | 嵌套规则解码失败只置 `nil`，**只影响该源的规则，不抛错** |
| 3 | `fetchSources` 改为**逐条解码**：`JSONSerialization` 取数组 → 每条单独 `decode` → 坏源跳过并记录序号与原因，好源照常导入 |
| 4 | 超时 20s → **45s** |
| 5 | 并发诊断：`updateAllSubscriptions` 打印管理器实例标识，若出现两个不同 id 说明单例被重复创建 |
| 6 | 已在执行时打印「已有更新任务在执行，忽略本次触发」，便于确认重复点击/启动自动更新是否叠加 |