package TimeKeeper::Timeline;

# This module handles the creation and cleanup of the timeline.
# A timeline is an array with start/stop periods. It is generated from the
# timer data in Storage.
#
# A most straightforward way to call this module is as follows:
#
#   my $timeline = timeline_nice;
#   print format_timeline $timeline;
#
#   my $totals = timeline_totals $timeline;
#   print format_timeline_totals $totals;
#
# A full user defined call would be as follows:
#
#   sub get_timer_info
#   {
#       my ($timer) = @_;
#       my $name = "Descriptive string for timer $timer";
#       return ( $name );
#   }
#
#   sub format_event
#   {
#       my ($start_d, $start_t, $end_d, $end_t, $description) =
#           @_[3, 4, 7, 8, 10];
#       return sprintf "%10s %5s - %10s %5s %s",
#           $start_d, $start_t, $end_d, $end_t, $description;
#   }
#
#   sub format_total
#   {
#       my ($description, $total) = @_[1, 3];
#       return "Total '$description': $total";
#   }
#
#   sub format_grand_total
#   {
#       my ($grand_total) = @_[1];
#       return sprintf "Grand total: $grand_total";
#   }
#
#   my $timeline = timeline_nice;
#   print format_timeline $timeline, \&get_timer_info, \&format_event;
#
#   my $totals = timeline_totals $timeline;
#   print format_timeline_totals $totals,
#       \&get_timer_info, \&format_total, \&format_grand_total;

use strict;
use Carp;

use Time::Local qw/timelocal_nocheck/;

use TimeKeeper::Storage;
use TimeKeeper::Utils;

BEGIN
{
	use Exporter ();
	our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

	# set the version for version checking
	$VERSION     = 1.00;

	@ISA         = qw(Exporter);
	@EXPORT      = qw(
		timeline_get timeline_nice

		timeline_totals timeline_split_midnight
		timeline_round_times
		timeline_remove_small_gaps timeline_remove_small_periods
		timeline_join_same_periods
		timeline_process_modifications

		format_timeline format_timeline_totals
	);
	@EXPORT_OK   = qw(
		default_get_timer_info
		default_format_timeline_event
		default_format_timeline_total default_format_timeline_grand_total
	);
	%EXPORT_TAGS = ();  # eg: TAG => [ qw!name1 name2! ],
}


##############################################################################
### Timeline related functions

##### Generic functions #####

# Given 4 points in time, return a point between t2 and t3, so that the space
# between t2 and t3 is proportionally divided between t1-t2 and t3-t4 on the
# basis of their relative sizes.
# The return value is rounded to an integer.
# Precondition: $t1 <= $t2 <= $t3 <= $t4
sub timeline_distribute
{
	my ($t1, $t2, $t3, $t4) = @_;

	unless ($t1 <= $t2 && $t2 <= $t3 && $t3 <= $t4)
	{
		# The times are not monotonously increasing. This is unexpected.
		# When necessary, this can be fixed, but for now, I assume
		# it will not happen.
		die sprintf "timeline_distribute(): Assumption failed: " .
			"Overlapping periods: [T-%d, T=%d] and [T+%d, T+%d]",
			$t2-$t1, $t2, $t3-$t2, $t4-$t2;
	}

	# Calculate differences
	#info sprintf "timeline_distribute(%d, +%d, +%d, +%d)\n", $t1, $t2-$t1, $t3-$t1, $t4-$t1;
	my $d12 = $t2 - $t1;
	my $d23 = $t3 - $t2;
	my $d34 = $t4 - $t3;

	my $f;
	if ($d12 + $d34 > 0)
	{
		$f = $d12 / ($d12 + $d34);  # relative size of 1-2 wrt 3-4
	}
	else
	{
		$f = 0.5;  # d12 and d34 are both 0, therefore, equal
	}

	return $t2 + round($d23 * $f, 1);
}

# Find the period before, during and after this timestamp.
# Returns array with these 3 indexes. When no period, undef is returned.
sub timeline_find_period
{
	my ($timeline, $ts) = @_;

	my $idx_before;  # last index with end<=ts
	my $idx_during;  # index with start<=ts<end
	my $idx_after;  # first index with start>ts
	# Note that the start is chosen to be inclusive and end exclusive.

	my $max = @$timeline-1;
	foreach my $idx (0..$max)
	{
		my ($start, $end) = @{$$timeline[$idx]};
		if ($end <= $ts)
		{
			# This one is (still) before.
			$idx_before = $idx;
		}
		elsif ($start <= $ts && $ts < $end)
		{
			# This one is during
			$idx_during = $idx;
		}
		elsif ($start > $ts)
		{
			# This one is after.
			$idx_after = $idx;
			# Stop now, so this doesn't get updated.
			last;
		}
	}

	return ($idx_before, $idx_during, $idx_after);
}

# Insert period before (if $amount>=0) or after (if $amount<0) idx in timeline.
# The period gets a length of abs($amount) and the specified timer.
# If the timer is left unspecified, the same timer as the existing period is
# used.
# A period will only be created if its interval>0 and if the timer>=0.
# Returns the indexes at which the periods have been created.
sub timeline_insert_period
{
	my ($timeline, $idx, $amount, $timer) = @_;

	my ($start, $end, $tm) = @{$$timeline[$idx]};
	$timer = $tm unless defined $timer;

	# Find the middle
	my $middle;
	my ($timer1, $timer2);
	if ($amount >= 0)
	{
		# Insert new period just before idx.
		$middle = $start + $amount;
		($timer1, $timer2) = ($timer, $tm);
	}
	else
	{
		# Insert new period just after idx (NB $amount is negative).
		$middle = $end + $amount;
		($timer1, $timer2) = ($tm, $timer);
	}
	# Check validity
	if ($middle < $start || $middle > $end)
	{
		my $duration = $end - $start;
		#info "START=$start; MIDDLE=$middle; END=$end\n";
		die "Amount ($amount) too big for period ($start-$end (=$duration))";
	}
	# Add new period
	my @periods = ();
	push @periods, [ $start, $middle, $timer1 ] if $middle > $start && $timer1 >= 0;
	push @periods, [ $middle, $end, $timer2 ] if $end > $middle && $timer2 >= 0;
	splice @$timeline, $idx, 1, @periods;

	# Construct return value
	my @retval = map $idx++, @periods;
	return @retval;
}

# Calculate a hash with the timer ids as keys and the arrays as values. These
# value entries have the following fields:
# 0 - total amount of time according to the timeline including all rounding
# 1 - current timer value
sub timeline_totals
{
	my ($timeline) = @_;

	my %totals;
	# Collect the totals
	foreach (@$timeline)
	{
		my ($start, $end, $timer) = @$_;
		$totals{$timer}[0] += $end - $start;
	}
	# Add the additional fields
	foreach my $timer (keys %totals)
	{
		my $total = $totals{$timer}[0];
		my $time = get_timer_current_time $timer;
		$totals{$timer}[1] = $time;
	}

	return \%totals;
}

# Go through the timeline and if a period crosses midnight, split it into
# multiple periods, so that each period is in one day only.
# Midnight is determined in the local timezone.
sub timeline_split_midnight
{
	my ($timeline) = @_;

	# Find all the periods that cross midnight.
	# Don't assume a day is 24 hours, which it isn't for daylight saving
	# crossings.
	my @crossings;  # contains [ idx, [ ts, ts, ... ] ] entries
	foreach my $idx (0..@$timeline-1)
	{
		my ($start, $end) = @{$$timeline[$idx]}[0, 1];
		my @start = localtime $start;
		my @end = localtime $end;
		if ($start[0] != $end[0] || $start[1] != $end[1] ||
			$start[2] != $end[2])
		{
			# This period spans one or more midnights
			my @midnights;
			my $ts = $start;  # starting timestamp
			while (1)
			{
				my @ts = localtime $ts;
				my $midnight = timelocal_nocheck 0, 0, 24, @ts[3, 4, 5];
				last if $midnight >= $end;  # done
				push @midnights, $midnight;
				$ts = $midnight;  # next starting point
			}
			push @crossings, [ $idx, \@midnights ];
		}
	}

	# Split the periods on midnights.
	# Iterate from back to front to allow the array to grow when adding
	# periods.
	foreach (reverse @crossings)
	{
		my ($idx, $midnights) = @$_;
		foreach my $midnight (@$midnights)
		{
			my $start = $$timeline[$idx][0];
			my $amount = $midnight - $start;
			my @idxs = timeline_insert_period $timeline, $idx, $amount;
			$idx = $idxs[1];  # continue with second period
		}
	}
}


##### Generic visitor-like functions #####

# Iterate through timeline and call &$condition on each period. If that
# function returns true, the period is flagged by setting the timer field
# to $flag.
# &$condition is called with the following arguments:
# - period entry
# - period entry index in @$timeline
# $flag defaults to -999.
sub timeline_flag_periods
{
	my ($timeline, $condition, $flag) = @_;
	$flag = -999 unless defined $flag;

	foreach (0..@$timeline-1)
	{
		my $period = $$timeline[$_];
		if (&$condition($period, $_))
		{
			$$period[2] = $flag;
		}
	}
}

# Iterate through timeline and call &$condition on each set of adjacent
# periods. If that function returns true, the first period is extended so that
# it covers the second and the second is deleted from the timeline.
# &$condition is called with the following arguments:
# - left period
# - right period
sub timeline_join_periods
{
	my ($timeline, $condition) = @_;

	my @new_timeline = ();
	foreach my $event (@$timeline)
	{
		if (!@new_timeline)
		{
			# This is the first event, just add it
			push @new_timeline, $event;
		}
		else
		{
			my $last_event = $new_timeline[-1];
			if (&$condition($last_event, $event))
			{
				# Join these periods (ie copy end-time)
				$$last_event[1] = $$event[1];
			}
			else
			{
				# Keep as separate period
				push @new_timeline, $event;
			}
		}
	}
	@$timeline = @new_timeline;
}

# Removes all the periods in timeline that have the timer field set to $flag.
# $flag defaults to -999.
sub timeline_remove_flagged_periods
{
	my ($timeline, $flag) = @_;
	$flag = -999 unless defined $flag;

	@$timeline = grep $$_[2] != $flag, @$timeline;
}


##### Operations on timelines to clean them up #####

# Round all times to a multiple of $round.
sub timeline_round_times
{
	my ($timeline, $round) = @_;

	foreach (@$timeline)
	{
		$$_[0] = round($$_[0], $round);  # start
		$$_[1] = round($$_[1], $round);  # end
	}
}

# Remove gaps smaller than $min_time to remove 'glitches'.
sub timeline_remove_small_gaps
{
	my ($timeline, $min_time) = @_;

	my $len = @$timeline;
	for (my ($a, $b) = (0, 1); $b < $len; ++$a, ++$b)
	{
		#print "Compare (@{$$timeline[$a]}) and (@{$$timeline[$b]}).\n";
		my $d = abs $$timeline[$b][0] - $$timeline[$a][1];
		if ($d < $min_time)
		{
			# This gap is small enough to fill
			# Calculate the 'new' middle
			my $middle = timeline_distribute
				$$timeline[$a][0], $$timeline[$a][1],
				$$timeline[$b][0], $$timeline[$b][1];
			# Fix the periods
			$$timeline[$a][1] = $$timeline[$b][0] = $middle;
		}
	}
}

# Remove periods smaller than $min_time to remove 'glitches'.
sub timeline_remove_small_periods
{
	my ($timeline, $min_time) = @_;

	# Mark the short periods
	timeline_flag_periods $timeline, sub {
		my ($period, $idx) = @_;
		my $d = abs $$period[1] - $$period[0];  # duration
		return $d < $min_time;
	}, -1000;
	# String them together
	timeline_join_periods $timeline, sub {
		my ($period1, $period2) = @_;
		return $$period1[1] == $$period2[0] &&  # no gap
			$$period1[2] == -1000 && $$period2[2] == -1000;  # flagged
	};
	# Distribute time of marked periods
	my $len = @$timeline;
	for (my $i = 0; $i < $len; ++$i)
	{
		my $period = $$timeline[$i];
		if ($$period[2] == -1000)
		{
			# This period is marked, divide its time between
			# left and right.
			my $left = ($i > 0) ? $$timeline[$i-1] : undef;
			$left = undef unless $$left[1] == $$period[0];
			my $right = ($i < $len-1) ? $$timeline[$i+1] : undef;
			$right = undef unless $$period[1] == $$right[0];
			# left and right are now the adjacent (without gap)
			# periods of period.
			if ($left && $right)
			{
				# Divide between left and right
				my $middle = timeline_distribute
					$$left[0], $$left[1],
					$$right[0], $$right[1];
				$$left[1] = $$right[0] = $middle;  # extend
				$$period[0] = $$period[1] = $middle;  # zero
			}
			elsif ($left)
			{
				# No right, move time to left
				$$left[1] = $$period[1];  # extend left
				$$period[0] = $$period[1];  # zero period
			}
			elsif ($right)
			{
				# No left, move time to right
				$$right[0] = $$period[0];  # extend right
				$$period[1] = $$period[0];  # zero period
			}
		}
	}
	# Remove Marked periods
	timeline_remove_flagged_periods $timeline, -1000;
}

# Iterate through the timeline and if there are adjacent periods for the same
# timer, join them into one period.
sub timeline_join_same_periods
{
	my ($timeline) = @_;

	timeline_join_periods $timeline, sub {
		my ($period1, $period2) = @_;
		return $$period1[1] == $$period2[0] &&  # no gap between
			$$period1[2] == $$period2[2];  # same timer
	};
}


##### Functions to merge modifications into the timeline #####

# Iterate through the modifications and process them.
sub timeline_process_modifications
{
	my ($timeline, $modifications) = @_;

	foreach my $mod (@$modifications)
	{
		my ($code, $ts, $amount) = @$mod;

		# Find the index for this timestamp
		my ($idx_before, $idx_during, $idx_after) =
			timeline_find_period $timeline, $ts;

		# Merge this modification
		if ($code eq 't' || $code eq 'd')
		{
			my ($from, $to);
			if ($code eq 't')
			{
				# This is a transfer
				($from, $to) = @$mod[3,4];
			}
			else
			{
				# This is a decrease
				($from) = @$mod[3];
				$to = -1;  # model by transfering to 'sink'
			}

			my $from_amount = $amount;

			# Check how much we can transfer at beginning of
			# current period
			if (defined($idx_during) &&
				$$timeline[$idx_during][2] == $from)
			{
				my ($start, $end) = @{$$timeline[$idx_during]}[0, 1];
				my $this_amount;
				if ($from_amount <= $ts - $start)
				{
					$this_amount = $from_amount;
					$from_amount = 0;
				}
				else
				{
					$this_amount = $ts - $start;
					$from_amount -= $this_amount;
				}
				# Add period at beginning
				#info "TRANSFER INSERT 1: $this_amount\n";
				timeline_insert_period $timeline, $idx_during, $this_amount, $to;
			}

			if ($from_amount > 0 && defined($idx_before))
			{
				# Iterate to the front and transfer more time
				for (my $idx = $idx_before; $idx >= 0; --$idx)
				{
					my ($start, $end, $timer) = @{$$timeline[$idx]};

					# It should be a from timer
					next if $timer != $from;

					# Determine the amount of time that
					# can be taken from this timer
					my $this_amount;
					if ($from_amount <= $end - $start)
					{
						$this_amount = $from_amount;
						$from_amount = 0;
					}
					else
					{
						$this_amount = $end - $start;
						$from_amount -= $this_amount;
					}
					# Add period at end
					#info "TRANSFER INSERT 2: $this_amount\n";
					timeline_insert_period $timeline, $idx, -$this_amount, $to;
				}
			}

			if ($from_amount > 0)
			{
				# If there is still some left, create a new
				# period at the front.
				# NB: This is strange, since it would mean that
				# more time is deducted than was in all the
				# periods, so making the time negative.
				#info "TRANSFER INSERT 3: $from_amount\n";
				my $end = @$timeline ? $$timeline[0][0] : $ts;
				my $start = $end - $from_amount;
				unshift @$timeline, [ $start, $end, $to ];
			}
		}
		elsif ($code eq 'i')
		{
			# This is an increase
			my ($timer) = @$mod[3];

			# Search backwards to find a gap where this amount fits
			# as a whole. Insert the period at the end of this gap.
			my $idx = $idx_before;
			if (!defined $idx)
			{
				# There is no period before, the period should
				# be inserted before the first period
				#info "INCREASE INSERT 1: $amount\n";
				my $end = @$timeline ? $$timeline[0][0] : $ts;
				my $start = $end - $amount;
				unshift @$timeline, [ $start, $end, $timer ];
			}
			elsif ($idx == @$timeline-1)
			{
				# This index is the last period, the period
				# should be inserted after the last period
				#info "INCREASE INSERT 2: $amount\n";
				my $start = $$timeline[-1][1];
				my $end = $start + $amount;
				unshift @$timeline, [ $start, $end, $timer ];
			}
			else
			{
				# Search backwards, starting with the gap,
				# following $idx.
				while (1)
				{
					last if $idx < 0;  # done searching
					# Calculate size of gap
					my $gap_size = $$timeline[$idx+1][0] -
						$$timeline[$idx][1];
					last if $gap_size >= $amount;
					--$idx;
				}
				# Period should be placed at the end of the
				# gap between $idx and $idx+1. This means that
				# the period must be inserted just before
				# period $idx+1.
				# If $idx==-1, $idx+1==0, resulting in an
				# insert at the start of the timeline.
				#info "INCREASE INSERT 3: $amount\n";
				my $end = $$timeline[$idx+1][0];
				my $start = $end - $amount;
				splice @$timeline, $idx+1, 0, [ $start, $end, $timer ];
			}
		}
		else
		{
			die "Unknown modification code: '$code'";
		}
	}
}


##### Retrieving timeline #####

# Retrieves the timeline from Storage and does an interpretation of the fields.
# It changes the following:
# 1) In modifications, recognize transfers and give them entries like this:
#    [ 't', <timestamp>, <amount-seconds>, <from timer id>, <to timer id> ]
#    Make it such that the amounts are positive.
# 2) Negative increases are represented by decreases in entries like this:
#    [ 'd', <timestamp>, <amount-seconds>, <timer> ]
# 3) If there is a pause without a run, a 0-length event is created in timeline.
#    Remove those 0-length events.
# 0-length events could occur during other events, which violates the rule in
# this module that a timeline should only have one active timer. To fix this,
# the 0-length event can be removed or the running event can be split at that
# time.
# Returns: ($timeline, $modifications).
sub timeline_get
{
	my ($timeline, $modifications) = create_timeline;

	# Rule 1) Extract transfers from modifications.
	# Store them in the following array with entries in the following
	# format: [ timestamp, amount_seconds, from_timer, to_timer ].
	my $len = @$modifications;
	for (my $a = 0, my $b = 1; $b < $len; ++$a, ++$b)
	{
		my $ma = $$modifications[$a];
		my $mb = $$modifications[$b];
		if ($$ma[0] == 'i' && $$mb[0] == 'i' &&  # both increases
			$$ma[1] == $$mb[1] &&  # at same timestamp
			$$ma[2] == -$$mb[2])  # amount is opposite
		{
			my (undef, $ts, $amount, $to) = @$ma;
			my (undef, undef, undef, $from) = @$mb;
			if ($amount < 0)
			{
				($amount, $from, $to) = (-$amount, $to, $from);
			}
			@$ma = ( 't', $ts, $amount, $from, $to );
			$$mb[0] = '';  # flag 'not used'
		}
	}
	# Remove redundant (ie with empty code) entries
	my @new_modifications = grep $$_[0], @$modifications;

	# Rule 2) Change negative increases into decreases
	foreach (@new_modifications)
	{
		if ($$_[0] eq 'i' && $$_[2] < 0)
		{
			$$_[0] = 'd';
			$$_[2] = -$$_[2];
		}
	}

	# Rule 3) Remove 0-length events (non-events)
	@$timeline = grep {
		my ($start, $end, $timer) = @$_;
		$start != $end;  # true (ie keep entry) if not 0-length
	} @$timeline;

	return ($timeline, \@new_modifications);
}

# Returns a beautified timeline. All modifications have been adjusted in the
# timeline. Also heuristics have been applied to smoothen things out.
# Optional arguments can be supplied via the "-option => value" syntax to
# control the heuristics:
# -min_gap [seconds, default 2*60]: Defines the minimum size of a gap. Gaps
#     that are smaller are filled with the periods on each side.
# -min_period [seconds, default 2*60]: Defines the minimum size of a period.
#     Periods that are smaller are divided up by the periods on each side.
# -round [seconds, default 5*60]: Times are rounded to multiples of this
#     value.
# -discard [array with timerids, default [0]]: These timers are discarded from
#     the timeline.
# -cleanup [boolean, default true]: If true, does beautification like min_gap,
#     min_period and round. If false, returns the raw timeline with
#     modifications applied.
sub timeline_nice
{
	my %args = @_;
	my ($min_gap, $min_period, $round, $discard, $cleanup) =
		@args{qw/-min_gap -min_period -round -discard -cleanup/};
	$min_gap = 2*60 unless defined $min_gap;
	$min_period = 2*60 unless defined $min_period;
	$round = 5*60 unless defined $round;
	$discard = [0] unless defined $discard;
	$cleanup = 1 unless defined $cleanup;

	# Create a timeline
	my ($timeline, $modifications) = timeline_get;
	timeline_process_modifications $timeline, $modifications;

	# Remove unwanted timers
	if ($discard && @$discard)
	{
		my %discard;
		$discard{$_} = 1 foreach @$discard;
		timeline_flag_periods $timeline, sub {
			my ($period, $idx) = @_;
			my $timer = $$period[2];
			return $discard{$timer};
		};
		timeline_remove_flagged_periods $timeline;
	}

	if ($cleanup)
	{
		# Remove the 'noise'
		timeline_remove_small_gaps $timeline, $min_gap;
		timeline_remove_small_periods $timeline, $min_period;
		timeline_join_same_periods $timeline;

		if ($round > 0)
		{
			# Round start and end times
			timeline_round_times $timeline, $round;
			# Cleanup 'noise' that rounding may cause
			timeline_remove_small_periods $timeline, 1;  # <1sec
			timeline_join_same_periods $timeline;
		}

		# Don't let the periods span midnight
		timeline_split_midnight $timeline;
	}

	return $timeline;
}


##### Format timeline into a string for printing #####

# Returns an array with info about this timer.
# Arguments:
# 0 - timer id
# The following elements are returned:
# - name
sub default_get_timer_info
{
	my ($timer) = @_;

	return ( "Timer_$timer" );
}

# Returns a string with the contents of the timeline event nicely formatted.
# Arguments:
# 0 - $event: The timeline event itself
# 1 - $start_ts: Start as timestamp
# 2 - $start_datetime: Start in human readable format
# 3 - $start_date: Start date in human readable format
# 4 - $start_time: Start time in human readable format
# 5 - $end_ts: End as timestamp
# 6 - $end_datetime: End in human readable format
# 7 - $end_date: End date in human readable format
# 8 - $end_time: End time in human readable format
# 9 - $duration: Duration in human readable format
# 10 - $description: Description of this event
# Returns:
# - Text string of single line (without linebreak).
sub default_format_timeline_event
{
	my ($event,
		$start_ts, $start_datetime, $start_date, $start_time,
		$end_ts, $end_datetime, $end_date, $end_time,
		$duration,
		$description) = @_;

	# Assume the start and end will generally be on the same date. If so,
	# display it a bit more concise.
	if ($start_date && $end_date && $start_date eq $end_date)
	{
		return sprintf "%10s %5s-%5s %7s %s",
			$start_date, $start_time, $end_time,
			"($duration)", $description;
	}
	else
	{
		return sprintf "%16s-%16s %7s %s",
			$start_datetime, $end_datetime,
			"($duration)", $description;
	}
}

# Returns a string with the contents of the timeline total nicely formatted.
# Arguments:
# 0 - $timer: Timer id for this timer total.
# 1 - $description: Description for this timer total.
# 2 - $total_sec: Total amount of time according to timeline (including
#     rounding) in seconds.
# 3 - $total: Total amount of time according to timeline (including rounding)
#     in human readable format.
# 4 - $time_sec: Total amount of time according to timer in seconds.
# 5 - $time: Total amount of time according to timer in human readable format.
# 6 - $fraction: Fraction difference (percentage/100) from time to total.
# 7 - $fraction_pct: Fraction as a percentage string.
# Returns:
# - Text string of single line (without linebreak).
sub default_format_timeline_total
{
	my ($timer, $description,
		$total_sec, $total, $time_sec, $time,
		$fraction, $fraction_pct) = @_;

	return "Total '$description': $total ($fraction_pct)";
}

# Returns a string with the contents of the timeline grand total nicely
# formatted.
# Arguments:
# 0 - $grand_total_sec: Grand total in seconds.
# 1 - $grand_total: Grand total in human readable format.
# Returns:
# - Text string of single line (without linebreak).
sub default_format_timeline_grand_total
{
	my ($grand_total_sec, $grand_total) = @_;

	return sprintf "Grand total: $grand_total";
}

# Returns a string with the contents of the timeline nicely formatted.
# The arguments are as follows:
# - $timeline: array with timeline events. An event is an array with the
#     following elements:
#     - start [timestamp]
#     - end [timestamp]
#     - timer id
# - $get_timer_info: Coderef that returns information of the timer in an array.
#     Defaults to default_get_timer_info, see that for details.
# - $format_timeline_event: Coderef that formats a single timeline report line.
#     Defaults to default_format_timeline_event, see that for details.
sub format_timeline
{
	my ($timeline, $get_timer_info, $format_timeline_event) = @_;
	$get_timer_info ||= \&default_get_timer_info;
	$format_timeline_event ||= \&default_format_timeline_event;

	my $s = "";
	foreach my $event (@$timeline)
	{
		my ($start_ts, $end_ts, $timer) = @$event;
		my $duration = format_time_hm($end_ts - $start_ts);
		$duration = "-" unless $duration;
		my $start_datetime = format_datetime_hm($start_ts);
		my $end_datetime = format_datetime_hm($end_ts, 1);
		my ($name) = &$get_timer_info($timer);

		# Assume the start and end will generally be on the same date.
		# If so, display it a bit more concise.
		my ($start_date, $start_time) = $start_datetime =~ /(\S+)\s+(\S+)/;
		my ($end_date, $end_time) = $end_datetime =~ /(\S+)\s+(\S+)/;

		$s .= &$format_timeline_event($event,
			$start_ts, $start_datetime, $start_date, $start_time,
			$end_ts, $end_datetime, $end_date, $end_time,
			$duration, $name);
		$s .= "\n";
	}
	return $s;
}

# Returns a string with the contents of the timeline totals nicely formatted.
# Arguments:
# - $totals: Hash created by timeline_totals().
# - $get_timer_info: Coderef that returns information of the timer in an array.
#     Defaults to default_get_timer_info, see that for details.
# - $format_timeline_total: Coderef that formats a single timeline total line.
#     Defaults to default_format_timeline_total, see that for details.
# - $format_timeline_grand_total: Coderef that formats a timeline grand total
#     line.
#     Defaults to default_format_timeline_grand_total, see that for details.
sub format_timeline_totals
{
	my ($totals, $get_timer_info, $format_timeline_total,
		$format_timeline_grand_total) = @_;
	$get_timer_info ||= \&default_get_timer_info;
	$format_timeline_total ||= \&default_format_timeline_total;
	$format_timeline_grand_total ||= \&default_format_timeline_grand_total;

	my $s = "";
	# Add the total lines
	my $grand_total_sec = 0;
	foreach my $timer (sort { $a <=> $b } keys %$totals)
	{
		my ($name) = &$get_timer_info($timer);
		my ($total_sec, $time_sec) = @{$$totals{$timer}};
		my $total = format_time_hm $total_sec;
		my $time = format_time_hm $time_sec;
		my ($frac, $frac_pct) = (0, 0);
		if ($time_sec > 0)
		{
			$frac = ($total_sec - $time_sec) / $time_sec;
			my $sign = ($frac >= 0) ? "+" : "-";
			$frac_pct = sprintf "%s%.1f%%", $sign, abs($frac*100);
		}

		$s .= &$format_timeline_total($timer, $name,
			$total_sec, $total, $time_sec, $time,
			$frac, $frac_pct);
		$s .= "\n";

		$grand_total_sec += $total_sec;
	}
	# Add the grand total line
	my $grand_total = format_time_hm $grand_total_sec;
	$s .= &$format_timeline_grand_total($grand_total_sec, $grand_total);
	$s .= "\n";

	return $s;
}


1;


