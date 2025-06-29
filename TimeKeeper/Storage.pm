package TimeKeeper::Storage;

# This module implements the storage and update of the timer events. These events contain the entire
# timer state. It also provides a function to create a timeline that is further processed in the
# TimeKeeper::Timeline module.

use strict;
use Carp;
my $CanUseThreads;
BEGIN
{
	$CanUseThreads = eval 'use threads; use Thread::Queue; 1';
}

use Fcntl qw(:flock SEEK_END SEEK_SET);

use TimeKeeper::Config;
use TimeKeeper::Utils;

BEGIN
{
	use Exporter ();
	our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

	# set the version for version checking
	$VERSION     = 1.00;

	@ISA         = qw(Exporter);
	@EXPORT      = (
		# Absolute state setting functions
		qw/set_timer_time set_timer_description set_timer_group
		set_timer_extra/,
		# Relative state modifying functions
		qw/inc_timer_time transfer_timer_time
		timer_run timer_pause timer_pause_all timer_events/,

		# State retrieval functions
		qw/get_timer_current_time
		get_timer_current_description
		get_timer_current_group_name get_timer_current_group_type get_used_timer_groups
		get_timer_extra
		get_timer_running get_all_timers_running
		get_changed_timers peek_changed_timers mark_changed_timer/,

		# State read/write
		qw/read_storage_file/,

		# Other functions
		qw/create_timeline/,
	);
	@EXPORT_OK   = (
		# Functions that can be called, but are not exported
		# automatically
		qw/time_1sec/,
	);
	%EXPORT_TAGS = ();  # eg: TAG => [ qw!name1 name2! ],
}


##############################################################################
### Global variables

my $StartUpTime = get_storage_timestamp();

# This @State array contains all the entries in the storage_file. Each entry
# is an array with the following elements:
# - GMT timestamp: UNIX timestamp in UTC
# - Timer: If it is a number, it is >=0, can be >NumTimers, so that only a
#   subset is used and the remaining timers are left unchanged.
#   It can also be a name, in which case it is a special object with a value
#   (that is stored with the E event code). In this case it does not time time,
#   but another value.
# - Event code: T, D, G, i, r, or p
# - Event specific arguments, which are:
#   * T (set_time):
#     - time: time to set the timer to (integer, in seconds)
#     - eventid: random id to identify absolute events when merging
#   * D (set_description):
#     - description: string to set the description to
#     - eventid: random id to identify absolute events when merging
#   * G (set_group):
#     - group name: string to set the group name to
#     - group type: string that specifies the type of this group (the meaning
#         of this field is up to the log definition where it is used)
#     - eventid: random id to identify absolute events when merging
#   * E (extra_info):
#     - info name
#     - info value
#   * i (increase_time):
#     - time: time to increase the timer value with (integer, in seconds)
#   * r (run):
#     - <no arguments>
#   * p (pause):
#     - <no arguments>
# The @State should be ordered by time (duplicate timestamps are allowed), so
# that it can be processed from beginning to end to 'replay' the events.
my @State = ();
my $Storage_appended = 0;  # number of events appended
my $Storage_changed = 1;  # if true, entire state might have been changed
my $Storage_ts = undef;  # timestamp van the last read storage file

my $Backupper_thread = undef;  # if set, this is the backupper() thread.
my $Backupper_queue = undef;  # if set, this is a message queue to backupper()
END
{
	if ($Backupper_queue)
	{
		$Backupper_queue->enqueue("EXIT");
		$Backupper_thread->join;
	}
	$Backupper_thread = $Backupper_queue = undef;
}

# Derived, 'running-total' states
my %Descriptions;
my %GroupNames;
my %GroupTypes;
my %Times;
my %Times_running;  # Is a substate of %Times.
my %ExtraInfo;

# This hash(set) contains the timerids that have been changed since it was
# reset. All state changing functions in this module use this variable to
# indicate state changes.
# The key is the changed timer's id. The value is a hash(set) to indicate which
# states have been changed. The following keys are used to indicate that:
# - 'D' : description changed
# - 'T' : time changed
# - 'G' : group changed
my %ChangedTimers = ();  # id -> state -> true

# Forward declarations
sub add_event;
sub replay_state;
sub mark_changed_timer;

sub get_storage_timestamp { return time; }  # Storage works with GMT timestamps

# Throughout this module, different properties of the events are used.
# %EventTraits is a global structure that stores these constant properties.
# (Used in: state_cleanup)
my %EventTraits = (
	G => create_event_trait(1, "g", 1),
	D => create_event_trait(1, "d", 2),
	T => create_event_trait(1, "t", 3),
	p => create_event_trait(0, "t", 4),
	r => create_event_trait(0, "t", 5),
	i => create_event_trait(0, "t", 6),
	E => create_event_trait(1, "e", 7),
);

sub create_event_trait {
	return {
		is_absolute => $_[0],  # 0==relative event, 1==absolute event
		data_item   => $_[1],  # t=time, d=description, g=group
		sort        => $_[2],  # sort-order (ascending)
	};
}


##############################################################################
### Read/write functions

sub get_storage_file_mtime
{
	my $fname = get_data_file;
	if (-e $fname)
	{
		return (stat $fname)[9];  # file's mtime
	}
	else
	{
		return undef;  # file does not exist
	}
}

# Calculate the file open mode from a preset and a delta.
# Arguments:
# - $preset: Set initial value. undef if unknown.
# - $update: The change wrt the preset.
# - $is_new: True if $update is the new value.
# - $is_append: True if $update should be appended.
# Returns array with the following elements:
# - File open mode ('>' or '>>')
# - Seek position (SET or END)
# - Contents to be written
# Returns undef if no change
sub get_open_mode
{
	my ($preset, $update, $is_new, $is_append) = @_;

	my ($open_mode, $seek_pos, $contents);
	if ($is_new)
	{
		# $update defines new contents, take that
		$open_mode = ">";
		$seek_pos = SEEK_SET;
		$contents = $update;
	}
	elsif ($is_append)
	{
		if (defined $preset)
		{
			# $update should be appended to $preset to get new
			# contents
			$open_mode = ">";
			$seek_pos = SEEK_SET;
			$contents = $preset . $update;
		}
		else
		{
			# $update should be appended to current contents
			$open_mode = ">>";
			$seek_pos = SEEK_END;
			$contents = $update;
		}
	}
	elsif (defined $preset)
	{
		# $preset is new contents without update
		$open_mode = ">";
		$seek_pos = SEEK_SET;
		$contents = $preset;
	}

	return ($open_mode, $seek_pos, $contents);
}

# To make storage-file access atomic, do all file access via this read-modify-
# write function. The read-part will lock and read the file if it contains
# newer contents than @State. The modify is passed in the $modifier coderef.
# The 
# Read all the records (events) in the storage file and apply the updates
# to the internal state.
# Arguments:
# - $modifier: This is a coderef that gets a ref to the state to process. It
#     needs to set $Storage_changed/appended appropriately. Its return value
#     is not used.
sub rmw_storage_file
{
	my ($modifier) = @_;

	#info "rmw_storage_file()\n";

	my $fname = get_data_file;
	my $fh = undef;

	# Original contents of the storage file if the file was reread.
	my $org_contents = undef;

	# Read the storage file if necessary
	if (-e $fname)
	{
		my $new_ts = get_storage_file_mtime;
		if ($Storage_ts != $new_ts)
		{
			info "storage read (current=$Storage_ts, new=$new_ts)\n";
			# File is different, reload it
			open $fh, "+< $fname" or die "Cannot open storage '$fname': $!";
			flock $fh, LOCK_EX or die "Cannot lock storage '$fname': $!";

			@State = ();  # empty current state
			foreach (0..get_num_timers)
			{
				mark_changed_timer $_, "T", "D";
			}
			# Note: The events are ordered by time.
			$org_contents = "";
			while (<$fh>)
			{
				$org_contents .= $_;

				s/[\r\n]+$//;  # NB: chomp fouls up dos/unix formats
				next if /^\s*(#|$)/;  # skip comment and empty lines
				my @entry = split /\t/;

				# Unify notations
				$entry[0] = parse_datetime $entry[0];

				# Add entry to state
				push @State, \@entry;
			}

			# Update timestamp within lock to avoid race
			$Storage_ts = get_storage_file_mtime;

			replay_state \@State;

			# Global variables are now in sync with storage file.
			$Storage_changed = $Storage_appended = 0;
		}
		# else keep current states
	}
	elsif (@State &&
		!keys(%Descriptions) &&
		!keys(%GroupNames) && !keys(%GroupTypes) &&
		!keys(%Times) && !keys(%Times_running) &&
		!keys(%ExtraInfo))
	{
		# The storage file does not exist, there is state and the
		# 'running totals' are empty. This means that this is an
		# initialization.
		replay_state \@State;
	}
	else
	{
		# If files does not exist or is not available, use the data
		# that is currently in memory (can be the default as specified
		# in the global variables).
	}

	# Modify the @State.
	&$modifier(\@State) if $modifier;
	# $Storage_changed/appended is set appropriately

	# Update of the contents
	my $contents_update = undef;

	# Write or append the changes to the storage file.
	if ($Storage_changed || $Storage_appended)
	{
		# Make sure the directory exists
		mkfiledir $fname unless -e $fname;

		# Check validity of file by timestamp
		if ($Storage_ts != get_storage_file_mtime)
		{
			# Proper locking should prevent this situation
			# (There exists a small race condition here, because
			# this check is done before opening and locking
			# the file later on. Opening for writing changes the
			# mtime, so this check cannot be done after the open().)
			die "Cannot write storage '$fname': File changed since last read.";
		}

		my @range;
		if ($Storage_changed)
		{
			# Some changes have occurred within the state so that
			# the entire storage file needs to be rewritten
			@range = ( 0, @State-1 );

			#info "storage write\n";
		}
		elsif ($Storage_appended)
		{
			# Append some events
			my $len = @State;
			@range = ( $len-$Storage_appended, $len-1 );

			#info "storage append\n";
		}

		# Open the file if not already open
		my ($open_mode, $seek_pos) =
			get_open_mode undef, undef, $Storage_changed, $Storage_appended;
		if (!$fh)
		{
			# Open file if necessary
			if (open $fh, $open_mode, $fname)
			{
				flock $fh, LOCK_EX or die "Cannot lock storage '$fname': $!";
			}
			else
			{
				$fh = undef;
			}
		}

		if ($fh)
		{
			# Do the actual file write

			# Seek to start/end for rewrite/append (end can be
			# changed while waiting for lock)
			seek $fh, 0, $seek_pos or die "Cannot seek storage '$fname': $!";
			#info sprintf "Storage file pos: %d\n", tell $fh;

			# Calculate current timezone
			my $tz = get_tz;
			# Write the entries to file
			$contents_update = "";
			foreach my $idx ($range[0]..$range[1])
			{
				my $entry = $State[$idx];
				# Convert timestamp to datetime
				my $ts = format_datetime_iso $$entry[0], $tz;
				# Write the line
				$contents_update .= $ts;  # first element
				my $len = @$entry;
				for (my $i = 1; $i < $len; ++$i)  # rest
				{
					$contents_update .= "\t$$entry[$i]";
				}
				$contents_update .= "\n";
			}
			print $fh $contents_update;
		}
		else
		{
			warn "Cannot open storage '$fname': $!";
		}
	}

	# Close and unlock storage if file handle is assigned
	if ($fh)
	{
		flock $fh, LOCK_UN or die "Cannot unlock storage '$fname': $!";
		close $fh or die "Cannot close storage '$fname': $!";
		$fh = undef;

		# Update the new timestamp (there is a little race condition
		# that the file is changed between unlock and this)
		$Storage_ts = get_storage_file_mtime;
	}

	if ($modifier)
	{
		# There are actual changes to the state, backup them too.
		# If the backup fails, ignore that and try next time again.
		my $bkfname = get_data_backup_file;
		if ($bkfname ne "")
		{
			if ($CanUseThreads)
			{
				# Threads are available, use that, so that long
				# timeouts are not a problem. This may happen
				# if the backup file is on a share that is not
				# available.
				unless ($Backupper_queue)
				{
					$Backupper_queue = Thread::Queue->new;
					$Backupper_thread = threads->create(\&backupper, $fname, $bkfname);
				}
				$Backupper_queue->enqueue("BACKUP");
			}
			else
			{
				# Just call directly
				eval
				{
					copy_file $fname, $bkfname;
				};
				if ($@)
				{
					info "Backup thread: Could not backup events: $@";
				}
			}
		}
	}

	# Changes updated, reset flags
	$Storage_changed = $Storage_appended = 0;
}

# This function copies $fname to $backup_fname.
# It runs on a separate thread and listens to the $Backuppper_queue, which
# recognizes the following commands:
# - BACKUP: Perform a backup. The thread may wait a little while to wait for
#     more requests to perform them at once.
# - EXIT: Stop the thread.
sub backupper
{
	my ($fname, $backup_fname) = @_;

	info "Backup thread: Started\n";
	while (1)
	{
		# Read the commands until it is quiet for some time.
		my $do_backup = 0;
		my $do_exit = 0;
		while (1)
		{
			if (defined(my $command = $Backupper_queue->dequeue_timed(30)))
			{
				# A command within 30 sec
				info "Backup thread: Received '$command'\n";
				if ($command eq "BACKUP")
				{
					$do_backup = 1;
				}
				elsif ($command eq "EXIT")
				{
					$do_exit = 1;
					last;
				}
				else
				{
					info "Backup thread: Unknown command: '$command'\n";
				}
			}
			else
			{
				# Quiet for 30 sec
				#info "Backup thread: No command within 30 sec\n";
				last;
			}
		}

		# Execute what needs to be done
		if ($do_backup)
		{
			eval
			{
				copy_file $fname, $backup_fname;
				info "Backup thread: Backed up events\n";
			};
			if ($@)
			{
				info "Backup thread: Could not backup events: $@";
			}
		}
		if ($do_exit)
		{
			info "Backup thread: Exiting\n";
			last;
		}
	}
	info "Backup thread: Ended\n";
}

# Read the storage file into @State.
# Returns reference to state.
sub read_storage_file
{
	rmw_storage_file;  # read and don't modify
	return \@State;
}


##############################################################################
### State operations

# These functions operate on the global state (@State) or on an argument that
# represents the state. If the @State is modified, $Storage_changed/appended
# is updated accordingly, so that rmw_storage_file() can be called to sync the
# file.

# This function adds one event to the global state and updates the caches.
sub add_event
{
	my $state = shift;
	my $ts = shift;
	my $timer = shift;
	my $code = shift;
	# arguments are left in @_

	info "add_event($ts,$timer,$code,@_)\n";
	#use Carp; Carp::cluck "Dump call stack";
	my $event = [ $ts, $timer, $code, @_ ];
	# Find the index before which to insert the new event
	my $idx = @$state;
	--$idx while $idx > 0 && $ts < $$state[$idx-1][0];
	# $idx is now such that is the first element with a timestamp greater
	# than $ts.
	if ($idx == @$state)
	{
		# Put this event at the end of the state
		push @$state, $event;
		++$Storage_appended;  # append one more line
	}
	else
	{
		# This timestamp is before the last event and should be
		# inserted into the state.
		splice @$state, $idx, 0, $event;
		$Storage_changed = 1;  # write entire file
	}
}

# Return the substate for a specific timer from the total state.
# Returns an array with references into the total state (as passed to this
# function). This means that the entries can be modified through this array.
# Not yet tested
sub get_substate
{
	my ($state, $timer) = @_;

	my @substate = ();
	foreach (@$state)
	{
		if ($$_[1] eq $timer)  # if this event is for this timer ...
		{
			push @substate, $_;  # ... add reference to substate
		}
	}
	return @substate;
}

# Return the size of the state (or substate).
sub state_size
{
	my ($state) = @_;

	return @$state;
}

# Merge the @$delta state into @$state accoording to certain rules.
sub state_merge
{
	my ($state, $delta) = @_;

	die "To be implemented";
}

# Calculate the delta state from the internal state and an external state, so
# that state_merge($state, state_delta($state, $other_state))==$other_state.
sub state_delta
{
	my ($state, $other_state) = @_;

	die "To be implemented";
}

# Check if there are events in the state that cancel eachother out. Remove
# those cancelled events.
#
# Because events are cancelled by *later* events, iterate the @$state in
# reverse order, so that we can do one pass.
# Per event, the following rules are applied:
# 1) An absolute event (like set) cancels out all previous absolute and
#    relative events (like increase) for the same timer and data item.
#
# Note that events can only cancel events from the same timer.
# The timers are numbered 0..n
# The data items are: g=group, d=description, t=time.
# running_status is a substate of time, which means that run and pause are
# really (relative) time events. It does also mean that if the time is set, its
# substate also has to be explicitly set to not loose information.
sub state_cleanup
{
	my ($state) = @_;

	#info sprintf "state_cleanup(Size=%d)\n", scalar @$state;
	# Iterate from the back and maintain a data structure to determine if
	# earlier events will be cancelled according to the rules before the
	# cut-off window ("near past") starts.
	# Non-cancelled events are copied to the new state.

	my $event_keep_history_time = get_keep_event_history_days() * 24 * 60 *60;

	my $new_state = [];
	my %reset_before_window;  # timer -> data_item -> bool
	my $keep_window_time = get_storage_timestamp() - $event_keep_history_time;
	info "Delete events before $keep_window_time (=" . localtime($keep_window_time) . ")...\n";
	foreach (reverse @$state)
	{
		my $remove_item = 0;

		my ($ts, $timer, $code) = @$_;
		my $data_item = $EventTraits{$code}{data_item};
		my $is_absolute = $EventTraits{$code}{is_absolute};
		my $in_keep_window = $ts > $keep_window_time;
		# NB: When $event_keep_history_time==0, the expectation is
		# that no history is kept.

		if ($in_keep_window)
		{
			# This event is in the near past window and should be
			# kept always.
			$remove_item = 0;
		}
		else
		{
			# This event is outside of the near past window. It
			# should only be kept if there is an absolute event
			# resetting it before the window starts.
			if ($reset_before_window{$timer}{$data_item})
			{
				# This item's effect will be reset before the
				# window starts. It can be removed.
				$remove_item = 1;
			}
			elsif ($is_absolute)
			{
				# This is an absolute event and it is before
				# the window starts.
				$reset_before_window{$timer}{$data_item} = 1;
				#info "ABSOLUTE EVENT BEFORE WINDOW: @$_\n";
			}
		}

		# If the event is cancelled, don't copy it into the new array.
		#info "EVENT @$_: data_item=$data_item, is_absolute=$is_absolute, remove_item=$remove_item\n";
		if ($remove_item)
		{
			info "Remove event '@$_'\n";
			$Storage_changed = 1;  # rewrite entire file
		}
		else
		{
			push @$new_state, $_;
			# I assume a push is faster than an unshift (because of
			# allocation issues), so I'll push now and reverse the
			# result later.
		}
	}
	# Update the argument
	@$state = reverse @$new_state;
}

# The specified amount of time has passed, add this to the running timers.
# If $timer is specified, only that timer is considered, otherwise all timers
# are considered.
sub state_pass_time
{
	my ($time, $timer) = @_;

	my @timers;
	if (defined $timer)
	{
		@timers = $timer;  # just this one
	}
	else
	{
		@timers = keys %Times_running;  # all timers
	}

	foreach my $idx (@timers)
	{
		if ($Times_running{$idx})
		{
			$Times{$idx} += $time;
			mark_changed_timer $idx, "T";
		}
	}
}

# Replay a single event from the state.
# Arguments:
# - $last_ts is the timestamp of the last event replayed.
# - $event is the event to replay.
# Returns timestamp of this event.
# Updates: %Times, %Descriptions, %Times_running, %GroupNames, %GroupTypes, %ExtraInfo.
sub replay_event
{
	my ($last_ts, $event) = @_;
	my ($ts, $timer, $code, $arg1, $arg2) = @$event;

	# Process the event into the cached state
	#info "EVENT: '@$event'\n";
	if ($code eq 'T')  # set_time
	{
		$Times{$timer} = $arg1;
	}
	elsif ($code eq 'D')  # set_description
	{
		$Descriptions{$timer} = $arg1;
	}
	elsif ($code eq 'G')  # set_group
	{
		$GroupNames{$timer} = $arg1;
		$GroupTypes{$timer} = $arg2;
	}
	elsif ($code eq 'E')  # extra info
	{
		_add_to_extra_info($timer, $ts, $arg1, $arg2);
	}
	elsif ($code eq 'i')  # increase_time
	{
		$Times{$timer} += $arg1;
	}
	elsif ($code eq 'r')  # run
	{
		$Times_running{$timer} = 1;
	}
	elsif ($code eq 'p')  # pause
	{
		$Times_running{$timer} = 0;
	}
	else
	{
		confess "Unknown code in event [@$event]: '$code'";
	}

	return $ts;
}

# Note on replay_state for events in the future:
# If there are events that are in the future, it might mess up proper
# interpretation (e.g. if 1 timer running now and one starting running in the
# future is seen as 2 timers running).
# A valid reason for having timestamps in the future is that they come from
# another system with a wrong system clock or timezone (remember that
# timestamps are in UTC).
# The most correct thing to do is to ignore the events in the future and leave
# them untouched, however this is inconvenient e.g. when booking free hours in
# the future. How it is dealt with here is to playback all event no matter how
# far in the future, but remember the running status at the current time.
# At the end, we correct the running status to now.

# Replay the state and calculate the current totals.
# If $timer is defined, only update the current totals for that 1 timer.
# Updates: %Times, %Descriptions, %Times_running, %GroupNames, %GroupTypes, %ExtraInfo.
sub replay_state
{
	my ($state, $timer) = @_;

	#info "replay_state()\n";
	if (defined $timer)
	{
		$Descriptions{$timer} = "";
		$GroupNames{$timer} = "";
		$GroupTypes{$timer} = "";
		$Times{$timer} = 0;
		$Times_running{$timer} = 0;
		$ExtraInfo{$timer} = {};
	}
	else
	{
		%Descriptions = ();
		%GroupNames = ();
		%GroupTypes = ();
		%Times = ();
		%Times_running = ();
		%ExtraInfo = ();
	}
	my %save_Times_running;
	my $now = get_storage_timestamp;
	my $last_ts = 0;
	foreach my $event (@$state)
	{
		my ($ts, $tm) = @$event;
		next if defined $timer && $timer != $tm;  # different timer
		if ($last_ts <= $now && $ts > $now)
		{
			# We crossed the current time. See note above on
			# future events.
			%save_Times_running = %Times_running;
		}

		# Add elapsed time to the running timers
		state_pass_time $ts - $last_ts, $timer;

		$last_ts = replay_event $last_ts, $event;
	}

	# Update running timers to now. Possibly, $last_ts is in the future,
	# in which case, too much time was added to the still running timers.
	# This is also corrected now.
	state_pass_time $now - $last_ts;

	# If we went into the future, restore the running state as it should
	# be now.
	%Times_running = %save_Times_running if keys %save_Times_running;
}


##############################################################################
### Absolute state setting functions

sub create_eventid
{
	get_random 16;
}

# Set the specified timer(s) to the specified time. Do not use get-modify-set
# construction, but rather inc_timer_time().
# The time has two aspects, which need to be set both for an absolute event:
# - time
# - running_status
sub set_timer_time
{
	my ($timers, $time, $ts) = @_;

	$timers = [ $timers ] unless ref $timers;

	#info "set_timer_time([@$timers],$time,$ts)\n";
	$ts = get_storage_timestamp unless defined $ts;

	# Add events to the Storage file
	rmw_storage_file sub {
		my $state = shift;
		foreach my $t (@$timers)
		{
			add_event $state, $ts, $t, "T", $time, create_eventid;
			add_event $state, $ts, $t, ($Times_running{$t} ? "r" : "p");
		}
		state_cleanup $state;
	};

	# Update internal variables and UI
	foreach my $t (@$timers)
	{
		$Times{$t} = $time;
		mark_changed_timer $t, "T";
	}
}

# Set the description of the specified timer.
sub set_timer_description
{
	my ($timer, $description, $ts) = @_;

	#info "set_timer_description($timer,$description,$ts)\n";
	$ts = get_storage_timestamp unless defined $ts;

	# Add events to the Storage file
	rmw_storage_file sub {
		my $state = shift;
		add_event $state, $ts, $timer, "D", $description, create_eventid;
		state_cleanup $state;
	};

	# Update internal variables and UI
	$Descriptions{$timer} = $description;
	mark_changed_timer $timer, "D";
}

# Set the name+type of the group of the specified timer.
sub set_timer_group
{
	my ($timer, $group_name, $group_type, $ts) = @_;

	#info "set_timer_group($timer,$group_name,$group_type,$ts)\n";
	$ts = get_storage_timestamp unless defined $ts;

	# Add events to the Storage file
	rmw_storage_file sub {
		my $state = shift;
		add_event $state, $ts, $timer, "G", $group_name, $group_type, create_eventid;
		state_cleanup $state;
	};

	# Update internal variables and UI
	$GroupNames{$timer} = $group_name;
	$GroupTypes{$timer} = $group_type;
	mark_changed_timer $timer, "G";
}

sub _add_to_extra_info
{
	my ($timer, $timestamp, $extra_info_name, $extra_info_value) = @_;

	# Add new entry
	my $entries = $ExtraInfo{$timer}{$extra_info_name} ||= {};
	my $events = $$entries{events} ||= {};
	$$events{$timestamp} = $extra_info_value;
	# Create sorted cache with unique entries
	my @sorted;
	while (my ($ts, $val) = each %$events)
	{
		push @sorted, [ $ts, $val ];
	}
	@sorted = sort { $$a[0] <=> $$b[0] } @sorted;
	# Set this as sorted cache
	$$entries{sorted} = \@sorted;
}

# Set the extra info for the specified timer.
sub set_timer_extra
{
	my ($timer, $extra_info_name, $extra_info_value, $ts) = @_;

	#info "set_timer_extera($timer, $extra_info, $ts)\n";
	$ts = get_storage_timestamp unless defined $ts;

	# Add events to the Storage file
	my @timers = ();
	rmw_storage_file sub {
		my $state = shift;
		add_event $state, $ts, $timer, "E", $extra_info_name, $extra_info_value;
		state_cleanup $state;
	};

	# Update internal variables
	_add_to_extra_info $timer, $ts, $extra_info_name, $extra_info_value;
}


##############################################################################
### Relative state modifying functions

# Increase the time of the specified timer with the specified amount.
# Use negative time to decrease value.
# Returns new value.
# This function does not do any range checking.
sub inc_timer_time
{
	my ($timer, $time, $ts) = @_;

	#info "inc_timer_time($timer,$time,$ts)\n";
	$ts = get_storage_timestamp unless defined $ts;

	# Add events to the Storage file
	rmw_storage_file sub {
		my $state = shift;
		add_event $state, $ts, $timer, "i", $time;
	};

	# Update internal variables and UI
	$Times{$timer} += $time;
	mark_changed_timer $timer, "T";

	return $Times{$timer};
}

# Transfers time from $timer_from to $timer_to.
# Returns array with new time_from and new time_to.
# This function does not do any range checking.
sub transfer_timer_time
{
	my ($timer_from, $timer_to, $time, $ts) = @_;

	#info "transfer_timer_time($timer,$time,$ts)\n";
	$ts = get_storage_timestamp unless defined $ts;

	# Add events to the Storage file
	rmw_storage_file sub {
		my $state = shift;
		add_event $state, $ts, $timer_from, "i", -$time;
		add_event $state, $ts, $timer_to, "i", $time;
	};

	# Update internal variables and UI
	$Times{$timer_from} -= $time;
	$Times{$timer_to} += $time;
	mark_changed_timer $timer_from, "T";
	mark_changed_timer $timer_to, "T";

	return ( $Times{$timer_from}, $Times{$timer_to} );
}

# Mark specified timer as running.
sub timer_run
{
	my ($timer, $ts) = @_;

	#info "timer_run($timer,$ts)\n";
	#info Carp::longmess "timer_run($timer,$ts)";
	$ts = get_storage_timestamp unless defined $ts;

	# Add events to the Storage file
	rmw_storage_file sub {
		my $state = shift;
		# Start specified timer
		if (!$Times_running{$timer})
		{
			add_event $state, $ts, $timer, "r";
			$Times_running{$timer} = 1;
		}
		state_cleanup $state;
	};
}

# Mark specified timer as stopped.
sub timer_pause
{
	my ($timer, $ts) = @_;

	#info "timer_pause($timer,$ts)\n";
	#info Carp::longmess "timer_pause($timer.$ts)";
	$ts = get_storage_timestamp unless defined $ts;

	# Add events to the Storage file
	rmw_storage_file sub {
		my $state = shift;
		# Stop specified timer
		if ($Times_running{$timer})
		{
			add_event $state, $ts, $timer, "p";
			$Times_running{$timer} = 0;
		}
		state_cleanup $state;
	};

	# This timer is stopped. Ensure it displays the correct state
	replay_state \@State, $timer;
}

# Mark all timers as stopped.
sub timer_pause_all
{
	my ($ts) = @_;

	#info "timer_pause_all($ts)\n";
	$ts = get_storage_timestamp unless defined $ts;

	# Add events to the Storage file
	my @timers = ();
	rmw_storage_file sub {
		my $state = shift;
		# Stop all running timers
		foreach my $idx (keys %Times_running)
		{
			next unless $idx =~ /^\d+$/;  # only numeric timers
			if ($Times_running{$idx})
			{
				add_event $state, $ts, $idx, "p";
				$Times_running{$idx} = 0;
				push @timers, $idx;
			}
		}
		state_cleanup $state;
	};

	# These timers are stopped. Ensure they display the correct state
	replay_state \@State, $_ foreach @timers;
}

# Do a combination of run/pause events.
# Arguments:
# - $events: Array of timer events of any of the following formats:
#     - [ "r", <timer>, <timestamp> ]: run timer; timestamp defaults to now
#     - [ "p", <timer>, <timestamp> ]: pause timer; timestamp defaults to now
sub timer_events
{
	my ($events) = @_;

	#info "timer_pauserun($timer1,$ts1,$timer2,$ts2)\n";
	my $now = get_storage_timestamp;

	# Add events to the Storage file
	my @timers = ();
	rmw_storage_file sub {
		my $state = shift;
		# Update specified timers
		foreach (@$events)
		{
			my ($code, $timer, $ts) = @$_;
			$ts = get_storage_timestamp unless defined $ts;
			if ($code eq "r")
			{
				if (!$Times_running{$timer})
				{
					# Should run, but is stopped
					add_event $state, $ts, $timer, "r";
					$Times_running{$timer} = 1;
				}
			}
			elsif ($code eq "p")
			{
				if ($Times_running{$timer})
				{
					# Should stop, but is running
					add_event $state, $ts, $timer, "p";
					$Times_running{$timer} = 0;
					push @timers, $timer;
				}
			}
			else
			{
				die "Unknown event code ($code)";
			}
		}
		state_cleanup $state;
	};

	# These timers are stopped. Ensure they display the correct state
	replay_state \@State, $_ foreach @timers;
}

# This function should be called every second. It updates the running totals
# of the timers.
# NB: This is not an event in itself
sub time_1sec
{
	#info "Storage::time_1sec()\n";
	# Do not check if a second has passed since the last call, because the
	# caller is checking that. And if both this function and the caller
	# would check it, it can happen that this function is called at
	# 1.0, 1.9 and 3.0. The sum of these intervals is 2 sec, but the
	# first is within the same second and the second is 2 sec. In other
	# words, since our timer has a second resolution, things would get
	# visibly worse, so it is not good to have two of these checks after
	# one another. Ergo: At the top, there is a timer, running at a higher
	# rate. That timer detects seconds transitions and act on those.
	state_pass_time 1;

	my $now = get_storage_timestamp;
	if (($now % 60) == 0)
	{
		# Check if the storage file has changed by someone else.
		rmw_storage_file;
	}
}


##############################################################################
### State retrieval functions

# Get the current time of the specified timer.
sub get_timer_current_time
{
	my ($timer) = @_;

	return $Times{$timer};
}

# Get the current description of the specified timer.
sub get_timer_current_description
{
	my ($timer) = @_;

	return $Descriptions{$timer};
}

# Get the current group name of the specified timer.
sub get_timer_current_group_name
{
	my ($timer) = @_;

	return $GroupNames{$timer};
}

# Get the current group type of the specified timer.
sub get_timer_current_group_type
{
	my ($timer) = @_;

	return $GroupTypes{$timer};
}

# Go through all events and gather all groups that are in use.
# If a group occurs multiple times, it is only returned once.
# Groups are returned in case-insensitive aphanumerical order.
# If $all==true, all groups in the storage file are returned, otherwise only
# the currently-in-use groups (i.e. the last group per timer) is returned.
# Note that these groups don't contain a color field.
sub get_used_timer_groups
{
	my ($all) = @_;

	my %groups;  # group name -> group properties
	my %current;  # timer -> current group name
	my $state = read_storage_file;
	foreach (@$state)
	{
		my ($ts, $timer, $code, $arg1, $arg2) = @$_;
		if ($code eq 'G')
		{
			my ($name, $type) = ($arg1, $arg2);
			if ($name ne "")
			{
				$current{$timer} = $name;  # maintain the last name
				$groups{$name} = {
					name  => $name,
					type  => $type,
				};
			}
			else
			{
				# This is a deleted group
				delete $current{$timer};  # maintain the last name
			}

		}
	}
	my @groups;
	if ($all)
	{
		# Get all groups
		@groups = values %groups;
	}
	else
	{
		# Get the groups referred to in %current
		my %currgroups;
		++$currgroups{$_} foreach values %current;
		@groups = @groups{keys %currgroups};
	}
	@groups = sort { lc $$a{name} cmp lc $$b{name} } @groups;
	return \@groups;
}

# Get all extra-info values in the specified timestamp range.
# $from_ts and $to_ts default to the current timestamp.
sub get_timer_extra
{
	my ($timer, $extra_info_name, $from_ts, $to_ts) = @_;

	unless (defined $from_ts && defined $to_ts)
	{
		my $ts = get_storage_timestamp;
		$from_ts = $ts unless defined $from_ts;
		$to_ts = $ts unless defined $to_ts;
	}

	# Collect all the changes in this window plus the one before.
	my @values = ( undef );  # already create the element for the one before
	foreach my $entry (@{$ExtraInfo{$timer}{$extra_info_name}{sorted}})
	{
		#info "ExtraInfo entry '$extra_info_name': '@$entry'\n";
		my ($ts, $val) = @$entry;
		if ($ts <= $from_ts)
		{
			# This entry is before the window, remember the last
			#info "->before ($ts<=$from_ts)\n";
			$values[0] = $val;
		}
		elsif ($ts <= $to_ts)
		{
			# This entry is inside the window
			#info "->between ($from_ts<$ts<=$to_ts)\n";
			push @values, $val;
		}
		else
		{
			# This entry is after the window
			#info "->after ($ts>$to_ts)\n";
			last;
		}
	}

	if (wantarray)
	{
		#info "Return get_timer_extra=" . join(", ", map "'$_'", @values) . "\n";
		return @values;  # return all
	}
	elsif (@values > 0)
	{
		#info "Return get_timer_extra='$values[-1]'\n";
		return $values[-1];  # return last
	}
	else
	{
		#info "Return get_timer_extra='undef'\n";
		return undef;  # none to return
	}
}

# Get the current running status of the specified timer.
sub get_timer_running
{
	my ($timer) = @_;

	return $Times_running{$timer};
}

# Return a list with indexes of all running timers.
sub get_all_timers_running
{
	my @timers = ();
	foreach (keys %Times_running)
	{
		next unless /^\d+$/;  # only numeric timers can be running
		push @timers, $_ if $Times_running{$_};
	}
	return @timers;
}

# Mark the specified state(s) of the specified timer as changed.
# Arguments:
# - $timers: The timer (or timers) to mark as changed
# - The rest of the arguments are states so set as changed (currently 'D',
#   'T' or 'G').
sub mark_changed_timer
{
	my $timers = shift;

	$timers = [ $timers ]  unless ref $timers;
	foreach my $timer (@$timers)
	{
		$ChangedTimers{$timer}{$_} = 1 foreach @_;
	}
}

# Create and return an array with changed timers. The entries consist of entries
# with the following format: [ id, state, ... ]
sub peek_changed_timers
{
	my @changes = ();
	foreach (sort { $a cmp $b } keys %ChangedTimers)
	{
		my @entry = ( $_ );
		push @entry, keys %{$ChangedTimers{$_}};

		push @changes, \@entry;
	}

	return @changes;
}

# Return an array with changed timers and reset the internal data structure.
sub get_changed_timers
{
	my @changes = peek_changed_timers;
	%ChangedTimers = ();
	return @changes;
}

# This function converts the specified state (or internal state if left
# unspecified) into a timeline. A timeline is a sorted array with entries with
# the following fields:
# - start [timestamp]
# - end [timestamp]
# - timer id (only the numeric timers)
# Also a second array with modifications is returned. This array consists of
# entries with any of the following formats:
# - [ 'i', <timestamp>, <amount-seconds>, <timer id> ]: increase/decrease time
#     of a timer.
# NB: The timeline array basically consists of the timer_run and timer_pause
# events. The modifications array consists of the increase_time and set_time
# events (the set_time is split into an implicit set_time(0) and an
# increase_time()).
# NB: The timeline entry's start and end times may be overlapping if multiple
# timers were running at the same time.
sub create_timeline
{
	sub create_timeline_event
	{
		my ($timer_status, $end, $timer) = @_;

		my $start = $$timer_status{$timer};
		if (!defined $start)
		{
			# This can happen if after a set_time when the
			# running_status is repeated.
			$start = $end;
		}
		elsif ($start <= 0)
		{
			die "Invalid start time: '$start' (timer=$timer)";
		}
		elsif ($end < $start)
		{
			die "Start time before end time (timer=$timer)";
		}
		delete $$timer_status{$timer};

		return [ $start, $end, $timer ];
	}

	my ($state) = @_;
	$state = read_storage_file unless defined $state;

	my @timeline, my @modifications;

	my %timer_status;  # timer -> running ts
	# Iterate through the state to collect the events
	my @events = sort {
		$$a[0] <=> $$b[0]  # sort by timestamp
		||
		$EventTraits{$$a[2]}{sort} <=> $EventTraits{$$b[2]}{sort}  # then by event type
		||
		$$a[1] <=> $$b[1]  # then by timer numeric (if necessary)
		||
		$$a[1] cmp $$b[1]  # then by timer other names (if necessary)
	} @$state;  # sort by timestamp
	foreach (@events)
	{
		my ($ts, $timer, $code, $arg1) = @$_;
		next unless $timer =~ /^\d+$/;  # only keep numeric timers
		if ($code eq 'T')
		{
			# Search back in @timeline and remove all events for this timer
			@timeline = grep $$_[2] != $timer, @timeline;
			# Search back in @modifications and remove all events for this timer
			@modifications = grep $$_[3] != $timer, @modifications;
			# If the timer is already running assume it started now
			if (defined $timer_status{$timer})
			{
				$timer_status{$timer} = $ts;
			}
		}
		elsif ($code eq 'D')
		{
			# Ignore description events in the timeline
		}
		elsif ($code eq 'G')
		{
			# Ignore group events in the timeline
		}
		elsif ($code eq 'E')
		{
			# Ignore extra-info events in the timeline
		}
		elsif ($code eq 'i')
		{
			# Add a 'transfer time' modification
			push @modifications, [ 'i', $ts, $arg1, $timer ]
				if $arg1 != 0;
		}
		elsif ($code eq 'r')
		{
			if (defined $timer_status{$timer})
			{
				# Timer already running, stop it first.
				# Stopping it first, as opposed to ignoring
				# the second start, preserves this timestamp
				# in the timeline. This method (adding an
				# implicit pause before a run) is analogous
				# to adding an implicit run before a line
				# pause, creating a 0-length event.
				push @timeline, create_timeline_event \%timer_status, $ts, $timer;
			}
			$timer_status{$timer} = $ts;
		}
		elsif ($code eq 'p')
		{
			push @timeline, create_timeline_event \%timer_status, $ts, $timer;
		}
		else
		{
			die "Unknown event code: '$code'";
		}
	}
	# Register an end time of now for all running timers
	my $now = get_storage_timestamp;
	foreach my $timer (keys %timer_status)
	{
		push @timeline, create_timeline_event \%timer_status, $now, $timer;
	}
	# Be sure that these manipulations leave a sorted timeline
	@timeline = sort {
		$$a[0] <=> $$b[0]  # sort by start timestamp
		||
		$$a[1] <=> $$b[1]  # then by end timestamp
		||
		$$a[2] <=> $$b[2];  # then by timer numeric (to make order unique)
	} @timeline;
	#use Data::Dumper; info Dumper \@timeline, \@modifications;

	return (\@timeline, \@modifications);
}


1;


