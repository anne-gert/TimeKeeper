package TimeKeeper::Config;

# This module contains functions to read and write the different configuration
# files for TimeKeeper:
# - config: Contains read-only configuration items, like number of timers,
#     editor to use and location of other data files.
# - status: Contains transient status, like window size and location.

use strict;
use Carp;

use File::Spec::Functions qw//;  # use rel2abs, but override it
sub rel2abs;
use TimeKeeper::Utils;

BEGIN
{
	use Exporter ();
	our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

	# set the version for version checking
	$VERSION     = 1.00;

	@ISA         = qw(Exporter);
	@EXPORT      = (
		# File paths
		qw(
		set_config_path set_config_file
		),
		# Derived file paths
		qw(
		get_config_file read_config_file write_config_file
		get_status_file read_status_file write_status_file update_status_file
		get_logdef_file get_logdef_file_default
		get_data_file get_data_backup_file
		get_groups_file get_groups_file_default
		),
		# Specified in config file (user-defined configuration)
		qw(
		get_num_timers
		get_cmd_edit
		get_pause_on_suspend get_pause_on_exit
		get_activate_on_startup
		get_debug_info_file get_keep_debug_info_period
		get_keep_event_history_days
		get_title_replace_common_prefix
		get_default_font
		get_exttool_entries
		),
		# Specified in status file (transient, persistent data)
		qw(
		get_position set_position get_geometry set_geometry geometry_pos
		get_scroll_pos set_scroll_pos
		get_keep_running_status set_keep_running_status
		get_generate_log_targets set_generate_log_targets
		),
	);
	@EXPORT_OK   = qw();
	%EXPORT_TAGS = ();  # eg: TAG => [ qw!name1 name2! ],
}


##############################################################################
### Configuration variables

# Filename of the configuration file with user-defined settings.
# This filename can be an absolute path or relative to this config file.
our $ConfigFileName = 'config';

# The configuration variables.
# See config_default for a description and the defaults.

our $NumTimers;
our $CmdEdit;
our $StatusFileName;
our $LogDefFileName;
our $DataFileName;
our $BackupDataFileName;
our $GroupsFileName;
our $PauseOnSuspend;
our $PauseOnExit;
our $ActivateOnStartup;
our $DebugInfoFileName;
our $KeepDebugInfoPeriod;
our $KeepEventHistoryDays;
our $TitleReplaceCommonPrefix;
our $DefaultFont;
our $ExtTools;


##############################################################################
### Status variables

# See write_status_file() for an explanation of these variables.

# Position of the MainWindow on screen.
our $MainWinLeft = undef;
our $MainWinTop = undef;
our $MainWinWidth = 250;
our $MainWinHeight = 200;
our $MainWinScrollPosition = 0;

# If $KeepRunningStatus==true, keep the previous running status as if
# $ActivateOnStartup==undef. This setting is thus an override for
# $ActivateOnStartup with the difference that $ActivateOnStartup is a user-
# setting in the config file and $KeepRunningStatus is a transient setting in
# the status file. It is used in a shutdown-startup sequence where there should
# be no additional data events generated.
our $KeepRunningStatus = undef;

our @GenerateLogTargets = qw/editor clipboard/;


##############################################################################
### Internal variables

our $ConfigPath;

my $Status_changed = 0;


##############################################################################
### Read/write functions

# The standard rel2abs() accepts an undef name as an empty string. Here, I
# want an undef name to result in an undef path.
sub rel2abs
{
	my ($name, $base) = @_;
	
	return undef unless defined $name;
	return File::Spec::Functions::rel2abs @_;  # the original
}

sub set_config_path
{
	$ConfigPath = shift;
}

sub set_config_file
{
	$ConfigFileName = shift;
}

sub get_config_file
{
	return rel2abs $ConfigFileName, $ConfigPath;
}

sub get_config_file_default
{
	return get_startup_path "TimeKeeper", "config_default";
}

sub read_config_file
{
	# First read the default file for new settings
	my $default_fname = get_config_file_default;
	# Read the default config as a perl fragment
	my $result = do $default_fname;
	if (!defined($result) && ($! || $@))
	{
		die "Cannot read config file '$default_fname': $!$@";
	}

	# Process the specified settings in the config file
	my $fname = get_config_file;
	if (-e $fname)
	{
		# Config file exists, read it as a perl fragment
		my $result = do $fname;
		if (!defined($result) && ($! || $@))
		{
			die "Cannot read config file '$fname': $!$@";
		}
	}
	else
	{
		# Config does not exist, copy default config file
		copy_file $default_fname, $fname;
	}
}

sub write_config_file
{
	copy_file get_config_file_default, get_config_file;
}

sub get_status_file
{
	return rel2abs $StatusFileName, $ConfigPath;
}

sub read_status_file
{
	my $fname = get_status_file;
	if (-e $fname)
	{
		# Read the storage as a perl fragment
		my $result = do $fname;
		if (!defined($result) && ($! || $@))
		{
			die "Cannot read status file '$fname': $!$@";
		}
	}
	# else use defaults
}

sub write_status_file
{
	my $fname = get_status_file;
	mkfiledir $fname unless -e $fname;
	open FILE, "> $fname" or die "Cannot open '$fname': $!";
	# Render the data as perl code to the file
	my $out_MainWinLeft = get_perl_value $MainWinLeft;
	my $out_MainWinTop = get_perl_value $MainWinTop;
	my $out_MainWinWidth = get_perl_value $MainWinWidth;
	my $out_MainWinHeight = get_perl_value $MainWinHeight;
	my $out_MainWinScrollPosition = get_perl_value $MainWinScrollPosition;
	my $out_KeepRunningStatus = get_perl_value $KeepRunningStatus;
	my $out_GenerateLogTargets =
		"( " .
		join(", ",
			map(get_perl_value($_),
				@GenerateLogTargets
			)
		) .
		" )";

	print FILE <<"FILE";
# vim: ft=perl

\$MainWinLeft = $out_MainWinLeft;
\$MainWinTop = $out_MainWinTop;
\$MainWinWidth = $out_MainWinWidth;
\$MainWinHeight = $out_MainWinHeight;
\$MainWinScrollPosition = $out_MainWinScrollPosition;
\$KeepRunningStatus = $out_KeepRunningStatus;
\@GenerateLogTargets = $out_GenerateLogTargets;

FILE
	close FILE;
}

sub update_status_file
{
	if ($Status_changed)
	{
		write_status_file;
		$Status_changed = 0;
	}
}

sub get_logdef_file
{
	return rel2abs $LogDefFileName, $ConfigPath;
}

sub get_logdef_file_default
{
	return get_startup_path "TimeKeeper", "logdef_default";
}

sub get_data_file
{
	return rel2abs $DataFileName, $ConfigPath;
}

sub get_data_backup_file
{
	return rel2abs $BackupDataFileName, $ConfigPath;
}

sub get_groups_file
{
	return rel2abs $GroupsFileName, $ConfigPath;
}

sub get_groups_file_default
{
	return get_startup_path "TimeKeeper", "groups_default";
}


##############################################################################
### Access functions

sub get_num_timers
{
	return $NumTimers;
}

sub get_position
{
	return ($MainWinLeft, $MainWinTop, $MainWinWidth, $MainWinHeight);
}

sub set_position
{
	($MainWinLeft, $MainWinTop, $MainWinWidth, $MainWinHeight) = @_;
	$Status_changed = 1;
}

# Convert geometry to (x, y, w, h) position.
sub geometry_pos
{
	my ($geometry) = @_;

	my @pos = ();
	# Accept the "+ x + y" part
	# (negative is +-x+-y, -x-y would be from left-bottom side)
	if ($geometry =~ /\+([+-]*\d+)\+([+-]*\d+)/)
	{
		@pos[0, 1] = (eval("$1+0"), eval("$2+0"));  # convert to numeric
	}
	# Accept the "w x h" part
	if ($geometry =~ /(\d+)x(\d+)/)
	{
		@pos[2, 3] = ($1, $2);
	}
	#print "Convert geometry to pos: '$geometry' = (@pos)\n";

	return @pos;
}

# Get the extent of the MainWin in geometry (leftxtop+x+y) format.
# The adjust inputs are added to the stored values. This can be used to move
# the window a specific amount.
sub get_geometry
{
	my ($adjustLeft, $adjustTop, $adjustWidth, $adjustHeight) = @_;

	my $geometry = "";
	if (defined($MainWinWidth) && defined($MainWinHeight))
	{
		my $w = $MainWinWidth + $adjustWidth;
		my $h = $MainWinHeight + $adjustHeight;
		$geometry .= "${w}x$h";
	}
	if (defined($MainWinLeft) && defined($MainWinLeft))
	{
		my $l = $MainWinLeft + $adjustLeft;
		my $t = $MainWinTop + $adjustTop;
		$geometry .= "+$l+$t";
	}
	return $geometry;
}

# Store the specified geometry as position and size of the window.
sub set_geometry
{
	my ($geometry) = @_;

	set_position geometry_pos $geometry;
}

sub get_scroll_pos
{
	return $MainWinScrollPosition;
}

sub set_scroll_pos
{
	$MainWinScrollPosition = shift;
	$Status_changed = 1;
}

sub get_keep_running_status
{
	return $KeepRunningStatus;
}

sub set_keep_running_status
{
	$KeepRunningStatus = shift;
}

sub get_cmd_edit
{
	my ($fname) = @_;

	my $cmd;
	if ($CmdEdit)
	{
		$cmd = $CmdEdit;
	}
	elsif ($ENV{EDITOR})
	{
		$cmd = $ENV{EDITOR} . ' "%s"';
	}
	elsif ($^O =~ /MSWin/i)
	{
		$cmd = 'notepad "%s"';
	}
	else
	{
		$cmd = 'gvim "%s"';
	}
	return sprintf $cmd, $fname;
}

sub get_pause_on_suspend
{
	return $PauseOnSuspend;
}

sub get_pause_on_exit
{
	return $PauseOnExit;
}

sub get_activate_on_startup
{
	return $ActivateOnStartup;
}

# Return array with current generate log targets.
sub get_generate_log_targets
{
	#info "GET \@GenerateLogTargets=(@GenerateLogTargets)\n";
	return @GenerateLogTargets;
}

# Set the current generate log targsts.
sub set_generate_log_targets
{
	@GenerateLogTargets = sort @_;  # sort for maintaining fixed order
	#info "SET \@GenerateLogTargets=(@GenerateLogTargets)\n";
}

# Get path to write debug info messages to.
sub get_debug_info_file
{
	return $DebugInfoFileName;
}

# Get the period (in seconds) to keep old debug info entries in the log-file.
sub get_keep_debug_info_period
{
	return $KeepDebugInfoPeriod;
}

# Returns the number of days that reset events should be kept in the Storage
# file.
# If this value is 0, events should be removed immediately after reset.
sub get_keep_event_history_days
{
	return $KeepEventHistoryDays;
}

# Returns string to use instead of common prefix. Undef if no common prefix
# replacement should be done.
sub get_title_replace_common_prefix
{
	return $TitleReplaceCommonPrefix;
}

# Returns the font name and size of the font to specify as default for the
# MainWindow.
sub get_default_font
{
	return $DefaultFont;
}

# Returns an array with tool-entry items. Each tool-entry item consists of the
# following elements:
# - DisplayText
# - Command
sub get_exttool_entries
{
	my @exttools = ();
	foreach my $line (split /\r?\n\r?/, $ExtTools)
	{
		$line =~ s/^\s+//;  # ignore leading whitespace
		$line =~ s/\s+$//;  # ignore trailing whitespace
		next if $line =~ /^#/;  # skip comment line
		next unless $line =~ /
			^                        # match for entire line
			(.+?)                    # DisplayText (non-empty
			(?:
				\s*              # whitespace around '::' allowed
				(?<!:)::(?!:)    # exactly 2 colons
				\s*              # whitespace allowed
				(.*)             # Command
			)?                       # Command is optional
			$                        # match for entire line
			/x, $line;

		# A valid line, add the fields
		push @exttools, [ $1, $2 ];
	}
	return @exttools;
}


1;


