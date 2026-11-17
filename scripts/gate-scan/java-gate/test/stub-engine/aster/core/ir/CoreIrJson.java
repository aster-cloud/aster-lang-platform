package aster.core.ir;

/** 测试桩。 */
public final class CoreIrJson {
    private CoreIrJson() {
    }

    public static String serialize(CoreModel.Module m) {
        return m.json;
    }
}
