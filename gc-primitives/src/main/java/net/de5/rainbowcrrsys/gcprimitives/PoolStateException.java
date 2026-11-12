package net.de5.rainbowcrrsys.gcprimitives;

/** 池契约被破坏时抛出：重复归还、跨线程归还、关闭后取用、工厂返回 null 等。 */
public class PoolStateException extends IllegalStateException {

    private static final long serialVersionUID = 1L;

    public PoolStateException(String message) {
        super(message);
    }

    public PoolStateException(String message, Throwable cause) {
        super(message, cause);
    }
}
