package TimeKeeper::Tui;

# This module implements a TUI (Textual User Interface), based on simple IO on
# top of the TimeKeeper Core module. It makes the core's functionalily
# available through a text interface.

use strict;
use Carp;

use IO::Handle;
use IO::Select;

use TimeKeeper::Core;
use TimeKeeper::Storage;
use TimeKeeper::Config;
use TimeKeeper::Utils;

BEGIN
{
	use Exporter ();
	our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

	# set the version for version checking
	$VERSION     = 1.00;

	@ISA         = qw(Exporter);
	@EXPORT      = qw(
		Init Run Done
	);
	@EXPORT_OK   = qw();
	%EXPORT_TAGS = ();  # eg: TAG => [ qw!name1 name2! ],
}


##############################################################################
### Global variables

# other global variables
our $CommandModeTimer = 0;

# constants


##############################################################################
### Event handlers that are triggered by the controls

sub EvtRun
{
	my ($args) = @_;

	if ($args =~ /^\s*$/)
	{
		# Arguments: none
		start;
	}
	elsif ($args =~ /^\s*(\d+)\s*$/)
	{
		# Arguments: timer_id
		activate $1;
	}
	else
	{
		print "Argument error\n";
	}
}

sub EvtPause
{
	my ($args) = @_;

	if ($args =~ /^\s*$/)
	{
		# Arguments: none
		stop;
	}
	else
	{
		print "Argument error\n";
	}
}

sub EvtList
{
	my ($args) = @_;

	if ($args =~ /^\s*$/)
	{
		# Arguments: none
		print "All timers\n";
		foreach my $timer (1..get_num_timers, 0)
		{
			my $description = get_timer_current_description $timer;
			my $time = format_time get_timer_current_time $timer;
			my $suffix = "";
			if (get_active == $timer)
			{
				if (get_timer_running $timer)
				{
					$suffix = " (running)";
				}
				else
				{
					$suffix = " (active)";
				}
			}
			if ($description || $time)
			{
				print "($timer) $description: $time$suffix\n";
			}
		}
		print "-----------\n";
	}
	else
	{
		print "Argument error\n";
	}
}

sub EvtIncTime
{
	my ($args) = @_;

	if ($args =~ /^\s*(\d+)\s*(.+?)\s*$/)
	{
		# Arguments: timer_id, time_expression
		add_timer $1, $2;
	}
	elsif ($args =~ /^\s*(.+?)\s*$/)
	{
		# Arguments: time_expression
		add_timer get_active(), $2;
	}
	else
	{
		print "Argument error\n";
	}
}

sub EvtDecTime
{
	my ($args) = @_;

	if ($args =~ /^\s*(\d+)\s*(.+?)\s*$/)
	{
		# Arguments: timer_id, time_expression
		add_timer $1, "-($2)";
	}
	elsif ($args =~ /^\s*(.+?)\s*$/)
	{
		# Arguments: time_expression
		add_timer get_active(), "-($2)";
	}
	else
	{
		print "Argument error\n";
	}
}

sub EvtSetTime
{
	my ($args) = @_;

	if ($args =~ /^\s*(\d+)\s*(.+?)\s*$/)
	{
		# Arguments: timer_id, time_expression
		set_timer $1, $2;
	}
	elsif ($args =~ /^\s*(.+?)\s*$/)
	{
		# Arguments: time_expression
		set_timer get_active(), $2;
	}
	else
	{
		print "Argument error\n";
	}
}

sub EvtTransferTime
{
	my ($args) = @_;

	if ($args =~ /^\s*(\d+)\s*(\d+)\s*(.+?)\s*$/)
	{
		# Arguments: from_timer_id, to_timer_id, time_expression
		transfer_time $1, $2, $3;
	}
	else
	{
		print "Argument error\n";
	}
}

sub EvtResetTimer
{
	my ($args) = @_;

	if ($args =~ /^\s*all\s*$/i)
	{
		# Arguments: 'all'
		set_timer $_, 0 foreach 0..get_num_timers;
	}
	elsif ($args =~ /^\s*(\d+)\s*$/)
	{
		# Arguments: timer_id
		set_timer $1, 0;
	}
	elsif ($args =~ /^\s*$/)
	{
		# Arguments: none
		set_timer get_active(), 0;
	}
	else
	{
		print "Argument error\n";
	}
}

sub EvtEditLog
{
	my ($args) = @_;

	if ($args =~ /^\s*$/)
	{
		# Arguments: none
		edit_logdef;
	}
	else
	{
		print "Argument error\n";
	}
}

sub EvtGenerateLog
{
	my ($args) = @_;

	my @target = "editor";
	if ($args =~ /^\s*$/)
	{
		# Arguments: none
		make_log "default", @target;
	}
	elsif ($args =~ /^\s*(\S*)\s*$/)
	{
		# Arguments: AltLogId
		make_log $1, @target;
	}
	else
	{
		print "Argument error\n";
	}
}

sub EvtEditConfig
{
	my ($args) = @_;

	if ($args =~ /^\s*$/)
	{
		# Arguments: none
		edit_config;
	}
	else
	{
		print "Argument error\n";
	}
}

sub EvtDescription
{
	my ($args) = @_;

	if ($args =~ /^\s*(\d+)\s*(.*?)\s*$/)
	{
		# Arguments: timer_id, description
		set_timer_description $1, $2;
	}
	elsif ($args =~ /^\s*(.*?)\s*$/)
	{
		# Arguments: description
		set_timer_description get_active(), $2;
	}
	else
	{
		print "Argument error\n";
	}
}

sub EvtPrintHelp
{
	# Ignore arguments
	print <<"HELP";
Press <Enter> for command input.
TimeKeeper Commands
  run [timer] : Start running specified or active timer.
  pause       : Pause the active timer.
  list        : List all timers.
  +|-|= [timer] <time> : Increase/Decrease/Set time to specified or active
                timer.
  transfer <from> <to> <time>: Transfer time from <from> to <to>.
  zero [timer]: Reset the specified or active timer.
  zero all    : Reset all timers.
  editlog     : Edit the log-definition in an editor.
  genlog [log-id] : Generate the log from the log-definition. Log-id defaults
                to "default".
  editconfig  : Edit the configuration file in an editor.
  description [timer] <description> : Set the specified or active timer's
                description.
  help, ?     : Display this help message.
  quit, exit  : Quit application.

Recognized time notation examples: 2:45, 2h, 45m, 100s, -2*3h
HELP
}

my @Commands = (
	[ "run",         \&EvtRun ],
	[ "pause",       \&EvtPause ],
	[ "list",        \&EvtList ],
	[ "+",           \&EvtIncTime ],
	[ "-",           \&EvtDecTime ],
	[ "=",           \&EvtSetTime ],
	[ "transfer",    \&EvtTransferTime ],
	[ "zero",        \&EvtResetTimer ],
	[ "editlog",     \&EvtEditLog ],
	[ "genlog",      \&EvtGenerateLog ],
	[ "editconfig",  \&EvtEditConfig ],
	[ "description", \&EvtDescription ],
	[ "help",        \&EvtPrintHelp ],
	[ "?",           \&EvtPrintHelp ],
	[ "quit",        "quit" ],
	[ "exit",        "quit" ],
);


##############################################################################
### Callbacks that are called to change controls

sub CbUpdateWallTime
{
	my ($time) = @_;

	# If in commandmode, decrease the timer
	if ($CommandModeTimer > 0)
	{
		--$CommandModeTimer;
		#print "\rCommandModeTimer=$CommandModeTimer     ";
	}
}


##############################################################################
### Package interface

sub Init
{
	initialize @_;

	print <<"TEXT";
TimeKeeper
Press <Enter> for command input.
TEXT
}

sub Run
{
	# Set the callbacks
	set_cb_update_wall_time \&CbUpdateWallTime;

	initialize_ui;
	my $inp_sel = IO::Select->new(\*STDIN);

	# Start the message loop
	local $| = 1;  # print character-based, not line-based
	my $timerline;
	while (1)
	{
		# Has a command been typed?
		my $cmd = undef;
		if ($inp_sel->can_read(0.1))
		{
			chomp($cmd = <STDIN>);
		}

		# Check input
		if ($cmd)
		{
			($cmd, my $args) = $cmd =~ /(\S+)\s*(.*)/;
			$cmd = lc $cmd;  # for case-insensitive compare
			#info "COMMAND: '$cmd'\n";
			my $func;
			foreach (@Commands)
			{
				if ($cmd eq "")
				{
					$func = "empty";
				}
				elsif (index($$_[0], $cmd) == 0)
				{
					# Found a matching command
					if ($func)
					{
						# Already found a function
						$func = "ambiguous";
						last;
					}
					else
					{
						# A matching command
						$func = $$_[1];
					}
				}
			}
			if ($func eq "empty")
			{
				print "Command (h for help): ";
				# Stay in commandmode for some time
				$CommandModeTimer = 30;
			}
			elsif ($func eq "ambiguous")
			{
				print "Command '$cmd' is ambiguous\n";
			}
			elsif ($func eq "quit")
			{
				last;  # exit this loop
			}
			elsif ($func)
			{
				&$func($args);
				$CommandModeTimer = 0;  # out of commandmode
			}
			else
			{
				print "Command '$cmd' is unknown\n";
			}
		}

		# Update state and handle callbacks
		time_tick;

		if ($CommandModeTimer == 0)
		{
			# Print the active timer
			my $timer = get_active;
			my $description = get_timer_current_description $timer;
			my $time = format_time get_timer_current_time $timer;
			my $new_timerline = "($timer) $description: $time";
			if ($timerline ne $new_timerline)
			{
				print "\r$new_timerline";
				my $size_dec = length($timerline) - length($new_timerline);
				if ($size_dec > 0)
				{
					# This line is smaller, add padding
					print " " x $size_dec;
				}
				$timerline = $new_timerline;
			}
		}
	}

	return 0;
}

sub Done
{
	finalize;
}


1;


