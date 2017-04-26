package TimeKeeper::Gui::PluginTk;

# This module implements a GUI-plugin, based on Perl/Tk for the TimeKeeper GUI.

use strict;
use base qw(TimeKeeper::Gui::PluginBase);

use Tk;
use Tk::Balloon;
use Tk::Pane;

use TimeKeeper::Gui qw/:plugin/;

use TimeKeeper::ImgUtils;
use TimeKeeper::ErrorDialog;


##############################################################################
### Constructors and factory methods

# Construct
sub new
{
	my $class = shift;

	my $self = $class->SUPER::new();
	# Set values
	$$self{AddCancelMenuItem} = 1;
	# Add my variables
	my %sub = (
		# references to widgets
		NormalIcon => undef,  # normal icon
		StoppedIcon => undef,  # icon when stopped

		# constants
	);
	@$self{keys %sub} = values %sub;

	return $self;
}


##############################################################################
### GUI draw and query functions

# Set this timer visually/behaviourally in edit-mode.
# If $preset is defined, display that value, otherwise keep the current value.
sub SetTimerEditMode
{
	my $self = shift;
	my ($timer, $preset) = @_;

	my $timerc = $self->{Timers}[$timer];
	my $ctrl_time = $timerc->{timectrl};
	my $timetext = $timerc->{timetext};
	# Go into edit-mode
	$ctrl_time->configure(-background => $self->{ColorEditable}, -insertontime => $self->{DefaultInsertOnTime});
	# Set edit-mode event-handlers
	$ctrl_time->bind("<Escape>", \&TimerEditCancel);
	$ctrl_time->bind("<Return>", \&TimerEditOk);
	$ctrl_time->bind("<Button-1>", undef);
	# Put right value in editbox
	$$timetext = $preset if defined $preset;
	$ctrl_time->selectionRange(0, "end");
	$ctrl_time->focus;
}

# Set this timer visually/behaviourally in normal-mode.
sub SetTimerNormalMode
{
	my $self = shift;
	my ($timer, $is_active) = @_;

	my $timerc = $self->{Timers}[$timer];
	my $ctrl_time = $timerc->{timectrl};
	# Go out of edit-mode
	my $color = $self->{$is_active ? "ColorActive" : "ColorReadOnly"};
	$ctrl_time->configure(-background => $color, -insertontime => 0);
	# Set normal event-handlers
	$ctrl_time->bind("<Escape>", undef);
	$ctrl_time->bind("<Return>", undef);
	$ctrl_time->bind("<Button-1>", sub { EvtActivate $timer });
	# Put right value in editbox
	$ctrl_time->selectionClear;
}

# Draw specified timer in an active state.
sub DrawTimerActive
{
	my $self = shift;
	my ($timer, $is_edit) = @_;

	my $timerc = $self->{Timers}[$timer];
	$timerc->{descrctrl}->configure(-background => $self->{ColorActive});
	my $color = $self->{$is_edit ? "ColorEditable" : "ColorActive"};
	$timerc->{timectrl}->configure(-background => $color);
}

# Draw specified timer in an inactive state.
sub DrawTimerInactive
{
	my $self = shift;
	my ($timer, $is_edit) = @_;

	my $timerc = $self->{Timers}[$timer];
	$timerc->{descrctrl}->configure(-background => $self->{ColorEditable});
	my $color = $self->{$is_edit ? "ColorEditable" : "ColorReadOnly"};
	$timerc->{timectrl}->configure(-background => $color);
}

# Draw application in a running state.
sub DrawRunning
{
	my $self = shift;

	#$self->GetMainWin->Icon(-image => $self->{NormalIcon});
	$self->{CopyRightLabel}->configure(-foreground => "#EECC00");
}

# Draw application in a stopped state.
sub DrawStopped
{
	my $self = shift;

	#$self->GetMainWin->Icon(-image => $self->{StoppedIcon});
	$self->{CopyRightLabel}->configure(-foreground => "red");
}

# Set the title of the toplevel main window.
sub SetWindowTitle
{
	my $self = shift;
	my ($title) = @_;

	$self->GetMainWin->title($title);
}

# Set the description of the specified timer.
sub SetTimerDescription
{
	my $self = shift;
	my ($timer, $description) = @_;

	${$self->{Timers}[$timer]{descrtext}} = $description;
}

# Set the group of the specified timer.
sub SetTimerGroup
{
	my $self = shift;
	my ($timer, $groupname, $groupcolor) = @_;

	my ($fg, $bg) = $self->GetTimerGroupColoring($groupname, $groupcolor);
	$groupname = "" unless defined $groupname;

	${$self->{Timers}[$timer]{groupname}} = $groupname;
	$self->{Timers}[$timer]{labelctrl}->configure(-background => $bg, -foreground => $fg);
}

# Set the time displayed in the specified timer.
sub SetTimerTime
{
	my $self = shift;
	my ($timer, $time) = @_;

	${$self->{Timers}[$timer]{timetext}} = $time;
}

# Get the time displayed in the specified timer.
sub GetTimerTime
{
	my $self = shift;
	my ($timer) = @_;

	return ${$self->{Timers}[$timer]{timetext}};
}

# Set the specified time (string) as wall-time on the clock.
sub SetWallTime
{
	my $self = shift;
	my ($time) = @_;

	$self->{LblClock}->configure(-text => $time);
}

# Popup the menu at position (x,y) on the widget.
sub ShowPopup
{
	my $self = shift;
	my ($menu, $widget, $x, $y) = @_;

	$menu->post($x + $widget->rootx, $y + $widget->rooty);
}


##############################################################################
### Miscellaneous GUI-stuff

# Run the GUI's main loop
sub Run
{
	my $self = shift;

	MainLoop;
}

# Set a function to be repetitively (every $time milliseconds) called.
sub SetRepeatTimer
{
	my $self = shift;
	my ($time, $func) = @_;

	$self->GetMainWin->repeat($time, $func);
}

# Set data on the clipboard
sub SetClipboard
{
	my $self = shift;
	my ($data) = @_;

	my $mw = $self->GetMainWin;
	$mw->clipboardClear;
	# For some reason, the (windows) clipboard likes to have unix
	# line-breaks.
	$mw->clipboardAppend(dos2unix $data);
}

# Add the specified option with the specified value.
sub AddOption
{
	my $self = shift;
	my ($option, $value) = @_;

	$self->GetMainWin->optionAdd($option, $value);
}

# Return the platform-specific RGB components of the specified color.
sub GetRgbRaw
{
	my $self = shift;
	my ($color) = @_;

	return $self->GetMainWin->rgb($color);
}


##############################################################################
### Create window

# The fonts are specified as "fontname size style" triplets. This function
# retrieves the widget's current font in @$_ and calls &$change. It then
# configures the font again. This way, the default font can be kept.
# Examples:
# - Make font bold: $gui->change_font($widget, sub { $$_[2] = "bold" });
sub change_font
{
	my $self = shift;
	my ($widget, $change) = @_;

	local $_ = ${$widget->cget("-font")};  # copy the referenced string
	#info "ORIGINAL FONT: '$_'\n";
	$_ = [ /^(.*?) ([-+]?\d+)(?: ([a-z ]+))?$/i ];
	# NB: The style is optional
	# NB: Sizes can be negative. Negative sizes could means size in points
	# rather than pixels.
	#info "FONT BEFORE: '$$_[0]', '$$_[1]', '$$_[2]'\n";
	&$change;  # apply the change
	#info "FONT AFTER: '$$_[0]', '$$_[1]', '$$_[2]'\n";
	$_ = join " ", @$_;
	$widget->configure(-font => $_);  # set the changed font
}

# Add a separator and a menu-item if AddCancelMenuItem is true.
# This is convenient if the windowing system does not cancel a posted menu if
# one clicks outside.
sub add_cancel_menu_item
{
	my $self = shift;
	my ($menu) = @_;

	if ($self->{AddCancelMenuItem})
	{
		$menu->add("separator");
		$menu->add("command", -label => "Cancel Menu");
	}
}

# Get the x-coordinate for the specified index in the specified Entry control.
sub entry_get_x
{
	my $self = shift;
	my ($entry, $index) = @_;

	my ($x, $y, $w, $h) = $entry->bbox($index);
	if ($index == $entry->index("end"))
	{
		# Cursor is at the end. Now bbox() has returned the coordinates
		# of the character *before* instead of the character after.
		# Correct this to make it more standard.
		($x, $w) = ($x + $w, 0);
	}
	return wantarray ? ( $x, $x + $w ) : $x;
}

# Get the numeric index for the specified x-coordinate in the specified Entry
# control.
sub entry_get_index
{
	my $self = shift;
	my ($entry, $x) = @_;

	return $entry->index("@" . $x);
}

# Get the current index for the specified Entry control.
sub entry_get_current_index
{
	my $self = shift;
	my ($entry) = @_;

	return $entry->index("insert");
}

# Focus the specified Entry control and set the insertion cursor if specified.
sub entry_focus
{
	my $self = shift;
	my ($entry, $icursor) = @_;

	$entry->focus();
	$entry->icursor($icursor) if defined $icursor;
}

# Deletes the contents in the selection range.
sub entry_delete_selection
{
	my $self = shift;
	my ($entry) = @_;

	$entry->delete("sel.first", "sel.last") if $entry->selectionPresent;
}

# Clear the selection tag
sub entry_clear_selection
{
	my $self = shift;
	my ($entry) = @_;

	$entry->selectionClear;
}

# Create the MainWindow.
sub CreateMainWin
{
	my $self = shift;

	$self->{MainWin} = my $mw = new MainWindow(-title => "TimeKeeper");
	TimeKeeper::ImgUtils::set_rgb_function sub { return $self->GetRgbRaw($_[0]) };

	$self->{ColorReadOnly} = $self->{ColorWindowBackground} = $mw->cget("-background");
	$self->{ColorEditable} = "white";

	if (my $geometry = get_geometry)
	{
		#sleep 2; print "Set initial geometry ($geometry)\n";
		$mw->geometry($geometry);
		# The above command does set the size of the window correctly,
		# but the position not. The latter depends on the size of the
		# window frame and if the frame is taken into account or not.
		# Ubuntu has the same origin for geometry and rootx/y. Windows,
		# however, not. To work around this, check if the current
		# position is ok and if not, adjust with the difference (which
		# is the thickness of the frame).
		$mw->update;  # update, so that rootx/rooty are updated as well
		#sleep 2;
		my @desired = geometry_pos $geometry;
		my @current = geometry_pos $mw->geometry;
		#print "Resulting position: (@current)\n";
		my @adjust;
		$adjust[$_] = $desired[$_] - $current[$_] foreach 0..3;
		#print "Adjust position: (@adjust)\n";
		$mw->geometry(get_geometry(@adjust));
		$mw->update;  # update to prevent flickering
		#sleep 2; print "Second update (geometry=(" . $mw->geometry . "))\n";
	}

	# Create the TopPanel
	$self->{TopPanel} = $mw->Frame->pack(-side => "top", -fill => "x");

	# Create the MiddlePanel which is scrollable
	# To make a Frame scrollable, use a Pane.
	my $frm = $mw->Scrolled("Pane", -scrollbars => "ow", -sticky => "new")->pack(-fill => "both", -expand => "yes");
	$frm->OnDestroy(sub {
		# At this time, this value seems to be always 0.
		set_scroll_pos $frm->yview;
	});
	# The mouse wheel is not working by default.
	my $middlePaneScroll = sub {
		my $self = shift;
		my ($delta) = @_;

		$delta = sprintf "%.0f", ($delta / 120) * -3;  # convert to scroll units
		#info "Scroll $delta units\n";
		$frm->yview("scroll", $delta, "units");
	};
	# For Windows, use the <MouseWheel> event
	$mw->bind("<MouseWheel>" => [ $middlePaneScroll, Tk::Ev("D") ]);
	# For Linux, use the virtual mouse buttons 4 and 5
	$mw->bind("<Button-4>" => [ $middlePaneScroll, 120 ]);
	$mw->bind("<Button-5>" => [ $middlePaneScroll, -120 ]);

	# I haven't found a way (or event) to set the scroll position. The
	# only thing I found was using a timeout. The problem is that in order
	# to do this, the scrollbar must exist. I think the same is true for
	# the OnDestoy event above.
	#$mw->after(1000, sub { $frm->yview(moveto => 0.25); });
	$self->{MiddlePanel} = $frm;

	# Create the BottomPanel
	$self->{BottomPanel} = $mw->Frame->pack(-side => "top", -fill => "x");

	$mw->OnDestroy(sub {
		set_geometry $mw->geometry;
	});
}

# Create and set the Icons on the MainWin.
sub CreateIcons
{
	my $self = shift;

	my $mw = $self->GetMainWin;
	my $normalIcon32_data = $self->GetNormalIcon32XPM;

	my $normalIcon;
	if ($^O =~ /MSWin32/i)
	{
		# * The downscale from 32x32 to 16x16 in Windows is quite bad,
		#   Therefore, help it by supplying a down-and-upscaled icon.

		# * Windows can't handle transparent color, so replace "none" by
		#   something suitable.
		$normalIcon = $mw->Pixmap(-data => 
			blur_xpm 3, 2,
			replace_color_xpm {
				"none" => $self->{ColorTitle},
			},
			$normalIcon32_data
		);
	}
	else
	{
		$normalIcon = $mw->Pixmap(-data => $normalIcon32_data);
	}
	# Defining the icon mask only really works with $mw->DefineBitmap()
	# (as opposed to the normal $mw->Bitmap() constructor. Furthermore,
	# it has to be referenced by name.
	my $data = create_mask_from_xpm $normalIcon;
	$mw->DefineBitmap("iconmask", 32, 32, $data);

	# Create a reddish icon for the stopped status
	my $stoppedIcon = $mw->Pixmap(-data =>
		replace_color_xpm {
			"#FFFFFF" => "#FFBBBB",
			"#FFFF00" => "#FF8800",
			"#000000" => "#BB0000",
		},
		$normalIcon
	);

	# Set the MainWindow icons
	$self->{NormalIcon} = $normalIcon;
	$self->{StoppedIcon} = $stoppedIcon;
	$mw->iconimage($normalIcon);
	$mw->iconmask("iconmask");
}

# Create the MainMenu on the MainWin.
sub CreateMainMenu
{
	my $self = shift;

	my $mw = $self->GetMainWin;
	my $frm = $self->GetTopPanel;

	# Create copyright label
	$self->{CopyRightLabel} = my $copyRightLabel =
		$frm->Label(-text => "(C) AGB 2001+", -foreground => "#EECC00")->pack(-side => "left");
	$copyRightLabel->bind("<Enter>", sub { $copyRightLabel->configure(-relief => "raised") });
	$copyRightLabel->bind("<Leave>", sub { $copyRightLabel->configure(-relief => "flat") });
	$copyRightLabel->bind("<ButtonPress-1>", sub { $copyRightLabel->configure(-relief => "sunken") });
	$copyRightLabel->bind("<ButtonRelease-1>", sub { $copyRightLabel->configure(-relief => "raised"); EvtStartStop });

	# Create the main menu
	my $mainmenu = $copyRightLabel->Menu(-tearoff => 0);
	$mainmenu->add("command", -label => "Pause/Resume", -command => [ \&EvtStartStop ]);
	$mainmenu->add("command", -label => "Reset All", -command => [ \&EvtResetTimer, "all" ]);
	$mainmenu->add("separator");
	$mainmenu->add("command", -label => "Generate Log", -command => [ \&EvtGenerateLog, "default" ]);
	my @alt_logs = get_alt_logs;
	if (@alt_logs > 0)
	{
		my $mnuAltLogs = $mainmenu->cascade(-label => "Alternative Logs", -tearoff => 0);
		foreach (@alt_logs)
		{
			$mnuAltLogs->command(-label => $_, -command => [ \&EvtGenerateLog, $_ ]);
		}
	}
	$mainmenu->add("command", -label => "Define Log", -command => [ \&EvtDefineLog ]);
	$mainmenu->add("command", -label => "Define Timer Groups", -command => [ \&EvtEditGroups ]);
	foreach my $target (qw/editor clipboard/)
	{
		my $status = is_generate_log_target $target;
		$mainmenu->checkbutton(-label => "Generate Log to \u$target", -variable => \$status, -command => [ \&EvtSetGenerateTarget, $target, \$status ]);
	}
	$mainmenu->add("separator");
	my @tools = get_exttool_entries;
	if (@tools > 0)
	{
		# There are tools, create a submenu
		my $mnuTools = $mainmenu->cascade(-label => "Tools", -tearoff => 0);
		foreach my $entry (@tools)
		{
			my ($text, $command) = @$entry;
			if ($text eq "---")
			{
				$mnuTools->separator;
			}
			else
			{
				$mnuTools->command(-label => $text, -command => sub { system $command });
			}
		}
		$mainmenu->add("separator");
	}
	$mainmenu->add("command", -label => "Configuration", -command => [ \&EvtEditConfig ]);
	my $clockFormats = $self->{ClockFormats};
	if ($clockFormats && @$clockFormats > 1)
	{
		my $clockFormat = $self->{ClockFormatRef};
		my $mnuClockFormat = $mainmenu->cascade(-label => "Clock Format", -tearoff => 1);
		foreach my $cf (0..@$clockFormats-1)
		{
			my $format = $$clockFormats[$cf];
			$mnuClockFormat->radiobutton(-label => $format, -variable => $clockFormat, -value => $cf, -command => \&EvtRedrawWallTime);
		}
	}
	$mainmenu->add("command", -label => "Edit Events", -command => [ \&EvtEditEvents ]);
	$mainmenu->add("separator");
	$mainmenu->add("command", -label => "Quit & Keep timing", -command => sub { set_keep_running_status 1; $mw->destroy });
	$mainmenu->add("command", -label => "Exit", -command => sub { $mw->destroy });
	$self->add_cancel_menu_item($mainmenu);
	$copyRightLabel->bind("<Button-3>", [ $self, 'ShowPopup', $mainmenu, Ev("W"), Ev("x"), Ev("y") ]);
	$mw->Balloon(-state => "balloon", -balloonposition => "mouse")->attach($copyRightLabel, -msg => "Click to pause/resume\nRightclick for menu");
	$self->change_font($copyRightLabel, sub { $$_[2] = "bold" });
}

# Create the Clock on the MainWin.
sub CreateWallClock
{
	my $self = shift;

	my $frm = $self->GetTopPanel;

	# Create WallClock (label with current time)
	$self->{LblClock} = my $lblClock = $frm->Label->pack(-side => "right");
	$self->change_font($lblClock, sub { $$_[2] = "normal" });
	
	# Create menu for clock
	my $clockFormats = $self->{ClockFormats};
	if ($clockFormats && @$clockFormats > 1)
	{
		my $clockmenu = $lblClock->Menu(-tearoff => 0);
		my $clockFormat = $self->{ClockFormatRef};
		my $mnuClockFormat = $clockmenu->cascade(-label => "Clock Format", -tearoff => 1);
		foreach my $cf (0..@$clockFormats-1)
		{
			my $format = $$clockFormats[$cf];
			$mnuClockFormat->radiobutton(-label => $format, -variable => $clockFormat, -value => $cf, -command => \&EvtRedrawWallTime);
		}
		$self->add_cancel_menu_item($clockmenu);

		$lblClock->bind("<Button-3>", [ $self, 'ShowPopup', $clockmenu, Ev("W"), Ev("x"), Ev("y") ]);

		$lblClock->bind("<Double-Button-1>", \&EvtCycleClockFormat);
	}
}

# Create form with the widgets for one timer. This form is created at the top
# of the $parent_widget. The timer widgets are also added to the @Timers
# data structure.
sub CreateTimer
{
	my $self = shift;
	my ($parent_widget, $timer_id) = @_;

	my $colorEditable = $self->{ColorEditable};
	my $colorReadOnly = $self->{ColorReadOnly};

	my $frm = $parent_widget->Frame->pack(-side => "top", -fill => "x");

	# number label
	my $label = $frm->Label(-text => $timer_id, -width => "2", -justify => "right")->pack(-side => "left", -anchor => "e");
	# Retrieve group-info of this timer and set the background color
	my $groupname = get_timer_current_group_name $timer_id;
	my $group = get_timer_group_info $groupname;
	if ($group)
	{
		my $groupcolor = $$group{color};
		my ($fg, $bg) = $self->GetTimerGroupColoring($groupname, $groupcolor);
		$label->configure(-background => $bg, -foreground => $fg);
		#info "Create Timer $timer_id with group $groupname and color $groupcolor\n";
	}
	my $popupGroupsMenu = sub {
		splice @_, 0, -3;  # leave all but the last 3 arguments (widget, x, y)
		my $menu = $label->Menu(-tearoff => 0);
		$menu->radiobutton(-label => "<None>", -variable => \$groupname, -value => "", -command => [ \&EvtSetTimerGroup, $timer_id, "" ]);
		my $groups = get_timer_group_infos;
		if ($groups && @$groups)
		{
			# There are groups, add them to the menu
			foreach my $group (@$groups)
			{
				my $name = $$group{name};
				$menu->radiobutton(-label => $name, -variable => \$groupname, -value => $name, -command => [ \&EvtSetTimerGroup, $timer_id, $name ]);
				my $color = $$group{color};
				my ($fg, $bg) = $self->GetTimerGroupColoring($name, $color);
				$menu->entryconfigure("last", -background => $bg, -foreground => $fg, -selectcolor => $fg);
			}
			$menu->separator;
		}
		# Add option to edit groups
		$menu->add("command", -label => "Edit Groups", -command => [ \&EvtEditGroups]);
		$self->add_cancel_menu_item($menu);
		$self->ShowPopup($menu, @_);
	};
	# Add the bindings
	$label->bind("<Button-3>", [ $popupGroupsMenu, Ev("W"), Ev("x"), Ev("y") ]);
	$self->GetMainWin->Balloon(-state => "balloon", -balloonposition => "mouse", -initwait => 750)->attach($label, -msg => "Rightclick to change group");

	# description field
	my $text = get_timer_current_description $timer_id;
	my $descr = $frm->Entry(-textvariable => \$text, -validate => "all", -validatecommand => sub { EvtEditDescription $timer_id, $_[0] }, -background => $colorEditable)
		# Put it at the left side to keep space for $time later on. Set -expand=>1
		# to have allocation rectangle consume all remaining space. Set -fill=>x
		# to have widget grow inside allocation rectangle.
		->pack(-fill => "x", -side => "left", -expand => 1);
	$self->{DefaultInsertOnTime} = $descr->cget("-insertontime");

	# time field
	my $timetext = format_time get_timer_current_time $timer_id;
	my $time = $frm->Entry(-textvariable => \$timetext, -width => "7", -justify => "right", -background => $colorReadOnly, -cursor => "arrow", -insertontime => "0")
		->pack(-side => "right");
	$time->bind("<Button-1>", sub { EvtActivate $timer_id });
	my $menu = $time->Menu(-tearoff => 0);
	$menu->add("command", -label => "Activate", -command => sub { EvtActivate $timer_id });
	$menu->add("command", -label => "Reset", -command => [ \&EvtResetTimer, $timer_id ]);
	$menu->add("command", -label => "Reset All", -command => [ \&EvtResetTimer, "all" ]);
	$menu->add("separator");
	my %mniTransfer;  # items to remember about the menuitem Transfer
	$mniTransfer{mode} = "transfer";
	$menu->add("command", -label => "<transfer>", -command => sub { EvtEditTimer($timer_id, $mniTransfer{mode}) });
	$mniTransfer{index} = $menu->index("last");
	my $mnuTimeEdit = $menu->cascade(-label => "Edit", -tearoff => 0);
	$mnuTimeEdit->command(-label => "Increase", -command => [ \&EvtEditTimer, $timer_id, "inc" ]);
	$mnuTimeEdit->command(-label => "Decrease", -command => [ \&EvtEditTimer, $timer_id, "dec" ]);
	$mnuTimeEdit->command(-label => "Edit", -command => [ \&EvtEditTimer, $timer_id, "edit" ]);
	$self->add_cancel_menu_item($menu);
	my $popupTimeMenu = sub {
		splice @_, 0, -3;  # leave all but the last 3 arguments (widget, x, y)
		my ($label, $mode);
		if (get_active == $timer_id)
		{
			$label = "Take from Previous";
			$mode = "take";
		}
		else
		{
			$label = "Transfer to Active";
			$mode = "transfer";
		}
		$menu->entryconfigure($mniTransfer{index}, -label => $label);
		$mniTransfer{mode} = $mode;
		$self->ShowPopup($menu, @_);
	};
	$time->bind("<Button-3>", [ $popupTimeMenu, Ev("W"), Ev("x"), Ev("y") ]);
	$self->GetMainWin->Balloon(-state => "balloon", -balloonposition => "mouse", -initwait => 750)->attach($time, -msg => "Click to activate\nRightclick for menu");

	# The default behaviour of an Entry is that a selection is not replaced
	# with the pasted text. I'd like it if it did, so I have this class
	# binding.
	# Idealy, this could be a class binding, but I haven't figured out how
	# to do that exactly, so for now it is an instance binding.
	$descr->bind("<<Paste>>", sub { $self->entry_delete_selection($_[0]) });
	$time->bind("<<Paste>>", sub { $self->entry_delete_selection($_[0]) });

	# Add event to go to next timer description on arrow-up/down
	$descr->bind("<Down>", sub { $self->FocusNextDescription($timer_id, 1) });
	$descr->bind("<Up>", sub { $self->FocusNextDescription($timer_id, -1) });

	# Add widgets to data structure
	$self->{Timers}[$timer_id] = {
		labelctrl => $label,
		groupname => \$groupname,
		descrctrl => $descr,
		descrtext => \$text,
		timectrl  => $time,
		timetext  => \$timetext,
	};
}


1;


