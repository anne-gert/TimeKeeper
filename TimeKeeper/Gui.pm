package TimeKeeper::Gui;

# This module implements a GUI on top of the TimeKeeper Core module. It makes
# the core's functionalily available through a GUI.
# Plugins are used to do the actual GUI work.

use strict;
use Carp;

use File::Basename;

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
	my @plugin_if = (  # expose functions for the plugin to use
		# Event handlers
		qw(EvtStartStop EvtActivate EvtEditTimer EvtEditDescription
		EvtResetTimer EvtSetTimerGroup
		EvtDefineLog EvtSetGenerateTarget EvtGenerateLog
		EvtEditConfig EvtEditEvents EvtEditGroups
		EvtRedrawWallTime
		EvtCycleClockFormat),
		# Other functions from this module
		qw(TimerEditCancel TimerEditOk),
		# Functions from other modules
		# TimeKeeper::Core
		qw(is_generate_log_target get_alt_logs
		get_active
		get_timer_group_infos get_timer_group_info),
		# TimeKeeper::Storage
		qw(get_timer_current_description get_timer_current_time
		get_timer_current_group_name),
		# TimeKeeper::Config
		qw(set_keep_running_status get_keep_running_status
		get_geometry set_geometry set_position geometry_pos
		get_position set_position
		set_scroll_pos
		get_num_timers
		get_exttool_entries),
		# TimeKeeper::Utils
		qw(format_time dos2unix info),
	);
	@EXPORT_OK   = ( @plugin_if );
	%EXPORT_TAGS = (
		plugin => \@plugin_if,
	);  # eg: TAG => [ qw!name1 name2! ],
}


##############################################################################
### Globals

# Global variables
our $TimerEdit = -1;  # if >=0, timer-number of timer being edited
our $TimerEditMode;  # only valid if $TimerEdit is valid
our $TimerEditUpdate;  # if true, the timer under edit may be updated
our $InitReady = 0;

# Walltime clock formats
our @ClockFormats = ( "Normal", "Timestamp", "Days+Seconds since year 1970",
	"Days+Seconds since year 1", "GMT", "Stardate" );

# The current plugin to use for the low-level GUI actions
my $GuiPlugin;


##############################################################################
### GUI control functions (hide specific GUI implementation)

{
package TimeKeeper::Gui::PluginBase;

use strict;
use Carp;

use TimeKeeper::Gui qw/:plugin/;


##############################################################################
### Constructors and factory methods

# To find compilation errors in plugins, enable line(s) below
#use TimeKeeper::Gui::PluginTk;
#use TimeKeeper::Gui::PluginTkx;

# Create an appropriate plugin and initialize it.
sub create
{
	my @plugins = qw/PluginTkx PluginTk/;
	#my @plugins = qw/PluginTk/;
	foreach (@plugins)
	{
		my $type = "TimeKeeper::Gui::$_";
		my $code = "require $type; return ${type}->new";
		#print "Execute '$code'\n";
		my $plugin = eval $code;
		# if $plugin is defined, it is the result of a successful
		# require and instantiation of this plugin.
		return $plugin if $plugin;
	}
	# If we get here, none of the previous types resulted in a proper
	# return. Print a message and exit.
	print <<"TEXT";
Could not find working GUI plugin: @plugins.

Module Tkx can be installed with one of the following commmands:
- ActiveState Perl: ppm install Tkx
- Ubuntu: apt install tcl libtcl-perl tk tklib bwidget
          perl -MCPAN -e "install Tcl, Tcl::Tk, Tkx"
- CentOS: yum install tcl tk tklib bwidget
          perl -MCPAN -e "install Tcl, Tcl::Tk, Tkx"

Module Tk can be installed with one of the following commmands:
- ActiveState Perl: Not available
- Ubuntu: apt install perl-tk
- CentOS: yum install perl-Tk
TEXT
	print "\nPress any key...";
	scalar <STDIN>;
	print "\n";
	exit 1;
}

# Construct
sub new
{
	my $class = shift;

	my $self = bless {
		# references to widgets
		MainWin => undef,  # reference to main window
		TopPanel => undef,  # reference to upper frame
		MiddlePanel => undef,  # reference to middle, scrollable frame
		BottomPanel => undef,  # reference to bottom frame
		CopyRightLabel => undef,  # reference to label that is also start/stop
		LblClock => undef,  # reference to label that shows wall-time
		Timers => [],  # array with hashes with timer widgets

		ClockFormats => [],  # posible wall-time formats
		ClockFormatRef => \(my $format = 0),  # ref to format of wall-time

		# constants
		ColorReadOnly => undef,
		ColorEditable => undef,
		ColorActive => "#FFCCCC",
		ColorTitle => "#4085F5",  # this color is for windows
		DefaultInsertOnTime => undef,
		AddCancelMenuItem => 0,  # if true, a special menu item to cancel is added

		# other variables
		DescrCurFirstX => undef,  # insertion cursor x-coor in description
		DescrCurLastIndex => undef,  # insertion cursor index in description
	}, $class;
	return $self;
}


##############################################################################
### Settings get/set functions

# Set the possible wall-time formats (strings).
sub SetWallTimeFormats
{
	my $self = shift;

	$self->{ClockFormats} = [ @_ ];
}

# Get the current wall-time format (0..max-1)
sub GetWallTimeFormat
{
	my $self = shift;

	return ${$self->{ClockFormatRef}};
}

# Set the current wall-time format (0..max-1)
sub SetWallTimeFormat
{
	my $self = shift;
	my ($clockFormat) = @_;

	${$self->{ClockFormatRef}} = $clockFormat;
}


##############################################################################
### GUI draw and query functions

# Set this timer visually/behaviourally in edit-mode.
# If $preset is defined, display that value, otherwise keep the current value.
sub SetTimerEditMode
{
	my $self = shift;
	my ($timer, $preset) = @_;

	confess "Abstract method called";
}

# Set this timer visually/behaviourally in normal-mode.
sub SetTimerNormalMode
{
	my $self = shift;
	my ($timer, $is_active) = @_;

	confess "Abstract method called";
}

# Draw specified timer in an active state.
sub DrawTimerActive
{
	my $self = shift;
	my ($timer, $is_edit) = @_;

	confess "Abstract method called";
}

# Draw specified timer in an inactive state.
sub DrawTimerInactive
{
	my $self = shift;
	my ($timer, $is_edit) = @_;

	confess "Abstract method called";
}

# Draw application in a running state.
sub DrawRunning
{
	my $self = shift;

	confess "Abstract method called";
}

# Draw application in a stopped state.
sub DrawStopped
{
	my $self = shift;

	confess "Abstract method called";
}

# Set the title of the toplevel main window.
sub SetWindowTitle
{
	my $self = shift;
	my ($title) = @_;

	confess "Abstract method called";
}

# Set the description of the specified timer.
sub SetTimerDescription
{
	my $self = shift;
	my ($timer, $description) = @_;

	confess "Abstract method called";
}

# Set the group of the specified timer.
sub SetTimerGroup
{
	my $self = shift;
	my ($timer, $groupname, $groupcolor) = @_;

	confess "Abstract method called";
}

# Set the time displayed in the specified timer.
sub SetTimerTime
{
	my $self = shift;
	my ($timer, $time) = @_;

	confess "Abstract method called";
}

# Get the time displayed in the specified timer.
sub GetTimerTime
{
	my $self = shift;
	my ($timer) = @_;

	confess "Abstract method called";
}

# Set the specified time (string) as wall-time on the clock.
sub SetWallTime
{
	my $self = shift;
	my ($time) = @_;

	confess "Abstract method called";
}

# Returns the next ($delta places) timerId.
# If $wrap==true (default), the id wraps around the bottom and top.
sub GetNextTimerId
{
	my $self = shift;
	my ($timer_id, $delta, $wrap) = @_;
	$delta = 1 unless defined $delta;
	$wrap = 1 unless defined $wrap;

	$timer_id += $delta;
	my ($min_id, $max_id) = (0, get_num_timers);
	if ($wrap)
	{
		# Wrap around
		$timer_id = $min_id if $timer_id > $max_id;
		$timer_id = $max_id if $timer_id < $min_id;
	}
	else
	{
		# Clip
		$timer_id = $max_id if $timer_id > $max_id;
		$timer_id = $min_id if $timer_id < $min_id;
	}
	return $timer_id;
}

# The functions to do focus the next timer description

# Get the x-coordinate for the specified index in the specified Entry control.
sub entry_get_x
{
	my $self = shift;
	my ($entry, $index) = @_;

	confess "Abstract method called";
}

# Get the numeric index for the specified x-coordinate in the specified Entry
# control.
sub entry_get_index
{
	my $self = shift;
	my ($entry, $x) = @_;

	confess "Abstract method called";
}

# Get the current index for the specified Entry control.
sub entry_get_current_index
{
	my $self = shift;
	my ($entry) = @_;

	confess "Abstract method called";
}

# Focus the specified Entry control and set the insertion cursor if specified.
sub entry_focus
{
	my $self = shift;
	my ($entry, $icursor) = @_;

	confess "Abstract method called";
}

# Deletes the contents in the selection range.
sub entry_delete_selection
{
	my $self = shift;
	my ($entry) = @_;

	confess "Abstract method called";
}

# Clear the selection tag
sub entry_clear_selection
{
	my $self = shift;
	my ($entry) = @_;

	confess "Abstract method called";
}

# Switch from one Entry control to the other, maintaining the position of the
# insertion cursor as is expected in a Text control.
sub FocusNextDescription
{
	my $self = shift;
	my ($timer_id, $delta, $wrap) = @_;

	my $next_timer_id = $self->GetNextTimerId($timer_id, $delta, $wrap);
	return if $timer_id == $next_timer_id;  # nothing to do

	# Get the edit controls for the descriptions
	my $from = $self->{Timers}[$timer_id]{descrctrl};
	my $to = $self->{Timers}[$next_timer_id]{descrctrl};

	# Retrieve current cursor position
	my $index = $self->entry_get_current_index($from);
	my $x = $self->entry_get_x($from, $index);
	# Determine the x-coordinate to use
	my $last_index = $self->{DescrCurLastIndex};
	my $first_x;
	if (defined $last_index && $last_index == $index)
	{
		# We haven't moved, assume it's the same sequence
		$first_x = $self->{DescrCurFirstX};
	}
	else
	{
		# We moved, start new sequence from here
		$first_x = $self->{DescrCurFirstX} = $x;
	}
	# Calculate in which character in the new control this x is
	$index = $self->entry_get_index($to, $first_x);  # index on left side of this x
	my ($l, $r) = $self->entry_get_x($to, $index);
	my $d_left = $first_x - $l;
	my $d_right = $r - $first_x;
	if ($d_right >= 0 && $d_right < $d_left)
	{
		# Right side is actually closer, use that instead
		++$index;
	}
	$last_index = $self->{DescrCurLastIndex} = $index;
	# If there was a previous selection, remove that first (to prevent
	# accidental deletion when editing)
	$self->entry_clear_selection($to);
	# Focus the new one and set cursor position
	$self->entry_focus($to, $index);
}


##############################################################################
### Miscellaneous GUI-stuff

# Run the GUI's main loop
sub Run
{
	my $self = shift;

	confess "Abstract method called";
}

# Set a function to be repetitively (every $time milliseconds) called.
sub SetRepeatTimer
{
	my $self = shift;
	my ($time, $func) = @_;

	confess "Abstract method called";
}

# Set data on the clipboard
sub SetClipboard
{
	my $self = shift;
	my ($data) = @_;

	confess "Abstract method called";
}

# Add the specified option with the specified value.
sub AddOption
{
	my $self = shift;
	my ($option, $value) = @_;

	confess "Abstract method called";
}

# Return an array with (foreground color, background color) to use for a
# timer group for a certain $groupcolor. This groupcolor can be:
# - #rrggbb: Take this a background and find a suitable foreground.
# - empty: Use the standard window background and foreground color.
# - undef: Use the standard window background, but use a distinctive
#     foreground color if a timer group is specified.
# Returns fore- and background color as #rrggbb.
sub GetTimerGroupColoring
{
	my $self = shift;
	my ($groupname, $groupcolor) = @_;

	my ($fg, $bg);
	if ($groupcolor)
	{
		# A color is defined, use that as background
		$bg = $groupcolor;
		$fg = $self->GetTextColorForBackground($bg);
	}
	elsif ($groupname)
	{
		# There is no background color given.
		# Use default background
		$bg = $self->{ColorWindowBackground};
		if (defined $groupcolor)
		{
			# The background color is defined, so explicitly
			# empty. Use the normal foreground color.
			$fg = $self->GetTextColorForBackground($bg);
		}
		else
		{
			# The background color is undefined, use a
			# signal color to indicate that this group is
			# not defined in the TimerGroups file.
			$fg = "darkorange3";
		}
	}
	else
	{
		# No color and no group, use default colors.
		$bg = $self->{ColorWindowBackground};
		$fg = $self->GetTextColorForBackground($bg);
	}

	return ($fg, $bg);
}

# Determine the text color to use on the specified background color to be
# readable.
# The input and output colors are colors acceptable by the underlying plugin.
# This may include HTML style "#rrggbb" or constant names like "blue" and
# "white".
sub GetTextColorForBackground
{
	my $self = shift;
	my ($bgcolor) = @_;

	# I did some testing and for the primary colors, I found that the
	# following values are the minimal values where black textcolor should
	# be used:
	# - Red: #D00000 -> 208, 0, 0 -> 0.816, 0, 0
	# - Green: #006000 -> 0, 96, 0 -> 0, 0.376, 0
	# - Blue: #3030FF -> 48, 48, 255 -> 0.188, 0.188, 1
	#
	# Some extra information is on http://stackoverflow.com/questions/596216/formula-to-determine-brightness-of-rgb-color,
	# where it is stated that there are 3 formulas:
	# A. Luminance (standard for certain colour spaces): (0.2126*R + 0.7152*G + 0.0722*B)
	# B. Luminance (perceived option 1): (0.299*R + 0.587*G + 0.114*B)
	# C. Luminance (perceived option 2, slower to calculate): sqrt( 0.299*R^2 + 0.587*G^2 + 0.114*B^2 )
	# Others state one should just take the maximum.
	#
	# Now calculate the values of each of the 3 colors above in the
	# different formulas:
	# - Formula A:
	#   0.816*0.2126 +     0*0.7152 + 0*0.0722 = 0.173
	#       0*0.2126 + 0.376*0.7152 + 0*0.0722 = 0.269
	#   0.188*0.2126 + 0.188*0.7152 + 1*0.0722 = 0.247
	# - Formula B:
	#   0.816*0.299 +     0*0.587 + 0*0.114 = 0.244
	#       0*0.299 + 0.376*0.587 + 0*0.114 = 0.221
	#   0.188*0.299 + 0.188*0.587 + 1*0.114 = 0.281
	# - Formula C:
	#   sqrt(0.816^2*0.299 +     0^2*0.587 + 0^2*0.114) = 0.446
	#   sqrt(    0^2*0.299 + 0.376^2*0.587 + 0^2*0.114) = 0.288
	#   sqrt(0.188^2*0.299 + 0.188^2*0.587 + 1^2*0.114) = 0.381
	#
	# From the numbers above, it looks like formula B has the values
	# closest together.
	# However when visually checked, relatively dark greys still have
	# an intensity that warrants a black foreground color. This means
	# that Formula B is not so good at combining the color channels.
	#
	# Formula C corrects better for this situation. I use an intensity
	# cut-off of 0.5, which looks best visually.

	# Get the perceived intensity.
	my $intensity = $self->GetWeightedIntensity($bgcolor);
	#info "Color '$bgcolor': Intensity $intensity\n";

	if ($intensity > 0.5)
	{
		return "black";
	}
	else
	{
		return "white";
	}
}

# This method calculates the intensity according to a certain formula.
# $color is any color accepted by the underlying plugin.
# Returns a value in 0..1 range.
sub GetWeightedIntensity
{
	my $self = shift;
	my ($color) = @_;

	return $self->GetWeightedIntensity_FormulaC($color);
}

# This method calculates the intensity for certain colour spaces.
# $color is any color accepted by the underlying plugin.
# Explanation:
# The human eye is not equally sensitive to all color components. The weights
# are about r:g:b = 0.2126 : 0.7152 : 0.0722
# Returns a value in 0..1 range.
sub GetWeightedIntensity_FormulaA
{
	my $self = shift;
	my ($color) = @_;

	my ($r, $g, $b) = $self->GetRgb($color);
	#info "Color '$color': Components($r, $g, $b)\n";
	return 0.2126*$r + 0.7152*$g + 0.0722*$b;
}

# This method calculates the intensity as it is perceived by the eye.
# $color is any color accepted by the underlying plugin.
# Explanation:
# The human eye is not equally sensitive to all color components. The weights
# are about r:g:b = 0.299 : 0.587 : 0.114
# Returns a value in 0..1 range.
sub GetWeightedIntensity_FormulaB
{
	my $self = shift;
	my ($color) = @_;

	my ($r, $g, $b) = $self->GetRgb($color);
	#info "Color '$color': Components($r, $g, $b)\n";
	return 0.299*$r + 0.587*$g + 0.114*$b;
}

# This method calculates the intensity as it is perceived by the eye.
# $color is any color accepted by the underlying plugin.
# Explanation:
# The human eye is not equally sensitive to all color components. The weights
# are about r:g:b = 0.299 : 0.587 : 0.114
# Returns a value in 0..1 range.
sub GetWeightedIntensity_FormulaC
{
	my $self = shift;
	my ($color) = @_;

	my ($r, $g, $b) = $self->GetRgb($color);
	#info "Color '$color': Components($r, $g, $b)\n";
	return sqrt(0.299*$r**2 + 0.587*$g**2 + 0.114*$b**2);
}

# Return the platform-specific RGB components of the specified color.
sub GetRgbRaw
{
	my $self = shift;
	my ($color) = @_;

	confess "Abstract method called";
}

my @WhiteRgb;

# This method returns an array with the (r,g,b) values for the specified
# color. These components are all in the 0..1 range.
sub GetRgb
{
	my $self = shift;
	my ($color) = @_;

	# Get the components
	my @color = $self->GetRgbRaw($color);
	# Scale it to 0..1 range where white is 1
	@WhiteRgb = $self->GetRgbRaw("white") unless @WhiteRgb;
	for (my $i = 0, my $len = @color; $i < $len; ++$i)
	{
		$color[$i] /= $WhiteRgb[$i];
	}
	return @color;
}


##############################################################################
### Create window

# Get the mainwindow.
# Throws exception if not yet created.
sub GetMainWin
{
	my $self = shift;

	my $mw = $self->{MainWin};
	die "MainWin does not yet exist" unless $mw;
	return $mw;
}

# Get the the top panel that holds the menu and the clock.
# Throws exception if not yet created.
sub GetTopPanel
{
	my $self = shift;

	my $frm = $self->{TopPanel};
	die "TopPanel does not yet exist" unless $frm;
	return $frm;
}

# Get the the middle panel that holds the timers.
# Throws exception if not yet created.
sub GetMiddlePanel
{
	my $self = shift;

	my $frm = $self->{MiddlePanel};
	die "MiddlePanel does not yet exist" unless $frm;
	return $frm;
}

# Get the the bottom panel that holds the default timer (0).
# Throws exception if not yet created.
sub GetBottomPanel
{
	my $self = shift;

	my $frm = $self->{BottomPanel};
	die "BottomPanel does not yet exist" unless $frm;
	return $frm;
}

# Create the MainWindow.
sub CreateMainWin
{
	my $self = shift;

	confess "Abstract method called";
}

# Returns the data of the icon in XPM format.
sub GetNormalIcon32XPM
{
	my $self = shift;

	return <<'ICON';
/* XPM */
static char * stopw_xpm[] = {
"32 32 11 1",
"  c none",
". c #000000",
"+ c #00FFFF",
"@ c #C0C0C0",
"# c #808080",
"$ c #FFFFFF",
"% c #FF0000",
"& c #800080",
"* c #000080",
"= c #FFFF00",
"- c #808000",
"             .....              ",
"            .+.@.#.             ",
"            .+.@.#.             ",
"             .@##.              ",
"   ..      .........      ..    ",
"  .$#.   ..@@@@@@@@@..   .+@.   ",
" .+@#. ..##$$$%&%$$$##.. .@@#.  ",
" .@#.#.##@$$$$&&&$$$$###.@.##.  ",
"  ..#.#@$$&&$$%&%$$&&$$##.#..   ",
"    .#@$$$&&$$$$$$$&&$$$##.     ",
"   .#@$$.$$$$$$$$$$$$$$$$##.    ",
"   .#@&&$.$$$$$.$$$$$$$$$$#.    ",
"  .#@$&&$$.$$$$.$$$$$$$&&$##.   ",
"  .#@$$$$$$.$$$.$$$$$$$&&$$#.   ",
" .#@$$$$$$$$.$$.$$$$$$$$$$$##.  ",
" .#@$$$$$$$$$.$.$$$$$$$$$$$##.  ",
" .#@$$$$$$$$$$...$$$$$$$$$$$#.  ",
" .#@&&$$$$$$$$.+.$$$$$$$$&&$#.  ",
" .#@&&$$$$$$$$...$$$$$$$$&&$#.  ",
" .#@$$$$$$$$$&$$$$$$$$$$$$$$#.  ",
" .#@$$$$$$$$&$$$$$$$$$$$$$$##.  ",
" .#@$$$$$$$&$$$$$$$$$$$$$$$##.  ",
"  .#@$&&$$&$$$$$$$$$$$$&&$$#.   ",
"................................",
".$*$*$*$*$*$*$*$*$*$*$*$*$*$*$*.",
".=*=*=*=*=*=*=*=*=*=*=*=*=*=*=*.",
".===*===*===*===*===*===*===*==.",
".=======*=======*=======*======.",
".==============================.",
".==============================.",
".------------------------------.",
"................................"};
ICON
}

# Create and set the Icons on the MainWin.
sub CreateIcons
{
	my $self = shift;

	confess "Abstract method called";
}

# Create the MainMenu on the MainWin.
sub CreateMainMenu
{
	my $self = shift;

	confess "Abstract method called";
}

# Create the Clock on the MainWin.
sub CreateWallClock
{
	my $self = shift;

	confess "Abstract method called";
}

# Create form with the widgets for one timer. This form is created at the top
# of the $parent_widget. The timer widgets are also added to the @Timers
# data structure.
sub CreateTimer
{
	my $self = shift;
	my ($parent_widget, $timer_id) = @_;

	confess "Abstract method called";
}

sub CreateGui
{
	my $self = shift;

	$self->CreateIcons;
	$self->CreateMainMenu;
	$self->CreateWallClock;

	my $panel = $self->GetMiddlePanel;
	foreach my $id (1..get_num_timers)
	{
		$self->CreateTimer($panel, $id);
	}
	my $panel = $self->GetBottomPanel;
	$self->CreateTimer($panel, 0);
}

}  # end of package


##############################################################################
### General functions

my @PreviousPeriodInfo;

# Set this timer visually/behaviourally in edit-mode.
sub TimerVisualEditMode
{
	my ($timer, $mode) = @_;

	#info "TimerVisualEditMode($timer, '$mode')\n";
	my $preset;
	if ($mode eq "inc" || $mode eq "dec")
	{
		$preset = "0:00:00";  # inc/dec: default to 0:00:00
	}
	elsif ($mode eq "take")
	{
		@PreviousPeriodInfo = get_previous_period_info;
		#info "PreviousPeriodInfo=( @PreviousPeriodInfo )\n";
		my $time = $PreviousPeriodInfo[1] - $PreviousPeriodInfo[0];
		$preset = format_time $time;
	}
	else
	{
		$preset = undef;  # leave current total time
	}
	$GuiPlugin->SetTimerEditMode($timer, $preset);
}

# Set this timer visually/behaviourally in normal-mode.
sub TimerVisualNormalMode
{
	my ($timer) = @_;

	#info "TimerVisualNormalMode($timer)\n";
	my $is_active = get_active == $timer;
	$GuiPlugin->SetTimerNormalMode($timer, $is_active);
	show_timer $timer;
}

# Accept the entry, update the timer and go to normal-mode.
sub TimerEditOk
{
	#info "TimerEditOk()\n";

	return if $TimerEdit < 0;  # return if no timer in edit-mode.

	eval
	{
		$TimerEditUpdate = 1;  # Can be edited again
		my $value = $GuiPlugin->GetTimerTime($TimerEdit);
		if ($TimerEditMode eq "edit")
		{
			set_timer $TimerEdit, $value;
		}
		elsif ($TimerEditMode eq "inc")
		{
			add_timer $TimerEdit, $value;
		}
		elsif ($TimerEditMode eq "dec")
		{
			add_timer $TimerEdit, "-($value)";
		}
		elsif ($TimerEditMode eq "transfer")
		{
			transfer_time $TimerEdit, undef, $value;
		}
		elsif ($TimerEditMode eq "take")
		{
			transfer_time $PreviousPeriodInfo[2], $TimerEdit, $value;
		}
		# NB: The add_timer() function will also update the gui.
		# If there is an exception when evaluating, we stay in edit-mode.

		TimerVisualNormalMode $TimerEdit;
		$TimerEdit = -1;
	};
	if ($@)
	{
		$TimerEditUpdate = 0;
		die $@;
	}
	@PreviousPeriodInfo = ();
}

# Cancel the entry and go to normal mode.
sub TimerEditCancel
{
	#info "TimerEditCancel()\n";

	return if $TimerEdit < 0;  # return if no timer in edit-mode.

	$TimerEditUpdate = 1;  # Can be edited again
	TimerVisualNormalMode $TimerEdit;
	$TimerEdit = -1;
	@PreviousPeriodInfo = ();
}

# If there is a timer that is editable, set it in normal-mode.
sub TimerNormalMode
{
	#info "TimerNormalMode()\n";
	TimerVisualNormalMode $TimerEdit if $TimerEdit >= 0;
	$TimerEdit = -1;
}

# Put the specified timer in edit-mode.
# If there is another timer in edit-mode, revert that.
sub TimerEditMode
{
	my ($timer, $mode) = @_;

	#info "TimerEditMode($timer, '$mode')\n";
	if ($timer != $TimerEdit)
	{
		TimerNormalMode;
		TimerVisualEditMode $timer, $mode;

		($TimerEdit, $TimerEditMode, $TimerEditUpdate) = ($timer, $mode, 0);
	}
}

# Call this function to update the title with new active Timer's description.
# It often happens that descriptions start with the same string. In a limited
# taskbar, it would be useful to see where it is different. This function also
# finds the common prefix (whole words only) and skips it if configured in the
# config.
sub UpdateTitle
{
	my $description = get_timer_current_description(get_active);
	my $app_name = "TimeKeeper";

	my $prefix_replace = get_title_replace_common_prefix;
	if (defined $prefix_replace)
	{
		# Find common prefix
		my $longest_common_prefix = 0;
		foreach my $t (0..get_num_timers)
		{
			my $d = get_timer_current_description($t);
			next if lc $description eq lc $d;  # skip the same
			local $_ = "$description\n$d";
			# In this string with 2 descriptions, find the common
			# prefix with a regex.
			# The prefix should be followed by whitespace (to
			# force prefixes to be whole words), possibly
			# with punctuation. This punctuation and whitespace
			# does not need to be matched by the other description
			# exactly.
			# o Just punctuation without whitespace is not enough
			#   because "A/B: C" and "A: D" is not "B: C" and "D"
			if (/^
				(                # Capture 1: Prefix in current description
					(.*)     # Capture 2: Prefix that is exactly matched
					[\p{PUNCTUATION}]* # Any amount of punctuation
					\s+      # Mandatory whitespace (to separate the word)
				)
				(.*\w.*)         # Capture 3: Rest of the description (non-empty)
				\n
				(                # Capture 4: Matched other prefix
					\2       # Matched prefix
					[\p{PUNCTUATION}]* # Any amount of punctuation
					\s+      # Mandatory whitespace (to separate the word)
				)
				/ix)
			{
				# Both descriptions start with the same prefix
				# and the prefix ends with a whitespace, so it
				# is a whole word.
				# The second part must contain a word character
				my $len_prefix = length $1;
				if ($len_prefix > $longest_common_prefix)
				{
					# This one is longer
					$longest_common_prefix = $len_prefix;
				}
			}
		}
		if ($longest_common_prefix > 0)
		{
			# Do the replacement
			if ($prefix_replace =~ m{^\s*s\{(.*)\}\{(.*)\}\s*$})
			{
				# This is a regex replacement
				my ($re, $repl) = ($1, $2);
				eval
				{
					# Construct 'prefix<TAB>tail'
					substr($description, $longest_common_prefix, 0) = "\t";
					# Execute regex (use same delimiter chars)
					$description =~ s{$re}{eval qq("$repl")}e;
				};
				if ($@)
				{
					# Report error
					info "ERROR: Prefix replacement error: $@";
				}
			}
			else
			{
				# This is a simple string replacement.
				substr($description, 0, $longest_common_prefix) =
					$prefix_replace;
			}
		}
	}

	$GuiPlugin->SetWindowTitle("$description - $app_name");
}


##############################################################################
### Event handlers that are triggered by the controls

sub EvtStartStop
{
	startstop;
}

sub EvtActivate
{
	my ($timer) = @_;

	TimerEditCancel if $TimerEdit >= 0;
	activate $timer;
}

sub EvtEditTimer
{
	my ($timer, $mode) = @_;

	#info "EvtEditTimer($timer,$mode)\n";
	TimerEditMode $timer, $mode;
}

sub EvtEditDescription
{
	my ($timer, $description) = @_;

	# This callback is also called at widget creation. Check this also.
	if ($InitReady)
	{
		# Widget has properly been created.
		# NB: $entry->get() is the before-value of this change.
		set_description_delayed $timer, $description;
	}
	return 1;  # validate ok
}

sub EvtResetTimer
{
	my ($timer) = @_;

	if ($timer eq "all")
	{
		$timer = [ 0 .. get_num_timers ];
	}
	show_timer $timer, 0;
}

sub EvtSetTimerGroup
{
	my ($timer, $groupname) = @_;

	set_timer_group_name $timer, $groupname;
}

sub EvtDefineLog
{
	edit_logdef;
}

sub EvtSetGenerateTarget
{
	my ($target, $status_ref) = @_;

	add_remove_generate_log_target $target, $status_ref;
}

sub EvtGenerateLog
{
	my ($logId) = @_;

	make_log $logId, get_generate_log_targets;
}

sub EvtEditConfig
{
	edit_config;
}

sub EvtEditEvents
{
	edit_storage;
}

sub EvtEditGroups
{
	edit_groups;
}

# Redraws wall time
sub EvtRedrawWallTime
{
	CbUpdateWallTime();
}

# Cycle from the current clock format to the next.
sub EvtCycleClockFormat
{
	my $clockFormat = $GuiPlugin->GetWallTimeFormat;
	++$clockFormat;  # the next format
	$clockFormat = 0 if $clockFormat >= @ClockFormats;
	$GuiPlugin->SetWallTimeFormat($clockFormat);

	EvtRedrawWallTime;
}


##############################################################################
### Callbacks that are called to change controls

sub CbActivate
{
	my ($timer) = @_;

	#print "CbActivate($timer)\n";
	$GuiPlugin->DrawTimerActive($timer, $timer == $TimerEdit);

	UpdateTitle;
}

sub CbDeactivate
{
	my ($timer) = @_;

	#print "CbDeactivate($timer)\n";
	$GuiPlugin->DrawTimerInactive($timer, $timer == $TimerEdit);
}

sub CbStart
{
	$GuiPlugin->DrawRunning;
}

sub CbStop
{
	$GuiPlugin->DrawStopped;
}

sub CbUpdateTimerTime
{
	my ($timer, $time) = @_;

	return if $timer == $TimerEdit && !$TimerEditUpdate;  # If timer is being edited, leave it alone

	my $text = format_time($time) || " ";  # space instead of empty to force update
	#info "Set timer $timer to '$text'\n";
	$GuiPlugin->SetTimerTime($timer, $text);
}

sub CbUpdateTimerDescription
{
	my ($timer, $description) = @_;

	#info "CbUpdateTimerDescription($timer,$description)\n";
	$GuiPlugin->SetTimerDescription($timer, $description);
	if ($timer == get_active)
	{
		# The active timer's description changed, update the title.
		UpdateTitle;
	}
}

sub CbUpdateTimerGroup
{
	my ($timer, $groupname, $groupcolor) = @_;

	info "CbUpdateTimerGroup($timer,$groupname,$groupcolor)\n";
	$GuiPlugin->SetTimerGroup($timer, $groupname, $groupcolor);
}

# Update the wall-time.
# If $time is not defined, use $LastWallTime. If that is not defined, use
# time().
# Remember last specified defined time in $LastWallTime.
my $LastWallTime;
sub CbUpdateWallTime
{
	my ($time) = @_;

	if (defined $time)
	{
		$LastWallTime = $time;
	}
	else
	{
		$time = $LastWallTime || time();
	}

	my $wall_time;
	my $clockFormat = $GuiPlugin->GetWallTimeFormat;
	if ($clockFormat == 0)  # normal format
	{
		# This will be the most common one
		$wall_time = format_datetime_full $time;
	}
	elsif ($clockFormat == 1)  # unix timestamp
	{
		$wall_time = "(UNIX time)    $time";
	}
	elsif ($clockFormat == 2)  # days & seconds since 1-1-1970
	{
		my $ltime = $time + get_timezone_offset;
		my $days = int($ltime / (24*60*60));  # days since 1-1-1970
		my $sec = $ltime % (24*60*60);  # seconds since 0:00:00
		$wall_time = "(Since 1-1-1970)    $days - $sec";
	}
	elsif ($clockFormat == 3)  # days & seconds since 1-1-1
	{
		my $ltime = $time + get_timezone_offset;
		my $days = int($ltime / (24*60*60));  # days since 1-1-1970
		$days += 719162;  # days from 1-1-1 to 1-1-1970
		my $sec = $ltime % (24*60*60);  # seconds since 0:00:00
		$wall_time = "(Since 1-1-1)    $days - $sec";
	}
	elsif ($clockFormat == 4)  # GMT date & time
	{
		my @parts = gmtime $time; ++$parts[4]; $parts[5] += 1900;
		$wall_time = sprintf "GMT %d-%d-%04d %d:%02d:%02d", @parts[3, 4, 5, 2, 1, 0];
	}
	elsif ($clockFormat == 5)  # StarTrek Stardate
	{
		# Format YYDDD.T
		# - YY: Year: First digit originally was the century ('4') and
		#    the second digit the season ('1' is 1987, the first year
		#    of Star Trek TNG).
		# - DDD: Day: This number goes from 000 to 999 during the year.
		# - T: This should divide the day in ten parts.
		# I calculate it as follows: 1-1-2323 is stardate 0 (Date of
		# first contact). Each year consists of 1000 parts. Each of
		# those 1000 parts is 8.76 hours (=31536 seconds).
		# Use 4 decimal places so that a once-per-second update doesn't
		# jump.
		# It is a bit weird, but since this is a decimal date+time
		# system, it means that the absolute time in the day gets
		# smaller when the date is negative (i.e. before 1-1-2323).
		# Example: The year 2322 (YY=-1) should run from -999 to 0.
		my @parts = localtime $time;
		my $year = $parts[5] + 1900;  # year
		my $yday = $parts[7];  # day in year
		my $dtime = $parts[2] * 60*60 + $parts[1] * 60 + $parts[0];  # time in day
		my $ysecs = $yday * 24*60*60 + $dtime;  # seconds in year
		my $max_yday = is_leapyear($year) ? 366 : 365;
		# Convert to stardate
		my $sdyear = $year - 2323;  # 1-1-2323 is origin
		my $sdsecs = 1000 * $ysecs / ($max_yday*24*60*60);  # fraction of year in 0..999
		my $stardate = ($sdyear * 1000) + $sdsecs;  # works for neg and pos years
		$wall_time = sprintf "(Stardate)    %5.4f", $stardate;
	}
	else
	{
		$wall_time = format_datetime_full $time;
	}

	$GuiPlugin->SetWallTime($wall_time);
}

sub CbSetClipboard
{
	my ($data) = @_;

	$GuiPlugin->SetClipboard($data);
}


##############################################################################
### Package interface

sub Init
{
	$InitReady = 0;
	# Check if we can create a GUI
	$GuiPlugin = TimeKeeper::Gui::PluginBase::create();
	# Initialize core
	initialize @_;
	# initialize GUI
	$GuiPlugin->SetWallTimeFormats(@ClockFormats);
	$GuiPlugin->CreateMainWin;
	if (my $font = get_default_font)
	{
		$GuiPlugin->AddOption("*font", $font);
	}
	$GuiPlugin->CreateGui;
	$InitReady = 1;
}

sub Run
{
	# Set the callbacks
	set_cb_activate \&CbActivate;
	set_cb_deactivate \&CbDeactivate;
	set_cb_start \&CbStart;
	set_cb_stop \&CbStop;
	set_cb_update_timer_time \&CbUpdateTimerTime;
	set_cb_update_timer_description \&CbUpdateTimerDescription;
	set_cb_update_timer_group \&CbUpdateTimerGroup;
	set_cb_update_wall_time \&CbUpdateWallTime;
	set_cb_set_clipboard \&CbSetClipboard;

	# Set the timer to 4 times a second
	$GuiPlugin->SetRepeatTimer(250, \&time_tick);
	initialize_ui;

	# Start the message loop
	$GuiPlugin->Run;

	# Unset the callbacks
	set_cb_activate;
	set_cb_deactivate;
	set_cb_start;
	set_cb_stop;
	set_cb_update_timer_time;
	set_cb_update_timer_description;
	set_cb_update_timer_group;
	set_cb_update_wall_time;
	set_cb_set_clipboard;

	return 0;
}

sub Done
{
	finalize;
}


1;


