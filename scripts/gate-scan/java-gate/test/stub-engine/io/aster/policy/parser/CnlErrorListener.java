package io.aster.policy.parser;

import java.util.Map;

/** 测试桩。 */
public final class CnlErrorListener {
    private CnlErrorListener() {
    }

    public record Diagnostic(String code, Map<String, String> params) {
    }
}
