# Set the task name
TASK = task_schedule

# Uncomment the correct choice indicating either SKA or TST flight environment
FLIGHT_ENV = SKA

# Set the names of all files that get installed
BIN = task_schedule3.pl
include /proj/sot/ska/include/Makefile.FLIGHT

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

# To 'test', first check that the INSTALL root is not the same as the FLIGHT
# root with 'check_install' (defined in Makefile.FLIGHT).  Typically this means
# doing 'setenv TST .'.  Then copy any outside data or bin dependencies into local
# directory via dependency rules defined in Makefile.FLIGHT.  Finally install
# the task, typically in '.'. 

test: test_basic test_exception test_basic_full test_fail test_send_mail test_send_mail_quiet

test_basic: check_install $(TEST_DEP) install
	rm -f $(INSTALL)/data/basic/task_sched_heartbeat
	rm -f $(INSTALL)/data/basic/task_sched_heart_attack
	rm -f $(INSTALL)/data/basic/task_sched_disable_alerts
	perl $(INSTALL_BIN)/task_schedule3.pl -alert $(USER) -config $(INSTALL)/data/basic/basic.config -fast 6 -no-email -loud

test_exception:check_install $(TEST_DEP) install
	rm -f $(INSTALL)/data/exception/task_sched_heartbeat
	rm -f $(INSTALL)/data/exception/task_sched_heart_attack
	rm -f $(INSTALL)/data/exception/task_sched_disable_alerts
	perl $(INSTALL_BIN)/task_schedule3.pl -alert $(USER) -config $(INSTALL)/data/exception/exception.config -fast 6 -no-email -loud

test_basic_full: check_install $(TEST_DEP) install
	rm -f $(INSTALL)/data/basic/task_sched_heartbeat
	rm -f $(INSTALL)/data/basic/task_sched_heart_attack
	rm -f $(INSTALL)/data/basic/task_sched_disable_alerts
	perl $(INSTALL_BIN)/task_schedule3.pl -alert $(USER) -config $(INSTALL)/data/basic/basic.config -loud

test_fail: check_install $(TEST_DEP) install 
	rm -f $(INSTALL)/data/fail/task_sched_heartbeat
	rm -f $(INSTALL)/data/fail/task_sched_heart_attack
	rm -f $(INSTALL)/data/fail/task_sched_disable_alerts
	perl $(INSTALL_BIN)/task_schedule3.pl -alert $(USER) -config $(INSTALL)/data/fail/fail.config -fast 20 -loud

test_send_mail: check_install $(TEST_DEP) install 
	rm -f $(INSTALL)/data/send_mail/task_sched_heartbeat
	rm -f $(INSTALL)/data/send_mail/task_sched_heart_attack
	rm -f $(INSTALL)/data/send_mail/task_sched_disable_alerts
	perl $(INSTALL_BIN)/task_schedule3.pl -alert $(USER) -config $(INSTALL)/data/send_mail/send_mail.config -fast 5 -loud

test_send_mail_quiet: check_install $(TEST_DEP) install 
	rm -f $(INSTALL)/data/send_mail/task_sched_heartbeat
	rm -f $(INSTALL)/data/send_mail/task_sched_heart_attack
	rm -f $(INSTALL)/data/send_mail/task_sched_disable_alerts
	perl $(INSTALL_BIN)/task_schedule3.pl -alert $(USER) -config $(INSTALL)/data/send_mail/send_mail.config -fast 5 

install:
	mkdir -p $(INSTALL_BIN); rsync --times --cvs-exclude $(BIN) $(INSTALL_BIN)/
	mkdir -p $(INSTALL_DOC)
	pod2html task_schedule3.pl > $(INSTALL_DOC)/index.html
	rm -f pod2htm?.tmp

clean:
	rm -r bin data doc

