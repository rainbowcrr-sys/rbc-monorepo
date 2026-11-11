package net.de5.rainbowcrrsys.gcprimitives;

/**
 * 一次借用的句柄，配合 try-with-resources 使用。
 *
 * <p>{@link #close()} 不抛受检异常；契约被破坏时抛 {@link PoolStateException}（运行时异常）。
 *
 * @param <T> 被借出的对象类型
 */
public interface Lease<T> extends AutoCloseable {

    /** 取得借出的对象；租约关闭后或跨线程调用会抛异常。 */
    T get();

    /** 归还对象并使其失效；重复关闭或跨线程关闭会抛异常。 */
    @Override
    void close();
}
