package gate;

import java.io.File;
import java.io.OutputStream;
import java.io.PrintStream;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.regex.Pattern;

/**
 * 发布列车门禁扫描的 Java 侧（生产编译路径：aster-api InProcessCnlParser + TypeChecker，引擎旧版 vs 新版）。
 *
 * <p>只依赖 JDK：两侧各建一个隔离的 URLClassLoader（各自的 replay + core + truffle + 词法包），经反射调用
 * {@link Worker}。输出只含 id / kind / lexicon / 诊断码 / IR 键路径，从不打印源码；调用引擎期间
 * System.out / System.err 指向空流，防止引擎日志带出源码片段。
 *
 * <p>用法：java -cp &lt;本工具 classes&gt; gate.Main --old-cp &lt;文件&gt; --new-cp &lt;文件&gt;
 * --sources &lt;jsonl&gt; [--sources …] [--ts-old-sources-ok N --ts-sources-total M [--max-gap-pct P]]
 *
 * <p>退出码：0 = 无需复核项；1 = 有需复核项；2 = 用法错误；3 = 环境错误（classpath 条目缺失、lexicon 未注册、
 * 金丝雀失败、导出损坏、与 ts 扫描的「旧版可编译源数」差距过大）——3 一律不得当作通过。
 */
public final class Main {
    /** 生产支持的全部 lexicon；生产库不存策略语言，每份源在每个 lexicon 下各编译一次。 */
    static final String[] LEXICONS = {"en-US", "zh-CN", "de-DE", "hi-IN"};
    /** ADR 0056 修订 A1 §4 的预筛正则（有少量误报，仅作交叉核对）。 */
    private static final Pattern E064_PREFILTER =
        Pattern.compile("\\(\\s*[^()]*\\b(?:result|[A-Z]\\w*)\\s+of\\s+[^(),]+,");
    private static final String CANARY = String.join("\n",
        "Module gate.canary.",
        "",
        "Rule ping given x as Int, produce Int:",
        "  Return x.",
        "");
    /** 只在列（origin.start.col / origin.end.col）上不同的 IR 差异单列一组，便于识别纯位置变化。 */
    private static final Pattern COL_PATH = Pattern.compile("(^|\\.)origin\\.(start|end)\\.col$");
    private static final int DEFAULT_MAX_GAP_PCT = 5;

    /** 报告用的真实标准输出；System.out / System.err 在启动时换成空流。 */
    private static final PrintStream OUT = System.out;
    private static final PrintStream ERR = System.err;

    private final Side oldSide;
    private final Side newSide;

    private Main(Side oldSide, Side newSide) {
        this.oldSide = oldSide;
        this.newSide = newSide;
    }

    /** 一侧引擎：隔离类加载器里的 Worker 方法句柄。 */
    private record Side(String label, ClassLoader loader, Method compile, Method diff, Method read, Method lexicons) {
        static Side load(String label, Path cpFile, URL self) throws Exception {
            if (!Files.isRegularFile(cpFile)) throw new IllegalStateException(label + " 侧 classpath 文件不存在：" + cpFile);
            List<URL> urls = new ArrayList<>();
            urls.add(self);
            for (String p : Files.readString(cpFile).trim().split(File.pathSeparator)) {
                if (p.isBlank()) continue;
                File f = new File(p);
                // URLClassLoader 会静默跳过不存在的条目（构建目录被清掉、jar 被删），结果因此不可信
                if (!f.exists()) throw new IllegalStateException(label + " 侧 classpath 条目不存在：" + p + "（重建 classpath）");
                urls.add(f.toURI().toURL());
            }
            ClassLoader cl = new URLClassLoader(label, urls.toArray(new URL[0]), ClassLoader.getPlatformClassLoader());
            Class<?> w = Class.forName("gate.Worker", true, cl);
            return new Side(label, cl, w.getMethod("compile", String.class, String.class),
                w.getMethod("diffIr", String.class, String.class), w.getMethod("readSources", String.class),
                w.getMethod("registeredLexicons"));
        }

        String[] run(String source, String lexicon) throws Exception {
            return (String[]) call(this, compile, source, lexicon);
        }
    }

    /**
     * 在本侧类加载器作为线程上下文类加载器（TCCL）时调用：core 的 LexiconRegistry 用 TCCL 做 SPI 发现
     * zh / de / hi 语言包。TCCL 留在应用类加载器时只发现 core 内嵌的 en-US——zh-CN / de-DE 每次都编译失败
     * （UNCODED），hi-IN 静默回退到 en-US，门禁实际只扫了 en-US（2026-11-17 前的 Java 门禁全部如此）。
     */
    static Object call(Side side, Method m, Object... args) throws Exception {
        Thread t = Thread.currentThread();
        ClassLoader saved = t.getContextClassLoader();
        t.setContextClassLoader(side.loader());
        try {
            return m.invoke(null, args);
        } catch (InvocationTargetException e) {
            throw e.getCause() instanceof Exception ex ? ex : new RuntimeException(e.getCause());
        } finally {
            t.setContextClassLoader(saved);
        }
    }

    /** 命令行参数。 */
    private record Args(String oldCp, String newCp, List<String> sources, Integer tsOldSourcesOk, Integer tsSourcesTotal,
                        int maxGapPct) {
        static Args parse(String[] argv) {
            String oldCp = null;
            String newCp = null;
            List<String> sources = new ArrayList<>();
            Integer tsOldOk = null;
            Integer tsTotal = null;
            Integer maxGap = null;
            for (int i = 0; i < argv.length; i++) {
                String value = i + 1 < argv.length ? argv[i + 1] : null;
                if (value == null || value.startsWith("--")) throw new IllegalArgumentException(argv[i] + " 缺少取值");
                switch (argv[i]) {
                    case "--old-cp" -> oldCp = value;
                    case "--new-cp" -> newCp = value;
                    case "--sources" -> sources.add(value);
                    case "--ts-old-sources-ok" -> tsOldOk = parseCount(value);
                    case "--ts-sources-total" -> tsTotal = parseCount(value);
                    case "--max-gap-pct" -> maxGap = parseCount(value);
                    default -> throw new IllegalArgumentException("未知参数：" + argv[i]);
                }
                i++;
            }
            if (oldCp == null || newCp == null || sources.isEmpty()) {
                throw new IllegalArgumentException("缺少 --old-cp / --new-cp / --sources");
            }
            if ((tsOldOk == null) != (tsTotal == null) || (maxGap != null && tsOldOk == null)) {
                throw new IllegalArgumentException("--ts-old-sources-ok 与 --ts-sources-total 须同时给出；--max-gap-pct 只能与它们一起用");
            }
            return new Args(oldCp, newCp, sources, tsOldOk, tsTotal, maxGap == null ? DEFAULT_MAX_GAP_PCT : maxGap);
        }

        private static int parseCount(String s) {
            try {
                int n = Integer.parseInt(s);
                if (n >= 0) return n;
            } catch (NumberFormatException ignored) {
                // 落到下面统一报错
            }
            throw new IllegalArgumentException("需要非负整数：" + s);
        }
    }

    public static void main(String[] argv) {
        PrintStream sink = new PrintStream(OutputStream.nullOutputStream(), true, StandardCharsets.UTF_8);
        System.setOut(sink);
        System.setErr(sink);
        Args args;
        try {
            args = Args.parse(argv);
        } catch (IllegalArgumentException e) {
            ERR.println(e.getMessage());
            ERR.println("用法：gate.Main --old-cp <文件> --new-cp <文件> --sources <jsonl> [--sources …] "
                + "[--ts-old-sources-ok N --ts-sources-total M [--max-gap-pct P]]");
            System.exit(2);
            return;
        }
        int code;
        try {
            URL self = Main.class.getProtectionDomain().getCodeSource().getLocation();
            Main m = new Main(Side.load("old", Path.of(args.oldCp()), self), Side.load("new", Path.of(args.newCp()), self));
            code = m.scan(args);
        } catch (IllegalStateException e) {
            ERR.println("环境错误：" + e.getMessage());
            OUT.println("result: ERROR (environment)");
            code = 3;
        } catch (Throwable t) {
            // 含 Error（NoClassDefFoundError、ExceptionInInitializerError、OutOfMemoryError…）：缺省处理器会把堆栈打到已换成
            // 空流的 System.err 并以 1 退出，看起来像 REVIEW。这里统一为 3，且只给异常类名（异常消息可能带源码片段）
            ERR.println("环境错误：意外异常 " + t.getClass().getName());
            OUT.println("result: ERROR (unexpected " + t.getClass().getSimpleName() + ")");
            code = 3;
        }
        OUT.flush();
        System.exit(code);
    }

    /** 每侧：lexicon 预检（全部已注册）+ en-US 金丝雀。 */
    private void preflight() throws Exception {
        for (Side s : List.of(oldSide, newSide)) {
            @SuppressWarnings("unchecked")
            Set<String> registered = (Set<String>) call(s, s.lexicons());
            for (String lex : LEXICONS) {
                if (!registered.contains(lex.toLowerCase(Locale.ROOT))) {
                    throw new IllegalStateException(s.label() + " 侧未注册 lexicon " + lex + "（已注册 " + registered
                        + "）——classpath 缺语言包或 SPI 未发现，结果不可信");
                }
            }
            String[] r = s.run(CANARY, "en-US");
            if (!"ok".equals(r[0])) throw new IllegalStateException(s.label() + " 侧金丝雀编译失败：" + r[0] + " " + r[1]);
        }
    }

    private int scan(Args args) throws Exception {
        preflight();
        List<String[]> rows = new ArrayList<>();
        for (String f : args.sources()) {
            for (String[] row : (String[][]) call(newSide, newSide.read(), f)) rows.add(row);
        }
        Map<String, Integer> kinds = new TreeMap<>();
        rows.forEach(r -> kinds.merge(r[1], 1, Integer::sum));
        OUT.println("sources: " + kinds);

        Map<String, List<String>> groups = new LinkedHashMap<>();
        for (String g : List.of("newly-failing-E064", "newly-failing", "throws", "changed-codes", "ir-changed-other",
            "ir-changed-cols-only", "newly-passing", "ir-changed-expected", "e064-prefilter-hits")) {
            groups.put(g, new ArrayList<>());
        }
        Map<String, Integer> histogram = new TreeMap<>();
        // 0 旧 ok，1 新 ok，2 旧过前端（ok + typecheck），3 新过前端，4 比较次数，5 编译总数，6 旧版在任一 lexicon 下过前端的源数
        int[] stats = new int[7];
        for (String[] row : rows) {
            String id = row[0];
            String kind = row[1];
            String src = row[2];
            if (E064_PREFILTER.matcher(src).find()) groups.get("e064-prefilter-hits").add(id + " [" + kind + "]");
            Map<String, String[]> oldRes = new LinkedHashMap<>();
            Map<String, String[]> newRes = new LinkedHashMap<>();
            for (String lex : LEXICONS) {
                String[] o = oldSide.run(src, lex);
                String[] n = newSide.run(src, lex);
                oldRes.put(lex, o);
                newRes.put(lex, n);
                stats[5]++;
                if ("ok".equals(o[0])) stats[0]++;
                if ("ok".equals(n[0])) stats[1]++;
                if (passesFrontEnd(o[0])) stats[2]++;
                if (passesFrontEnd(n[0])) stats[3]++;
            }
            if (oldRes.values().stream().anyMatch(r -> passesFrontEnd(r[0]))) stats[6]++;
            for (String lex : pickLexicons(oldRes, newRes)) {
                stats[4]++;
                compare(id + " [" + kind + "] " + lex, oldRes.get(lex), newRes.get(lex), groups, histogram);
            }
        }
        OUT.println("gate scan (java): old/new engine via aster-api InProcessCnlParser + TypeChecker");
        OUT.println("lexicons: " + String.join(", ", LEXICONS));
        OUT.printf("compiles: old ok %d / new ok %d / %d (source × lexicon); compared %d%n",
            stats[0], stats[1], stats[5], stats[4]);
        OUT.printf("front-end ok (ok + typecheck): old %d / new %d; old sources ok in any lexicon: %d / %d%n",
            stats[2], stats[3], stats[6], rows.size());
        for (Map.Entry<String, List<String>> g : groups.entrySet()) {
            OUT.println(g.getKey() + ": " + g.getValue().size());
            g.getValue().forEach(l -> OUT.println("  " + l));
        }
        OUT.println("ir-diff histogram (b=expected TypeApp→Result/Option, c=other): " + histogram);
        if (args.tsOldSourcesOk() == null) {
            OUT.println("sanity: SKIPPED (no ts scan given; the four-lexicon preflight still ran)");
        } else if (args.tsSourcesTotal() != rows.size()) {
            OUT.println("sanity: ts scanned " + args.tsSourcesTotal() + " sources, java " + rows.size() + " — different exports");
            OUT.println("result: INVALID (ts scan is of a different export)");
            return 3;
        } else if (!sane(stats[6], args.tsOldSourcesOk(), args.maxGapPct())) {
            return 3;
        }
        int bad = 0;
        for (String g : List.of("newly-failing-E064", "newly-failing", "throws", "changed-codes", "ir-changed-other",
            "ir-changed-cols-only")) {
            bad += groups.get(g).size();
        }
        OUT.println("result: " + (bad == 0 ? "PASS" : "REVIEW") + " (" + bad
            + " need review; newly-passing / ir-changed-expected / e064-prefilter-hits are informational)");
        return bad == 0 ? 0 : 1;
    }

    /** 比较一个 lexicon 下的新旧结果，归入相应分组。 */
    private void compare(String tag, String[] o, String[] n, Map<String, List<String>> groups,
                         Map<String, Integer> histogram) throws Exception {
        String detail = tag + " old=" + o[0] + "{" + o[1] + "} new=" + n[0] + "{" + n[1] + "}";
        boolean oldOk = "ok".equals(o[0]);
        boolean newOk = "ok".equals(n[0]);
        if ("throw".equals(n[0])) groups.get("throws").add(detail);
        else if (oldOk && !newOk) groups.get(n[1].contains("E064(',')") ? "newly-failing-E064" : "newly-failing").add(detail);
        else if (!oldOk && newOk) groups.get("newly-passing").add(detail);
        else if (!o[1].equals(n[1]) || !o[0].equals(n[0])) groups.get("changed-codes").add(detail);
        if (o[2].isEmpty() || n[2].isEmpty() || o[2].equals(n[2])) return;
        List<String> other = new ArrayList<>();
        List<String> expected = new ArrayList<>();
        for (String d : (String[]) call(newSide, newSide.diff(), o[2], n[2])) {
            (d.startsWith("b:") ? expected : other).add(d.substring(2));
            histogram.merge(d.substring(0, 2) + key(d.substring(2)), 1, Integer::sum);
        }
        if (other.isEmpty()) groups.get("ir-changed-expected").add(tag + " nodes=" + expected.size());
        else if (other.stream().allMatch(p -> COL_PATH.matcher(p).find())) groups.get("ir-changed-cols-only").add(tag + " paths=" + other);
        else groups.get("ir-changed-other").add(tag + " paths=" + other);
    }

    /** 通过了解析、名称解析与降级（类型检查错误不算失败）：与 ts compile() 的「成功」口径一致。 */
    private static boolean passesFrontEnd(String status) {
        return "ok".equals(status) || "typecheck".equals(status);
    }

    /**
     * 与 ts 扫描对账：同一批源里，旧版在任一 lexicon 下能编译（过前端）的源数两边应基本一致。按源计而不按
     * 「源 × lexicon」计——Java 的 zh / de / hi 词法表回退 en-US（英文源在四个 lexicon 下都能编译），ts 不回退，
     * 逐 lexicon 的成功数两边天然不同（生产 2026-11-17：Java 344 vs ts 269 / 440）。差距超过阈值通常说明 Java 侧
     * 缺语言包（只剩 en-US 时只用 zh / de 写的源全部失败）或 ts 构建不对，此时 Java 结果作废（退出码 3）。
     */
    static boolean sane(int javaOldSourcesOk, int tsOldSourcesOk, int maxGapPct) {
        int gap = Math.abs(javaOldSourcesOk - tsOldSourcesOk);
        long allowed = Math.max(1, (long) tsOldSourcesOk * maxGapPct / 100);
        String line = "sanity: old sources ok in any lexicon: java " + javaOldSourcesOk + " vs ts " + tsOldSourcesOk
            + " (gap " + gap + ", allowed " + allowed + " = " + maxGapPct + "%)";
        if (gap <= allowed) {
            OUT.println(line + " — ok");
            return true;
        }
        OUT.println(line + " — TOO LARGE");
        ERR.println("环境错误：Java 与 ts 的旧版可编译源数差距过大，Java 结果不可信（缺语言包？ts 构建不对？）");
        OUT.println("result: INVALID (java/ts old-ok sources gap too large)");
        return false;
    }

    /** 与 scan.mjs 相同的 lexicon 规则：旧版成功的全部 lexicon；全失败时只比一个（新版成功的第一个，否则 en-US）。 */
    private static List<String> pickLexicons(Map<String, String[]> oldRes, Map<String, String[]> newRes) {
        List<String> ok = new ArrayList<>();
        oldRes.forEach((lex, r) -> {
            if ("ok".equals(r[0])) ok.add(lex);
        });
        if (!ok.isEmpty()) return ok;
        for (String lex : LEXICONS) {
            if ("ok".equals(newRes.get(lex)[0])) return List.of(lex);
        }
        return List.of(LEXICONS[0]);
    }

    /** 直方图键：去掉路径前缀，只留最后两段（如 params.type{TypeApp(result)->Result}）。 */
    private static String key(String path) {
        String[] parts = path.split("\\.");
        int from = Math.max(0, parts.length - 2);
        return String.join(".", Arrays.copyOfRange(parts, from, parts.length));
    }
}
