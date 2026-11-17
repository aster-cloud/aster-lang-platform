package aster.core.ir;

/** 测试桩：Core IR 只携带已序列化的 JSON。 */
public final class CoreModel {
    private CoreModel() {
    }

    public static final class Module {
        public final String json;
        public final boolean typeError;

        public Module(String json, boolean typeError) {
            this.json = json;
            this.typeError = typeError;
        }
    }
}
