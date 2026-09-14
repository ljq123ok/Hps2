/*
 * OHOS (musl) compatibility shim for symbols that SDL3 references but the
 * HarmonyOS NDK sysroot does not provide.
 *
 * Context: OHOS pthread.h defines PTHREAD_CANCEL_ASYNCHRONOUS but does not
 * declare or export pthread_setcanceltype(). SDL3's
 * src/thread/pthread/SDL_systhread.c guards the call with
 * "#ifdef PTHREAD_CANCEL_ASYNCHRONOUS", so the guard passes and the shared
 * library fails to link with "undefined symbol: pthread_setcanceltype".
 *
 * This shim is intentionally a local porting aid for the Hps2/ARMSX2 build.
 * It is NOT intended for upstream SDL contribution.
 *
 * HarmonyOS musl has no POSIX thread cancellation at all, so there is no
 * state to change: report the previous (deferred) type and succeed. SDL
 * ignores the return value.
 */

int pthread_setcanceltype(int type, int *oldtype)
{
    (void)type;
    if (oldtype) {
        *oldtype = 0; /* PTHREAD_CANCEL_DEFERRED */
    }
    return 0;
}

int pthread_setcancelstate(int state, int *oldstate)
{
    (void)state;
    if (oldstate) {
        *oldstate = 0; /* PTHREAD_CANCEL_ENABLE */
    }
    return 0;
}
