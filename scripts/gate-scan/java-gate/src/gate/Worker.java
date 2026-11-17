package gate;

import aster.core.ir.CoreIrJson;
import aster.core.typecheck.ErrorCode;
import aster.core.typecheck.TypeChecker;
import aster.core.typecheck.model.Diagnostic;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.aster.policy.parser.CnlErrorListener;
import io.aster.policy.parser.InProcessCnlParser;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.TreeSet;

/**
 * 在某一侧引擎（旧 / 新）的类加载器里执行：按 aster-api 生产编译路径（InProcessCnlParser.parse → TypeChecker，
 * 剔除治理类诊断 → CoreIrJson.serialize）编译一份源码。只回传状态、诊断码与规范 IR，绝不打印源码。
 * 驱动类（Main）只依赖 JDK，经反射调用本类，两侧各自一个 URLClassLoader，互不可见。
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
                marker = n.get("_count").asInt();
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
     * 编译一次。返回 [status, codes, coreJson]：status ∈ ok | parse | resolve | typecheck | budget | throw；
     * codes 为排序后的「码:级别」集合（逗号分隔）；coreJson 只在通过名称解析后给出（类型错误时也给，便于比较）。
     */
    public static String[] compile(String source, String locale) {
        try {
            InProcessCnlParser.ParseResult pr = InProcessCnlParser.parse(source, locale);
            Set<String> codes = new TreeSet<>();
            for (Diagnostic w : pr.warnings()) codes.add(tag(w));
            boolean typeError = false;
            for (Diagnostic d : new TypeChecker().typecheckModule(pr.core())) {
                if (d.code().category() == ErrorCode.Category.GOVERNANCE) continue;
                codes.add(tag(d));
                typeError |= d.severity() == Diagnostic.Severity.ERROR;
            }
            String json = CoreIrJson.serialize(pr.core());
            return new String[] {typeError ? "typecheck" : "ok", String.join(",", codes), json};
        } catch (InProcessCnlParser.NameResolutionFailure e) {
            Set<String> codes = new TreeSet<>();
            for (Diagnostic d : e.resolutionDiagnostics()) codes.add(tag(d));
            return new String[] {"resolve", String.join(",", codes), ""};
        } catch (InProcessCnlParser.BudgetExceededFailure e) {
            return new String[] {"budget", "BUDGET", ""};
        } catch (InProcessCnlParser.CnlParseException e) {
            Set<String> codes = new TreeSet<>();
            for (CnlErrorListener.Diagnostic d : e.getDiagnostics()) {
                String c = d.code() == null ? "UNCODED" : d.code().toUpperCase(Locale.ROOT);
                // E064 是通用的「Unexpected {construct}」；ADR 0056 修订 A1 §2.3 的歧义逗号单独标成 E064(',')
                if ("E064".equals(c) && d.params() != null && "','".equals(d.params().get("construct"))) c = "E064(',')";
                codes.add(c + ":error");
            }
            if (codes.isEmpty()) codes.add("UNCODED:error");
            return new String[] {"parse", String.join(",", codes), ""};
        } catch (Throwable t) {
            return new String[] {"throw", "THROW:" + t.getClass().getSimpleName(), ""};
        }
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
