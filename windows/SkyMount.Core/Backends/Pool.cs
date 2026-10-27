namespace SkyMount.Core;

/// A fixed number of connections, each used by one caller at a time. A connection that broke is
/// reopened, and a call that failed for lack of a connection is retried twice.
sealed class Pool<T>(int size, Func<T> open, Action<T> close, Func<T, bool> isOpen) where T : class
{
    readonly SemaphoreSlim available = new(size, size);
    readonly Stack<T?> idle = new(Enumerable.Repeat<T?>(null, size));

    public R Use<R>(Func<T, R> body)
    {
        available.Wait();
        T? c;
        lock (idle) c = idle.Pop();
        try
        {
            for (var attempt = 0; ; attempt++)
            {
                try
                {
                    if (c != null && !isOpen(c))
                    {
                        close(c);
                        c = null;
                    }
                    c ??= open();
                    return body(c);
                }
                catch (RemoteException e) when (e.Kind == RemoteErrorKind.Network && attempt < 2)
                {
                    if (c != null) close(c);
                    c = null;
                    Thread.Sleep(TimeSpan.FromSeconds(attempt + 1));
                }
            }
        }
        finally
        {
            lock (idle) idle.Push(c);
            available.Release();
        }
    }

    /// Closes connections nobody is using (after sleep or a network change).
    public void CloseIdle()
    {
        lock (idle)
        {
            var all = idle.ToArray();
            idle.Clear();
            foreach (var c in all)
            {
                if (c != null) close(c);
                idle.Push(null);
            }
        }
    }

    /// Waits for every connection to come back, then closes them.
    public void CloseAll()
    {
        for (var i = 0; i < size; i++) available.Wait();
        CloseIdle();
        available.Release(size);
    }
}
