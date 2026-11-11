#ifndef TASKSCOPE_TEST_ENVIRONMENT_H
#define TASKSCOPE_TEST_ENVIRONMENT_H

#include <stdbool.h>

/// True when the test bundle's load-time setup has run. It runs while the
/// bundle loads, before XCTest enumerates classes to build its list of tests.
bool taskscope_test_environment_was_prepared_at_load(void);

#endif
