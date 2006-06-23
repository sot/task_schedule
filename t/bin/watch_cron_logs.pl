#!/usr/bin/env /proj/axaf/bin/perl

# Keep a 7-day daily archive of log outputs from cron jobs
# 
# Author:  T. Aldcroft
# Created: 29-July-2004

use warnings;
use File::Basename;
use Getopt::Long;
use Config::General;
use Data::Dumper;

sub run($) {
  my $command = shift;
  print "$command\n" if $opt{loud} or $opt{dryrun};
  unless ($opt{dryrun}) {
      system($command) == 0 or die $!;
  }
}

our %opt = (config => 'data/default.config');

GetOptions (\%opt,
	    'logs=s',
	    'config=s',
	    'subject=s',
	    'erase!',
	    'loud!',
	    'help!',
	    'dryrun!',
	   );

if ( $opt{help} ) {
    use lib '/proj/axaf/simul/lib/perl';
    require 'usage.pl';
    usage(0);
}

%opt = (ParseConfig(-ConfigFile => $opt{config}), %opt) if (-r $opt{config});

our $n_days     = $opt{n_days};
our $logs       = $opt{logs};
our $master_log = $opt{master_log};

# Assemble the grep checks that are done on specified log files
foreach (qw(error required_always required_when_output)) {
    while (($file, $val) = each %{$opt{check}{$_}}) {
	@{$rexp{$_}{$file}} = ref $val eq "ARRAY" ? @{$val} : ($val);
    }
}

# Slide every daily directory up by one and delete 8th day if there
for $i (reverse (0 .. $n_days-1)) {
    $i1 = sprintf "%d", $i+1;
    run "mv $logs/daily.$i $logs/daily.$i1" if -e "$logs/daily.$i";
}

run "rm -rf $logs/daily.$n_days" if -e "$logs/daily.$n_days";

# Make directory for newest log data

run "mkdir $logs/daily.0";


# Concat log info into a single MASTER log file in the same directory
# and accumulate log entries for each cron task for checking later

@files = grep {-r and not -d} glob("$logs/*");	# Grab all log files
@ARGV =  @files;			# Set up to read all log file data

# Initialize log strings and errors
foreach $file (@files) {
    @{$log{$file}} = ();
    @{$errors{$file}} = ();
}

# Now actually read the data and write to master log file, with headers
# indicating each new log file

our $file = "";
our $line;
while (<ARGV>) {
    # If the input ARGV file has changed then its a new log file
    if ($ARGV ne $file) {
	$file = $ARGV;
	$line = 1;
    }
    push @{$log{$file}}, $_;	# Accumulate log entries for each cron task for checking later
    foreach $rexp (@{$rexp{error}{basename($file)}}, @{$rexp{error}{'*'}}) {
	push @{$errors{$file}}, "** ERROR - Matched '$rexp' at line $line\n" if /$rexp/i;
    }
    $line++;
}

# Make sure that the required outputs are there
foreach $req (qw(required_always required_when_output)) {
    foreach $file (@files) {
	# If there is no output, skip file for 'required_when_output' checks
	next if (not @{$log{$file}} and $req eq 'required_when_output'); 

	foreach $rexp (@{$rexp{$req}{basename($file)}}) {
	    push @{$errors{$file}}, "** ERROR - No instance of '$rexp' in log output\n"
	      unless grep /$rexp/i, @{$log{$file}};
	}
    }
}

# Create the master log file unless this is a dry run, otherwise just print to STDOUT

our $master_file = "$logs/daily.0/$master_log";
unless ($opt{dryrun}) {
    open MASTER, "> $master_file" or die "Could not open $master_file";
    select MASTER;
}
foreach $file (@files) {
    next unless @{$log{$file}} or @{$errors{$file}};	# No output if log file is empty
    printf "%s %s %s\n", "*"x20, basename($file), "*"x(30-length(basename($file)));
    if (@{$errors{$file}}) {
	print @{$errors{$file}};
	print "*"x60,"\n";
    }
    print @{$log{$file}};
    print "\n\n";
}
close MASTER unless $opt{dryrun};
select STDOUT;

# Move all log files in $logs to $logs/daily.0 and touch to create
# new (empty) log files

foreach (@files) {
    next if /daily.\d\Z/;
    if ($opt{erase}) {
	run "mv $_ $logs/daily.0 ; touch $_; chgrp aspect $_; chmod g+w $_";
    } else {
	run "cp $_ $logs/daily.0/";
    }
}

# Email "notifications", which is currently just a copy of the $master_log file

if (defined $opt{daily}) {
    my $addr_list = ref($opt{daily}) eq "ARRAY" ? join(',', @{$opt{daily}}) : $opt{daily};
    run "mail -s \"$opt{subject}\" $addr_list < $master_file";
}

# Now check contents of log files and send alerts (probably pagers) if needed

my @err_files;
if (defined $opt{alert}) {
    # Check if there were any errors and issue alerts if so
    @err_files = grep { @{$errors{$_}} } @files;

    if (@err_files) {
        # Build the address list and mail command for sending alerts
	my $addr_list = ref($opt{alert}) eq "ARRAY" ? join(',', @{$opt{alert}}) : $opt{alert};
	my $cmd = "mail -s \"$opt{subject}: ALERT\" $addr_list";

	# If not dry run then do mail command else just print errors to stdout
	unless ($opt{dryrun}) {
	    open MAIL, "| $cmd"
	      or die "Could not start mail to send alert notification";
	    select MAIL;
	} 
	print STDOUT "$cmd\n" if $opt{loud};
	print "Errors in files: \n";
	map {print basename($_),"\n" } @err_files;
	close MAIL unless $opt{dryrun};
	select STDOUT;
    }
}

exit( scalar @err_files );

=head1 NAME

watch_cron_logs.pl - Watch output log files from a set of cron jobs
                     and collect outputs into daily archives.  This
                     tool should be run once daily.

=head1 SYNOPSIS

watch_cron_logs.pl [options]

=head1 OPTIONS

=over 8

=item B<-logs <log_file_directory>>

Look for log files in <log_file_directory>

=item B<-erase>

Erase contents of log files each day

=item B<-loud>

Show exactly what watch_cron_logs is doing

=item B<-dryrun>

Print log file summary to screen and print warnings, but do not actually
create any files or send emails

=item B<-config <config_file>>

Configuration file controlling behavior of watch_cron_logs.  Specifies defaults
for command line options as well as daily and alert email recipients, and 
criteria for issuing alerts.  See config file for documentation.

=item B<-subject <email_subject>>

'Subject' of email notifications

=item B<--help>

print this usage and exit.

=back

=head1 DESCRIPTION

B<watch_cron_logs> is normally used as a cron job itself to monitor
the outputs of other cron tasks on a daily basis.  It collects the
task outputs into daily archives accumulate for a week.  It will
also do specific error detection and email notification, but not yet. 

=head2 EXAMPLE

 /proj/sot/ska/bin/watch_cron_logs.pl -logs /proj/sot/tst/ops

=head1 AUTHOR

Tom Aldcroft (taldcroft@cfa.harvard.edu)
