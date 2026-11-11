package net.de5.rainbowcrrsys.gcprimitives;

/**
 * 有界的对象来源：借出与归还由 {@link Lease} 表达，归还时由 {@link Recycler} 复位对象状态。
 *
 * <p>语义契约：
 * <ul>
 *   <li>每次 {@link #borrow()} 得到的租约必须放在 try-with-resources 中关闭；</li>
 *   <li>租约与借出的对象只归借用线程使用，不跨线程传递；</li>
 *   <li>关闭之后不得再持有或使用该对象引用。</li>
 * </ul>
 *
 * <p>实现只提供可组合的原语，不绑定具体场景；调用方自行决定延迟与吞吐的取舍。
 *
 * @param <T> 被池化的对象类型
 */
public interface Pool<T> {

    /** 借出一个对象；返回的租约必须关闭。 */
    Lease<T> borrow();

    /** 每线程保留的空闲对象上限。 */
    int capacity();

    /** 当前线程的空闲对象数；仅用于诊断。 */
    int idleCount();

    /** 所有线程合计尚未归还的租约数；恒等于 borrowCount - returnCount。 */
    long activeLeases();

    /** 累计借出次数。 */
    long borrowCount();

    /** 累计归还次数。 */
    long returnCount();

    /** 断言当前没有未归还的租约，测试期用来把泄漏直接变成失败。 */
    default void assertNoActiveLeases() {
        long active = activeLeases();
        if (active != 0L) {
            throw new PoolStateException(
                    active + " lease(s) not returned; close every borrow() in try-with-resources");
        }
    }
}
