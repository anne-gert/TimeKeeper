package TimeKeeper::Core;

# This module handles the control of the TimeKeeper. It also provides the
# scope where the log definition is run.
# This module also provides callbacks for a UI module.

use strict;
use Carp;

use File::Basename;
use File::Spec::Functions;
use Time::Local;  # used for timezone calculation

use TimeKeeper::Core;
use TimeKeeper::Storage;
use TimeKeeper::Config;
use TimeKeeper::Timeline;
use TimeKeeper::Logging;
use TimeKeeper::Utils;

BEGIN
{
	use Exporter ();
	our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

	# set the version for version checking
	$VERSION     = 1.00;

	@ISA         = qw(Exporter);
	@EXPORT      = qw(
		initialize finalize initialize_ui
		activate get_active
		startstop start stop
		time_tick
		set_description_delayed force_pending_description_changes
		get_timer_group_infos get_timer_group_info set_timer_group_name
		is_timer_group_type
		show_timer set_timer add_timer add_active_timer transfer_time
		get_previous_period_info
		is_generate_log_target add_remove_generate_log_target
		edit_logdef generate_log get_alt_logs make_log
		edit_text edit_file
		edit_config edit_storage edit_groups
		read_all_config write_all_config update_all_config

		get_timezone_offset

		set_cb_activate set_cb_deactivate
		set_cb_start set_cb_stop
		set_cb_update_timer_time set_cb_update_timer_description set_cb_update_timer_group
		set_cb_update_wall_time
		set_cb_set_clipboard
	);
	@EXPORT_OK   = qw();
	%EXPORT_TAGS = ();  # eg: TAG => [ qw!name1 name2! ],
}


##############################################################################
### Globals

# Constants
# Make this timer active if no active timer
our $DefaultActiveTimer = 0;
# Time [sec] to wait before description change
our $DescriptionChangeMaxPendingTime = 5;
# Max time [sec] between ticks. longer times are assumed to be suspends.
our $MaxTimeBetweenTicks = 600;

# other global variables
our $LastTime = 0;  # timestamp of last update event
our $IsStopped = 0;  # flag if active timer is running or not

our $TimeZone = undef;

# This datastructure maintains the latest changes in descriptions.
my %DescriptionChanges;  # timer_id -> [ timestamp, description ]

# callback references for certain events
our $cb_activate;
our $cb_deactivate;
our $cb_start;
our $cb_stop;
our $cb_update_timer_time;
our $cb_update_timer_description;
our $cb_update_timer_group;
our $cb_update_wall_time;
our $cb_set_clipboard;

# Forward declarations
sub get_active;
sub add_active_timer;
sub start;
sub stop;
sub show_timer;
sub get_timestamp;
sub process_pending_description_changes;
sub get_timer_group_info;


##############################################################################
### General functions

# Edit an existing file with the defined editor.
sub edit_file
{
	my ($fname) = @_;

	my $cmd = get_cmd_edit $fname;
	if ($cmd eq "stdout")
	{
		# Read the contents and print it to stdout
		if (open FILE, "< $fname")
		{
			print while (<FILE>);
			close FILE;
		}
		else
		{
			print "Cannot open '$fname': $!\n";
		}
	}
	else
	{
		# Proper shell command, run it
		system $cmd;
	}
}

# Displays text in the editor. Via a temporary file.
sub edit_text
{
	my ($text) = @_;

	if (get_cmd_edit eq "stdout")
	{
		# Just print the text to stdout
		print $text;
	}
	else
	{
		my $fname = create_temp_text $text;
		edit_file $fname;
	}
}

# Check with the storage and update (via callbacks in the UI) all timers that
# have changed.
sub update_timers
{
	my $report = "";
	foreach (get_changed_timers)
	{
		my $timer = shift @$_;
		$report .= " $timer(";
		foreach (@$_)
		{
			$report .= $_;
			if ($_ eq 'D')
			{
				# Description has been updated
				if (!exists $DescriptionChanges{$timer})
				{
					# Description not being edited
					my $desc = get_timer_current_description $timer;
					&$cb_update_timer_description($timer, $desc)
						if $cb_update_timer_description;
				}
			}
			elsif ($_ eq 'T')
			{
				# Time has been updated
				my $time = get_timer_current_time $timer;
				&$cb_update_timer_time($timer, $time)
					if $cb_update_timer_time;
			}
			elsif ($_ eq 'G')
			{
				# Group has been updated
				my $name = get_timer_current_group_name $timer;
				my $group = get_timer_group_info $name;
				my $color = $$group{color};
				&$cb_update_timer_group($timer, $name, $color)
					if $cb_update_timer_group;
			}
		}
		$report .= ")";
	}
	#info "update_timers:$report\n" if $report;
}

# Return the current timezone offset in seconds
sub get_timezone_offset
{
	unless (defined $TimeZone)
	{
		my $time = time;
		$TimeZone = timegm(localtime($time)) - $time;
	}
	return $TimeZone;
}


##############################################################################
### Read write configuration

# This function determines the configuration file to use from the arguments
# and environment. After determining the path, read the config file and the
# other files that contain status info (status and storage).
sub read_all_config
{
	my @args = @_;

	my $StartupPath = get_startup_path;
	my $ConfigPath;
	if (@args)
	{
		# Read config file from the arguments
		my $config_file = shift @args;  # take config file from arguments
		$ConfigPath = dirname $config_file;
		set_config_file basename $config_file;
	}
	else
	{
		# Retrieve default path for config file
		my $HomePath = $ENV{HOME} || "$ENV{HOMEDRIVE}$ENV{HOMEPATH}";
		$ConfigPath = catfile $HomePath || $StartupPath, ".TimeKeeper";
	}
	
	set_config_path $ConfigPath;
	read_config_file;
	redirect_debug_info \&get_debug_info_file;
	read_status_file;
	my $state = read_storage_file;
	unless (@$state)
	{
		# There is no state, make some default filling
		my $preset_timer = sub {
			my ($timer, $description, $groupname) = @_;

			my $now = get_timestamp;
			set_timer_description $timer, $description, $now;
			set_timer_group_name($timer, $groupname);
		};

		$preset_timer->(0, "Rest time", qr/other/i);
		$preset_timer->(1, "Lunch", qr/own/i);
		$preset_timer->(2, "General Meeting", qr/general/i);
		$preset_timer->(3, "Project Meeting", qr/project/i);
		$preset_timer->(4, "Implementation", qr/project/i);
		$preset_timer->(5, "Writing webpage", qr/project/i);
	}
}

# Write the files that contain status (status and storage).
sub write_all_config
{
	write_status_file;
}

# Write configs when necessary.
sub update_all_config
{
	update_status_file;
}

# Read the timer-groups file and return an arrayref with group-entries with the
# following fields:
# name: Group name
# type: Group type
# color: Group color
sub read_timer_groups
{
	my $fname = get_groups_file;

	my @groups = ();
	if (open my $fh, "< $fname")
	{
		# Read the lines
		while (my $line = <$fh>)
		{
			$line =~ s/[\r\n]+$//;
			next if $line =~ /^#/;  # comment line
			my @fields = split /\t/, $line;
			next if @fields != 3;  # wrong format
			push @groups, {
				type => $fields[0],
				color => $fields[1],
				name => $fields[2],
			};
		}
		close $fh;
	}
	else
	{
		# File does not exist or is empty
	}

	return \@groups;
}

# Initialize data structures before creating user interface.
sub initialize
{
	read_all_config @_;

	# Cleanup debug info messages if applicable.
	if (my $debug_info_file = get_debug_info_file)
	{
		# A debug_info_file has been defined.
		# Cleanup old entries first
		my @old = localtime time() - get_keep_debug_info_period;
		++$old[4]; @old[5] += 1900;
		my $old = sprintf "%04d-%02d-%02d %02d:%02d:%02d", @old[5,4,3,2,1,0];
		if (open my $LOG, "< $debug_info_file")
		{
			# Read and keep all entries that are greater than $old.
			# NB: Entries start with date in sortable order and
			# letters are greater than numbers.
			my @log = grep $_ gt $old, <$LOG>;
			close $LOG;
			open $LOG, "> $debug_info_file" or die "Cannot write '$debug_info_file': $!";
			print $LOG @log;
			close $LOG;
		}
	}

	# Check that at most one timer is running and fix it if not.
	my @running = get_all_timers_running;
	#info "initialize(): Running: @running\n";
	# Determine which timer should actually be running.
	my $active_timer;
	if (get_keep_running_status)
	{
		# Override startup timer during this initialize.
		$active_timer = undef;
		set_keep_running_status 0;
	}
	else
	{
		# Use this startup timer.
		$active_timer = get_activate_on_startup;
	}
	if (defined $active_timer)
	{
		# ActivateOnStartup, so timer should start running.
		$IsStopped = 0;
	}
	elsif (@running > 0)
	{
		# Take the first running timer.
		$active_timer = shift @running;  # take first
		$IsStopped = 0;
	}
	else
	{
		# Keep the original
		$active_timer = get_active;
		$IsStopped = 1;
	}
	# Pause all other timers
	foreach (@running)
	{
		if ($_ != $active_timer)
		{
			&$cb_deactivate($_) if $cb_deactivate;
			timer_pause $_;
		}
	}
	# Start timer if it should and doesn't.
	if (!$IsStopped && !get_timer_running $active_timer)
	{
		timer_run $active_timer;
	}
}

# Initialize user interface (like draw correct state for widgets) before
# control is handed over to MainLoop.
sub initialize_ui
{
	# Show the active timer
	&$cb_activate(get_active) if $cb_activate;
	# Show start/stop status
	if ($IsStopped)
	{
		&$cb_stop if $cb_stop;
	}
	else
	{
		&$cb_start if $cb_start;
	}
}

# Finalizes application. Called just before exit.
sub finalize
{
	# If timer should stop on exit, do that here.
	if (!get_keep_running_status && get_pause_on_exit)
	{
		if (!$IsStopped)
		{
			$IsStopped = 1;
			my $active_timer = get_active;
			timer_pause $active_timer if $active_timer >= 0;
		}
	}

	# Force update latest change in descriptions
	process_pending_description_changes 1;

	# Update all configuration changes
	update_all_config;
}


##############################################################################
### Description related functions

# The description is not submitted atomically. Therefore, it is necessary to
# collect the changes as they happen and decide when to write the final result.
# A description is considered final if it hasn't changed for 10 seconds. This
# is checked in time_tick().

# Collect changes as they happen.
sub set_description_delayed
{
	my ($timer, $description) = @_;

	my $last_description = $DescriptionChanges{$timer}[1];
	my $curr_description = get_timer_current_description $timer;
	if ($description eq $curr_description)
	{
		# The description is now (again) the same. There is no
		# actual change.
		delete $DescriptionChanges{$timer};
		#info "Remove/Ignore pending description change for timer $timer\n";
	}
	elsif ($description ne $last_description)
	{
		# It is a real change wrt last change
		my $ts = get_timestamp;  # timestamp of change
		$DescriptionChanges{$timer} = [ $ts, $description ];
	}
}

# Process the currently collected latest changes.
# If $force is true, the latest changes are written, otherwise they have to
# be stable for a certain timeout value ($DescriptionChangeMaxPendingTime).
sub process_pending_description_changes
{
	my ($force) = @_;

	my $now = get_timestamp;
	foreach my $timer (keys %DescriptionChanges)
	{
		my $entry = $DescriptionChanges{$timer};
		if (!defined $entry)
		{
			# Fast clicking between descriptions can cause empty entries to
			# be created. Just delete them and ignore them.
			delete $DescriptionChanges{$timer};  # cleanup
			next;
		}
		my ($ts, $description) = @{$DescriptionChanges{$timer}};
		if ($now - $ts > $DescriptionChangeMaxPendingTime || $force)
		{
			# This change (latest change for this timer) is more
			# than 10 seconds ago. (Or processing is forced.)
			set_timer_description $timer, $description, $ts;
			# Remove this entry
			delete $DescriptionChanges{$timer};
			# Give UI chance to update
			update_timers;
		}
	}
}

# Force updating the currently collected latest changes.
sub force_pending_description_changes
{
	process_pending_description_changes 1;
}


##############################################################################
### Group related functions

sub create_default_groups
{
	# Copy default groups to groups file
	copy_file get_groups_file_default, get_groups_file;
}

sub edit_groups
{
	my $fname = get_groups_file;
	create_default_groups unless -e $fname;
	edit_file $fname;
}

# For defined timer-groups
my $_timer_groups = undef;  # the latest group_infos read
my $_timer_groups_mtime = -1;  # modification time to know when cache invalid
my $_timer_groups_by_name = undef;  # hash for lookup by name

# Return an arrayref with group-entries which have the following fields:
# name: Group name
# type: Group type
# color: Group color
sub get_timer_group_infos
{
	my $fname = get_groups_file;
	create_default_groups unless -e $fname;
	my $mtime = (stat $fname)[9];  # modification time
	if ($mtime > $_timer_groups_mtime)
	{
		# File has changed, re-read it
		my $groups1 = read_timer_groups;
		my $groups2 = get_used_timer_groups;
		# Store in cache variables and remember which group have changed
		my $old_timer_groups_by_name = $_timer_groups_by_name;
		my %changed_groups = ();
		$_timer_groups = [];
		$_timer_groups_mtime = $mtime;
		$_timer_groups_by_name = {};
		foreach my $group (@$groups1, @$groups2)
		{
			# Iterate through all the groups that are defined
			# and/or used.
			# NB: All groups that are displayed in the timers are
			# used groups and are thus included in this iteration.
			# NB: Iterate defined groups first, so that those
			# types will override the used ones.
			my $name = $$group{name};
			next if exists $$_timer_groups_by_name{$name};  # already seen def

			push @$_timer_groups, $group;
			$$_timer_groups_by_name{$name} = $group;

			# Check if this is the first read
			if (!defined $old_timer_groups_by_name)
			{
				info "Read group '$name'\n";
				$changed_groups{$name} = $group;
				next;
			}

			# Check if it changed
			my $old_group = $$old_timer_groups_by_name{$name};
			# the name is the same because we selected that key
			if (!defined $old_group)
			{
				info "Group '$name' changed: New group\n";
				$changed_groups{$name} = $group;
			}
			elsif ($$group{type} ne $$old_group{type})
			{
				info "Group '$name' changed: Type changed from '$$old_group{type}' to '$$group{type}'\n";
			}
			elsif (defined($$group{color}) != defined($$old_group{color}))
			{
				# if the defined-ness changed, the group was
				# moved in or out of the groups file.
				if (defined($$group{color}))
				{
					info "Group '$name' changed: Added color\n";
				}
				else
				{
					info "Group '$name' changed: Removed color\n";
				}
				$changed_groups{$name} = $group;
			}
			elsif ($$group{color} ne $$old_group{color})
			{
				info "Group '$name' changed: Color changed from '$$old_group{color}' to '$$group{color}'\n";
				$changed_groups{$name} = $group;
			}
		}
		#use Data::Dumper; info Dumper $_timer_groups; info Dumper $_timer_groups_by_name;

		# Go through the timers and update the ones that refer to a changed
		# group.
		#info "Changed groups (GUI): @{[sort keys %changed_groups]}\n";
		foreach my $timer (0..get_num_timers)
		{
			my $name = get_timer_current_group_name $timer;
			if (exists $changed_groups{$name})
			{
				my $color;
				if (my $group = $changed_groups{$name})
				{
					#info "Update Group '$name'\n";
					$color = $$group{color};
				}
				else
				{
					#info "Update removed Group '$name'\n";
					$color = undef;
				}
				&$cb_update_timer_group($timer, $name, $color)
					if $cb_update_timer_group;
			}
			my $currType = get_timer_current_group_type $timer;
			my $newType = $$_timer_groups_by_name{$name}{type};
			if ($newType ne $currType)
			{
				# Update the timer type in the storage file.
				set_timer_group_name($timer, $name);
			}
		}
	}
	return $_timer_groups;
}

# Return the timer group entry for the specified group name.
# Returns undef if groupname could not be found.
# If $groupname is a regex, the first matching is returned.
sub get_timer_group_info
{
	my ($groupname) = @_;

	get_timer_group_infos;  # update cache
	#info "get_timer_group_info($groupname)\n";
	if (is_regex $groupname)
	{
		return undef unless defined $_timer_groups;
		foreach (@$_timer_groups)
		{
			return $_ if $$_{name} =~ $groupname;
		}
	}
	else
	{
		return $$_timer_groups_by_name{$groupname};
	}
}

# Change the timer group for the specified timer to the one with groupname.
# If $groupname is a regex, the first matching is returned.
sub set_timer_group_name
{
	my ($timer_id, $groupname) = @_;

	my $set = 0;
	my $grouptype;
	if ($groupname eq "")
	{
		# We should set the 'emtpy' group
		$grouptype = 0;
		$set = 1;
	}
	else
	{
		my $group = get_timer_group_info $groupname;
		if ($group)
		{
			$groupname = $$group{name};
			$grouptype = $$group{type};
			$set = 1;
		}
		else
		{
			#info "Could not find group '$groupname' for timer $timer_id\n";
			$grouptype = "";  # keep this empty
		}
	}

	if ($set)
	{
		#info "Set group of timer $timer_id to '$groupname'\n";
		set_timer_group $timer_id, $groupname, $grouptype, get_timestamp;
		# Give UI chance to update
		update_timers;
	}
}

# Check if the groups have changed and redraw the timer groups, that have
# changed, on the main window.
sub reevaluate_timer_groups
{
	my ($force) = @_;

	if ($force)
	{
		# Force re-read of timer groups
		undef $_timer_groups_mtime;
	}

	# (Re-)check the timer groups
	get_timer_group_infos;  # update cache
}

# Test the Timer's TimerGroup's Type.
# Arguments:
# - $timer: The Timer number whose TimerGroup to test.
# - @group_types: The GroupTypes to match. If any matches, true is returned.
# A group_type can be:
# - regex: Perform a regex comparison.
# - numeric: If the Timer's group is also numeric, a numeric compare is done.
# - string: If neither of the above cases is true, a string comparison is done.
# If the Timer's TimerGroup contains ',', it is regarded as a comma separated
# list of values. If any of the values match, this function returns true.
sub is_timer_group_type
{
	my ($timer, @group_types) = @_;

	my $timer_group_type = get_timer_current_group_type($timer);
	if (!defined $timer_group_type)
	{
		# This type does not have a group, return false
		return 0;
	}

	my @timer_group_types = split /,/, $timer_group_type;
	foreach my $timer_group_type (@timer_group_types)
	{
		foreach my $group_type (@group_types)
		{
			if (is_regex $group_type)
			{
				# Test against a regex
				return 1 if $timer_group_type =~ $group_type;
			}
			elsif (is_integer $group_type && is_integer $timer_group_type)
			{
				# Test numeric
				return 1 if $timer_group_type == $group_type;
			}
			else
			{
				# Test as string
				return 1 if $timer_group_type eq $group_type;
			}
		}
	}
	return 0;  # there was no match
}


##############################################################################
### Time related functions

# This function should be called at least once a second and it updates the
# times.
sub time_tick
{
	#info "Core::time_tick()\n";
	my $time = get_timestamp;
	my $active_timer = get_active;
	if ($time != $LastTime)
	{
		# The time has changed, update times

		if (!get_keep_running_status && get_pause_on_suspend &&
			!$IsStopped &&
			$LastTime > 0 && $time - $LastTime > $MaxTimeBetweenTicks)
		{
			# No activity for a certain time
			# ($MaxTimeBetweenTicks), so suspend is assumed.  If
			# PauseOnSuspend is configured, pause the timer, but
			# also start it again, because now there is activity
			# again.
			my @events = [ "p", $active_timer, $LastTime ];
			push @events, [ "r", $active_timer ];
			timer_events \@events;
		}

		if (($time % (60*60)) == 0)
		{
			# Execute this once every hour
			$TimeZone = undef;
			get_timezone_offset;
		}

		# Update time window
		&$cb_update_wall_time($time) if $cb_update_wall_time;

		# Update running timer
		TimeKeeper::Storage::time_1sec;
		show_timer $active_timer;

		$LastTime = $time;
	}

	if (($time % 60) == 0)
	{
		# Check if the timer-group file has changed.
		reevaluate_timer_groups;
	}

	# Check if there are changes in descriptions that should be added
	# to the State.
	process_pending_description_changes;

	# Update the changed timers. If updates have been dealt with already
	# (like in show_timer or process_pending_description_changes), nothing
	# will happen here.
	update_timers;
}


##############################################################################
### Active timer related functions

my $_last_active_timer = undef;

sub activate
{
	my ($timer) = @_;

	my $active_timer = get_active;
	if ($timer != $active_timer)
	{
		# Only do something if timer is different.
		my @events;
		&$cb_deactivate($active_timer) if $cb_deactivate;
		push @events, [ "p", $active_timer ] if $active_timer >= 0;

		push @events, [ "r", $timer ] if $timer >= 0;
		timer_events \@events;
		&$cb_activate($timer) if $cb_activate;
	}
	$_last_active_timer = $active_timer;

	# Always start running if paused.
	start if $IsStopped;

	# Update changes
	update_timers;
}

sub get_active
{
	my @running = get_all_timers_running;
	# Take first running timer or last active
	my $active_timer = (@running) ? shift @running : $_last_active_timer;
	$active_timer = $DefaultActiveTimer unless defined $active_timer;
	# Stop all others
	foreach (@running)
	{
		timer_pause $_;
	}
	# If changed, update
	if (!defined $_last_active_timer)
	{
		$_last_active_timer = $active_timer;
	}
	elsif ($active_timer != $_last_active_timer)
	{
		my $old_active_timer = $_last_active_timer;
		# This prevents a recursive call via (de)activate callbacks
		$_last_active_timer = $active_timer;
		# Update GUI
		&$cb_deactivate($old_active_timer) if $cb_deactivate;
		&$cb_activate($active_timer) if $cb_activate;
	}

	return $active_timer;
}

# Show specified value on timer(s).
# Also updates GUI.
# If $time==undef (default), the current time is used.
sub show_timer
{
	my ($timer_or_timers, $time) = @_;

	if (defined $time)
	{
		set_timer_time $timer_or_timers, $time;
	}
	mark_changed_timer $timer_or_timers, "T";
	update_timers;
}

# Evaluates the time_expr.
# Returns the result or undef if there is an error.
sub eval_time
{
	my ($time_expr) = @_;

	#info "Original expression: '$time_expr'\n" if $time_expr != 1;
	# interpret "" as 0
	$time_expr = 0 if $time_expr eq "";
	# interpret h:mm:ss and h:mm
	# remove leading 0, because it makes the number interpret as octal
	$time_expr =~ s/0*(\d+):0*(\d+):0*(\d+)/($1*3600+$2*60+$3)/g;
	$time_expr =~ s/0*(\d+):0*(\d+)/($1*3600+$2*60)/g;
	# interpret h, m and s suffixes/infixes
	$time_expr =~ s/(?<=\d)h(?![a-z])/*3600+/gi;
	$time_expr =~ s/(?<=\d)m(?![a-z])/*60+/g;
	$time_expr =~ s/(?<=\d)s(?![a-z])/*1+/g;
	$time_expr =~ s/\+(?=\s*($|\)))//g;  # remove superfluous '+' at end of (sub)expression
	#info "Evaluating '$time_expr'\n" if $time_expr != 1;  # (1 is normal tick)
	my $time = eval $time_expr;

	return $time;
}

# Set the timer to $time_expr.
# Returns true if successful.
sub set_timer
{
	my ($timer, $time_expr) = @_;

	# Calculate the delta
	my $time = eval_time $time_expr;
	die "Error in expression '$time_expr': $@\n" unless defined $time;

	set_timer_time $timer, $time;
	update_timers;

	return 1;
}

# Add the $deltatime_expr to the timer.
# Returns true if successful.
sub add_timer
{
	my ($timer, $deltatime_expr) = @_;

	# Calculate the delta
	my $deltatime = eval_time $deltatime_expr;
	die "Error in expression '$deltatime_expr': $@\n" unless defined $deltatime;

	# Use the value from current_time to calculate if this change is valid,
	# but do not add and set the timer with this value again. Use inc_timer_time()
	# for that to keep the relative nature of this change.
	my $time = get_timer_current_time $timer;

	my $ok = 1;
	if ($time + $deltatime >= 0)
	{
		# This change will keep $time valid
		$time = inc_timer_time $timer, $deltatime;
	}
	else
	{
		$ok = 0;
	}
	update_timers;

	return $ok;
}

# Evaluate the expression and add the resulting amount of time to the active
# timer.
sub add_active_timer
{
	my ($deltatime_expr) = @_;

	return add_timer get_active, $deltatime_expr;
}

# Evaluate the expression and transfer the resulting amount of time from
# $from_timer to $to_timer. If a $from_timer and/or $to_timer is undef, the
# active timer is used.
# If the transfer would make either timer less than 0, it will not be done.
# Returns true if transfer ok, false if not.
sub transfer_time
{
	my ($from_timer, $to_timer, $deltatime_expr) = @_;

	my $active_timer = get_active;
	$from_timer = $active_timer unless defined $from_timer;
	$to_timer = $active_timer unless defined $to_timer;

	# Calculate the delta
	my $deltatime = eval_time $deltatime_expr;
	die "Error in expression '$deltatime_expr': $@\n" unless defined $deltatime;

	# Use the value from current_time to calculate if this change is valid,
	# but do not add and set the timer with this value again. Use inc_timer_time()
	# for that to keep the relative nature of this change.
	my $from_time = get_timer_current_time $from_timer;
	my $to_time = get_timer_current_time $to_timer;

	my $ok = 0;
	if ($from_time - $deltatime >= 0 && $to_time + $deltatime >= 0)
	{
		# This change will keep $from_time and $to_time valid
		($from_time, $to_time) = transfer_timer_time
			$from_timer, $to_timer, $deltatime;
		$ok = 1;
	}
	update_timers;

	return $ok;
}

# Get the period before the current period (period on the active timer) and
# return that as (start, stop, timer).
# If no such period can be found, an empty array is returned.
sub get_previous_period_info
{
	my $timeline = timeline_nice -discard => [],
		-min_gap => 10, -min_period => 0, -round => 0;
	my $last = pop @$timeline;
	if (defined $last && $$last[2] == get_active)
	{
		# Last period is the currently running one on the active timer
		$last = pop @$timeline;  # skip it
	}
	if (defined $last)
	{
		return @$last;
	}
	else
	{
		return ();
	}
}


##############################################################################
### Start/stop related functions

sub start
{
	if ($IsStopped)
	{
		$IsStopped = 0;
		my $active_timer = get_active;
		timer_run $active_timer if $active_timer >= 0;
	}
	&$cb_start if $cb_start;
}

sub stop
{
	if (!$IsStopped)
	{
		$IsStopped = 1;
		my $active_timer = get_active;
		timer_pause $active_timer if $active_timer >= 0;
	}
	&$cb_stop if $cb_stop;

	update_status_file;
}

sub startstop
{
	$IsStopped ? start : stop;
}


##############################################################################
### Log related functions

sub create_default_logdef
{
	# Copy default logdef to logdef file
	copy_file get_logdef_file_default, get_logdef_file;
}

# Returns true if the specified target is included in the current targets.
sub is_generate_log_target
{
	my ($target) = @_;
	return (grep $_ eq $target, get_generate_log_targets) ? 1 : 0;
}

# Add or remove the specified target, depending on the value of $$status_ref.
sub add_remove_generate_log_target
{
	my ($target, $status_ref) = @_;

	# Take current targets and remove specified target
	my @targets = grep $_ ne $target, get_generate_log_targets;
	if ($$status_ref)
	{
		# Add specified target
		push @targets, $target;
	}
	#info "Update GenerateLogTargets: '@targets'\n";
	set_generate_log_targets @targets;
}

sub edit_logdef
{
	my $fname = get_logdef_file;
	create_default_logdef unless -e $fname;
	edit_file $fname;
}

sub generate_log
{
	(our $AltLogId) = @_;

	my $fname = get_logdef_file;
	create_default_logdef unless -e $fname;
	# $AltLogId is package variable, so it is visible inside do.
	my $log = do $fname;  # "do get_logdef_file" doesn't work
	unless (defined $log)
	{
		# Generating the log failed. This can be due to a syntax error.
		# If that is the case and we don't have a GUI yet, no error
		# will be displayed with wperl. Therefore, write the error also
		# to the info log.
		my $msg = "Error in log: $!$@\n";
		info $msg;
		die $msg;
	}
	$log = unix2dos $log;  # most systems understand dos (=network) format
	return $log;
}

sub get_alt_logs
{
	our @AltLogs;
	generate_log;  # sets global @AltLogs
	return @AltLogs;
}

# Generate the log and send it to the specified targets in the arguments.
# Targets can be:
# - "editor": Display the content in an editor
# - "clipboard": Send the content to the clipboard
# The first argument is the $AltLogId that defines how to generate. This
# variable is available in generate_log().
sub make_log
{
	my ($AltLogId, @targets) = @_;

	# Make descriptions consistent.
	force_pending_description_changes;

	my $log = generate_log $AltLogId;
	my %targets; $targets{$_} = 1 foreach @targets;
	# Copy to editor last, because that may block, depending on the editor.
	if ($targets{clipboard})
	{
		&$cb_set_clipboard($log) if $cb_set_clipboard;
	}
	if ($targets{editor})
	{
		edit_text $log;
	}
}


##############################################################################
### Other file related functions

sub edit_config
{
	my $fname = get_config_file;
	write_config_file unless -e $fname;
	edit_file $fname;
}

sub edit_storage
{
	my $fname = get_data_file;

	# Make descriptions consistent.
	force_pending_description_changes;

	edit_file $fname;
}


##############################################################################
### General callback related functions

sub set_cb_activate
{
	$cb_activate = shift;
}

sub set_cb_deactivate
{
	$cb_deactivate = shift;
}

sub set_cb_start
{
	$cb_start = shift;
}

sub set_cb_stop
{
	$cb_stop = shift;
}

sub set_cb_update_timer_time
{
	$cb_update_timer_time = shift;
}

sub set_cb_update_timer_description
{
	$cb_update_timer_description = shift;
}

sub set_cb_update_timer_group
{
	$cb_update_timer_group = shift;
}

sub set_cb_update_wall_time
{
	$cb_update_wall_time = shift;
}

sub set_cb_set_clipboard
{
	$cb_set_clipboard = shift;
}


1;


