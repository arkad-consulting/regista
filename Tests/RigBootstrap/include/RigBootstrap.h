#ifndef RIG_BOOTSTRAP_H
#define RIG_BOOTSTRAP_H

/// Whether the test bundle's load-time hook ran on the main thread and made HIToolbox's main event queue there (1), ran
/// on another thread (0), or never ran (-1). See RigBootstrap.c.
int rig_main_event_queue_made_on_main(void);

#endif
