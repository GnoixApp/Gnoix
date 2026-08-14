# 解析与阅读持续优化 TODO

> 更新时间: 2026-03-26

## 已完成

- [x] 发现页仅展示启用书源，并在返回时保持选中状态。
- [x] 书源健康检测改为高并发任务组，检测失败自动禁用。
- [x] 搜索/发现列表封面贴边显示，去除多层边框观感。
- [x] 默认封面占位图改为更简洁样式。
- [x] 服务器模式正文解析增强:
  - 支持字符串 / 对象 / 数组 / JSON字符串嵌套。
  - 支持漫画图片多字段提取 (`imageUrls/images/imgs/picUrls/...`)。
  - 支持 HTML / markdown / 纯图片链接提取。
  - 支持 `__API_ROOT__`、相对路径、懒加载字段 URL 规范化。
- [x] `getBookContent` 请求体与 reader 服务端参数兼容:
  - 增加 `bookSourceUrl`、`chapterUrl`。
  - 首次空内容自动 `refresh=1` 重试。
- [x] `getChapterList` 增强:
  - `index/chapterIndex` 的 Int/NSNumber/String 兼容解析。
  - 目录为空自动 `refresh=1` 重试。
- [x] 阅读引擎加空内容兜底:
  - 按 `chapter.index` 失败时，按当前章节位置再试一次。
- [x] 漫画 Cell 侧增加 URL 规范化兜底，避免相对地址导致空白。
- [x] 失败诊断持久化:
  - 新增 `SourceDiagnosticRecord`（endpoint/source/book/chapter/reason/失败次数/时间）。
  - `getBookInfo/getChapterList/getBookContent` 关键失败分支自动记录并聚合计数。
  - 支持 `getSourceDiagnostics()/clearSourceDiagnostics()` 便于后续做“失败源一键处理”。
- [x] 阅读失败提示补齐:
  - `ReadBookEngine` 在服务器正文拉取失败时回调 `onLoadFailed`，不再只打印日志。
- [x] 正文解析再兜底:
  - `getBookContent` 在非 JSON 响应时也会按纯文本/HTML/图片链接路径解析，减少“正文空白/原始文本”。
- [x] 服务端响应形态兼容增强:
  - `getBookInfo/getChapterList/getBookContent` 支持顶层对象/数组/标准包裹三种响应。
  - 目录接口可直接解析“未包裹章节数组”，降低空目录误判。
  - 漫画图片键补充 `picList/urlList/comicImages/pages/photos`。
- [x] 漫画阅读链路专项优化:
  - 漫画 Cell 增加 Referer/User-Agent 请求头，提升防盗链场景下的图片加载成功率。
  - 增加 URL 编码容错与无效 URL 兜底提示，减少空白页。
  - 阅读页增加漫画图片预取（窗口预加载）与布局刷新合并，降低滑动卡顿与闪烁。
- [x] 跨章节预热与失败重试:
  - `ReadBookEngine` 增加远程章节内容缓存与后台预热（普通书预热下一章，漫画预热后两章）。
  - 切章优先命中缓存，减少“下一章空白等待”。
  - 漫画图片请求增加重试策略与 Referer 失败回退（无 Referer 二次尝试）。
- [x] 返回列表封面稳定性修复（非漫画）:
  - 分类列表页改为仅在真正离开页面时取消封面下载，避免详情返回后封面空白。
  - 搜索/发现列表增加 `didEndDisplaying` 精准取消，替代整页误取消。
  - 书籍列表 Cell 增加 `prepareForReuse` 清理，复用状态更稳定。
- [x] 书架数据回退优化（服务器模式）:
  - 先显示本地书架快照，再异步刷新服务器，减少返回时空白和闪动。
  - 服务器请求失败时不再清空书架，保留已有内容。
  - 服务器返回缺失封面/简介时自动回填本地已有数据。
  - 增加短周期刷新节流（默认 8 秒），返回页面时优先本地快照，降低重复全量刷新抖动。
- [x] 本地解析容错增强（目录/正文 JSON 文本问题）:
  - 目录缓存增加脏数据识别（JSON 文本标题）并自动清理后重抓。
  - 章节入库前按书清理旧目录，避免旧脏目录与新目录混写。
  - 目录解析新增 JSON payload 回退提取，减少“有响应但无目录”。
  - 正文解析在规则失效时自动尝试 JSON payload 提取文本/图片，降低原始 JSON 泄漏概率。
  - 目录解析新增 HTML 链接自动识别回退（规则失效时自动从页面章节链接提取目录）。
  - 增加目录质量评估（有效 URL/章节标题命中率）并在主解析与回退结果间自动择优。
- [x] 目录顺序与正文 404 再兜底（本地解析）:
  - 目录缓存新增“顺序异常”检测（前几章混入末尾章节/整体倒序）并自动清理重抓。
  - 正文 404 时从“单次重试”升级为“多候选回退”：目录刷新后按索引、标题、邻近章节重试。
  - 正文链接增加 `http/https` 互换兜底，降低站点跳转差异导致的 404。
- [x] 阅读切章流畅度优化（对齐 reader 服务端思路）:
  - 切章请求增加任务代号校验，忽略过期章节响应，避免快速翻章时内容回跳。
  - 远程章节缓存容量提升并改为前后双向预热（下一章/下两章 + 上一章）。
  - 已缓存章节切换不再强制显示 loading；边界滑动切章阈值降低并去掉额外延时。
  - 分页模式改为后台线程先算分页范围，再主线程渲染，降低主线程卡顿。
- [x] 发现列表解析增强:
  - 书名/链接/封面字段增加回退提取（元素文本、`href/data-href`、`src/data-src`）。
  - 避免将明显 JSON 文本误当作书名/作者/简介。
- [x] 本地 TXT 目录解析增强（对齐 legado 思路）:
  - 支持 `chapterSize` 规则透传，并用于无目录分片和超长章节切分阈值。
  - 标题清洗与噪声过滤增强（去除菜单/广告类伪标题）。
  - 邻近重复标题去重，降低同页重复命中导致的伪章节。
  - 章节重排增强：支持倒序检测反转、按章节号排序择优，减少“前几章混入末尾章节”。
  - 中文章节号提取增强（含大写中文数字转换），提升顺序判断准确率。
  - 新增“疑似标题”判定与异常短章节合并，减少目录误切片。
  - 重排逻辑保护前置无编号章节（如前言/序章）位置，避免被反转到末尾。
- [x] 本地 TXT 与书源规则联动:
  - `ReadBookEngine` 在本地 TXT 解析时复用当前书源 `ruleToc`（`chapterList/isVolume/chapterSize` 等）。
  - 保持无规则时原有默认行为，兼容已有导入书籍流程。
- [x] Legado 规则兼容增强（针对你书源合集高频能力）:
  - 规则前缀大小写兼容：`@Json/@JSon/@XPath` 等变体可识别。
  - 新增内联 `<js>...</js>` 管道规则支持（前置/中置/后置 JS 块串联选择器）。
  - JSONPath 新增过滤表达式支持：`[?(@.key=='v')]` / `!=` / `=~ /regex/i`。
  - JS 运行时补齐高频缺失方法：`java.post`、`base64Encode/base64Decode`、`base64DecodeToByteArray`、`hexDecodeToString`、`HMacBase64`、`createSymmetricCrypto(...).decryptStr(...)`。
  - JS 运行时补齐 URL 刷新兼容入口：`initUrl/refreshTocUrl/refreshBookUrl`（兼容旧脚本调用链）。
  - `java.getStrResponse/java.post` 现在返回带 `header()/code()/url()/body()` 的响应对象，兼容依赖响应头的脚本。
  - 网络层新增详细响应接口（状态码/响应头/最终 URL），供 JS 规则引擎读取。
- [x] Legado Java API 继续补齐（source/connect 兼容批次）:
  - `source.getLoginInfoMap()` 改为真实可写 Map（`get/put/remove/keySet/clear`），不再是空壳。
  - 新增 `source.getVariableBook()` 运行时变量 Map 兼容（`get/put/remove/keySet/clear`）。
  - `source.putLoginHeader/removeLoginHeader` 改为真实生效：支持登录后动态注入/移除 Header（含 Cookie 字符串兜底归一化）。
  - `source.header` 现在读取当前运行时 Header（基础头 + 登录头合并），并保持 JSON 字符串语义。
  - `java.get(url, headers)` 新增 HTTP 模式重载（保留原 `java.get(key)` 变量读取能力）。
  - `java.connect(...).raw().request()` 扩展为可链式配置请求（`method/header/headers/userAgent/referrer/cookie/data/requestBody/postData`）并返回完整响应对象。
- [x] 目录 `js/@js/<js>` 规则解析兜底增强（修复 `SelectorParseException: Could not parse query js:`）:
  - `RuleAnalyzer.analyzeList` 新增规则前缀归一化（BOM/零宽字符/全角冒号 `：`）。
  - CSS 选择器分支抛错时增加“宽松 JS 规则识别”回退，避免将 JS 脚本误当 CSS 继续解析。
  - 新增单测覆盖 `@js:`、`js:`、`@js：` 三种目录规则写法。

## 进行中

- [x] 诊断信息可视化:
  - 在“书源管理”增加失败统计面板（最近失败、失败次数、失败原因）。
  - 支持“按失败统计禁用异常书源”与“清空失败统计”。
  - 书源列表行内显示失败次数与最近失败时间，高风险源高亮图标提示。

## 下一步

- [ ] 对照 reader 继续补齐接口参数兼容矩阵（`getBookInfo/getChapterList/getBookContent` 全链路）。
- [ ] 继续补齐 Legado Java API 兼容:
  - `source.getLoginInfoMap()` 与登录 UI 参数打通（将用户输入透传到 JS 登录脚本）。
  - 细化 `java.connect(...).raw().request()` 语义（`timeout/followRedirects/ignoreHttpErrors` 对请求行为的真实控制）。
- [ ] 增加书源粒度失败统计（失败率、最近失败时间、失败原因聚类）。
- [ ] 阅读页漫画体验优化:
  - 图片预加载与缓存命中提升。
  - 长图章节滚动性能与内存峰值控制。
- [ ] 回归测试清单自动化:
  - 文本小说正文、漫画章节、JSON正文、目录分页四类样本验证。

## 验收建议

- 用 3 类书源各测 2 本书:
  - 普通文字小说
  - 漫画图集
  - 正文返回 JSON 的源
- 检查 4 个关键点:
  - 目录是否完整且顺序正确
  - 正文是否非空且非原始 JSON 文本
  - 漫画图片是否全部加载
  - 切章是否不会跳错章
