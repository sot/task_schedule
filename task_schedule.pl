#!/usr/bin/env /proj/sot/ska/bin/perlska
# #!/usr/bin/env /proj/axaf/bin/perl

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
 
##***************************************************************************
##   Some initialization
##***************************************************************************

$| = 1;
%ENV = CXC::Envs::Flight::env('ska','tst'); # Adds Ska and TST env to existing ENV

##***************************************************************************
##   Get config and cmd line options
##***************************************************************************

our %opt = (config => 'data/test.config',
	    email  => 1,
	   );

GetOptions (\%opt,
	    'config=s',
	    'loud!',
	    'help!',
	    'email!',
	    'fast=i',
	   );

help(2) if ($opt{help});

%opt = (ParseConfig(-ConfigFile => $opt{config}), %opt) if (-r $opt{config});

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

# Fix heartbeat file name
if ($opt{heartbeat} !~ m|\A \s* /|x and $opt{data_dir}) {
    $opt{heartbeat} = "$opt{data_dir}/$opt{heartbeat}";
}
dbg "heartbeat=$opt{heartbeat}";

while (my ($name, $task) = each %{$opt{task}}) {
    $task->{exec} = parse_exec($task->{exec});
#    for ((ref $task->{exec} eq "ARRAY") ? @{$task->{exec}} : ($task->{exec})) {
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
    system("mkdir -p $opt{log_dir}") == 0
      or die send_alert("ERROR - : Could not open log dir $opt{log_dir}");
}

# Print the final program options
dbg Dumper \%opt;

##***************************************************************************
##  Check heartbeat file and exit gracefully if the file is recent
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
    my $next_time = next_time($task->{cron});
    
    push @crontab, {cron  => $task->{cron},
		    exec  => $task->{exec},
		    context => $task->{context},
		    loud     => $opt{loud},
		    timeout  => $task->{timeout} || $opt{timeout},
		    log      => $task->{log},
		    next_time => $next_time,
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
    system("touch $opt{heartbeat}");
    my $pid;
    my $time = time;
    foreach my $cronjob (@crontab) {
	if ($time >= $cronjob->{next_time}) {
	    if ($pid = fork) {
		$cronjob->{next_time} = next_time($cronjob->{cron});
		foreach (@{$cronjob->{exec}}) {
		    $_->{count} = ++$_->{count} % $_->{repeat_count};
		}
	    } else {
		print Dumper $cronjob;
		my $error = run($cronjob->{exec},
				map { $_ => $cronjob->{$_} } qw(loud timeout log context)
			       );
		if ($error) {
		    send_alert($error);
		}
		exit(0);
	    }
	}
    }
    sleep (next_time("* * * * *") - time);
}

send_alert("Quit because of lost heartbeat");

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
sub send_alert {
##***************************************************************************
    my $alert_message = shift;

    my $addr_list = ref($opt{alert}) eq "ARRAY" ? join(',', @{$opt{alert}}) : $opt{alert};
    my $mail_cmd = "mail -s \"$opt{subject}: ALERT\" $addr_list";

    my $message = "Severe processing error:\n $alert_message\n";

    # If specified then do mail command else just print errors to stdout
    if ($opt{email}) {
	open MAIL, "| $mail_cmd"
	  or die "Could not start mail to send alert notification";
	print MAIL $message;
	close MAIL;
    } 
    
    dbg $mail_cmd;
    dbg $message;

    return $alert_message;
}

##***************************************************************************
sub next_time {
##***************************************************************************
    return $opt{fast} ? time + $opt{fast} : $cron->get_next_execution_time(shift);
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

    # Open log file for task
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

	alarm $par{timeout} if $par{timeout};

	# Set up commands to run.  Arg to run() can be either a command or an
	# reference to a list of commands
	my @cmds = (ref $cmds eq "ARRAY") ? @{$cmds} : ($cmds);
	for my $cmd (@cmds) {
	    my $first_output = 1;
	    next unless ($cmd->{count} == 0);
	    ($cmd_root) = split ' ', $cmd->{cmd};
	    dbg "Running $cmd->{cmd} $cmd->{count} $cmd->{repeat_count}";
	    $cmd_pid = open CMD, "$cmd->{cmd} 2>&1 |" or die "ERROR - Could not start $cmd_root command\n";
	
	    while (<CMD>) {
		dbg $_;
		dbg "context = $par{context}\n";
		if ($first_output and $par{context}) {
		    print $LOG_FH "\n", '#'x60, "\n", " $cmd->{cmd}\n", '#'x60, "\n";
		    $first_output = 0;
		}
		my $time_string = $par{context} ? strftime("<<%Y-%b-%d %H:%M>> ", localtime) : '';
		print $LOG_FH $time_string . $_;
	    }
	    close CMD;
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

    $LOG_FH->close();
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
    my $align = ' 'x39;
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

 # Configuration file for watch_cron_logs operation in TST area

 loud         0                       # Run loudly
 subject      TST tasks               # subject of email
 timeout      1000                    # Default tool timeout
 heartbeat_timeout 120                # Maximum age of heartbeat file (seconds)

 # Data files and directories.  The *_dir vars can have $ENV{} vars which
 # get interpolated.  (Note lack of task name after TST_DATA because this is just for test).

 data_dir     $ENV{SKA_DATA}          # Data file directory
 log_dir      $ENV{SKA_DATA}/Logs     # Log file directory
 bin_dir      $ENV{SKA_BIN}           # Bin dir (optional, see task def'n)
 master_log   Master.log              # Composite master log (created in log_dir)
 heartbeat    heartbeat		     # File to ensure sched. running (in data_dir)

 # Email addresses that receive an alert if there was a severe error in
 # running jobs (i.e. couldn't start jobs or couldn't open log file).
 # Processing errors *within* the jobs are caught with watch_cron_logs

 alert	     first_person@head.cfa.harvard.edu
 alert	     another_person@head.cfa.harvard.edu

 # Define task parameters
 #  cron: Job repetition specification ala crontab
 #  exec: Name of executable.  Can have $ENV{} vars which get interpolated.  
 #        If bin_dir is defined then bin_dir is prepended to non-absolute exec names.
 #  log: Name of log.  Can have $ENV{} vars which get interpolated.
 #        If log is set to '' then no log file will be created
 #        If log is not defined it is set to <task_name>.log.
 #        If log_dir is defined then log_dir is prepended to non-absolute log names.
 #  timeout: Maximum time (seconds) for job before timing out

 # # Task that isn't found, generating email
  <task task1>
        cron * * * * *
        exec task1.pl 20
        log  task1_with_nonstandard.log
        timeout 15
  </task>

 # This has multiple jobs which get run in specified order
 # Note the syntax 'exec <number> : cmd', which means that the given command is
 # executed only once for each <number> of times the task is executed.  In the
 # example below, the commands are done once each 1, 2, and 4 minutes, respectively.
 # The 'context 1' enables print context information for each task command
 # which includes the name and a timestamp for each output. 

 <task task2>
       cron * * * * *
       exec task1.pl 1
       exec 2 : $ENV{SKA_BIN}/task1.pl 2
       exec 4 : task1.pl 3
       timeout 100
       context 1
 </task>
  
=head1 AUTHOR

Tom Aldcroft (taldcroft@cfa.harvard.edu)
