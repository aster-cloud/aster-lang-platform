package aster.core.typecheck;

import aster.core.ir.CoreModel;
import aster.core.typecheck.model.Diagnostic;
import java.util.List;

/** 测试桩：类型错误由解析桩按指令标在 Module 上；治理诊断总是附带一条（门禁应忽略它）。 */
public final class TypeChecker {
    public List<Diagnostic> typecheckModule(CoreModel.Module m) {
        Diagnostic governance = new Diagnostic(ErrorCode.W900, Diagnostic.Severity.WARNING);
        return m.typeError ? List.of(governance, new Diagnostic(ErrorCode.E200, Diagnostic.Severity.ERROR)) : List.of(governance);
    }
}
