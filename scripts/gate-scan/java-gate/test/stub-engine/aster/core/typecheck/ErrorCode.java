package aster.core.typecheck;

/** 测试桩：类型检查码与治理码（治理码不参与门禁比较）。 */
public enum ErrorCode {
    E200("E200", Category.TYPE),
    E801("E801", Category.RESOLUTION),
    W900("W900", Category.GOVERNANCE);

    public enum Category { TYPE, RESOLUTION, GOVERNANCE }

    private final String code;
    private final Category category;

    ErrorCode(String code, Category category) {
        this.code = code;
        this.category = category;
    }

    public String code() {
        return code;
    }

    public Category category() {
        return category;
    }
}
