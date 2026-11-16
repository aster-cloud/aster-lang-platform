package aster.core.typecheck.model;

import aster.core.typecheck.ErrorCode;

/** 测试桩。 */
public record Diagnostic(ErrorCode code, Severity severity) {
    public enum Severity { ERROR, WARNING }
}
