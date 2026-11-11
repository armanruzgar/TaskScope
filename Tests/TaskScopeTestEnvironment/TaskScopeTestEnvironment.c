// Settings the test process needs before XCTest builds its list of tests.
#include "TaskScopeTestEnvironment.h"

#include <stdlib.h>

static bool preparedAtLoad = false;

// XCTest finds test classes by enumerating every Objective-C class, which
// realizes the classes of every framework loaded into the test process.
// ViewInspector links AuthenticationServices, which loads ContactsUI, and
// realizing one of ContactsUI's classes runs +[CNContactStore initialize].
// Unless CN_UNIT_TESTING is set, that schedules a background warm-up of the
// shared address book: it asks tccd for Contacts access and, when the process
// counts as authorized, connects to contactsd to open the user's Contacts
// database. Contacts reads the variable while that class initializes, so set
// it here, while the bundle loads, before XCTest enumerates any class.
__attribute__((constructor))
static void prepareTestEnvironment(void) {
    setenv("CN_UNIT_TESTING", "YES", 1);
    preparedAtLoad = true;
}

bool taskscope_test_environment_was_prepared_at_load(void) {
    return preparedAtLoad;
}
