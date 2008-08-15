#!/usr/bin/env /proj/sot/ska/bin/perl

##***************************************************************************
# Schedule a set a tasks
# 
# Author:  T. Aldcroft
# Created: 28-Dec-04
##***************************************************************************

use warnings;
use strict;
use File::Basename;
use Getopt::Long;
use Config::General;
use Data::Dumper;
use Safe;
use Schedule::Cron;
use IO::File;
use subs qw(dbg);
use CXC::Envs::Flight;
use POSIX qw(strftime);
use IO::All;
use Mail::Send;
use Ska::Process qw(send_mail);
 
##***************************************************************************
##   Some initialization
##***************************************************************************

$| = 1;
%ENV = CXC::Envs::Flight::env('ska'); # Adds Ska env to existing ENV

##***************************************************************************
##   Get config and cmd line options
##***************************************************************************

our %opt = (heartbeat      => 'task_sched_heartbeat',
	    heart_attack   => 'task_sched_heart_attack',
	    disable_alerts => 'task_sched_disable_alerts',
	    cron           => '* * * * *',
	    check_cron     => '0 0 * * *',
	    email          => 1,
	    iterations     => 0,   # No limit on iterations
	    master_log     => 'watch_cron_logs.master',
	   );

GetOptions (\%opt,
	    'config=s',
	    'loud!',
	    'help!',
	    'email!',
	    'fast=i',
	    'iterations=i',
	   );

help(2) if ($opt{help});

%opt = (%opt,
	ParseConfig(-ConfigFile => $opt{config},
		    -CComments => 0,
		   ),
       );

##***************************************************************************
## Interpolate (safely) some of the options to allow for generalized paths  
## based on environment vars.  Prepend default paths for bin and log directories
## if required.
##***************************************************************************
our $safe = new Safe;		# Make a safe container for doing evals
$safe->share('%ENV');
foreach (qw(data_dir bin_dir log_dir)) {
    $opt{$_} = defined $opt{$_} ? $safe->reval(qq/"$opt{$_}"/) : ".";
    dbg "$_=$opt{$_}";
}

# Prepend files names with $opt{data_dir} if needed
for (qw(heartbeat heart_attack disable_alerts)) {
    if ($opt{$_} and $opt{$_} !~ m|\A \s* /|x and $opt{data_dir}) {
	$opt{$_} = "$opt{data_dir}/$opt{$_}";
    }
    dbg "$_=$opt{$_}";
}

while (my ($name, $task) = each %{$opt{task}}) {
    $task->{exec} = parse_exec($task->{exec});
    foreach (@{$task->{exec}}) {
	$_->{cmd} = $safe->reval(qq/"$_->{cmd}"/);

	# If (after interpolation) the exec isn't an absolute path
	# and there is a bin_dir defined, then prepend that to path
	if (not $_->{cmd} =~ m|\A \s* /|x and $opt{bin_dir}) {
	    $_->{cmd} = "$opt{bin_dir}/$_->{cmd}";
	}
    }

    # Do the same for the log file, except that a value of undef
    # goes to "$name.log", and a value of '' gets left untouched
    $task->{log} = defined $task->{log} ? $safe->reval(qq/"$task->{log}"/) : "$name.log";
    if ($task->{log} and $task->{log} !~ m|\A \s* /|x and $opt{log_dir}) {
	$task->{log} = "$opt{log_dir}/$task->{log}";
    }

    dbg "Task=$name  exec=$task->{exec}  log=$task->{log}";
}

# Create log directory if necessary
if ($opt{log_dir} and not -d $opt{log_dir}) {
    eval { io($opt{log_dir})->mkpath };
    if ($@) {
	my $error = "ERROR - Could not open log dir $opt{log_dir}: $@";
	send_mail(addr_list => $opt{alert},
		  subject   => "$opt{subject}: ALERT",
		  message   => $error,
		  loud      => $opt{loud},
		  dryrun    => not $opt{email});
	die "$error\n";
    }
}

# Print the final program options
dbg Dumper \%opt;

##***************************************************************************
##  Check heart_attack file and exit if the file exists
##***************************************************************************
heart_attack() if (-e $opt{heart_attack});

##***************************************************************************
##  Check heartbeat file and exit gracefully if the file is recent.
##***************************************************************************
if (-e $opt{heartbeat}) {
    my $modify_time = (stat $opt{heartbeat})[9];

    # Go quietly into the night if heartbeat file is sufficiently new
    if (time-$modify_time < $opt{heartbeat_timeout}) {
	dbg "Quit because heartbeat was modified ", time-$modify_time, " seconds ago";
	exit(0);
    }
} else {
    # No heartbeat file, so create it
    system("touch $opt{heartbeat}");
}

##***************************************************************************
## Set up the cron table and run
##***************************************************************************
our @crontab;

# Make a Schedule::Cron object just to parse the 5-column cron entry
our $cron = new Schedule::Cron(sub {});

while (my ($name, $task) = each %{$opt{task}}) {
    $task->{cron}       ||= '* * * * *';
    $task->{check_cron} ||= '0 0 * * *';
    push @crontab, { %{$task},
		     name     	     => $name,
		     timeout  	     => $task->{timeout} || $opt{timeout},
		     next_time	     => next_time($task->{cron}),
		     next_check_time => next_time($task->{check_cron}),
		     iterations      => $opt{iterations},
		   };
}

##***************************************************************************
## Run the jobs
##  Fork so each job is launched in a separate process which waits until
##  the job finishes or a timeout alarm expires.  The parent just schedules
##  the next execution event for the job.
##  Touch a "heartbeat" file each minute 
##***************************************************************************

$SIG{CHLD} = 'IGNORE';		# Avoid zombies from dead children
while (-r $opt{heartbeat}) {
    # Check within main loop for presense of heart_attack file
    heart_attack() if (-e $opt{heart_attack});

    system("touch $opt{heartbeat}");
    my $pid;
    my $time = time;
    foreach my $cronjob (@crontab) {
	next if ($cronjob->{disabled});
	if ($time >= $cronjob->{next_time}) {
	    if ($pid = fork) {
		# Set time for next cronjob execution
		$cronjob->{next_time} = next_time($cronjob->{cron});

		# Set time for next check_outputs (watch_cron_logs) execution
		$cronjob->{next_check_time} = next_time($cronjob->{check_cron})
		  if ($time >= $cronjob->{next_check_time});

		# Disable further processing if iteration count reached
		$cronjob->{disabled} = 1 if (--$cronjob->{iterations} == 0);

		foreach (@{$cronjob->{exec}}) {
		    $_->{count} = ++$_->{count} % $_->{repeat_count};
		}
	    } else {
		# Actually run each of the executables (exec's) in task
		my $error= run($cronjob->{exec},
			       map { $_ => $cronjob->{$_} } qw(loud timeout log context name));

		# Send Alert and Notification as necessary
		if ($error) {
		    dbg("WARNING - Task processing error: $error");
                    unless ($opt{disable_alerts} and -e $opt{disable_alerts}) {
                        dbg(send_mail(addr_list => $opt{alert},
                                      subject   => "$opt{subject}: ALERT",
                                      message   => $error,
                                      loud      => 0,
                                      dryrun    => not $opt{email})) ;
                    }
		}

		my $notify_msg = "Task '$cronjob->{name}' ran at ".localtime()."\n"
                     		  . ($opt{notify_msg} || '');
		dbg send_mail(addr_list => $opt{notify},
			      subject   => "$opt{subject}: NOTIFY",
			      message   => $notify_msg,
			      loud      => 0,
			      dryrun    => not $opt{email});

		# Check for errors in output and archive files in log directory
		check_outputs($cronjob) if ($cronjob->{check}
					    and $time >= $cronjob->{next_check_time}
					   );

                # After running check_outputs then disable further alerts if there was
                # an error in the task processing.
                io($opt{disable_alerts})->touch if $error and $opt{disable_alerts};

		exit(0);
	    }
	}
    }

    # Exit if all the cron tasks have been disabled
    exit(0) unless grep { not $_->{disabled} } @crontab;

    sleep (next_time("* * * * *") - time);
}

send_mail(addr_list => $opt{alert},
	  subject   => "$opt{subject}: ALERT",
	  message   => "Quit because of lost heartbeat",
	  loud      => $opt{loud},
	  dryrun    => not $opt{email});

##***************************************************************************
sub check_outputs {
##***************************************************************************
    my $cronjob = shift;

    my $watch_config = io(POSIX::tmpnam);
    my $log_dir = dirname($cronjob->{log});
    my $config .= Config::General->new()->save_string({ check => $cronjob->{check},
							alert => $opt{alert},
							subject => "$opt{subject} (watch_cron_logs)",
							logs => $log_dir,
							n_days => 7,
							master_log => $opt{master_log},
						      });
    $config > $watch_config;

    # email     disable_alerts  not_dis_alerts   not -e disable_alerts    email_flag
    #  0            --             --                 --                   -noemail
    #  1             0              1                 --                   -email
    #  1           <file>           0                 1                    -email
    #  1           <file>           0                 0                    -noemail
    my $email_flag = ($opt{email} and (not $opt{disable_alerts} or not -e $opt{disable_alerts}))
                      ? '-email' 
                      : '-noemail';

    my $print_error_flag = $opt{print_error} ? '-printerror' : '';
    my $error = run([ { cmd => "watch_cron_logs.pl $email_flag $print_error_flag -erase -config $watch_config",
			count => 0,
			repeat_count => 1,
		      }],
		    name => 'watch_cron_logs',
		    context => 1,
		   );
    if ($error) {
	dbg("WARNING - Task processing errors found in watch_cron_logs");
        unless ($opt{disable_alerts} and -e $opt{disable_alerts}) {
            dbg(send_mail(addr_list => $opt{alert},
                          subject   => "$opt{subject}: WARNING",
                          message   => $error,
                          loud      => 0,
                          dryrun    => not $opt{email})) ;
            io($opt{disable_alerts})->touch;
        }
    }

    $watch_config->unlink;
}

##***************************************************************************
sub parse_exec {
##***************************************************************************
    my $cmds = shift;
    local $_;
    my @cmds = (ref $cmds eq "ARRAY") ? @{$cmds} : ($cmds);
    my @cmds_out;
    foreach (@cmds) {
	my $repeat_count = 1;
	my $cmd = $_;
	dbg "cmd = $_\n";
	if (/\A \s* (\d+) \s* : \s* (.+) \Z/x) {
	    $repeat_count = $1;
	    $cmd = $2;
	    dbg "repeat count, cmd = $repeat_count '$cmd'\n";
	}
	push @cmds_out, { cmd => $cmd,
			  count => 0,
			  repeat_count => $repeat_count };
    }
    return \@cmds_out;
}

##***************************************************************************
sub heart_attack {
##***************************************************************************
    dbg "Quit because heart_attack file was found";
    unlink $opt{heartbeat} if (-w $opt{heartbeat});
    exit(0);
}

##***************************************************************************
sub next_time {
##***************************************************************************
    my $val = shift;
    return time + $opt{fast} if $opt{fast};

    # Seems like a bug in Schedule::Cron get_next_execution because I find it returning
    # a two-element array [next_time, '']
    my @time = $cron->get_next_execution_time($val);
    return $time[0];
}

##***************************************************************************
sub run {
##***************************************************************************
    my $cmds = shift;
    my $cmd_pid;
    my $cmd_root;
    my $LOG_FH;

    # Set up run parameters, including optional params spec'd after cmd
    my %par = (loud => 1,
	       @_
	      );

    # Append to the appropriate log file
    if ($par{log}) {
	$LOG_FH = new IO::File ">> $par{log}" or
	  return "ERROR - could not open logfile $par{log}";
    }

    # Run within eval block to be able to set a local alarm to time out if
    # command doesn't finish in in $par{timeout} seconds
    # See perldoc -f alarm
    eval {
	local $SIG{ALRM} = sub { die "alarm\n";
			       }; # NB: \n required
	local $SIG{CHLD};

	alarm $par{timeout} if $par{timeout};

	# Set up commands to run.  Arg to run() can be either a command or an
	# reference to a list of commands
	my @cmds = (ref $cmds eq "ARRAY") ? @{$cmds} : ($cmds);
	for my $cmd (@cmds) {
	    my $first_output = 1;
	    next unless ($cmd->{count} == 0);
	    ($cmd_root) = split ' ', $cmd->{cmd};
	    dbg "Running '$cmd->{cmd}' $cmd->{count} $cmd->{repeat_count}";
	    $cmd_pid = open CMD, "$cmd->{cmd} 2>&1 |" or die "ERROR - Could not start $cmd_root command: $!\n";
	
	    my $exec_out = '';
	    while (<CMD>) {
		$exec_out .= $_;
		if ($first_output and $par{context}) {
		    print $LOG_FH "\n", '#'x60, "\n", " $cmd->{cmd}\n", '#'x60, "\n" if $LOG_FH;
		    $first_output = 0;
		}
		my $time_string = $par{context} ? strftime("<<%Y-%b-%d %H:%M>> ", localtime) : '';
		print $LOG_FH $time_string . $_ if $LOG_FH;
	    }
	    dbg("$par{name} output:") if $par{name};
	    dbg($exec_out);

	    # Close and make sure all is OK.  'die $! ? "A" : "B"' doesn't parse in xemacs)
	    unless (close CMD) {
		if ($!) { die "ERROR - Couldn't close $cmd_root pipe: $! \n"; }
		else    {
                    my @exec_out = split("\n", $exec_out);
                    $exec_out = join("\n", (@exec_out > 50) ? @exec_out[($#exec_out-50..$#exec_out)] : @exec_out);
                    die "WARNING - '$cmd->{cmd}' returned non-zero status: $?\n$exec_out\n";
                }
	    }
	}
	alarm 0;
    };

    if ($@) {
	return $@ unless $@ eq "alarm\n"; # propagate unexpected errors

	my $warning = "WARNING - $cmd_root command timed out ".localtime()."\n";
	dbg $warning;
	print $LOG_FH $warning;
				 
	# Kill the cmd process.  See Ska::Process for a more detailed routine that
	# finds all child processes with same group pid and kills them one at a time.
	# This is a bad idea here because there may be other "cron" processes with
	# same gid that should not be killed

	kill 9 => $cmd_pid;
	sleep 5;
	close CMD;
    }

    $LOG_FH->close() if $LOG_FH;
    return;			# For this routine, undef => success
}

##***************************************************************************
# our very own debugging routine
# ('guess everybody has its own style ;-)
sub dbg  {
##***************************************************************************
  if ($opt{loud}) {
    my $args = join('',@_) || "";
    my $caller = (caller(1))[0];
    my $line = (caller(0))[2];
    $caller ||= $0;
    if (length $caller > 22) {
      $caller = substr($caller,0,10)."..".substr($caller,-10,10);
    }
    my $align = ' 'x40;
    $args =~ s/\n/\n$align/g;
    print STDERR sprintf ("%02d:%02d:%02d [%22.22s %4.4s]  %s\n",
			  (localtime)[2,1,0],$caller,$line,$args);
  }
}

#########################################################################
sub help {
#########################################################################
  my ( $verbose ) = @_;

  my $exitval = 0;

  if ( $verbose == -1 )
  {
    $exitval = 'NOEXIT';
    $verbose = 2;
  }
  require IO::Pager::Page if $verbose < 2;
  require Pod::Usage;
  Pod::Usage::pod2usage( { -exitval => $exitval, -verbose => $verbose } );
}

__END__

=pod

=head1 NAME

task_schedule.pl - Run a set of tasks at predetermined intervals ala crontab.

=head1 SYNOPSIS

task_schedule.pl -config <config_file> [options]

=head1 OPTIONS

=over 8

=item B<-config <config_file>>

This option is mandatory and gives the name of a file containing the
task scheduler configuration.  This file specifies the jobs to be 
run, email addresses for alerts, and all other program options.
The test config file (t/data/test.config) has further documentation.

=item B<-loud>

Show exactly what task_schedule is doing

=item B<-no-email>

Print error alerts but do not actually send emails.  

=item B<-fast <time>>

For development and testing, ignore task cron specifications and instead run
each job every <time> seconds.

=item B<-iterations <number>>

Run tasks a maximum of <number> iterations.  The default is no limit, but another
typical value is 1, in which case task_schedule will run the task once and quit.
This makes sense for tasks that run infrequently.

=item B<--help>

print this usage and exit.

=back

=head1 DESCRIPTION

B<Task_schedule> is a tool to run various jobs at regular intervals in the
manner of crontab.  This tool runs jobs, captures job output in log files and
make sure jobs finish in a timely manner.  Alerts are sent to an email list if
any severe errors occur.

The tool can be run interactively for development purposes, but in a production 
environment it is intended to be run as a regular cron job which is scheduled every 
minute.  If B<task_schedule> detects that an instance is already successfully running 
then it simply quits.  This ensures maximum reliability in case of temporary hardware 
issues or reboots.

To detect another instance of running jobs, B<task_schedule> looks at a "heartbeat" file 
that is touched every minute.  If the file is older than a specified age (typically 200
seconds) then the jobs are not running and B<task_schedule> begins.  Note that the heartbeat
file is specific to the particular configuration, so there can be multiple
sets of jobs running as long as none of the files collide.

B<Task_schedule> can be shut down gracefully by deleting its heartbeat file.  (If you
think suddenly finding yourself without a heartbeat could be graceful).  

=head1 EXAMPLE

 /proj/sot/ska/bin/task_schedule.pl -config my_task.config

=head1 EXAMPLE CONFIG FILE

The example config file below illustrates all the available configuration options.

 loud              0                  # Run loudly
 subject           task_schedule: task  # Subject line of emails
 email             1                  # Set to 0 to disable emails (alert, notify)
 timeout           1000               # Default tool timeout
 heartbeat_timeout 120                # Maximum age of heartbeat file (seconds)
 iterations        0                  # Maximum task iterations.  Zero => no limit.
 master_log        watch_cron.log     # Master log (from all tasks) if checking is enabled
 
 # Data files and directories.  The *_dir vars can have $ENV{} vars which
 # get interpolated.  The '/task' would be replaced by the actual task name.

 data_dir     	$ENV{SKA_DATA}/task          # Data file directory
 log_dir      	$ENV{SKA_DATA}/task/logs     # Log file directory
 bin_dir      	$ENV{SKA_SHARE}/task         # Bin dir (optional, see task def'n)
 heartbeat    	task_sched_heartbeat	     # File to ensure sched. running (in data_dir)
 heart_attack 	task_sched_heart_attack      # File to kill task_schedule nicely
 disable_alerts task_sched_disable_alerts    # File to stop alerts from being sent
 disable_alerts 0                            # If set to a false value then never disable alerts

 # Email addresses that receive an alert if there was a severe error in
 # running jobs (i.e. couldn't start jobs or couldn't open log file).
 # Processing errors *within* the jobs are caught with watch_cron_logs

 alert	     first_person@head.cfa.harvard.edu
 alert	     another_person@head.cfa.harvard.edu

 # Email addresses that receive notification that task ran.  This
 # will be sent once per task cron interval, so this list should
 # probably be left empty for tasks running every minute!

 notify	     first_person@head.cfa.harvard.edu
 notify	     another_person@head.cfa.harvard.edu

 # Optional message to include in the notification email
 notify_msg <<NOTIFY
  Please see the web page to check on the weather:
  http://weather.yahoo.com/forecast/USNH0169_f.html
 NOTIFY

 # Define task parameters
 #  cron: Job repetition specification ala crontab.  Defaults to '* * * * *'
 #  check_cron: Crontab specification of log (processing) checks via watch_cron_logs.
 #        Defaults to '0 0 * * *'.  
 #  exec: Name of executable.  Can have $ENV{} vars which get interpolated.  
 #        If bin_dir is defined then bin_dir is prepended to non-absolute exec names.
 #  log: Name of log.  Can have $ENV{} vars which get interpolated.
 #        If log is set to '' then no log file will be created (not recommended)
 #        If log is not defined it is set to <task_name>.log.
 #        If log_dir is defined then log_dir is prepended to non-absolute log names.
 #  timeout: Maximum time (seconds) for job before timing out
 #  check: Specify reg-ex's to watch for in output from task1.  This is done
 # 	   with a call to watch_cron_logs based on this definition.  Flagged
 # 	   errors are sent to the alert list.  If no <check ..> 
 # 	   parameter is given then no checking is done.  See
 # 	   watch_cron_logs doc for more info.  If an alert is sent then further
 #         alerts are disabled until the file specified by disable_alerts
 #         in the data directory is removed.


 # Typical task setup to run something called task1.pl with argument 20
 # and a few checks for error/warning messages.  The '*' glob for the
 # check file means to look in any file in the log directory.
 # This example runs every minute and checks the output logs once a day
 # at 1am.  At that time the log output is archived in daily.? directories.

  <task task1>
        cron       * * * * *
        check_cron 0 1 * * *
        exec task1.pl 20
        timeout 15
        <check>
           <error>
             #    File          Reg. Expression (case insensitive)
             #  ----------      ---------------------------
                *               use of uninitialized value
                *               warning
                *               (?<!Program caused arithmetic )error
                *               fatal
           </error>
       </check>
  </task>

 # This has multiple jobs which get run in specified order
 # Note the syntax 'exec <number> : cmd', which means that the given command is
 # executed only once for each <number> of times the task is executed.  In the
 # example below, the commands are done once each 1, 2, and 4 minutes, respectively.
 # The 'context 1' enables print context information in the log file
 # which includes the name and a timestamp for each output. 

 <task task2>
       cron * * * * *
       log  task2_with_nonstandard.log
       exec task1.pl 1
       exec 2 : $ENV{SKA_BIN}/task1.pl 2
       exec 4 : task1.pl 3
       timeout 100
       context 1
 </task>
  
=head1 AUTHOR

Tom Aldcroft (taldcroft@cfa.harvard.edu)
Copyright 2004-2006 Smithsonian Astrophysical Observatory
