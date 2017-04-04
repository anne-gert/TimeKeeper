#!/usr/bin/perl

use strict;
use File::Basename;

use lib dirname $0;  # use current directory as well
use TimeKeeper::Gui;


Init @ARGV;
Run;
Done;


