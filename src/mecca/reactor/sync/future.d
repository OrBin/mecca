/// Fiber future result execution
module mecca.reactor.sync.future;

// Licensed under the Boost license. Full copyright information in the AUTHORS file

import std.exception;
import std.traits;

import mecca.log;
import mecca.lib.exception;
import mecca.lib.time;
import mecca.reactor;
import mecca.reactor.utils;
import mecca.reactor.sync.event: Signal;

/// Custom exception thrown by `Future.get` if the fiber quit without setting a result
class FiberKilledWithNoResult : Exception {
    mixin ExceptionBody!"Future controlled fiber killed without setting a result";
}

/// Representation for future calculation result
@notrace
struct Future(T) {
private:
    Signal suspender;
    FiberHandle fiberHandle;
    ExcBuf _exBuf;
    static if (!is(T == void)) {
        @notrace T _value;
    }
    bool isSet = false;

public:
    @disable this(this);

    /// Returns whether the future has a return value
    @property bool ready() const pure nothrow @safe @nogc {
        return isSet;
    }

    /// Returns the exception stored in the future's result (if any)
    @property Throwable exception() @safe @nogc  {
        enforceNGC(isSet, "Future not yet set");
        return _exBuf.get();
    }

    /// Wait for the future to be set
    @notrace @nogc
    void wait(Timeout timeout = Timeout.infinite, string file = __FILE__, ulong line = __LINE__) {
        if (fiberHandle.isSet) {
            theReactor.joinFiber(fiberHandle, timeout);

            if(!isSet) {
                // WEKAPP-53185: fiber was killed before even starting
                _exBuf.construct!FiberKilledWithNoResult(file, line, true);
                internalRaise();
            }
        }

        if (!isSet) {
            suspender.wait(timeout);
        }
    }

    /// Set the future's state to raised exception
    @notrace @nogc void raise(Throwable ex) {
        // we MUST copy the exception here since we may later refer to exceptions that came from defunct fibers
        // and the fiber itself is GC-allocated, which confuses toGC
        _exBuf.set(ex);
        DEBUG!"Future.raise ex=%s _ex=%s"(cast(void*)ex, cast(void*)_exBuf.get);
        internalRaise();
    }

    @notrace @nogc private void internalRaise() {
        enforceNGC(!isSet, "Future already set");
        isSet = true;
        suspender.signal();
    }

    /// Get the result stored in the future
    ///
    /// If the future is not yet set, will wait for it to become ready.
    @notrace @nogc
    auto ref get(Timeout timeout = Timeout.infinite) {
        wait(timeout);
        if (_exBuf.get !is null) {
            throw setEx(_exBuf.get());
        }
        static if (!is(T == void)) {
            return _value;
        }
    }

    static if (is(T == void)) {
        @notrace void set() {
            enforce(!isSet, "Future already set");
            assert(_exBuf.get is null, "ex is set");
            isSet = true;
            suspender.signal();
        }
    }
    else {
        @notrace void set(const ref T value) {
            enforce(!isSet, "Future already set");
            assert(_exBuf.get is null, "ex is set");
            isSet = true;
            _value = value;
            suspender.signal();
        }

        @notrace void set(T value) {
            enforce(!isSet, "Future already set");
            assert(_exBuf.get() is null, "ex is set");
            isSet = true;
            _value = value;
            suspender.signal();
        }
    }

    @notrace auto runInFiber(alias F)(Parameters!F args) {
        return runInFiber!F(theReactor, args);
    }

    @notrace auto runInFiber(alias F, Runner)(ref Runner runner, Parameters!F args) {
        alias RetType = ReturnType!F;
        static void run(FiberPointer!(Future!RetType) pFut, Parameters!F args) {
            try {
                static if (is(RetType == void)) {
                    F(args);
                    if (pFut.isValid) {
                        pFut.set();
                    }
                }
                else {
                    auto tmp = F(args);
                    if (pFut.isValid) {
                        pFut.set(tmp);
                    }
                }
            }
            catch (Exception ex) {
                if (pFut.isValid) {
                    pFut.raise(ex);
                }
                else {
                    throw setEx(ex);
                }
            }
        }

        fiberHandle = runner.spawnFiber!run(FiberPointer!(Future!RetType)(&this), args);
        return fiberHandle;
    }

    @notrace auto runInFiber(T)(T delegate() dlg) {
        static auto proxyCall(T delegate() dlg) {
            return dlg();
        }

        return runInFiber!proxyCall(dlg);
    }
}

unittest {
    testWithReactor({
        static void fib1(Future!void* fut) {
            theReactor.sleep(msecs(20));
            fut.set();
        }

        static void fib2(Future!int* fut) {
            theReactor.sleep(msecs(10));
            fut.set(88);
        }

        static void fib3(Future!string* fut) {
            theReactor.sleep(msecs(15));
            fut.raise(new Exception("boom"));
        }

        Future!void f1;
        Future!int f2;
        Future!string f3;

        theReactor.spawnFiber!fib1(&f1);
        theReactor.spawnFiber!fib2(&f2);
        theReactor.spawnFiber!fib3(&f3);

        f1.get();
        assertEQ(f2.get(), 88);
        assert(f3.ready, "f3 not ready");
        assert(f3.exception, "f3 not exception");
        bool failed = false;
        try {
            f3.get();
        }
        catch (Exception ex) {
            assertEQ(ex.msg, "boom");
            failed = true;
        }
        assert(failed);
    });
}

unittest {
    // WEKAPP-53185
    static void func() {
    }

    testWithReactor({
            Future!void fut;
            auto fib = fut.runInFiber!func();
            // Kill the fiber before it gets a change to receive the CPU
            theReactor.throwInFiber!FiberKilled(fib);

            assertThrows!FiberKilledWithNoResult( fut.get( Timeout(12.msecs) ) );
        });
}
