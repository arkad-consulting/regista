// The test process's main event queue belongs to its main thread (#118).
//
// HIToolbox makes its main event queue on the first call that needs one (GetMainEventQueue, GetCurrentEventQueue, the
// creation of the NSApplication object) and gives it to the thread that made that call. AppKit checks, once, on the
// first event the main thread asks for, that the main event queue is the main thread's, and traps the process when it
// is not (SIGTRAP in ___NSAssertMainEventQueueIsCurrentEventQueue_block_invoke, under _DPSNextEvent). In the test
// process any test may come first: one running on a worker thread that makes the application object (a cursor rendered
// while the main thread is busy, #46) leaves the queue to that worker, and the mouse rig's first click on an AppKit
// control traps a minute later. So the queue is made here, on the main thread, while the test bundle loads, before any
// test runs.
#include <pthread.h>
#include <Carbon/Carbon.h>

static int madeOnMain = -1;

__attribute__((constructor)) static void rigMakeMainEventQueue(void) {
    if (pthread_main_np()) {
        (void)GetMainEventQueue();
        madeOnMain = 1;
    } else {
        madeOnMain = 0;
    }
}

int rig_main_event_queue_made_on_main(void) { return madeOnMain; }
