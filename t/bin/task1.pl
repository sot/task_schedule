#!/usr/bin/env perl

my $sleep = shift @ARGV || 5;

print "Hello from task1 at " . localtime()."\n";
sleep $sleep;
