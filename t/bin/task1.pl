#!/usr/bin/env perl

my $sleep = shift @ARGV || 5;
my $arg = shift @ARGV || "default";

print "Hello from task1 $sleep $arg at " . localtime()."\n";
sleep $sleep;
print "Hello from task1 $sleep $arg at " . localtime()." after sleep\n";
