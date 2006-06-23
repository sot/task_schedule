#!/usr/bin/env perl

my $sleep = shift @ARGV || 5;

print "Hello from task1 $sleep at " . localtime()."\n";
sleep $sleep;
print "Hello from task1 $sleep at " . localtime()." after sleep\n";
