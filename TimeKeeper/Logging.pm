package TimeKeeper::Logging;

# This module contains functions that can be used in the logging of the timers
# and groups.

use strict;
use Carp;

use TimeKeeper::Config;
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
		progressive_round

		format_log_timers
		format_log_groups format_log_groups_2
		format_log_total

		report_log_group_total_difference
		report_log_missing_descriptions report_log_missing_groups
	);
	@EXPORT_OK   = ();
	%EXPORT_TAGS = ();  # eg: TAG => [ qw!name1 name2! ],
}


##############################################################################
### Utility functions for logging

# Rounds progressively from smallest value to largest value, distributing the
# rounded value over the larger values.
# Progressive rounding iterates through the values from the smallest to the
# largest. The rounded value is corrected on the remaining values, distributing
# proportional to the relative value (i.e. value with respect to total
# remaining).
# Arguments:
# - $items: Reference to name-value hash for input as well as output. The values
#    are integers.
# - $round_to: Value that specifies to which multiples should be rounded.
# Optional arguments (in "-option => value" syntax):
# -round_up [default 0.5]: Specifies the fraction from where to round up.
# -round_up_last [default -round_up]: Specifies the fraction from where to
#    round up for the last (=biggest) value. This may be set differently,
#    because this is where all of the value ends up.
# -round_up_small [default 0.25]: Specifies the fraction from where to round
#    up for small values. Small values are values less than 1, so that
#    rounding down would make it 0.
sub progressive_round
{
	my ($items, $round_to, %args) = @_;
	my ($round_up, $round_up_last, $round_up_small) =
		@args{qw/-round_up -round_up_last -round_up_small/};
	$round_up = 0.5 unless defined $round_up;
	$round_up_last = $round_up unless defined $round_up_last;
	$round_up_small = 0.25 unless defined $round_up_small;

	# Get the key names, ordered by value
	my @names = sort {
		$$items{$a} <=> $$items{$b}  # sort ascending by value
	} keys %$items;

	# Round the items, start with the smallest value.
	my @zeroed;
	for (my $i = 0; $i < @names; ++$i)
	{
		my $name = $names[$i];
		my $value = $$items{$name};

		# Calculate wholes/remainder wrt to $round_to
		my $value_wholes = int($value / $round_to) * $round_to;
		my $value_remainder = $value - $value_wholes;
		my $value_frac = $value_remainder / $round_to;

		# Determine the amount to round and adjust this item.
		my $round_up_frac;
		if ($i == @names - 1)
		{
			# This is the last item, apply special rules.
			$round_up_frac = $round_up_last;
		}
		elsif ($value_wholes == 0)
		{
			# This item is small (between 0 and 1).
			$round_up_frac = $round_up_small;
		}
		else
		{
			# Round this item to the nearest $round_to multiple
			$round_up_frac = $round_up;
		}

		# Calculate the new value for this item
		my $new_value = ($value_frac >= $round_up_frac)
			? $value_wholes + $round_to  # round up
			: $value_wholes;  # round down
		$$items{$name} = $new_value;
		push @zeroed, $name if $new_value <= 0;
		my $round = $new_value - $value;  # amount to round
		#print "DEBUG: Set '$name' $value -> $new_value (round=$round) (frac=$value_frac, round_up_frac=$round_up_frac)\n";

		# Adjust the bigger items by distributing the rounded
		# amount, depending on the item's relative size.
		if ($round != 0)
		{
			# Calculate the total for the bigger items
			# (Bigger items are later in @names)
			my $total = 0;
			for (my $j = $i + 1; $j < @names; ++$j)
			{
				my $name2 = $names[$j];
				my $value2 = $$items{$name2};
				$total += $value2;
			}

			# Adjust bigger items
			for (my $j = $i + 1; $j < @names; ++$j)
			{
				my $name2 = $names[$j];
				my $value2 = $$items{$name2};
				my $rel_size = $value2 / $total;
				# Add value, depending on its relative size
				my $rel_round = -$round * $rel_size;
				my $new_value = $value2 + $rel_round;
				$$items{$name2} = $new_value;
				#print "DEBUG: Adjust '$name2' $value2 -> $new_value (round=$rel_round)\n";
			}
		}
	}

	# Remove the items that have no time anymore
	delete @$items{@zeroed};
}


##############################################################################
### Timer logging functions

# Use the lineformat as a template for a line.
# The other variables are a hash of which the "<key>" is to be replaced by
# its value.
# Returns the formatted line with a linebreak.
sub format_line
{
	my $line = shift;  # lineformat
	my %values = @_;
	my $re = "<(" . join("|", keys %values) . ")>";
	$line =~ s/$re/$values{$1}/ge;
	return "$line\n";
}

# Iterate through the timers and add a line for each timer.
# Returns the string with lines.
# Arguments:
# - $lineformat: Line of text that is used for each timer. It may contain the
#     following placeholders:
#     - <description>: The description of the timer
#     - <time>: The current time of the timer
sub format_log_timers
{
	my ($lineformat) = @_;

	my $log = "";
	foreach (1..get_num_timers, 0)
	{
		my $description = get_timer_current_description $_;
		my $time = get_timer_current_time $_;
		$time = format_time_hm $time;
		if ($time)
		{
			$log .= format_line $lineformat, description => $description, time => $time;
		}
	}
	return $log;
}

# For all groups in @$groupnames, output a line with $lineformat. %$grouptimes
# is a hash with the times for each groupname.
# Returns a string with lines.
# - $lineformat: Line of text that is used for each group. It may contain the
#     following placeholders:
#     - <description>: The description of the group
#     - <time>: The total time for the timers in the group
# - $groupnames: Arrayref with names of groups.
# - $grouptimes: Hashref with groupname -> time mapping.
sub _format_groups
{
	my ($lineformat, $groupnames, $grouptimes) = @_;

	my $log = "";
	foreach my $groupname (@$groupnames)
	{
		my $time = format_time_hm $$grouptimes{$groupname};
		if (defined $groupname && $time)
		{
			$log .= format_line $lineformat, description => $groupname, time => $time;
		}
	}
	return $log;
}

# Iterate through the groups and add a line for each group with a non-zero
# time.
# Returns the string with lines.
# Arguments:
# - $lineformat: Line of text that is used for each group. It may contain the
#     following placeholders:
#     - <description>: The description of the group
#     - <time>: The total time for the timers in the group
# - $numgroups: The groups are numbered 0..$numgroups-1
# - &$get_group($g): Returns the description of the group $g
# - &$get_timers($g): Returns a reference to an array with timer ids that
#     belong to this group. The group time is the sum of the times of these
#     timers.
sub format_log_groups
{
	my ($lineformat, $numgroups, $get_group, $get_timers) = @_;

	# Collect the group-time data
	my (@groupnames, %grouptimes);
	for (my $g = 0; $g < $numgroups; ++$g)
	{
		my $description = &$get_group($g);
		my $timers = &$get_timers($g);
		my $time = 0;
		foreach (@$timers)
		{
			$time += get_timer_current_time $_;
		}
		push @groupnames, $description;
		$grouptimes{$description} = $time;
	}

	# Format the lines
	return _format_groups $lineformat, \@groupnames, \%grouptimes;
}

# Iterates through the timers and finds all the timer groups with non-zero
# times. Then, sort the groups alphanumerically and add a line per group.
# Returns the string with lines.
# Arguments:
# - $lineformat: Line of text that is used for each group. It may contain the
#     following placeholders:
#     - <description>: The description of the group
#     - <time>: The total time for the timers in the group
# - &$get_valid($t): Returns true if the timer is valid, false otherwise.
sub format_log_groups_2
{
	my ($lineformat, $get_valid) = @_;

	# Collect the group-time data
	my %grouptimes;  # groupname -> time
	foreach (1..get_num_timers, 0)
	{
		if (&$get_valid($_))
		{
			my $groupname = get_timer_current_group_name $_;
			my $time = get_timer_current_time $_;
			$grouptimes{$groupname} += $time;
		}
	}

	# Format the lines
	my @groupnames = sort keys %grouptimes;
	return _format_groups $lineformat, \@groupnames, \%grouptimes;
}

# Iterate through the timers and add the time of all the valid timers.
# Returns the string with lines.
# Arguments:
# - $lineformat: Line of text that is used. It may contain the following
#     placeholders:
#     - <time>: The total time for the valid timers.
#     - <description>: The concatenation of descriptions of the valid timers
#         with non-zero time.
#     - <description0>: The concatenation of descriptions of the valid timers,
#         even the ones with zero time.
# - &$get_valid($t): Returns true if the timer is valid, false otherwise.
sub format_log_total
{
	my ($lineformat, $get_valid) = @_;

	my $time = 0;
	my @descriptions = ();
	my @descriptions0 = ();
	foreach (1..get_num_timers, 0)
	{
		if (&$get_valid($_))
		{
			my $t = get_timer_current_time $_;
			my $d = get_timer_current_description $_;

			push @descriptions0, $d;
			if ($t != 0)
			{
				$time += $t;
				push @descriptions, $d;
			}
		}
	}
	my $time = format_time_hm $time;
	my $description = join ", ", @descriptions;
	my $description0 = join ", ", @descriptions0;
	return format_line $lineformat, time => $time, description => $description, description0 => $description0;
}

# Compare the total time for the groups and for the timers and check that
# there is no difference. If there is a difference report this, using the
# string $errorformat.
# Returns the string with lines.
# Arguments:
# - $numgroups: The groups are numbered 0..$numgroups-1
# - &$get_timers($g): Returns a reference to an array with timer ids that
#     belong to this group. The group time is the sum of the times of these
#     timers.
# - $errorformat: Line of text that is used in case of error. It may contain
#     the following placeholders:
#     - <time>: The detected time difference (timer minus groups)
sub report_log_group_total_difference
{
	my ($numgroups, $get_timers, $errorformat) = @_;

	# Calculate totals for the tasks
	my $total1 = 0;
	foreach (0..get_num_timers)
	{
		$total1 += get_timer_current_time $_;
	}
	# Calculate totals for the groups
	my $total2 = 0;
	for (my $g = 0; $g < $numgroups; ++$g)
	{
		my $timers = &$get_timers($g);
		foreach (@$timers)
		{
			$total2 += get_timer_current_time $_;
		}
	}
	# Report error
	my $log = "";
	my $time = $total1 - $total2;
	if ($time)
	{
		$time = format_time_hm $time;
		$log .= format_line $errorformat, time => $time;
	}
	return $log;
}

# Iterate through the timers and check that all timers that have a time also
# have a description. If not, use $errorformat to report this.
# Returns the string with lines.
# Arguments:
# - $errorformat: Line of text that is used in case of error. It may contain
#     the following placeholders:
#     - <timer>: The timer number that has no description
#     - <group>: The group name of the timer
#     - <time>: The time of the timer
sub report_log_missing_descriptions
{
	my ($errorformat) = @_;

	my $log = "";
	foreach (1..get_num_timers, 0)
	{
		my $description = get_timer_current_description $_;
		my $time = get_timer_current_time $_;
		next if $time == 0 || $description ne "";

		my $groupname = get_timer_current_group_name $_;
		$log .= format_line $errorformat, timer => $_, group => $groupname, time => $time;
	}
	return $log;
}

# Iterate through the timers and check that all timers that have a time also
# have a group. If not, use $errorformat to report this.
# Returns the string with lines.
# Arguments:
# - $errorformat: Line of text that is used in case of error. It may contain
#     the following placeholders:
#     - <timer>: The timer number that has no description
#     - <description>: The timer description that has no group
#     - <time>: The time of the timer
sub report_log_missing_groups
{
	my ($errorformat) = @_;

	my $log = "";
	foreach (1..get_num_timers, 0)
	{
		my $groupname = get_timer_current_group_name $_;
		my $time = get_timer_current_time $_;
		next if $time == 0 || $groupname ne "";

		my $description = get_timer_current_description $_;
		$log .= format_line $errorformat, timer => $_, descripition => $description, time => $time;
	}
	return $log;
}


1;


