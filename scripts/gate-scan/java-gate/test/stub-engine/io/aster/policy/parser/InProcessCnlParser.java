package io.aster.policy.parser;

import aster.core.ir.CoreModel;
import aster.core.lexicon.LexiconRegistry;
import aster.core.typecheck.ErrorCode;
import aster.core.typecheck.model.Diagnostic;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.logging.Logger;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 测试桩：按源码里的指令决定编译结果，并故意把源码打到 stdout / stderr / JUL 日志，用来验证门禁不泄露源码。
 *
 * <p>指令：{@code [<build>[@<lexicon>]:<动作>]}，build 为 old / new / all（本 jar 的 build 名取自资源 stub-build.txt）；
 * 动作：Exxx = 解析错误，comma = E064(',')，resolve = 名称解析失败 E801，tc = 类型错误 E200，throw = 抛异常，
 * col = IR 列 +1，rename = IR 名字改变。{@code [lex:<id>]} 表示只在该 lexicon 下能解析。
 * 未注册的 lexicon 一律解析失败（UNCODED），与真实引擎在缺语言包时的表现一致。
 */
public final class InProcessCnlParser {
    private static final Logger LOG = Logger.getLogger(InProcessCnlParser.class.getName());
    private static final Pattern DIRECTIVE = Pattern.compile("\\[(\\w+)(?:@([\\w-]+))?:([\\w-]+)]");
    private static final String BUILD = readBuild();

    private InProcessCnlParser() {
    }

    private static String readBuild() {
        try (InputStream in = InProcessCnlParser.class.getResourceAsStream("/stub-build.txt")) {
            return new String(in.readAllBytes(), StandardCharsets.UTF_8).trim();
        } catch (IOException | NullPointerException e) {
            throw new IllegalStateException("stub-build.txt missing");
        }
    }

    public record ParseResult(List<Diagnostic> warnings, CoreModel.Module core) {
    }

    public static class CnlParseException extends RuntimeException {
        private final List<CnlErrorListener.Diagnostic> diagnostics;

        public CnlParseException(String message, List<CnlErrorListener.Diagnostic> diagnostics) {
            super(message);
            this.diagnostics = diagnostics;
        }

        public List<CnlErrorListener.Diagnostic> getDiagnostics() {
            return diagnostics;
        }
    }

    public static final class NameResolutionFailure extends CnlParseException {
        public NameResolutionFailure() {
            super("resolution", List.of());
        }

        public List<Diagnostic> resolutionDiagnostics() {
            return List.of(new Diagnostic(ErrorCode.E801, Diagnostic.Severity.ERROR));
        }
    }

    public static final class BudgetExceededFailure extends CnlParseException {
        public BudgetExceededFailure() {
            super("budget", List.of());
        }
    }

    public static ParseResult parse(String source, String locale) {
        System.out.println("LEAK " + source);
        System.err.println("LEAK " + source);
        LOG.warning("LEAK " + source);
        if (!LexiconRegistry.getInstance().has(locale)) {
            throw new CnlParseException("no lexicon " + source, List.of(new CnlErrorListener.Diagnostic(null, null)));
        }
        int col = 1;
        String name = "rule";
        boolean typeError = false;
        List<CnlErrorListener.Diagnostic> errors = new ArrayList<>();
        Matcher m = DIRECTIVE.matcher(source);
        while (m.find()) {
            String who = m.group(1);
            String onlyLex = m.group(2);
            String what = m.group(3);
            if (who.equals("lex")) {
                if (!what.equalsIgnoreCase(locale)) errors.add(new CnlErrorListener.Diagnostic("E050", Map.of()));
                continue;
            }
            if (!who.equals(BUILD) && !who.equals("all")) continue;
            if (onlyLex != null && !onlyLex.equalsIgnoreCase(locale)) continue;
            switch (what) {
                case "throw" -> throw new IllegalStateException("boom " + source);
                case "resolve" -> throw new NameResolutionFailure();
                case "tc" -> typeError = true;
                case "col" -> col = 2;
                case "rename" -> name = "renamed";
                case "comma" -> errors.add(new CnlErrorListener.Diagnostic("e064", Map.of("construct", "','")));
                default -> errors.add(new CnlErrorListener.Diagnostic(what, Map.of()));
            }
        }
        if (!errors.isEmpty()) throw new CnlParseException("parse " + source, errors);
        String json = "{\"decls\":[{\"name\":\"" + name + "\",\"origin\":{\"start\":{\"col\":" + col
            + ",\"line\":1},\"end\":{\"col\":" + (col + 4) + ",\"line\":1}}}]}";
        return new ParseResult(List.of(), new CoreModel.Module(json, typeError));
    }
}
