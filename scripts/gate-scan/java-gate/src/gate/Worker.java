package gate;

import aster.core.ir.CoreIrJson;
import aster.core.ir.CoreModel;
import aster.core.typecheck.ErrorCode;
import aster.core.typecheck.TypeChecker;
import aster.core.typecheck.model.Diagnostic;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;

/**
 * 在某一侧引擎（旧 / 新）的类加载器里执行：按 aster-api 生产编译路径（InProcessCnlParser.parse → TypeChecker，
 * 剔除治理类诊断 → CoreIrJson.serialize）编译一份源码。只回传状态、诊断码与规范 IR，绝不打印源码。
 * 驱动类（Main）只依赖 JDK，经反射调用本类，两侧各自一个 URLClassLoader，互不可见。
 *
 * <p>解析器按侧选择（反射，不在编译期绑定）：本侧 classpath 上有 aster-api 自己的副本
 * {@code io.aster.policy.parser.InProcessCnlParser} 时用它（aster-api 删除副本之前的生产路径），否则用 core 的
 * {@code aster.core.embed.InProcessCnlParser}（删除副本之后的生产路径，aster-api A1）。两者的公开签名与异常层次相同。
 */
public final class Worker {
    private static final ObjectMapper MAPPER = new ObjectMapper();

    private Worker() {
    }

    /**
     * 读取导出 JSONL：返回 {id, kind, content}。完成标记 {"_count": N} 必须恰好一个、位于最后一个非空行，且 N 等于行数；
     * 否则视为截断或拼接损坏的导出。
     */
    public static String[][] readSources(String path) throws Exception {
        List<String[]> rows = new ArrayList<>();
        Integer marker = null;
        for (String line : Files.readAllLines(Path.of(path))) {
            if (line.isBlank()) continue;
            if (marker != null) throw new IllegalStateException(path + "：完成标记之后还有数据行（导出损坏）");
            JsonNode n = MAPPER.readTree(line);
            if (n.has("_count")) {
                JsonNode c = n.get("_count");
                // 只收整数节点：asInt() 会把 1.9 / "1" 之类宽松转换成 1
                if (!c.isIntegralNumber() || !c.canConvertToInt() || c.intValue() < 0) {
                    throw new IllegalStateException(path + "：完成标记 _count 不是非负整数（导出损坏）");
                }
                marker = c.intValue();
                continue;
            }
            rows.add(new String[] {n.get("id").asText(), n.get("kind").asText(), n.get("content").asText()});
        }
        if (marker == null || marker != rows.size()) {
            throw new IllegalStateException(path + "：完成标记缺失或与行数不符（marker=" + marker + "，rows=" + rows.size() + "）");
        }
        return rows.toArray(new String[0][]);
    }

    /**
     * 读取 {@code export --with-vocab} 的 vocab.jsonl（export-vocab.sql）：返回有别名集的行 {id, aliasSet 原文}。
     * 完成标记的校验与 {@link #readSources} 相同；aliasSet 为 null / 空串的行（词条、快照、无别名集的版本）跳过。
     */
    public static String[][] readAliasSets(String path) throws Exception {
        List<String[]> rows = new ArrayList<>();
        Integer marker = null;
        int total = 0;
        for (String line : Files.readAllLines(Path.of(path))) {
            if (line.isBlank()) continue;
            if (marker != null) throw new IllegalStateException(path + "：完成标记之后还有数据行（导出损坏）");
            JsonNode n = MAPPER.readTree(line);
            if (n.has("_count")) {
                JsonNode c = n.get("_count");
                if (!c.isIntegralNumber() || !c.canConvertToInt() || c.intValue() < 0) {
                    throw new IllegalStateException(path + "：完成标记 _count 不是非负整数（导出损坏）");
                }
                marker = c.intValue();
                continue;
            }
            total++;
            JsonNode id = n.get("id");
            JsonNode aliasSet = n.get("aliasSet");
            if (id == null || !id.isTextual() || aliasSet == null || !aliasSet.isTextual() || aliasSet.asText().isBlank()) continue;
            rows.add(new String[] {id.asText(), aliasSet.asText()});
        }
        if (marker == null || marker != total) {
            throw new IllegalStateException(path + "：完成标记缺失或与行数不符（marker=" + marker + "，rows=" + total + "）");
        }
        return rows.toArray(new String[0][]);
    }

    /** aster-api 副本（删除前的生产路径）与 core 内嵌解析器（删除后的生产路径），按此顺序取本侧第一个存在的。 */
    private static final String[] PARSER_CLASSES = {
        "io.aster.policy.parser.InProcessCnlParser", "aster.core.embed.InProcessCnlParser"};
    private static final Class<?> PARSER = resolveParser();

    private static Class<?> resolveParser() {
        for (String name : PARSER_CLASSES) {
            try {
                return Class.forName(name, true, Worker.class.getClassLoader());
            } catch (ClassNotFoundException e) {
                // 试下一个
            }
        }
        throw new IllegalStateException("本侧 classpath 上没有 InProcessCnlParser（" + String.join(" / ", PARSER_CLASSES) + "）");
    }

    /** 本侧实际使用的解析器类名（驱动类打印到输出头，复核时据此确认两侧各走哪条生产路径）。 */
    public static String parserClass() {
        return PARSER.getName();
    }

    /** 不带别名集的编译（{@code InProcessCnlParser.parse}）。 */
    public static String[] compile(String source, String locale) {
        return compile(source, locale, null);
    }

    /**
     * 编译一次。返回 [status, codes, coreJson]：status ∈ ok | parse | resolve | typecheck | budget | throw | unreadable-aliasSet；
     * codes 为排序后的「码:级别」集合（逗号分隔）；coreJson 只在通过名称解析后给出（类型错误时也给，便于比较）。
     *
     * <p>{@code aliasSetJson} 非空时走冻结版本的执行路径 {@code parseWithUserAliases(source, locale, null, aliasSet, true)}
     * （aster-api 执行已存版本时以 allowStructural = true 复验冻结的别名集；别名名字守卫 E808 与解析失败归因只在这条路径上）。
     * 词汇作用域传 null：两侧同样不带词汇，比较的只是解析器与别名处理的差异。
     */
    public static String[] compile(String source, String locale, String aliasSetJson) {
        Object pr;
        try {
            pr = aliasSetJson == null
                ? PARSER.getMethod("parse", String.class, String.class).invoke(null, source, locale)
                : parseWithAliases(source, locale, aliasSetJson);
        } catch (UnreadableAliasSet e) {
            return new String[] {"unreadable-aliasSet", "", ""};
        } catch (InvocationTargetException e) {
            return failure(e.getCause());
        } catch (Throwable t) {
            return new String[] {"throw", "THROW:" + t.getClass().getSimpleName(), ""};
        }
        try {
            Set<String> codes = new TreeSet<>();
            for (Object w : (List<?>) invoke(pr, "warnings")) codes.add(tag((Diagnostic) w));
            CoreModel.Module core = (CoreModel.Module) invoke(pr, "core");
            boolean typeError = false;
            for (Diagnostic d : new TypeChecker().typecheckModule(core)) {
                if (d.code().category() == ErrorCode.Category.GOVERNANCE) continue;
                codes.add(tag(d));
                typeError |= d.severity() == Diagnostic.Severity.ERROR;
            }
            String json = CoreIrJson.serialize(core);
            return new String[] {typeError ? "typecheck" : "ok", String.join(",", codes), json};
        } catch (Throwable t) {
            return new String[] {"throw", "THROW:" + t.getClass().getSimpleName(), ""};
        }
    }

    private static Object parseWithAliases(String source, String locale, String aliasSetJson) throws Exception {
        Method m = null;
        for (Method c : PARSER.getMethods()) {
            if (c.getName().equals("parseWithUserAliases") && c.getParameterCount() == 5) m = c;
        }
        if (m == null) throw new IllegalStateException(PARSER.getName() + " 没有 5 参数的 parseWithUserAliases");
        return m.invoke(null, source, locale, null, aliasSet(aliasSetJson), true);
    }

    /** 别名集原文（kind → [别名]）→ Map&lt;SemanticTokenKind, List&lt;String&gt;&gt;；形状不符或 kind 未知时整条判为不可读。 */
    @SuppressWarnings({"unchecked", "rawtypes"})
    private static Map<Object, List<String>> aliasSet(String json) throws Exception {
        Class<? extends Enum> kindType = (Class<? extends Enum>) Class.forName(
            "aster.core.lexicon.SemanticTokenKind", true, Worker.class.getClassLoader());
        JsonNode n;
        try {
            n = MAPPER.readTree(json);
        } catch (Exception e) {
            throw new UnreadableAliasSet();
        }
        if (n == null || !n.isObject()) throw new UnreadableAliasSet();
        Map<Object, List<String>> out = new LinkedHashMap<>();
        Iterator<Map.Entry<String, JsonNode>> it = n.fields();
        while (it.hasNext()) {
            Map.Entry<String, JsonNode> e = it.next();
            if (!e.getValue().isArray()) throw new UnreadableAliasSet();
            List<String> aliases = new ArrayList<>();
            for (JsonNode a : e.getValue()) {
                if (!a.isTextual()) throw new UnreadableAliasSet();
                aliases.add(a.asText());
            }
            try {
                out.put(Enum.valueOf(kindType, e.getKey()), aliases);
            } catch (IllegalArgumentException unknownKind) {
                throw new UnreadableAliasSet();
            }
        }
        return out;
    }

    /** 别名集原文不可读（两侧同样不可读，不参与比较；vocab-check.mjs 的 unreadable_aliasSet 单独报告）。 */
    private static final class UnreadableAliasSet extends Exception {
        private static final long serialVersionUID = 1L;

        UnreadableAliasSet() {
            super(null, null, false, false);
        }
    }

    /** 解析器抛出的异常 → 结果。按异常类层次上的类名判定（两侧的异常类不是同一个 Class）。 */
    private static String[] failure(Throwable e) {
        try {
            if (isA(e, "NameResolutionFailure")) {
                Set<String> codes = new TreeSet<>();
                for (Object d : (List<?>) invoke(e, "resolutionDiagnostics")) codes.add(tag((Diagnostic) d));
                return new String[] {"resolve", String.join(",", codes), ""};
            }
            if (isA(e, "BudgetExceededFailure")) return new String[] {"budget", "BUDGET", ""};
            if (isA(e, "CnlParseException")) {
                Set<String> codes = new TreeSet<>();
                for (Object d : (List<?>) invoke(e, "getDiagnostics")) {
                    String code = (String) invoke(d, "code");
                    @SuppressWarnings("unchecked")
                    Map<String, String> params = (Map<String, String>) invoke(d, "params");
                    String c = code == null ? "UNCODED" : code.toUpperCase(Locale.ROOT);
                    // E064 是通用的「Unexpected {construct}」；ADR 0056 修订 A1 §2.3 的歧义逗号单独标成 E064(',')
                    if ("E064".equals(c) && params != null && "','".equals(params.get("construct"))) c = "E064(',')";
                    codes.add(c + ":error");
                }
                if (codes.isEmpty()) codes.add("UNCODED:error");
                return new String[] {"parse", String.join(",", codes), ""};
            }
        } catch (Throwable t) {
            return new String[] {"throw", "THROW:" + t.getClass().getSimpleName(), ""};
        }
        return new String[] {"throw", "THROW:" + e.getClass().getSimpleName(), ""};
    }

    /** e 的类或任一父类是解析器的嵌套类 {@code simpleName}。 */
    private static boolean isA(Throwable e, String simpleName) {
        for (Class<?> c = e.getClass(); c != null; c = c.getSuperclass()) {
            if (c.getSimpleName().equals(simpleName) && c.getEnclosingClass() == PARSER) return true;
        }
        return false;
    }

    private static Object invoke(Object target, String method) throws Exception {
        Method m = target.getClass().getMethod(method);
        m.setAccessible(true);
        return m.invoke(target);
    }

    /** 本侧 LexiconRegistry 已注册的 lexicon id（小写规范化），供驱动类做语言包预检。 */
    public static java.util.Set<String> registeredLexicons() {
        aster.core.lexicon.LexiconRegistry reg = aster.core.lexicon.LexiconRegistry.getInstance();
        Set<String> out = new TreeSet<>();
        for (String id : new String[] {"en-us", "zh-cn", "de-de", "hi-in"}) {
            if (reg.has(id)) out.add(id);
        }
        return out;
    }

    private static String tag(Diagnostic d) {
        return d.code().code().toUpperCase(Locale.ROOT) + ":" + d.severity().name().toLowerCase(Locale.ROOT);
    }

    /**
     * 比较新旧规范 IR。返回差异条目：「b:<路径>」= 旧侧 TypeApp(base 为 result / option，大小写不敏感)
     * 在新侧变为 Result / Option 节点（core#270 的预期变化，不再下钻）；「c:<路径>」= 其余任何差异。
     * 路径只由 IR 的 schema 键名组成（数组下标省略），不含任何取值。
     */
    public static String[] diffIr(String oldJson, String newJson) throws Exception {
        Set<String> out = new TreeSet<>();
        diff(MAPPER.readTree(oldJson), MAPPER.readTree(newJson), "", out);
        return out.toArray(new String[0]);
    }

    private static void diff(JsonNode a, JsonNode b, String path, Set<String> out) {
        if (a.equals(b)) return;
        if (a.isObject() && b.isObject()) {
            if (isExpectedTypeAppChange(a, b)) {
                String tagPath = path + "{TypeApp(" + a.path("base").asText().toLowerCase(Locale.ROOT) + ")->"
                    + b.path("kind").asText() + "}";
                out.add("b:" + tagPath);
                // 节点种类的变化是预期的，但分量必须一一对应：旧 args[0] ↔ 新 ok / type，旧 args[1] ↔ 新 err。
                // 旧侧省略失败类型时新侧补的是缺省 Text（只比较种类与名字，位置随 of 记号）。分量不等即
                // 含义变了（如 #256 修复前被内层 list 吞掉的失败类型），记为 c。
                JsonNode args = a.path("args");
                boolean isResult = "Result".equals(b.path("kind").asText());
                int max = isResult ? 2 : 1;
                if (!args.isArray() || args.size() < 1 || args.size() > max) {
                    out.add("c:" + tagPath + ".args(arity)");
                    return;
                }
                diff(args.get(0), b.path(isResult ? "ok" : "type"), tagPath + ".ok", out);
                if (isResult) {
                    JsonNode err = b.path("err");
                    if (args.size() == 2) {
                        diff(args.get(1), err, tagPath + ".err", out);
                    } else if (!"TypeName".equals(err.path("kind").asText()) || !"Text".equals(err.path("name").asText())) {
                        out.add("c:" + tagPath + ".err(default)");
                    }
                }
                if (!a.path("origin").equals(b.path("origin"))) out.add("b:" + tagPath + ".origin");
                return;
            }
            Set<String> keys = new TreeSet<>();
            a.fieldNames().forEachRemaining(keys::add);
            b.fieldNames().forEachRemaining(keys::add);
            for (String k : keys) {
                JsonNode x = a.get(k);
                JsonNode y = b.get(k);
                String p = path.isEmpty() ? k : path + "." + k;
                if (x == null || y == null) out.add("c:" + p + (x == null ? "(+)" : "(-)"));
                else diff(x, y, p, out);
            }
            return;
        }
        if (a.isArray() && b.isArray() && a.size() == b.size()) {
            Iterator<JsonNode> ia = a.elements();
            Iterator<JsonNode> ib = b.elements();
            while (ia.hasNext()) diff(ia.next(), ib.next(), path, out);
            return;
        }
        out.add("c:" + (path.isEmpty() ? "(root)" : path));
    }

    private static boolean isExpectedTypeAppChange(JsonNode a, JsonNode b) {
        if (!"TypeApp".equals(a.path("kind").asText())) return false;
        String base = a.path("base").asText().toLowerCase(Locale.ROOT);
        String kind = b.path("kind").asText();
        return ("result".equals(base) && "Result".equals(kind)) || ("option".equals(base) && "Option".equals(kind));
    }
}
