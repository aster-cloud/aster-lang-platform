package aster.core.lexicon;

/** 测试桩：语言包 SPI（真实 core 用 ServiceLoader 在线程上下文类加载器上发现 zh / de / hi 语言包）。 */
public interface LexiconPack {
    String id();
}
