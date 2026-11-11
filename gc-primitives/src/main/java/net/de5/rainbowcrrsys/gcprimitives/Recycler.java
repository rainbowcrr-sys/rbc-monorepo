package net.de5.rainbowcrrsys.gcprimitives;

/**
 * 归还时的复位钩子：把对象恢复到可再次借出的干净状态。
 *
 * <p>复位由库在归还路径上调用，调用方无需自己清理；复位逻辑不应抛异常。
 *
 * @param <T> 被池化的对象类型
 */
@FunctionalInterface
public interface Recycler<T> {

    void recycle(T value);

    /** 不做任何复位的单例；仅适用于无可变状态的对象。 */
    @SuppressWarnings("rawtypes")
    Recycler NO_OP = value -> { };

    /** 返回不做任何复位的 {@link Recycler}。 */
    @SuppressWarnings("unchecked")
    static <T> Recycler<T> noOp() {
        return (Recycler<T>) NO_OP;
    }
}
