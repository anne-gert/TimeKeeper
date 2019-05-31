package TimeKeeper::Utils;

# This module contains general purpose functions that can be used by multiple
# other modules.

use strict;
use Carp;
use File::Basename;
use File::Temp qw/tempfile/;

use File::Spec::Functions qw/catdir catfile catpath splitdir splitpath/;
use Time::Local;

BEGIN
{
	use Exporter ();
	our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

	# set the version for version checking
	$VERSION     = 1.00;

	@ISA         = qw(Exporter);
	@EXPORT      = qw(
		info
		redirect_debug_info

		get_perl_value
		round
		get_random
		is_integer is_regex

		get_startup_path
		mkfiledir create_temp_text
		unix2dos dos2unix
		copy_file

		get_timestamp get_week is_leapyear
		format_datetime_iso
		format_datetime_full format_datetime_hm
		format_date format_date_iso
		format_time format_time_hm
		parse_datetime

		get_tz format_tz
	);
	@EXPORT_OK   = qw();
	%EXPORT_TAGS = ();  # eg: TAG => [ qw!name1 name2! ],
}


##############################################################################
### Global variables

# constants
our @DoW = qw/Sun Mon Tue Wed Thu Fri Sat/;

# variables
our $CbGetDebugInfoFile = undef;


##############################################################################
### Utility functions

# forward declarations
sub mkfiledir;

# Set the path where to write the debug info log entries to.
# The argument is a coderef to a function that returns the current filename.
# Set to undef to use STDOUT.
sub redirect_debug_info
{
	my ($get_fname) = @_;

	# Print redirection to previous log
	my $fname = $get_fname;
	$fname = &$fname if $fname;
	$fname = "STDOUT" unless $fname;
	info("Redirecting debug info to '$fname'\n");
	# Change the path now
	$CbGetDebugInfoFile = $get_fname;
}

# This function prints info. All should use it, so that it can be redirected
# more easily.
sub info
{
	# Create timestamp to prefix the lines
	my @parts = localtime;
	++$parts[4]; $parts[5] += 1900;
	my $ts = sprintf "%04d-%02d-%02d %2d:%02d:%02d",
		@parts[5,4,3,2,1,0];
	# Prefix all lines
	local $_ = join "", @_;
	s/^/$ts: /mg;
	# Print all the lines
	my $path = $CbGetDebugInfoFile;
	$path = &$path if $path;  # call it
	if ($path)
	{
		mkfiledir $path;
		open my $LOG, ">> $path" or die "Cannot open '$path': $! (log message: '$_')";
		print $LOG $_;
		close $LOG;
	}
	else
	{
		print $_;
	}
}

# Escapes the value, so that it can be used in a perl variable assignment.
sub get_perl_value
{
	my ($val) = @_;

	if (!defined $val)
	{
		return "undef";
	}
	elsif ($val =~ /^[+-]?\d+(\.\d*)?$/)
	{
		# Regard values like +1, -1, 1, 1., 1.2, etc as numeric. These
		# don't need escaping
		return $val;
	}
	else
	{
		# Regard it as a string, escape it and add (single) quotes
		$val =~ s/(['\\])/\\$1/g;
		return "'$val'";
	}
}

# Round $value to the nearest multiple of $step.
sub round
{
	my ($value, $step) = @_;

	# Note that calculating the correctly rounded value with int() is not
	# simple straightforward, because one needs to take into account
	# that $value and/or $step might be negative.
	return sprintf("%.0f", $value / $step) * $step;
}

# Returns a random hex string of the specified number of digits.
sub get_random
{
	my ($length) = @_;

	my $s = "";
	# Collect digits
	while (length($s) < $length)
	{
		$s .= sprintf "%04X", rand(0x10000);
	}
	# truncate surplus
	$s = substr $s, 0, $length;
	return $s;
}

# Returns true if the argument is an integer numeric.
sub is_integer($)
{
	my ($value) = @_;

	return $value =~ /^[+-]?\d+$/;
}

# Returns true if the argument is a regex (i.e. qr/.../).
sub is_regex($)
{
	my ($value) = @_;

	return ref $value eq "Regexp";
}


##############################################################################
### File and directory functions

# The path from where this script is started.
# If arguments are given, they are added to this path.
our $_startupPath;
sub get_startup_path
{
	my @dirs = @_;

	$_startupPath = dirname $0 unless defined $_startupPath;
	return catfile $_startupPath, @dirs;
}

# Check if directory of the specified filename exists and create it if not.
sub mkfiledir
{
	my ($path) = @_;

	my ($vol, $dirs, $base) = splitpath $path;
	my @dirs = splitdir $dirs;

	my @d;
	while (@dirs)
	{
		push @d, shift @dirs;
		my $dir = catpath $vol, catdir(@d);
		#info "mkfiledir(): Checking '$dir'\n";
		mkdir $dir unless -d $dir;
	}
}

# Create a temporary file with the specified contents.
# Returns the filename.
sub create_temp_text
{
	my ($contents) = @_;

	# Create filename (return handle to open it as well to avoid race condition)
	my ($fh, $fname) = tempfile("tempXXXX", TMPDIR => 1, SUFFIX => ".txt", UNLINK => 1);
	# Put log into that file
	print $fh $contents;
	close $fh;
	# Return the name of the file
	return $fname;
}

# Converts all linebreaks from unix format (lf) into dos format (crlf).
sub unix2dos
{
	my ($text) = @_;

	$text =~ s/(?<!\015)\012/\015\012/g;  # replace every lf by crlf if there is no cr already
	return $text;
}

# Converts all linebreaks from dos format (crlf) into unix format (lf).
sub dos2unix
{
	my ($text) = @_;

	$text =~ s/\015\012/\012/g;  # replace every crlf by lf
	return $text;
}

# Copy the file contents from $fname_from to $fname_to.
# Dies when $fname_from does not exist. Creates and/or overwrites $fname_to
# including directories.
sub copy_file
{
	my ($fname_from, $fname_to) = @_;

	open my $fh_from, "< $fname_from" or die "Cannot open source file '$fname_from': $!";
	mkfiledir $fname_to unless -e $fname_to;
	open my $fh_to, "> $fname_to" or die "Cannot open destination file '$fname_to': $!";
	print $fh_to $_ while <$fh_from>;
	close $fh_to;
	close $fh_from;
}

##############################################################################
### Datetime/Timezone functions

# Returns the current timestamp, which is a number of seconds since a certain
# epoch time.
sub get_timestamp
{
	return time();
}

# Returns true if the specified year is a leapyear, false otherwise.
sub is_leapyear
{
	my ($year) = @_;

	return 1 if $year % 400 == 0;  # divisible by 400
	return 0 if $year % 100 == 0;  # not divisible by 100
	return 1 if $year % 4 == 0;  # divisible by 4
	return 0;  # otherwise not a leapyear
}

# The rules (ISO8601) for the week number are as follows:
# 1) A week starts on Monday (day number 1 from localtime).
# 2) The week number depends on that week's Thursday.
# 3) The week number is the number of Thursdays in the year.
sub get_week
{
	my ($timestamp) = @_;

	#print "===== WEEK NUMBER FOR $timestamp =====\n";
	my ($year, $wday, $yday) = (localtime $timestamp)[5, 6, 7];
	#print "year=$year, wday=$wday, yday=$yday\n";
	$wday = ($wday - 1) % 7;  # rotate so that Monday (=1) goes to 0
	#print "Number of days to Monday: $wday\n";
	my $toThursday = 3 - $wday;  # number of days to the right Thursday
	#print "Number of days to this week's Thursday: $toThursday\n";
	# $yday is number of days in this year to get to today. January 1 is 0.
	# Extend this day's $yday to this day's week's Thursday by adding
	# $toThursday.
	my $daynum = $yday + $toThursday;
	#print "DayNum=$daynum\n";
	# The $daynum value is depicted in a table below. For
	# simplicity's sake, assume the previous year has 52 weeks (can be 53)
	# and the year has 365 (can also be 266).
	#
	#                     December       |           January              |
	# Date     25  26  27  28  29  30  31| 01  02  03  04  05  06  07  08 |
	# YDay    358 359 360 361 362 363 364|  0   1   2   3   4   5   6   7 |
	# -----------------------------------+------------------------------- +
	# Days     MO  tu  we  TH  fr  sa  su| MO  tu  we  TH  fr  sa  su  MO |
	# DayNum  361 361 361 361 361 361 361|  3   3   3   3   3   3   3  10 |
	# Weeks                            5X|1                         1  2  |
	# Days     tu  we  TH  fr  sa  su| MO  tu  we  TH  fr  sa  su  MO  tu |
	# DayNum  360 360 360 360 360 360|367   2   2   2   2   2   2   9   9 |
	# Weeks                        5X|1                         1  2      |
	# Days     we  TH  fr  sa  su| MO  tu  we  TH  fr  sa  su  MO  tu  we |
	# DayNum  359 359 359 359 359|366 366   1   1   1   1   1   8   8   8 |
	# Weeks                    5X|1                         1  2          |
	# Days     TH  fr  sa  su| MO  tu  we  TH  fr  sa  su  MO  tu  we  TH |
	# DayNum  358 358 358 358|365 365 365   0   0   0   0   7   7   7   7 |
	# Weeks                5X|1                         1  2              |
	# Days     fr  sa  su  MO  tu  we  TH  fr  sa  su| MO  tu  we  TH  fr |
	# DayNum  357 357 357 364 364 364 364  -1  -1  -1|  6   6   6   6   6 |
	# Weeks                5X                      5X|1                   |
	# Days     sa  su  MO  tu  we  TH  fr  sa  su| MO  tu  we  TH  fr  sa |
	# DayNum  356 356 363 363 363 363 363  -2  -2|  5   5   5   5   5   5 |
	# Weeks            5X                      5X|1                       |
	# Days     su  MO  tu  we  TH  fr  sa  su| MO  tu  we  TH  fr  sa  su |
	# DayNum  355 362 362 362 362 362 362  -3|  4   4   4   4   4   4   4 |
	# Weeks        5X                      5X|1                           |
	#
	# From the above table, it can be derived that:
	# 1) If DayNum >= number of days in year -> DayNum same as 3 days later
	#    The WeekNum wil always be 1
	# 2) If DayNum < 0 -> DayNum same as 3 days earlier
	# 3) WeekNum = floor(DayNum / 7) + 1
	#
	# Note that the weeknumber is equal to the number of Thursdays in the
	# year up that week. A year has 52 weeks plus 1 day (or 2 in
	# leapyears), so a year has 52 Thursdays or 53 if the last day of the
	# year is a Thursday or the second last day is a Thursday and it is a
	# leapyear.
	#
	# Reasoning further, we can see:
	# 2a) If DayNum == -1 -> WeekNum = 53
	# 2b) If DayNum == -2 -> WeekNum = 53 if previous year is a leapyear
	# 2c) If DayNum < 0 otherwise -> WeekNum = 52

	my $week;
	my $maxday = is_leapyear($year) ? 366 : 365;
	if ($daynum < 0)
	{
		if ($daynum == -1)
		{
			# Rule 2a: Last year has 53 Thursdays
			$week = 53;
		}
		elsif ($daynum == -2 && is_leapyear($year - 1))
		{
			# Rule 2b: Last year has 53 Thursdays
			$week = 53;
		}
		else
		{
			# Rule 2c: Last year has 52 Thursdays
			$week = 52;
		}
	}
	elsif ($daynum >= $maxday)
	{
		# Rule 1: This should be week 1
		$week = 1;
	}
	else
	{
		# Rule 3: Normal calculation
		$week = int($daynum / 7) + 1;
	}
	#print "Week number: $week\n";

	return $week;
}

# Executes an automatic test of the get_week() function.
sub Test_get_week
{
	my ($prevWeekNr, $weekNr);
	my ($prevYear, $year);
	my $ts = 12*60*60;  # 1970-1-1 12:00:00, the middle of the first day
	while ($ts < 0x7FFF_FFFF)
	{
		my @dt = localtime $ts;
		my $year = $dt[5] + 1900;
		my $wday = $dt[6];
		if ($year != $prevYear)
		{
			print "Testing year $year\n";
		}

		# Calculate week number
		$weekNr = get_week $ts;

		# Evaluate calculation
		my $error = 0;
		if (defined $prevWeekNr)
		{
			if ($wday == 1)
			{
				# This is a Monday, the week should increase
				if ($weekNr == 1)
				{
					# Year crossing only at week 52 or 53
					if ($prevWeekNr != 52 &&
						$prevWeekNr != 53)
					{
						$error = 1;
					}
				}
				else
				{
					# Normal week increase
					if ($weekNr != $prevWeekNr + 1)
					{
						$error = 1;
					}
				}
			}
			else
			{
				# Non-Monday, expect same week
				if ($weekNr != $prevWeekNr)
				{
					$error = 1;
				}
			}
		}

		# Report errors
		if ($error)
		{
			print "Suspicious week number at " . (localtime $ts) .
				", from $prevWeekNr to $weekNr\n";
		}

		# Advance to next date
		$prevWeekNr = $weekNr;
		$prevYear = $year;
		$ts += 24*60*60;  # one day later
	}
}
#Test_get_week;

# Format the time difference in seconds as a +/-HHMM timezone specification.
sub format_tz
{
	my ($diff) = @_;

	$diff = sprintf "%.0f", $diff / 60;  # to minutes
	my $s= "+";
	if ($diff < 0)
	{
		$s = "-";
		$diff = -$diff;
	}
	return sprintf "%s%02d%02d", $s, int($diff / 60), $diff % 60;
}

# Format the timestamp (in unix timestamp) in the format "yyyy-mm-dd hh:mm:ss".
# The timezone is appended if specified.
sub format_datetime_iso
{
	my ($timestamp, $timezone) = @_;

	my @parts = gmtime $timestamp + $timezone;  # correct parts for timezone
	++$parts[4]; $parts[5] += 1900;
	my $ts = sprintf "%04d-%02d-%02d %2d:%02d:%02d",
		@parts[5,4,3,2,1,0];
	my $tz = format_tz $timezone;
	return "$ts $tz";
}

# Format the timestamp in the format "Wk wk dow d-m-yyyy h:mm:ss" in the
# current timezone.
sub format_datetime_full
{
	my ($timestamp) = @_;

	my @parts = localtime $timestamp;
	++$parts[4]; $parts[5] += 1900;
	my $week = get_week $timestamp;
	return sprintf "Wk %d %s %d-%d-%d %d:%02d:%02d",
		$week, $DoW[$parts[6]], @parts[3, 4, 5, 2, 1, 0];
}

# Format the timestamp in the format "d-m-yyyy h:mm" in the current timezone.
# If $allow2400 is true, use 24:00 rather than 0:00 (and adjust the day one
# less). This is useful for end datetimes.
sub format_datetime_hm
{
	my ($timestamp, $allow2400) = @_;

	$timestamp = int(($timestamp+30) / 60) * 60;  # round on minutes
	my @parts = localtime $timestamp;
	if ($allow2400 && $parts[0] == 0 && $parts[1] == 0 && $parts[2] == 0)
	{
		# This is 0:00 hour, make it 24:00 on the previous day
		@parts = localtime $timestamp-1;  # 1 second earlier (prev day)
		@parts[2, 1, 0] = (24, 0, 0);  # 24:00
	}
	++$parts[4]; $parts[5] += 1900;
	return sprintf "%d-%d-%d %d:%02d", @parts[3, 4, 5, 2, 1];
}

# Format the timestamp in the format "d-m-yyyy" in the current timezone.
# If $timestamp==0, an empty string is returned.
sub format_date
{
	my ($timestamp) = @_;

	my @parts = localtime $timestamp;
	++$parts[4]; $parts[5] += 1900;
	return sprintf "%d-%d-%d", @parts[3, 4, 5];
}

# Format the timestamp in the format "yyyy-mm-dd" in the current timezone.
# If $timestamp==0, an empty string is returned.
sub format_date_iso
{
	my ($timestamp) = @_;

	my @parts = localtime $timestamp;
	++$parts[4]; $parts[5] += 1900;
	return sprintf "%04d-%02d-%02d", @parts[5, 4, 3];
}

# Format the timestamp in the format "h:mm:ss" in the current timezone.
# If $timestamp==0, an empty string is returned.
sub format_time
{
	my ($timestamp) = @_;

	return "" if $timestamp == 0;

	my $sign = "";
	if ($timestamp < 0)
	{
		$sign = "-";
		$timestamp = -$timestamp;
	}

	my $sec = $timestamp % 60; $timestamp /= 60;
	my $min = $timestamp % 60; $timestamp /= 60;
	my $hours = $timestamp;
	return sprintf "$sign%d:%02d:%02d", $hours, $min, $sec;
}

# Format the timestamp in the format "h:mm" in the current timezone.
# If $timestamp==0, an empty string is returned.
sub format_time_hm
{
	my ($timestamp) = @_;

	return "" if $timestamp == 0;

	my $sign = "";
	if ($timestamp < 0)
	{
		$sign = "-";
		$timestamp = -$timestamp;
	}

	$timestamp = int(($timestamp+30) / 60);  # round on minutes
	my $min = $timestamp % 60; $timestamp /= 60;
	my $hours = $timestamp;
	return sprintf "$sign%d:%02d", $hours, $min;
}

# Parse a datetime and return the unix timestamp. The datetime can be in
# any of the following formats:
# - unix timestamp (seconds since 1-1-1970 UTC)
# - yyyy-mm-dd hh:mm:ss UTC
# - yyyy-mm-dd hh:mm:ss +/-HHMM
sub parse_datetime
{
	my ($string) = @_;

	if ($string =~ /^\s*
		(\d{4})\D+(\d{1,2})\D+(\d{1,2})  # yyyy-mm-dd
		\D+
		(\d{1,2})\D+(\d{2})\D+(\d{2})  # hh:mm:ss
		(?:\s*  # timezone is optional
			([+-])\s*
			(\d{1,2})  # 1-2 digits for hours
			:?  # optional separator
			(\d{2})  # 2 digits for minutes
		)?\s*$/x)
	{
		# Convert yyyy-mm-dd hh:mm:ss +zzzz to ts
		my @tm = ($6, $5, $4, $3, $2-1, $1);
		my $tz = $8 * 3600 + $9 * 60;
		$tz = -$tz if $7 eq "-";
		my $tm = timegm @tm;
		# The timestamp is in the specified
		# timezone. To calculate to UTC,
		# subtract the timezome.
		$tm -= $tz;

		return $tm;
	}
	elsif ($string =~ /^\s*\d+\s*$/)
	{
		# It's already a number, assume it's a unix timestamp.
		return $string;
	}
	else
	{
		die "Unknown format for timestamp: '$string'";
	}
}

# With the current time, calculate the current timezone difference in seconds.
sub get_tz
{
	# Take the current unix timestamp.
	my $now = time;
	# Calculate localtime components and re-interpret it as UTC components,
	# calculating back timestamp. This gives the unix timestamp when it
	# would be the same time in UTC as it is now locally.
	my $local = timegm localtime $now;
	# Take the difference as the difference in timezone.
	return $local - $now;
}


1;


