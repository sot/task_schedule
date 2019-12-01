# Set the task name
TASK = task_schedule

# Set the names of all files that get installed
BIN = task_schedule3.pl

# Define outside data and bin dependencies required for testing,
# i.e. all tools and data required by the task which are NOT
# created by or internal to the task itself.  These will be copied
# first from the local test directory t/ and if not found from the
# ROOT_FLIGHT area.
#
TEST_DEP = data/basic/basic.config \
	data/exception/exception.config \
	data/fail/fail.config \
	data/send_mail/send_mail.config \
	bin/task1.pl bin/task2.pl \
	bin/watch_cron_logs.pl \
	bin/exception.py

TEST_SKA = $(PWD)/test_ska

# Define installation PREFIX as the sys.prefix of python in the PATH.
PREFIX = $(shell python -c 'import sys; print(sys.prefix)')

# To 'test', first check that the INSTALL root is not the same as the FLIGHT
# root with 'check_install' (defined in Makefile.FLIGHT).  Typically this means
# doing 'setenv TST .'.  Then copy any outside data or bin dependencies into local
# directory via dependency rules defined in Makefile.FLIGHT.  Finally install
# the task, typically in '.'.

test: test_basic test_exception test_basic_full test_fail test_send_mail test_send_mail_quiet

show_prefix:
	echo $(PREFIX)

test_basic:
	rm -rf $(TEST_SKA)
	rsync -av t/ $(TEST_SKA)/
	env SKA=$(TEST_SKA) ./task_schedule3.pl -alert $(USER) \
 		-config $(TEST_SKA)/data/basic/basic.config -fast 6 -no-email -loud

test_exception:
	rm -rf $(TEST_SKA)
	rsync -av t/ $(TEST_SKA)/
	env SKA=$(TEST_SKA) ./task_schedule3.pl -alert $(USER) \
		-config $(TEST_SKA)/data/exception/exception.config -fast 6 -no-email -loud

test_basic_full:
	rm -rf $(TEST_SKA)
	rsync -av t/ $(TEST_SKA)/
	env SKA=$(TEST_SKA) ./task_schedule3.pl -alert $(USER) \
		-config $(TEST_SKA)/data/basic/basic.config -loud

test_fail:
	rm -rf $(TEST_SKA)
	rsync -av t/ $(TEST_SKA)/
	env SKA=$(TEST_SKA) ./task_schedule3.pl -alert $(USER) \
		-config $(TEST_SKA)/data/fail/fail.config -fast 20 -loud

test_send_mail:
	rm -rf $(TEST_SKA)
	rsync -av t/ $(TEST_SKA)/
	env SKA=$(TEST_SKA) ./task_schedule3.pl -alert $(USER) \
		-config $(TEST_SKA)/data/send_mail/send_mail.config -fast 5 -loud

test_send_mail_quiet:
	rm -rf $(TEST_SKA)
	rsync -av t/ $(TEST_SKA)/
	env SKA=$(TEST_SKA) ./task_schedule3.pl -alert $(USER) \
		-config $(TEST_SKA)/data/send_mail/send_mail.config -fast 5

install:
	mkdir -p $(PREFIX)/bin
	rsync --times --cvs-exclude $(BIN) $(PREFIX)/bin/

install_doc:
	mkdir -p $(SKA)/doc/$(TASK)
	pod2html task_schedule3.pl > $(SKA)/doc/$(TASK)/index.html
	rm -f pod2htm?.tmp

clean:
	rm -r $(TEST_SKA)

