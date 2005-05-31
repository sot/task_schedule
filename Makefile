# Set the task name
TASK = task_schedule

# Uncomment the correct choice indicating either SKA or TST flight environment
FLIGHT_ENV = SKA

# Set the names of all files that get installed
BIN = task_schedule.pl
DOC = README
# include /proj/sot/ska/include/Makefile.FLIGHT
include /proj/sot/ska/include/Makefile.FLIGHT

# Define outside data and bin dependencies required for testing,
# i.e. all tools and data required by the task which are NOT 
# created by or internal to the task itself.  These will be copied
# first from the local test directory t/ and if not found from the
# ROOT_FLIGHT area.
#
TEST_DEP = data/test.config bin/task1.pl bin/task2.pl

# To 'test', first check that the INSTALL root is not the same as the FLIGHT
# root with 'check_install' (defined in Makefile.FLIGHT).  Typically this means
# doing 'setenv TST .'.  Then copy any outside data or bin dependencies into local
# directory via dependency rules defined in Makefile.FLIGHT.  Finally install
# the task, typically in '.'. 

test: check_install $(TEST_DEP) install
	$(INSTALL_BIN)/task_schedule.pl -config $(INSTALL)/data/test.config -fast 20 -no-email -loud

install:
	mkdir -p $(INSTALL_BIN); rsync --times --cvs-exclude $(BIN) $(INSTALL_BIN)/
	mkdir -p $(INSTALL_DOC); rsync --times --cvs-exclude $(DOC) $(INSTALL_DOC)/

clean:
	rm -r bin data doc

