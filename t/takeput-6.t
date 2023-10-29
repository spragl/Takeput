#!/usr/bin/perl
# t/takeput-6.t
use strict;
use experimental qw(signatures);

use Test::More 'no_plan';

our $dir;
my $tdir;
BEGIN {
    use File::Basename qw(dirname);
    use Cwd qw(abs_path);
    $tdir = dirname(abs_path($0));
    $dir = $tdir =~ s/[^\/]+$/lib/r;
    };

use File::Spec;

use lib $dir;

use_ok 'File::Takeput' , qw(plunk grab fgrab); # 1

our $fn = $tdir.'/takeput-6.txt';

unlink $fn;

ok (plunk($fn , create => 1)->('abgcdgabgefg')); # 2

ok (File::Takeput::set(separator => 'g' , newline => 'x')); # 3

package test_namespace;

use lib $main::dir;

use File::Takeput qw(grab fgrab);

my $fn = $main::fn;

main::ok (File::Takeput::set(separator => 'b' , newline => 'x')); # 4
my @content;
main::ok (@content = grab($fn)); # 5
main::ok ((join '' , @content) eq 'axgcdgaxgefg'); # 6
main::ok (scalar @content == 3); # 7

package main;

my @content;
ok (@content = grab($fn)); # 8
ok ((join '' , @content) eq 'abxcdxabxefx'); # 9
ok (scalar @content == 4); # 10

open STDERR , '>' , File::Spec->devnull();

ok (not grab($fn , error => 2)); # 11
ok (not grab($fn , patience => -5)); # 12
ok (not grab($fn , separator => '')); # 13
ok (not grab($fn , x => 1)); # 14
ok (not grab($fn , x => {y => 1})); # 15

my $read;
ok (not fgrab($fn , x => 1)); # 16
ok ($read = fgrab($fn.'x')); # 17
ok (not $read->()); # 18

__END__
