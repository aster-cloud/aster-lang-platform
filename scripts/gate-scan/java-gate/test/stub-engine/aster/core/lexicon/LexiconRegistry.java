package aster.core.lexicon;

import java.util.Locale;
import java.util.ServiceLoader;
import java.util.Set;
import java.util.TreeSet;

/** 测试桩：与真实 core 一样，en-US 内嵌，其余语言包经线程上下文类加载器（TCCL）上的 SPI 发现，首次调用后缓存。 */
public final class LexiconRegistry {
    private static LexiconRegistry instance;
    private final Set<String> ids = new TreeSet<>();

    private LexiconRegistry() {
        ids.add("en-us");
        for (LexiconPack p : ServiceLoader.load(LexiconPack.class, Thread.currentThread().getContextClassLoader())) {
            ids.add(p.id().toLowerCase(Locale.ROOT));
        }
    }

    public static synchronized LexiconRegistry getInstance() {
        if (instance == null) instance = new LexiconRegistry();
        return instance;
    }

    public boolean has(String id) {
        return ids.contains(id.toLowerCase(Locale.ROOT));
    }
}
