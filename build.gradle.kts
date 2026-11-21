// aster-lang-platform — the single source of truth for aster-lang
// ecosystem dependency versions (ADR 0012).
//
// This project publishes a Gradle *version catalog* artifact
// (cloud.aster-lang:aster-lang-platform). Every consumer repo
// (aster-lang-core, -runtime, -truffle, -validation, -locales,
// aster-api, …) imports this catalog in its settings.gradle and refers
// to deps by alias (e.g. `asterLibs.core`) instead of hardcoding
// `cloud.aster-lang:aster-lang-core:0.0.1`.
//
// To bump the whole ecosystem: change `asterLang` below once, publish a
// new platform version, then point each consumer's catalog import at it.
// (Multi-repo can't do literal "edit one line, everything updates" —
// each repo still pins which platform version it imports — but this
// collapses ~20 scattered version literals down to one per repo.)
//
// SCOPE: JVM ecosystem only. The TypeScript packages (aster-lang-ts etc.)
// publish to npm on an independent cadence and intentionally are NOT in
// this catalog — binding the two ecosystems to one number is a false
// coupling (see ADR 0012 §"rejected: unified cross-ecosystem version").

plugins {
    `version-catalog`
    `maven-publish`
}

group = "cloud.aster-lang"
// The platform artifact's OWN version. Bump this when the catalog
// contents change (i.e. when any ecosystem version below changes).
// 2026-07 全量审计收尾：28 项发现全部处理完毕（跨 core/ts/truffle/test/aster-api）。
// 本次把 platform 自身与生态号**对齐到同一数字**——此前 platform 因 wrapper 升级、
// 治理文件、审计报告等仅影响自身的改动先行到 1.0.16，生态仍停在 1.0.14，两者相差 2。
// lockstep 生态 → asterLang 1.0.14→1.0.17，platform 自身 1.0.16→1.0.17（追平）。
// 1.0.18：core 生产词法器补天城文、truffle NameNode slot 读取修复 + AsyncTaskRegistry
// 线程池泄漏、ts eval-parity 转 PR-blocking。platform 与生态号继续保持一致。
// 1.0.19：aster-api /evaluate-source 并发闸门可被取消绕过（许可挂 onTermination，
// HTTP 取消立刻归还而 worker 仍在跑 → 反复「发起再取消」可绕过闸门）。许可归还
// 收敛为 PermitLease 的 CAS 一次性租约。本仓无代码改动，随生态 lockstep 对齐。
// 1.0.20：truffle 两项修复随生态 lockstep 发布——(1) 步骤级 trace 带源码行号
// （条件漏斗按行号分组/排序，truffle#64）；(2) 成员访问失败时列出可用键名，
// 不再把「键名对不上」误导成 HostAccess 配置问题（truffle#65 / api#244）；
// 另 GraalVM 组件收敛到 25.0.4，消除 25.0.1/25.0.3/25.0.4 三版本混用（api#193）。
//
// 1.0.21：新增 graalvm 版本与 7 个组件别名（api#193），并随生态 lockstep 发版。
//
// ★订正上一版的判断：我曾只抬目录自身 version、把 asterLang 留在 1.0.20，
//   理由是「没有模块重新发版」。但 aster-api 的 CI 有一处刻意设计——
//   setup-aster-build 的 sibling-ref 默认 v1.0.20，注释写明
//   「生态 lockstep 发版，七个仓共用同一个版本号与 tag 名」。
//   分离两个版本轴会打破这个不变量，使 api 找不到对应 tag 的兄弟仓源码。
//   故本次按原设计走完整生态列车：platform / asterLang / ecosystemVersion 同为 1.0.21。
//
// 1.0.22：补丁列车，唯一实质内容是把 ui-messages 的 evidenceExport 四语文案
//   （aster-lang-locales#60 / aster-lang-hi#57，issue #260 遗留）带到 tag 上。
//
//   ★为什么不能直接移动 v1.0.21：aster-api 的 sibling parity 门禁比对的是
//   CI 检出的**兄弟仓 tag**，而 v1.0.21 的制品已发布到 GH Packages。
//   移 tag 会让「tag 指向的源码」与「同名不可变制品」永久对不上——
//   这正是 sibling-ref 钉版本要消除的那类不确定性。故只能向前发新版。
//
// 1.0.23：把 aster-lang-ts#112 的 stdlib 补齐送到 npm —— Text.substring /
//   Text.replace / List.slice / Maybe.unwrap / Result.unwrap / Result.unwrapErr
//   此前只有 JVM 引擎有，TS 侧缺失，而文档站演练场跑的正是 TS 引擎，
//   用户照文档抄必撞 Undefined function（aster-dev#22）。
//   其余各仓的未发版 commit 都是 CI 管道（共享 checkout-sibling），不改制品行为。
//
//   ★ui-messages 的 npm 版本同步抬到 1.0.18：它是 literal 版本且 1.0.17 已发布，
//   而 locales/hi 是 maven+npm 双制品共用一个 release.yml —— maven 1.0.23 不可见
//   必然触发 dispatch，连带重发 npm，撞重复版本即断层（1.0.22 已踩过）。
//
// 1.0.24：安全 + 正确性补丁列车。
//   ★ReDoS（CodeQL high）：scale 校验正则的歧义分支，宿主传入 2 万字符即可
//     占死线程 101 秒（truffle#84 / ts#114）。
//   其余：#73 实参不再写入共享 globalEnv、api#244 标量参数错误信息指向真因、
//   #74 第 1 项 Map 拒绝 null 键（ADR 0035 档位 A）、valueEquals 深度上限双引擎对齐。
//
// 1.0.25：二轮深度审查修的两条**双引擎分叉**。
//   ★is equal to 对结构体/列表两侧结果不同（TS 引用相等 false / Java 结构相等 true）
//     —— 同一条规则在两套引擎给出不同决策。统一为结构相等（ts#117）。
//   ★List.groupBy 自己造键、绕过 mapKey，null 分组键与字符串 "null" 塌陷同桶
//     （truffle#87 / ts#117），顺带修掉 groupBy 的 1 vs 1.0 分组分叉。
//   语料补 struct_list_equality 作跨引擎守门（test#90）——此前唯一的相等用例只喂标量。
//
// 1.0.26：ADR 0035 档位 C —— **破坏性语义变更**。
//   ★Map.get 不再返回裸值/null，改为 Some(value) / None。
//     明知破坏 spec-1.0-freeze 的「Stable 1.x 内语义不变」承诺，由用户拍板接受
//     （真实用量仅 3 个 corpus 文件，已逐一核实）。
//   配套：List.* 对非列表输入改为响亮失败（此前 TS 静默返回 0/true/null，
//     Java 一律 throw —— 既是双引擎分叉也是静默错答案）。
//   至此档位 B（编译期警告）判定为不必要：其四种目标情形已全部响亮失败。
//
// 1.0.27：文案同步发版（无语义变更）。
//   线上 /signup 长期渲染裸 key（auth.signup.emailLabel 等）。根因不是缓存、
//   也不是 npm 包没发：cloud 的加载顺序是 KV → 后端 /api/v1/messages → 内嵌 npm 包，
//   **后端优先级最高**，而 aster-api 的 classpath 副本停在旧版。
//   实测生产 API 只返回 12 个 signup key、无 auth.verifyEmail、无 auditUnlimited。
//   本次：locales/hi 真相源补 auditUnlimited 与 161 条印地语翻译（四语各 2436 叶子），
//   aster-api classpath 副本同步（api#290）。副本与源的 lockstep parity 测试比对
//   的是 sibling tag，故必须切新 tag 才能让副本与源同时上线。
//   引擎/语义零改动——本版只为把文案送上生产。
//
// 1.0.33：Cedar 导出目标发版（ADR 0047）。
//   core：aster.core.cedar——CNL 规则到 Cedar policy/schema 的确定性导出、T/F 缺键语义、
//   范围守卫、等价性探针生成，新增 E720–E724。ts：同步错误码 E720–E724。
//   runtime/validation/test/locales/hi/truffle 源码无变更，lockstep 重新打 tag。
//
// 1.0.32：引擎一致性与测试稳定性修复版。
//   truffle：and/or 短路求值（ShortCircuitNode），与 ts 一致。ts：前缀运算符调用集合与
//   Java operatorCall 逐项对齐；发版 workflow 补 aster-lang-test 兄弟仓；移除跨 org 升级派发。
//   core/ts/truffle：ReDoS 与基准测试改为计数/宽缩放判定，去除 CI 噪声。test：and/or 短路与
//   List.get 立即求值 parity 样本。
//
// 1.0.31：治理档案与语法糖发版（ADR 0045/0046）。
//   core/ts：控制点注册表与 W704、`Profile "<id>".` 声明、When/Otherwise 语法糖、
//   档案检查 E705/E706 与治理检查不可用 E707、前缀运算符调用；ts 格式化器重写为
//   AST 打印器、LSP 无损重排不再改写字符串字面量。locales/hi：注册表 1.1.0（含档案）
//   与六个治理语法糖词。test：语法糖/长写法成对样本与前缀运算符样本。
//   新 SemanticTokenKind 在本版发布前一直位于 OPTIONAL_KINDS（ADR 0029 先例）。
//
// 1.0.30：发布链路验证版（**引擎源码相对 1.0.29 零变更**）。
//   本版不含任何语义/引擎改动——九个生态仓相对 v1.0.29 逐字节相同。
//   目的是用一轮真实列车验证 platform#82 / aster-api#338 的修复：
//   列车 dispatch 现在传 trainId，aster-api 的 image-pin 不再被静默 skip，
//   且新增 pin-closure-guard 在「该 pin 而没 pin」时显式失败。
//   lockstep 设计本就允许无变更模块跟发，故整体 bump。
//
// 1.0.29：引擎缺陷修复发版。
//   core：BOM 剥离（#158）、连续 not 深度守卫（#157）、组合记号纳入词边界
//   判定（hi#73，修 Hindi 标识符被关键词词内替换）。ts 侧同步 BOM 列号对齐、
//   LSP 租户词汇注册抽成可测模块（#161）。另含 ADR-0037 mapping 层（MappingIR/
//   ProofIR/SourceIR/QuantityIR verifier、Stable Node ID、显式 rename 声明）与
//   ReDoS 加固——均为内部 IR 层，未改公开 CNL 语法，故取补丁位。
//
// 1.0.28：文案同步发版（无语义变更）。
//   新增 AI 拒绝原因文案 8 键（ai.error* + goVerifyEmail）。
//   用户报「点 AI 生成只在控制台看到 403，界面无原因」——服务端早已给出精确
//   原因码，前端此前把响应体当纯文本，用户读不到（cloud#438 已修解析）。
//   但**线上实际显示什么由 aster-api 的 /api/v1/messages 决定**（它优先于 npm 包），
//   故必须同步 classpath 副本（api#292）并重新部署；副本受 lockstep parity 约束
//   （比对 sibling tag），必须切新 tag。引擎/语义零改动。
// 1.0.34：服务端类型检查接入前置（2026-10-23 生产 E2E）。core：Java 检查器与 TS 对齐
// （裸枚举变体、推断返回类型进签名、字段路径 E101/E011、命名空间调用目标）；core 与 ts 同步把
// 未标类型的 context/metadata 推断为 Map<Text, Unknown> 并允许字段路径穿过 Map（IR 协议同步，
// ts npm 1.0.36）；test 新增 context 点访问 parity 样本。aster-api 据此在全部编译路径强制类型检查。
//
// 1.0.35：2026-10-25 aster-lang 问题清扫。core：DualEngineCrossLangTest 支持 expectError（#192）、
// Decimal 展开位数按真实长度计算（#185，与 aster-cloud canonical-json 同步）、Java 侧语义桥主链路
// 与 verifier 判定门禁（#213）；truffle：死锁判定以任务终态为准（#131）、已知规模 builtin 物化前
// 准入扣分配预算（#126，与 ts 同步）；locales：lexicon parity 门禁在 CI fail-closed（#94）、zh
// 括号函数头变换器消除二次回溯（128KB 源码原约 54 秒）；test：soc2 样本通过 Java 类型检查、
// bridge-cases 新增两例（npm 包与生态共用 v* tag，本轮不发，见 aster-lang-test#168）；ts npm 1.0.37：E104 块作用域与 lambda 作用域对齐、变换器
// 字符串掩码、zh 括号函数头、分配预算准入、语义桥候选区间改为原文坐标。
//
// 1.0.36：领域词汇按位置解析（ADR 0051）。不做向后兼容：解析前全局文本替换被删除，改为
//   解析后两阶段名称解析（R1 声明位置 / R2 引用位置），E800–E807/W800–W801 诊断，toolchainId 改为
//   abi=1.1;…;resolver=1;casefold=15.1，source envelope 增加第 5 段（canonicalScopesJson）。
//   locales：Unicode 15.1 简单大小写折叠表（casefold/）与测试向量；内置词汇无父枚举值补齐父枚举
//   （CreditLevel/LoanType/QuoteStatus/RiskLevel）；E8xx 中文诊断文案。core：Java 同构实现
//   （VocabularyScopes、NameResolution、限定枚举成员 E.M 类型检查、EnvelopeVectorsTest）。
//   truffle：Loader 求值 E.M 枚举成员，CnlCompiler 改走 core NameResolution（E8xx 闸门）。
//   test：语料自带词汇格式、tier1 vocab-de/zh/hi parity 样本、envelope 向量；npm 1.1.0
//   （normalizeIr 改为选项对象并新增 includeResolution，签名不兼容，取次版本位）。
//   ts npm 1.1.0：R1/R2、buildVocabularyScopes/resolvePolicyTypes、LSP 按角色悬停与补全；包入口不再导出
//   lowerModule 与未检查的 resolveAndLower（只保留带检查的出口），属 API 不兼容，取次版本位。
//   runtime/validation/hi 源码无变更，lockstep 重新打 tag。
//
// 1.0.37：ADR 0051 跟进修复。core：workflow 多元素（第二个 step、compensate、retry、timeout）与 match
//   缩进块分支的 Java 语法与 TS 对齐（#218）；Core IR 中 workflow 未设置的 retry/timeout/compensate
//   省略而非输出 null（#219，与 TS 一致）；天城文可作类型名与枚举值（#220，裁决 R53）；重复/歧义的
//   枚举变体、Data 字段与构造字段诊断报在条目位置。locales：zh 诊断译文补齐 95 条、de 新增 95 条，
//   overlay 移到 overlays/<语言 id>/，修复多个语言包同处 classpath 时同名 overlay 互相遮蔽（#107/#108）。
//   hi：hi-IN 诊断 overlay 注册与 95 条译文。truffle：反序列化 Block 分支体、Scope 局部遮蔽（#149）。
//   test：签名与字段类型的 written/role 纳入 parity 比较，新增 workflow/函数类型/天城文 tier1 样本；
//   npm 1.2.0（normalizeIr 在 includeResolution 下比较更严格，取次版本位）。ts npm 1.2.0：函数类型
//   语法 (T1, T2) -> R（#247）、格式化器保留 Type X as T（#246）、诊断随语言包 overlay 本地化
//   （locales#107）、LSP 修复（#248）；只在函数体出现的显式 of T 保留到 typeParams（Core IR 变化，
//   裁决 R54：不递增 RESOLVER_VERSION）。runtime/validation 源码无变更，lockstep 重新打 tag。
//
// 1.0.38：Set 语句与块作用域写回（ADR 0052）。core：`Set x to …` 解析为对已有 Let 绑定的赋值，不再
//   改写成 Let 声明；首次声明用 Set 报 E101，Set 形参、模式绑定与 lambda 捕获变量报 E001（#225）；
//   词法器合成的 token 带来源，缺句末标点紧接文件末尾时不再 NPE（#226）；CoreIrFingerprintCli 输出
//   诊断位置（#224）。locales：zh/de/en 词法表不再把 Set 改写成 Let（#112）；德语快照回滚按钮文案
//   修正（#111，ui-messages npm 1.0.25）。truffle：成员缺失抛结构化 MissingMemberException（#154）；
//   延迟重试 poller 不再读写 workflow 确定性时钟，轮询出错时退避（#155）。test：Set 块作用域写回与
//   规则作函数值 tier1 样本，带词汇样本比较两引擎诊断起始行（#179–#181）；npm 包无变更，保持 1.2.0。
//   ts npm 1.2.3（已含 Set 写回）先行发布，本次不变。runtime/validation/hi 源码无变更，lockstep 重新打 tag。
//
// 1.0.39：ADR 0051 R55 与块作用域跟进。core：无大小写文字（中文/天城文等）的裸模式名按成员 / 绑定
//   统一 IR 形态（#230，R55；上线前两库 R55 扫描 0 行，2026-11-05）；规则调用实参检查与 TS 对齐，
//   调用非函数局部名报 E001（#231）。locales：语法错误文案目录迁入 locales 作为唯一真相源，德语快照
//   diff 文案改 Sie 形式（#115/#117，ui-messages npm 1.0.26 已先行发布，本次不变）。truffle：case 分支 /
//   Scope 内同名 Let 与模式绑定遮蔽外层（#158）；单段 builtin 名与 core CallTargetBuiltins.NAMES 双向
//   核对（#160）。test：块作用域遮蔽与中文裸模式名 tier1 样本（#183）；npm 包无变更，保持 1.2.0。
//   ts npm 1.2.4（ts#278）由本次列车 ts:npm 层发布。runtime/validation/hi 源码无变更，lockstep 重新打 tag。
//
// 1.0.40：类型检查放宽与作用域跟进。core：按名字推断的类型视为未知、Return 与实参同一套可赋值规则
//   （数值拓宽、T → T?）、builtin 单词别名、workflow step / compensate 体各开一层作用域（#237，
//   含 #232 #233 #234 #236；上线前两库 R55 扫描与 scan-typecheck-followups 均 0 行，2026-11-05/06）。
//   truffle：workflow step / compensate 体词法作用域、局部函数值优先于同名规则（#163）；T? 裸值匹配
//   When Some(v)、null 匹配 When None，别名同步测试（#164）。locales：de-DE ui-messages 残余 du 形式
//   统一为 Sie（#119），ui-messages npm 1.0.26 → 1.0.27 由本次列车 locales 层发布。test：同名规则与
//   局部闭包、workflow step 作用域 tier1 样本（#185）；npm 包无变更，保持 1.2.0。ts npm 1.2.5（ts#280）
//   由本次列车 ts:npm 层发布。runtime/validation/hi 源码无变更，lockstep 重新打 tag。
//
// 1.0.41：返回路径类型检查与 Decimal 整数模式。core：每条 Return（任意嵌套 If / Match 分支）都与声明
//   返回类型按可赋值规则比对，E003 报在该 Return 语句上，不再只比较函数级推断结果（#240，Fixes #239；
//   这是收紧，内层分支 Return 类型不符的存量策略会新增 E003）。truffle：整数模式 When N 对 Decimal 值按
//   BigDecimal.compareTo 精确数值匹配（#167，此前 Decimal 上的整数模式永远落空）。locales：evaluation-
//   diagnostics 评估诊断文案目录迁入 locales（随 aster-lang-locales-en jar 与 ui-messages npm 分发，#121，
//   aster-api#445/#451 的前置），ui-messages npm 1.0.27 → 1.0.28 由本次列车 locales 层发布。ts npm 1.2.6
//   （ts#284 #285 #286 #287 #288 #290）由本次列车 ts:npm 层发布。runtime/validation/hi/test 源码无变更，
//   lockstep 重新打 tag；test npm 包无变更，保持 1.2.0。
//
// 1.0.42：冠词保护声明名与诊断文案。core：Canonicalizer 按语法位置保护 Define/Rule 声明名，不再把
//   声明名开头的 a/an/the 当冠词删掉（#244，Fixes #243；canonicalize 结果变化，以冠词开头的声明名存量
//   策略的规范化源码会不同）。locales：模块解析诊断 module.* 文案与语法目录 token.* 名词（#124），
//   ui-messages npm 1.0.28 → 1.0.29 由本次列车 locales 层发布。ts npm 1.3.0（ts#293 新增 functions[].entry 与
//   resolveSpelling 导出、#296 放宽未知能力 / await 参数个数、#298 冠词、#299 overlay 重新生成、#300 删除
//   legacyCode，破坏性）由本次列车 ts:npm 层发布。补记 1.0.41：解析诊断码 E050–E069（core#241 / ts#291，
//   R56）与顶层统一命名空间 E807（R57）已随 1.0.41 发布。runtime/validation/hi/truffle 源码无变更，lockstep
//   重新打 tag；test 仅新增 tier1 样本（#187），npm 包无变更，保持 1.2.0。
//
// 1.0.43：lowering 诊断码与嵌套深度守卫。core：共享码表新增 lowering 诊断码 E600–E606（#248，与 ts#303
//   同车次）；解析嵌套深度守卫 AsterCustomLexer.MAX_NESTING_DEPTH / AstBuilder.MAX_EXPR_DEPTH 300 → 64 并改为
//   public（#249，aster-api#472：1MB 线程栈上 157–196 层括号即栈溢出，原上限形同虚设；嵌套 >64 的存量策略会
//   新增 E054）。locales：E051–E069 句型模板与 token 名词、de E061/E062 句式、删除 4 条死 module.* 文案（#127）；
//   E600–E606 zh / de 译文（#128），ui-messages npm 1.0.29 → 1.0.30 由本次列车 locales 层发布。hi：E600–E606
//   hi-IN 译文（#96，只改 Maven overlay，ui-messages-hi npm 无变更，保持 1.0.24）。ts npm 1.4.0（ts#303 新增
//   compile() 公开字段 loweringDiagnostics、loweringErrors 标 @deprecated、overlay 重新生成；#305 表达式嵌套上限
//   64、类型递归上限保持 300）由本次列车 ts:npm 层发布。runtime/validation/truffle 源码无变更，lockstep 重新
//   打 tag；test 仅 parity 记录，npm 包无变更，保持 1.2.0。
//
// 1.0.44：类型嵌套守卫、未知效果名与规则输入引用（R62）。core：类型嵌套改在词法期守卫，上限 64 先于栈溢出
//   报 E054（#253，Fixes #250；类型嵌套 >64 的存量策略会新增 E054）；治理 lowering 为每条 Verdict 规则产出
//   Func.inputRefs，新增 E708（档案要求 verifiedInputs 而规则 inputRefs 为 ["*"]），控制注册表 1.2.0 增
//   requires.verifiedInputs（#257，R62；两个档案都为 false，本版本不新增诊断）；注册表 requires 含未知键时
//   加载成功且忽略（#252，R62 X1）。locales：控制注册表 1.2.0 与 E708 zh / de 译文（#130，只改 Maven 制品，
//   ui-messages npm 无变更，保持 1.0.30）。hi：E708 hi-IN 译文（#98，只改 Maven overlay，ui-messages-hi npm
//   无变更，保持 1.0.24）。ts npm 1.5.0（ts#308 接受任意基效果名、未知效果按 pure
//   检查并保留在 IR，Fixes #304；#311 类型嵌套上限 300 → 64；#312 Core.Func.inputRefs、E708 与注册表 1.2.0；
//   #307 注册表未知键）由本次列车 ts:npm 层发布。test：未知效果名与 R62 输入引用 tier1 样本（#191 #192），npm
//   包无变更，保持 1.2.0。runtime/validation/truffle 源码无变更，lockstep 重新打 tag。
//
// 1.0.45：控制注册表 1.3.0 翻转（ADR 0046 §11.4 ⑦，X4）与重放门面线程安全。locales：控制注册表 1.3.0，
//   eu-ai-act-high-risk.requires.verifiedInputs → true（governed 仍为 false；#132，只改 Maven 制品与 controls，
//   ui-messages npm 无变更，保持 1.0.30）。core：内置注册表副本逐字同步 1.3.0（#260）——声明
//   eu-ai-act-high-risk 且 inputRefs 为 ["*"] 的规则从此报 E708（error 级），aster-api 对该档案的
//   from-evidence 要求已签名事实，否则 DENY unverified_input。runtime：重放门面（时钟 / UUID / 随机数）
//   实例方法加 synchronized，修复并发记录竞态（#77，truffle DelayedTaskTest.testConcurrentScheduling 间歇失败）。
//   ts npm 1.6.0（ts#315 内置注册表副本 1.3.0；默认注册表变化会让既有源码出现新的 error 级诊断，故取 minor）
//   由本次列车 ts:npm 层发布。core#245 不随本列车（另排）。validation/test/hi/truffle 源码无变更，lockstep
//   重新打 tag；hi:npm 1.0.24、test:npm 1.2.0 无变更，幂等 skip。
//
// 1.0.46：Core IR v2（ADR 0055，破坏性变更，不做 v1 兼容）。两引擎产出同一种 schemaVersion 2 的规范 IR。
//   locales：v2 JSON Schema 与负例夹具（core-ir/，verifyCoreIrSchema 挂到 check），新增诊断码 E213
//   EFFECT_PARAM_SHADOWS_BUILTIN 与 E900 PARSE_DUPLICATE_ANNOTATION_ARG 的码表与 zh / de 译文（#135）；
//   syntax-diagnostics 新增 parseTimeBudget（E054 时间预算超时整句文案，#134，core#259）——两者都改了随
//   ui-messages npm 分发的 syntax-diagnostics 目录，ui-messages npm 1.0.30 → 1.0.31 由本次列车 locales 层发布。
//   core：CoreModel v2 形状、严格读方 CoreIrJson（版本预检 → schema → 严格绑定 → 不变式）、CanonicalJson
//   规范输出、lowering 产出 v2、注解读方迁到 args、效应参数 <E>（E210 / E211 / E213）（#262）。truffle：
//   严格读入 v2，删除 PatCtor.names 与首字母大写启发式，效应名小写（#173）。hi：E213 / E900 hi-IN 译文（#101，
//   只改 Maven overlay，ui-messages-hi npm 无变更，保持 1.0.24）。ts npm 2.0.0（ts#317 产出 v2、serializeCoreIr /
//   readCoreIr、删除 v1 序列化 API）与 test npm 2.0.0（test#199 删除 IR 归一化导出，门禁改为 schema 校验加
//   逐字节比较）分别由本次列车 ts:npm、test:npm 层发布。runtime/validation 源码无变更，lockstep 重新打 tag。
//
// 1.0.47：推断值统一（ADR 0056，破坏性变更）。两引擎对未写明的类型与能力产出相同的 IR，Core IR v2 值层豁免表清空
//   （aster-lang-test#195–#198）。locales：推断命名规则表 type-inference/naming-rules.json 与 497 条共用测试向量
//   （verifyTypeInferenceRules 挂到 check），删除三个语言包 overlay 的 typeInferenceRules（#137；未动 ui-messages /
//   syntax-diagnostics / evaluation-diagnostics，ui-messages npm 保持 1.0.31）。core：工作流能力检查只看显式能力
//   （V2）、推断返回类型统一为占位 Unknown（V1-ret、V4）（#265）；形参 / 字段推断改读 locales 命名规则表并按约束
//   修正（V1-类型，#267）；Lambda.captures 只列外层局部（V3，#268）。truffle：captures 只列外层局部时全局名回落的
//   加载测试（#177）。test：删除 V1–V4 豁免，新增 captures / 推断字段约束 / 工作流裸 io 能力 tier1 样本（#201–#203）
//   ——npm 包只新增语料样本，test:npm 2.0.0 → 2.1.0。ts npm 3.0.0（ts#321–#323 同一组推断值变化，公开类型 Lexicon
//   删除 typeInferenceRules，故取 major）由本次列车 ts:npm 层发布。runtime/validation/hi 源码无变更，lockstep
//   重新打 tag；hi:npm 1.0.24 无变更，幂等 skip。
//
// 1.0.48：解析器修复与双引擎 parity 清扫（ADR 0056 修订 A1）。core：`X of` 按名字定元数（list / option 恰一个参数，
//   result 至多两个），result / option 产出 Result / Option 节点而非 TypeApp；函数类型与括号类型合并、类型内预测
//   切 SLL（病态类型从数十秒降到毫秒）；解析器层嵌套守卫（E054）（#270，#256 #254 #255）。括号类型表里开放元数
//   `X of A, B` 的歧义逗号报 E064；manifest 的 io / cpu 类别键按 capabilities.json 展开；E601 改为保留码（#271）。
//   truffle：宿主调用入口按声明安装 effect 权限，workflow / Start 的 worker 线程进入 context（#179，#174 #175）。
//   test：X of 元数 / 边界 tier1 样本与规则头单行、歧义逗号等必拒样本（#208 #209）——npm 包只新增语料样本，
//   test:npm 2.1.0 → 2.2.0。ts npm 3.1.0（ts#326 #327：规则头单行、X of 边界、E064、LSP 效果快修、manifest 能力
//   检查与 core 一致；公开导出无删减，新增 error 级诊断按 ADR 0046 §11.7 第 11 条取 minor）由本次列车 ts:npm 层
//   发布。locales / hi / runtime / validation 源码无变更，lockstep 重新打 tag；ui-messages 1.0.31、
//   ui-messages-hi 1.0.24 无变更，幂等 skip。aster-api 的 pin 首次由列车在 L4 接管（ADR 0053 修订 A1，
//   release-plan 的 aster-api:service pinOwner=train）。
//
// 1.0.49：发布门禁改造（ADR 0053 修订 A2）与两组语言修正。A2：全部仓的 release workflow 不再重跑测试，改为发布前
//   要求 main CI 已对该 commit 通过（共享 action require-main-ci-green 与各仓 .github/main-ci-gate.json；forceTests
//   为逃生口）；platform：列车 preflight 增加 main CI 检查，pin PR 的可证实超时按 build-hosted / * 匹配（#127 #128）。
//   core：W709 GOV_PII_RETURNED_AS_TEXT——@pii 输入字段流入返回的 Text 给不阻断警告（#276，aster-cloud#772）；
//   签名与类型别名语法对齐 ts（尖括号泛型 E056、大写形参名 E055、Type 别名关键词、前缀 maybe）（#277，ts#328）；
//   语料测试在 CI 中缺语料即失败（#275）。locales / hi：W709 的 zh / de / hi-IN 诊断译文与共享码表（#142、#107，
//   只改 Maven overlay 与测试基线，ui-messages 1.0.31、ui-messages-hi 1.0.24 无变更，幂等 skip）。test：ts#328 的
//   tier1 与必拒样本（#213）——npm 包只新增语料样本，test:npm 2.2.0 → 2.3.0。ts npm 3.2.0（ts#331 W709、ts#332
//   形参前置注解 / result of A or B 报 E062 / maybe of 报 E061；公开导出只增不删，新增 warning 与新拒绝写法按
//   ADR 0046 §11.7 第 11 条取 minor）由本次列车 ts:npm 层发布。runtime / validation / truffle 源码无变更，
//   lockstep 重新打 tag。
//
// 1.0.50：ADR 0059 策略包导出（P1 / P2 E1）与两组双引擎 parity 修正。core：生产编译路径进公共包 aster.core.embed
//   （#280）；大写规则名 / 字段名报 E055、USE 大小写不敏感、_ 开头标识符报 E050、X of A 后的裸小写名字报 E055（#278，
//   ts#334）；zh「包含」固定规范化成 with，IR 不再随 JVM 进程变化（#281）；词法空白只认 ASCII 的 parity 夹具（#283，
//   ts#348）；登记导出码 E730–E735、E737–E739（#284）。truffle：生产值编解码与沙箱执行器进公共包 aster.truffle.embed
//   （#184）、导出 builtin 白名单（#186）、JVM aster CLI 子项目与 fat jar / 启动脚本 Release 资产（#185 #187 #189–#192），
//   内置信任锚改为生产导出公钥 export-2026-11a（#193）。locales / hi：导出码的 zh / de / hi-IN 译文与共享码表（#144、
//   #108，只改 Maven overlay 与测试基线，ui-messages 1.0.31、ui-messages-hi 1.0.24 无变更，幂等 skip）。test：ts#334 /
//   ts#348 的 tier1 与必拒样本（#215 #225）——npm 包只新增语料样本，test:npm 2.3.0 → 2.4.0；包格式 v1 一致性夹具
//   （#216–#223 #227）与 CoreIrEvalCli 修正（#224）不进 npm 包。ts npm 3.3.0（包格式 v1 的 aster CLI 与单文件 runner、./layout /
//   ./runner / ./package-check 子路径、导出码、ts#334 / ts#348 parity 的新拒绝写法；公开声明只增不删，按 ADR 0046
//   §11.7 第 11 条取 minor）由本次列车 ts:npm 层发布。platform：gate-scan 工具入库（#131）、docs-only 判定 action
//   （#132）。runtime / validation 源码无变更，lockstep 重新打 tag。
//
// 1.0.51：双引擎 parity 修正与 LSP 词汇修复。core：引号归一只改写字符串定界符，字符串字面量里的弯引号原样保留、
//   "abc” 不再被当作闭合（报未闭合字符串）；字面量宏值的 \ 与 " 转义后展开（#287，ts#347 / ts#345）；
//   SemanticTokenKind.CATEGORIES 按书写顺序遍历，LexiconExporter 导出的 categories 不再随 JVM 进程变化（#286，#282）。
//   locales：zh 令…定义为 变换器的空白只认空格、\t 与 U+3000，绑定不跨行（#146，locales#143；只改 Maven 模块，
//   ui-messages 1.0.31 无变更，幂等 skip）。test：上述三项的 tier1 与必拒样本（#229）——npm 包只新增语料样本，
//   test:npm 2.4.0 → 2.5.0。ts npm 3.4.0（ts#361 引号 / 字面量宏与 core 同规则、ts#363 CLI / LSP 依赖改回
//   dependencies、ts#366 LSP 对 en-US 文档应用租户词汇；公开导出不变，但 "abc” 这类既有源码新报 error 级诊断，
//   按 ADR 0046 §11.7 第 11 条取 minor）由本次列车 ts:npm 层发布。platform / runtime / validation / hi / truffle
//   源码无变更，lockstep 重新打 tag；ui-messages-hi 1.0.24 无变更，幂等 skip。
//
// 1.0.52：别名校验 v2（ADR 0060，aster-cloud#830）。core：UserAliasValidator v2——zh 下 2–8 个汉字的单词别名放行、
//   FUNC_PRODUCE 入结构词档、别名不得等于字面量宏触发词；新码 E808 ALIAS_IDENTIFIER_COLLISION（别名名字守卫：
//   AST 名字折叠后等于汉字单词别名或被别名化 kind 的英文拼写即失败）；《静夜思》原诗证明（#291）。locales / hi：
//   E808 的 zh / de / hi-IN 译文与共享码表 136 码（#149、#111，只改 Maven overlay 与测试基线，ui-messages 1.0.31、
//   ui-messages-hi 1.0.24 无变更，幂等 skip）。test：envelope 共享向量 envelope.literal-macro（#231）——npm 包只追加
//   语料向量，test:npm 2.5.0 → 2.6.0。ts npm 3.5.0（ts#369 与 core 同规则的别名校验 v2 与 E808；新 error 级诊断、
//   既有别名集新拒绝，./browser 的 CompileOptions 新增 astGuard，按 ADR 0046 §11.7 第 11 条取 minor）由本次列车
//   ts:npm 层发布。platform / runtime / validation / truffle 源码无变更，lockstep 重新打 tag。
//
// 1.0.53：策略包显示排版（ADR 0059 修订 4）与 Wave B 双引擎 parity 修正。core：纯 Java aster.core.layout——包格式 1.1
//   排版规则 L1–L9 与反向映射（#297），UserAliasValidator.operatorKinds()；类型别名引导词 TYPE_ALIAS（#301，ADR 0058
//   修订 2）；字面量触发词与关键词同形时关键词优先（#299，ADR 0060 修订 1）；字面量宏内容允许 \、" 与弯引号（#300）；
//   裸小写类型名与歧义分隔符报 E055、规则体 / If 块头后可空行（#302，ADR 0056 修订 A4）；W709 识别名字前的 @pii（#296）；
//   规范化后为空的源码按空源码拒绝（#295）；ANTLR 工具链不再进运行时 classpath 与发布的 pom（#294）。truffle：JVM aster
//   CLI 包格式 1.1——show、run --display、verify 的 display / display-ir（#198）。locales / hi：TYPE_ALIAS 拼写（#153、
//   #114），zh 函数头与 结果为 只认词法空白（#152；只改 Maven 模块，ui-messages 1.0.31、ui-messages-hi 1.0.24 无变更，
//   幂等 skip）。test：Wave B 的 tier1 正例与必拒样本（#236 #237 #239–#242）——npm 包只新增语料样本，test:npm
//   2.6.0 → 2.7.0；包格式 1.1 显示排版真相源（#234）与 package-v1 夹具（#235）不进 npm 包。ts npm 3.6.0（包格式 1.1 的
//   show / run --display 与 ./layout 包规则（#373）、TYPE_ALIAS 与上述 parity 修正；公开声明只增不删，既有源码新报
//   error 级诊断，按 ADR 0046 §11.7 第 11 条取 minor）由本次列车 ts:npm 层发布。platform：共享 setup-gradle-cached
//   与列车 api-parity 预检（#139）、gate-scan --with-vocab 与 vocab-check（#140）。runtime / validation 源码无变更，
//   lockstep 重新打 tag。
//
// 1.0.54：请求级解析额度迁入 core（aster-api#489，解阻 aster-api 删除解析器副本）。core：aster.core.embed.ParseBudget
//   新增公开的 withinRequestAllowance(Duration, Work) 与 Work 接口（请求级额度栈，按默认预算发起的解析在结束时计入额度，
//   E808 归因探测共用额度剩余），InProcessCnlParser 接入；CnlError 诊断渲染测试从 aster-api 迁入（#304）。公开 API 只增；
//   未传额度时行为与 1.0.53 相同。platform：gate-scan java-gate 按侧选解析器（aster-api 删除副本后回落 core）与
//   --aliases（#143），verify-jar-contents 忽略 -test-fixtures 附属 jar（#142）。test：package-v1 CI 固定 ts v3.6.0、
//   删除 pending-ts-release.json、开启 --strict-formats（#244；只改 CI、conformance/ 与 scripts/，不进 npm / jvm 包，
//   test:npm 2.7.0 无变更）。runtime / validation / locales / hi / truffle 源码无变更，lockstep 重新打 tag；ts npm 3.6.0
//   （v3.6.0 后 main 无提交）、ui-messages 1.0.31、ui-messages-hi 1.0.24 无变更，本次不发布。
//
// 1.0.55：Wave C 双引擎 parity 收尾（core#298、ts#357 第 3 行、ts#380、test#174 第 5 项、aster-api#594）。core：
//   the result is 之后的分隔空白只认空格与 tab（#306，收紧：VT / FF / 换行不再被改写）；声明头与语句中间换行的 parity
//   夹具（#307）；类型别名右侧在 TYPE 位置解析，查不到报 E800（#308，收紧）；类型别名前的声明级注解报 E056（#309，
//   收紧）；任何块头之后都可以先空行再写块（#310，放宽）；名称解析前后检查解析预算、各阶段线性度模糊测试（#311，
//   预算之内结果不变）。公开 API 不变。truffle：GraalVM native 可执行构建与 native conformance 门（#201，ADR 0063；
//   org.graalvm.sdk 组对齐 catalog graalvm 版本、native-image 元数据改为生成，不发布 native 产物）；确定性调用深度上限
//   10 000，与 Node CLI 同计数、同报错（#202，ADR 0063；求值线程栈 64 MiB）。test：Wave C 语料（#252）。ts npm
//   3.6.0 → 3.7.0（minor：既有源码新拒绝 E063 / E052 / E800，en-US / de-DE 启用 result-is 与 english-possessive；
//   公开 exports 不变）；test:npm 2.7.0 → 2.8.0（minor：语料只增，另有两份 zh 样本改用汉字标识符）。runtime /
//   validation / locales / hi 源码无变更，lockstep 重新打 tag；ui-messages 1.0.31、ui-messages-hi 1.0.24 无变更，本次不发布。
//
version = "1.0.55"

catalog {
    versionCatalog {
        // ===== single source of truth for ecosystem versions =====
        // Current published baseline of every first-party JVM module.
        //
        // ★这里只写“机制”，不写具体版本号的来历（issue #76）。
        //   此前这段写的是「1.0.4 ecosystem-wide for the keyword-alias-mechanism
        //   release」，而下面的值早已是 1.0.28 —— 注释描述的是某一次历史发版，
        //   却紧挨着一个完全不同的当前值，第一次读到这里的人会被误导。
        //   版本演进史留在文件头 changelog 一处即可，不要在声明处复述。
        //
        // 机制：catalog 对所有一方 JVM 模块使用**同一个**版本号，故每次发版
        // 全部模块 lockstep 重新打 tag —— 即便某些模块（runtime/truffle/
        // validation/locales）本次无代码变更，也会重新发布以保持生态一致。
        version("asterLang", "1.0.55")

        // ===== third-party ecosystem versions =====
        // These were previously hardcoded across consumer repos and had begun to
        // drift (audit #32): quarkus-bom 3.32.2 in -runtime vs 3.37.0 in aster-api;
        // assertj 3.27.3 (-core) / 3.27.6 (-validation) / 3.27.7 (aster-api). Governing
        // them here gives consumers one aligned value to import. Where consumers
        // diverged the NEWER value is chosen as the catalog target; runtime/validation
        // and other laggards should adopt these in a follow-up migration (this platform
        // PR does not touch consumer repos).
        version("junit", "6.0.0")      // org.junit.jupiter:junit-jupiter (uniform across consumers)
        version("quarkus", "3.37.0")   // quarkus-bom: newer of 3.32.2 (-runtime) / 3.37.0 (aster-api)
        version("antlr", "4.13.1")     // ANTLR tool + runtime (aster-lang-core)
        version("assertj", "3.27.7")   // newest present: 3.27.3 / 3.27.6 / 3.27.7 across consumers

        // ★GraalVM：全部组件必须 lockstep（aster-api#193）。
        //   混搭版本的典型症状是 NoClassDefFoundError → ExceptionInInitializerError
        //   at Engine.java:559（实测于单独升 polyglot 的 PR）。
        //   此前 aster-api 与 aster-lang-truffle 各自硬编码字面量，
        //   曾出现 api 内部 25.0.3/25.0.4 混用 + 跨仓 25.0.1 落后。
        //   收进目录后由此处统一，消费仓改用 asterLibs.graalvm.* 别名。
        version("graalvm", "25.0.4")

        // ===== libraries (all reference the version above) =====
        library("core", "cloud.aster-lang", "aster-lang-core").versionRef("asterLang")
        library("runtime", "cloud.aster-lang", "aster-lang-runtime").versionRef("asterLang")
        library("truffle", "cloud.aster-lang", "aster-lang-truffle").versionRef("asterLang")
        library("validation", "cloud.aster-lang", "aster-lang-validation").versionRef("asterLang")
        library("test", "cloud.aster-lang", "aster-lang-test").versionRef("asterLang")

        // GraalVM / Truffle 组件（全部 versionRef("graalvm")，保证 lockstep）
        library("graalvm-polyglot", "org.graalvm.polyglot", "polyglot").versionRef("graalvm")
        library("graalvm-sdk", "org.graalvm.sdk", "graal-sdk").versionRef("graalvm")
        library("graalvm-truffle-api", "org.graalvm.truffle", "truffle-api").versionRef("graalvm")
        library("graalvm-truffle-runtime", "org.graalvm.truffle", "truffle-runtime").versionRef("graalvm")
        library("graalvm-truffle-compiler", "org.graalvm.truffle", "truffle-compiler").versionRef("graalvm")
        library("graalvm-truffle-dsl-processor", "org.graalvm.truffle", "truffle-dsl-processor").versionRef("graalvm")
        library("graalvm-compiler", "org.graalvm.compiler", "compiler").versionRef("graalvm")

        // Locale packs from aster-lang-locales (multi-module).
        // 新坐标 aster-lang-locales-{en,zh,de}：从 aster-lang-locales 仓发布（自有坐标，
        // 无 GitHub Packages 422）。老坐标 aster-lang-{en,zh,de} 归属已归档仓、冻在 1.0.2，
        // 不再随生态级联。同 hi 用独立坐标的先例。
        library("en", "cloud.aster-lang", "aster-lang-locales-en").versionRef("asterLang")
        library("zh", "cloud.aster-lang", "aster-lang-locales-zh").versionRef("asterLang")
        library("de", "cloud.aster-lang", "aster-lang-locales-de").versionRef("asterLang")
        // Hindi (hi-IN) ships from its own repo (aster-lang-hi) as a hot-pluggable
        // SPI pack — extracted from core's builtins so ops can load/unload it.
        library("hi", "cloud.aster-lang", "aster-lang-hi").versionRef("asterLang")

        // ===== third-party libraries =====
        // Reference the third-party versions declared above so consumers can
        // replace their hardcoded literals with aliases (e.g. asterLibs.junit.jupiter).
        library("junit-jupiter", "org.junit.jupiter", "junit-jupiter").versionRef("junit")
        library("quarkus-bom", "io.quarkus.platform", "quarkus-bom").versionRef("quarkus")
        library("antlr", "org.antlr", "antlr4").versionRef("antlr")
        library("antlr-runtime", "org.antlr", "antlr4-runtime").versionRef("antlr")
        library("assertj-core", "org.assertj", "assertj-core").versionRef("assertj")

        // ===== bundles =====
        // The first-party locale packs, for consumers that load them all via
        // SPI (aster-api, aster-lang-truffle runtime). Includes hi so the
        // backend keeps offering Hindi now that it's an SPI pack, not a builtin.
        bundle("locales", listOf("en", "zh", "de", "hi"))
    }
}

publishing {
    publications {
        create<MavenPublication>("maven") {
            from(components["versionCatalog"])
            artifactId = "aster-lang-platform"
        }
    }
    repositories {
        maven {
            name = "GitHubPackages"
            url = uri("https://maven.pkg.github.com/aster-cloud/aster-lang-platform")
            credentials {
                username = System.getenv("GITHUB_ACTOR") ?: ""
                password = System.getenv("GITHUB_TOKEN") ?: ""
            }
        }
    }
}
