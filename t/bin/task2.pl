#!/usr/bin/env perl

my $sleep = shift @ARGV || 10;

print "Hello from task2 at " . localtime()."\n";
sleep $sleep;
